import SwiftUI

/// Send Later: the composer's message goes into this chat at a chosen time,
/// from a schedule the Ripul service keeps (docs/plans/scheduled-agent-runs.md).
/// It arrives after any task in hand, whether or not anyone has the chat open,
/// and survives the Mac sleeping.
@available(iOS 16.0, macOS 13.0, *)
public struct SendLaterSheet: View {
    let message: String
    /// Schedules the message; returns an error to show, or nil when it is scheduled.
    let onSchedule: (Date) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var when: Date
    @State private var choice: Choice
    @State private var scheduling = false
    @State private var error: String?

    enum Choice: Hashable { case quick(Int), custom }

    private struct Quick: Identifiable { let id: Int; let title: String; let date: Date }

    public init(message: String, onSchedule: @escaping (Date) async -> String?) {
        self.message = message
        self.onSchedule = onSchedule
        let quick = Self.quickChoices(now: Date())
        _when = State(initialValue: quick.first?.date ?? Date().addingTimeInterval(3600))
        _choice = State(initialValue: .quick(0))
    }

    /// In an hour, in three, this evening (before five), tomorrow morning.
    private static func quickChoices(now: Date) -> [Quick] {
        let calendar = Calendar.current
        var out = [
            Quick(id: 0, title: "In 1 hour", date: now.addingTimeInterval(3600)),
            Quick(id: 1, title: "In 3 hours", date: now.addingTimeInterval(3 * 3600)),
        ]
        if calendar.component(.hour, from: now) < 17,
           let evening = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: now) {
            out.append(Quick(id: 2, title: "This evening", date: evening))
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           let morning = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) {
            out.append(Quick(id: 3, title: "Tomorrow morning", date: morning))
        }
        return out
    }

    private var quick: [Quick] { Self.quickChoices(now: Date()) }

    private var range: ClosedRange<Date> {
        Date().addingTimeInterval(60)...Date().addingTimeInterval(90 * 24 * 3600)
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section(themed: "Message") {
                    Text(message)
                        .font(.ripul(.body))
                        .lineLimit(4)
                }
                Section(themed: "When") {
                    ForEach(quick) { option in
                        Button {
                            choice = .quick(option.id)
                            when = option.date
                        } label: {
                            HStack {
                                Text(option.title).font(.ripul(.body)).foregroundStyle(.ripul(.text))
                                Spacer()
                                Text(option.date.formatted(date: .omitted, time: .shortened))
                                    .font(.ripul(.callout))
                                    .foregroundStyle(.ripul(.textSecondary))
                                if choice == .quick(option.id) {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                    DatePicker("Pick a time", selection: Binding(
                        get: { when },
                        set: { when = $0; choice = .custom }
                    ), in: range)
                    .font(.ripul(.body))
                }
                Section {
                    EmptyView()
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if let error {
                            Text(error).font(.ripul(.caption)).foregroundStyle(.ripul(.danger))
                        }
                        Text("It arrives in this chat at that time, after any task in hand, even if nobody has the chat open or the Mac was asleep. Text only.")
                            .font(.ripul(.caption))
                            .foregroundStyle(.ripul(.textSecondary))
                    }
                }
            }
            .navigationTitle("Send Later")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(scheduling ? "Scheduling…" : "Schedule") {
                        scheduling = true
                        error = nil
                        Task {
                            let failure = await onSchedule(when)
                            scheduling = false
                            if let failure { error = failure } else { dismiss() }
                        }
                    }
                    .disabled(scheduling)
                }
            }
        }
    }
}
