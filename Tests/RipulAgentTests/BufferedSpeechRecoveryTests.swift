import XCTest
@testable import RipulAgent

@MainActor
private final class SpeechSocketFixture: RealtimeSpeechSocket {
    var messages: [Result<String, Error>] = []
    var waiting: CheckedContinuation<String, Error>?
    var sent: [[String: Any]] = []
    var onSend: (([String: Any]) async throws -> Void)?
    var cancelled = false
    var concurrentSends = 0
    var maxConcurrentSends = 0

    func send(_ text: String) async throws {
        concurrentSends += 1
        maxConcurrentSends = max(maxConcurrentSends, concurrentSends)
        defer { concurrentSends -= 1 }
        let payload = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        sent.append(payload)
        try await onSend?(payload)
    }
    func receive() async throws -> String {
        if !messages.isEmpty { return try messages.removeFirst().get() }
        if cancelled { throw CancellationError() }
        return try await withCheckedThrowingContinuation { waiting = $0 }
    }
    func emit(_ object: [String: Any]) {
        let text = String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        deliver(.success(text))
    }
    func deliver(_ result: Result<String, Error>) {
        if let waiting { self.waiting = nil; waiting.resume(with: result) }
        else { messages.append(result) }
    }
    func cancel() {
        cancelled = true
        if let waiting { self.waiting = nil; waiting.resume(throwing: CancellationError()) }
    }
    func ready() { emit(["message_type": "session_started"]) }
    func committed(_ text: String) { emit(["message_type": "committed_transcript", "text": text]) }
}

final class BufferedSpeechRecoveryTests: XCTestCase {
    func testBufferRetainsSentAudioUntilAcknowledgementAndReportsOverflow() {
        let audio = BufferedSpeechAudio(sampleRate: 100, seconds: 2)
        audio.append(Data(repeating: 1, count: 200), voiced: true)
        audio.append(Data(repeating: 2, count: 200), voiced: true)
        XCTAssertNotNil(audio.chunk(after: 0))
        audio.acknowledge(through: 100)
        XCTAssertNil(audio.chunk(after: 0))
        XCTAssertEqual(audio.chunk(after: 100)?.pcm.first, 2)
        audio.append(Data(repeating: 3, count: 200), voiced: true)
        XCTAssertFalse(audio.snapshot.overflow)
        audio.append(Data(repeating: 4, count: 2), voiced: true)
        XCTAssertTrue(audio.snapshot.overflow)
        XCTAssertFalse(audio.snapshot.recording)
        XCTAssertEqual(audio.snapshot.captured, 300, "Overflow must not overwrite untranscribed audio")
    }

    @MainActor
    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let until = Date().addingTimeInterval(3)
        while !condition() && Date() < until { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    @available(iOS 26.0, macOS 26.0, *)
    private var fastTiming: ElevenLabsTranscriptionStream.Timing {
        var timing = ElevenLabsTranscriptionStream.Timing()
        timing.poll = 1_000_000
        timing.retry = 1_000_000
        return timing
    }

    @MainActor
    func testDisconnectReplaysOnlyUnconfirmedPCMThenDrainsBeforeFinishing() async throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip() }
        let audio = BufferedSpeechAudio(sampleRate: 100)
        let first = SpeechSocketFixture(), second = SpeechSocketFixture()
        first.ready(); second.ready()
        var connections = 0
        var commits: [String] = []
        var recovered = false
        first.onSend = { payload in
            if payload["commit"] as? Bool == true { first.committed("Hello") }
            else if Data(base64Encoded: payload["audio_base_64"] as! String)?.first == 3 {
                throw URLError(.networkConnectionLost)
            }
        }
        second.onSend = { payload in
            // Hold a real asynchronous send; a second send must not overlap it.
            try await Task.sleep(nanoseconds: 2_000_000)
            if payload["commit"] as? Bool == true { second.committed("there") }
        }
        let stream = ElevenLabsTranscriptionStream(audio: audio, timing: fastTiming, connect: {
            connections += 1
            return connections == 1 ? first : second
        }, event: {
            if case .committed(let text) = $0 { commits.append(text) }
            if case .recovery(nil) = $0, connections > 1 { recovered = true }
        })
        defer { stream.stop() }
        audio.append(Data(repeating: 1, count: 200), voiced: true)
        audio.append(Data(repeating: 2, count: 200), voiced: false)
        stream.start()
        try await eventually { audio.snapshot.confirmed == 200 }
        audio.append(Data(repeating: 3, count: 200), voiced: true)
        try await eventually { connections == 2 }
        audio.append(Data(repeating: 4, count: 200), voiced: true)
        try await stream.finish()
        XCTAssertTrue(stream.finished)
        XCTAssertTrue(recovered)
        XCTAssertEqual(commits, ["Hello", "there"])
        XCTAssertEqual(audio.snapshot.confirmed, 400)
        XCTAssertEqual(Data(base64Encoded: second.sent[0]["audio_base_64"] as! String)?.first, 3)
        XCTAssertTrue((second.sent[0]["previous_text"] as? String)?.contains("Hello") == true)
        XCTAssertFalse(second.sent.dropFirst().contains { $0["previous_text"] != nil })
        XCTAssertEqual(second.maxConcurrentSends, 1)
    }

    @MainActor
    func testLostCommitReplyReplaysSegmentAndEmitsTextOnce() async throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip() }
        let audio = BufferedSpeechAudio(sampleRate: 100)
        audio.append(Data(repeating: 7, count: 400), voiced: true)
        let first = SpeechSocketFixture(), second = SpeechSocketFixture()
        first.ready(); second.ready()
        var connections = 0
        var commits: [String] = []
        first.onSend = { payload in
            if payload["commit"] as? Bool == true {
                first.deliver(.failure(URLError(.networkConnectionLost)))
            }
        }
        second.onSend = { payload in
            if payload["commit"] as? Bool == true { second.committed("Only once") }
        }
        let stream = ElevenLabsTranscriptionStream(audio: audio, timing: fastTiming, connect: {
            connections += 1; return connections == 1 ? first : second
        }, event: { if case .committed(let text) = $0 { commits.append(text) } })
        defer { stream.stop() }
        stream.start()
        try await stream.finish()
        XCTAssertEqual(commits, ["Only once"])
        XCTAssertEqual(audio.snapshot.confirmed, 200)
        XCTAssertEqual(Data(base64Encoded: second.sent[0]["audio_base_64"] as! String), Data(repeating: 7, count: 400))
    }

    @MainActor
    func testFinalizationWaitsForCommittedTextAndIgnoresTimestampDuplicate() async throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip() }
        let audio = BufferedSpeechAudio(sampleRate: 100)
        audio.append(Data(repeating: 8, count: 100), voiced: true)
        let socket = SpeechSocketFixture(); socket.ready()
        var commits: [String] = []
        let stream = ElevenLabsTranscriptionStream(audio: audio, timing: fastTiming, connect: { socket },
            event: { if case .committed(let text) = $0 { commits.append(text) } })
        defer { stream.stop() }
        stream.start()
        let finalization = Task { try await stream.finish() }
        try await eventually { socket.sent.contains { $0["commit"] as? Bool == true } }
        XCTAssertFalse(stream.finished, "A successful send is not a transcription acknowledgement")
        XCTAssertEqual(audio.snapshot.confirmed, 0)
        XCTAssertEqual(Data(base64Encoded: socket.sent.last!["audio_base_64"] as! String)?.count, 300, "Short final segment is padded to two seconds")
        socket.committed("Final words")
        socket.emit(["message_type": "committed_transcript_with_timestamps", "text": "Final words"])
        try await finalization.value
        XCTAssertEqual(commits, ["Final words"])
        XCTAssertEqual(audio.snapshot.confirmed, 50)
    }

    @MainActor
    func testOverflowStopsWithExplicitMissingSpeechError() async throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip() }
        let audio = BufferedSpeechAudio(sampleRate: 100, seconds: 1)
        let socket = SpeechSocketFixture()
        var errors: [String] = []
        let stream = ElevenLabsTranscriptionStream(audio: audio, timing: fastTiming, connect: { socket },
            event: { if case .audioGap(let message) = $0 { errors.append(message) } })
        defer { stream.stop() }
        stream.start()
        audio.append(Data(count: 202), voiced: true)
        try await eventually { !errors.isEmpty }
        XCTAssertTrue(errors[0].contains("some speech is missing"))
        do { try await stream.finish(); XCTFail("Must not finish successfully after audio loss") } catch {}
    }

    @MainActor
    func testStartupRetriesAreBoundedButAnEstablishedConversationCanRetryAgain() async throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip() }
        let startupAudio = BufferedSpeechAudio(sampleRate: 100)
        var attempts = 0
        var startupFailure: String?
        let startup = ElevenLabsTranscriptionStream(audio: startupAudio, timing: fastTiming, connect: {
            attempts += 1
            throw URLError(.notConnectedToInternet)
        }, event: { if case .error(let text) = $0 { startupFailure = text } })
        defer { startup.stop() }
        startup.start()
        try await eventually { startupFailure != nil }
        XCTAssertEqual(attempts, 3)

        let audio = BufferedSpeechAudio(sampleRate: 100)
        audio.append(Data(repeating: 9, count: 400), voiced: true)
        let socket = SpeechSocketFixture(); socket.ready()
        socket.onSend = { payload in
            if payload["commit"] as? Bool == true { socket.committed("Recovered") }
        }
        var retries = 0
        let existing = ElevenLabsTranscriptionStream(audio: audio, previouslyConnected: true, timing: fastTiming, connect: {
            retries += 1
            if retries < 5 { throw URLError(.notConnectedToInternet) }
            return socket
        }, event: { _ in })
        defer { existing.stop() }
        existing.start()
        try await existing.finish()
        XCTAssertEqual(retries, 5)
        XCTAssertEqual(audio.snapshot.confirmed, 200)
    }

    @MainActor
    func testUnresponsiveSocketReconnectsAndLateFactoryCompletionIsCancelled() async throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip() }
        let audio = BufferedSpeechAudio(sampleRate: 100)
        audio.append(Data(repeating: 6, count: 400), voiced: true)
        let late = SpeechSocketFixture(), replacement = SpeechSocketFixture()
        replacement.ready()
        replacement.onSend = { payload in
            if payload["commit"] as? Bool == true { replacement.committed("Recovered after timeout") }
        }
        var factory: CheckedContinuation<any RealtimeSpeechSocket, Never>?
        var attempts = 0
        var timing = fastTiming
        timing.connectionTimeout = 0.02
        let stream = ElevenLabsTranscriptionStream(audio: audio, timing: timing, connect: {
            attempts += 1
            if attempts == 1 { return await withCheckedContinuation { factory = $0 } }
            return replacement
        }, event: { _ in })
        defer { stream.stop() }
        stream.start()
        try await eventually { attempts == 2 }
        factory?.resume(returning: late)
        try await stream.finish()
        XCTAssertTrue(late.cancelled)
        XCTAssertFalse(replacement.cancelled)
        XCTAssertEqual(audio.snapshot.confirmed, 200)
    }

    @MainActor
    func testMissingCommitResponseTimesOutWithoutDroppingAudio() async throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip() }
        let audio = BufferedSpeechAudio(sampleRate: 100)
        audio.append(Data(repeating: 5, count: 400), voiced: true)
        let stalled = SpeechSocketFixture(), replacement = SpeechSocketFixture()
        stalled.ready(); replacement.ready()
        replacement.onSend = { payload in
            if payload["commit"] as? Bool == true { replacement.committed("Complete") }
        }
        var attempts = 0
        var timing = fastTiming
        timing.responseTimeout = 0.02
        let stream = ElevenLabsTranscriptionStream(audio: audio, timing: timing, connect: {
            attempts += 1; return attempts == 1 ? stalled : replacement
        }, event: { _ in })
        defer { stream.stop() }
        stream.start()
        try await stream.finish()
        XCTAssertEqual(attempts, 2)
        XCTAssertTrue(stalled.cancelled)
        XCTAssertEqual(audio.snapshot.confirmed, 200)
    }

    @MainActor
    func testHungAudioSendIsReplayedOnNewSocket() async throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip() }
        let audio = BufferedSpeechAudio(sampleRate: 100)
        audio.append(Data(repeating: 5, count: 400), voiced: false)
        let stalled = SpeechSocketFixture(), replacement = SpeechSocketFixture()
        stalled.ready(); replacement.ready()
        stalled.onSend = { _ in try await Task.sleep(nanoseconds: 5_000_000_000) }
        replacement.onSend = { payload in
            if payload["commit"] as? Bool == true { replacement.committed("") }
        }
        var attempts = 0
        var timing = fastTiming
        timing.responseTimeout = 0.02
        let stream = ElevenLabsTranscriptionStream(audio: audio, timing: timing, connect: {
            attempts += 1; return attempts == 1 ? stalled : replacement
        }, event: { _ in })
        defer { stream.stop() }
        stream.start()
        try await stream.finish()
        XCTAssertEqual(attempts, 2)
        XCTAssertTrue(stalled.cancelled)
        XCTAssertEqual(audio.snapshot.confirmed, 200)
    }

    @MainActor
    func testStopCancelsReconnectAndFinishing() async throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip() }
        let audio = BufferedSpeechAudio(sampleRate: 100)
        audio.append(Data(count: 200), voiced: true)
        let socket = SpeechSocketFixture(); socket.ready()
        let stream = ElevenLabsTranscriptionStream(audio: audio, timing: fastTiming, connect: { socket }, event: { _ in })
        stream.start()
        let finish = Task { try await stream.finish() }
        try await eventually { !socket.sent.isEmpty }
        stream.stop()
        do { try await finish.value; XCTFail("Stopped capture must not send") } catch {}
        XCTAssertTrue(socket.cancelled)
    }
}
