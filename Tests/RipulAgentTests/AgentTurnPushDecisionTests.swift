import XCTest
@testable import RipulAgent

/// The two decisions on their own: no bridge, no web view.
final class AgentTurnPushDecisionTests: XCTestCase {
    private let phases: [AgentTurnPhase?] = [nil, .idle, .running, .awaitingInput, .completed, .failed]

    // MARK: - A status push

    private func status(running: Bool = false, paused: Bool = false, current: AgentTurnPhase?, events: Bool) -> StatusPushDecision {
        StatusPushDecision.decide(running: running, paused: paused, current: current, hasTurnEvents: events)
    }

    func testAChatKnownOnlyByStatusBelievesRunningAndPaused() {
        for current in phases {
            XCTAssertEqual(status(running: true, current: current, events: false), .apply(.running))
            XCTAssertEqual(status(running: true, paused: true, current: current, events: false), .apply(.awaitingInput))
            XCTAssertEqual(status(paused: true, current: current, events: false), .apply(.awaitingInput), "Paused wins")
        }
    }

    func testAChatKnownOnlyByStatusPullsWhenALiveTurnIsSaidNotToBeRunning() {
        XCTAssertEqual(status(current: .running, events: false), .pull(.liveChatSaidNotRunning))
        XCTAssertEqual(status(current: .awaitingInput, events: false), .pull(.liveChatSaidNotRunning))
        for current in [nil, .idle, .completed, .failed] as [AgentTurnPhase?] {
            XCTAssertEqual(status(current: current, events: false), .leave, "Nothing live to defend")
        }
    }

    func testAChatWithTurnEventsIsNeverWrittenByAPush() {
        for current in phases {
            for running in [true, false] {
                for paused in [true, false] {
                    if case .apply = status(running: running, paused: paused, current: current, events: true) {
                        XCTFail("applied running=\(running) paused=\(paused) over \(String(describing: current))")
                    }
                }
            }
        }
    }

    func testAChatWithTurnEventsPullsOnlyWhenThePushDisagrees() {
        // Says not running while the events say running.
        XCTAssertEqual(status(current: .running, events: true), .pull(.disagreesWithTurnEvents))
        // Says paused while the events say anything but waiting.
        for current in [nil, .idle, .running, .completed, .failed] as [AgentTurnPhase?] {
            XCTAssertEqual(status(running: true, paused: true, current: current, events: true), .pull(.disagreesWithTurnEvents))
        }
        // Agrees, or says something the events do not contradict.
        XCTAssertEqual(status(running: true, current: .running, events: true), .leave)
        XCTAssertEqual(status(running: true, paused: true, current: .awaitingInput, events: true), .leave)
        XCTAssertEqual(status(current: .awaitingInput, events: true), .leave, "Not running, but waiting: the events stand")
        XCTAssertEqual(status(current: .completed, events: true), .leave)
        XCTAssertEqual(status(running: true, current: .completed, events: true), .leave, "A running push does not restart a finished turn")
    }

    // MARK: - An activity event's subtitle

    private func subtitle(_ event: AgentActivityEvent, fresh: Bool = true, running: Bool = false) -> ActivitySubtitleDecision {
        ActivitySubtitleDecision.decide(event: event, isFresh: fresh, isAgentRunning: running)
    }

    private func start(_ name: String) -> AgentActivityEvent {
        .toolStart(toolName: name, toolId: "t", toolLabel: nil, toolDetail: nil)
    }

    private func end(_ name: String) -> AgentActivityEvent {
        .toolEnd(toolName: name, toolId: "t", status: "success", toolLabel: nil, toolDetail: nil)
    }

    func testAFreshEventLatchesAndAReplayDoesNot() {
        for event in [start("Read"), end("Read"), .thinking, .response(preview: "hi"), .error(message: "x"), .complete] {
            XCTAssertEqual(subtitle(event), .latch)
            XCTAssertEqual(subtitle(event, fresh: false), .leave)
        }
    }

    func testACompletionClearsAndPullsOnlyWhileTheAgentIsShownRunning() {
        for event in [start("completion"), end("completion")] {
            XCTAssertEqual(subtitle(event, running: true), .clear(pullStatus: true))
            XCTAssertEqual(subtitle(event, running: false), .clear(pullStatus: false))
            XCTAssertEqual(subtitle(event, fresh: false, running: true), .clear(pullStatus: true), "Even a replayed one clears")
        }
    }

    func testATodoWriteClearsAndNeverPulls() {
        XCTAssertEqual(subtitle(end("TodoWrite"), running: true), .clear(pullStatus: false))
        XCTAssertEqual(subtitle(start("TodoWrite"), fresh: false), .clear(pullStatus: false))
    }

    func testSessionActionsAreStoredWhateverElseIsTrue() {
        let actions = [SessionRowAction.from(dict: ["id": "open-pr", "label": "Open PR"])!]
        XCTAssertEqual(subtitle(.sessionAction(actions: actions)), .storeSessionActions(actions))
        XCTAssertEqual(subtitle(.sessionAction(actions: actions), fresh: false, running: true), .storeSessionActions(actions))
    }
}
