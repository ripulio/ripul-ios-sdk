import XCTest
import WebKit
@testable import RipulAgent

final class WebContentTerminationDelegateTests: XCTestCase {
    @MainActor
    func testWebKitCanDispatchProcessTerminationToTheRealCoordinator() {
        // This optional delegate callback must be exposed under WebKit's
        // selector. A similarly named Swift method compiles but never runs.
        XCTAssertTrue(AgentWebView.Coordinator.instancesRespond(
            to: #selector(WKNavigationDelegate.webViewWebContentProcessDidTerminate(_:))))
    }

    @MainActor
    func testReasonCallbackIsAvailableOnlyInDeveloperBuilds() {
        let selector = NSSelectorFromString("_webView:webContentProcessDidTerminateWithReason:")
        #if DEBUG || RIPUL_DEVELOPER_BUILD
        XCTAssertTrue(AgentWebView.Coordinator.instancesRespond(to: selector))
        #else
        XCTAssertFalse(AgentWebView.Coordinator.instancesRespond(to: selector))
        #endif
    }
}
