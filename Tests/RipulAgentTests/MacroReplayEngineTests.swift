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
        /// Selector id → ambiguity count to report instead of resolving.
        var ambiguous: [String: Int] = [:]
        /// Selector id → whether performTap/performType should report success.
        var actuationFails: Set<String> = []
        /// The `via` string successful taps report — mirrors LiveScreenResolver
        /// forwarding ScreenActuationEngine's real actuation path.
        var tapVia: String? = nil
        private(set) var resolveTapCalls: [String?] = []
        private(set) var performTapCalls: [String?] = []
        private(set) var performTypeCalls: [(id: String?, text: String)] = []

        func resolveTap(_ selector: MacroSelector) -> MacroResolution<FakeElement> {
            resolveTapCalls.append(selector.id)
            if let id = selector.id, let count = ambiguous[id] { return .ambiguous(count: count) }
            guard let id = selector.id, resolvable.contains(id) else { return .notFound }
            return .resolved(FakeElement(selectorId: id))
        }

        func resolveScrollView(_ selector: MacroSelector) -> MacroResolution<FakeElement> {
            resolveTap(selector)
        }

        func performTap(_ element: FakeElement, matchId: String?, matchText: String?) -> (success: Bool, error: String?) {
            performTapCalls.append(element.selectorId)
            if let id = element.selectorId, actuationFails.contains(id) {
                return (false, "fake actuation failure for \(id)")
            }
            return (true, nil)
        }

        func performTapDetailed(_ element: FakeElement, matchId: String?, matchText: String?) -> (success: Bool, via: String?, error: String?) {
            performTapCalls.append(element.selectorId)
            if let id = element.selectorId, actuationFails.contains(id) {
                return (false, nil, "fake actuation failure for \(id)")
            }
            return (true, tapVia, nil)
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

        func describe(_ element: FakeElement) -> String? {
            "FakeElement(\(element.selectorId ?? "?"))"
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

    func testAllStepsSucceedInOrder() async throws {
        let resolver = FakeResolver()
        resolver.resolvable = ["a", "b", "c"]
        let result = try await MacroReplayEngine.replay(
            macro(steps: [tapStep("a"), tapStep("b"), tapStep("c")]),
            parameters: [:], resolver: resolver)

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.completedSteps, 3)
        XCTAssertEqual(result.totalSteps, 3)
        XCTAssertNil(result.failedStepIndex)
        XCTAssertEqual(resolver.performTapCalls, ["a", "b", "c"])
    }

    // MARK: - Stop on first failure

    func testStopsAtFirstUnresolvableStepAndNeverCallsLaterSteps() async throws {
        let resolver = FakeResolver()
        resolver.resolvable = ["a"] // "b" is never resolvable
        let result = try await MacroReplayEngine.replay(
            macro(steps: [tapStep("a"), tapStep("b"), tapStep("c")]),
            parameters: [:], resolver: resolver, resolutionTimeout: 0.3)

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.failedStepIndex, 1)
        XCTAssertEqual(result.completedSteps, 1)
        // Step "a" acted; "c" must NEVER have been attempted.
        XCTAssertEqual(resolver.performTapCalls, ["a"])
        XCTAssertNotNil(result.error)
    }

    func testStopsAtFirstActuationFailureEvenWhenResolvable() async throws {
        let resolver = FakeResolver()
        resolver.resolvable = ["a", "b", "c"]
        resolver.actuationFails = ["b"] // resolves fine, but the tap itself fails
        let result = try await MacroReplayEngine.replay(
            macro(steps: [tapStep("a"), tapStep("b"), tapStep("c")]),
            parameters: [:], resolver: resolver)

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.failedStepIndex, 1)
        XCTAssertEqual(resolver.performTapCalls, ["a", "b"])
    }

    // MARK: - Parameter substitution

    func testTypeStepSubstitutesParameterBeforeActing() async throws {
        let resolver = FakeResolver()
        resolver.resolvable = ["field"]
        _ = try await MacroReplayEngine.replay(
            macro(steps: [typeStep("field", text: "Note: {{note}}")], parameters: [MacroParameter(name: "note", description: "d")]),
            parameters: ["note": "started shift"], resolver: resolver)

        XCTAssertEqual(resolver.performTypeCalls.count, 1)
        XCTAssertEqual(resolver.performTypeCalls.first?.text, "Note: started shift")
    }

    func testMissingParameterLeavesTokenLiteralRatherThanFailing() async throws {
        let resolver = FakeResolver()
        resolver.resolvable = ["field"]
        let result = try await MacroReplayEngine.replay(
            macro(steps: [typeStep("field", text: "{{missing}}")]),
            parameters: [:], resolver: resolver)

        // Substitution never fails the step — the literal token is what
        // visibly gets typed, so the malformed macro fails loudly at the
        // point of use, not silently here.
        XCTAssertTrue(result.success)
        XCTAssertEqual(resolver.performTypeCalls.first?.text, "{{missing}}")
    }

    // MARK: - Empty macro

    func testEmptyMacroSucceedsTrivially() async throws {
        let resolver = FakeResolver()
        let result = try await MacroReplayEngine.replay(macro(steps: []), parameters: [:], resolver: resolver)
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.completedSteps, 0)
        XCTAssertEqual(result.totalSteps, 0)
    }

    // MARK: - Per-step results + live progress events

    func testStepResultsRecordEveryAttemptedStepInOrder() async throws {
        let resolver = FakeResolver()
        resolver.resolvable = ["a", "b", "c"]
        resolver.tapVia = "fakePath"
        let result = try await MacroReplayEngine.replay(
            macro(steps: [tapStep("a", label: "Tap A"), tapStep("b", label: "Tap B"), tapStep("c", label: "Tap C")]),
            parameters: [:], resolver: resolver)

        XCTAssertEqual(result.stepResults.count, 3)
        XCTAssertEqual(result.stepResults.map(\.index), [0, 1, 2])
        XCTAssertEqual(result.stepResults.map(\.label), ["Tap A", "Tap B", "Tap C"])
        XCTAssertTrue(result.stepResults.allSatisfy(\.succeeded))
        XCTAssertEqual(result.stepResults.first?.via, "fakePath")
    }

    func testStepResultsStopAtTheFailedStepAndCarryItsError() async throws {
        let resolver = FakeResolver()
        resolver.resolvable = ["a", "b", "c"]
        resolver.actuationFails = ["b"]
        let result = try await MacroReplayEngine.replay(
            macro(steps: [tapStep("a"), tapStep("b"), tapStep("c")]),
            parameters: [:], resolver: resolver)

        // Steps up to and INCLUDING the failure are recorded; step "c" is absent.
        XCTAssertEqual(result.stepResults.map(\.index), [0, 1])
        XCTAssertTrue(result.stepResults[0].succeeded)
        XCTAssertFalse(result.stepResults[1].succeeded)
        XCTAssertNotNil(result.stepResults[1].error)
    }

    func testProgressEventsFireStartedThenSucceededPerStep() async throws {
        let resolver = FakeResolver()
        resolver.resolvable = ["a", "b"]
        var events: [MacroStepEvent] = []
        _ = try await MacroReplayEngine.replay(
            macro(steps: [tapStep("a"), tapStep("b")]),
            parameters: [:], resolver: resolver,
            onStepProgress: { events.append($0) })

        XCTAssertEqual(events.count, 4)
        XCTAssertEqual(events.map(\.index), [0, 0, 1, 1])
        XCTAssertEqual(events[0].phase, .started)
        guard case .succeeded(let via, _, _) = events[1].phase else {
            XCTFail("expected .succeeded, got \(events[1].phase)"); return
        }
        XCTAssertNil(via)
        XCTAssertEqual(events[2].phase, .started)
        guard case .succeeded = events[3].phase else {
            XCTFail("expected .succeeded, got \(events[3].phase)"); return
        }
    }

    func testProgressEventsCarryTheFailureOnTheFailedStep() async throws {
        let resolver = FakeResolver()
        resolver.resolvable = ["a", "b"]
        resolver.actuationFails = ["b"]
        var events: [MacroStepEvent] = []
        _ = try await MacroReplayEngine.replay(
            macro(steps: [tapStep("a"), tapStep("b")]),
            parameters: [:], resolver: resolver,
            onStepProgress: { events.append($0) })

        XCTAssertEqual(events.count, 4)
        guard case .failed(let error, _, _) = events[3].phase else {
            XCTFail("expected the final event to be .failed, got \(events[3].phase)")
            return
        }
        XCTAssertNotNil(error)
    }

    // MARK: - Ambiguity is reported distinctly from not-found

    func testAmbiguousMatchReportsTheCountInsteadOfGenericNotResolved() async throws {
        let resolver = FakeResolver()
        resolver.ambiguous["tab"] = 5
        let result = try await MacroReplayEngine.replay(
            macro(steps: [tapStep("tab", label: "Tap _UITabButton")]),
            parameters: [:], resolver: resolver, resolutionTimeout: 0.3)

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.failedStepIndex, 0)
        XCTAssertEqual(result.error, "'Tap _UITabButton' matched 5 elements — ambiguous (needs an nth or a within anchor to pick one).")
        // Ambiguity must never become an actuation: nothing was pressed.
        XCTAssertTrue(resolver.performTapCalls.isEmpty)
    }

    // MARK: - Resolved detail + timing land in step results

    func testStepResultsCarryResolvedDetailAndTiming() async throws {
        let resolver = FakeResolver()
        resolver.resolvable = ["a"]
        let result = try await MacroReplayEngine.replay(
            macro(steps: [tapStep("a")]),
            parameters: [:], resolver: resolver)

        XCTAssertEqual(result.stepResults.count, 1)
        XCTAssertEqual(result.stepResults[0].resolvedDetail, "FakeElement(a)")
        XCTAssertGreaterThanOrEqual(result.stepResults[0].durationMs, 0)
        XCTAssertGreaterThanOrEqual(result.stepResults[0].resolveMs, 0)
    }

    func testFailedResolutionHasNoDetail() async throws {
        let resolver = FakeResolver() // nothing resolvable
        let result = try await MacroReplayEngine.replay(
            macro(steps: [tapStep("missing")]),
            parameters: [:], resolver: resolver, resolutionTimeout: 0.3)

        XCTAssertEqual(result.stepResults.count, 1)
        XCTAssertNil(result.stepResults[0].resolvedDetail)
    }

    // MARK: - compactSummary (replay-log selector line)

    func testCompactSummaryOmitsUnsetPredicates() {
        XCTAssertEqual(MacroSelector(id: "records.tab").compactSummary, "id=records.tab")
        XCTAssertEqual(MacroSelector(text: "Records", role: "button", className: "_UITabButton", nth: 1).compactSummary,
                       "text='Records' role=button class=_UITabButton nth=1")
        XCTAssertEqual(MacroSelector().compactSummary, "")
    }
}
