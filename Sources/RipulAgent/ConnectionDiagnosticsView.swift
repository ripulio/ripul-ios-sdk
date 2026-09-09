import SwiftUI

// MARK: - Structured rendering of a ConnectionDiagnosticsReport
//
// The sections are ordered by what a failing connect actually needs answered:
// where did it stall → was the machine we wanted reachable → what are the
// transports doing → is the client itself healthy. The raw JSON is never
// removed, only demoted behind a disclosure and a copy button.

@available(iOS 17.0, macOS 14.0, *)
struct ConnectionDiagnosticsView: View {
    let report: ConnectionDiagnosticsReport

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let phase = report.phase {
                phaseCard(phase)
            }
            if !report.machines.isEmpty {
                machinesSection
            }
            if !report.transports.isEmpty {
                transportsSection
            }
            if !report.pairingGroups.isEmpty {
                pairingsSection
            }
            clientSection
            if !report.sectionErrors.isEmpty {
                sectionErrorsSection
            }
        }
    }

    // MARK: Stall point

    @ViewBuilder
    private func phaseCard(_ phase: ConnectionDiagnosticsReport.Phase) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: phase.isStalled ? "exclamationmark.triangle.fill" : "flag.checkered")
                    .foregroundStyle(phase.isStalled ? .orange : .secondary)
                Text(phase.isStalled ? "Stalled here" : "Reached")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let elapsed = phase.elapsedText {
                    Text(elapsed)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Text(phase.title)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let explanation = phase.scopeExplanation {
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let machine = report.targetMachine {
                HStack(spacing: 6) {
                    statusDot(machine.presumedOnline ? .green : .orange)
                    Text("Talking to \(machine.displayName)")
                        .font(.caption)
                    if let seen = machine.lastSeenText {
                        Text("· last seen \(seen)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if !phase.detailFields.isEmpty {
                chipRow(phase.detailFields.map { "\($0.key) \($0.value)" })
            }
            Text(phase.raw)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(phase.isStalled ? 0.12 : 0.06))
        )
        .accessibilityElement(children: .combine)
    }

    // MARK: Machines

    private var machinesSection: some View {
        section("Machines", subtitle: report.remoteBridgeAvailable == false ? "relay bridge unavailable" : nil) {
            ForEach(report.machines) { machine in
                HStack(spacing: 8) {
                    statusDot(machine.presumedOnline ? .green : .orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(machine.displayName)
                            .font(.caption.weight(machine.machineId == report.targetMachineId ? .semibold : .regular))
                        Text(machine.presumedOnline ? "presumed online" : "looks offline")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if let seen = machine.lastSeenText {
                        Text(seen)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: Transports

    private var transportsSection: some View {
        let unhealthy = report.unhealthyTransports.count
        return section("Connections", subtitle: unhealthy > 0 ? "\(unhealthy) not established" : "all established") {
            ForEach(report.transports) { transport in
                HStack(alignment: .top, spacing: 8) {
                    statusDot(color(for: transport.health))
                        .padding(.top, 3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(transport.label)
                            .font(.caption.monospaced())
                        Text(transport.detailText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func color(for health: ConnectionDiagnosticsReport.TransportHealth) -> Color {
        switch health {
        case .healthy: return .green
        case .connecting: return .yellow
        case .reconnecting: return .orange
        case .down: return .red
        case .untracked: return .secondary
        }
    }

    // MARK: Pairings

    private var pairingsSection: some View {
        section("Paired sessions", subtitle: "\(report.totalPairings) total") {
            ForEach(report.pairingGroups) { group in
                HStack(spacing: 8) {
                    Text(group.machineName).font(.caption)
                    Spacer(minLength: 8)
                    Text("\(group.tabCount)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: Client

    private var clientSection: some View {
        section("This device", subtitle: nil) {
            if let build = report.build { keyValue("Build", build) }
            if let uptime = report.uptimeSec {
                keyValue("Uptime", ConnectionDiagnosticsReport.durationText(seconds: uptime))
            }
            if let capturedAt = report.capturedAt { keyValue("Captured", capturedAt) }
            if report.hasCrash {
                if let live = report.crashLive { keyValue("Crash (live)", live, tint: .red) }
                if let persisted = report.crashPersisted { keyValue("Last crash", persisted, tint: .orange) }
            } else {
                keyValue("Crashes", "none recorded")
            }
        }
    }

    private var sectionErrorsSection: some View {
        section("Unavailable data", subtitle: nil) {
            ForEach(report.sectionErrors.sorted(by: { $0.key < $1.key }), id: \.key) { key, message in
                keyValue(key, message, tint: .orange)
            }
        }
    }

    // MARK: Building blocks

    @ViewBuilder
    private func section<Content: View>(
        _ title: String,
        subtitle: String?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let subtitle {
                    Text("· \(subtitle)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            VStack(alignment: .leading, spacing: 6) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
        }
    }

    private func keyValue(_ key: String, _ value: String, tint: Color? = nil) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(key)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.caption2.monospaced())
                .foregroundStyle(tint ?? .primary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func chipRow(_ items: [String]) -> some View {
        // Wraps naturally on narrow sheets; these are 1–3 short `key value` pairs.
        HStack(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.caption2.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(Color.primary.opacity(0.07))
                    )
            }
        }
    }

    private func statusDot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 7, height: 7)
    }
}
