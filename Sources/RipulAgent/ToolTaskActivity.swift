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
        case "running", "pending", "streaming": return .blue
        case "completed", "success": return .green
        case "failed", "error": return .red
        case "ended", "orphaned", "killed", "stopped": return .orange
        default: return .secondary
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
            if Self.isBusy(status) && !reduceMotion {
                ProgressView().controlSize(.mini).tint(color).frame(width: 12, height: 12)
            } else {
                Image(systemName: symbol).font(.system(size: 12)).frame(width: 12, height: 12)
            }
            if showLabel { Text(Self.title(status)).font(.caption.weight(.medium)) }
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
                Text(summary).font(.callout).textSelection(.enabled)
                    .accessibilityIdentifier("ToolTask.outcome")
            }
            if let error = task.error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    .accessibilityIdentifier("ToolTask.error")
            }
            if let usage = task.usage {
                Text(usage).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .accessibilityIdentifier("ToolTask.usage")
            }
            HStack {
                Text("Recent activity").font(.headline)
                Spacer()
                if task.totalCount > 0 { Text("\(task.totalCount)").font(.caption).foregroundStyle(.secondary) }
            }
            if task.entries.isEmpty {
                Text(ToolTaskStatus.isBusy(task.status)
                    ? "Working. Activity will appear here when reported."
                    : "No activity was reported.")
                    .font(.callout).foregroundStyle(.secondary)
                    .accessibilityIdentifier("ToolTask.emptyActivity")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(task.entries.enumerated().reversed()), id: \.offset) { _, entry in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: entry.kind == "tool" ? "wrench" : "text.bubble")
                                .font(.caption).foregroundStyle(.secondary).frame(width: 16)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                if let label = entry.label { Text(label).font(.subheadline.weight(.medium)) }
                                if let detail = entry.detail {
                                    Text(detail).font(.system(.callout, design: entry.kind == "tool" ? .monospaced : .default))
                                        .foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .accessibilityIdentifier("ToolTask.activityEntry")
                    }
                }
                if task.totalCount > task.entries.count {
                    Text("\(task.totalCount - task.entries.count) earlier activities")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ToolTask.activity")
    }
}
