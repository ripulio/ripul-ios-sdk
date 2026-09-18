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
        let failed = expectation(description: "Failure is published")
        let subscription = model.$openSessionError.compactMap { $0 }.prefix(1).sink { _ in failed.fulfill() }
        await fulfillment(of: [failed], timeout: timeout)
        withExtendedLifetime(subscription) {}
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
