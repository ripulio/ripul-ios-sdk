import XCTest
@testable import RipulAgent

/// Phase-2 (automation-macros): `MacroSlug.slug(from:)` turns a developer-typed
/// macro name into a valid `run_macro_<slug>` tool-name suffix. Pure string
/// logic, no UIKit.
final class MacroSlugTests: XCTestCase {
    func testLowercasesAndUnderscoresSpaces() {
        XCTAssertEqual(MacroSlug.slug(from: "Clock In"), "clock_in")
    }

    func testStripsPunctuation() {
        XCTAssertEqual(MacroSlug.slug(from: "Approve Timesheet!"), "approve_timesheet")
    }

    func testCollapsesRepeatedSeparators() {
        XCTAssertEqual(MacroSlug.slug(from: "Create  a   Workplace"), "create_a_workplace")
    }

    func testTrimsLeadingAndTrailingUnderscores() {
        XCTAssertEqual(MacroSlug.slug(from: "  Clock In  "), "clock_in")
    }

    func testPreservesNumbers() {
        XCTAssertEqual(MacroSlug.slug(from: "Step 2 Approval"), "step_2_approval")
    }
}
