import WebKit
import XCTest
@testable import RipulAgent

@MainActor
final class SessionDeletionTests: XCTestCase {
    private final class Loader: NSObject, WKNavigationDelegate {
        var completion: (() -> Void)?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { completion?() }
    }

    private func fixture(success: Bool) async -> (AgentBridge, WKWebView) {
        let bridge = AgentBridge()
        let web = WKWebView()
        let loader = Loader()
        let loaded = expectation(description: "Deletion fixture ready")
        loader.completion = { loaded.fulfill() }
        web.navigationDelegate = loader
        web.loadHTMLString("""
            <script>window.__ripulDeleteSession = async () => ({
              success: \(success ? "true" : "false"), results: [], errors: \(success ? "[]" : "['Host disconnected']")
            });</script>
            """, baseURL: nil)
        await fulfillment(of: [loaded], timeout: 10)
        bridge.attach(to: web)
        bridge.sessions = [
            ChatSession(id: "delete-target", sourceChatId: "delete-target", displayName: "Empty chat", createdAt: Date()),
            ChatSession(id: "keep-neighbour", sourceChatId: "keep-neighbour", displayName: "Other chat", createdAt: Date()),
        ]
        bridge.activeSessionId = "delete-target"
        return (bridge, web)
    }

    func testFailedDeleteKeepsNativeRowAndSelection() async {
        let (bridge, web) = await fixture(success: false)
        let result = await bridge.deleteSession(tabId: "delete-target", machineId: "host", remoteSessionId: "delete-target")
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.errors, ["Host disconnected"])
        XCTAssertEqual(bridge.sessions.map(\.id), ["delete-target", "keep-neighbour"])
        XCTAssertEqual(bridge.activeSessionId, "delete-target")
        withExtendedLifetime(web) {}
    }

    func testSuccessfulDeleteRemovesOnlyTheRequestedRow() async {
        let (bridge, web) = await fixture(success: true)
        let result = await bridge.deleteSession(tabId: "delete-target", machineId: "host", remoteSessionId: "delete-target")
        XCTAssertTrue(result.success)
        XCTAssertEqual(bridge.sessions.map(\.id), ["keep-neighbour"])
        XCTAssertEqual(bridge.activeSessionId, "keep-neighbour")
        withExtendedLifetime(web) {}
    }
}
