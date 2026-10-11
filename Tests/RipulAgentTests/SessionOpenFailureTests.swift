import Combine
import WebKit
import XCTest
@testable import RipulAgent

@MainActor
final class SessionOpenFailureTests: XCTestCase {
    private final class Loader: NSObject, WKNavigationDelegate {
        var completion: (() -> Void)?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { completion?() }
    }

    private func model(_ bridge: AgentBridge) -> RipulSessionListModel {
        bridge.sessions = []
        return RipulSessionListModel(bridge: bridge, tokenProvider: { nil },
            cache: UserDefaultsSessionCache(suiteName: "io.ripul.tests.open.\(UUID().uuidString)"))
    }

    private func row(_ id: String = "test-session", remote: Bool = true, cached: Bool = false) -> UnifiedSession {
        UnifiedSession(id: id, title: "Test chat", lastUsed: Date(), gitBranch: nil,
            messageCount: nil, projectName: nil, provider: nil, providerLabel: nil,
            machineName: remote ? "Test Mac" : nil, machineId: remote ? "test-mac" : nil,
            cachedIsOpen: cached, ripulSession: nil)
    }

    private func webFixture(_ bridge: AgentBridge, script: String) async -> WKWebView {
        let web = WKWebView()
        let loader = Loader()
        let loaded = expectation(description: "Fixture ready")
        loader.completion = { loaded.fulfill() }
        web.navigationDelegate = loader
        web.loadHTMLString("<script>\(script)</script>", baseURL: nil)
        await fulfillment(of: [loaded], timeout: 10)
        bridge.attach(to: web)
        return web
    }

    private func waitForFailure(_ model: RipulSessionListModel, timeout: TimeInterval = 3) async {
        // The model is @Observable (no Combine publisher): poll for the error.
        let deadline = Date().addingTimeInterval(timeout)
        while model.openSessionError == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotNil(model.openSessionError, "Failure is published")
        XCTAssertNil(model.openingUnifiedSessionId)
    }

    func testHostFailureDoesNotWaitForStalledDiagnostics() async {
        let bridge = AgentBridge()
        let model = model(bridge)
        let web = await webFixture(bridge, script: """
            window.__ripulOpenRemoteSession = async () => ({success:false, errorCode:'machine-offline', error:'Host unavailable'});
            window.__ripulDiagnostics = () => new Promise(resolve => { window.finishDiagnostics = resolve; });
            """)
        model.openSession(row(), onSelect: { _ in XCTFail("Failed chat must not open") },
                          onDismiss: { XCTFail("Keep the error visible on the list") })
        await waitForFailure(model)
        XCTAssertEqual(model.openSessionError, "machine-offline: Host unavailable")
        _ = try? await web.evaluateJavaScript("if (window.finishDiagnostics) window.finishDiagnostics({});")
    }

    func testRemoteSuccessWithoutATabInTheListShowsAnError() async {
        let bridge = AgentBridge()
        let model = model(bridge)
        let web = await webFixture(bridge, script: """
            window.__ripulOpenRemoteSession = async () => ({success:true, tabId:'missing-tab'});
            window.__ripulGetSessions = async () => ({sessions:[], activeId:null});
            """)
        model.openSession(row(), onSelect: { _ in XCTFail("There is no usable chat") },
                          onDismiss: { XCTFail("Do not silently dismiss") })
        await waitForFailure(model)
        XCTAssertTrue(model.openSessionError?.hasPrefix("session-open-incomplete:") == true)
        withExtendedLifetime(web) {}
    }

    func testRestoreTimeoutKeepsTheListVisibleAndPublishesAnError() async {
        let model = model(AgentBridge())
        model.openSession(row(remote: false, cached: true), onSelect: { _ in XCTFail("Nothing restored") },
                          onDismiss: { XCTFail("Keep the list visible while waiting and after failure") })
        await waitForFailure(model, timeout: 33)
        XCTAssertTrue(model.openSessionError?.hasPrefix("session-restore-timeout:") == true)
    }

    /// An invited chat's row as the list holds it: the "machine" is the share,
    /// named after the chat, and has no id any of this account's Macs answer to.
    private func invitedRow(cached: Bool = true) -> UnifiedSession {
        UnifiedSession(id: "shared_1", title: "Invite latency", lastUsed: Date(), gitBranch: nil,
            messageCount: nil, projectName: nil, provider: nil, providerLabel: nil,
            machineName: "Invite latency", machineId: nil,
            cachedIsOpen: cached, ripulSession: nil)
    }

    /// A chat on a Mac this account no longer has: named, with no id to route by.
    private func orphanedRow(cached: Bool = true) -> UnifiedSession {
        UnifiedSession(id: "remote-1", title: "Old chat", lastUsed: Date(), gitBranch: nil,
            messageCount: nil, projectName: nil, provider: nil, providerLabel: nil,
            machineName: "Gone Mac", machineId: nil,
            cachedIsOpen: cached, ripulSession: nil)
    }

    /// A page that is up, answers, and lists no tabs.
    private static let emptyPage = """
        window.__ripulOpenRemoteSession = async () => ({success:false, error:'unused'});
        window.__ripulGetSessions = async () => ({sessions:[], activeId:null});
        """

    private func invitedTab() -> ChatSession {
        ChatSession(id: "shared_1", sourceChatId: "shared_1", displayName: "Invite latency", createdAt: Date(),
                    remoteMachineName: "Invite latency", isSharedGuest: true)
    }

    func testAnInvitedChatOpenedBeforeItsTabIsListedWaitsForTheTab() async throws {
        // Straight after launch: the row is from the cache and the web app has
        // not listed its tabs. This was refused at once as "isn't connected".
        let bridge = AgentBridge()
        let model = model(bridge)
        let selected = expectation(description: "Invited chat selected")
        model.openSession(invitedRow(), onSelect: { chat in
            XCTAssertEqual(chat.id, "shared_1")
            selected.fulfill()
        }, onDismiss: { XCTFail("Do not dismiss before the tab is there") })
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(model.openSessionError)
        XCTAssertEqual(model.openingUnifiedSessionId, "shared_1")
        bridge.isSessionsReady = true
        bridge.sessions = [invitedTab()]
        await fulfillment(of: [selected], timeout: 2)
        XCTAssertNil(model.openSessionError)
        XCTAssertNil(model.openingUnifiedSessionId)
    }

    func testAnInvitedChatWhoseRowIsOlderThanItsTabOpensAtOnce() async {
        // The tab is listed but the row has not been rebuilt to hold it.
        let bridge = AgentBridge()
        let model = model(bridge)
        bridge.sessions = [invitedTab()]
        let selected = expectation(description: "Invited chat selected")
        model.openSession(invitedRow(cached: false), onSelect: { chat in
            XCTAssertEqual(chat.id, "shared_1")
            selected.fulfill()
        }, onDismiss: {})
        await fulfillment(of: [selected], timeout: 0.5)
        XCTAssertNil(model.openSessionError)
    }

    func testAChatWhoseMachineIsGoneStillSaysSoOnceThePageHasListedItsTabs() async {
        // The open flag is stale: the page is up, and this chat is not one of its tabs.
        let bridge = AgentBridge()
        let model = model(bridge)
        let web = await webFixture(bridge, script: Self.emptyPage)
        model.openSession(orphanedRow(), onSelect: { _ in XCTFail("There is no tab to open") },
                          onDismiss: { XCTFail("Keep the error visible on the list") })
        await waitForFailure(model, timeout: 5)
        XCTAssertTrue(model.openSessionError?.hasPrefix("machine-unavailable:") == true)
        withExtendedLifetime(web) {}
    }

    func testAnInvitedChatWhoseTabIsGoneSendsTheUserBackToInvites() async {
        // Not "isn't connected": an invited chat has no machine to wait for.
        let bridge = AgentBridge()
        let model = model(bridge)
        let web = await webFixture(bridge, script: Self.emptyPage)
        model.openSession(invitedRow(), onSelect: { _ in XCTFail("There is no tab to open") },
                          onDismiss: { XCTFail("Keep the error visible on the list") })
        await waitForFailure(model, timeout: 5)
        XCTAssertTrue(model.openSessionError?.hasPrefix("invited-chat-closed:") == true)
        XCTAssertEqual(ConnectionDiagnosis.classify(rawError: model.openSessionError, phase: nil).hint, "Open it again from Invites.")
        withExtendedLifetime(web) {}
    }

    func testAChatThatWasNeverOpenHereIsRefusedWithoutWaiting() async {
        let model = model(AgentBridge())
        model.openSession(orphanedRow(cached: false), onSelect: { _ in XCTFail("There is no tab to open") },
                          onDismiss: { XCTFail("Keep the error visible on the list") })
        await waitForFailure(model, timeout: 0.5)
        XCTAssertTrue(model.openSessionError?.hasPrefix("machine-unavailable:") == true)
    }

    func testAnInvitedChatIsFoundOnceThePageListsItAfterStarting() async throws {
        // The page is up but lists the invited chat's tab only on its second
        // listing, as it does while restoring that tab from its pairing.
        let bridge = AgentBridge()
        let model = model(bridge)
        let web = await webFixture(bridge, script: """
            window.__ripulOpenRemoteSession = async () => ({success:false, error:'unused'});
            window.listings = 0;
            window.__ripulGetSessions = async () => (++window.listings < 2
                ? {sessions:[], activeId:null}
                : {sessions:[{id:'shared_1', sourceChatId:'shared_1', displayName:'Invite latency',
                              remoteMachineName:'Invite latency', isSharedGuest:true}], activeId:null});
            """)
        let selected = expectation(description: "Invited chat selected")
        model.openSession(invitedRow(), onSelect: { chat in
            XCTAssertEqual(chat.id, "shared_1")
            selected.fulfill()
        }, onDismiss: {})
        await fulfillment(of: [selected], timeout: 5)
        XCTAssertNil(model.openSessionError)
        withExtendedLifetime(web) {}
    }

    func testAJoinThatGetsNoAnswerIsAskedAgainOnceThePageAnswers() async {
        // The first call dies without an answer, as it does on a page that has
        // stopped answering. This used to end as WebKit's own words on screen.
        let bridge = AgentBridge()
        let web = await webFixture(bridge, script: """
            window.__ripulOpenRemoteSession = async () => ({success:false, error:'unused'});
            window.__ripulGetSessions = async () => ({sessions:[], activeId:null});
            window.joins = 0;
            window.__ripulJoinShareLink = async (token) => {
                if (++window.joins === 1) throw new Error('the page went away');
                return {ok:true, tabId:'tab-shared', label:'Shared', chatId: undefined, modelId: undefined, viewOnly:false};
            };
            """)
        let result = await bridge.joinShareLink(token: "tok")
        XCTAssertEqual(result.tabId, "tab-shared")
        XCTAssertNil(result.error)
        let joins = try? await web.evaluateJavaScript("window.joins") as? Int
        XCTAssertEqual(joins, 2)
    }

    func testRestoreWaitsForTheRequestedChatAndIgnoresRepeatedTaps() async throws {
        let bridge = AgentBridge()
        let model = model(bridge)
        model.openSessionError = "Previous failure"
        let selected = expectation(description: "Restored chat selected")
        model.openSession(row(remote: false, cached: true), onSelect: { chat in
            XCTAssertEqual(chat.id, "test-session")
            selected.fulfill()
        }, onDismiss: { XCTFail("Do not dismiss before restore") })
        XCTAssertNil(model.openSessionError)
        model.openSession(row(remote: false, cached: true), onSelect: { _ in XCTFail("Duplicate open") },
                          onDismiss: { XCTFail("Duplicate dismiss") })
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(model.openingUnifiedSessionId, "test-session")
        bridge.sessions = [ChatSession(id: "test-session", sourceChatId: "test-session",
                                      displayName: "Test chat", createdAt: Date())]
        await fulfillment(of: [selected], timeout: 2)
        XCTAssertNil(model.openingUnifiedSessionId)
        XCTAssertNil(model.openSessionError)
    }

    func testSessionFailuresAreNotMisclassifiedAsMissingMachines() {
        let missing = ConnectionDiagnosis.classify(rawError: "session-not-found: Chat not found", phase: nil)
        XCTAssertEqual(missing.summary, "This chat is no longer on its host")
        let restore = ConnectionDiagnosis.classify(rawError: "session-restore-timeout: Timed out", phase: nil)
        XCTAssertEqual(restore.summary, "This chat didn't finish restoring")
    }

    func testAnotherRowSupersedesACachedRestoreWithoutWaitingForItsTimeout() async {
        let bridge = AgentBridge()
        let model = model(bridge)
        model.openSession(row("old", remote: false, cached: true),
            onSelect: { _ in XCTFail("The superseded restore must not select") }, onDismiss: {})
        bridge.sessions = [ChatSession(id: "latest", sourceChatId: "latest", displayName: "Latest", createdAt: Date())]
        let selected = expectation(description: "Latest click takes immediately")
        model.openSession(row("latest", remote: false, cached: true), onSelect: { chat in
            XCTAssertEqual(chat.id, "latest")
            selected.fulfill()
        }, onDismiss: {})
        await fulfillment(of: [selected], timeout: 1)
        XCTAssertNil(model.openSessionError)
        XCTAssertNil(model.openingUnifiedSessionId)
    }

    func testLateRemoteOpenDoesNotSelectOrClearTheNewerNavigation() async throws {
        let bridge = AgentBridge()
        let model = model(bridge)
        let web = await webFixture(bridge, script: """
            window.pending = {};
            window.openFocus = [];
            window.__ripulOpenRemoteSession = (machine, id, title, opts) => {
                window.openFocus.push(opts.focus);
                return new Promise(resolve => { window.pending[id] = resolve; });
            };
            window.__ripulGetSessions = async () => ({sessions:[], activeId:null});
            """)
        bridge.sessions = ["old", "latest"].map {
            ChatSession(id: $0, sourceChatId: $0, displayName: $0, createdAt: Date())
        }
        model.openSession(row("old"), onSelect: { _ in XCTFail("Late open stole selection") }, onDismiss: {})
        for _ in 0..<100 {
            if (try await web.evaluateJavaScript("!!window.pending.old")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let focused = expectation(description: "Newer navigation starts")
        var finishNavigation: CheckedContinuation<Void, Never>?
        model.openSession(row("latest"), onSelect: { _ in
            focused.fulfill()
            await withCheckedContinuation { finishNavigation = $0 }
        }, onDismiss: {})
        for _ in 0..<100 {
            if (try await web.evaluateJavaScript("!!window.pending.latest")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = try await web.evaluateJavaScript("window.pending.latest({success:true,tabId:'latest'}); 0")
        await fulfillment(of: [focused], timeout: 2)
        _ = try await web.evaluateJavaScript("window.pending.old({success:true,tabId:'old'}); 0")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.openingUnifiedSessionId, "latest", "Old completion cannot clear the current spinner")
        let focusOptions = try await web.evaluateJavaScript("window.openFocus") as? [Bool]
        XCTAssertEqual(focusOptions, [false, false])
        finishNavigation?.resume()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(model.openingUnifiedSessionId)
    }

    func testABARequestsCancelTheOldNavigationEvenWhenTheIDMatchesAgain() async throws {
        let bridge = AgentBridge()
        let model = model(bridge)
        bridge.sessions = ["a", "b"].map {
            ChatSession(id: $0, sourceChatId: $0, displayName: $0, createdAt: Date())
        }
        let firstStarted = expectation(description: "First A navigation started")
        var finishFirst: CheckedContinuation<Void, Never>?
        var oldWasCancelled = false
        model.openSession(row("a", remote: false, cached: true), onSelect: { _ in
            firstStarted.fulfill()
            await withCheckedContinuation { finishFirst = $0 }
            oldWasCancelled = Task.isCancelled
        }, onDismiss: {})
        await fulfillment(of: [firstStarted], timeout: 1)
        model.openSession(row("b", remote: false, cached: true), onSelect: { _ in XCTFail("B was superseded before it started") }, onDismiss: {})
        let latestStarted = expectation(description: "Latest A navigation started")
        var finishLatest: CheckedContinuation<Void, Never>?
        model.openSession(row("a", remote: false, cached: true), onSelect: { _ in
            latestStarted.fulfill()
            await withCheckedContinuation { finishLatest = $0 }
        }, onDismiss: {})
        await fulfillment(of: [latestStarted], timeout: 1)
        finishFirst?.resume()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(oldWasCancelled)
        XCTAssertEqual(model.openingUnifiedSessionId, "a")
        finishLatest?.resume()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(model.openingUnifiedSessionId)
    }

    func testSessionFetchStartedBeforeFocusCannotRevertTheActiveChat() async throws {
        let bridge = AgentBridge()
        let web = await webFixture(bridge, script: """
            window.__ripulGetSessions = () => new Promise(resolve => { window.finishList = resolve; });
            window.__ripulFocusSession = async () => ({success:true});
            """)
        let fetch = Task { await bridge.fetchSessions() }
        for _ in 0..<100 {
            if (try await web.evaluateJavaScript("!!window.finishList")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await bridge.focusSession(id: "clicked")
        _ = try await web.evaluateJavaScript("window.finishList({sessions:[],activeId:'old'}); 0")
        await fetch.value
        XCTAssertEqual(bridge.activeSessionId, "clicked")
    }
}
