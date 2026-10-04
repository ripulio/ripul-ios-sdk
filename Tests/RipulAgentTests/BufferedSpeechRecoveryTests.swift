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
        timing.catchUp = 1_000_000
        return timing
    }

    /// Short segments so a test can reach a pause-delimited commit quickly.
    @available(iOS 26.0, macOS 26.0, *)
    private var shortSegmentTiming: ElevenLabsTranscriptionStream.Timing {
        var timing = fastTiming
        timing.segmentTarget = 2
        timing.segmentPause = 1
        return timing
    }

    /// Committing at every short pause made Scribe finalize fragments on their
    /// own: clipped words and invented fillers at each seam. Natural pauses
    /// inside the first 20 s must not close a segment; the first pause after
    /// it does; 30 s is a hard cap even with no pause at all.
    @MainActor
    func testPausesDoNotCommitBeforeTargetButCloseTheSegmentAfterIt() async throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip() }
        let audio = BufferedSpeechAudio(sampleRate: 100)
        let socket = SpeechSocketFixture()
        socket.ready()
        var commitAtFrames: [Int] = []
        var sentFrames = 0
        socket.onSend = { payload in
            if payload["commit"] as? Bool == true {
                commitAtFrames.append(sentFrames)
                socket.committed("segment")
            } else if let pcm = Data(base64Encoded: payload["audio_base_64"] as! String) {
                sentFrames += pcm.count / 2
            }
        }
        let stream = ElevenLabsTranscriptionStream(audio: audio, timing: fastTiming,
                                                   connect: { socket }, event: { _ in })
        defer { stream.stop() }
        stream.start()
        // 18 s of speech with a 2 s thinking pause every 4 s: 2 s voiced, 2 s quiet.
        for second in 0..<18 {
            audio.append(Data(count: 200), voiced: second % 4 < 2)
        }
        try await eventually { sentFrames == 1800 }
        XCTAssertEqual(commitAtFrames, [], "Pauses before the 20 s target must not commit")
        // Speech through 21 s, then a pause: the segment closes at that pause.
        for _ in 18..<21 { audio.append(Data(count: 200), voiced: true) }
        audio.append(Data(count: 200), voiced: false)
        try await eventually { commitAtFrames.count == 1 }
        XCTAssertEqual(commitAtFrames, [2200])
        // 31 s of continuous speech: forced at 30 s, never beyond it.
        for _ in 0..<31 { audio.append(Data(count: 200), voiced: true) }
        try await eventually { commitAtFrames.count == 2 }
        XCTAssertEqual(commitAtFrames[1] - commitAtFrames[0], 3000)
        try await stream.finish()
        XCTAssertEqual(audio.snapshot.confirmed, audio.snapshot.captured)
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
        let stream = ElevenLabsTranscriptionStream(audio: audio, timing: shortSegmentTiming, connect: {
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

    /// Scribe can send a partial for a segment after its committed transcript.
    /// Passed through, the controller showed committed + partial and sent
    /// "A. Send command. A". Stale partials must not surface; new speech must.
    @MainActor
    func testLatePartialForCommittedSegmentIsDropped() async throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip() }
        let audio = BufferedSpeechAudio(sampleRate: 100)
        let socket = SpeechSocketFixture()
        socket.ready()
        var partials: [String] = []
        socket.onSend = { payload in
            guard payload["commit"] as? Bool == true else { return }
            socket.committed("We need to recheck. Send command.")
            socket.emit(["message_type": "partial_transcript", "text": "We need to recheck. Send command."])
            socket.emit(["message_type": "partial_transcript", "text": "we need to recheck send"])
        }
        let stream = ElevenLabsTranscriptionStream(audio: audio, timing: shortSegmentTiming, connect: { socket }, event: {
            if case .partial(let text) = $0 { partials.append(text) }
        })
        defer { stream.stop() }
        audio.append(Data(count: 200), voiced: true)
        audio.append(Data(count: 200), voiced: true)
        audio.append(Data(count: 200), voiced: false)
        stream.start()
        try await eventually { audio.snapshot.confirmed == 300 }
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(partials, [], "Partials for already-committed audio must be dropped")
        socket.onSend = nil
        audio.append(Data(count: 200), voiced: true)
        try await eventually { (socket.sent.last?["audio_base_64"] as? String) != nil && socket.sent.count >= 5 }
        socket.emit(["message_type": "partial_transcript", "text": "Different new words"])
        try await eventually { partials == ["Different new words"] }
    }

    /// Scribe says nothing about sound it does not hear as speech. The stream
    /// read twelve seconds of that as a dead socket whenever the microphone
    /// had been loud once, and reconnected: ten times in 3.5 minutes on one
    /// phone, each one a replay of the same noise.
    @MainActor
    func testSoundWithoutSpeechDoesNotReconnect() async throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip() }
        let audio = BufferedSpeechAudio(sampleRate: 100)
        let socket = SpeechSocketFixture()
        socket.ready()
        var connections = 0
        var timing = fastTiming
        timing.responseTimeout = 0.02
        let stream = ElevenLabsTranscriptionStream(audio: audio, timing: timing, connect: {
            connections += 1; return socket
        }, event: { _ in })
        defer { stream.stop() }
        stream.start()
        audio.append(Data(count: 200), voiced: true)
        try await eventually { socket.sent.count == 1 }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(connections, 1)
        XCTAssertFalse(socket.cancelled)
    }

    /// With text out for the open segment Scribe repeats it about once a
    /// second, so going quiet then does mean the connection has died.
    @MainActor
    func testSilenceWhileTextIsOutReconnects() async throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip() }
        let audio = BufferedSpeechAudio(sampleRate: 100)
        let first = SpeechSocketFixture(), second = SpeechSocketFixture()
        first.ready(); second.ready()
        var connections = 0
        var timing = fastTiming
        timing.responseTimeout = 0.03
        let stream = ElevenLabsTranscriptionStream(audio: audio, timing: timing, connect: {
            connections += 1; return connections == 1 ? first : second
        }, event: { _ in })
        defer { stream.stop() }
        audio.append(Data(count: 200), voiced: true)
        stream.start()
        try await eventually { first.sent.count == 1 }
        first.emit(["message_type": "partial_transcript", "text": "Hello"])
        try await eventually { connections == 2 }
        XCTAssertTrue(first.cancelled)
    }

    /// A reconnect replays the open segment and Scribe transcribes it from its
    /// first word again. Shown as it arrived, that was the whole utterance
    /// starting over on screen. The reconnect point is not a segment boundary
    /// either: a commit there cuts mid-sentence.
    @MainActor
    func testReplayedTextStaysOffScreenUntilItHasCaughtUp() async throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip() }
        let audio = BufferedSpeechAudio(sampleRate: 100)
        let first = SpeechSocketFixture(), second = SpeechSocketFixture()
        first.ready(); second.ready()
        var connections = 0
        var screen: [String] = []
        var replayed = 0
        var commits = 0
        let regrowing = ["one", "one two", "one two three four"]
        second.onSend = { payload in
            if payload["commit"] as? Bool == true { commits += 1; return }
            replayed += 1
            second.emit(["message_type": "partial_transcript", "text": regrowing[min(replayed, 3) - 1]])
            // Let the stream read it before the next chunk moves the replay on.
            try await Task.sleep(nanoseconds: 3_000_000)
        }
        let stream = ElevenLabsTranscriptionStream(audio: audio, timing: fastTiming, connect: {
            connections += 1; return connections == 1 ? first : second
        }, event: {
            switch $0 {
            case .partial(let text): screen.append(text)
            case .committed(let text): screen.append("committed: " + text)
            case .recovery(nil) where connections > 1: screen.append("recovered")
            default: break
            }
        })
        defer { stream.stop() }
        for _ in 0..<3 { audio.append(Data(count: 200), voiced: true) }
        stream.start()
        try await eventually { first.sent.count == 3 }
        first.emit(["message_type": "partial_transcript", "text": "one two three"])
        try await eventually { screen == ["one two three"] }
        first.deliver(.failure(URLError(.networkConnectionLost)))
        try await eventually { screen.last == "recovered" }
        XCTAssertEqual(screen, ["one two three", "one two three four", "recovered"])
        XCTAssertEqual(commits, 0, "The reconnect point must not close the segment")
        XCTAssertEqual(audio.snapshot.confirmed, 0)
    }

    /// A long replay passes a real segment boundary on the way. That text
    /// reaches the screen with the rest of the replay, not ahead of it, where
    /// it would wipe the words still showing after it.
    @MainActor
    func testSegmentClosedDuringReplayReachesTheScreenWithTheRest() async throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip() }
        let audio = BufferedSpeechAudio(sampleRate: 100)
        let first = SpeechSocketFixture(), second = SpeechSocketFixture()
        first.ready(); second.ready()
        first.onSend = { _ in if first.sent.count > 1 { throw URLError(.networkConnectionLost) } }
        var connections = 0
        var screen: [String] = []
        var screenBeforeCatchUp: [String]?
        var replayed = 0
        second.onSend = { payload in
            if payload["commit"] as? Bool == true { second.committed("alpha beta."); return }
            replayed += 1
            guard replayed == 5 else { return }
            screenBeforeCatchUp = screen
            second.emit(["message_type": "partial_transcript", "text": "gamma delta"])
        }
        let stream = ElevenLabsTranscriptionStream(audio: audio, timing: shortSegmentTiming, connect: {
            connections += 1; return connections == 1 ? first : second
        }, event: {
            switch $0 {
            case .partial(let text): screen.append(text)
            case .committed(let text): screen.append("committed: " + text)
            case .recovery(nil) where connections > 1: screen.append("recovered")
            default: break
            }
        })
        defer { stream.stop() }
        audio.append(Data(count: 200), voiced: true)
        stream.start()
        try await eventually { first.sent.count == 1 }
        first.emit(["message_type": "partial_transcript", "text": "alpha"])
        try await eventually { screen == ["alpha"] }
        // Speech, a pause long enough to close the segment, then more speech.
        audio.append(Data(count: 200), voiced: true)
        audio.append(Data(count: 200), voiced: false)
        audio.append(Data(count: 200), voiced: true)
        audio.append(Data(count: 200), voiced: true)
        try await eventually { screen.last == "recovered" }
        XCTAssertEqual(screenBeforeCatchUp, ["alpha"])
        XCTAssertEqual(screen, ["alpha", "committed: alpha beta.", "gamma delta", "recovered"])
        XCTAssertEqual(audio.snapshot.confirmed, 300)
    }

    /// Text a replay had already confirmed is the user's, even when recovery
    /// then gives up. It is handed over before the failure is reported.
    @MainActor
    func testConfirmedReplayTextSurvivesAFailedRecovery() async throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip() }
        let audio = BufferedSpeechAudio(sampleRate: 100)
        let first = SpeechSocketFixture(), second = SpeechSocketFixture()
        first.ready(); second.ready()
        first.onSend = { _ in if first.sent.count > 1 { throw URLError(.networkConnectionLost) } }
        var acknowledged = false
        second.onSend = { payload in
            if payload["commit"] as? Bool == true { acknowledged = true; second.committed("alpha beta."); return }
            if acknowledged { throw URLError(.networkConnectionLost) }
        }
        var connections = 0
        var outcome: [String] = []
        var timing = shortSegmentTiming
        timing.recoveryLimit = 0.05
        let stream = ElevenLabsTranscriptionStream(audio: audio, timing: timing, connect: {
            connections += 1
            if connections == 1 { return first }
            if connections == 2 { return second }
            throw URLError(.notConnectedToInternet)
        }, event: {
            switch $0 {
            case .committed(let text): outcome.append("committed: " + text)
            case .error: outcome.append("failed")
            default: break
            }
        })
        defer { stream.stop() }
        audio.append(Data(count: 200), voiced: true)
        stream.start()
        try await eventually { first.sent.count == 1 }
        audio.append(Data(count: 200), voiced: true)
        audio.append(Data(count: 200), voiced: false)
        audio.append(Data(count: 200), voiced: true)
        try await eventually { outcome.last == "failed" }
        XCTAssertEqual(outcome, ["committed: alpha beta.", "failed"])
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
