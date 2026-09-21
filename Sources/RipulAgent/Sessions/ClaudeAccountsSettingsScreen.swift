import SwiftUI

/// Every host and its accounts are visible together; tapping an account switches that host.
public struct ClaudeAccountsSettingsScreen: View {
    let bridge: AgentBridge
    @State private var machines: [RemoteMachine] = []
    @State private var loading = true
    @State private var refreshToken = UUID()

    public init(bridge: AgentBridge) { self.bridge = bridge }

    public var body: some View {
        List {
            if loading && machines.isEmpty {
                ProgressView("Loading Macs…")
            } else if machines.isEmpty {
                Text("Pair with a Mac to manage its Claude accounts.").foregroundStyle(.secondary)
            }
            ForEach(machines) { machine in
                ClaudeAccountSection(machine: machine, bridge: bridge, refreshToken: refreshToken)
            }
        }
        .navigationTitle("Claude accounts")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
        .refreshable { await load(); refreshToken = UUID() }
    }

    private func load() async {
        machines = await bridge.listMachines().filter { $0.can("cli") }
        loading = false
    }
}
