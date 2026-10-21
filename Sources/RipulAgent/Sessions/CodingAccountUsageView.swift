import SwiftUI

/// The plan an account is on, as a small pill. Shown beside the account's name.
struct CodingAccountPlanBadge: View {
    let name: String

    init?(usage: CodingAccountUsage?, plan: String?) {
        guard let name = CodingAccountUsage.planName(usage?.plan ?? plan) else { return nil }
        self.name = name
    }

    var body: some View {
        Text(name)
            .font(.ripul(.caption2, weight: .medium))
            .foregroundStyle(.ripul(.textSecondary))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.ripul(.textSecondary).opacity(0.12), in: Capsule())
            .fixedSize()
    }
}

/// What an account row offers at its trailing edge.
enum CodingAccountRowAction {
    case busy
    case signIn(String, () -> Void)
    case active
    case switchTo(() -> Void)
}

/// One coding account, as both the Claude and Codex sections draw it: who it
/// is, its plan, what can be done with it, and its usage beneath.
struct CodingAccountRow: View {
    let name: String
    var detail: String? = nil
    let isActive: Bool
    let usage: CodingAccountUsage?
    var plan: String? = nil
    var showsUsage = true
    let action: CodingAccountRowAction
    var disabled = false
    /// Prefix for the action buttons' identifiers (`.signIn`, `.switch`).
    let identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "person.crop.circle")
                    .font(.ripul(.title3))
                    .foregroundStyle(isActive ? Color.accentColor : Color.ripul(.textSecondary))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(name).font(.ripul(.body, weight: isActive ? .semibold : .regular))
                            .foregroundStyle(.ripul(.text)).lineLimit(1).truncationMode(.middle)
                        CodingAccountPlanBadge(usage: usage, plan: plan)
                    }
                    if let detail, detail != name {
                        Text(detail).font(.ripul(.caption)).foregroundStyle(.ripul(.textSecondary)).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                accessory
            }
            if showsUsage {
                CodingAccountUsageView(usage: usage, plan: plan, showsPlan: false)
                    .padding(.leading, 36)
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder private var accessory: some View {
        switch action {
        case .busy:
            ProgressView()
        case .signIn(let title, let perform):
            Button(title, action: perform)
                .ripulProminentButtonStyle().controlSize(.small).disabled(disabled)
                .uiKitIdentifier("\(identifier).signIn")
        case .active:
            Text("Active").font(.ripul(.caption, weight: .medium)).foregroundStyle(Color.accentColor)
        case .switchTo(let perform):
            Button("Switch", action: perform)
                .buttonStyle(.bordered).controlSize(.small).disabled(disabled)
                .uiKitIdentifier("\(identifier).switch")
        }
    }
}

/// On a wide Catalyst or Mac window the rows would stretch edge to edge,
/// leaving a usage label and its percentage a screen apart.
struct CodingAccountsListWidth: ViewModifier {
    func body(content: Content) -> some View {
        GeometryReader { proxy in
            content.contentMargins(.horizontal, max(0, (proxy.size.width - 680) / 2), for: .scrollContent)
        }
    }
}

/// Shared by the Claude and Codex account rows, including inactive accounts.
///
/// When the host could not refresh an account (`usage.error`), the windows it
/// still carries are the last ones it read, possibly weeks old. They are not
/// drawn: an old 93% bar reads exactly like a live one.
struct CodingAccountUsageView: View {
    let usage: CodingAccountUsage?
    var plan: String? = nil
    /// False when the row shows the plan itself, beside the account's name.
    var showsPlan = true

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = context.date.timeIntervalSince1970
            VStack(alignment: .leading, spacing: 8) {
                if showsPlan, let badge = CodingAccountPlanBadge(usage: usage, plan: plan) { badge }
                if usage?.error == nil {
                    ForEach(usage?.windows ?? []) { window in windowRow(window, now: now) }
                }
                if let line = statusLine(now: now) {
                    Text(line).font(.ripul(.caption)).foregroundStyle(.ripul(.textSecondary))
                }
            }
        }
        .foregroundStyle(.ripul(.text))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
    }

    private func windowRow(_ window: CodingAccountUsage.Window, now: Double) -> some View {
        let used = min(100, max(0, window.usedPercent))
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(window.label) · \(Text("\(used, specifier: "%.0f")% used").monospacedDigit())")
                Spacer(minLength: 8)
                if let reset = window.resetsAt, reset > now {
                    Text("Resets \(Date(timeIntervalSince1970: reset).formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
                        .foregroundStyle(.ripul(.textSecondary))
                }
            }
            .font(.ripul(.caption))
            // Drawn rather than a ProgressView: Mac Catalyst draws its bar in
            // the accent colour whatever tint it is given.
            Capsule()
                .fill(Color.ripul(.textSecondary).opacity(0.18))
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule().fill(barColour(used)).frame(width: max(4, proxy.size.width * used / 100))
                    }
                }
                .frame(height: 6)
                .accessibilityLabel(window.label)
                .accessibilityValue(Text("\(used, specifier: "%.0f") percent used"))
        }
    }

    private func barColour(_ used: Double) -> Color {
        used >= 95 ? .ripul(.danger) : used >= 80 ? .ripul(.warning) : .accentColor
    }

    private func statusLine(now: Double) -> String? {
        let updated = usage?.updatedAt
        if let message = usage?.error {
            guard let updated else { return message }
            return "Usage not checked for \(age(now - updated))"
        }
        if usage?.windows.isEmpty != false {
            return updated == nil ? "Usage unavailable" : "No usage limits reported"
        }
        if let updated, now - updated > 120 { return "Last checked \(age(now - updated)) ago" }
        return nil
    }

    private func age(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = [.day, .hour, .minute]
        return formatter.string(from: max(60, seconds)) ?? "a while"
    }
}
