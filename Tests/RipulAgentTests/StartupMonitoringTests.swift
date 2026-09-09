import XCTest
import WebKit
@testable import RipulAgent

final class StartupMonitoringTests: XCTestCase {
    @MainActor
    func testBridgeConnectionStillWaitsForReturningUsersToken() async {
        let bridge = AgentBridge()
        var auth: String? = "unknown"
        bridge.startupAuthenticationState = { auth }
        bridge.beginStartupMonitoring()
        let start = ProcessInfo.processInfo.systemUptime
        bridge.isConnected = true
        bridge.updateStartupMonitoring(at: start, isActive: true)
        XCTAssertEqual(bridge.startupLoadState.message, "Signing in…")

        bridge.updateStartupMonitoring(at: start + 20, isActive: true)
        XCTAssertNil(bridge.loadError)
        XCTAssertTrue(bridge.startupLoadState.isTakingLonger)
        auth = "alive"
        bridge.updateStartupMonitoring(at: start + 25, isActive: true)
        XCTAssertEqual(bridge.startupLoadState.message, "Restoring your session…")
        bridge.updateStartupMonitoring(at: start + 54, isActive: true)
        XCTAssertNil(bridge.loadError)
        bridge.updateStartupMonitoring(at: start + 55, isActive: true)
        XCTAssertEqual(bridge.loadError, "Signing in didn’t complete")

        // A late token heals the timeout without requiring a reload.
        auth = nil
        bridge.updateStartupMonitoring(at: start + 56, isActive: true)
        XCTAssertNil(bridge.loadError)
        XCTAssertNil(bridge.loadErrorDetails)
        XCTAssertEqual(bridge.startupLoadState.message, "Ready")
    }

    @MainActor
    func testResourcesExtendStartupAndRetryResetsDeadline() async {
        let bridge = AgentBridge()
        bridge.beginStartupMonitoring()
        let start = ProcessInfo.processInfo.systemUptime
        bridge.updateStartupMonitoring(at: start, isActive: true)
        bridge.updateStartupMonitoring(at: start + 20, isActive: true)
        bridge.recordStartupProgress()
        bridge.updateStartupMonitoring(at: start + 40, isActive: true)
        XCTAssertNil(bridge.loadError)
        bridge.updateStartupMonitoring(at: start + 50, isActive: true)
        XCTAssertNotNil(bridge.loadError)

        bridge.beginStartupMonitoring()
        let retry = ProcessInfo.processInfo.systemUptime
        bridge.updateStartupMonitoring(at: retry, isActive: true)
        bridge.updateStartupMonitoring(at: retry + 20, isActive: true)
        XCTAssertNil(bridge.loadError)
    }

    @MainActor
    func testNavigationDoesNotResetOverallStartupBudget() async {
        let bridge = AgentBridge()
        bridge.beginStartupMonitoring()
        let start = ProcessInfo.processInfo.systemUptime
        bridge.updateStartupMonitoring(at: start, isActive: true)
        for offset in stride(from: 20, through: 100, by: 20) {
            bridge.updateStartupMonitoring(at: start + Double(offset), isActive: true)
            bridge.pageDidStartLoading()
            XCTAssertNil(bridge.loadError)
        }
        bridge.updateStartupMonitoring(at: start + 120, isActive: true)
        XCTAssertTrue(bridge.loadErrorDetails?.contains("2-minute") == true)
    }

    @MainActor
    func testRealLoadErrorsAreNotReplacedByWatchdog() async {
        let bridge = AgentBridge()
        bridge.beginStartupMonitoring()
        let start = ProcessInfo.processInfo.systemUptime
        bridge.updateStartupMonitoring(at: start, isActive: true)
        bridge.loadError = "No internet connection"
        bridge.loadErrorDetails = "The internet connection appears to be offline."
        bridge.updateStartupMonitoring(at: start + 40, isActive: true)
        XCTAssertEqual(bridge.loadError, "No internet connection")
    }
}
