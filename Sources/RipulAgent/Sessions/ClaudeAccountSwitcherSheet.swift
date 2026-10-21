import SwiftUI

// MARK: - Claude Account Switcher Sheet

/// Machine-global Claude account switcher for a paired host (or this Mac).
///
/// Switch makes it the host's ACTIVE account: idle CLI sessions recycle onto
/// it immediately (`--resume` keeps the conversation — every profile shares
/// the one session store via the projects symlink), and busy sessions switch
/// after their current reply. A profile with no login yet offers Sign in, into
/// a profile-scoped HostSignInSheet instead — switching to a dead account
/// would just 401 every session.
///
/// Each profile keeps its own OAuth credential (Keychain namespaced per
/// CLAUDE_CONFIG_DIR), so adding an account never disturbs the active one.
public struct ClaudeAccountSwitcherSheet: View {
    let machine: RemoteMachine
    let bridge: AgentBridge
    var chatId: String? = nil
    /// Fires after a successful switch so the caller can refresh its label.
    var onSwitched: ((ClaudeAccountProfile?) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var signIn: ClaudeAccountSignInRequest?
    @State private var refreshToken = UUID()

    public init(machine: RemoteMachine, bridge: AgentBridge, chatId: String? = nil, onSwitched: ((ClaudeAccountProfile?) -> Void)? = nil) {
        self.machine = machine
        self.bridge = bridge
        self.chatId = chatId
        self.onSwitched = onSwitched
    }

    public var body: some View {
        NavigationStack {
            List {
                ClaudeAccountSection(machine: machine, bridge: bridge, chatId: chatId,
                    onSignIn: { signIn = ClaudeAccountSignInRequest(machine: machine, profile: $0) },
                    onSwitched: onSwitched, refreshToken: refreshToken)
            }.ripulThemedList()
                .navigationTitle(chatId == nil ? "Claude accounts" : "Chat account")
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
        .ripulSheet(item: $signIn, onDismiss: { refreshToken = UUID() }) { request in
            HostSignInSheet(machine: request.machine, bridge: bridge,
                profile: request.profile.slug, profileName: request.profile.name,
                startSignInImmediately: request.profile.loggedIn)
        }
    }
}

/// The screen owns presentation, outside the List's changing form/account rows.
struct ClaudeAccountSignInRequest: Identifiable {
    let machine: RemoteMachine
    let profile: ClaudeAccountProfile
    var id: String { "\(machine.machineId)/\(profile.slug)" }
}

/// Account rows shared by Settings and the per-machine shortcut, without another navigation layer.
struct ClaudeAccountSection: View {
    let machine: RemoteMachine
    let bridge: AgentBridge
    var chatId: String? = nil
    let onSignIn: (ClaudeAccountProfile) -> Void
    var onSwitched: ((ClaudeAccountProfile?) -> Void)? = nil
    var refreshToken: UUID? = nil
    @Environment(\.scenePhase) private var scenePhase

    @State private var accounts: [ClaudeAccountProfile] = []
    @State private var active: String = "default"
    @State private var followsDefault = true
    @State private var loading = false
    @State private var error: String?
    @State private var switchingTo: String?
    @State private var addingAccount = false
    @State private var newName = ""
    @State private var deleteCandidate: ClaudeAccountProfile?

    var body: some View {
        Section {
            if !machine.isOnline {
                Text("Connect to this Mac to manage accounts.").foregroundStyle(.ripul(.textSecondary))
            } else {
                if loading && accounts.isEmpty {
                    ProgressView("Loading accounts…").uiKitIdentifier("ClaudeAccountSwitcherSheet.loading")
                }
                if chatId != nil && !accounts.isEmpty {
                    Button { Task { await selectAccount("__machine_default__") } } label: {
                        HStack {
                            Label("Use Mac default", systemImage: "desktopcomputer")
                            Spacer()
                            if followsDefault { Image(systemName: "checkmark.circle.fill") }
                        }
                    }
                    .disabled(loading || switchingTo != nil)
                    .uiKitIdentifier("ClaudeAccountSwitcherSheet.useDefault")
                }
                ForEach(accounts) { account in accountRow(account) }
                if let error, !error.isEmpty {
                    Text(error).font(.ripul(.caption)).foregroundStyle(.ripul(.warning))
                    Button("Retry") { Task { await refresh() } }
                        .disabled(loading || switchingTo != nil)
                        .uiKitIdentifier("ClaudeAccountSwitcherSheet.retry")
                }
                if addingAccount {
                    HStack(spacing: 8) {
                        TextField("Account name (e.g. Work)", text: $newName)
                            #if os(iOS)
                            .textInputAutocapitalization(.words)
                            #endif
                            .uiKitIdentifier("ClaudeAccountSwitcherSheet.nameField")
                        Button("Create") {
                            let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                            Task { await createAndSignIn(name: name) }
                        }
                            .disabled(loading || newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .uiKitIdentifier("ClaudeAccountSwitcherSheet.createAccount")
                        Button("Cancel") { addingAccount = false; newName = "" }.disabled(loading)
                            .uiKitIdentifier("ClaudeAccountSwitcherSheet.cancelCreateAccount")
                    }
                    // Automatic List buttons share the row's tap: Create also
                    // fired Cancel, clearing the name before its Task ran.
                    .buttonStyle(.borderless)
                } else {
                    Button { addingAccount = true } label: { Label("Add account", systemImage: "plus") }
                        .disabled(loading || switchingTo != nil)
                        .uiKitIdentifier("ClaudeAccountSwitcherSheet.addAccount")
                }
            }
        } header: { RipulSectionHeader {
            HStack {
                Label(machine.displayName, systemImage: "desktopcomputer")
                Spacer()
                if !machine.isOnline { Text("Offline") }
            }
        } } footer: { RipulSectionFooter {
            if machine.isOnline {
                Text(chatId == nil
                    ? "Chats using the Mac default switch after their current reply. Chats with their own account keep it."
                    : "Applies only to this chat, after the current reply finishes. Conversation history is kept.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        } }.ripulThemedListRows()
        .task(id: refreshToken) {
            repeat {
                await refresh()
                do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { break }
            } while !Task.isCancelled
        }
        .onChange(of: scenePhase) { phase in if phase == .active { Task { await refresh() } } }
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
    }

    @ViewBuilder
    private func accountRow(_ account: ClaudeAccountProfile) -> some View {
        let isActive = account.slug == active && (chatId == nil || !followsDefault)
        // A usage error is almost always an expired sign-in, so it is offered in place of Switch.
        let action: CodingAccountRowAction =
            switchingTo == account.slug ? .busy
            : !account.loggedIn ? .signIn("Sign in", { onSignIn(account) })
            : account.usage?.error != nil ? .signIn("Sign in again", { onSignIn(account) })
            : isActive ? .active
            : .switchTo({ Task { await selectAccount(account.slug) } })
        let detail = [account.email ?? (account.loggedIn ? "Signed in" : "Not signed in"),
                      account.isDefault ? "This Mac's login" : nil].compactMap { $0 }.joined(separator: " · ")
        CodingAccountRow(name: account.name, detail: detail, isActive: isActive,
            usage: account.usage, plan: account.plan, showsUsage: account.loggedIn,
            action: action, disabled: loading || switchingTo != nil,
            identifier: "ClaudeAccountSwitcherSheet.accountRow.\(account.slug)")
        .uiKitIdentifier("ClaudeAccountSwitcherSheet.accountRow.\(account.slug)")
        .contextMenu { MenuIcons {
            if account.loggedIn {
                Button("Sign in again", systemImage: "arrow.clockwise") { onSignIn(account) }
            }
            if !account.isDefault {
                Button("Remove", systemImage: "trash", role: .destructive) { deleteCandidate = account }
                    .disabled(loading || switchingTo != nil)
            }
        }}
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
    }

    private func selectAccount(_ slug: String) async {
        switchingTo = slug
        error = nil
        let result = await bridge.switchClaudeAccount(machineId: machine.machineId, slug: slug, chatId: chatId)
        switchingTo = nil
        if result.ok {
            active = result.active ?? slug
            followsDefault = slug == "__machine_default__"
            onSwitched?(accounts.first { $0.slug == active })
        } else {
            error = result.error ?? "Switch failed"
        }
    }

    private func createAndSignIn(name: String) async {
        guard !name.isEmpty else { return }
        loading = true
        let result = await bridge.createClaudeAccount(machineId: machine.machineId, name: name)
        loading = false
        if result.ok, let slug = result.slug {
            addingAccount = false
            newName = ""
            let profile = ClaudeAccountProfile(
                slug: slug, name: result.name ?? name, email: nil, loggedIn: false, isDefault: false
            )
            accounts.append(profile)
            onSignIn(profile)
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
        // Foreground, the periodic task and Retry can arrive together. Keep
        // one request in flight and remove the previous failure while it runs.
        guard machine.isOnline, !loading, switchingTo == nil else { return }
        loading = true
        error = nil
        defer { loading = false }
        let result = await bridge.fetchClaudeAccounts(machineId: machine.machineId, chatId: chatId)
        if result.error == nil { accounts = result.accounts; active = result.active; followsDefault = result.followsDefault }
        error = result.error
    }
}
