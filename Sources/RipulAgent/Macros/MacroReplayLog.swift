import Foundation

/// Builds the paste-ready replay transcript (the "Copy log" text) from a
/// macro, the parameter values used, and the run's `MacroReplayResult` —
/// which already carries per-step via/error/resolved-detail/timing, so the
/// builder itself is pure string logic with no UIKit and full `swift test`
/// coverage. Consumed by the macro editor's Copy log button; the HUD strip
/// intentionally shows a one-line summary instead.
public enum MacroReplayLog {
    /// "240ms" below a second, "1.2s" above.
    public static func formatMs(_ ms: Int) -> String {
        ms < 1000 ? "\(ms)ms" : String(format: "%.1fs", Double(ms) / 1000)
    }

    public static func text(macro: RipulMacro, paramValues: [String: String], outcome: MacroReplayResult) -> String {
        var lines: [String] = ["Replay: \(macro.name) — \(macro.steps.count) step\(macro.steps.count == 1 ? "" : "s")"]
        for parameter in macro.parameters {
            lines.append("  \(parameter.name) = \"\(paramValues[parameter.name] ?? "")\"")
        }
        for stepResult in outcome.stepResults {
            let index = stepResult.index
            let prefix = "\(index + 1). \(stepResult.label)"
            if stepResult.succeeded {
                let viaPart = stepResult.via.map { "via \($0) · " } ?? ""
                lines.append("✓ \(prefix) — \(viaPart)\(formatMs(stepResult.durationMs))")
            } else {
                lines.append("✗ \(prefix) — \(stepResult.error ?? "failed") · \(formatMs(stepResult.durationMs))")
            }
            if macro.steps.indices.contains(index) {
                let summary = macro.steps[index].selector.compactSummary
                if !summary.isEmpty { lines.append("   selector: \(summary)") }
            }
            if let detail = stepResult.resolvedDetail {
                lines.append("   matched: \(detail)")
            }
        }
        let totalMs = outcome.stepResults.map(\.durationMs).reduce(0, +)
        lines.append(outcome.success
            ? "Outcome: all \(outcome.totalSteps) steps completed in \(formatMs(totalMs))."
            : "Outcome: stopped at step \((outcome.failedStepIndex ?? 0) + 1) of \(outcome.totalSteps) — \(outcome.error ?? "unknown error")")
        return lines.joined(separator: "\n")
    }
}
