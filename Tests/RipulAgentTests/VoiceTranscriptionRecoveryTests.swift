import XCTest
@testable import RipulAgent

@available(iOS 26.0, macOS 26.0, *)
@MainActor
private final class StubTranscriptionProvider: NativeSpeechProviding {
    let id: String
    var label: String { id }
    var starts: [(@MainActor (SpeechService.TranscriptionEvent) -> Void)] = []
    var startError: Error?
    var onStart: (() -> Void)?
    var suspendStartup = false
    var pendingStarts: [CheckedContinuation<Void, Never>] = []

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
    }
    func stopTranscription() { starts.last?(.ended) }
}

final class VoiceTranscriptionRecoveryTests: XCTestCase {
    @MainActor
    func testMidUtteranceCloudFailureKeepsWordsAndIgnoresLateCloudEvents() async throws {
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

        let appleStarted = expectation(description: "Apple recovery")
        apple.onStart = { appleStarted.fulfill() }
        oldCallback(.error("OSStatus error -9820 - bad MAC"))
        XCTAssertFalse(controller.captureLive)
        XCTAssertEqual(controller.committedText, "Please check the")
        XCTAssertEqual(controller.partialText, "")
        await fulfillment(of: [appleStarted], timeout: 4)

        // A closed socket may still deliver any of these after the replacement
        // is already listening. None may replace text or schedule another start.
        oldCallback(.partial("obsolete words"))
        oldCallback(.error("Socket is not connected"))
        oldCallback(.ended)
        apple.starts.last?(.partial("logs"))
        XCTAssertEqual(controller.phase, .listening)
        XCTAssertEqual(controller.committedText, "Please check the")
        XCTAssertEqual(controller.partialText, "logs")
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(cloud.starts.count, 1)
        XCTAssertEqual(apple.starts.count, 1)
    }

    @MainActor
    func testThrownCloudStartupFailureAlsoFallsBack() async throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip("Requires speech runtime") }
        let cloud = StubTranscriptionProvider("elevenlabs")
        cloud.startError = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
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
        cloud.startError = NSError(domain: NSURLErrorDomain, code: NSURLErrorSecureConnectionFailed)
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
