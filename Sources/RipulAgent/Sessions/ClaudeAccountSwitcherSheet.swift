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
/// CLAUDE_CONFIG_DIR), so adding an account never disturbs a signed-in one in
/// use; on a Mac with none, the Mac makes the new one its account
/// (`makeMacDefaultIfUnsigned` on its page). Claude Code's own folder is not
/// listed until it holds a sign-in, and then under that account's email
/// (`CodingAccountDefaultFolder`).
public struct ClaudeAccountSwitcherSheet: View {
    let machine: RemoteMachine
    let bridge: AgentBridge
    var chatId: String? = nil
    var startsAddingAccount = false
    var suggestedAccountName: String?
    var suggestedAccountEmail: String?
    var onAccountAdded: ((ClaudeAccountProfile) -> Void)?
    /// Fires after a successful switch so the caller can refresh its label.
    var onSwitched: ((ClaudeAccountProfile?) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var signIn: ClaudeAccountSignInRequest?
    @State private var refreshToken = UUID()
    /// The profile this sheet's Add Computer set up, signed in for the
    /// suggested account rather than the one it last had.
    @State private var addedSlug: String?

    public init(machine: RemoteMachine, bridge: AgentBridge, chatId: String? = nil, onSwitched: ((ClaudeAccountProfile?) -> Void)? = nil, startsAddingAccount: Bool = false,
                suggestedAccountName: String? = nil, suggestedAccountEmail: String? = nil,
                onAccountAdded: ((ClaudeAccountProfile) -> Void)? = nil) {
        self.machine = machine
        self.bridge = bridge
        self.chatId = chatId
        self.onSwitched = onSwitched
        self.startsAddingAccount = startsAddingAccount
        self.suggestedAccountName = suggestedAccountName
        self.suggestedAccountEmail = suggestedAccountEmail
        self.onAccountAdded = onAccountAdded
    }

    public var body: some View {
        NavigationStack {
            List {
                if let suggestedAccountName {
                    CodingAccountAddComputerHint(name: suggestedAccountName, email: suggestedAccountEmail, machineName: machine.displayName)
                }
                ClaudeAccountSection(machine: machine, bridge: bridge, chatId: chatId,
                    onSignIn: { signIn = ClaudeAccountSignInRequest(machine: machine, profile: $0) },
                    onSwitched: onSwitched, refreshToken: refreshToken, startsAddingAccount: startsAddingAccount,
                    suggestedAccountName: suggestedAccountName, suggestedAccountEmail: suggestedAccountEmail,
                    onAccountAdded: { profile in
                        addedSlug = profile.slug
                        onAccountAdded?(profile)
                    })
            }.ripulThemedList()
                .navigationTitle(suggestedAccountName != nil ? "Add Computer" : chatId == nil ? "Claude accounts" : "Chat account")
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
        .dismissesKeyboardOnTapAway()
        .ripulSheet(item: $signIn, onDismiss: { refreshToken = UUID() }) { request in
            // Adding a computer to an account expects that account; signing a
            // profile in again expects the one it had.
            HostSignInSheet(machine: request.machine, bridge: bridge,
                profile: request.profile.slug, profileName: request.profile.displayName,
                startSignInImmediately: suggestedAccountName != nil || request.profile.loggedIn || request.profile.signInEnded,
                expectedEmail: request.profile.slug == addedSlug ? suggestedAccountEmail : request.profile.email)
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
    var startsAddingAccount = false
    var suggestedAccountName: String?
    var suggestedAccountEmail: String?
    var onAccountAdded: ((ClaudeAccountProfile) -> Void)?
    @State private var openedAddAccount = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    @State private var accounts: [ClaudeAccountProfile] = []
    @State private var active: String = "default"
    @State private var followsDefault = true
    /// A listing has come back, so an empty one means the Mac has no account.
    @State private var loaded = false
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
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Same as this Mac")
                                    // While the chat follows the Mac, the listing's active account is the Mac's.
                                    if followsDefault, let using = accounts.first(where: { $0.slug == active }), !using.isEmptyDefault {
                                        Text(using.displayName).font(.ripul(.caption)).foregroundStyle(.ripul(.textSecondary))
                                    }
                                }
                            } icon: { Image(systemName: "desktopcomputer") }
                            Spacer()
                            if followsDefault { Image(systemName: "checkmark.circle.fill") }
                        }
                    }
                    .disabled(loading || switchingTo != nil)
                    .uiKitIdentifier("ClaudeAccountSwitcherSheet.useDefault")
                }
                if chatId == nil, loaded, error == nil,
                   let notice = CodingAccountDefaultFolder.macNotice(listed: listedAccounts.map { ($0.slug, $0.loggedIn) },
                                                                     active: active, agent: "Claude") {
                    Text(notice).font(.ripul(.caption)).foregroundStyle(.ripul(.warning))
                        .fixedSize(horizontal: false, vertical: true)
                        .uiKitIdentifier("ClaudeAccountSwitcherSheet.notice")
                }
                ForEach(listedAccounts) { account in accountRow(account) }
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
                Button {
                    openURL(CodingAccountProvider.claude.billingAndAccountURL())
                } label: {
                    HStack {
                        Label(CodingAccountProvider.claude.billingAndAccountTitle, systemImage: "creditcard")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.ripul(.caption))
                            .foregroundStyle(.ripul(.textSecondary))
                    }
                }
                .buttonStyle(.borderless)
                .uiKitIdentifier("ClaudeAccountSwitcherSheet.billing")
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
                    ? "Chats on this Mac use the Active account, and switch after their current reply. Chats given their own account keep it."
                    : "Applies only to this chat, after the current reply finishes. Conversation history is kept.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        } }.ripulThemedListRows()
        .task(id: refreshToken) {
            if startsAddingAccount && !openedAddAccount {
                openedAddAccount = true
                newName = suggestedAccountName ?? ""
                addingAccount = true
                if suggestedAccountName != nil {
                    await refresh()
                    if error != nil { return }
                    await createAndSignIn(name: newName)
                    // Keep a failed creation visible with its prefilled retry form.
                    if error != nil { return }
                }
            }
            repeat {
                await refresh()
                do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { break }
            } while !Task.isCancelled
        }
        .onChange(of: scenePhase) { phase in if phase == .active { Task { await refresh() } } }
        .confirmationDialog(
            "Remove \(deleteCandidate?.displayName ?? "account")?",
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
            : account.signInEnded || (account.loggedIn && account.usage?.error != nil) ? .signIn("Sign in again", { onSignIn(account) })
            : !account.loggedIn ? .signIn("Sign in", { onSignIn(account) })
            : isActive ? .active
            : .switchTo({ Task { await selectAccount(account.slug) } })
        let ends = ClaudeSignInEnd.text(endsAt: account.signInEndsAt, ended: account.signInEnded)
        let detail = [CodingAccountDefaultFolder.detail(title: account.displayName, email: account.email,
                                                        loggedIn: account.loggedIn, saysSignInEnd: ends != nil),
                      ends?.text].compactMap { $0 }.joined(separator: " · ")
        CodingAccountRow(name: account.displayName, detail: detail, isActive: isActive,
            usage: account.usage, plan: account.plan, showsUsage: account.loggedIn,
            action: action, disabled: loading || switchingTo != nil,
            identifier: "ClaudeAccountSwitcherSheet.accountRow.\(account.slug)")
        .uiKitIdentifier("ClaudeAccountSwitcherSheet.accountRow.\(account.slug)")
        .contextMenu { MenuIcons {
            if account.loggedIn {
                Button("Sign in again", systemImage: "arrow.clockwise") { onSignIn(account) }
            }
            Button(CodingAccountProvider.claude.billingAndAccountTitle, systemImage: "arrow.up.right.square") {
                openURL(CodingAccountProvider.claude.billingAndAccountURL(email: account.email))
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
        guard !name.isEmpty, !loading, switchingTo == nil else { return }
        // A retry of Add Computer continues its earlier setup instead of
        // creating another same-named profile on the destination Mac: one that
        // never finished signing in, or one that signed in to another account
        // than this one (the browser's, not the one chosen).
        if suggestedAccountName != nil,
           let existing = accounts.first(where: { profile in
               guard !profile.isDefault, profile.name == name else { return false }
               if profile.email == nil { return !profile.loggedIn }
               return CodingAccountEmail.isDifferentAccount(expected: suggestedAccountEmail, signedIn: profile.email)
           }) {
            addingAccount = false
            onAccountAdded?(existing)
            onSignIn(existing)
            return
        }
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
            onAccountAdded?(profile)
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
        if result.error == nil { accounts = result.accounts; active = result.active; followsDefault = result.followsDefault; loaded = true }
        error = result.error
    }

    /// Every profile but Claude Code's own folder while nothing is signed in there.
    private var listedAccounts: [ClaudeAccountProfile] { accounts.filter { !$0.isEmptyDefault } }
}
