import Foundation

/// What owns the "minimize the console and host the replay strip" side of a
/// HUD-mode replay — the dev overlay (`RipulDevAssistantOverlay`, iOS) in
/// production, a fake in tests. Splitting `canPresent` from
/// `collapseForReplay` matters for ordering: the controller sets its
/// `.running` phase BETWEEN the two, so the overlay's collapse reveal sees
/// the HUD is active and doesn't fight the strip for the bottom edge.
@MainActor
public protocol MacroReplayPresenting {
    var canPresent: Bool { get }
    func collapseForReplay()
}

/// Drives the deterministic-replay HUD strip (docs/plans/automation-macros/):
/// a macro replay that runs WITHOUT the sheet/console covering the host
/// screen — the console collapses, and this controller's published state
/// renders as a bottom-docked strip showing the current executing line.
/// Platform-independent (no UIKit) so `swift test` drives the state machine
/// with a fake presenter + fake resolver; the strip view and its hosting
/// live in the iOS-only overlay.
@MainActor
public final class MacroReplayHUDController: ObservableObject {
    public static let shared = MacroReplayHUDController()
    private init() {}

    public enum Phase: Equatable { case hidden, running, finished }
    public enum StepStatus: Equatable {
        case pending, running, succeeded(via: String?), failed(error: String?)
    }

    @Published public private(set) var phase: Phase = .hidden
    @Published public private(set) var macroName = ""
    @Published public private(set) var stepLabels: [String] = []
    @Published public private(set) var statuses: [StepStatus] = []
    @Published public private(set) var currentIndex = 0
    @Published public private(set) var outcome: MacroReplayResult?

    /// How long the outcome stays on screen before the strip hands back to
    /// the compact bar/bubble. Internal (not private) so tests can shorten it.
    var autoHideDelayNs: UInt64 = 2_500_000_000

    private var runTask: Task<Void, Never>?
    private var runGeneration = 0

    /// The currently-executing step's label — the strip's headline.
    public var currentLabel: String? {
        guard stepLabels.indices.contains(currentIndex) else { return nil }
        return stepLabels[currentIndex]
    }

    /// Begin a HUD-mode replay. Returns false when the presenter can't host
    /// the strip (e.g. no overlay window) — the caller keeps its inline UI.
    @discardableResult
    public func begin<R: MacroElementResolving>(
        _ macro: RipulMacro,
        parameters: [String: String],
        resolver: R,
        presenter: MacroReplayPresenting
    ) -> Bool {
        guard presenter.canPresent else { return false }
        runTask?.cancel()
        runGeneration += 1
        let generation = runGeneration
        macroName = macro.name
        stepLabels = macro.steps.map(\.recordedLabel)
        statuses = Array(repeating: .pending, count: macro.steps.count)
        currentIndex = 0
        outcome = nil
        phase = .running
        presenter.collapseForReplay()
        runTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await MacroReplayEngine.replay(
                    macro, parameters: parameters, resolver: resolver
                ) { [weak self] event in
                    self?.apply(event)
                }
                self.outcome = result
            } catch {
                // Cancelled (dismiss, or a newer begin superseded this run).
            }
            if self.phase == .running { self.phase = .finished }
            try? await Task.sleep(nanoseconds: self.autoHideDelayNs)
            if self.phase == .finished, generation == self.runGeneration {
                self.phase = .hidden
            }
        }
        return true
    }

    /// Stop the run (the engine's cancellation points interrupt promptly)
    /// and hide the strip.
    public func dismiss() {
        runTask?.cancel()
        runTask = nil
        runGeneration += 1
        phase = .hidden
    }

    private func apply(_ event: MacroStepEvent) {
        guard statuses.indices.contains(event.index) else { return }
        currentIndex = event.index
        switch event.phase {
        case .started:
            statuses[event.index] = .running
        case .succeeded(let via, _, _):
            statuses[event.index] = .succeeded(via: via)
        case .failed(let error, _, _):
            statuses[event.index] = .failed(error: error)
        }
    }
}
