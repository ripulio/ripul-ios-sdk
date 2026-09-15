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

    private func row(remote: Bool = true, cached: Bool = false) -> UnifiedSession {
        UnifiedSession(id: "test-session", title: "Test chat", lastUsed: Date(), gitBranch: nil,
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
}
