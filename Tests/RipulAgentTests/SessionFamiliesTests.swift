import XCTest
@testable import RipulAgent

final class SessionFamiliesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_630_000)

    /// A chat as the host's list gives it. `startedBy` names the starter the way the host does.
    /// - Parameter starterMachine: The starter is on another Mac, so this chat's Mac names it with that Mac's id in front.
    private func chat(_ name: String, minutesAgo: Double, startedBy starter: String? = nil,
                      machine: String? = "mac", rowKnown: Bool = true,
                      folder: String? = nil, branch: String? = nil, starterOn starterMachine: String? = nil) -> UnifiedSession {
        UnifiedSession(
            id: "claude-cli:\(name)", title: name, lastUsed: now.addingTimeInterval(-minutesAgo * 60),
            gitBranch: branch, messageCount: nil, projectName: folder, provider: "claude-cli", providerLabel: nil,
            machineName: machine, machineId: machine, matchKeys: ["claude-cli:\(name)", name, "cli_\(name)"],
            startedBy: starter.map {
                // A Mac has no row for a chat on another Mac, so it can only give the id.
                if let starterMachine { return SessionStartedBy(agentId: "\(starterMachine)/cli_\($0)", sessionId: nil, title: $0) }
                return SessionStartedBy(agentId: "cli_\($0)", sessionId: rowKnown ? "claude-cli:\($0)" : nil, title: $0)
            },
            ripulSession: nil)
    }

    /// - Parameter placed: Where the person has put chats: a chat's name to the name of the chat it is under, or "" for by itself.
    private func arrange(_ sessions: [UnifiedSession], open: Set<String> = [], closed: Set<String> = [], folds: Bool = true,
                         pinned: Set<String> = [], working: Set<String> = [], placed: [String: String] = [:]) -> SessionFamilies {
        SessionFamilies.arrange(sessions, open: open, closed: closed, folds: folds,
                                isPinned: { pinned.contains($0.title) },
                                recency: { Int($0.lastUsed.timeIntervalSince1970 / 30) },
                                mustShow: { working.contains($0.title) },
                                placedUnder: { placed[$0.title] })
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

    func testAQuietChatWithAWorkingChatUnderItIsNotFoldedAway() {
        var sessions = [chat("lead", minutesAgo: 100)]
        for index in 1...7 { sessions.append(chat("task\(index)", minutesAgo: Double(index), startedBy: "lead")) }
        // The sixth is quiet and past the three that are shown, and a chat it started is mid-turn.
        sessions.append(chat("deep", minutesAgo: 60, startedBy: "task6"))
        let layout = arrange(sessions, working: ["deep"])
        XCTAssertEqual(layout.visible.map(\.title), ["lead", "task1", "task2", "task3", "task6", "deep"],
                       "Folding the sixth away would take the working chat under it out of sight")
        XCTAssertEqual(layout.folds, ["claude-cli:deep": .init(parentId: "claude-cli:lead", count: 3, isOpen: false)])
    }

    func testAHeadCanPutItsStartedChatsAwayAndSaysHowMany() {
        let sessions = [
            chat("lead", minutesAgo: 100), chat("a", minutesAgo: 1, startedBy: "lead"), chat("b", minutesAgo: 2, startedBy: "lead"),
            chat("under a", minutesAgo: 3, startedBy: "a"), chat("other", minutesAgo: 50),
        ]
        let shown = arrange(sessions)
        XCTAssertEqual(shown.heads, ["claude-cli:lead": .init(started: 3, isClosed: false, needsLooking: false, putAway: [])], "Only the chat at the head of a family is a head")

        let closed = arrange(sessions, closed: ["claude-cli:lead"], working: ["under a"])
        XCTAssertEqual(closed.visible.map(\.title), ["lead", "other"], "The family keeps its place with its chats put away")
        XCTAssertEqual(closed.all.count, 5, "Put away is not gone: the host is still told of them")
        XCTAssertEqual(closed.heads["claude-cli:lead"]?.started, 3)
        XCTAssertEqual(closed.heads["claude-cli:lead"]?.needsLooking, true, "A working chat out of sight, however deep, is flagged on the head")
        XCTAssertTrue(closed.folds.isEmpty)
        XCTAssertFalse(arrange(sessions, closed: ["claude-cli:lead"]).heads["claude-cli:lead"]!.needsLooking)

        // A search shows every match, whatever was put away.
        XCTAssertEqual(arrange(sessions, closed: ["claude-cli:lead"], folds: false).visible.count, 5)
    }

    func testAPersonCanPutAnyChatUnderAnyOther() {
        // "work" is a chat used as a container: nobody started the chats put under it.
        let sessions = [
            chat("work", minutesAgo: 500, machine: "machine-studio"), chat("notes", minutesAgo: 5, machine: "machine-studio"),
            // On another Mac: a person's choice is theirs wherever the chat is.
            chat("research", minutesAgo: 40, machine: "machine-macbook"),
            chat("lead", minutesAgo: 100), chat("started", minutesAgo: 20, startedBy: "lead"), chat("moved", minutesAgo: 30, startedBy: "lead"),
            chat("freed", minutesAgo: 60, startedBy: "lead"), chat("other", minutesAgo: 90),
        ]
        let layout = arrange(sessions, placed: ["notes": "work", "research": "work", "moved": "work", "freed": ""])
        // The container moves with its newest chat; a chat moved out of a family sits by itself.
        XCTAssertEqual(layout.visible.map(\.title), ["work", "notes", "moved", "research", "lead", "started", "freed", "other"])
        XCTAssertEqual(layout.depth, ["claude-cli:notes": 1, "claude-cli:moved": 1, "claude-cli:research": 1, "claude-cli:started": 1])
        XCTAssertEqual(layout.under["claude-cli:work"]?.map(\.title), ["notes", "moved", "research"])
        XCTAssertEqual(layout.under["claude-cli:lead"]?.map(\.title), ["started"], "A chat the person moved is no longer under its starter")
        XCTAssertEqual(layout.above["claude-cli:moved"]?.title, "work")
        XCTAssertNil(layout.above["claude-cli:freed"], "By itself is a choice: it takes a started chat out from under its starter")
        XCTAssertEqual(layout.heads["claude-cli:work"]?.started, 3)

        // Put away, the container speaks for what is in it, as a starter does.
        XCTAssertEqual(arrange(sessions, closed: ["claude-cli:work"], placed: ["notes": "work", "research": "work"])
            .heads["claude-cli:work"]?.putAway.map(\.title), ["notes", "research"])
    }

    func testAChatMayNotGoUnderItselfOrUnderAChatThatIsUnderIt() {
        let layout = arrange([
            chat("lead", minutesAgo: 100), chat("a", minutesAgo: 1, startedBy: "lead"), chat("under a", minutesAgo: 3, startedBy: "a"),
            chat("other", minutesAgo: 50),
        ])
        XCTAssertTrue(layout.canPlace("claude-cli:other", under: "claude-cli:lead"))
        XCTAssertTrue(layout.canPlace("claude-cli:under a", under: "claude-cli:other"), "A chat can leave its family for another")
        XCTAssertTrue(layout.canPlace("claude-cli:a", under: "claude-cli:other"))
        XCTAssertFalse(layout.canPlace("claude-cli:lead", under: "claude-cli:lead"))
        XCTAssertFalse(layout.canPlace("claude-cli:lead", under: "claude-cli:under a"), "That would make a ring of them")
        XCTAssertFalse(layout.canPlace("claude-cli:a", under: "claude-cli:under a"))
        // What a dragged row carries names its chat, and nothing else is taken for one.
        let carried = SessionFamilies.dragPayload(for: chat("lead", minutesAgo: 1))
        XCTAssertEqual(SessionFamilies.draggedSessionId(carried), "claude-cli:lead")
        XCTAssertNil(SessionFamilies.draggedSessionId("some text dragged in from another app"))
    }

    func testAChatPutUnderOneThatIsNotInTheListStandsByItself() {
        // The container is archived or filtered out. The choice still holds: it does not fall back under its starter.
        let layout = arrange([chat("lead", minutesAgo: 9), chat("moved", minutesAgo: 1, startedBy: "lead")], placed: ["moved": "gone"])
        XCTAssertEqual(layout.visible.map(\.title), ["moved", "lead"])
        XCTAssertTrue(layout.depth.isEmpty)
    }

    func testChatsPutUnderEachOtherAreStillAllShownOnce() {
        let layout = arrange([chat("a", minutesAgo: 2), chat("b", minutesAgo: 1), chat("self", minutesAgo: 3)],
                             placed: ["a": "b", "b": "a", "self": "self"])
        XCTAssertEqual(Set(layout.visible.map(\.title)), ["a", "b", "self"])
        XCTAssertEqual(layout.visible.count, 3)
    }

    func testEveryChatThatHasStartedOthersKnowsTheChatsUnderIt() {
        let layout = arrange([
            chat("lead", minutesAgo: 100), chat("a", minutesAgo: 1, startedBy: "lead"), chat("b", minutesAgo: 2, startedBy: "lead"),
            chat("under a", minutesAgo: 3, startedBy: "a"), chat("under under a", minutesAgo: 4, startedBy: "under a"),
            chat("alone", minutesAgo: 50),
        ])
        // What goes with a chat when it is archived: all of it, from wherever in the family the chat is.
        XCTAssertEqual(layout.under["claude-cli:lead"]?.map(\.title), ["a", "under a", "under under a", "b"])
        XCTAssertEqual(layout.under["claude-cli:a"]?.map(\.title), ["under a", "under under a"])
        XCTAssertEqual(layout.under["claude-cli:under a"]?.map(\.title), ["under under a"])
        XCTAssertNil(layout.under["claude-cli:b"])
        XCTAssertNil(layout.under["claude-cli:alone"])
    }

    func testTheArchiveKeepsAChatWithTheChatsItStarted() {
        func archived(_ name: String, daysAgo: Double, machine: String = "machine-studio", startedBy: SessionStartedBy? = nil) -> AgentBridge.ArchivedSessionInfo {
            .init(id: "claude-cli:\(name)", displayName: name, projectName: "ripul", archivedAt: now.addingTimeInterval(-daysAgo * 86_400),
                  provider: "claude-cli", machineId: machine, startedBy: startedBy)
        }
        let rows = [
            archived("newest", daysAgo: 1),
            // Archived on the MacBook, started by the chat on the Studio: the MacBook names it with the Studio's id.
            archived("panels", daysAgo: 2, machine: "machine-macbook", startedBy: .init(agentId: "machine-studio/cli_design", title: "design (Studio)")),
            archived("under panels", daysAgo: 3, machine: "machine-macbook", startedBy: .init(agentId: "cli_panels", sessionId: "claude-cli:panels", title: "panels")),
            archived("rows", daysAgo: 4, startedBy: .init(agentId: "cli_design", sessionId: "claude-cli:design", title: "design")),
            archived("design", daysAgo: 9),
            // Its starter is still in the list, not in the archive.
            archived("orphan", daysAgo: 5, startedBy: .init(agentId: "cli_live", title: "A live chat")),
        ]
        let layout = ArchivedSessionFamilies.arrange(rows)
        // The family sits where its most recently archived chat would: after "newest", before "orphan".
        XCTAssertEqual(layout.rows.map(\.displayName), ["newest", "design", "panels", "under panels", "rows", "orphan"])
        XCTAssertEqual(layout.rows.map { layout.depth(of: $0) }, [0, 0, 1, 2, 1, 0])
        XCTAssertEqual(layout.under(rows[4]).map(\.displayName), ["panels", "under panels", "rows"], "What comes back with the chat")
        XCTAssertEqual(layout.under(rows[1]).map(\.displayName), ["under panels"])
        XCTAssertTrue(layout.under(rows[5]).isEmpty)
        XCTAssertEqual(layout.rows.last?.startedBy?.title, "A live chat", "A chat whose starter is not archived can still say whose it is")

        // What the person put under a chat is kept with it in the archive as well.
        let placed = ArchivedSessionFamilies.arrange([archived("container", daysAgo: 8), archived("loose", daysAgo: 1, machine: "machine-macbook")],
                                                     placements: ["loose": "container"])
        XCTAssertEqual(placed.rows.map(\.displayName), ["container", "loose"])
        XCTAssertEqual(placed.under(placed.rows[0]).map(\.displayName), ["loose"])

        // The same id archived on two Macs is two rows, each with its own.
        let twice = ArchivedSessionFamilies.arrange([archived("design", daysAgo: 1), archived("design", daysAgo: 2, machine: "machine-macbook"),
                                                    archived("rows", daysAgo: 3, machine: "machine-macbook", startedBy: .init(agentId: "cli_design"))])
        XCTAssertEqual(twice.rows.map(\.machineId), ["machine-studio", "machine-macbook", "machine-macbook"])
        XCTAssertEqual(twice.rows.map { twice.depth(of: $0) }, [0, 0, 1])
    }

    func testAHeadIsGivenTheChatsPutAwayUnderItToSpeakFor() {
        let sessions = [
            chat("lead", minutesAgo: 100), chat("a", minutesAgo: 1, startedBy: "lead"), chat("b", minutesAgo: 2, startedBy: "lead"),
            chat("under a", minutesAgo: 3, startedBy: "a"), chat("under under a", minutesAgo: 4, startedBy: "under a"),
            chat("alone", minutesAgo: 50),
        ]
        // Put away, their rows cannot say they are mid-turn or when they last spoke, so the
        // head's row is handed every one of them, however deep, and none that is not its own.
        let closed = arrange(sessions, closed: ["claude-cli:lead"])
        XCTAssertEqual(closed.heads["claude-cli:lead"]?.putAway.map(\.title), ["a", "under a", "under under a", "b"])
        // Shown, each speaks on its own row, and the head only for itself.
        XCTAssertEqual(arrange(sessions).heads["claude-cli:lead"]?.putAway, [])
        // A search shows the rows again.
        XCTAssertEqual(arrange(sessions, closed: ["claude-cli:lead"], folds: false).heads["claude-cli:lead"]?.putAway, [])
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

    func testAChatStartedFromAnotherMacSitsUnderItsStarterThere() {
        // An agent on the Studio started two chats on the MacBook. The MacBook names their
        // starter with the Studio's id in front, and that says which Mac's row to look for.
        let layout = arrange([
            chat("design", minutesAgo: 60, machine: "machine-studio", folder: "ripul", branch: "main"),
            chat("panels", minutesAgo: 1, startedBy: "design", machine: "machine-macbook", folder: "ripul", branch: "main", starterOn: "machine-studio"),
            chat("rows", minutesAgo: 2, startedBy: "design", machine: "machine-macbook", starterOn: "machine-studio"),
            chat("under panels", minutesAgo: 3, startedBy: "panels", machine: "machine-macbook", folder: "ripul", branch: "main"),
            chat("other", minutesAgo: 30, machine: "machine-macbook"),
        ])
        XCTAssertEqual(layout.visible.map(\.title), ["design", "panels", "under panels", "rows", "other"])
        XCTAssertEqual(layout.depth, ["claude-cli:panels": 1, "claude-cli:under panels": 2, "claude-cli:rows": 1])
        XCTAssertEqual(layout.heads["claude-cli:design"]?.started, 3)
        XCTAssertEqual(layout.sharesFolder, ["claude-cli:panels", "claude-cli:under panels"], "The same repository on another Mac is not said again")
        XCTAssertEqual(layout.sharesBranch, ["claude-cli:panels", "claude-cli:under panels"])

        // Put away, the head speaks for the chats on the other Mac as for any others.
        let closed = arrange(layout.all, closed: ["claude-cli:design"])
        XCTAssertEqual(closed.heads["claude-cli:design"]?.putAway.map(\.title), ["panels", "under panels", "rows"])
    }

    func testAnIdThatNamesAMacIsOnlyMatchedOnThatMac() {
        // The starter is on the Studio, which is not listed. A chat of the same id on a third Mac is not it.
        let layout = arrange([
            chat("design", minutesAgo: 10, machine: "machine-mini"),
            chat("panels", minutesAgo: 1, startedBy: "design", machine: "machine-macbook", starterOn: "machine-studio"),
        ])
        XCTAssertEqual(layout.visible.map(\.title), ["panels", "design"])
        XCTAssertTrue(layout.depth.isEmpty)
    }

    func testTheStarterIsTheChatOnTheSameMacWhenAnotherMacHasTheSameId() {
        // A chat moved between Macs leaves its id on both. The copy on the other Mac comes first in the list.
        let copy = UnifiedSession(
            id: "claude-cli:design-on-studio", title: "design on studio", lastUsed: now, gitBranch: nil, messageCount: nil,
            projectName: nil, provider: "claude-cli", providerLabel: nil, machineName: "studio", machineId: "machine-studio",
            matchKeys: ["cli_design"], startedBy: nil, ripulSession: nil)
        let layout = arrange([
            copy,
            chat("design", minutesAgo: 10, machine: "machine-macbook"),
            chat("panels", minutesAgo: 1, startedBy: "design", machine: "machine-macbook", rowKnown: false),
        ])
        XCTAssertEqual(layout.visible.map(\.title), ["design on studio", "design", "panels"])
        XCTAssertEqual(layout.depth, ["claude-cli:panels": 1])
        XCTAssertEqual(layout.heads.keys.map { $0 }, ["claude-cli:design"])
    }

    @MainActor
    func testAChatNotOpenHereIsRunningWhenItsMacSaysSo() {
        let store = SessionListStore()
        func row(_ name: String, onHost: Bool, tab: Bool) -> UnifiedSession {
            UnifiedSession(
                id: "claude-cli:\(name)", title: name, lastUsed: now, gitBranch: nil, messageCount: nil, projectName: nil,
                provider: "claude-cli", providerLabel: nil, machineName: "mac", machineId: "mac", runningOnHost: onHost,
                ripulSession: tab ? ChatSession(id: name, sourceChatId: name, displayName: name, createdAt: now) : nil)
        }
        // A chat an agent has just started is open on no device: all there is to go on is its Mac's list.
        XCTAssertTrue(store.isRunning(row("started", onHost: true, tab: false)))
        XCTAssertTrue(store.isWorkingOrAsking(row("started", onHost: true, tab: false)), "So it is not folded away either")
        XCTAssertFalse(store.isRunning(row("quiet", onHost: false, tab: false)))
        // One open here has a live phase, which is newer than any list.
        store.sessionPhases = ["live": .running, "over": .completed, "asking": .awaitingInput]
        XCTAssertTrue(store.isRunning(row("live", onHost: false, tab: true)))
        XCTAssertFalse(store.isRunning(row("over", onHost: true, tab: true)), "A list read before the turn ended does not outvote the phase")
        XCTAssertFalse(store.isRunning(row("asking", onHost: false, tab: true)))
        XCTAssertTrue(store.isWorkingOrAsking(row("asking", onHost: false, tab: true)))
        // The flag is not kept in the cache, where it would outlive the turn.
        let cached = try? JSONDecoder().decode(UnifiedSession.self, from: JSONEncoder().encode(row("started", onHost: true, tab: false)))
        XCTAssertEqual(cached?.runningOnHost, false)
        XCTAssertNotEqual(row("a", onHost: true, tab: false), row("a", onHost: false, tab: false), "A change must redraw the row")
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
