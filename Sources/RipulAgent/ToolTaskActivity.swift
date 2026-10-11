import SwiftUI

struct ToolTaskActivity: Decodable, Equatable {
    struct Entry: Decodable, Equatable {
        let kind: String
        let label: String?
        let detail: String?
    }
    let id: String
    let type: String
    let title: String
    let status: String
    let variant: String?
    let summary: String?
    let error: String?
    let entries: [Entry]
    let totalCount: Int
    let usage: String?
    let synthetic: Bool
    /// A workflow run's phases and agents, once the run has reported any.
    var workflow: Workflow? = nil

    /// One workflow run, as the web words it: every string is ready to show,
    /// so this sheet and the web's dialog cannot describe a run differently.
    struct Workflow: Decodable, Equatable {
        struct Agent: Decodable, Equatable, Identifiable {
            let id: String
            let label: String
            /// queued | running | done | failed | stopped
            let state: String
            let detail: String?
        }
        struct Phase: Decodable, Equatable, Identifiable {
            let id: String
            let title: String
            let state: String
            /// "3 of 8", or empty for a phase that has started no agents.
            let count: String
            let agents: [Agent]
            /// Agents of this phase the web left out of `agents`.
            let omitted: Int
        }
        /// "5 of 9 agents done", with failures named when there are any.
        let progress: String
        let done: Int
        let total: Int
        let phases: [Phase]
    }

    var kindTitle: String {
        switch type {
        case "local_agent": return "Agent"
        case "local_bash": return "Shell"
        case "local_workflow": return "Workflow"
        default: return "Task"
        }
    }
    var subtitle: String { [kindTitle, variant].compactMap { $0 }.joined(separator: " · ") }
}

/// Same compact status affordance on a lozenge and in a task's activity view.
struct ToolTaskStatus: View {
    let status: String
    var showLabel = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func isBusy(_ status: String?) -> Bool {
        ["running", "pending", "streaming"].contains(status ?? "")
    }
    static func title(_ status: String) -> String {
        switch status {
        case "ended": return "Ended — no outcome reported"
        case "orphaned": return "Interrupted — agent session restarted"
        case "killed", "stopped": return "Stopped"
        default: return status.prefix(1).uppercased() + status.dropFirst()
        }
    }
    private var color: Color {
        switch status {
        case "running", "pending", "streaming": return .ripul(.info)
        case "completed", "success": return .ripul(.success)
        case "failed", "error": return .ripul(.danger)
        case "ended", "orphaned", "killed", "stopped": return .ripul(.warning)
        default: return .ripul(.textSecondary)
        }
    }
    private var symbol: String {
        switch status {
        case "running", "pending", "streaming": return "circle.fill"
        case "completed", "success": return "checkmark.circle.fill"
        case "paused": return "pause.circle.fill"
        case "failed", "error": return "exclamationmark.circle.fill"
        default: return "stop.circle"
        }
    }
    var body: some View {
        HStack(spacing: 6) {
            if Self.isBusy(status) && !reduceMotion && !PerfSwitch.isOff("toolSpinner") {
                ProgressView().controlSize(.mini).tint(color).frame(width: 12, height: 12)
            } else {
                Image(systemName: symbol).font(.ripulIcon(size: 12)).frame(width: 12, height: 12)
            }
            if showLabel { Text(Self.title(status)).font(.ripul(.caption, weight: .medium)) }
        }
        .foregroundStyle(color)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.title(status))
        .accessibilityIdentifier("ToolTask.status")
    }
}

struct ToolTaskActivityView: View {
    let task: ToolTaskActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ToolTaskStatus(status: task.status, showLabel: true)
            if let summary = task.summary, summary != task.title {
                Text(summary).font(.ripul(.callout)).textSelection(.enabled)
                    .accessibilityIdentifier("ToolTask.outcome")
            }
            if let error = task.error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.ripul(.callout)).foregroundStyle(.ripul(.danger)).textSelection(.enabled)
                    .accessibilityIdentifier("ToolTask.error")
            }
            if let usage = task.usage {
                Text(usage).font(.ripul(.caption)).foregroundStyle(.ripul(.textSecondary)).monospacedDigit()
                    .accessibilityIdentifier("ToolTask.usage")
            }
            if let workflow = task.workflow {
                ToolWorkflowPhasesView(workflow: workflow)
            } else {
                recentActivity
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ToolTask.activity")
    }

    /// Direct children of the stack above, so they keep its spacing.
    @ViewBuilder private var recentActivity: some View {
        HStack {
            Text("Recent activity").font(.ripul(.headline))
            Spacer()
            if task.totalCount > 0 { Text("\(task.totalCount)").font(.ripul(.caption)).foregroundStyle(.ripul(.textSecondary)) }
        }
        if task.entries.isEmpty {
            Text(ToolTaskStatus.isBusy(task.status)
                ? "Working. Activity will appear here when reported."
                : "No activity was reported.")
                .font(.ripul(.callout)).foregroundStyle(.ripul(.textSecondary))
                .accessibilityIdentifier("ToolTask.emptyActivity")
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(task.entries.enumerated().reversed()), id: \.offset) { _, entry in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: entry.kind == "tool" ? "wrench" : "text.bubble")
                            .font(.ripulIcon(.caption)).foregroundStyle(.ripul(.textSecondary)).frame(width: 16)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            if let label = entry.label { Text(label).font(.ripul(.subheadline, weight: .medium)) }
                            if let detail = entry.detail {
                                Text(detail).font(.ripul(.callout, family: entry.kind == "tool" ? .code : nil))
                                    .foregroundStyle(.ripul(.textSecondary)).textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityIdentifier("ToolTask.activityEntry")
                }
            }
            if task.totalCount > task.entries.count {
                Text("\(task.totalCount - task.entries.count) earlier activities")
                    .font(.ripul(.caption)).foregroundStyle(.ripul(.textSecondary))
            }
        }
    }
}

/// A workflow run: its phases in order, each with the agents it started.
struct ToolWorkflowPhasesView: View {
    let workflow: ToolTaskActivity.Workflow

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(workflow.progress).font(.ripul(.headline)).monospacedDigit()
                .accessibilityIdentifier("ToolTask.workflowProgress")
            ForEach(workflow.phases) { phase in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        ToolWorkflowMark(state: phase.state)
                        Text(phase.title).font(.ripul(.subheadline, weight: .semibold))
                        Spacer(minLength: 8)
                        if !phase.count.isEmpty {
                            Text(phase.count).font(.ripul(.caption)).foregroundStyle(.ripul(.textSecondary)).monospacedDigit()
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("ToolTask.workflowPhase.\(phase.id)")
                    ForEach(phase.agents) { agent in
                        HStack(alignment: .top, spacing: 10) {
                            ToolWorkflowMark(state: agent.state, quiet: true).padding(.top, 3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(agent.label).font(.ripul(.callout))
                                if let detail = agent.detail {
                                    Text(detail).font(.ripul(.caption))
                                        .foregroundStyle(agent.state == "failed" ? Color.ripul(.danger) : Color.ripul(.textSecondary))
                                        .textSelection(.enabled)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.leading, 20)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("ToolTask.workflowAgent.\(phase.id).\(agent.id)")
                    }
                    if phase.omitted > 0 {
                        Text("\(phase.omitted) more \(phase.omitted == 1 ? "agent" : "agents") not listed")
                            .font(.ripul(.caption)).foregroundStyle(.ripul(.textSecondary)).padding(.leading, 42)
                            .accessibilityIdentifier("ToolTask.workflowOmitted.\(phase.id)")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ToolTask.workflow")
    }
}

/// The mark beside a phase or an agent. `quiet` draws a working agent as a
/// still dot: a wide phase would otherwise run a spinner on every row for as
/// long as the run lasts.
struct ToolWorkflowMark: View {
    let state: String
    var quiet = false

    var body: some View {
        switch state {
        case "queued":
            still("circle", color: Color.ripul(.textSecondary).opacity(0.6), label: "Waiting")
        case "running" where quiet:
            still("circle.fill", color: .ripul(.info), label: "Working")
        case "done":
            ToolTaskStatus(status: "completed")
        default:
            ToolTaskStatus(status: state)
        }
    }

    private func still(_ symbol: String, color: Color, label: String) -> some View {
        Image(systemName: symbol).font(.ripulIcon(size: 12)).frame(width: 12, height: 12)
            .foregroundStyle(color)
            .accessibilityLabel(label)
    }
}
