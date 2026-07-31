import XCTest
@testable import RipulAgent

/// The replay HUD's state machine — phases, collapse wiring, cancel-on-
/// dismiss, per-step status application — driven with a fake presenter and
/// fake resolver, no UIKit anywhere (the strip view + overlay hosting are
/// iOS-only and covered by the sim build).
@MainActor
final class MacroReplayHUDControllerTests: XCTestCase {

    struct FakeElement: Equatable { let id: String }

    final class FakePresenter: MacroReplayPresenting {
        var canPresent = true
        private(set) var collapseCalls = 0
        func collapseForReplay() { collapseCalls += 1 }
    }

    final class AlwaysResolver: MacroElementResolving {
        func resolveTap(_ selector: MacroSelector) -> MacroResolution<FakeElement> {
            .resolved(FakeElement(id: selector.id ?? "x"))
        }
        func resolveScrollView(_ selector: MacroSelector) -> MacroResolution<FakeElement> {
            .resolved(FakeElement(id: selector.id ?? "x"))
        }
        func performTap(_ element: FakeElement, matchId: String?, matchText: String?) -> (success: Bool, error: String?) { (true, nil) }
        func performTapDetailed(_ element: FakeElement, matchId: String?, matchText: String?) -> (success: Bool, via: String?, error: String?) { (true, "fake", nil) }
        func performType(_ element: FakeElement, text: String, append: Bool) -> (success: Bool, error: String?) { (true, nil) }
        func performScroll(_ element: FakeElement, direction: String, amount: Double) -> Bool { true }
        func describe(_ element: FakeElement) -> String? { "FakeElement(\(element.id))" }
    }

    private func macro(_ name: String = "clock_in", steps: Int = 2) -> RipulMacro {
        RipulMacro(id: "m", name: name, description: "d",
                  steps: (0..<steps).map { MacroStep(kind: .tap, selector: MacroSelector(id: "s\($0)"), recordedLabel: "Step \($0 + 1)") },
                  createdAt: Date(), updatedAt: Date())
    }

    /// Poll until `predicate` holds or ~2s elapse (the controller's run is a
    /// Task — state lands asynchronously).
    private func waitFor(_ predicate: @escaping () -> Bool) async -> Bool {
        for _ in 0..<40 where !predicate() {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return predicate()
    }

    func testBeginReturnsFalseAndDoesNothingWhenPresenterCannotHost() async {
        let controller = MacroReplayHUDController.shared
        controller.dismiss()
        let presenter = FakePresenter()
        presenter.canPresent = false

        let began = controller.begin(macro(), parameters: [:], resolver: AlwaysResolver(), presenter: presenter)

        XCTAssertFalse(began)
        XCTAssertEqual(controller.phase, .hidden)
        XCTAssertEqual(presenter.collapseCalls, 0)
    }

    func testBeginCollapsesOnceAndRunsToFinishedWithStatuses() async {
        let controller = MacroReplayHUDController.shared
        controller.dismiss()
        controller.autoHideDelayNs = 60_000_000_000 // keep finished state for assertions
        defer { controller.autoHideDelayNs = 2_500_000_000 }
        let presenter = FakePresenter()

        let began = controller.begin(macro("clock_in", steps: 2), parameters: [:], resolver: AlwaysResolver(), presenter: presenter)

        XCTAssertTrue(began)
        XCTAssertEqual(presenter.collapseCalls, 1)
        XCTAssertEqual(controller.phase, .running)
        XCTAssertEqual(controller.macroName, "clock_in")
        XCTAssertEqual(controller.stepLabels, ["Step 1", "Step 2"])

        let finished = await waitFor { controller.phase == .finished }
        XCTAssertTrue(finished, "run should reach finished")
        XCTAssertEqual(controller.outcome?.success, true)
        XCTAssertEqual(controller.statuses.count, 2)
        guard case .succeeded = controller.statuses[0], case .succeeded = controller.statuses[1] else {
            XCTFail("both steps should report succeeded: \(controller.statuses)")
            return
        }
        controller.dismiss()
    }

    func testDismissCancelsAndHides() async {
        let controller = MacroReplayHUDController.shared
        controller.dismiss()
        controller.autoHideDelayNs = 60_000_000_000
        defer { controller.autoHideDelayNs = 2_500_000_000 }
        let presenter = FakePresenter()

        _ = controller.begin(macro(steps: 3), parameters: [:], resolver: AlwaysResolver(), presenter: presenter)
        XCTAssertEqual(controller.phase, .running)

        controller.dismiss()
        XCTAssertEqual(controller.phase, .hidden)
        XCTAssertNil(controller.outcome)
    }

    func testAutoHideReturnsToHiddenAfterFinished() async {
        let controller = MacroReplayHUDController.shared
        controller.dismiss()
        controller.autoHideDelayNs = 100_000_000 // 0.1s
        defer { controller.autoHideDelayNs = 2_500_000_000 }
        let presenter = FakePresenter()

        _ = controller.begin(macro(steps: 1), parameters: [:], resolver: AlwaysResolver(), presenter: presenter)
        let finished = await waitFor { controller.phase == .finished }
        XCTAssertTrue(finished)

        let hidden = await waitFor { controller.phase == .hidden }
        XCTAssertTrue(hidden, "strip should auto-hide after the outcome delay")
        controller.dismiss()
    }
}
