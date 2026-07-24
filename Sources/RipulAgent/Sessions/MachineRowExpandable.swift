import SwiftUI

// MARK: - Machine Row (Expandable)

/// Expandable machine row: header (name, online status, active-session count,
/// default star, folded quick-launch CLI buttons) with a disclosure body
/// offering New-Agent / new-CLI-session tiles and machine settings (restart,
/// set default, set icon, enable/disable).
///
/// The app's version also hosts a "remote actions" (scripts) grid + execution
/// sheet; that quick-actions feature is deferred and is not present here.
///
/// Cache-derived values (`allowRipulAgents`, `machineIcon`, `isMachineDisabled`,
/// `defaultMachineId`) are resolved by the parent — which owns the
/// `RipulSessionCache` — and passed in, with `onSetDefault` / `onSetIcon`
/// callbacks writing back through the same cache.
struct MachineRowExpandable: View {
    let machine: RemoteMachine
    let activeSessions: [ChatSession]
    let isConnecting: Bool
    @Binding var isExpanded: Bool
    let onConnect: () -> Void
    var onFocusSession: ((ChatSession) -> Void)? = nil
    var onNewCliSession: ((RemoteMachine, String) -> Void)? = nil
    var onRestart: ((RemoteMachine) -> Void)? = nil
    var onToggleDisabled: ((RemoteMachine) -> Void)? = nil
    var isRestarting: Bool = false
    var isRestartSucceeded: Bool = false

    // Cache-derived, resolved by the parent.
    var allowRipulAgents: Bool = false
    var machineIcon: String? = nil
    var isMachineDisabled: Bool = false
    var defaultMachineId: String = ""
    var onSetDefault: ((String) -> Void)? = nil
    var onSetIcon: ((String?) -> Void)? = nil

    @State private var loadingTile: String?
    @State private var showIconPicker = false

    private var isDefault: Bool { machine.machineId == defaultMachineId }

    private let gridColumns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(spacing: 10) {
                // === Primary section: square tiles ===
                LazyVGrid(columns: gridColumns, spacing: 10) {
                    // New Ripul Agent
                    if machine.isOnline && !isMachineDisabled && allowRipulAgents {
                        MachineActionTile(
                            icon: "plus.message.fill",
                            label: "New Agent",
                            subtitle: "Start a fresh Ripul agent",
                            isLoading: loadingTile == "newAgent"
                        ) {
                            loadingTile = "newAgent"
                            onConnect()
                        }
                    }

                    // CLI provider tiles (driven by providers.json)
                    if machine.isOnline && !isMachineDisabled, let newCliAction = onNewCliSession {
                        ForEach(ProviderConstants.cliProviders, id: \.id) { provider in
                            MachineActionTile(
                                icon: provider.sfSymbol,
                                label: provider.label,
                                subtitle: "Start a new remote \(provider.label) session",
                                tint: Color(hex: provider.color),
                                isLoading: loadingTile == provider.id
                            ) {
                                loadingTile = provider.id
                                newCliAction(machine, provider.providerKey!)
                            }
                        }
                    }
                }

                // === Secondary section: compact rows ===
                VStack(spacing: 0) {
                    // Restart Host
                    if (machine.isOnline && !isMachineDisabled && onRestart != nil) || isRestarting || isRestartSucceeded {
                        MachineActionRow(
                            icon: "arrow.triangle.2.circlepath",
                            label: "Restart Host",
                            tint: .orange,
                            isLoading: isRestarting,
                            isSucceeded: isRestartSucceeded,
                            loadingLabel: "Restarting…",
                            succeededLabel: "Restarted"
                        ) {
                            onRestart?(machine)
                        }
                    }

                    // Set as Default
                    MachineActionRow(
                        icon: isDefault ? "star.fill" : "star",
                        label: isDefault ? "Default Machine" : "Set as Default",
                        tint: .yellow
                    ) {
                        onSetDefault?(isDefault ? "" : machine.machineId)
                    }

                    // Set Icon
                    MachineActionRow(
                        icon: machineIcon ?? "photo.on.rectangle",
                        label: "Set Icon",
                        tint: .purple
                    ) {
                        showIconPicker = true
                    }

                    // Disable / Enable
                    if let onToggleDisabled {
                        MachineActionRow(
                            icon: isMachineDisabled ? "checkmark.circle" : "nosign",
                            label: isMachineDisabled ? "Enable" : "Disable",
                            tint: isMachineDisabled ? .green : .red
                        ) {
                            onToggleDisabled(machine)
                        }
                    }
                }
                .modifier(GlassTileBackground())
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: machineIcon ?? "desktopcomputer")
                    .font(.system(size: 16))
                    .foregroundStyle(.blue)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(machine.displayName)
                            .font(.body)
                            .lineLimit(1)
                            .uiKitIdentifier("MachineRowExpandable.name")
                        if machine.isOnline {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 8, height: 8)
                                .uiKitIdentifier("MachineRowExpandable.onlineDot")
                        }
                    }

                    if isRestarting {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("Restarting…")
                                .font(.caption)
                        }
                        .foregroundStyle(.orange)
                    } else if isRestartSucceeded {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption2)
                            Text("Restarted")
                                .font(.caption)
                        }
                        .foregroundStyle(.green)
                    } else if isMachineDisabled {
                        Text("Disabled")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if !machine.isOnline {
                        Text("Offline")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(activeSessions.isEmpty
                             ? "Online"
                             : "\(activeSessions.count) active \(activeSessions.count == 1 ? "session" : "sessions")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if isDefault {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                }

                if isConnecting || isRestarting {
                    ProgressView()
                        .controlSize(.small)
                }

                // Quick-launch buttons visible when folded (driven by providers.json)
                if !isExpanded && machine.isOnline && !isMachineDisabled, let newCliAction = onNewCliSession {
                    ForEach(ProviderConstants.cliProviders, id: \.id) { provider in
                        Button {
                            loadingTile = provider.id
                            newCliAction(machine, provider.providerKey!)
                        } label: {
                            if loadingTile == provider.id {
                                ProgressView().controlSize(.small)
                                    .frame(width: 32, height: 32)
                            } else {
                                Image(systemName: provider.sfSymbol)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Color(hex: provider.color))
                                    .frame(width: 32, height: 32)
                            }
                        }
                        .modifier(GlassCircleModifier(glassStyle: "regular"))
                        .buttonStyle(.plain)
                        .uiKitIdentifier("MachineRowExpandable.quick\(provider.id)")
                    }
                }
            }
            .padding(.vertical, 2)
            .opacity(machine.isOnline && !isMachineDisabled ? 1 : 0.5)
        }
        .onChange(of: isExpanded) { expanded in
            if !expanded { loadingTile = nil }
        }
        .onChange(of: activeSessions.count) { _ in
            loadingTile = nil
        }
        .onChange(of: isConnecting) { connecting in
            if !connecting { loadingTile = nil }
        }
        .sheet(isPresented: $showIconPicker) {
            MachineIconPicker(
                machineName: machine.displayName,
                currentIcon: machineIcon
            ) { icon in
                onSetIcon?(icon)
            }
        }
    }
}

// MARK: - Machine Action Tile

private struct MachineActionTile: View {
    let icon: String
    let label: String
    let subtitle: String
    var tint: Color = .blue
    var isLoading: Bool = false
    let action: () -> Void

    var body: some View {
        Button {
            if !isLoading { action() }
        } label: {
            VStack(spacing: 6) {
                if isLoading {
                    ProgressView()
                        .controlSize(.regular)
                        .tint(tint)
                        .frame(height: 22)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(tint)
                }
                VStack(spacing: 2) {
                    Text(isLoading ? "Connecting…" : label)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2, reservesSpace: true)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 90)
            .opacity(isLoading ? 0.7 : 1)
            .modifier(GlassTileBackground())
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }
}

// MARK: - Machine Action Row (compact, de-emphasized)

private struct MachineActionRow: View {
    let icon: String
    let label: String
    var tint: Color = .secondary
    var isLoading: Bool = false
    var isSucceeded: Bool = false
    var loadingLabel: String? = nil
    var succeededLabel: String? = nil
    let action: () -> Void

    private var displayLabel: String {
        if isLoading, let l = loadingLabel { return l }
        if isSucceeded, let l = succeededLabel { return l }
        return label
    }

    var body: some View {
        Button {
            if !isLoading && !isSucceeded { action() }
        } label: {
            HStack(spacing: 10) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(tint)
                        .frame(width: 18, height: 18)
                } else if isSucceeded {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.green)
                        .frame(width: 18)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(tint)
                        .frame(width: 18)
                }
                Text(displayLabel)
                    .font(.subheadline)
                    .foregroundStyle(isSucceeded ? .green : .primary)
                Spacer()
                if !isLoading && !isSucceeded {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.quaternary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .opacity(isLoading ? 0.7 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isLoading || isSucceeded)
    }
}

// MARK: - Glass Tile Background

private struct GlassTileBackground: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.clear.interactive(), in: .rect(cornerRadius: 14))
        } else {
            content
                .background {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(.ultraThinMaterial)
                        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(.white.opacity(0.25), lineWidth: 0.5)
                }
        }
        #else
        if #available(macOS 26.0, *) {
            content
                .background(.clear)
                .glassEffect(.clear.interactive(), in: .rect(cornerRadius: 14))
        } else {
            content
                .background {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(.ultraThinMaterial)
                        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(.white.opacity(0.25), lineWidth: 0.5)
                }
        }
        #endif
    }
}
