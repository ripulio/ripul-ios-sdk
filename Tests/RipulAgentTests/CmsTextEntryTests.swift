import XCTest
@testable import RipulAgent

/// The `textEntry` block's rules, held to the web's TextEntryBlock.tsx.
final class CmsTextEntryTests: XCTestCase {
    func testAFilterPublishesItsTrimmedValueOrNothing() {
        XCTAssertEqual(CmsTextEntry.output("  kfc ", bound: false), [["value": .string("kfc")]])
        XCTAssertEqual(CmsTextEntry.output("   ", bound: false), [])
        XCTAssertEqual(CmsTextEntry.output("", bound: false), [])
    }

    func testABoundFieldPublishesItsValueAsTypedEvenEmpty() {
        XCTAssertEqual(CmsTextEntry.output(" Jo ", bound: true), [["value": .string(" Jo ")]])
        XCTAssertEqual(CmsTextEntry.output("", bound: true), [["value": .string("")]])
    }

    func testPropsAndBinding() {
        let filter = CmsTextEntry.Props(["label": .string("Search customers")])
        XCTAssertEqual(filter.placeholder, "Type to filter…")
        XCTAssertFalse(filter.isBound)
        // Both halves are needed to bind, as on the web.
        XCTAssertFalse(CmsTextEntry.Props(["bindQuerySlug": .string("q")]).isBound)
        XCTAssertFalse(CmsTextEntry.Props(["bindQuerySlug": .string("q"), "bindColumn": .string("")]).isBound)
        XCTAssertTrue(CmsTextEntry.Props(["bindQuerySlug": .string("q"), "bindColumn": .string("name")]).isBound)
    }

    func testPrefillReadsTheColumnAsText() {
        XCTAssertEqual(CmsTextEntry.prefill(["n": .number(12)], column: "n"), "12")
        XCTAssertEqual(CmsTextEntry.prefill(["n": .null], column: "n"), "")
        XCTAssertEqual(CmsTextEntry.prefill(nil, column: "n"), "")
    }
}
