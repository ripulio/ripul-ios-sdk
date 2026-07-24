import Foundation

/// Resolved subtitle state for a session row, computed from plan + tool activity inputs.
///
/// Encapsulates the priority chain that both `SessionRow` (agent screen) and
/// `UnifiedSessionRow` (iPhone paired session sheet) use to decide what subtitle
/// to render. Extracting this into a shared type prevents the "wired into the
/// wrong view" class of bugs documented in `docs/tool-subtitle-handoff.md` —
/// the priority logic lives in one place, and each view switches on the result
/// for its own rendering.
///
/// Priority: **in-progress plan > live tool call > completed plan > idle**.
enum SessionSubtitleState {
    /// An in-progress plan (not all todos completed) is the primary subtitle.
    case planInProgress(TodoState)
    /// A live or recently-completed tool call is the primary subtitle.
    case toolActivity(AgentActivityEvent)
    /// A fully-completed plan is the fallback subtitle (cleared once viewed).
    case planCompleted(TodoState)
    /// No activity — show default provider/time info.
    case idle

    // MARK: - Resolve

    /// Resolve the subtitle priority chain from plan + tool activity state.
    ///
    /// - Parameters:
    ///   - activePlan: In-progress plan (plain `visibleTodoState`). Shows even
    ///     after the user has opened the chat so interleaved tool calls don't
    ///     knock the plan summary out.
    ///   - listPlan: Completed plan (`visibleTodoStateForList`). Clears once
    ///     the user opens the chat via the `listViewedTodoVersions` marker.
    ///   - latestToolActivity: Most recent tool activity event, or nil.
    static func resolve(
        activePlan: TodoState?,
        listPlan: TodoState?,
        latestToolActivity: AgentActivityEvent?
    ) -> SessionSubtitleState {
        let planIsInProgress: Bool = {
            guard let plan = activePlan, !plan.todos.isEmpty else { return false }
            return !plan.todos.allSatisfy { $0.status == "completed" }
        }()

        if planIsInProgress, let plan = activePlan {
            return .planInProgress(plan)
        }
        if let activity = latestToolActivity {
            return .toolActivity(activity)
        }
        if let plan = listPlan {
            return .planCompleted(plan)
        }
        return .idle
    }

    // MARK: - Computed helpers

    /// Whether a plan is actively in progress (not all completed).
    var planIsInProgress: Bool {
        if case .planInProgress = self { return true }
        return false
    }

    /// Extract a human-readable detail string for the current state.
    var detailText: String? {
        switch self {
        case .planInProgress(let plan), .planCompleted(let plan):
            return Self.planDetailText(plan: plan)
        case .toolActivity(let activity):
            let d = activity.detail ?? ""
            return d.isEmpty ? nil : d
        case .idle:
            return nil
        }
    }

    /// Stable identity key for SwiftUI crossfade animations. Includes enough
    /// information to trigger a transition when the active subtitle branch or
    /// its content changes.
    ///
    /// - Parameter inlineToolActivity: When a plan is in progress AND a tool
    ///   is running concurrently, pass the tool event so the key also captures
    ///   third-row changes (used by `UnifiedSessionRow`).
    func subtitleKey(inlineToolActivity: AgentActivityEvent? = nil) -> String {
        switch self {
        case .planInProgress(let plan):
            let toolKey: String
            if let activity = inlineToolActivity {
                toolKey = "\(activity.toolNameForIcon ?? "")|\(activity.detail ?? "")|\(activity.isActive ? "a" : "i")"
            } else {
                toolKey = "none"
            }
            return "plan-progress:\(plan.todos.count):\(detailText ?? ""):tool=\(toolKey)"
        case .toolActivity(let activity):
            return "tool:\(activity.toolNameForIcon ?? "")|\(activity.displayName ?? "")|\(activity.detail ?? "")|\(activity.isActive ? "a" : "i")"
        case .planCompleted:
            return "plan-done:\(detailText ?? "")"
        case .idle:
            return "default"
        }
    }

    // MARK: - Plan detail text

    /// Extract plan detail text: the in-progress todo's activeForm, or
    /// "Plan done" when all todos are completed.
    static func planDetailText(plan: TodoState) -> String {
        let completed = plan.todos.filter { $0.status == "completed" }.count
        let total = plan.todos.count
        let inProgress = plan.todos.first(where: { $0.status == "in_progress" })
        let allDone = completed == total && total > 0
        if allDone { return "Plan done" }
        return inProgress?.activeForm ?? inProgress?.content ?? "Plan"
    }
}
