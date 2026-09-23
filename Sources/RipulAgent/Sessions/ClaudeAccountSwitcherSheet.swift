import SwiftUI

// MARK: - Claude Account Switcher Sheet

/// Machine-global Claude account switcher for a paired host (or this Mac).
///
/// One tap switches the host's ACTIVE account: idle CLI sessions recycle onto
/// it immediately (`--resume` keeps the conversation — every profile shares
/// the one session store via the projects symlink), and busy sessions switch
/// after their current reply. A profile with no login yet routes the tap into
/// a profile-scoped HostSignInSheet instead — switching to a dead account
/// would just 401 every session.
///
/// Each profile keeps its own OAuth credential (Keychain namespaced per
/// CLAUDE_CONFIG_DIR), so adding an account never disturbs the active one.
public struct ClaudeAccountSwitcherSheet: View {
    let machine: RemoteMachine
    let bridge: AgentBridge
    /// Fires after a successful switch so the caller can refresh its label.
    var onSwitched: ((ClaudeAccountProfile?) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    public init(machine: RemoteMachine, bridge: AgentBridge, onSwitched: ((ClaudeAccountProfile?) -> Void)? = nil) {
        self.machine = machine
        self.bridge = bridge
        self.onSwitched = onSwitched
    }

    public var body: some View {
        NavigationStack {
            List { ClaudeAccountSection(machine: machine, bridge: bridge, onSwitched: onSwitched) }
                .navigationTitle("Claude accounts")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }.uiKitIdentifier("ClaudeAccountSwitcherSheet.done")
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 420)
        #endif
        .ripulSheet(.page, detents: [.medium, .large])
    }
}

/// Account rows shared by Settings and the per-machine shortcut, without another navigation layer.
struct ClaudeAccountSection: View {
    let machine: RemoteMachine
    let bridge: AgentBridge
    var onSwitched: ((ClaudeAccountProfile?) -> Void)? = nil
    var refreshToken: UUID? = nil
    @Environment(\.scenePhase) private var scenePhase

    @State private var accounts: [ClaudeAccountProfile] = []
    @State private var active: String = "default"
    @State private var loading = true
    @State private var error: String?
    @State private var switchingTo: String?
    @State private var addingAccount = false
    @State private var newName = ""
    @State private var signInProfile: ClaudeAccountProfile?
    @State private var deleteCandidate: ClaudeAccountProfile?

    var body: some View {
        Section {
            if !machine.isOnline {
                Text("Connect to this Mac to manage accounts.").foregroundStyle(.secondary)
            } else {
                if loading && accounts.isEmpty {
                    ProgressView("Loading accounts…").uiKitIdentifier("ClaudeAccountSwitcherSheet.loading")
                }
                ForEach(accounts) { account in accountRow(account) }
                if let error, !error.isEmpty {
                    Text(error).font(.caption).foregroundStyle(.orange)
                    Button("Retry") { Task { await refresh() } }.disabled(loading)
                }
                if addingAccount {
                    HStack(spacing: 8) {
                        TextField("Account name (e.g. Work)", text: $newName)
                            #if os(iOS)
                            .textInputAutocapitalization(.words)
                            #endif
                            .uiKitIdentifier("ClaudeAccountSwitcherSheet.nameField")
                        Button("Create") { Task { await createAndSignIn() } }
                            .disabled(loading || newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .uiKitIdentifier("ClaudeAccountSwitcherSheet.createAccount")
                        Button("Cancel") { addingAccount = false; newName = "" }.disabled(loading)
                    }
                } else {
                    Button { addingAccount = true } label: { Label("Add account", systemImage: "plus") }
                        .disabled(loading || switchingTo != nil)
                        .uiKitIdentifier("ClaudeAccountSwitcherSheet.addAccount")
                }
            }
        } header: {
            HStack {
                Label(machine.displayName, systemImage: "desktopcomputer")
                Spacer()
                if !machine.isOnline { Text("Offline") }
            }
        } footer: {
            if machine.isOnline {
                Text("New sessions use the selected account. Running sessions switch after their current reply.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: refreshToken) {
            repeat {
                await refresh()
                do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { break }
            } while !Task.isCancelled
        }
        .onChange(of: scenePhase) { phase in if phase == .active { Task { await refresh() } } }
        .sheet(item: $signInProfile) { profile in
            HostSignInSheet(machine: machine, bridge: bridge, profile: profile.slug, profileName: profile.name,
                            startSignInImmediately: profile.loggedIn)
        }
        .confirmationDialog(
            "Remove \(deleteCandidate?.name ?? "account")?",
            isPresented: Binding(
                get: { deleteCandidate != nil },
                set: { if !$0 { deleteCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Account", role: .destructive) {
                if let candidate = deleteCandidate {
                    Task { await deleteAccount(candidate) }
                }
            }
            Button("Cancel", role: .cancel) { deleteCandidate = nil }
        } message: {
            Text("This deletes the profile and its sign-in on \(machine.displayName). Conversations are shared across accounts and are kept.")
        }
        // A completed (or cancelled) sign-in changes the list — refresh when
        // the sheet dismisses.
        .onChange(of: signInProfile) { _, newValue in
            if newValue == nil { Task { await refresh() } }
        }
    }

    @ViewBuilder
    private func accountRow(_ account: ClaudeAccountProfile) -> some View {
        let isActive = account.slug == active
        Button {
            Task { await handleTap(account) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Image(systemName: "person.circle")
                        .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.isDefault ? "\(account.name) (this Mac's login)" : account.name)
                            .font(.subheadline.weight(isActive ? .semibold : .regular))
                            .foregroundStyle(.primary)
                        Text(account.email ?? (account.loggedIn ? "Signed in" : "Not signed in — tap to sign in"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if switchingTo == account.slug {
                        ProgressView()
                    } else if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                if account.loggedIn {
                    CodingAccountUsageView(usage: account.usage, plan: account.plan)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(loading || switchingTo != nil)
        .uiKitIdentifier("ClaudeAccountSwitcherSheet.accountRow.\(account.slug)")
        .contextMenu {
            if account.loggedIn {
                Button("Sign in again", systemImage: "arrow.clockwise") { signInProfile = account }
            }
        }
        // The default profile is the Mac's own login — removing it would sign the Mac
        // out of Claude entirely, so only extra profiles offer removal.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !account.isDefault {
                Button(role: .destructive) {
                    deleteCandidate = account
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .uiKitIdentifier("ClaudeAccountSwitcherSheet.accountRow.\(account.slug).delete")
            }
        }
        if account.loggedIn, account.usage?.error != nil {
            Button("Sign in again") { signInProfile = account }
                .font(.subheadline)
                .disabled(loading || switchingTo != nil)
                .uiKitIdentifier("ClaudeAccountSwitcherSheet.accountRow.\(account.slug).signInAgain")
        }
    }

    private func handleTap(_ account: ClaudeAccountProfile) async {
        if (account.slug == active && account.loggedIn) || switchingTo != nil { return }
        // No login yet → sign the profile in rather than switching to it.
        guard account.loggedIn else {
            signInProfile = account
            return
        }
        switchingTo = account.slug
        let result = await bridge.switchClaudeAccount(machineId: machine.machineId, slug: account.slug)
        switchingTo = nil
        if result.ok {
            active = result.active ?? account.slug
            onSwitched?(accounts.first { $0.slug == active })
        } else {
            error = result.error ?? "Switch failed"
        }
    }

    private func createAndSignIn() async {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        loading = true
        let result = await bridge.createClaudeAccount(machineId: machine.machineId, name: name)
        loading = false
        if result.ok, let slug = result.slug {
            addingAccount = false
            newName = ""
            await refresh()
            signInProfile = ClaudeAccountProfile(
                slug: slug, name: result.name ?? name, email: nil, loggedIn: false, isDefault: false
            )
        } else {
            error = result.error ?? "Could not create the account"
        }
    }

    private func deleteAccount(_ account: ClaudeAccountProfile) async {
        deleteCandidate = nil
        loading = true
        let result = await bridge.deleteClaudeAccount(machineId: machine.machineId, slug: account.slug)
        loading = false
        if result.ok {
            await refresh()
        } else {
            error = result.error ?? "Could not remove the account"
        }
    }

    private func refresh() async {
        guard machine.isOnline else { loading = false; return }
        loading = true
        let result = await bridge.fetchClaudeAccounts(machineId: machine.machineId)
        if result.error == nil { accounts = result.accounts; active = result.active }
        error = result.error
        loading = false
    }
}
