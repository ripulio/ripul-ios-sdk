import XCTest
@testable import RipulAgent

/// How a chat shows thinking follows the web's `showThinking` setting.
@MainActor
final class ThinkingDisplayModeTests: XCTestCase {

    /// Read as the web's `normalizeThinkingMode` reads it: anything it does
    /// not know is its default, open.
    func testSettingReadsAsTheWebReadsIt() {
        XCTAssertEqual(ThinkingDisplayMode(setting: "none"), .none)
        XCTAssertEqual(ThinkingDisplayMode(setting: "folded"), .folded)
        XCTAssertEqual(ThinkingDisplayMode(setting: "open"), .open)
        XCTAssertEqual(ThinkingDisplayMode(setting: nil), .open)
        XCTAssertEqual(ThinkingDisplayMode(setting: "full"), .open)
        XCTAssertEqual(ThinkingDisplayMode(setting: ""), .open)
    }

    /// Before the page answers, a chat draws thinking open, the web's default.
    func testStartsAtTheWebDefault() {
        XCTAssertEqual(NavigationStore().thinkingDisplayMode, .open)
        XCTAssertEqual(AgentBridge().showThinkingMode, "open")
    }

    /// The last answer the page gave is drawn from the first frame of the next
    /// launch; a value the page would never give is not.
    func testRemembersTheLastSettingAcrossLaunches() {
        let suite = "io.ripul.tests.thinking.\(UUID().uuidString)"
        let cache = UserDefaultsSessionCache(suiteName: suite)
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        cache.set("folded", forKey: "ripul.showThinkingMode")
        let bridge = AgentBridge()
        bridge.sessionCache = cache
        XCTAssertEqual(bridge.showThinkingMode, "folded")

        cache.set("full", forKey: "ripul.showThinkingMode")
        let other = AgentBridge()
        other.sessionCache = cache
        XCTAssertEqual(other.showThinkingMode, "open")
    }
}
