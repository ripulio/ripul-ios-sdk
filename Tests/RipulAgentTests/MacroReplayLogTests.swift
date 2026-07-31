import XCTest
@testable import RipulAgent

/// The copy-log builder — the transcript a user pastes back when a replay
/// misbehaves: per-step action (via + duration), selector summary, matched
/// element, and the outcome line with total wall-clock.
final class MacroReplayLogTests: XCTestCase {

    private func step(_ label: String, index: Int, succeeded: Bool, via: String? = nil,
                      error: String? = nil, detail: String? = nil, durationMs: Int = 100) -> MacroStepResult {
        MacroStepResult(index: index, label: label, succeeded: succeeded, via: via, error: error,
                        resolvedDetail: detail, resolveMs: 0, durationMs: durationMs)
    }

    private func macro(name: String = "clock_in", steps: [MacroStep], parameters: [MacroParameter] = []) -> RipulMacro {
        RipulMacro(id: "m", name: name, description: "d", steps: steps, parameters: parameters,
                  createdAt: Date(), updatedAt: Date())
    }

    func testSuccessfulRunLogsViaSelectorMatchedAndTotal() {
        let m = macro(steps: [MacroStep(kind: .tap, selector: MacroSelector(id: "records.tab"), recordedLabel: "Tap Records")])
        let outcome = MacroReplayResult(success: true, completedSteps: 1, totalSteps: 1,
                                        failedStepIndex: nil, error: nil,
                                        stepResults: [step("Tap Records", index: 0, succeeded: true, via: "uicontrol",
                                                           detail: "_UITabButton [records.tab] \"Records\" @(100,877 88×54)",
                                                           durationMs: 240)])
        let log = MacroReplayLog.text(macro: m, paramValues: [:], outcome: outcome)
        XCTAssertTrue(log.contains("✓ 1. Tap Records — via uicontrol · 240ms"))
        XCTAssertTrue(log.contains("selector: id=records.tab"))
        XCTAssertTrue(log.contains("matched: _UITabButton [records.tab] \"Records\" @(100,877 88×54)"))
        XCTAssertTrue(log.contains("Outcome: all 1 steps completed in 240ms."))
    }

    func testFailedRunLogsTheErrorAndStopPoint() {
        let m = macro(steps: [
            MacroStep(kind: .tap, selector: MacroSelector(id: "a"), recordedLabel: "Tap A"),
            MacroStep(kind: .tap, selector: MacroSelector(text: "Confirm"), recordedLabel: "Tap Confirm"),
        ])
        let outcome = MacroReplayResult(success: false, completedSteps: 1, totalSteps: 2,
                                        failedStepIndex: 1, error: "Could not resolve 'Tap Confirm' within 5s.",
                                        stepResults: [
                                            step("Tap A", index: 0, succeeded: true, via: "uicontrol", durationMs: 100),
                                            step("Tap Confirm", index: 1, succeeded: false,
                                                 error: "Could not resolve 'Tap Confirm' within 5s.", durationMs: 5000),
                                        ])
        let log = MacroReplayLog.text(macro: m, paramValues: [:], outcome: outcome)
        XCTAssertTrue(log.contains("✗ 2. Tap Confirm — Could not resolve 'Tap Confirm' within 5s. · 5.0s"))
        XCTAssertTrue(log.contains("Outcome: stopped at step 2 of 2 — Could not resolve 'Tap Confirm' within 5s."))
    }

    func testParametersAreLoggedWithValues() {
        let m = macro(steps: [MacroStep(kind: .type, selector: MacroSelector(role: "field"), text: "{{note}}", recordedLabel: "Type note")],
                      parameters: [MacroParameter(name: "note", description: "Shift note")])
        let outcome = MacroReplayResult(success: true, completedSteps: 1, totalSteps: 1,
                                        failedStepIndex: nil, error: nil,
                                        stepResults: [step("Type note", index: 0, succeeded: true)])
        let log = MacroReplayLog.text(macro: m, paramValues: ["note": "started shift"], outcome: outcome)
        XCTAssertTrue(log.contains("note = \"started shift\""))
    }

    func testFormatMsChoosesUnits() {
        XCTAssertEqual(MacroReplayLog.formatMs(240), "240ms")
        XCTAssertEqual(MacroReplayLog.formatMs(1200), "1.2s")
        XCTAssertEqual(MacroReplayLog.formatMs(5000), "5.0s")
    }
}
