import SwiftUI

// MARK: - Claude Accounts Settings Screen

/// Settings > Claude Accounts — one row per host machine showing that
/// machine's ACTIVE Claude account; tapping opens the machine-global switcher
/// (ClaudeAccountSwitcherSheet). The session list's per-machine Claude row
/// opens the same sheet — this screen is the discoverable home, that row is
/// the fast path.
public struct ClaudeAccountsSettingsScreen: View {
    let bridge: AgentBridge

    @State private var machines: [RemoteMachine] = []
    @State private var loading = true
    @State private var activeByMachine: [String: String] = [:]
    @State private var switcherMachine: RemoteMachine?

    public init(bridge: AgentBridge) {
        self.bridge = bridge
    }

    public var body: some View {
        Group {
            if loading && machines.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading machines…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if machines.isEmpty {
                ContentUnavailableView(
                    "No host machines",
                    systemImage: "macbook.and.iphone",
                    description: Text("Claude Code sessions run on your paired machines. Once a machine hosts sessions, its account appears here.")
                )
            } else {
                List {
                    Section {
                        ForEach(machines) { machine in
                            machineRow(machine)
                        }
                    } footer: {
                        Text("Each machine runs its CLI sessions under one Claude account at a time. Switching is instant and machine-wide; running sessions switch after their current reply.")
                    }
                }
            }
        }
        .navigationTitle("Claude Accounts")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
        .sheet(item: $switcherMachine) { machine in
            ClaudeAccountSwitcherSheet(machine: machine, bridge: bridge) { activeProfile in
                if let activeProfile {
                    activeByMachine[machine.machineId] = activeProfile.email ?? activeProfile.name
                }
            }
        }
    }

    @ViewBuilder
    private func machineRow(_ machine: RemoteMachine) -> some View {
        Button {
            switcherMachine = machine
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "desktopcomputer")
                    .foregroundStyle(machine.isOnline ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(machine.displayName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(activeByMachine[machine.machineId] ?? (machine.isOnline ? "Loading…" : "Offline"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .disabled(!machine.isOnline)
        .uiKitIdentifier("ClaudeAccountsSettingsScreen.machineRow")
    }

    private func load() async {
        loading = true
        // Chat hosts only — a browser host can't run CLI sessions, so an
        // account row for it would promise a switch it can't deliver.
        machines = await bridge.listMachines().filter { $0.can("cli") }
        loading = false
        await withTaskGroup(of: (String, String?).self) { group in
            for machine in machines where machine.isOnline {
                group.addTask { [bridge] in
                    let result = await bridge.fetchClaudeAccounts(machineId: machine.machineId)
                    let active = result.accounts.first { $0.slug == result.active }
                    return (machine.machineId, active?.email ?? active?.name)
                }
            }
            for await (machineId, label) in group {
                activeByMachine[machineId] = label ?? "—"
            }
        }
    }
}
