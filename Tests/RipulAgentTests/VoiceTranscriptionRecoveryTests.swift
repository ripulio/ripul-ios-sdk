import XCTest
@testable import RipulAgent

@available(iOS 26.0, macOS 26.0, *)
@MainActor
private final class StubTranscriptionProvider: BufferedConversationSpeechProviding {
    let id: String
    var label: String { id }
    var starts: [(@MainActor (SpeechService.TranscriptionEvent) -> Void)] = []
    var startError: Error?
    var startEventError: String?
    var onStart: (() -> Void)?
    var suspendStartup = false
    var pendingStarts: [CheckedContinuation<Void, Never>] = []
    var bufferedConversationTranscription = true
    var onFinish: (() async throws -> Void)?
    func finishBufferedTranscription() async throws { try await onFinish?() }

    init(_ id: String) { self.id = id }
    func listVoices() async throws -> [SpeechService.Voice] { [] }
    func speak(text: String, voiceId: String?, onPlaybackEnd: (@MainActor () -> Void)?) async throws {}
    func stopSpeaking() {}
    func pauseSpeaking() {}
    func resumeSpeaking() {}
    func startTranscription(onEvent: @escaping @MainActor (SpeechService.TranscriptionEvent) -> Void) async throws {
        starts.append(onEvent)
        onStart?()
        if suspendStartup {
            await withCheckedContinuation { pendingStarts.append($0) }
        }
        if let startError { throw startError }
        if let startEventError { onEvent(.error(startEventError)) }
    }
    func stopTranscription() { starts.last?(.ended) }
}

final class VoiceTranscriptionRecoveryTests: XCTestCase {
    @MainActor
    func testSendWaitsForFinalTranscriptAndTypedOverrideCancelsWaitingSend() async throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip() }
        for override in [false, true] {
            let cloud = StubTranscriptionProvider("elevenlabs")
            var submitted: [String] = []
            let controller = VoiceModeController(transcriptionProvider: cloud, fallback: StubTranscriptionProvider("apple"),
                submit: { submitted.append($0); return false })
            defer { controller.stop() }
            let started = expectation(description: "Capture")
            cloud.onStart = { started.fulfill() }
            controller.beginListening(keepText: false)
            await fulfillment(of: [started], timeout: 1)
            let callback = try XCTUnwrap(cloud.starts.last)
            callback(.connectionReady)
            callback(.partial("Incomplete"))
            callback(.recovery("Reconnecting — still recording"))
            let draining = expectation(description: "Drain starts")
            var finish: CheckedContinuation<Void, Never>?
            cloud.onFinish = {
                draining.fulfill()
                await withCheckedContinuation { finish = $0 }
            }
            controller.sendNow()
            await fulfillment(of: [draining], timeout: 1)
            XCTAssertTrue(submitted.isEmpty)
            XCTAssertTrue(controller.isFinalizingTranscription)
            if override { controller.submitTypedUtterance("Typed override") }
            callback(.committed("Complete recovered words"))
            finish?.resume()
            try await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertEqual(submitted, [override ? "Typed override" : "Complete recovered words"])
        }
    }

    @MainActor
    func testReadyCloudNeverFallsBackEvenBeforeItsFirstWordOrOnLaterUtterance() async throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip() }
        let cloud = StubTranscriptionProvider("elevenlabs")
        let apple = StubTranscriptionProvider("apple")
        let controller = VoiceModeController(transcriptionProvider: cloud, fallback: apple)
        defer { controller.stop() }
        let first = expectation(description: "First capture")
        cloud.onStart = { first.fulfill() }
        controller.beginListening(keepText: false)
        await fulfillment(of: [first], timeout: 1)
        cloud.starts.last?(.connectionReady)
        cloud.starts.last?(.error("Cloud unavailable"))
        XCTAssertEqual(controller.phase, .paused)
        XCTAssertTrue(apple.starts.isEmpty)

        let second = expectation(description: "Later utterance")
        cloud.onStart = { second.fulfill() }
        cloud.startError = URLError(.notConnectedToInternet)
        controller.resumeConversation()
        await fulfillment(of: [second], timeout: 1)
        XCTAssertEqual(controller.phase, .paused)
        XCTAssertTrue(apple.starts.isEmpty, "Startup of a later utterance must not reset fallback eligibility")
    }

    @MainActor
    func testRecoveringMicStaysLiveAndPauseWaitsForSavedTranscript() async throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip() }
        let cloud = StubTranscriptionProvider("elevenlabs")
        let controller = VoiceModeController(transcriptionProvider: cloud, fallback: StubTranscriptionProvider("apple"))
        defer { controller.stop() }
        let started = expectation(description: "Capture")
        cloud.onStart = { started.fulfill() }
        controller.beginListening(keepText: false)
        await fulfillment(of: [started], timeout: 1)
        cloud.starts.last?(.connectionReady)
        cloud.starts.last?(.recovery("Reconnecting — still recording"))
        cloud.starts.last?(.audioLevel(0.1))
        XCTAssertTrue(controller.captureLive)
        XCTAssertTrue(controller.listeningStatus.contains("still recording"))
        let draining = expectation(description: "Waiting for final transcript")
        var finish: CheckedContinuation<Void, Never>?
        cloud.onFinish = {
            draining.fulfill()
            await withCheckedContinuation { finish = $0 }
        }
        controller.pauseConversation()
        await fulfillment(of: [draining], timeout: 1)
        XCTAssertTrue(controller.isFinalizingTranscription)
        XCTAssertFalse(controller.captureLive)
        XCTAssertFalse(controller.canSendNow)
        XCTAssertTrue(controller.listeningStatus.contains("audio saved"))
        cloud.starts.last?(.committed("Saved during reconnect"))
        XCTAssertFalse(controller.captureLive, "A final result must not relight a stopped microphone")
        finish?.resume()
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(controller.phase, .paused)
        XCTAssertEqual(controller.committedText, "Saved during reconnect")
    }

    @MainActor
    func testAudioGapBeforeCloudReadyDoesNotPretendAppleCanRecoverIt() async throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip() }
        let cloud = StubTranscriptionProvider("elevenlabs")
        let apple = StubTranscriptionProvider("apple")
        let controller = VoiceModeController(transcriptionProvider: cloud, fallback: apple)
        defer { controller.stop() }
        let started = expectation(description: "Capture")
        cloud.onStart = { started.fulfill() }
        controller.beginListening(keepText: false)
        await fulfillment(of: [started], timeout: 1)
        cloud.starts.last?(.audioGap("Recording interrupted; speech is missing"))
        XCTAssertEqual(controller.phase, .paused)
        XCTAssertTrue(apple.starts.isEmpty)
        XCTAssertTrue(controller.microphoneWarning?.contains("speech is missing") == true)
    }

    @MainActor
    func testExhaustedMidUtteranceCloudFailurePausesWithoutAppleAndIgnoresLateEvents() async throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip("Requires speech runtime") }
        let cloud = StubTranscriptionProvider("elevenlabs")
        let apple = StubTranscriptionProvider("apple")
        let controller = VoiceModeController(transcriptionProvider: cloud, fallback: apple)
        defer { controller.stop() }
        let cloudStarted = expectation(description: "Cloud capture")
        cloud.onStart = { cloudStarted.fulfill() }
        controller.beginListening(keepText: false)
        await fulfillment(of: [cloudStarted], timeout: 1)
        let oldCallback = try XCTUnwrap(cloud.starts.first)
        oldCallback(.committed("Please"))
        oldCallback(.partial("check the"))

        oldCallback(.error("OSStatus error -9820 - bad MAC"))
        XCTAssertFalse(controller.captureLive)
        XCTAssertEqual(controller.committedText, "Please check the")
        XCTAssertEqual(controller.partialText, "")
        XCTAssertEqual(controller.phase, .paused)
        XCTAssertNotNil(controller.microphoneWarning)

        // A closed socket may still deliver any of these after the replacement
        // is already listening. None may replace text or schedule another start.
        oldCallback(.partial("obsolete words"))
        oldCallback(.error("Socket is not connected"))
        oldCallback(.ended)
        XCTAssertEqual(controller.phase, .paused)
        XCTAssertEqual(controller.committedText, "Please check the")
        XCTAssertEqual(controller.partialText, "")
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(cloud.starts.count, 1)
        XCTAssertEqual(apple.starts.count, 0)
    }

    @MainActor
    func testUnavailableCloudAtStartupFallsBack() async throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip("Requires speech runtime") }
        let cloud = StubTranscriptionProvider("elevenlabs")
        cloud.startEventError = "ElevenLabs unavailable at startup"
        let apple = StubTranscriptionProvider("apple")
        let controller = VoiceModeController(transcriptionProvider: cloud, fallback: apple)
        defer { controller.stop() }
        let recovered = expectation(description: "Startup fallback")
        apple.onStart = { recovered.fulfill() }
        controller.beginListening(keepText: false)
        await fulfillment(of: [recovered], timeout: 4)
        XCTAssertEqual(controller.phase, .listening)
        XCTAssertEqual(cloud.starts.count, 1)
    }

    @MainActor
    func testRepeatedAppleStartupFailuresStopInsteadOfRetryingForever() async throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip("Requires speech runtime") }
        let apple = StubTranscriptionProvider("apple")
        apple.startError = NSError(domain: "Microphone", code: 1)
        let controller = VoiceModeController(transcriptionProvider: apple, fallback: apple)
        defer { controller.stop() }
        for attempt in 1...5 {
            let started = expectation(description: "Attempt \(attempt)")
            apple.onStart = { started.fulfill() }
            controller.beginListening(keepText: true)
            await fulfillment(of: [started], timeout: 1)
        }
        XCTAssertEqual(controller.phase, .inactive)
        XCTAssertFalse(controller.captureLive)
        try await Task.sleep(nanoseconds: 2_400_000_000)
        XCTAssertEqual(apple.starts.count, 5)
    }

    @MainActor
    func testMissingApplePrivacyDeclarationStopsFallbackWithWarning() async throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip("Requires speech runtime") }
        let cloud = StubTranscriptionProvider("elevenlabs")
        cloud.startEventError = "ElevenLabs unavailable at startup"
        let apple = StubTranscriptionProvider("apple")
        apple.startError = SpeechPrivacyRequirements.MissingUsageDescription(key: "NSSpeechRecognitionUsageDescription")
        let controller = VoiceModeController(transcriptionProvider: cloud, fallback: apple)
        defer { controller.stop() }
        let attempted = expectation(description: "Apple preflight")
        apple.onStart = { attempted.fulfill() }
        controller.beginListening(keepText: false)
        await fulfillment(of: [attempted], timeout: 4)
        XCTAssertEqual(controller.phase, .inactive)
        XCTAssertTrue(controller.microphoneWarning?.contains("continue by typing") == true)
        XCTAssertFalse(controller.captureLive)
        try await Task.sleep(nanoseconds: 2_400_000_000)
        XCTAssertEqual(apple.starts.count, 1)
    }

    @MainActor
    func testStoppedStartupCannotMarkNewAttemptLive() async throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip("Requires speech runtime") }
        let cloud = StubTranscriptionProvider("elevenlabs")
        cloud.suspendStartup = true
        let controller = VoiceModeController(transcriptionProvider: cloud, fallback: StubTranscriptionProvider("apple"))
        defer { controller.stop() }
        for attempt in 1...2 {
            let started = expectation(description: "Suspended capture \(attempt)")
            cloud.onStart = { started.fulfill() }
            controller.beginListening(keepText: false)
            await fulfillment(of: [started], timeout: 1)
            if attempt == 1 { controller.stop() }
        }
        XCTAssertFalse(controller.captureLive)
        cloud.pendingStarts.removeFirst().resume()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(controller.captureLive)
        cloud.starts[0](.error("Late failure"))
        XCTAssertEqual(controller.phase, .listening)
        cloud.pendingStarts.removeFirst().resume()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(controller.captureLive)
    }
}
