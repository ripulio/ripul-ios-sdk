import SwiftUI

/// Something a Mac host is warning its owner about: low disk space, a drive
/// it relies on being unplugged. The host raises and clears these
/// (HostAlertsRemoteActionProvider.swift on the Mac) and carries the current
/// list in its registry meta (`alerts`, a JSON string; `src/relay/hostAlerts.ts`
/// in the web app). The machine's row shows them as a bell, opening
/// `HostAlertsSheet`.
public struct HostAlert: Decodable, Identifiable, Equatable {
    public enum Severity: String, Decodable { case info, warning, critical }

    public let id: String
    public let severity: Severity
    public let title: String
    public let detail: String
    public let raisedAt: String
    /// A remote action on the host that deals with it, offered as a button.
    public let actionId: String?
    public let actionTitle: String?

    private nonisolated(unsafe) static let dateFormatter = ISO8601DateFormatter()

    public var raisedDate: Date? { Self.dateFormatter.date(from: raisedAt) }

    var icon: String {
        switch severity {
        case .critical: return "exclamationmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    var color: Color {
        switch severity {
        case .critical: return Color.ripul(.danger)
        case .warning: return Color.ripul(.warning)
        case .info: return Color.ripul(.info)
        }
    }
}

public extension RemoteMachine {
    /// The host's current alerts, worst first (the host sorts them). Empty for
    /// a host that has none or predates alerts.
    var alerts: [HostAlert] {
        guard let text = meta?["alerts"], let data = text.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([HostAlert].self, from: data)) ?? []
    }
}

/// A machine's alerts, each with the action that deals with it when the host
/// offers one (e.g. clearing old /tmp builds when the disk is low).
public struct HostAlertsSheet: View {
    let machineName: String
    let alerts: [HostAlert]
    /// Runs an alert's action on the host. Nil = the buttons are not offered.
    let onExecute: ((RemoteActionDescriptor) async -> [String: Any])?
    @Environment(\.dismiss) private var dismiss
    @State private var running: String?
    @State private var outcomes: [String: (text: String, ok: Bool)] = [:]
    @State private var confirming: HostAlert?

    public init(machineName: String, alerts: [HostAlert],
                onExecute: ((RemoteActionDescriptor) async -> [String: Any])?) {
        self.machineName = machineName
        self.alerts = alerts
        self.onExecute = onExecute
    }

    public var body: some View {
        NavigationStack {
            Form {
                if alerts.isEmpty {
                    Section {
                        Label("Nothing to report", systemImage: "checkmark.circle")
                            .foregroundStyle(.ripul(.success))
                    }.ripulThemedListRows()
                }
                ForEach(alerts) { alert in
                    Section { row(alert) }.ripulThemedListRows()
                }
            }
            .ripulThemedList()
            .navigationTitle("\(machineName) Alerts")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.uiKitIdentifier("HostAlertsSheet.done")
                }
            }
            .confirmationDialog(confirming?.actionTitle ?? "", isPresented: Binding(
                get: { confirming != nil }, set: { if !$0 { confirming = nil } }
            ), titleVisibility: .visible, presenting: confirming) { alert in
                Button(alert.actionTitle ?? "Run", role: .destructive) { run(alert) }
                    .uiKitIdentifier("HostAlertsSheet.confirm")
            } message: { _ in
                Text("Runs on \(machineName).")
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 360)
        #endif
        .ripulSheet(.page, detents: [.medium, .large])
    }

    private func row(_ alert: HostAlert) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(alert.title).ripulText()
                    .font(.ripul(.headline))
            } icon: {
                Image(systemName: alert.icon).foregroundStyle(alert.color)
            }
            .uiKitIdentifier("HostAlertsSheet.title")
            if !alert.detail.isEmpty {
                Text(alert.detail)
                    .font(.ripul(.subheadline))
                    .foregroundStyle(.ripul(.textSecondary))
                    .uiKitIdentifier("HostAlertsSheet.detail")
            }
            if let date = alert.raisedDate {
                Text("Since \(date.formatted(.relative(presentation: .named)))")
                    .font(.ripul(.caption))
                    .foregroundStyle(.ripul(.textSecondary))
            }
            if let title = alert.actionTitle, alert.actionId != nil, onExecute != nil {
                HStack(spacing: 8) {
                    Button(title) { confirming = alert }
                        .buttonStyle(.bordered)
                        .disabled(running != nil)
                        .uiKitIdentifier("HostAlertsSheet.action")
                    if running == alert.id { ProgressView().controlSize(.small) }
                }
            }
            if let outcome = outcomes[alert.id] {
                Text(outcome.text)
                    .font(.ripul(.caption))
                    .foregroundStyle(outcome.ok ? Color.ripul(.success) : Color.ripul(.danger))
                    .uiKitIdentifier("HostAlertsSheet.outcome")
            }
        }
        .padding(.vertical, 4)
    }

    private func run(_ alert: HostAlert) {
        guard let actionId = alert.actionId, let onExecute else { return }
        // The host checks again after its action, and the row's alerts follow
        // with the machine list, so the outcome is shown here meanwhile.
        let action = RemoteActionDescriptor(id: actionId, displayName: alert.actionTitle ?? actionId,
                                            description: alert.title, category: "alerts",
                                            destructive: true, timeout: 900)
        running = alert.id
        Task {
            let result = await onExecute(action)
            running = nil
            if let error = result["error"] as? String {
                outcomes[alert.id] = (error, false)
            } else {
                outcomes[alert.id] = ((result["summary"] as? String) ?? "Done", true)
            }
        }
    }
}
