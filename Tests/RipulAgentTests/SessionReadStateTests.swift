import WebKit
import XCTest
@testable import RipulAgent

/// Which chats are waiting on you, what counts as having read one, and which
/// are pinned: the rules behind the unread shading and Siri's "what's waiting".
/// Driven the way the app drives them, by turn events arriving on the bridge.
@MainActor
final class SessionReadStateTests: XCTestCase {
    private func cache() -> RipulSessionCache {
        UserDefaultsSessionCache(suiteName: "io.ripul.tests.readstate.\(UUID().uuidString)")
    }

    private func bridge(_ cache: RipulSessionCache) -> AgentBridge {
        let bridge = AgentBridge()
        bridge.sessionCache = cache
        return bridge
    }

    /// A turn event as the web app sends it. `at` is the turn's own time.
    private func turn(_ bridge: AgentBridge, _ kind: String, chat: String, at: Date? = nil) {
        var message: [String: Any] = ["type": "agent-framework:agent:turn\(kind)", "chatId": chat]
        if let at { message["timestamp"] = at.timeIntervalSince1970 * 1000 }
        bridge.handleMessage(message)
    }

    private func waiting(_ cache: RipulSessionCache) -> [String] {
        AgentBridge.waitingSessions(cache: cache).map(\.chatId)
    }

    private func row(_ id: String, tab: ChatSession? = nil, title: String = "Row") -> UnifiedSession {
        UnifiedSession(id: id, title: title, lastUsed: Date(), gitBranch: nil, messageCount: nil,
                       projectName: nil, provider: nil, providerLabel: nil, machineName: nil, machineId: nil,
                       cachedIsOpen: false, ripulSession: tab)
    }

    // MARK: - What makes a chat wait

    func testATurnThatEndsWaitsAndOneThatIsRunningDoesNot() {
        let cache = cache(); let bridge = bridge(cache)
        turn(bridge, "Started", chat: "a")
        XCTAssertEqual(waiting(cache), [])
        turn(bridge, "Completed", chat: "a", at: Date())
        turn(bridge, "Failed", chat: "b", at: Date().addingTimeInterval(1))
        turn(bridge, "AwaitingInput", chat: "c", at: Date().addingTimeInterval(2))
        XCTAssertEqual(waiting(cache), ["c", "b", "a"], "Newest first")
        XCTAssertEqual(bridge.sessionList.unreadChatIds, ["a", "b", "c"])
    }

    func testANewTurnStartingDoesNotClearAnUnreadReply() {
        let cache = cache(); let bridge = bridge(cache)
        turn(bridge, "Completed", chat: "a", at: Date())
        turn(bridge, "Started", chat: "a")
        XCTAssertEqual(waiting(cache), ["a"])
    }

    func testOpeningAChatReadsItUnderEitherOfItsNames() {
        let cache = cache(); let bridge = bridge(cache)
        bridge.sessions = [ChatSession(id: "tab-1", sourceChatId: "chat-1", displayName: "One", createdAt: Date())]
        turn(bridge, "Completed", chat: "chat-1", at: Date())
        XCTAssertEqual(waiting(cache), ["chat-1"])
        bridge.notifyAppBackgrounded()
        bridge.activeSessionId = "tab-1"
        XCTAssertEqual(waiting(cache), [], "Opening the tab reads the chat behind it")
        XCTAssertTrue(bridge.sessionList.unreadChatIds.isEmpty)
    }

    func testTheSamePhaseAgainIsNotNews() {
        let cache = cache(); let bridge = bridge(cache)
        turn(bridge, "Completed", chat: "a", at: Date())
        AgentBridge.clearWaiting(chatId: "a", cache: cache)
        turn(bridge, "Completed", chat: "a", at: Date().addingTimeInterval(5))
        XCTAssertEqual(waiting(cache), [], "Completed re-asserted is not a transition")
    }

    func testWatchingAChatFinishIsReadingIt() {
        let cache = cache(); let bridge = bridge(cache)
        bridge.sessions = [ChatSession(id: "tab-1", sourceChatId: "chat-1", displayName: "One", createdAt: Date())]
        bridge.activeSessionId = "tab-1"
        turn(bridge, "Started", chat: "chat-1")
        turn(bridge, "Completed", chat: "chat-1", at: Date().addingTimeInterval(1))
        XCTAssertEqual(waiting(cache), [], "On screen and frontmost")

        bridge.notifyAppBackgrounded()
        turn(bridge, "Started", chat: "chat-1")
        turn(bridge, "Completed", chat: "chat-1", at: Date().addingTimeInterval(2))
        XCTAssertEqual(waiting(cache), ["chat-1"], "The app was in the background")
    }

    // MARK: - Read state across launches

    func testAReplayOfAnOldTurnStaysReadAndANewerOneDoesNot() {
        let cache = cache()
        let first = bridge(cache)
        first.markSessionRead("a")
        let readAt = Date()

        let relaunched = bridge(cache)
        turn(relaunched, "Completed", chat: "a", at: readAt.addingTimeInterval(-3600))
        XCTAssertEqual(waiting(cache), [], "Ended before it was read")
        turn(relaunched, "Started", chat: "a")
        turn(relaunched, "Completed", chat: "a")
        XCTAssertEqual(waiting(cache), [], "No time on the event: treated as a replay, not news")
        turn(relaunched, "Started", chat: "a")
        turn(relaunched, "Completed", chat: "a", at: readAt.addingTimeInterval(3600))
        XCTAssertEqual(waiting(cache), ["a"], "Ended after it was read")
    }

    func testReadStampsUseOneNameAndAreBounded() {
        let cache = cache()
        AgentBridge.stampRead(chatId: "cli_abc", cache: cache)
        XCTAssertNotNil(AgentBridge.readStamps(cache: cache)["abc"], "Stored without the cli_ prefix")
        XCTAssertEqual(AgentBridge.canonicalChatKey("cli_abc"), "abc")
        XCTAssertEqual(AgentBridge.canonicalChatKey("abc"), "abc")
        for index in 1..<300 { AgentBridge.stampRead(chatId: "chat-\(index)", cache: cache) }
        XCTAssertEqual(AgentBridge.readStamps(cache: cache).count, 300)
        AgentBridge.stampRead(chatId: "one more", cache: cache)
        XCTAssertEqual(AgentBridge.readStamps(cache: cache).count, 200, "Past 300 it keeps the 200 most recent")
        XCTAssertNotNil(AgentBridge.readStamps(cache: cache)["one more"])
        XCTAssertNil(AgentBridge.readStamps(cache: cache)["abc"], "The oldest went")
    }

    // MARK: - The waiting list itself

    func testClearingMatchesBothNamesOfACliChat() {
        let cache = cache(); let bridge = bridge(cache)
        turn(bridge, "Completed", chat: "cli_abc", at: Date())
        turn(bridge, "Completed", chat: "def", at: Date().addingTimeInterval(1))
        AgentBridge.clearWaiting(chatId: "abc", cache: cache)
        XCTAssertEqual(waiting(cache), ["def"])
        AgentBridge.clearWaiting(chatId: "cli_def", cache: cache)
        XCTAssertEqual(waiting(cache), [])
    }

    func testAnEntryTakesTheChatsTitle() {
        let cache = cache(); let bridge = bridge(cache)
        bridge.sessions = [
            ChatSession(id: "tab-1", sourceChatId: "chat-1", displayName: "  Named  ", createdAt: Date()),
            ChatSession(id: "tab-2", sourceChatId: "chat-2", displayName: "   ", createdAt: Date()),
        ]
        bridge.notifyAppBackgrounded()
        turn(bridge, "Completed", chat: "chat-1", at: Date())
        turn(bridge, "Completed", chat: "chat-2", at: Date().addingTimeInterval(1))
        turn(bridge, "Completed", chat: "chat-3", at: Date().addingTimeInterval(2))
        let titles = Dictionary(uniqueKeysWithValues: AgentBridge.waitingSessions(cache: cache).map { ($0.chatId, $0.title) })
        XCTAssertEqual(titles, ["chat-1": "Named", "chat-2": "Untitled session", "chat-3": "Untitled session"])
    }

    func testTheListKeepsTheFiftyNewest() {
        let cache = cache(); let bridge = bridge(cache)
        let start = Date()
        for index in 0..<51 { turn(bridge, "Completed", chat: "chat-\(index)", at: start.addingTimeInterval(Double(index))) }
        let now = waiting(cache)
        XCTAssertEqual(now.count, 50)
        XCTAssertEqual(now.first, "chat-50")
        XCTAssertFalse(now.contains("chat-0"))
    }

    func testWhatIsReadAloudIsWholeSentencesUpToABudget() {
        XCTAssertNil(AgentBridge.spokenPreview(nil))
        XCTAssertNil(AgentBridge.spokenPreview("  \n "))
        XCTAssertEqual(AgentBridge.spokenPreview("## Done\n**All** `good`"), "Done All `good`")
        let sentence = String(repeating: "word ", count: 20).trimmingCharacters(in: .whitespaces)
        let long = Array(repeating: sentence, count: 4).joined(separator: ". ") + "."
        let spoken = AgentBridge.spokenPreview(long)
        XCTAssertEqual(spoken, sentence + ". " + sentence + ".", "Two whole sentences fit in 220 characters")
        let unbroken = String(repeating: "x", count: 300)
        XCTAssertEqual(AgentBridge.spokenPreview(unbroken), String(repeating: "x", count: 220) + ".")
    }

    // MARK: - What the agent last said

    private func reply(_ bridge: AgentBridge, chat: String, _ text: String) {
        bridge.handleMessage([
            "type": "agent-framework:agent:activity", "chatId": chat,
            "event": ["kind": "response", "preview": text],
        ])
    }

    private func preview(_ cache: RipulSessionCache, _ chat: String) -> String? {
        AgentBridge.waitingSessions(cache: cache).first { $0.chatId == chat }?.preview
    }

    func testAReplyHeardBeforeTheTurnEndsIsFiledWithIt() {
        let cache = cache(); let bridge = bridge(cache)
        reply(bridge, chat: "a", "  The answer.  ")
        turn(bridge, "Completed", chat: "a", at: Date())
        XCTAssertEqual(preview(cache, "a"), "The answer.")
    }

    func testAReplyHeardAfterTheTurnEndsIsFilledInOnce() {
        let cache = cache(); let bridge = bridge(cache)
        turn(bridge, "Completed", chat: "a", at: Date())
        XCTAssertNil(preview(cache, "a"))
        reply(bridge, chat: "a", "Late answer.")
        XCTAssertEqual(preview(cache, "a"), "Late answer.")
        reply(bridge, chat: "a", "A later one.")
        XCTAssertEqual(preview(cache, "a"), "Late answer.", "An entry that has a reply keeps it")
        reply(bridge, chat: "never waited", "Nobody is waiting on this.")
        XCTAssertNil(preview(cache, "never waited"))
    }

    private final class Loader: NSObject, WKNavigationDelegate {
        var completion: (() -> Void)?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { completion?() }
    }

    func testAReplyNobodyHeardIsAskedForFromThePage() async {
        let cache = cache(); let bridge = bridge(cache)
        let web = WKWebView()
        let loader = Loader()
        let loaded = expectation(description: "Page ready")
        loader.completion = { loaded.fulfill() }
        web.navigationDelegate = loader
        web.loadHTMLString("""
            <script>window.__ripulGetLastAssistantText = async (chatId) => ({text: 'Reply for ' + chatId});</script>
            """, baseURL: nil)
        await fulfillment(of: [loaded], timeout: 10)
        bridge.attach(to: web)

        turn(bridge, "Completed", chat: "it's \"quoted\"", at: Date())
        let deadline = Date().addingTimeInterval(3)
        while preview(cache, "it's \"quoted\"") == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(preview(cache, "it's \"quoted\""), "Reply for it's \"quoted\"")
        withExtendedLifetime(web) {}
    }

    // MARK: - By hand, from a row's menu

    func testMarkingARowUnreadAndReadAgain() {
        let cache = cache(); let bridge = bridge(cache)
        let tab = ChatSession(id: "tab-1", sourceChatId: "chat-1", displayName: "One", createdAt: Date())
        bridge.markSessionUnread(row("row-1", tab: tab, title: "Come back"))
        let entry = AgentBridge.waitingSessions(cache: cache).first
        XCTAssertEqual(entry?.chatId, "chat-1")
        XCTAssertEqual(entry?.title, "Come back")
        XCTAssertEqual(bridge.sessionList.unreadChatIds, ["chat-1"])

        bridge.markSessionRead(row("row-1", tab: tab))
        XCTAssertEqual(waiting(cache), [])
        XCTAssertNotNil(AgentBridge.readStamps(cache: cache)["chat-1"])
        XCTAssertNotNil(AgentBridge.readStamps(cache: cache)["row-1"], "Every name the row answers to is stamped")

        bridge.markSessionUnread(row("row-2"))
        XCTAssertEqual(waiting(cache), ["row-2"], "A row with no open tab is filed under its own id")
    }

    func testPinningARowPinsEveryNameItAnswersTo() {
        let cache = cache(); let bridge = bridge(cache)
        let tab = ChatSession(id: "tab-1", sourceChatId: "cli_abc", displayName: "One", createdAt: Date())
        let pinned = row("row-1", tab: tab)
        bridge.setSessionPinned(true, pinned)
        XCTAssertTrue(AgentBridge.pinnedKeys(cache: cache).isSuperset(of: ["row-1", "abc", "tab-1"]))
        XCTAssertEqual(bridge.sessionList.pinnedChatKeys, AgentBridge.pinnedKeys(cache: cache))

        XCTAssertEqual(self.bridge(cache).sessionList.pinnedChatKeys, AgentBridge.pinnedKeys(cache: cache),
                       "A new bridge given the cache shows the pins")

        bridge.setSessionPinned(false, pinned)
        XCTAssertTrue(AgentBridge.pinnedKeys(cache: cache).isEmpty)
        XCTAssertTrue(bridge.sessionList.pinnedChatKeys.isEmpty)
    }
}
