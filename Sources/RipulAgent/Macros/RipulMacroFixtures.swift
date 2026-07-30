import Foundation

#if canImport(UIKit)
/// A hardcoded macro proving `MacroReplayEngine` + `MacroTool` work end to end
/// on a real screen — used only as UI-test scaffolding now
/// (`RipulAppApp`'s `-RipulUITestRunFixtureMacro` and
/// `-RipulUITestRecordCaptureStep` hooks, `MacroReplayFixtureUITests`). It
/// briefly stood in for `RipulAgentConsole`'s real registration path (phase 1,
/// before `/v1/macros` existed); phase 4 replaced that call with a real
/// fetch-from-backend + dynamic synthesis (`refreshMacroTools()`).
///
/// Deliberately recreates the exact sequence `OnboardingUITests
/// .testDoneDismissesOnboardingAndRevealsSignIn` already proves works
/// unattended (walk 4 onboarding pages via Continue, tap Done, land on
/// sign-in) — driven through the macro system instead of raw XCUITest calls,
/// so the proof is against known-good app behavior rather than a guess about
/// what an untested screen does.
///
/// `public`: `RipulAppApp`'s UI-test-only launch-argument hook
/// (`-RipulUITestRunFixtureMacro`) constructs `MacroTool(macro:
/// RipulMacroFixtures.onboardingWalkthrough)` directly and calls `execute`,
/// so the app-side proof replays the EXACT SAME macro value the console
/// registers — one source of truth, not a hand-copied duplicate that could
/// drift.
public enum RipulMacroFixtures {
    public static let onboardingWalkthrough = RipulMacro(
        id: "macro_fixture_onboarding_walkthrough",
        name: "onboarding_walkthrough",
        description: "Walks through the first-run onboarding cards and taps Done, "
            + "revealing the sign-in screen.",
        steps: [
            MacroStep(kind: .tap, selector: MacroSelector(id: "OnboardingView.continueButton"),
                     recordedLabel: "Tap Continue (page 1 of 5)"),
            MacroStep(kind: .tap, selector: MacroSelector(id: "OnboardingView.continueButton"),
                     recordedLabel: "Tap Continue (page 2 of 5)"),
            MacroStep(kind: .tap, selector: MacroSelector(id: "OnboardingView.continueButton"),
                     recordedLabel: "Tap Continue (page 3 of 5)"),
            MacroStep(kind: .tap, selector: MacroSelector(id: "OnboardingView.continueButton"),
                     recordedLabel: "Tap Continue (page 4 of 5)"),
            MacroStep(kind: .tap, selector: MacroSelector(id: "OnboardingView.doneButton"),
                     recordedLabel: "Tap Done"),
        ],
        createdAt: Date(),
        updatedAt: Date()
    )
}
#endif
