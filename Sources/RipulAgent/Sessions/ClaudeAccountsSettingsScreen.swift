import SwiftUI

/// Every host and its accounts are visible together; tapping an account switches that host.
public struct ClaudeAccountsSettingsScreen: View {
    let bridge: AgentBridge
    @State private var machines: [RemoteMachine] = []
    @State private var loading = true
    @State private var refreshToken = UUID()
    @State private var signIn: ClaudeAccountSignInRequest?

    public init(bridge: AgentBridge) { self.bridge = bridge }

    public var body: some View {
        List {
            if loading && machines.isEmpty {
                ProgressView("Loading Macs…")
            } else if machines.isEmpty {
                NoPairedMacView("See and switch the Claude accounts on your Mac.")
            }
            ForEach(machines) { machine in
                ClaudeAccountSection(machine: machine, bridge: bridge,
                    onSignIn: { signIn = ClaudeAccountSignInRequest(machine: machine, profile: $0) },
                    refreshToken: refreshToken)
            }
        }.ripulThemedList()
        .navigationTitle("Claude accounts")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
        .refreshable { await load(); refreshToken = UUID() }
        .ripulSheet(item: $signIn, onDismiss: { refreshToken = UUID() }) { request in
            HostSignInSheet(machine: request.machine, bridge: bridge,
                profile: request.profile.slug, profileName: request.profile.name,
                startSignInImmediately: request.profile.loggedIn)
        }
    }

    private func load() async {
        machines = await bridge.listMachines().filter { $0.can("cli") }
        loading = false
    }
}
