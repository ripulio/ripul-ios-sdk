import XCTest
@testable import RipulAgent

/// Phase-0 (automation-macros): pure string logic behind `{{name}}` token
/// substitution — used by `MacroReplayEngine` (phase 1) before dispatching a
/// `.type` step, and by the recording UI's parameter auto-detection (phase 2).
final class MacroParameterSubstitutionTests: XCTestCase {

    func testNoTokensReturnsTextUnchanged() {
        XCTAssertEqual(MacroParameterSubstitution.apply("plain text", parameters: [:]), "plain text")
    }

    func testSingleTokenSubstituted() {
        let result = MacroParameterSubstitution.apply("Note: {{note}}", parameters: ["note": "started shift"])
        XCTAssertEqual(result, "Note: started shift")
    }

    func testMultipleDistinctTokensSubstituted() {
        let result = MacroParameterSubstitution.apply("{{greeting}}, {{name}}!",
                                                       parameters: ["greeting": "Hi", "name": "Alice"])
        XCTAssertEqual(result, "Hi, Alice!")
    }

    func testRepeatedTokenSubstitutedEveryOccurrence() {
        let result = MacroParameterSubstitution.apply("{{x}} and {{x}} again", parameters: ["x": "1"])
        XCTAssertEqual(result, "1 and 1 again")
    }

    func testMissingParameterLeftLiteralNotStrippedNotEmpty() {
        // A malformed macro should fail loudly at the point of use (the
        // literal token visibly typed into a field), not silently here.
        let result = MacroParameterSubstitution.apply("Note: {{typo}}", parameters: ["note": "x"])
        XCTAssertEqual(result, "Note: {{typo}}")
    }

    func testWhitespaceInsideBracesIsTolerated() {
        let result = MacroParameterSubstitution.apply("{{ note }}", parameters: ["note": "value"])
        XCTAssertEqual(result, "value")
    }

    func testTokenNamesExtractsDistinctInFirstAppearanceOrder() {
        let names = MacroParameterSubstitution.tokenNames(in: "{{b}} then {{a}} then {{b}} again")
        XCTAssertEqual(names, ["b", "a"])
    }

    func testTokenNamesEmptyWhenNoTokens() {
        XCTAssertEqual(MacroParameterSubstitution.tokenNames(in: "no tokens here"), [])
    }

    // MARK: - detectParameters (phase 2: save sheet auto-population)

    private func typeStep(_ text: String) -> MacroStep {
        MacroStep(kind: .type, selector: MacroSelector(id: "field"), text: text, recordedLabel: "Type")
    }

    private func tapStep() -> MacroStep {
        MacroStep(kind: .tap, selector: MacroSelector(id: "button"), recordedLabel: "Tap")
    }

    func testDetectParametersMergesAcrossStepsInFirstAppearanceOrder() {
        let names = MacroParameterSubstitution.detectParameters(in: [
            typeStep("{{note}}"),
            tapStep(),
            typeStep("{{amount}} for {{note}}"),
        ])
        XCTAssertEqual(names, ["note", "amount"])
    }

    func testDetectParametersIgnoresNonTypeSteps() {
        let names = MacroParameterSubstitution.detectParameters(in: [tapStep()])
        XCTAssertEqual(names, [])
    }

    func testDetectParametersEmptyWhenNoTokensAnywhere() {
        let names = MacroParameterSubstitution.detectParameters(in: [typeStep("plain text"), tapStep()])
        XCTAssertEqual(names, [])
    }
}
