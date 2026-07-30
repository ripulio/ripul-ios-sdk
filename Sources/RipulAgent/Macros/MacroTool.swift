import Foundation

/// Generates a `MacroTool`'s description from `macro.description` plus an
/// auto-appended step summary, so the agent has something concrete to match
/// against even when a developer's own description is sparse. Pure string
/// logic — kept UIKit-independent so it's testable alongside the rest of
/// `MacroModelsTests`.
enum MacroToolDescription {
    static func generate(for macro: RipulMacro) -> String {
        var text = macro.description
        if !macro.steps.isEmpty {
            let summary = macro.steps.map(\.recordedLabel).joined(separator: ", ")
            text += " Steps: \(summary)."
        }
        if !macro.parameters.isEmpty {
            let names = macro.parameters.map { "\($0.name) (\($0.description))" }.joined(separator: ", ")
            text += " Parameters: \(names)."
        }
        return text
    }
}

#if canImport(UIKit)
/// A `NativeTool` synthesized from a persisted `RipulMacro` — the bridge
/// between "developer recorded a workflow" (phase 2) and "the agent can call
/// it" (this phase, then phase 4's dynamic registration). Replays through
/// `MacroReplayEngine` + `LiveScreenResolver`, the exact same actuation
/// implementation the live `tap_element`/`type_text`/`scroll_element` tools
/// use — never a second interpreter.
public struct MacroTool: NativeTool {
    public let macro: RipulMacro

    public init(macro: RipulMacro) {
        self.macro = macro
    }

    public var name: String { "run_macro_\(macro.name)" }
    public var description: String { MacroToolDescription.generate(for: macro) }
    public var inputSchema: [String: Any] {
        ToolSchema.object(macro.parameters.map { .string($0.name, $0.description) })
    }

    @MainActor
    public func execute(args: [String: Any]) async throws -> Any {
        var parameters: [String: String] = [:]
        for parameter in macro.parameters {
            if let value = args[parameter.name] as? String {
                parameters[parameter.name] = value
            }
        }
        let result = await MacroReplayEngine.replay(macro, parameters: parameters, resolver: LiveScreenResolver())
        return [
            "success": result.success,
            "completedSteps": result.completedSteps,
            "totalSteps": result.totalSteps,
            "failedStepIndex": result.failedStepIndex as Any,
            "error": result.error as Any,
            // Per-step outcomes — "did step 3 pass?" is answerable, and the
            // failed step's error + the passing steps' via paths tell the
            // agent exactly where and how the run broke or succeeded.
            "steps": result.stepResults.map { step in
                [
                    "index": step.index,
                    "label": step.label,
                    "succeeded": step.succeeded,
                    "via": step.via as Any,
                    "error": step.error as Any,
                    "resolvedDetail": step.resolvedDetail as Any,
                    "resolveMs": step.resolveMs,
                    "durationMs": step.durationMs,
                ] as [String: Any]
            },
        ]
    }
}
#endif
