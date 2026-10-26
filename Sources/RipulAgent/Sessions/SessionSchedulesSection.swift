import SwiftUI

/// The schedules that wake this chat, under its observations: messages a
/// person set with Send Later and wakes an agent set with `ripul_schedule`
/// (docs/plans/scheduled-agent-runs.md). A person can pause, resume, run now
/// and delete them here.
///
/// The panel loads the list and leaves this section out while it is empty: a
/// section that hid itself could not load, since a view with nothing in it
/// never runs its tasks. A change made here reloads the panel's list through
/// `AgentBridge.schedulesChangedNotification`.
@available(iOS 15.0, macOS 13.0, *)
struct SessionSchedulesSection: View {
    let bridge: AgentBridge
    let chatId: String
    let schedules: [AgentBridge.ChatSchedule]
    @Binding var isExpanded: Bool

    @State private var error: String?

    /// Finished ones shown beneath the rest, newest first.
    private static let finishedShown = 3

    /// Every one that can still run, then the latest finished ones.
    private var shown: [AgentBridge.ChatSchedule] {
        let finished = schedules.filter(\.isFinished)
            .sorted { ($0.lastRunAt ?? .distantPast) > ($1.lastRunAt ?? .distantPast) }
        return schedules.filter { !$0.isFinished } + finished.prefix(Self.finishedShown)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded { content }
        }
        .modifier(GlassPanelBackground())
        .uiKitIdentifier("SessionMetadataPanel.schedules")
    }

    private func change(_ schedule: AgentBridge.ChatSchedule, _ action: String) {
        Task {
            error = await bridge.changeSchedule(chatId: chatId, id: schedule.id, action: action)
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "chevron.right")
                .font(.ripulIcon(.caption2, weight: .semibold))
                .foregroundStyle(.ripul(.textSecondary))
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .animation(.easeInOut(duration: 0.2), value: isExpanded)
            Text("Schedules")
                .font(.ripul(.subheadline, weight: .semibold))
                .foregroundStyle(.ripul(.textSecondary))
                .textCase(.uppercase)
            let live = schedules.filter(\.isLive).count
            if live > 0 {
                Text("\(live)")
                    .font(.ripul(.caption))
                    .foregroundStyle(.ripul(.textTertiary))
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, schedule in
                if index > 0 { Divider().padding(.leading, 35) }
                row(schedule).padding(.horizontal, 16)
            }
            if let error {
                Text(error)
                    .font(.ripul(.caption))
                    .foregroundStyle(.ripul(.danger))
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
            }
        }
        .padding(.bottom, 8)
    }

    private func detail(_ schedule: AgentBridge.ChatSchedule) -> String {
        var parts = [schedule.when]
        if schedule.isLive, let next = schedule.nextRunAt {
            parts.append("next \(next.formatted(date: Calendar.current.isDateInToday(next) ? .omitted : .abbreviated, time: .shortened))")
        } else {
            parts.append(schedule.stateLabel)
        }
        parts.append(schedule.author == "agent" ? "set by an agent" : "set by a person")
        return parts.joined(separator: " · ")
    }

    private func row(_ schedule: AgentBridge.ChatSchedule) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: schedule.isLive ? "clock" : "clock.badge.checkmark")
                .font(.ripulIcon(.caption))
                .foregroundStyle(schedule.isLive ? .ripul(.info) : .ripul(.textTertiary))
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(schedule.name)
                    .font(.ripul(.subheadline))
                    .foregroundStyle(schedule.isLive ? .ripul(.text) : .ripul(.textSecondary))
                    .lineLimit(2)
                Text(detail(schedule))
                    .font(.ripul(.caption))
                    .foregroundStyle(.ripul(.textTertiary))
            }
            Spacer(minLength: 8)
            Menu {
                if schedule.endedReason == nil || schedule.endedReason == "failures" {
                    if schedule.paused {
                        Button { change(schedule, "resume") } label: { Label("Resume", systemImage: "play") }
                    } else {
                        Button { change(schedule, "pause") } label: { Label("Pause", systemImage: "pause") }
                    }
                }
                Button { change(schedule, "run_now") } label: { Label("Run Now", systemImage: "bolt") }
                Button(role: .destructive) { change(schedule, "delete") } label: { Label("Delete", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.ripulIcon(.caption))
                    .foregroundStyle(.ripul(.textSecondary))
                    .frame(width: 32, height: 24)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Schedule actions")
            .uiKitIdentifier("SessionMetadataPanel.schedules.actions")
        }
        .padding(.vertical, 8)
    }
}
