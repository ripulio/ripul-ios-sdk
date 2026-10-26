import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Antigravity Account Models & Bridge

public struct AntigravityAccountProfile: Codable, Identifiable, Equatable, Sendable {
    public let slug: String
    public let name: String
    public let email: String?
    public let plan: String?
    public let loggedIn: Bool
    public let usage: CodingAccountUsage?

    public var id: String { slug }
    public var isDefault: Bool { slug == "default" }

    public init(
        slug: String,
        name: String,
        email: String? = nil,
        plan: String? = nil,
        loggedIn: Bool = false,
        usage: CodingAccountUsage? = nil
    ) {
        self.slug = slug
        self.name = name
        self.email = email
        self.plan = plan
        self.loggedIn = loggedIn
        self.usage = usage
    }
}

public struct AntigravityAccountsResponse: Decodable {
    public let ok: Bool
    public let accounts: [AntigravityAccountProfile]?
    public let active: String?
    public let chatAccount: String?
    public let chatPinned: Bool?
    public let slug: String?
    public let name: String?
    public let loggedIn: Bool?
    public let email: String?
    public let authMethod: String?
    public let subscriptionType: String?
    public let cliAvailable: Bool?
    public let profile: String?
    public let sessionId: String?
    public let authUrl: String?
    public let expiresAt: String?
    public let pendingSessionId: String?
    public let pendingExpiresAt: String?
    public let error: String?
}

extension AgentBridge {
    public func antigravityAccounts(
        machineId: String,
        direct: Bool = false,
        params: [String: Any]
    ) async throws -> AntigravityAccountsResponse {
        var payload = params
        if payload["requestId"] == nil {
            payload["requestId"] = UUID().uuidString
        }
        let result: Any?
        if direct {
            result = try await capabilityRouter.invoke(capability: "directMac", method: "request", args: [[
                "op": "machine",
                "action": "antigravity.accounts",
                "directHostId": machineId,
                "params": payload,
            ]])
        } else {
            let data = try JSONSerialization.data(
                withJSONObject: ["machineId": machineId, "params": payload],
                options: [.sortedKeys]
            )
            let literal = String(decoding: data, as: UTF8.self)
            result = try await callAsyncJavaScript("""
                const request = \(literal);
                if (!window.__ripulRemoteAntigravityAccounts) return { ok: false, error: 'Update Ripul to use Antigravity accounts.' };
                return await window.__ripulRemoteAntigravityAccounts(request.machineId, request.params);
                """)
        }
        guard let result else {
            throw NSError(
                domain: "AntigravityAccounts",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The Mac did not respond."]
            )
        }
        return try JSONDecoder().decode(
            AntigravityAccountsResponse.self,
            from: JSONSerialization.data(withJSONObject: result)
        )
    }

    public func fetchAntigravityAccounts(
        machineId: String,
        direct: Bool = false,
        chatId: String? = nil
    ) async -> (accounts: [AntigravityAccountProfile], active: String, chatAccount: String, chatPinned: Bool, error: String?) {
        var params: [String: Any] = ["action": "list"]
        if let chatId, !chatId.isEmpty { params["chatId"] = chatId }
        do {
            let res = try await antigravityAccounts(machineId: machineId, direct: direct, params: params)
            let active = res.active ?? "default"
            let chatAccount = res.chatAccount ?? active
            let chatPinned = res.chatPinned ?? false
            return (res.accounts ?? [], active, chatAccount, chatPinned, res.ok ? nil : (res.error ?? "Could not load Antigravity accounts."))
        } catch {
            return ([], "default", "default", false, error.localizedDescription)
        }
    }

    public func createAntigravityAccount(
        machineId: String,
        direct: Bool = false,
        name: String
    ) async -> (ok: Bool, slug: String?, name: String?, error: String?) {
        do {
            let res = try await antigravityAccounts(
                machineId: machineId,
                direct: direct,
                params: ["action": "create", "name": name]
            )
            return (res.ok, res.slug, res.name, res.error)
        } catch {
            return (false, nil, nil, error.localizedDescription)
        }
    }

    public func switchAntigravityAccount(
        machineId: String,
        direct: Bool = false,
        slug: String,
        chatId: String? = nil
    ) async -> (ok: Bool, active: String?, error: String?) {
        var params: [String: Any] = ["action": "switch", "slug": slug]
        if let chatId, !chatId.isEmpty { params["chatId"] = chatId }
        do {
            let res = try await antigravityAccounts(machineId: machineId, direct: direct, params: params)
            return (res.ok, res.chatAccount ?? res.active ?? slug, res.error)
        } catch {
            return (false, nil, error.localizedDescription)
        }
    }

    public func deleteAntigravityAccount(
        machineId: String,
        direct: Bool = false,
        slug: String
    ) async -> (ok: Bool, active: String?, error: String?) {
        do {
            let res = try await antigravityAccounts(
                machineId: machineId,
                direct: direct,
                params: ["action": "delete", "slug": slug]
            )
            return (res.ok, res.active, res.error)
        } catch {
            return (false, nil, error.localizedDescription)
        }
    }

    public func fetchAntigravityAuthStatus(
        machineId: String,
        direct: Bool = false,
        profile: String? = nil
    ) async -> HostAuthStatusInfo {
        var params: [String: Any] = ["action": "authStatus"]
        if let profile, !profile.isEmpty { params["profile"] = profile }
        do {
            let res = try await antigravityAccounts(machineId: machineId, direct: direct, params: params)
            return HostAuthStatusInfo(
                loggedIn: res.loggedIn ?? false,
                authMethod: res.authMethod,
                apiProvider: nil,
                email: res.email,
                orgName: nil,
                subscriptionType: res.subscriptionType,
                pendingSessionId: res.pendingSessionId,
                error: res.error,
                toolsNotice: nil
            )
        } catch {
            return HostAuthStatusInfo(
                loggedIn: false,
                authMethod: nil,
                apiProvider: nil,
                email: nil,
                orgName: nil,
                subscriptionType: nil,
                pendingSessionId: nil,
                error: error.localizedDescription,
                toolsNotice: nil
            )
        }
    }

    public func beginAntigravityAuth(
        machineId: String,
        direct: Bool = false,
        profile: String? = nil
    ) async -> (sessionId: String?, authUrl: String?, error: String?) {
        var params: [String: Any] = ["action": "loginBegin"]
        if let profile, !profile.isEmpty { params["profile"] = profile }
        do {
            let res = try await antigravityAccounts(machineId: machineId, direct: direct, params: params)
            return (res.sessionId, res.authUrl, res.error)
        } catch {
            return (nil, nil, error.localizedDescription)
        }
    }

    public func submitAntigravityAuthCode(
        machineId: String,
        direct: Bool = false,
        sessionId: String,
        code: String,
        profile: String? = nil
    ) async -> (ok: Bool, error: String?) {
        var params: [String: Any] = [
            "action": "loginCode",
            "sessionId": sessionId,
            "code": code,
        ]
        if let profile, !profile.isEmpty { params["profile"] = profile }
        do {
            let res = try await antigravityAccounts(machineId: machineId, direct: direct, params: params)
            return (res.ok, res.error)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    public func cancelAntigravityAuth(machineId: String, direct: Bool = false) async -> Bool {
        do {
            let res = try await antigravityAccounts(
                machineId: machineId,
                direct: direct,
                params: ["action": "loginCancel"]
            )
            return res.ok
        } catch {
            return false
        }
    }
}

// MARK: - Antigravity Accounts Settings Screen

public struct AntigravityAccountsSettingsScreen: View {
    let bridge: AgentBridge
    let suppliedMachines: [RemoteMachine]?

    public init(bridge: AgentBridge, machines: [RemoteMachine]? = nil) {
        self.bridge = bridge
        self.suppliedMachines = machines
    }

    public var body: some View {
        CodingAccountsSettingsList(provider: .antigravity, bridge: bridge, machines: suppliedMachines)
    }
}

// MARK: - Antigravity Account Switcher Sheet

public struct AntigravityAccountSwitcherSheet: View {
    let machine: RemoteMachine
    let bridge: AgentBridge
    var chatId: String? = nil
    var startsAddingAccount = false
    var onSwitched: ((AntigravityAccountProfile?) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var signIn: AntigravityAccountSignInRequest?
    @State private var refreshToken = UUID()

    public init(
        machine: RemoteMachine,
        bridge: AgentBridge,
        chatId: String? = nil,
        onSwitched: ((AntigravityAccountProfile?) -> Void)? = nil,
        startsAddingAccount: Bool = false
    ) {
        self.machine = machine
        self.bridge = bridge
        self.chatId = chatId
        self.onSwitched = onSwitched
        self.startsAddingAccount = startsAddingAccount
    }

    public var body: some View {
        NavigationStack {
            List {
                AntigravityAccountSection(
                    machine: machine,
                    bridge: bridge,
                    chatId: chatId,
                    onSignIn: { signIn = AntigravityAccountSignInRequest(machine: machine, profile: $0) },
                    onSwitched: onSwitched,
                    refreshToken: refreshToken,
                    startsAddingAccount: startsAddingAccount
                )
            }.ripulThemedList()
                .navigationTitle(chatId == nil ? "Antigravity accounts" : "Chat account")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }.uiKitIdentifier("AntigravityAccountSwitcherSheet.done")
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 420)
        #endif
        .ripulSheet(.page, detents: [.medium, .large])
        .dismissesKeyboardOnTapAway()
        .ripulSheet(item: $signIn, onDismiss: { refreshToken = UUID() }) { request in
            AntigravitySignInSheet(
                machine: request.machine,
                bridge: bridge,
                profile: request.profile.slug,
                profileName: request.profile.name,
                startSignInImmediately: true
            )
        }
    }
}

struct AntigravityAccountSignInRequest: Identifiable {
    let machine: RemoteMachine
    let profile: AntigravityAccountProfile
    var id: String { "\(machine.machineId)/\(profile.slug)" }
}

// MARK: - Antigravity Account Section

struct AntigravityAccountSection: View {
    let machine: RemoteMachine
    let bridge: AgentBridge
    var chatId: String? = nil
    let onSignIn: (AntigravityAccountProfile) -> Void
    var onSwitched: ((AntigravityAccountProfile?) -> Void)? = nil
    var refreshToken: UUID? = nil
    var startsAddingAccount = false
    @State private var openedAddAccount = false
    @Environment(\.scenePhase) private var scenePhase

    @State private var accounts: [AntigravityAccountProfile] = []
    @State private var active: String = "default"
    @State private var followsDefault = true
    @State private var loading = false
    @State private var error: String?
    @State private var switchingTo: String?
    @State private var addingAccount = false
    @State private var newName = ""
    @State private var deleteCandidate: AntigravityAccountProfile?

    private var isDirect: Bool { machine.meta?["connection"] == "direct" }

    var body: some View {
        Section {
            if !machine.isOnline {
                Text("Connect to this Mac to manage accounts.").foregroundStyle(.ripul(.textSecondary))
            } else {
                if loading && accounts.isEmpty {
                    ProgressView("Loading accounts…").uiKitIdentifier("AntigravityAccountSwitcherSheet.loading")
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
                    .uiKitIdentifier("AntigravityAccountSwitcherSheet.useDefault")
                }
                ForEach(accounts) { account in accountRow(account) }
                if let error, !error.isEmpty {
                    Text(error).font(.ripul(.caption)).foregroundStyle(.ripul(.warning))
                    Button("Retry") { Task { await refresh() } }
                        .disabled(loading || switchingTo != nil)
                        .uiKitIdentifier("AntigravityAccountSwitcherSheet.retry")
                }
                if addingAccount {
                    HStack(spacing: 8) {
                        TextField("Account name (e.g. Work)", text: $newName)
                            #if os(iOS)
                            .textInputAutocapitalization(.words)
                            #endif
                            .uiKitIdentifier("AntigravityAccountSwitcherSheet.nameField")
                        Button("Create") {
                            let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                            Task { await createAndSignIn(name: name) }
                        }
                            .disabled(loading || newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .uiKitIdentifier("AntigravityAccountSwitcherSheet.createAccount")
                        Button("Cancel") { addingAccount = false; newName = "" }.disabled(loading)
                            .uiKitIdentifier("AntigravityAccountSwitcherSheet.cancelCreateAccount")
                    }
                    .buttonStyle(.borderless)
                } else {
                    Button { addingAccount = true } label: { Label("Add account", systemImage: "plus") }
                        .disabled(loading || switchingTo != nil)
                        .uiKitIdentifier("AntigravityAccountSwitcherSheet.addAccount")
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
                    ? "Chats using the Mac default switch on their next reply. Conversation history is shared across accounts."
                    : "Applies only to this chat on its next reply. Conversation history is kept.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        } }.ripulThemedListRows()
        .task(id: refreshToken) {
            if startsAddingAccount && !openedAddAccount {
                openedAddAccount = true
                addingAccount = true
            }
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
    private func accountRow(_ account: AntigravityAccountProfile) -> some View {
        let isActive = account.slug == active && (chatId == nil || !followsDefault)
        let action: CodingAccountRowAction =
            switchingTo == account.slug ? .busy
            : !account.loggedIn ? .signIn("Sign in", { onSignIn(account) })
            : account.usage?.error != nil ? .signIn("Sign in again", { onSignIn(account) })
            : isActive ? .active
            : .switchTo({ Task { await selectAccount(account.slug) } })
        let detail = [account.email ?? (account.loggedIn ? "Signed in" : "Not signed in"),
                      account.isDefault ? "This Mac's login" : nil].compactMap { $0 }.joined(separator: " · ")
        CodingAccountRow(
            name: account.name,
            detail: detail,
            isActive: isActive,
            usage: account.usage,
            plan: account.plan,
            showsUsage: account.loggedIn,
            action: action,
            disabled: loading || switchingTo != nil,
            identifier: "AntigravityAccountSwitcherSheet.accountRow.\(account.slug)"
        )
        .uiKitIdentifier("AntigravityAccountSwitcherSheet.accountRow.\(account.slug)")
        .contextMenu { MenuIcons {
            if account.loggedIn {
                Button("Sign in again", systemImage: "arrow.clockwise") { onSignIn(account) }
            }
            if !account.isDefault {
                Button("Remove", systemImage: "trash", role: .destructive) { deleteCandidate = account }
                    .disabled(loading || switchingTo != nil)
            }
        }}
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !account.isDefault {
                Button(role: .destructive) {
                    deleteCandidate = account
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .uiKitIdentifier("AntigravityAccountSwitcherSheet.accountRow.\(account.slug).delete")
            }
        }
    }

    private func selectAccount(_ slug: String) async {
        switchingTo = slug
        error = nil
        let result = await bridge.switchAntigravityAccount(
            machineId: machine.machineId,
            direct: isDirect,
            slug: slug,
            chatId: chatId
        )
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
        let result = await bridge.createAntigravityAccount(
            machineId: machine.machineId,
            direct: isDirect,
            name: name
        )
        loading = false
        if result.ok, let slug = result.slug {
            addingAccount = false
            newName = ""
            let profile = AntigravityAccountProfile(
                slug: slug,
                name: result.name ?? name,
                email: nil,
                plan: nil,
                loggedIn: false
            )
            accounts.append(profile)
            onSignIn(profile)
        } else {
            error = result.error ?? "Could not create the account"
        }
    }

    private func deleteAccount(_ account: AntigravityAccountProfile) async {
        deleteCandidate = nil
        loading = true
        error = nil
        let result = await bridge.deleteAntigravityAccount(
            machineId: machine.machineId,
            direct: isDirect,
            slug: account.slug
        )
        loading = false
        if result.ok {
            accounts.removeAll { $0.slug == account.slug }
            if let newActive = result.active {
                active = newActive
                onSwitched?(accounts.first { $0.slug == newActive })
            }
        } else {
            error = result.error ?? "Could not remove the account"
        }
    }

    private func refresh() async {
        loading = true
        error = nil
        let res = await bridge.fetchAntigravityAccounts(
            machineId: machine.machineId,
            direct: isDirect,
            chatId: chatId
        )
        loading = false
        accounts = res.accounts
        active = chatId == nil ? res.active : res.chatAccount
        followsDefault = !res.chatPinned
        error = res.error
    }
}

// MARK: - Phone-Driven Antigravity Sign-In Sheet

public struct AntigravitySignInSheet: View {
    let machine: RemoteMachine
    let bridge: AgentBridge
    let profile: String?
    let profileName: String?
    let startSignInImmediately: Bool
    @Environment(\.dismiss) private var dismiss

    public init(
        machine: RemoteMachine,
        bridge: AgentBridge,
        profile: String? = nil,
        profileName: String? = nil,
        startSignInImmediately: Bool = false
    ) {
        self.machine = machine
        self.bridge = bridge
        self.profile = profile
        self.profileName = profileName
        self.startSignInImmediately = startSignInImmediately
    }

    private enum Phase {
        case loading
        case signedIn(HostAuthStatusInfo)
        case idle(error: String?)
        case pendingElsewhere(sessionId: String)
        case awaitingCode(sessionId: String, authUrl: String)
        case submitting
        case success(HostAuthStatusInfo?)
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var code: String = ""
    @State private var didCopyLink = false

    private var isDirect: Bool { machine.meta?["connection"] == "direct" }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    content
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(profile.map { "\(profileName ?? $0) on \(machine.displayName)" } ?? "Antigravity on \(machine.displayName)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .uiKitIdentifier("AntigravitySignInSheet.done")
                }
            }
        }
        .ripulSheet(.page, detents: [.medium, .large])
        .task {
            if startSignInImmediately { await begin() }
            else { await refreshStatus() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                Text("Preparing Google sign-in…")
                    .foregroundStyle(.ripul(.textSecondary))
            }
            .uiKitIdentifier("AntigravitySignInSheet.loading")

        case .signedIn(let status):
            VStack(alignment: .leading, spacing: 12) {
                Label("Signed in", systemImage: "checkmark.circle.fill")
                    .font(.ripul(.headline))
                    .foregroundStyle(.ripul(.success))
                accountRows(status)
                Divider()
                Button("Sign in with a different Google account") {
                    Task { await begin() }
                }
                .font(.ripul(.subheadline))
                .uiKitIdentifier("AntigravitySignInSheet.signedIn.switchAccount")
            }
            .uiKitIdentifier("AntigravitySignInSheet.signedIn")

        case .idle(let error):
            VStack(alignment: .leading, spacing: 12) {
                Label("Not signed in", systemImage: "person.crop.circle.badge.xmark")
                    .font(.ripul(.headline))
                    .foregroundStyle(.ripul(.textSecondary))
                Text("Connect an Antigravity account on \(machine.displayName) directly from this device — the credential stays on your Mac.")
                    .font(.ripul(.subheadline))
                    .foregroundStyle(.ripul(.textSecondary))
                if let error, !error.isEmpty {
                    Text(error)
                        .font(.ripul(.caption))
                        .foregroundStyle(.ripul(.warning))
                }
                Button {
                    Task { await begin() }
                } label: {
                    Label("Sign in with Google", systemImage: "person.badge.key")
                        .frame(maxWidth: .infinity)
                }
                .ripulProminentButtonStyle()
                .controlSize(.large)
                .uiKitIdentifier("AntigravitySignInSheet.idle.signIn")
            }
            .uiKitIdentifier("AntigravitySignInSheet.idle")

        case .pendingElsewhere(let sessionId):
            VStack(alignment: .leading, spacing: 12) {
                Label("Sign-in already in progress", systemImage: "hourglass")
                    .font(.ripul(.headline))
                Text("The Mac is waiting for an authorization code. Paste the code below, or start over for a fresh sign-in link.")
                    .font(.ripul(.subheadline))
                    .foregroundStyle(.ripul(.textSecondary))
                codeEntry(sessionId: sessionId)
                Button("Start Over") {
                    Task { await startOver() }
                }
                .font(.ripul(.subheadline))
                .uiKitIdentifier("AntigravitySignInSheet.pending.startOver")
            }
            .uiKitIdentifier("AntigravitySignInSheet.pending")

        case .awaitingCode(let sessionId, let authUrl):
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Step 1").font(.ripul(.caption, weight: .semibold)).foregroundStyle(.ripul(.textSecondary))
                    Button {
                        openAuthUrl(authUrl)
                    } label: {
                        Label("Open Google sign-in", systemImage: "safari")
                            .frame(maxWidth: .infinity)
                    }
                    .ripulProminentButtonStyle()
                    .controlSize(.large)
                    .uiKitIdentifier("AntigravitySignInSheet.awaiting.openUrl")

                    Button {
                        copyLink(authUrl)
                    } label: {
                        Label(didCopyLink ? "Link copied" : "Copy link instead", systemImage: didCopyLink ? "checkmark" : "doc.on.doc")
                            .font(.ripul(.caption))
                    }
                    .buttonStyle(.borderless)
                    .uiKitIdentifier("AntigravitySignInSheet.awaiting.copyUrl")
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Step 2").font(.ripul(.caption, weight: .semibold)).foregroundStyle(.ripul(.textSecondary))
                    Text("Sign in with Google, copy the authorization code shown on the callback page, and paste it here.")
                        .font(.ripul(.subheadline))
                        .foregroundStyle(.ripul(.textSecondary))
                    codeEntry(sessionId: sessionId)
                }

                Button("Cancel sign-in", role: .destructive) {
                    Task {
                        _ = await bridge.cancelAntigravityAuth(machineId: machine.machineId, direct: isDirect)
                        await refreshStatus()
                    }
                }
                .font(.ripul(.subheadline))
                .uiKitIdentifier("AntigravitySignInSheet.awaiting.cancel")
            }
            .uiKitIdentifier("AntigravitySignInSheet.awaiting")

        case .submitting:
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Verifying…").ripulText()
                        .font(.ripul(.headline))
                }
                Text("The Mac is redeeming the authorization code and saving the account.")
                    .font(.ripul(.caption))
                    .foregroundStyle(.ripul(.textSecondary))
            }
            .uiKitIdentifier("AntigravitySignInSheet.submitting")

        case .success(let status):
            VStack(alignment: .leading, spacing: 12) {
                Label("Signed in", systemImage: "checkmark.circle.fill")
                    .font(.ripul(.headline))
                    .foregroundStyle(.ripul(.success))
                if let status {
                    accountRows(status)
                }
                Text("Antigravity sessions on \(machine.displayName) can now use this account.")
                    .font(.ripul(.caption))
                    .foregroundStyle(.ripul(.textSecondary))
            }
            .uiKitIdentifier("AntigravitySignInSheet.success")

        case .failed(let message):
            VStack(alignment: .leading, spacing: 12) {
                Label("Sign-in failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.ripul(.headline))
                    .foregroundStyle(.ripul(.warning))
                Text(message)
                    .font(.ripul(.subheadline))
                    .foregroundStyle(.ripul(.textSecondary))
                Text("Authorization codes are single-use — start over to open a fresh sign-in link.")
                    .font(.ripul(.caption))
                    .foregroundStyle(.ripul(.textSecondary))
                Button("Start Over") {
                    Task { await startOver() }
                }
                .ripulProminentButtonStyle()
                .uiKitIdentifier("AntigravitySignInSheet.failed.startOver")
            }
            .uiKitIdentifier("AntigravitySignInSheet.failed")
        }
    }

    @ViewBuilder
    private func accountRows(_ status: HostAuthStatusInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let email = status.email {
                HStack(spacing: 8) {
                    Image(systemName: "envelope")
                        .font(.ripulIcon(.caption))
                        .foregroundStyle(.ripul(.textSecondary))
                        .frame(width: 18)
                    Text(email).ripulText()
                        .font(.ripul(.subheadline))
                }
            }
            if let plan = status.subscriptionType {
                HStack(spacing: 8) {
                    Image(systemName: "creditcard")
                        .font(.ripulIcon(.caption))
                        .foregroundStyle(.ripul(.textSecondary))
                        .frame(width: 18)
                    Text(plan.capitalized).ripulText()
                        .font(.ripul(.subheadline))
                }
            }
        }
    }

    @ViewBuilder
    private func codeEntry(sessionId: String) -> some View {
        TextField("Paste authorization code", text: $code)
            .font(.ripul(.body, family: .code))
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.asciiCapable)
            #endif
            .textFieldStyle(.roundedBorder)
            .uiKitIdentifier("AntigravitySignInSheet.codeField")

        Button {
            Task { await submit(sessionId: sessionId) }
        } label: {
            Text("Submit Code")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .uiKitIdentifier("AntigravitySignInSheet.submitCode")
    }

    private func refreshStatus() async {
        phase = .loading
        let status = await bridge.fetchAntigravityAuthStatus(
            machineId: machine.machineId,
            direct: isDirect,
            profile: profile
        )
        if status.loggedIn {
            phase = .signedIn(status)
        } else if let pending = status.pendingSessionId {
            phase = .pendingElsewhere(sessionId: pending)
        } else {
            phase = .idle(error: status.error)
        }
    }

    private func begin() async {
        phase = .loading
        code = ""
        didCopyLink = false
        let result = await bridge.beginAntigravityAuth(
            machineId: machine.machineId,
            direct: isDirect,
            profile: profile
        )
        if let sessionId = result.sessionId, let authUrl = result.authUrl {
            phase = .awaitingCode(sessionId: sessionId, authUrl: authUrl)
            openAuthUrl(authUrl)
        } else {
            phase = .idle(error: result.error ?? "Could not start the sign-in")
        }
    }

    private func startOver() async {
        phase = .loading
        _ = await bridge.cancelAntigravityAuth(machineId: machine.machineId, direct: isDirect)
        await begin()
    }

    private func submit(sessionId: String) async {
        phase = .submitting
        let (ok, error) = await bridge.submitAntigravityAuthCode(
            machineId: machine.machineId,
            direct: isDirect,
            sessionId: sessionId,
            code: code,
            profile: profile
        )
        if ok {
            let status = await bridge.fetchAntigravityAuthStatus(
                machineId: machine.machineId,
                direct: isDirect,
                profile: profile
            )
            phase = .success(status.loggedIn ? status : nil)
        } else {
            phase = .failed(error ?? "The host could not verify the code.")
        }
    }

    private func openAuthUrl(_ authUrl: String) {
        guard let url = URL(string: authUrl) else { return }
        #if os(iOS)
        UIApplication.shared.open(url)
        #elseif os(macOS)
        NSWorkspace.shared.open(url)
        #endif
    }

    private func copyLink(_ authUrl: String) {
        #if os(iOS)
        UIPasteboard.general.string = authUrl
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(authUrl, forType: .string)
        #endif
        didCopyLink = true
    }
}
