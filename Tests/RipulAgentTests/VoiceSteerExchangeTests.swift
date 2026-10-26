import XCTest
@testable import RipulAgent

/// A spoken message sent while the agent works steers the running task. The
/// agent's `answer: true` speech ends that exchange and reopens the mic while
/// the task carries on; the end of the task is handled as a turn ends today.
final class VoiceSteerExchangeTests: XCTestCase {
    func testOnlyTheAnswerToAMidTaskMessageEndsTheExchange() {
        var exchange = VoiceSteerExchange()
        exchange.sent(whileAgentRunning: false)
        XCTAssertFalse(exchange.agentSpoke(answer: true, agentRunning: true), "A message that started its own turn ends with the turn")

        exchange.sent(whileAgentRunning: true)
        XCTAssertFalse(exchange.agentSpoke(answer: false, agentRunning: true), "A progress note is not the answer")
        XCTAssertTrue(exchange.awaitingAnswer)
        XCTAssertTrue(exchange.agentSpoke(answer: true, agentRunning: true))
        XCTAssertTrue(exchange.listeningMidTask)
        XCTAssertFalse(exchange.agentSpoke(answer: true, agentRunning: true), "Only one answer per message")

        XCTAssertTrue(exchange.taskEnded())
        XCTAssertEqual(exchange, VoiceSteerExchange())
    }

    func testAnswerAfterTheTaskEndedDoesNotListenMidTask() {
        var exchange = VoiceSteerExchange()
        exchange.sent(whileAgentRunning: true)
        XCTAssertTrue(exchange.agentSpoke(answer: true, agentRunning: false))
        XCTAssertFalse(exchange.listeningMidTask)
        XCTAssertFalse(exchange.taskEnded())
    }

    @MainActor
    func testSpokenSteersReopenTheMicWhileTheTaskRunsAndTheTaskEndsAsBefore() async throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip() }
        let mic = SteerStubTranscription()
        var submitted: [String] = []
        let controller = VoiceModeController(transcriptionProvider: mic, fallback: SteerStubTranscription(),
            submit: { submitted.append($0); return true })
        defer { controller.stop() }
        var running = true
        controller.agentRunningProbe = { running }
        controller.handleRunningChange(true)

        for (index, words) in ["What is three times three", "And four times four"].enumerated() {
            try await speak(words, into: controller, mic: mic)
            try await waitFor { controller.phase == .thinking }
            XCTAssertEqual(submitted.count, index + 1)
            XCTAssertTrue(controller.steer.awaitingAnswer)

            controller.handleAgentSpeech("Still on the file counts.", answer: false)
            try await Task.sleep(nanoseconds: 300_000_000)
            XCTAssertEqual(controller.phase, .thinking, "A progress note keeps the mic shut")

            controller.handleAgentSpeech("Nine.", answer: true)
            try await waitFor { controller.phase == .listening }
            XCTAssertTrue(controller.steer.listeningMidTask, "The mic reopened while the task runs")
        }

        // The task ends while the user is quiet: handled as a turn ends today
        // (no agent speech since the mic reopened, no reply text here).
        running = false
        controller.handleRunningChange(false)
        XCTAssertNotEqual(controller.phase, .listening)
        XCTAssertFalse(controller.steer.listeningMidTask)
        try await waitFor(seconds: 6) { if case .notice = controller.phase { return true } else { return false } }
    }

    @MainActor
    func testAgentSpeechMidTaskWaitsForTheUsersSentence() async throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip() }
        let mic = SteerStubTranscription()
        let controller = VoiceModeController(transcriptionProvider: mic, fallback: SteerStubTranscription(),
            submit: { _ in true })
        defer { controller.stop() }
        controller.agentRunningProbe = { true }
        controller.handleRunningChange(true)
        try await speak("What is three times three", into: controller, mic: mic)
        try await waitFor { controller.phase == .thinking }
        controller.handleAgentSpeech("Nine.", answer: true)
        try await waitFor { controller.phase == .listening }

        // Quiet mic: the agent's next words close it while they play.
        controller.handleAgentSpeech("Two folders left.", answer: false)
        XCTAssertEqual(controller.phase, .thinking)
        try await waitFor { controller.phase == .listening }

        // Mid-sentence: the agent waits, and so does the end of the task.
        mic.starts.last?(.partial("And what about"))
        controller.handleAgentSpeech("One folder left.", answer: false)
        XCTAssertEqual(controller.phase, .listening)
        controller.handleRunningChange(false)
        XCTAssertEqual(controller.phase, .listening)
    }

    @MainActor
    func testMessageThatStartsItsOwnTurnKeepsTheMicShutUntilTheTurnEnds() async throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip() }
        let mic = SteerStubTranscription()
        let controller = VoiceModeController(transcriptionProvider: mic, fallback: SteerStubTranscription(),
            submit: { _ in true })
        defer { controller.stop() }
        controller.agentRunningProbe = { false }
        try await speak("What is three times three", into: controller, mic: mic)
        try await waitFor { controller.phase == .thinking }
        controller.handleAgentSpeech("Nine.", answer: true)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(controller.phase, .thinking)
    }

    @available(iOS 26.0, macOS 26.0, *)
    @MainActor
    private func speak(_ words: String, into controller: VoiceModeController, mic: SteerStubTranscription) async throws {
        if controller.phase != .listening { controller.beginListening(keepText: false) }
        try await waitFor { !mic.starts.isEmpty && controller.phase == .listening }
        let callback = try XCTUnwrap(mic.starts.last)
        callback(.connectionReady)
        callback(.committed(words))
        controller.sendNow()
    }

    @MainActor
    private func waitFor(seconds: Double = 2, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

@available(iOS 26.0, macOS 26.0, *)
@MainActor
private final class SteerStubTranscription: BufferedConversationSpeechProviding {
    let id = "stub"
    var label: String { id }
    var starts: [(@MainActor (SpeechService.TranscriptionEvent) -> Void)] = []
    var bufferedConversationTranscription = true
    func finishBufferedTranscription() async throws {}
    func listVoices() async throws -> [SpeechService.Voice] { [] }
    func speak(text: String, voiceId: String?, onPlaybackEnd: (@MainActor () -> Void)?) async throws {}
    func stopSpeaking() {}
    func pauseSpeaking() {}
    func resumeSpeaking() {}
    func startTranscription(onEvent: @escaping @MainActor (SpeechService.TranscriptionEvent) -> Void) async throws {
        starts.append(onEvent)
    }
    func stopTranscription() { starts.last?(.ended) }
}
