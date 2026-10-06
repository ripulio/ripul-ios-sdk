import XCTest
@testable import RipulAgent

/// What two pushes from the web app do to a chat on the native side: a status
/// push ("is the agent running?") and an activity event ("what is it doing?").
/// Driven the way the app drives them, by messages arriving on the bridge.
@MainActor
final class AgentTurnPushTests: XCTestCase {
    private func bridge(synced: Bool = true) -> AgentBridge {
        let bridge = AgentBridge()
        bridge.sessionCache = UserDefaultsSessionCache(suiteName: "io.ripul.tests.turnpush.\(UUID().uuidString)")
        bridge.initialStatusSyncComplete = synced
        return bridge
    }

    private func status(_ bridge: AgentBridge, chat: String?, running: Bool = false, paused: Bool = false) {
        var message: [String: Any] = ["type": "agent-framework:agent:status", "isRunning": running, "isPaused": paused]
        if let chat { message["chatId"] = chat }
        bridge.handleMessage(message)
    }

    /// A turn event carrying a sequence: this is what gives a chat lifecycle history.
    private func turn(_ bridge: AgentBridge, _ kind: String, chat: String, sequence: Int) {
        bridge.handleMessage(["type": "agent-framework:agent:turn\(kind)", "chatId": chat, "sequence": sequence])
    }

    private func activity(_ bridge: AgentBridge, chat: String?, _ event: [String: Any], at: Date? = nil) {
        var message: [String: Any] = ["type": "agent-framework:agent:activity", "event": event]
        if let chat { message["chatId"] = chat }
        if let at { message["timestamp"] = at.timeIntervalSince1970 * 1000 }
        bridge.handleMessage(message)
    }

    private func tool(_ kind: String, _ name: String, extra: [String: Any] = [:]) -> [String: Any] {
        ["kind": kind, "toolName": name, "toolId": "t-1"].merging(extra) { _, new in new }
    }

    // MARK: - A status push

    func testAStatusPushBeforeTheFirstSyncIsIgnored() {
        let bridge = bridge(synced: false)
        status(bridge, chat: "a", running: true)
        XCTAssertNil(bridge.chatTurnPhases["a"], "The pull after connection is the authority, not a push during start-up")
    }

    func testAStatusPushThatNamesNoChatIsIgnored() {
        let bridge = bridge()
        status(bridge, chat: nil, running: true)
        status(bridge, chat: "", running: true)
        XCTAssertTrue(bridge.chatTurnPhases.isEmpty)
    }

    func testAStatusPushSetsRunningOrWaitingForAChatKnownOnlyByStatus() {
        let bridge = bridge()
        status(bridge, chat: "a", running: true)
        XCTAssertEqual(bridge.chatTurnPhases["a"], .running)
        status(bridge, chat: "b", running: true, paused: true)
        XCTAssertEqual(bridge.chatTurnPhases["b"], .awaitingInput)
        status(bridge, chat: "c", paused: true)
        XCTAssertEqual(bridge.chatTurnPhases["c"], .awaitingInput, "Paused wins whatever running says")
    }

    func testAStatusPushIsAboutTheChatItNamesAndNoOther() {
        let bridge = bridge()
        status(bridge, chat: "a", running: true)
        status(bridge, chat: "b", running: true, paused: true)
        XCTAssertEqual(bridge.chatTurnPhases, ["a": .running, "b": .awaitingInput])
    }

    /// A not-running push can be transiently wrong mid-turn (the question
    /// prompt pushes it while a tool waits on the user), so it never clears
    /// a live chat by itself: the web's lifecycle snapshot is pulled instead.
    func testANotRunningPushDoesNotClearALiveChat() {
        let bridge = bridge()
        status(bridge, chat: "a", running: true)
        status(bridge, chat: "a")
        XCTAssertEqual(bridge.chatTurnPhases["a"], .running)
        status(bridge, chat: "b", paused: true)
        status(bridge, chat: "b")
        XCTAssertEqual(bridge.chatTurnPhases["b"], .awaitingInput)
    }

    func testANotRunningPushForAChatThatIsNotLiveChangesNothing() {
        let bridge = bridge()
        status(bridge, chat: "a")
        XCTAssertNil(bridge.chatTurnPhases["a"])
        turn(bridge, "Completed", chat: "b", sequence: 4)
        status(bridge, chat: "b")
        XCTAssertEqual(bridge.chatTurnPhases["b"], .completed)
    }

    /// Once a chat has turn events, they are the truth: a status push never
    /// writes its phase, whichever way it disagrees.
    func testAStatusPushNeverWritesThePhaseOfAChatWithTurnEvents() {
        let bridge = bridge()
        turn(bridge, "Started", chat: "a", sequence: 1)
        status(bridge, chat: "a")
        XCTAssertEqual(bridge.chatTurnPhases["a"], .running, "Disagrees: pulled, not cleared")
        status(bridge, chat: "a", running: true, paused: true)
        XCTAssertEqual(bridge.chatTurnPhases["a"], .running, "Disagrees: pulled, not set to waiting")

        turn(bridge, "Completed", chat: "a", sequence: 2)
        status(bridge, chat: "a", running: true)
        XCTAssertEqual(bridge.chatTurnPhases["a"], .completed, "A running push does not restart a finished turn")
    }

    // MARK: - An activity event

    func testAnActivityEventIsTheLatestActivityWhateverChatItIsFor() {
        let bridge = bridge()
        activity(bridge, chat: nil, ["kind": "thinking"])
        XCTAssertEqual(bridge.latestActivity, .thinking)
        XCTAssertTrue(bridge.sessionList.latestActivityByChatId.isEmpty, "No chat named: nothing is filed per chat")
    }

    func testAnEventThatCannotBeReadChangesNothing() {
        let bridge = bridge()
        activity(bridge, chat: "a", ["kind": "thinking"])
        activity(bridge, chat: "a", ["kind": "juggling"])
        activity(bridge, chat: "a", ["toolName": "Read"])
        bridge.handleMessage(["type": "agent-framework:agent:activity", "chatId": "a"])
        XCTAssertEqual(bridge.latestActivity, .thinking)
        XCTAssertEqual(bridge.sessionList.latestActivityByChatId["a"], .thinking)
    }

    /// The Claude CLI reports a tool as one `toolEnd` and never a `toolStart`,
    /// so both are latched as the row's subtitle.
    func testAToolEventBecomesTheChatsSubtitleStartOrEnd() {
        let bridge = bridge()
        activity(bridge, chat: "a", tool("toolStart", "Read"))
        XCTAssertEqual(bridge.sessionList.latestActivityByChatId["a"],
                       .toolStart(toolName: "Read", toolId: "t-1", toolLabel: nil, toolDetail: nil))
        activity(bridge, chat: "a", tool("toolEnd", "Bash", extra: ["status": "error"]))
        XCTAssertEqual(bridge.sessionList.latestActivityByChatId["a"],
                       .toolEnd(toolName: "Bash", toolId: "t-1", status: "error", toolLabel: nil, toolDetail: nil))
    }

    /// A replayed event carries its original time. Latching it would show a
    /// live subtitle for a turn that finished while the app was closed.
    func testAReplayedEventDoesNotBecomeTheSubtitle() {
        let bridge = bridge()
        activity(bridge, chat: "a", tool("toolStart", "Read"), at: Date().addingTimeInterval(-120))
        XCTAssertNil(bridge.sessionList.latestActivityByChatId["a"])
        activity(bridge, chat: "a", tool("toolStart", "Read"), at: Date().addingTimeInterval(-30))
        XCTAssertNotNil(bridge.sessionList.latestActivityByChatId["a"], "Under a minute old is live")
        activity(bridge, chat: "b", tool("toolStart", "Read"))
        XCTAssertNotNil(bridge.sessionList.latestActivityByChatId["b"], "No timestamp is treated as live")
    }

    func testACompletionOrATodoWriteClearsTheSubtitle() {
        let bridge = bridge()
        for clearing in ["completion", "TodoWrite"] {
            activity(bridge, chat: "a", tool("toolStart", "Read"))
            XCTAssertNotNil(bridge.sessionList.latestActivityByChatId["a"])
            activity(bridge, chat: "a", tool("toolEnd", clearing))
            XCTAssertNil(bridge.sessionList.latestActivityByChatId["a"], "\(clearing) clears it")
        }
        activity(bridge, chat: "a", tool("toolStart", "Read"))
        activity(bridge, chat: "a", tool("toolStart", "completion"), at: Date().addingTimeInterval(-600))
        XCTAssertNil(bridge.sessionList.latestActivityByChatId["a"], "Cleared even by a replayed completion")
    }

    /// Row actions persist across turns: they are kept apart from the tool
    /// subtitle and neither replaces the other.
    func testSessionActionsAreFiledApartFromTheSubtitle() {
        let bridge = bridge()
        activity(bridge, chat: "a", tool("toolStart", "Read"))
        activity(bridge, chat: "a", ["kind": "sessionAction", "actions": [["id": "open-pr", "label": "Open PR"]]])
        XCTAssertEqual(bridge.sessionList.sessionActionsByChatId["a"]?.map(\.id), ["open-pr"])
        XCTAssertEqual(bridge.sessionList.latestActivityByChatId["a"],
                       .toolStart(toolName: "Read", toolId: "t-1", toolLabel: nil, toolDetail: nil))
        activity(bridge, chat: "a", ["kind": "sessionAction", "actions": [[String: Any]]()])
        XCTAssertEqual(bridge.sessionList.sessionActionsByChatId["a"]?.map(\.id), ["open-pr"], "An empty list is not an event")
    }

    func testAnEditRecordsItsFileAsRecentlyEdited() {
        let bridge = bridge()
        bridge.sessionList.recentlyEditedFiles = []
        activity(bridge, chat: "a", tool("toolEnd", "Edit", extra: ["toolFilePath": "/repo/a.swift"]))
        activity(bridge, chat: "a", tool("toolEnd", "Read", extra: ["toolFilePath": "/repo/b.swift"]))
        activity(bridge, chat: "a", tool("toolEnd", "Edit", extra: ["toolFilePath": ""]))
        activity(bridge, chat: nil, tool("toolEnd", "Edit", extra: ["toolFilePath": "/repo/c.swift"]))
        XCTAssertEqual(bridge.sessionList.recentlyEditedFiles, ["/repo/c.swift", "/repo/a.swift"],
                       "Edits only, newest first, with or without a chat")
    }

    func testTheAgentsWordsAreKeptPerChatTrimmed() {
        let bridge = bridge()
        activity(bridge, chat: "a", ["kind": "response", "preview": "  The answer.\n"])
        XCTAssertEqual(bridge.lastResponsePreviewByChatId["a"], "The answer.")
        activity(bridge, chat: "a", ["kind": "response", "preview": "   "])
        XCTAssertEqual(bridge.lastResponsePreviewByChatId["a"], "The answer.", "Blank words do not replace real ones")
        activity(bridge, chat: nil, ["kind": "response", "preview": "For nobody."])
        XCTAssertEqual(bridge.lastResponsePreviewByChatId.count, 1)
    }

    func testAnActivityEventStampsWhenTheChatWasLastActive() {
        let bridge = bridge()
        let then = Date(timeIntervalSince1970: 1_700_000_000)
        activity(bridge, chat: "a", ["kind": "thinking"], at: then)
        XCTAssertEqual(bridge.sessionList.lastActiveTimeByChatId["a"], then)
    }
}
