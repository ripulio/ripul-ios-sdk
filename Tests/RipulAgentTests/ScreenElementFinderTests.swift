import XCTest
@testable import RipulAgent

/// Phase-0 backfill (automation-macros): pins the pure predicate-matching and
/// collapse logic BEFORE the phase-0 actuation-core refactor touches the file
/// it lives in, so a red test after the refactor means the refactor broke
/// something. `ScreenElementFinder` itself is `#if canImport(UIKit)`-gated and
/// unreachable from `swift test` on macOS — these tests exercise the two
/// pieces that were extracted specifically to be UIKit-independent:
/// `ScreenElementFinder.matches(_:_:)` (predicate AND-matching over
/// `ElementFacts`, not `UIView`) and the generic core of
/// `collapseToOutermost`. See `ScreenActuationTools.swift`.
final class ScreenElementFinderTests: XCTestCase {

    // MARK: - matches(_:_:) — predicate AND-matching

    private typealias Facts = ScreenElementFinder.ElementFacts
    private typealias Query = ScreenElementFinder.Query

    func testEmptyQueryMatchesEverything() {
        let facts = Facts(id: nil, text: nil, role: nil, className: nil)
        XCTAssertTrue(ScreenElementFinder.matches(facts, Query()))
    }

    func testIdMatchesExactAndCaseInsensitive() {
        let facts = Facts(id: "Records.ClockIn", text: nil, role: nil, className: nil)
        XCTAssertTrue(ScreenElementFinder.matches(facts, Query(id: "Records.ClockIn")))
        XCTAssertTrue(ScreenElementFinder.matches(facts, Query(id: "records.clockin")))
        XCTAssertFalse(ScreenElementFinder.matches(facts, Query(id: "Records.ClockOut")))
    }

    func testIdPredicateFailsWhenFactsHaveNoId() {
        let facts = Facts(id: nil, text: "Clock In", role: "button", className: "UIButton")
        XCTAssertFalse(ScreenElementFinder.matches(facts, Query(id: "anything")))
    }

    func testTextMatchesCaseInsensitiveSubstring() {
        let facts = Facts(id: nil, text: "Clock In Now", role: nil, className: nil)
        XCTAssertTrue(ScreenElementFinder.matches(facts, Query(text: "clock in")))
        XCTAssertFalse(ScreenElementFinder.matches(facts, Query(text: "clock out")))
    }

    func testRoleMatchesCaseInsensitiveExact() {
        let facts = Facts(id: nil, text: nil, role: "button", className: nil)
        XCTAssertTrue(ScreenElementFinder.matches(facts, Query(role: "Button")))
        XCTAssertFalse(ScreenElementFinder.matches(facts, Query(role: "field")))
    }

    func testClassNameMatchesCaseInsensitiveSubstring() {
        let facts = Facts(id: nil, text: nil, role: nil, className: "WACButton")
        XCTAssertTrue(ScreenElementFinder.matches(facts, Query(className: "button")))
        XCTAssertFalse(ScreenElementFinder.matches(facts, Query(className: "textfield")))
    }

    func testPredicatesCombineWithAND() {
        let facts = Facts(id: nil, text: "Clock In", role: "button", className: "UIButton")
        // All predicates satisfied.
        XCTAssertTrue(ScreenElementFinder.matches(facts, Query(text: "Clock In", role: "button")))
        // Text matches but role doesn't — AND means the whole query fails.
        XCTAssertFalse(ScreenElementFinder.matches(facts, Query(text: "Clock In", role: "field")))
    }

    // MARK: - collapseToOutermost — generic core

    private struct Node: Equatable {
        let name: String
        /// Names of every element this node is nested inside, for the test's
        /// `isAncestor` closure to consult.
        let ancestorNames: Set<String>
    }

    private func collapse(_ nodes: [Node]) -> [Node] {
        ScreenElementFinder.collapseToOutermost(
            nodes,
            isSame: { $0.name == $1.name },
            isAncestor: { ancestor, descendant in descendant.ancestorNames.contains(ancestor.name) }
        )
    }

    /// The regression this backfill exists to catch: a button and the label
    /// inside it both match a query. The OUTER element (the button, the
    /// container the actuation ladder needs — path 1 fires on the UIControl,
    /// not the label) must survive; the inner label must be dropped. Written
    /// against the intended behavior BEFORE the phase-0 refactor lands, so it
    /// pins the fix rather than merely describing the code as found.
    func testNestedDuplicateCollapsesToTheOutermostContainer() {
        let button = Node(name: "button", ancestorNames: [])
        let label = Node(name: "label", ancestorNames: ["button"])
        let survivors = collapse([button, label])
        XCTAssertEqual(survivors, [button])
    }

    func testDisjointMatchesBothSurvive() {
        let rowA = Node(name: "rowA", ancestorNames: [])
        let rowB = Node(name: "rowB", ancestorNames: [])
        let survivors = collapse([rowA, rowB])
        XCTAssertEqual(Set(survivors.map(\.name)), ["rowA", "rowB"])
    }

    func testThreeLevelNestingKeepsOnlyTheOutermost() {
        let container = Node(name: "container", ancestorNames: [])
        let row = Node(name: "row", ancestorNames: ["container"])
        let button = Node(name: "button", ancestorNames: ["container", "row"])
        let survivors = collapse([container, row, button])
        XCTAssertEqual(survivors, [container])
    }

    func testCollapseIsANoOpOnASingleElement() {
        let solo = Node(name: "solo", ancestorNames: [])
        XCTAssertEqual(collapse([solo]), [solo])
    }
}
