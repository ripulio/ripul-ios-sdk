import XCTest
@testable import RipulAgent

/// Phase-1 (automation-macros): pins `MacroReplayEngine`'s control flow —
/// sequencing, `{{param}}` substitution, stop-on-first-failure — against a
/// fake `MacroElementResolving` conformance with NO UIKit dependency
/// whatsoever (`FakeElement` is a plain enum case). This is the whole point
/// of phase 0's resolver seam: the engine itself never mentions `UIView`, so
/// this suite runs on plain `swift test` and exercises the exact same code
/// path `MacroTool.execute` uses at runtime, just with `LiveScreenResolver`
/// swapped for a scripted fake.
@MainActor
final class MacroReplayEngineTests: XCTestCase {

    /// An opaque "resolved something" marker — carries just enough for
    /// assertions (which selector resolved to it) without any UI concept.
    struct FakeElement: Equatable {
        let selectorId: String?
    }

    /// Scripts resolution and actuation outcomes per call, and records every
    /// call it received so tests can assert what the engine actually did
    /// (including that it STOPPED — later steps must never be called after a
    /// failure).
    final class FakeResolver: MacroElementResolving {
        /// Selector id → whether resolution should succeed. Missing id = fail.
        var resolvable: Set<String> = []
        /// Selector id → whether performTap/performType should report success.
        var actuationFails: Set<String> = []
        private(set) var resolveTapCalls: [String?] = []
        private(set) var performTapCalls: [String?] = []
        private(set) var performTypeCalls: [(id: String?, text: String)] = []

        func resolveTap(_ selector: MacroSelector) -> FakeElement? {
            resolveTapCalls.append(selector.id)
            guard let id = selector.id, resolvable.contains(id) else { return nil }
            return FakeElement(selectorId: id)
        }

        func resolveScrollView(_ selector: MacroSelector) -> FakeElement? {
            resolveTap(selector)
        }

        func performTap(_ element: FakeElement, matchId: String?, matchText: String?) -> (success: Bool, error: String?) {
            performTapCalls.append(element.selectorId)
            if let id = element.selectorId, actuationFails.contains(id) {
                return (false, "fake actuation failure for \(id)")
            }
            return (true, nil)
        }

        func performType(_ element: FakeElement, text: String, append: Bool) -> (success: Bool, error: String?) {
            performTypeCalls.append((element.selectorId, text))
            if let id = element.selectorId, actuationFails.contains(id) {
                return (false, "fake actuation failure for \(id)")
            }
            return (true, nil)
        }

        func performScroll(_ element: FakeElement, direction: String, amount: Double) -> Bool {
            true
        }
    }

    private func tapStep(_ id: String, label: String? = nil) -> MacroStep {
        MacroStep(kind: .tap, selector: MacroSelector(id: id), recordedLabel: label ?? "Tap \(id)")
    }

    private func typeStep(_ id: String, text: String) -> MacroStep {
        MacroStep(kind: .type, selector: MacroSelector(id: id), text: text, recordedLabel: "Type into \(id)")
    }

    private func macro(steps: [MacroStep], parameters: [MacroParameter] = []) -> RipulMacro {
        RipulMacro(id: "m1", name: "test_macro", description: "d", steps: steps,
                  parameters: parameters, createdAt: Date(), updatedAt: Date())
    }

    // MARK: - All steps succeed

    func testAllStepsSucceedInOrder() async {
        let resolver = FakeResolver()
        resolver.resolvable = ["a", "b", "c"]
        let result = await MacroReplayEngine.replay(
            macro(steps: [tapStep("a"), tapStep("b"), tapStep("c")]),
            parameters: [:], resolver: resolver)

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.completedSteps, 3)
        XCTAssertEqual(result.totalSteps, 3)
        XCTAssertNil(result.failedStepIndex)
        XCTAssertEqual(resolver.performTapCalls, ["a", "b", "c"])
    }

    // MARK: - Stop on first failure

    func testStopsAtFirstUnresolvableStepAndNeverCallsLaterSteps() async {
        let resolver = FakeResolver()
        resolver.resolvable = ["a"] // "b" is never resolvable
        let result = await MacroReplayEngine.replay(
            macro(steps: [tapStep("a"), tapStep("b"), tapStep("c")]),
            parameters: [:], resolver: resolver, resolutionTimeout: 0.3)

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.failedStepIndex, 1)
        XCTAssertEqual(result.completedSteps, 1)
        // Step "a" acted; "c" must NEVER have been attempted.
        XCTAssertEqual(resolver.performTapCalls, ["a"])
        XCTAssertNotNil(result.error)
    }

    func testStopsAtFirstActuationFailureEvenWhenResolvable() async {
        let resolver = FakeResolver()
        resolver.resolvable = ["a", "b", "c"]
        resolver.actuationFails = ["b"] // resolves fine, but the tap itself fails
        let result = await MacroReplayEngine.replay(
            macro(steps: [tapStep("a"), tapStep("b"), tapStep("c")]),
            parameters: [:], resolver: resolver)

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.failedStepIndex, 1)
        XCTAssertEqual(resolver.performTapCalls, ["a", "b"])
    }

    // MARK: - Parameter substitution

    func testTypeStepSubstitutesParameterBeforeActing() async {
        let resolver = FakeResolver()
        resolver.resolvable = ["field"]
        _ = await MacroReplayEngine.replay(
            macro(steps: [typeStep("field", text: "Note: {{note}}")], parameters: [MacroParameter(name: "note", description: "d")]),
            parameters: ["note": "started shift"], resolver: resolver)

        XCTAssertEqual(resolver.performTypeCalls.count, 1)
        XCTAssertEqual(resolver.performTypeCalls.first?.text, "Note: started shift")
    }

    func testMissingParameterLeavesTokenLiteralRatherThanFailing() async {
        let resolver = FakeResolver()
        resolver.resolvable = ["field"]
        let result = await MacroReplayEngine.replay(
            macro(steps: [typeStep("field", text: "{{missing}}")]),
            parameters: [:], resolver: resolver)

        // Substitution never fails the step — the literal token is what
        // visibly gets typed, so the malformed macro fails loudly at the
        // point of use, not silently here.
        XCTAssertTrue(result.success)
        XCTAssertEqual(resolver.performTypeCalls.first?.text, "{{missing}}")
    }

    // MARK: - Empty macro

    func testEmptyMacroSucceedsTrivially() async {
        let resolver = FakeResolver()
        let result = await MacroReplayEngine.replay(macro(steps: []), parameters: [:], resolver: resolver)
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.completedSteps, 0)
        XCTAssertEqual(result.totalSteps, 0)
    }
}
