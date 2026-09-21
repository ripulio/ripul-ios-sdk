import SwiftUI

/// Shared by the Claude and Codex account rows, including inactive accounts.
struct CodingAccountUsageView: View {
    let usage: CodingAccountUsage?
    var plan: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let name = CodingAccountUsage.planName(usage?.plan ?? plan) {
                Text("\(name) plan")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.secondary.opacity(0.1), in: Capsule())
            }
            ForEach(usage?.windows ?? []) { window in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(window.label)
                        Spacer(minLength: 8)
                        Text("\(window.usedPercent, specifier: "%.0f")% used").monospacedDigit()
                    }
                    ProgressView(value: min(100, max(0, window.usedPercent)), total: 100)
                        .tint(window.usedPercent >= 95 ? .red : window.usedPercent >= 80 ? .orange : .accentColor)
                        .accessibilityLabel(window.label)
                        .accessibilityValue(Text("\(window.usedPercent, specifier: "%.0f") percent used"))
                    if let reset = window.resetsAt {
                        Text("Resets \(Date(timeIntervalSince1970: reset).formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
            if let message = usage?.error {
                Text(message).font(.caption).foregroundStyle(.secondary)
            } else if usage?.windows.isEmpty != false {
                Text(usage?.updatedAt == nil ? "Usage unavailable" : "No usage limits reported")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let updated = usage?.updatedAt {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    if usage?.error != nil || context.date.timeIntervalSince1970 - updated > 120 {
                        Text("Last checked \(Date(timeIntervalSince1970: updated), style: .relative) ago")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
    }
}
