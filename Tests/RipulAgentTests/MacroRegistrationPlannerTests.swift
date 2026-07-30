import XCTest
@testable import RipulAgent

/// Phase-4 (automation-macros): `MacroRegistrationPlanner`'s dedup + publish
/// partition — pure `RipulMacro` in/out, no `MacroTool`/UIKit, so testable
/// under plain `swift test`.
final class MacroRegistrationPlannerTests: XCTestCase {

    private func macro(id: String, name: String, published: Bool, updatedAt: Date) -> RipulMacro {
        RipulMacro(id: id, name: name, description: "d", steps: [], published: published,
                  createdAt: updatedAt, updatedAt: updatedAt)
    }

    // MARK: - dedupByName

    func testDedupKeepsTheNewerOfTwoSameNameMacros() {
        let older = macro(id: "a", name: "clock_in", published: false, updatedAt: Date(timeIntervalSince1970: 100))
        let newer = macro(id: "b", name: "clock_in", published: false, updatedAt: Date(timeIntervalSince1970: 200))
        let result = MacroRegistrationPlanner.dedupByName([older, newer])
        XCTAssertEqual(result.map(\.id), ["b"])
    }

    func testDedupIsOrderIndependent() {
        let older = macro(id: "a", name: "clock_in", published: false, updatedAt: Date(timeIntervalSince1970: 100))
        let newer = macro(id: "b", name: "clock_in", published: false, updatedAt: Date(timeIntervalSince1970: 200))
        let result = MacroRegistrationPlanner.dedupByName([newer, older])
        XCTAssertEqual(result.map(\.id), ["b"])
    }

    func testDedupLeavesDistinctNamesUntouched() {
        let a = macro(id: "a", name: "clock_in", published: false, updatedAt: Date())
        let b = macro(id: "b", name: "clock_out", published: false, updatedAt: Date())
        let result = MacroRegistrationPlanner.dedupByName([a, b])
        XCTAssertEqual(Set(result.map(\.id)), ["a", "b"])
    }

    // MARK: - plan (dedup + publish partition)

    func testPlanPartitionsByPublished() {
        let draft = macro(id: "a", name: "draft_one", published: false, updatedAt: Date())
        let live = macro(id: "b", name: "live_one", published: true, updatedAt: Date())
        let plan = MacroRegistrationPlanner.plan([draft, live])
        XCTAssertEqual(plan.developer.map(\.id), ["a"])
        XCTAssertEqual(plan.endUser.map(\.id), ["b"])
    }

    /// The incumbent pin (self-testing.md's standing rule): an unpublished
    /// macro must stay OUT of endUser even across repeated planning calls —
    /// not just once. Regression-pins the exact failure mode this plan
    /// exists to prevent (a draft macro silently reaching real end users).
    func testUnpublishedMacroNeverAppearsInEndUserAcrossRepeatedCalls() {
        let draft = macro(id: "a", name: "draft_one", published: false, updatedAt: Date())
        for _ in 0..<5 {
            let plan = MacroRegistrationPlanner.plan([draft])
            XCTAssertTrue(plan.endUser.isEmpty)
            XCTAssertEqual(plan.developer.map(\.id), ["a"])
        }
    }

    func testPublishingFlipsWhichPartitionAMacroLandsIn() {
        let id = "a"
        let name = "clock_in"
        let draftPlan = MacroRegistrationPlanner.plan([macro(id: id, name: name, published: false, updatedAt: Date())])
        XCTAssertEqual(draftPlan.developer.map(\.id), [id])
        XCTAssertTrue(draftPlan.endUser.isEmpty)

        let publishedPlan = MacroRegistrationPlanner.plan([macro(id: id, name: name, published: true, updatedAt: Date())])
        XCTAssertTrue(publishedPlan.developer.isEmpty)
        XCTAssertEqual(publishedPlan.endUser.map(\.id), [id])
    }
}
