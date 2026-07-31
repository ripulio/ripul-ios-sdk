import Foundation

/// Outcome of a single step — shown per-step in the replay sheet and
/// included in the agent-facing tool output, so "did step 3 pass?" is
/// answerable, not just "did the macro pass?".
public struct MacroStepResult: Codable, Equatable {
    public let index: Int
    public let label: String
    public let succeeded: Bool
    /// Which actuation path fired for taps (`uicontrol` / `accessibilityElement`
    /// / `accessibilityActivate` / `tapGesture`) — a weak press (tapGesture) is
    /// worth knowing about when a step "passed" but the app didn't respond.
    public let via: String?
    public let error: String?
    /// What the selector actually matched (class, role, id, text, frame) —
    /// the difference between "the step passed" and "the step passed ON THE
    /// RIGHT THING". Nil when resolution failed.
    public let resolvedDetail: String?
    /// Milliseconds spent resolving the selector (bounded-poll total).
    public let resolveMs: Int
    /// Milliseconds for the whole step (resolve + actuate).
    public let durationMs: Int
}

/// A live replay-progress event — fired at step start and step end, drives
/// the replay sheet's per-step status icons.
public struct MacroStepEvent {
    public enum Phase: Equatable {
        case started
        case succeeded(via: String?, detail: String?, durationMs: Int)
        case failed(error: String?, detail: String?, durationMs: Int)
    }
    public let index: Int
    public let label: String
    public let phase: Phase
}

/// Outcome of replaying a macro — `MacroTool.execute`'s return value, and what
/// the agent sees. Stops at the first failing step and reports which one, so
/// a partial run is always legible rather than a silent partial success.
public struct MacroReplayResult: Codable {
    public let success: Bool
    public let completedSteps: Int
    public let totalSteps: Int
    public let failedStepIndex: Int?
    public let error: String?
    /// Every step attempted, in order — the failed step (if any) is last.
    public let stepResults: [MacroStepResult]
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
        resolutionTimeout: TimeInterval = MacroReplayEngine.resolutionTimeout,
        onStepProgress: ((MacroStepEvent) -> Void)? = nil
    ) async throws -> MacroReplayResult {
        var stepResults: [MacroStepResult] = []
        for (index, step) in macro.steps.enumerated() {
            try Task.checkCancellation()
            onStepProgress?(MacroStepEvent(index: index, label: step.recordedLabel, phase: .started))
            let outcome = try await run(step, parameters: parameters, resolver: resolver, resolutionTimeout: resolutionTimeout)
            stepResults.append(MacroStepResult(index: index, label: step.recordedLabel,
                                               succeeded: outcome.success, via: outcome.via, error: outcome.error,
                                               resolvedDetail: outcome.detail, resolveMs: outcome.resolveMs,
                                               durationMs: outcome.durationMs))
            if outcome.success {
                onStepProgress?(MacroStepEvent(index: index, label: step.recordedLabel,
                                               phase: .succeeded(via: outcome.via, detail: outcome.detail, durationMs: outcome.durationMs)))
            } else {
                onStepProgress?(MacroStepEvent(index: index, label: step.recordedLabel,
                                               phase: .failed(error: outcome.error, detail: outcome.detail, durationMs: outcome.durationMs)))
                return MacroReplayResult(success: false, completedSteps: index,
                                         totalSteps: macro.steps.count, failedStepIndex: index,
                                         error: outcome.error, stepResults: stepResults)
            }
        }
        return MacroReplayResult(success: true, completedSteps: macro.steps.count,
                                 totalSteps: macro.steps.count, failedStepIndex: nil, error: nil,
                                 stepResults: stepResults)
    }

    private struct StepOutcome {
        let success: Bool
        let via: String?
        let error: String?
        let detail: String?
        let resolveMs: Int
        let durationMs: Int

        init(success: Bool, via: String?, error: String?, detail: String? = nil,
             resolveMs: Int = 0, durationMs: Int = 0) {
            self.success = success
            self.via = via
            self.error = error
            self.detail = detail
            self.resolveMs = resolveMs
            self.durationMs = durationMs
        }
    }

    private static func run<R: MacroElementResolving>(_ step: MacroStep, parameters: [String: String],
                                                       resolver: R, resolutionTimeout: TimeInterval) async throws -> StepOutcome {
        let stepStart = Date()
        func ms(since date: Date) -> Int { Int(Date().timeIntervalSince(date) * 1000) }

        switch step.kind {
        case .tap:
            let resolution = try await pollResolveTap(step.selector, resolver: resolver, resolutionTimeout: resolutionTimeout)
            let resolveMs = ms(since: stepStart)
            guard case .resolved(let element) = resolution else {
                return StepOutcome(success: false, via: nil,
                                   error: notResolved(step, resolution, resolutionTimeout),
                                   resolveMs: resolveMs, durationMs: ms(since: stepStart))
            }
            let detail = resolver.describe(element)
            let outcome = resolver.performTapDetailed(element, matchId: step.selector.id, matchText: step.selector.text)
            return StepOutcome(success: outcome.success, via: outcome.via, error: outcome.error,
                               detail: detail, resolveMs: resolveMs, durationMs: ms(since: stepStart))

        case .type:
            let resolution = try await pollResolveTap(step.selector, resolver: resolver, resolutionTimeout: resolutionTimeout)
            let resolveMs = ms(since: stepStart)
            guard case .resolved(let element) = resolution else {
                return StepOutcome(success: false, via: nil,
                                   error: notResolved(step, resolution, resolutionTimeout),
                                   resolveMs: resolveMs, durationMs: ms(since: stepStart))
            }
            let detail = resolver.describe(element)
            let text = MacroParameterSubstitution.apply(step.text ?? "", parameters: parameters)
            let outcome = resolver.performType(element, text: text, append: step.append ?? false)
            return StepOutcome(success: outcome.success, via: nil, error: outcome.error,
                               detail: detail, resolveMs: resolveMs, durationMs: ms(since: stepStart))

        case .scroll:
            let resolution = try await pollResolveScrollView(step.selector, resolver: resolver, resolutionTimeout: resolutionTimeout)
            let resolveMs = ms(since: stepStart)
            guard case .resolved(let element) = resolution else {
                return StepOutcome(success: false, via: nil,
                                   error: notResolved(step, resolution, resolutionTimeout),
                                   resolveMs: resolveMs, durationMs: ms(since: stepStart))
            }
            let detail = resolver.describe(element)
            let scrolled = resolver.performScroll(element, direction: step.direction ?? "down", amount: step.amount ?? 0.8)
            return StepOutcome(success: scrolled, via: nil, error: scrolled ? nil : "Element resolved, but it isn't a scroll container.",
                               detail: detail, resolveMs: resolveMs, durationMs: ms(since: stepStart))

        case .wait:
            let wantGone = step.state == "gone"
            let timeout = step.timeout ?? resolutionTimeout
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                let found = resolver.resolveTap(step.selector).element != nil
                if wantGone != found {
                    return StepOutcome(success: true, via: nil, error: nil,
                                       durationMs: ms(since: stepStart))
                }
                if Date() >= deadline {
                    return StepOutcome(success: false, via: nil,
                                       error: "Timed out after \(Int(timeout))s waiting for '\(step.recordedLabel)' to become \(wantGone ? "gone" : "visible").",
                                       durationMs: ms(since: stepStart))
                }
                try await Task.sleep(nanoseconds: pollInterval)
            }

        case .pause:
            // Fixed settle time — always succeeds, no condition. The sleep
            // throws promptly on cancellation, same as the poll loops.
            let seconds = max(step.seconds ?? 1, 0)
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return StepOutcome(success: true, via: nil, error: nil,
                               durationMs: ms(since: stepStart))
        }
    }

    /// Bounded poll: re-resolves on every attempt (never holds a stale
    /// reference across attempts) so a step whose target hasn't rendered yet
    /// — the common case right after the previous step triggered a
    /// navigation — succeeds without a recorded wait step. Keeps the LAST
    /// resolution so the error message can say whether the poll saw nothing
    /// or saw too much. Throws promptly on task cancellation (dismissed
    /// replay HUD) instead of polling out the full timeout.
    private static func pollResolveTap<R: MacroElementResolving>(_ selector: MacroSelector, resolver: R,
                                                                  resolutionTimeout: TimeInterval) async throws -> MacroResolution<R.ResolvedElement> {
        let deadline = Date().addingTimeInterval(resolutionTimeout)
        var last: MacroResolution<R.ResolvedElement> = .notFound
        while true {
            last = resolver.resolveTap(selector)
            if case .resolved = last { return last }
            if Date() >= deadline { return last }
            try await Task.sleep(nanoseconds: pollInterval)
        }
    }

    private static func pollResolveScrollView<R: MacroElementResolving>(_ selector: MacroSelector, resolver: R,
                                                                         resolutionTimeout: TimeInterval) async throws -> MacroResolution<R.ResolvedElement> {
        let deadline = Date().addingTimeInterval(resolutionTimeout)
        var last: MacroResolution<R.ResolvedElement> = .notFound
        while true {
            last = resolver.resolveScrollView(selector)
            if case .resolved = last { return last }
            if Date() >= deadline { return last }
            try await Task.sleep(nanoseconds: pollInterval)
        }
    }

    private static func notResolved<E>(_ step: MacroStep, _ resolution: MacroResolution<E>, _ timeout: TimeInterval) -> String {
        switch resolution {
        case .ambiguous(let count):
            return "'\(step.recordedLabel)' matched \(count) elements — ambiguous (needs an nth or a within anchor to pick one)."
        default:
            return "Could not resolve '\(step.recordedLabel)' within \(Int(timeout))s."
        }
    }
}
