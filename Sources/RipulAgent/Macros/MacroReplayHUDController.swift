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

/// Set by the replay HUD's "open context" action (tap the finished strip) —
/// consumed by the console's Solution management section (opens the macro
/// library) and by the library itself (opens the editor for exactly this
/// macro), so a replay's finish state is a one-tap return to the edit-test
/// loop instead of a drill-back-down through the sessions list.
enum MacroDeepLink {
    static var pendingEditorMacro: RipulMacro?
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

    /// The macro currently (or most recently) replayed — retained so the
    /// finished strip's tap can deep-link straight back to its editor.
    public private(set) var currentMacro: RipulMacro?

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
        currentMacro = macro
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
            // The strip STAYS on the outcome — it's the one-tap return ticket
            // to the macro's editor (openContext). It hides only on dismiss,
            // openContext, or a newer run.
            if self.phase == .running { self.phase = .finished }
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
        currentMacro = nil
    }

    /// The finished strip's tap: deep-link back to the macro's editor —
    /// expand the console, open the library, open the editor for exactly the
    /// macro that just ran. The strip hides (the console covers everything
    /// anyway); the pending deep-link is consumed on appear (robust to
    /// presentation timing) AND by notification (robust to the console
    /// already being warm in the background).
    public func openContext() {
        guard phase == .finished, let macro = currentMacro else { return }
        MacroDeepLink.pendingEditorMacro = macro
        phase = .hidden
        #if os(iOS)
        if #available(iOS 26.0, *) {
            RipulDevAssistantOverlay.shared.expand()
            NotificationCenter.default.post(name: .ripulOpenMacroEditor, object: nil)
        }
        #endif
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
