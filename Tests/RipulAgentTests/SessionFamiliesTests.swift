import XCTest
@testable import RipulAgent

final class SessionFamiliesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_630_000)

    /// A chat as the host's list gives it. `startedBy` names the starter the way the host does.
    private func chat(_ name: String, minutesAgo: Double, startedBy starter: String? = nil,
                      machine: String? = "mac", rowKnown: Bool = true,
                      folder: String? = nil, branch: String? = nil) -> UnifiedSession {
        UnifiedSession(
            id: "claude-cli:\(name)", title: name, lastUsed: now.addingTimeInterval(-minutesAgo * 60),
            gitBranch: branch, messageCount: nil, projectName: folder, provider: "claude-cli", providerLabel: nil,
            machineName: machine, machineId: machine, matchKeys: ["claude-cli:\(name)", name, "cli_\(name)"],
            startedBy: starter.map { SessionStartedBy(agentId: "cli_\($0)", sessionId: rowKnown ? "claude-cli:\($0)" : nil, title: $0) },
            ripulSession: nil)
    }

    private func arrange(_ sessions: [UnifiedSession], open: Set<String> = [], closed: Set<String> = [], folds: Bool = true,
                         pinned: Set<String> = [], working: Set<String> = []) -> SessionFamilies {
        SessionFamilies.arrange(sessions, open: open, closed: closed, folds: folds,
                                isPinned: { pinned.contains($0.title) },
                                recency: { Int($0.lastUsed.timeIntervalSince1970 / 30) },
                                mustShow: { working.contains($0.title) })
    }

    func testChatsNobodyStartedKeepTheListsOwnOrder() {
        let layout = arrange([chat("old", minutesAgo: 90), chat("new", minutesAgo: 1), chat("pinned", minutesAgo: 300)], pinned: ["pinned"])
        XCTAssertEqual(layout.visible.map(\.title), ["pinned", "new", "old"])
        XCTAssertEqual(layout.all, layout.visible)
        XCTAssertTrue(layout.depth.isEmpty)
        XCTAssertTrue(layout.folds.isEmpty)
    }

    func testStartedChatsSitUnderTheirStarterAndTheFamilyMovesAsOne() {
        // The starter last spoke two hours ago; a chat it started is working now.
        let layout = arrange([
            chat("between", minutesAgo: 30),
            chat("design", minutesAgo: 120),
            chat("panels", minutesAgo: 1, startedBy: "design"),
            chat("tokens", minutesAgo: 45, startedBy: "design"),
            chat("yesterday", minutesAgo: 1500),
        ])
        XCTAssertEqual(layout.visible.map(\.title), ["design", "panels", "tokens", "between", "yesterday"])
        XCTAssertEqual(layout.depth, ["claude-cli:panels": 1, "claude-cli:tokens": 1])
    }

    func testAChatStartedByAStartedChatGoesOneFurtherInAndNoDeeper() {
        let layout = arrange([
            chat("a", minutesAgo: 50), chat("b", minutesAgo: 40, startedBy: "a"),
            chat("c", minutesAgo: 30, startedBy: "b"), chat("d", minutesAgo: 20, startedBy: "c"),
        ])
        XCTAssertEqual(layout.visible.map(\.title), ["a", "b", "c", "d"])
        XCTAssertEqual(layout.depth, ["claude-cli:b": 1, "claude-cli:c": 2, "claude-cli:d": 2])
    }

    func testQuietStartedChatsBeyondThreeFoldBehindOneControl() {
        var sessions = [chat("lead", minutesAgo: 100)]
        for index in 1...6 { sessions.append(chat("task\(index)", minutesAgo: Double(index), startedBy: "lead")) }
        let closed = arrange(sessions)
        XCTAssertEqual(closed.visible.map(\.title), ["lead", "task1", "task2", "task3"])
        XCTAssertEqual(closed.all.count, 7, "A folded chat is still in the list, for what is told to Siri and for selection")
        XCTAssertEqual(closed.folds, ["claude-cli:task3": .init(parentId: "claude-cli:lead", count: 3, isOpen: false)])

        let open = arrange(sessions, open: ["claude-cli:lead"])
        XCTAssertEqual(open.visible.count, 7)
        XCTAssertEqual(open.folds, ["claude-cli:task6": .init(parentId: "claude-cli:lead", count: 3, isOpen: true)])

        // A search may match a folded chat, so a search shows every row and no control.
        let searching = arrange(sessions, folds: false)
        XCTAssertEqual(searching.visible.count, 7)
        XCTAssertTrue(searching.folds.isEmpty)
    }

    func testAChatThatIsWorkingIsNeverFoldedAway() {
        var sessions = [chat("lead", minutesAgo: 100)]
        for index in 1...7 { sessions.append(chat("task\(index)", minutesAgo: Double(index), startedBy: "lead")) }
        let layout = arrange(sessions, working: ["task6", "task7"])
        XCTAssertEqual(layout.visible.map(\.title), ["lead", "task1", "task2", "task3", "task6", "task7"])
        XCTAssertEqual(layout.folds.values.first, .init(parentId: "claude-cli:lead", count: 2, isOpen: false))
        XCTAssertEqual(layout.folds.keys.first, "claude-cli:task7", "The control follows the family's last row")
    }

    func testAHeadCanPutItsStartedChatsAwayAndSaysHowMany() {
        let sessions = [
            chat("lead", minutesAgo: 100), chat("a", minutesAgo: 1, startedBy: "lead"), chat("b", minutesAgo: 2, startedBy: "lead"),
            chat("under a", minutesAgo: 3, startedBy: "a"), chat("other", minutesAgo: 50),
        ]
        let shown = arrange(sessions)
        XCTAssertEqual(shown.heads, ["claude-cli:lead": .init(started: 3, isClosed: false, needsLooking: false)], "Only the chat at the head of a family is a head")

        let closed = arrange(sessions, closed: ["claude-cli:lead"], working: ["under a"])
        XCTAssertEqual(closed.visible.map(\.title), ["lead", "other"], "The family keeps its place with its chats put away")
        XCTAssertEqual(closed.all.count, 5, "Put away is not gone: the host is still told of them")
        XCTAssertEqual(closed.heads["claude-cli:lead"], .init(started: 3, isClosed: true, needsLooking: true), "A working chat out of sight is flagged on the head")
        XCTAssertTrue(closed.folds.isEmpty)
        XCTAssertFalse(arrange(sessions, closed: ["claude-cli:lead"]).heads["claude-cli:lead"]!.needsLooking)

        // A search shows every match, whatever was put away.
        XCTAssertEqual(arrange(sessions, closed: ["claude-cli:lead"], folds: false).visible.count, 5)
    }

    func testAStartedChatSaysWhereItWorksOnlyWhenThatDiffersFromTheChatAboveIt() {
        let layout = arrange([
            chat("lead", minutesAgo: 9, folder: "ripul", branch: "main"),
            chat("same", minutesAgo: 1, startedBy: "lead", folder: "ripul", branch: "main"),
            chat("branched", minutesAgo: 2, startedBy: "lead", folder: "ripul", branch: "theme"),
            chat("elsewhere", minutesAgo: 3, startedBy: "lead", folder: "website", branch: "main"),
            chat("under branched", minutesAgo: 4, startedBy: "branched", folder: "ripul", branch: "theme"),
            chat("alone", minutesAgo: 5, folder: "ripul", branch: "main"),
        ])
        XCTAssertEqual(layout.sharesFolder, ["claude-cli:same", "claude-cli:branched", "claude-cli:under branched"])
        XCTAssertEqual(layout.sharesBranch, ["claude-cli:same", "claude-cli:under branched"],
                       "main in another folder is another branch; a chat is compared with the one it sits under, not the head")
    }

    func testOneChatBeyondTheLimitIsShownRatherThanFolded() {
        var sessions = [chat("lead", minutesAgo: 100)]
        for index in 1...4 { sessions.append(chat("task\(index)", minutesAgo: Double(index), startedBy: "lead")) }
        let layout = arrange(sessions)
        XCTAssertEqual(layout.visible.count, 5, "A control that hides one row saves nothing")
        XCTAssertTrue(layout.folds.isEmpty)
    }

    func testAStartedChatWhoseStarterIsNotListedStandsByItself() {
        let layout = arrange([chat("orphan", minutesAgo: 5, startedBy: "archived"), chat("other", minutesAgo: 1)])
        XCTAssertEqual(layout.visible.map(\.title), ["other", "orphan"])
        XCTAssertTrue(layout.depth.isEmpty)
        XCTAssertEqual(layout.visible[1].startedBy?.title, "archived", "The row can still say who started it")
    }

    func testAnIdFromOneMacIsNotMatchedOnAnother() {
        let layout = arrange([chat("design", minutesAgo: 10, machine: "studio"), chat("panels", minutesAgo: 1, startedBy: "design", machine: "macbook")])
        XCTAssertEqual(layout.visible.map(\.title), ["panels", "design"])
        XCTAssertTrue(layout.depth.isEmpty)
    }

    func testTheStarterIsFoundByItsChatIdWhenTheHostCouldNotNameItsRow() {
        let layout = arrange([chat("panels", minutesAgo: 1, startedBy: "design", rowKnown: false), chat("design", minutesAgo: 10)])
        XCTAssertEqual(layout.visible.map(\.title), ["design", "panels"])
        XCTAssertEqual(layout.depth, ["claude-cli:panels": 1])
    }

    func testChatsNamingEachOtherAreStillAllShownOnce() {
        let layout = arrange([chat("a", minutesAgo: 2, startedBy: "b"), chat("b", minutesAgo: 1, startedBy: "a"), chat("self", minutesAgo: 3, startedBy: "self")])
        XCTAssertEqual(Set(layout.visible.map(\.title)), ["a", "b", "self"])
        XCTAssertEqual(layout.visible.count, 3)
    }

    func testWhoStartedAChatSurvivesTheCacheAndAScanThatCouldNotSay() throws {
        let started = chat("panels", minutesAgo: 1, startedBy: "design")
        let decoded = try JSONDecoder().decode(UnifiedSession.self, from: JSONEncoder().encode(started))
        XCTAssertEqual(decoded.startedBy, started.startedBy)
        // A row cached before the field existed decodes as a chat nobody started.
        let old = try JSONDecoder().decode(UnifiedSession.self, from: Data(#"{"id":"x","title":"Old","lastUsed":0}"#.utf8))
        XCTAssertNil(old.startedBy)
        let rescanned = chat("panels", minutesAgo: 0).coalescing(over: started)
        XCTAssertEqual(rescanned.startedBy?.agentId, "cli_design")
        XCTAssertNotEqual(chat("panels", minutesAgo: 1), started, "A change of starter must redraw the list")
        XCTAssertEqual(started.withModel("claude-opus").startedBy, started.startedBy)
        XCTAssertNil(SessionStartedBy(wire: ["title": "No id"]))
        XCTAssertEqual(SessionStartedBy(wire: ["agentId": "cli_design", "sessionId": "claude-cli:design", "title": "Design"]),
                       SessionStartedBy(agentId: "cli_design", sessionId: "claude-cli:design", title: "Design"))
    }
}
