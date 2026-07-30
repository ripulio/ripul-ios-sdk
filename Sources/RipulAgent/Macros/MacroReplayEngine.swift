import Foundation

/// Outcome of replaying a macro — `MacroTool.execute`'s return value, and what
/// the agent sees. Stops at the first failing step and reports which one, so
/// a partial run is always legible rather than a silent partial success.
public struct MacroReplayResult: Codable {
    public let success: Bool
    public let completedSteps: Int
    public let totalSteps: Int
    public let failedStepIndex: Int?
    public let error: String?
}

/// Replays a `RipulMacro`'s steps through a `MacroElementResolving`
/// conformance. Generic over the resolver (not hardcoded to
/// `LiveScreenResolver`) — no UIKit dependency anywhere in this file, no
/// `#if canImport(UIKit)` gate, so the whole control flow (sequencing,
/// `{{param}}` substitution, stop-on-first-failure, the bounded-poll
/// discipline) is exercised by plain `swift test` on macOS with a fake
/// resolver. The real call site (`MacroTool.execute`) supplies
/// `LiveScreenResolver()`; nothing here knows or cares that it's UIKit-backed.
/// See `docs/plans/automation-macros/phase-1-replay-engine.md`.
///
/// `@MainActor` because `MacroElementResolving` is (the live resolver walks a
/// UIView tree) — but actor isolation is a Concurrency feature, not a UIKit
/// one, so this doesn't affect testability: `swift test` runs fine with
/// `@MainActor`-isolated test methods, exactly like `ToolRegistryTests`.
@MainActor
public enum MacroReplayEngine {
    /// How long, and how often, a single step polls for its target to resolve
    /// before giving up — the bounded-poll-per-step default that replaces
    /// recorded wait steps for the common "screen hasn't re-rendered yet" case
    /// (docs/plans/automation-macros/README.md decision #3). `nonisolated`: a
    /// plain `TimeInterval` constant has no actor affinity, and used as a
    /// default parameter value it must be evaluable outside `replay`'s
    /// isolation domain (default-argument expressions run nonisolated even
    /// when the function itself is `@MainActor` — leaving this isolated is a
    /// warning today and a hard error under Swift 6 strict concurrency).
    public nonisolated static let resolutionTimeout: TimeInterval = 5
    static let pollInterval: UInt64 = 150_000_000 // nanoseconds

    public static func replay<R: MacroElementResolving>(
        _ macro: RipulMacro,
        parameters: [String: String],
        resolver: R,
        resolutionTimeout: TimeInterval = MacroReplayEngine.resolutionTimeout
    ) async -> MacroReplayResult {
        for (index, step) in macro.steps.enumerated() {
            let outcome = await run(step, parameters: parameters, resolver: resolver, resolutionTimeout: resolutionTimeout)
            if !outcome.success {
                return MacroReplayResult(success: false, completedSteps: index,
                                         totalSteps: macro.steps.count, failedStepIndex: index,
                                         error: outcome.error)
            }
        }
        return MacroReplayResult(success: true, completedSteps: macro.steps.count,
                                 totalSteps: macro.steps.count, failedStepIndex: nil, error: nil)
    }

    private struct StepOutcome {
        let success: Bool
        let error: String?
    }

    private static func run<R: MacroElementResolving>(_ step: MacroStep, parameters: [String: String],
                                                       resolver: R, resolutionTimeout: TimeInterval) async -> StepOutcome {
        switch step.kind {
        case .tap:
            guard let element = await pollResolveTap(step.selector, resolver: resolver, resolutionTimeout: resolutionTimeout) else {
                return StepOutcome(success: false, error: notResolved(step, resolutionTimeout))
            }
            let outcome = resolver.performTap(element, matchId: step.selector.id, matchText: step.selector.text)
            return StepOutcome(success: outcome.success, error: outcome.error)

        case .type:
            guard let element = await pollResolveTap(step.selector, resolver: resolver, resolutionTimeout: resolutionTimeout) else {
                return StepOutcome(success: false, error: notResolved(step, resolutionTimeout))
            }
            let text = MacroParameterSubstitution.apply(step.text ?? "", parameters: parameters)
            let outcome = resolver.performType(element, text: text, append: step.append ?? false)
            return StepOutcome(success: outcome.success, error: outcome.error)

        case .scroll:
            guard let element = await pollResolveScrollView(step.selector, resolver: resolver, resolutionTimeout: resolutionTimeout) else {
                return StepOutcome(success: false, error: notResolved(step, resolutionTimeout))
            }
            let scrolled = resolver.performScroll(element, direction: step.direction ?? "down", amount: step.amount ?? 0.8)
            return StepOutcome(success: scrolled, error: scrolled ? nil : "Element resolved, but it isn't a scroll container.")

        case .wait:
            let wantGone = step.state == "gone"
            let timeout = step.timeout ?? resolutionTimeout
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                let found = resolver.resolveTap(step.selector) != nil
                if wantGone != found { return StepOutcome(success: true, error: nil) }
                if Date() >= deadline {
                    return StepOutcome(success: false,
                                       error: "Timed out after \(Int(timeout))s waiting for '\(step.recordedLabel)' to become \(wantGone ? "gone" : "visible").")
                }
                try? await Task.sleep(nanoseconds: pollInterval)
            }
        }
    }

    /// Bounded poll: re-resolves on every attempt (never holds a stale
    /// reference across attempts) so a step whose target hasn't rendered yet
    /// — the common case right after the previous step triggered a
    /// navigation — succeeds without a recorded wait step.
    private static func pollResolveTap<R: MacroElementResolving>(_ selector: MacroSelector, resolver: R,
                                                                  resolutionTimeout: TimeInterval) async -> R.ResolvedElement? {
        let deadline = Date().addingTimeInterval(resolutionTimeout)
        while true {
            if let element = resolver.resolveTap(selector) { return element }
            if Date() >= deadline { return nil }
            try? await Task.sleep(nanoseconds: pollInterval)
        }
    }

    private static func pollResolveScrollView<R: MacroElementResolving>(_ selector: MacroSelector, resolver: R,
                                                                         resolutionTimeout: TimeInterval) async -> R.ResolvedElement? {
        let deadline = Date().addingTimeInterval(resolutionTimeout)
        while true {
            if let element = resolver.resolveScrollView(selector) { return element }
            if Date() >= deadline { return nil }
            try? await Task.sleep(nanoseconds: pollInterval)
        }
    }

    private static func notResolved(_ step: MacroStep, _ timeout: TimeInterval) -> String {
        "Could not resolve '\(step.recordedLabel)' within \(Int(timeout))s."
    }
}
