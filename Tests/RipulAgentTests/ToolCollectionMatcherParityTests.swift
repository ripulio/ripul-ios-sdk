import XCTest
@testable import RipulAgent

/// Matcher-mirror parity (native-tool-registry phase 4 §2).
///
/// `RipulToolCollectionMatcher` mirrors the web app's `CategoryToolMatcher.ts`;
/// since phase 4, collection membership also feeds enforcement (`group://`
/// expansion in a context's `includedTools`), so drift here misleads the
/// developer about what a context will actually allow.
///
/// The fixture is duplicated byte-for-byte in the web side's
/// `packages/api/src/toolCollections/__tests__/matcherParity.test.ts`; both
/// sides must report the identical membership set. If you change one, change
/// both.
final class ToolCollectionMatcherParityTests: XCTestCase {
    // ---- shared fixture (mirrored in matcherParity.test.ts) ----
    private let explicitTools = ["get_events", "group://other", "absent_tool"]
    private let toolPatterns = ["^calendar_", "(unclosed"]
    private let toolNames = ["get_events", "calendar_list", "calendar_add", "unrelated_tool", "calendar_list"]
    private let expectedMembers = ["get_events", "calendar_list", "calendar_add"]
    // ------------------------------------------------------------

    func testReportsExactlyTheSharedExpectedMembership() {
        let matcher = RipulToolCollectionMatcher(
            explicitTools: explicitTools,
            toolPatterns: toolPatterns,
            toolNames: toolNames
        )

        XCTAssertEqual(Set(matcher.presentMatches), Set(expectedMembers))
        // Pins the Swift-specific reporting too, so a semantics change is loud.
        XCTAssertEqual(matcher.explicitMatches, ["get_events"])
        XCTAssertEqual(matcher.patternMatches, ["calendar_list", "calendar_add"])
        XCTAssertEqual(matcher.absentMembers, ["absent_tool"])
        XCTAssertEqual(matcher.invalidPatterns.count, 1)
        XCTAssertEqual(matcher.invalidPatterns.first?.pattern, "(unclosed")
    }
}
