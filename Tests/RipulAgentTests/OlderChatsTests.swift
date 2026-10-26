import XCTest
@testable import RipulAgent

/// Older Chats at the end of the session list: the pages a Mac is read for on
/// one tap (`RipulSessionListModel.pageOlder`) and how they join its newest
/// list (`RipulSessionListModel.flatten`).
@MainActor
final class OlderChatsTests: XCTestCase {
    private func chat(_ id: String, at seconds: TimeInterval) -> RemoteSessionInfo {
        RemoteSessionInfo(
            id: id, sourceChatId: id, displayName: id,
            createdAt: Date(timeIntervalSince1970: seconds), lastModified: Date(timeIntervalSince1970: seconds),
            isRunning: false, projectName: nil, cwd: nil, gitBranch: nil, messageCount: nil,
            provider: "claude-cli", providerLabel: nil, model: nil, hostChatId: nil, machineId: "mac-1")
    }

    private func page(_ chats: [RemoteSessionInfo], next: TimeInterval?) -> AgentBridge.OlderSessionsPage {
        AgentBridge.OlderSessionsPage(sessions: chats, next: next.map { Date(timeIntervalSince1970: $0) }, error: nil)
    }

    /// A Mac whose chats are one every second back from 1000, `count` of them,
    /// answering pages the way the host does.
    private func mac(count: Int, size: Int) -> (Date) async -> AgentBridge.OlderSessionsPage {
        { cursor in
            let before = cursor.timeIntervalSince1970
            let older = (0..<count).map { 1000 - TimeInterval($0) }.filter { $0 < before }
            let taken = Array(older.prefix(size))
            let more = older.count > size
            return self.page(taken.map { self.chat("c\(Int($0))", at: $0) }, next: more ? taken.last : nil)
        }
    }

    func testOneTapReadsAPageOfChatsTheListDoesNotHold() async {
        let fetch = await RipulSessionListModel.pageOlder(
            machineId: "mac-1", from: Date(timeIntervalSince1970: 2000), listed: [], pageSize: 10,
            page: mac(count: 100, size: 10))
        XCTAssertEqual(fetch.sessions.count, 10)
        XCTAssertEqual(fetch.newCount, 10)
        XCTAssertEqual(fetch.cursor, Date(timeIntervalSince1970: 991))
        XCTAssertFalse(fetch.exhausted)
    }

    func testAPageOfChatsTheListHoldsAlreadyIsFollowedByTheNext() async {
        // The newest twelve are open as tabs, so they are in the newest list.
        let listed = Set((0..<12).map { "c\(1000 - $0)" })
        let fetch = await RipulSessionListModel.pageOlder(
            machineId: "mac-1", from: Date(timeIntervalSince1970: 2000), listed: listed, pageSize: 10,
            page: mac(count: 100, size: 10))
        // Page one brought nothing new, page two eight: enough to stop at.
        XCTAssertEqual(fetch.sessions.count, 20)
        XCTAssertEqual(fetch.newCount, 8)
        XCTAssertEqual(fetch.cursor, Date(timeIntervalSince1970: 981))
    }

    func testAtMostFourPagesATap() async {
        let listed = Set((0..<100).map { "c\(1000 - $0)" })
        var asked = 0
        let pages = mac(count: 100, size: 10)
        let fetch = await RipulSessionListModel.pageOlder(
            machineId: "mac-1", from: Date(timeIntervalSince1970: 2000), listed: listed, pageSize: 10,
            page: { cursor in asked += 1; return await pages(cursor) })
        XCTAssertEqual(asked, 4)
        XCTAssertEqual(fetch.newCount, 0)
        XCTAssertFalse(fetch.exhausted, "The next tap carries on from where this one stopped")
    }

    func testASearchReadsOnUntilAChatMatches() async {
        // The match is 130 chats back: pages 1 to 13 of 10.
        let pages = mac(count: 200, size: 10)
        var asked = 0
        let fetch = await RipulSessionListModel.pageOlder(
            machineId: "mac-1", from: Date(timeIntervalSince1970: 2000), listed: [], pageSize: 10,
            matching: { $0.id == "c870" }, page: { cursor in asked += 1; return await pages(cursor) })
        XCTAssertEqual(asked, 14)
        XCTAssertTrue(fetch.sessions.contains { $0.id == "c870" })
    }

    func testASearchStopsAtTwentyPages() async {
        let pages = mac(count: 1000, size: 10)
        var asked = 0
        _ = await RipulSessionListModel.pageOlder(
            machineId: "mac-1", from: Date(timeIntervalSince1970: 2000), listed: [], pageSize: 10,
            matching: { _ in false }, page: { cursor in asked += 1; return await pages(cursor) })
        XCTAssertEqual(asked, 20)
    }

    func testTheSearchMatchesWhatTheListSearches() {
        let match = RipulSessionListModel.searchMatcher("  TERRA ")!
        XCTAssertTrue(match(chat("Terraform ux", at: 1)))
        XCTAssertFalse(match(chat("Payslips", at: 1)))
        XCTAssertNil(RipulSessionListModel.searchMatcher("   "))
    }

    func testAMacWithNothingOlderIsDone() async {
        let fetch = await RipulSessionListModel.pageOlder(
            machineId: "mac-1", from: Date(timeIntervalSince1970: 2000), listed: [], pageSize: 10,
            page: mac(count: 7, size: 10))
        XCTAssertEqual(fetch.sessions.count, 7)
        XCTAssertTrue(fetch.exhausted)
    }

    func testANextPageThatStartsNoEarlierEndsTheMac() async {
        // A page saying the next starts where this one did would be read for ever.
        let stuck = await RipulSessionListModel.pageOlder(
            machineId: "mac-1", from: Date(timeIntervalSince1970: 500), listed: [], pageSize: 10,
            page: { cursor in self.page([], next: cursor.timeIntervalSince1970) })
        XCTAssertTrue(stuck.exhausted)
    }

    func testAMacThatCannotAnswerIsNotDone() async {
        let fetch = await RipulSessionListModel.pageOlder(
            machineId: "mac-1", from: Date(timeIntervalSince1970: 2000), listed: [], pageSize: 10,
            page: { _ in AgentBridge.OlderSessionsPage(sessions: [], next: nil, error: "This Mac lists older chats once Ripul Host is updated.") })
        XCTAssertFalse(fetch.exhausted, "A tap later, once the host is updated, may bring them")
        XCTAssertNil(fetch.cursor)
        XCTAssertNotNil(fetch.error)
    }

    func testTheNoteNamesTheMacsInOneSentenceEach() {
        XCTAssertEqual(RipulSessionListModel.olderSessionsNote(needUpdate: ["Macbook", "Studio"], unanswered: []),
                       "Macbook and Studio list older chats once Ripul Host is updated.")
        XCTAssertEqual(RipulSessionListModel.olderSessionsNote(needUpdate: ["Studio"], unanswered: ["Air", "Macbook", "Mini"]),
                       "Studio lists older chats once Ripul Host is updated. Air, Macbook and Mini did not answer.")
        XCTAssertNil(RipulSessionListModel.olderSessionsNote(needUpdate: [], unanswered: []))
    }

    // MARK: Quiet tabs

    private let now = Date(timeIntervalSince1970: 100 * 86_400)

    private func tab(_ id: String, daysAgo: Double, machine: String = "Studio", shared: Bool = false,
                     repliedDaysAgo: Double? = nil) -> ChatSession {
        ChatSession(id: id, sourceChatId: id, displayName: id, createdAt: now.addingTimeInterval(-daysAgo * 86_400),
                    remoteMachineName: machine, hostChatId: id, isSharedGuest: shared,
                    latestHumanReplyAt: repliedDaysAgo.map { now.addingTimeInterval(-$0 * 86_400) })
    }

    /// A chat as its Mac lists it: the bare uuid, and the host tab it is open in.
    private func listed(_ uuid: String, usedDaysAgo: Double, running: Bool = false) -> RemoteSessionInfo {
        RemoteSessionInfo(id: "claude-cli:\(uuid)", sourceChatId: uuid, displayName: uuid,
                          createdAt: now.addingTimeInterval(-usedDaysAgo * 86_400),
                          lastModified: now.addingTimeInterval(-usedDaysAgo * 86_400), isRunning: running,
                          projectName: nil, cwd: nil, gitBranch: nil, messageCount: nil, provider: "claude-cli",
                          providerLabel: nil, model: nil, hostChatId: "cli_\(uuid)", machineId: "mac-studio")
    }

    private let studio = ["mac-studio": "Studio"]

    func testAQuietTabOnAMacThatPagesIsClosed() {
        let quiet = tab("cli_quiet", daysAgo: 30)
        let ids = RipulSessionListModel.quietTabCandidates(tabs: [quiet], listed: ["mac-studio": []], pagingMachines: studio, now: now) { _ in false }
        XCTAssertEqual(ids, ["cli_quiet"], "Its Mac answered and left it out of the two-week list")
    }

    func testATabFindsItsMacByIdAfterTheMacWasRenamed() {
        var renamed = tab("cli_renamed", daysAgo: 30, machine: "peter\u{2019}s Mac Studio")
        renamed.remoteMachineId = "mac-studio"
        var otherMac = tab("cli_other", daysAgo: 30, machine: "Studio")
        otherMac.remoteMachineId = "mac-book"
        let ids = RipulSessionListModel.quietTabCandidates(tabs: [renamed, otherMac], listed: ["mac-studio": []],
                                                           pagingMachines: studio, now: now) { _ in false }
        XCTAssertEqual(ids, ["cli_renamed"], "The id decides; a name that matches another Mac does not")
    }

    func testTabsInUseOrRecentOrElsewhereStay() {
        let tabs = [
            tab("cli_new", daysAgo: 3),
            tab("cli_replied", daysAgo: 30, repliedDaysAgo: 2),
            tab("cli_shared", daysAgo: 30, shared: true),
            tab("cli_oldmac", daysAgo: 30, machine: "Macbook"),
            tab("cli_pinned", daysAgo: 30),
        ]
        let ids = RipulSessionListModel.quietTabCandidates(tabs: tabs, listed: ["mac-studio": []], pagingMachines: studio, now: now) {
            $0.id == "cli_pinned"
        }
        XCTAssertEqual(ids, [], "New, replied to, shared, on a Mac that cannot page, or in use")
    }

    func testAListedChatGoesOnlyWhenItsMacSaysItIsQuiet() {
        let uuids = ["11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222",
                     "33333333-3333-4333-8333-333333333333"]
        let tabs = uuids.map { tab("cli_\($0)", daysAgo: 30) }
        let macList = [listed(uuids[0], usedDaysAgo: 2), listed(uuids[1], usedDaysAgo: 40),
                       listed(uuids[2], usedDaysAgo: 40, running: true)]
        let ids = RipulSessionListModel.quietTabCandidates(tabs: tabs, listed: ["mac-studio": macList],
                                                           pagingMachines: studio, now: now) { _ in false }
        XCTAssertEqual(ids, ["cli_\(uuids[1])"], "Used this week, or running, the chat stays")
    }

    func testTheNewestListsRowWinsOverAnOlderPagesCopy() {
        let newest = ["mac-1": [chat("a", at: 900)]]
        let older = ["mac-1": [chat("a", at: 100), chat("b", at: 90)]]
        let merged = RipulSessionListModel.flatten(newest: newest, older: older, archived: [])
        XCTAssertEqual(merged.sessions.map(\.id), ["a", "b"])
        XCTAssertEqual(merged.sessions.first?.lastModified, Date(timeIntervalSince1970: 900))
        XCTAssertEqual(merged.olderOnly, ["b"], "Only the row an older page alone gave stays out of the row cache")
    }

    func testAChatArchivedHereLeavesTheOlderPagesToo() {
        let merged = RipulSessionListModel.flatten(newest: [:], older: ["mac-1": [chat("b", at: 90)]], archived: ["b"])
        XCTAssertTrue(merged.sessions.isEmpty)
    }

    func testCrossMachineDuplicateSessionIdsCollapseToOneRow() {
        let echo = RemoteSessionInfo(
            id: "claude-cli:shared", sourceChatId: "shared", displayName: "Shared",
            createdAt: Date(timeIntervalSince1970: 500), lastModified: nil,
            isRunning: false, projectName: nil, cwd: nil, gitBranch: nil, messageCount: nil,
            provider: nil, providerLabel: nil, model: nil, hostChatId: "cli_shared", machineId: "mac-1")
        let scanned = RemoteSessionInfo(
            id: "claude-cli:shared", sourceChatId: "shared", displayName: "Shared",
            createdAt: Date(timeIntervalSince1970: 500), lastModified: Date(timeIntervalSince1970: 900),
            isRunning: true, projectName: "ripul", cwd: "/tmp/ripul", gitBranch: "main", messageCount: 4,
            provider: "claude-cli", providerLabel: "Claude Code", model: "claude-opus-4-6",
            hostChatId: "cli_shared", machineId: "mac-2")
        let merged = RipulSessionListModel.flatten(
            newest: ["mac-1": [echo], "mac-2": [scanned]],
            older: [:],
            archived: []
        )
        XCTAssertEqual(merged.sessions.count, 1)
        XCTAssertEqual(merged.sessions.first?.machineId, "mac-2")
        XCTAssertEqual(merged.sessions.first?.provider, "claude-cli")

        let built = UnifiedSession.build(
            from: [echo, scanned],
            localSessions: [],
            machineNames: ["claude-cli:shared": "MacBook"]
        )
        XCTAssertEqual(built.count, 1)
        XCTAssertEqual(built.first?.id, "claude-cli:shared")
        XCTAssertEqual(built.first?.hasKnownActivity, true)
    }

    func testLaunchCrashCircuitBreakerClearsVolatileSessionCachesAfterTwoUnfinishedLaunches() {
        let suiteName = "io.ripul.tests.launchCircuitBreaker.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cache = UserDefaultsSessionCache(suite: defaults)

        let row = UnifiedSession(
            id: "claude-cli:1", title: "Cached", lastUsed: Date(timeIntervalSince1970: 100),
            hasKnownActivity: true, gitBranch: "main", messageCount: 1, projectName: "ripul",
            projectPath: "/tmp/ripul", provider: "claude-cli", providerLabel: "Claude Code",
            model: "claude-opus-4-6", machineName: "Studio", machineId: "mac-1",
            matchKeys: [], tags: [], metadataKey: "1", cachedIsOpen: true,
            titleFromScan: true, titleRenamedAt: nil, startedBy: nil, runningOnHost: false,
            ripulSession: nil
        )
        UnifiedSession.saveToCache([row], cache: cache)
        cache.set(Data([1, 2, 3]), forKey: "ripulRemoteSessionsByMachineIdV2")

        // First launch starts and survives -> counter resets, cache stays intact.
        XCTAssertFalse(RipulSessionListModel.recordLaunchStart(cache: cache))
        RipulSessionListModel.markLaunchSurvived(cache: cache)
        XCTAssertEqual(UnifiedSession.loadCached(cache: cache).count, 1)

        // Two consecutive unfinished launches (crashes before survival window) -> third launch trips breaker.
        XCTAssertFalse(RipulSessionListModel.recordLaunchStart(cache: cache))
        XCTAssertFalse(RipulSessionListModel.recordLaunchStart(cache: cache))
        XCTAssertEqual(UnifiedSession.loadCached(cache: cache).count, 1)

        XCTAssertTrue(RipulSessionListModel.recordLaunchStart(cache: cache))
        XCTAssertTrue(UnifiedSession.loadCached(cache: cache).isEmpty)
        XCTAssertNil(cache.data(forKey: "ripulRemoteSessionsByMachineIdV2"))
    }
}
