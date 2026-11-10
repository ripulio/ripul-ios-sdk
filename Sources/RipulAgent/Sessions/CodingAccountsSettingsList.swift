import SwiftUI

/// Account-first Settings, shared by all coding providers and native clients.
struct CodingAccountsSettingsList: View {
    let suppliedMachines: [RemoteMachine]?
    @StateObject private var model: CodingAccountsSettingsModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var presentation: Presentation?
    @State private var refreshToken = UUID()
    @State private var machineIcons: [String: String] = [:]
    @State private var renaming: CodingAccountGroup?
    @State private var newName = ""
    @State private var renameNotice: String?
    @ScaledMetric(relativeTo: .caption) private var machineColumnWidth: CGFloat = 88

    private struct Presentation: Identifiable {
        let machine: RemoteMachine
        var signIn: CodingAccountEntry?
        var addAccount = false
        var accountToAdd: CodingAccountGroup?
        var id: String { "\(machine.id)/\(signIn?.localId ?? accountToAdd?.id ?? (addAccount ? "add" : "manage"))" }
    }

    init(provider: CodingAccountProvider, bridge: AgentBridge, machines: [RemoteMachine]? = nil) {
        suppliedMachines = machines
        _model = StateObject(wrappedValue: CodingAccountsSettingsModel(provider: provider, bridge: bridge))
    }

    var body: some View {
        List {
            if model.loading && model.machines.isEmpty {
                ProgressView("Loading accounts…")
            } else if model.machines.isEmpty {
                NoPairedMacView("See and switch the \(model.provider.title) accounts on your Mac.")
            } else {
                ForEach(model.groups) { account in
                    Section {
                        accountRow(account)
                    }.ripulThemedListRows()
                }
                if !model.unfinishedAccounts.isEmpty {
                    Section {
                        ForEach(model.unfinishedAccounts) { account in
                            if let machine = model.machines.first(where: { $0.id == account.machineId }) {
                                Button {
                                    presentation = Presentation(machine: machine, signIn: account)
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: icon(machine))
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(account.name).foregroundStyle(.ripul(.text))
                                            Text(machine.displayName).font(.ripul(.caption)).foregroundStyle(.ripul(.textSecondary))
                                        }
                                        Spacer()
                                        Text("Finish sign-in").font(.ripul(.subheadline))
                                    }
                                }
                                .buttonStyle(.borderless)
                                .disabled(!machine.isOnline || model.snapshots[machine.id]?.busy == true)
                                .uiKitIdentifier("CodingAccounts.unfinished.\(account.id)")
                            }
                        }
                    } header: { RipulSectionHeader { Text("Unfinished sign-ins") } }
                    footer: { RipulSectionFooter {
                        Text("Finish signing in to show each computer under its account.")
                    } }
                    .ripulThemedListRows()
                }
                Section {
                    ForEach(model.machines) { machine in machineStatus(machine) }
                    billingShortcutRow
                } footer: { RipulSectionFooter {
                    Text("Tap a machine icon to switch or manage its account. A checkmark shows the account in use on that machine.")
                } }.ripulThemedListRows()
            }
        }
        .ripulThemedList()
        #if os(iOS)
        .listStyle(.insetGrouped)
        .listSectionSpacing(16)
        #endif
        .ripulBottomBarScrollClearance(gap: 16)
        .modifier(CodingAccountsListWidth())
        .navigationTitle("\(model.provider.title) accounts")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if !model.machines.isEmpty {
                    addAccountButton
                }
            }
        }
        .task(id: refreshToken) {
            updateIcons()
            while !Task.isCancelled {
                // The management sheet owns requests while it is presented.
                if presentation == nil { await model.refresh(suppliedMachines: suppliedMachines) }
                do { try await Task.sleep(nanoseconds: model.pollInterval) } catch { break }
            }
        }
        .refreshable { await model.refresh(suppliedMachines: suppliedMachines) }
        .onChange(of: suppliedMachines) { _, _ in refreshToken = UUID() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { refreshToken = UUID() } }
        .onReceive(NotificationCenter.default.publisher(for: RemoteMachine.iconsDidChangeNotification)) { _ in updateIcons() }
        .ripulSheet(item: $presentation, onDismiss: { refreshToken = UUID() }) { request in
            managementSheet(request)
        }
        .alert("Rename Account", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
                .uiKitIdentifier("CodingAccounts.rename.name")
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                guard let account = renaming else { return }
                let name = newName
                Task { await rename(account, to: name) }
            }
            .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Every computer signed in to \(renaming?.email ?? "this account") uses this name.")
        }
        .alert("Rename Account", isPresented: Binding(get: { renameNotice != nil }, set: { if !$0 { renameNotice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(renameNotice ?? "")
        }
    }

    private func startRename(_ account: CodingAccountGroup) {
        // A title that is the email (two accounts shared a name) is no name.
        newName = account.nameIsShared ? "" : account.profileName ?? ""
        renaming = account
    }

    /// Renames on every computer that holds the account, then says which did
    /// not take it. A Mac whose Ripul predates renaming needs an update.
    private func rename(_ account: CodingAccountGroup, to name: String) async {
        let outcome = await model.renameAccount(account, to: name)
        var lines: [String] = []
        if !outcome.needsUpdate.isEmpty {
            lines.append("\(outcome.needsUpdate.joined(separator: " and ")) needs a Ripul update before it can rename accounts.")
        }
        if !outcome.notReached.isEmpty {
            lines.append("\(outcome.notReached.joined(separator: " and ")) couldn't be reached, so it keeps the old name. Rename again when it's online.")
        }
        if !lines.isEmpty {
            let done = outcome.renamed.isEmpty ? "" : "Renamed on \(outcome.renamed.joined(separator: " and ")). "
            renameNotice = done + lines.joined(separator: " ")
        }
        refreshToken = UUID()
    }

    @ViewBuilder private var addAccountButton: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            addAccountMenu.buttonStyle(.glass)
        } else {
            addAccountMenu.buttonStyle(.bordered)
        }
    }

    private var addAccountMenu: some View {
        Menu {
            ForEach(model.machines) { machine in
                Button { presentation = Presentation(machine: machine, addAccount: true) } label: {
                    Label(machine.displayName, systemImage: icon(machine))
                }
                .disabled(!machine.isOnline || model.snapshots[machine.id]?.busy == true)
            }
        } label: { Label("Add account", systemImage: "plus") }
        .disabled(!model.machines.contains { $0.isOnline && model.snapshots[$0.id]?.busy != true })
        .uiKitIdentifier("CodingAccounts.add")
    }

    private func accountRow(_ account: CodingAccountGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            accountIdentity(account)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: machineColumnWidth, maximum: machineColumnWidth), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                machineButtons(account)
                addComputerButton(account)
            }
            if account.entries.contains(where: { !$0.needsLogin }) || account.usage != nil {
                CodingAccountUsageView(usage: account.usage, plan: account.plan, showsPlan: false)
            }
        }
        .padding(.vertical, 8)
        .listRowSeparator(.hidden)
        .uiKitIdentifier("CodingAccounts.account.\(account.id)")
    }

    private func accountIdentity(_ account: CodingAccountGroup) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(account.name).font(.ripul(.body, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                CodingAccountPlanBadge(usage: account.usage, plan: account.plan)
                Spacer(minLength: 8)
                if model.provider == .claude {
                    Button { startRename(account) } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!account.machineIds.contains { id in model.machines.first { $0.id == id }?.isOnline == true })
                    .accessibilityLabel("Rename \(account.name)")
                    .uiKitIdentifier("CodingAccounts.account.\(account.id).rename")
                }
                Button { openURL(model.provider.billingAndAccountURL(email: account.email)) } label: {
                    Image(systemName: "arrow.up.right.square")
                        .foregroundStyle(.ripul(.textSecondary))
                }
                .buttonStyle(.borderless)
                .help("\(model.provider.billingAndAccountTitle) for \(account.name)")
                .accessibilityLabel("\(model.provider.billingAndAccountTitle) for \(account.name)")
                .uiKitIdentifier("CodingAccounts.account.\(account.id).billing")
            }
            if let email = account.email, email != account.name {
                Text(email).font(.ripul(.caption)).foregroundStyle(.ripul(.textSecondary))
                    .lineLimit(1).truncationMode(.middle)
            }
            if let first = account.soonestSignInEnd,
               let ends = ClaudeSignInEnd.text(endsAt: first.signInEndsAt, ended: first.signInEnded) {
                let machine = account.machineIds.count > 1
                    ? model.machines.first { $0.id == first.machineId }?.displayName : nil
                Text(machine.map { "\(ends.text) on \($0)" } ?? ends.text)
                    .font(.ripul(.caption))
                    .foregroundStyle(ends.soon ? .ripul(.warning) : .ripul(.textSecondary))
                    .lineLimit(1)
                    .uiKitIdentifier("CodingAccounts.account.signInEnds")
            }
        }
        .foregroundStyle(.ripul(.text))
    }

    @ViewBuilder private func machineButtons(_ account: CodingAccountGroup) -> some View {
        ForEach(model.machines.filter { account.machineIds.contains($0.id) }) { machine in
            let entries = account.accounts(on: machine.id)
            let active = entries.contains { $0.isActive }
            let needsLogin = entries.allSatisfy { $0.needsLogin }
            let snapshot = model.snapshots[machine.id]
            let busy = snapshot?.requesting == true || snapshot?.operation?.isPending == true
            let status = !machine.isOnline ? "Offline" : busy ? "Working" : needsLogin ? "Sign in needed" : active ? "Active" : "Available"
            Menu {
                Section(machine.displayName) {
                    if !machine.isOnline {
                        Text("Offline")
                    } else {
                        ForEach(entries) { entry in
                            if let ends = ClaudeSignInEnd.text(endsAt: entry.signInEndsAt, ended: entry.signInEnded) {
                                Text(entries.count > 1 ? "\(entry.name): \(ends.text)" : ends.text)
                            }
                            if entry.needsLogin {
                                Button(entries.count > 1 ? "Sign in to \(entry.name)…" : entry.signInEnded ? "Sign in again…" : "Sign in…") {
                                    presentation = Presentation(machine: machine, signIn: entry)
                                }.disabled(snapshot?.busy == true)
                            } else if entry.isActive {
                                Label(entries.count > 1 ? "\(entry.name) is active" : "Active on this machine", systemImage: "checkmark")
                            } else {
                                Button(entries.count > 1 ? "Use \(entry.name)" : "Use this account") {
                                    Task { await model.switchAccount(entry, on: machine) }
                                }.disabled(snapshot?.busy == true)
                            }
                        }
                        Button("Manage accounts…", systemImage: "person.crop.circle") {
                            presentation = Presentation(machine: machine)
                        }
                        Button(model.provider.billingAndAccountTitle, systemImage: "arrow.up.right.square") {
                            openURL(model.provider.billingAndAccountURL(email: account.email))
                        }
                    }
                }
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: icon(machine))
                        .font(.ripul(.body))
                        .foregroundStyle(active && machine.isOnline ? Color.accentColor : Color.ripul(.textSecondary))
                        .frame(width: 36, height: 32)
                        .background(active ? Color.accentColor.opacity(0.10) : Color.ripul(.textSecondary).opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(alignment: .bottomTrailing) {
                            if busy && machine.isOnline {
                                ProgressView().controlSize(.mini)
                            } else if !machine.isOnline || needsLogin || active {
                                Image(systemName: !machine.isOnline ? "minus.circle.fill" : needsLogin ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                                    .font(.ripul(.caption2))
                                    .foregroundStyle(needsLogin && machine.isOnline ? Color.ripul(.warning) : Color.ripul(.textSecondary))
                                    .background(.background, in: Circle())
                            }
                        }
                        .frame(width: 44, height: 44)
                    Text(machine.displayName)
                        .font(.ripul(.caption))
                        .foregroundStyle(.ripul(.textSecondary))
                        .multilineTextAlignment(.center)
                        .lineLimit(2, reservesSpace: true)
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .opacity(machine.isOnline ? 1 : 0.5)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .buttonStyle(.borderless)
            .help("\(machine.displayName) · \(status)")
            .accessibilityLabel("\(machine.displayName), \(account.name)")
            .accessibilityValue(status)
            .uiKitIdentifier("CodingAccounts.account.\(account.id).machine.\(machine.id)")
        }
    }

    @ViewBuilder private func addComputerButton(_ account: CodingAccountGroup) -> some View {
        let candidates = model.machines.filter { !account.machineIds.contains($0.id) }
        if !candidates.isEmpty {
            Menu {
                ForEach(candidates) { machine in
                    Button {
                        guard canAddAccount(on: machine) else { return }
                        presentation = Presentation(machine: machine, addAccount: true, accountToAdd: account)
                    } label: {
                        Label(machine.displayName, systemImage: icon(machine))
                    }
                    .disabled(!canAddAccount(on: machine))
                }
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.ripul(.body))
                        .frame(width: 36, height: 32)
                        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                        .frame(width: 44, height: 44)
                    Text("Add Computer")
                        .font(.ripul(.caption))
                        .multilineTextAlignment(.center)
                        .lineLimit(2, reservesSpace: true)
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .buttonStyle(.borderless)
            .disabled(!candidates.contains { canAddAccount(on: $0) })
            .accessibilityLabel("Add Computer to \(account.name)")
            .uiKitIdentifier("CodingAccounts.account.\(account.id).addComputer")
        }
    }

    private func canAddAccount(on machine: RemoteMachine) -> Bool {
        // Wait for a successful account listing before offering to add one:
        // an unknown or failed host response does not prove it is missing.
        guard machine.isOnline, let snapshot = model.snapshots[machine.id] else { return false }
        return snapshot.loaded && snapshot.error == nil && !snapshot.busy
    }

    private var billingShortcutRow: some View {
        let singleEmail = model.groups.count == 1 ? model.groups.first?.email : nil
        return Button {
            openURL(model.provider.billingAndAccountURL(email: singleEmail))
        } label: {
            HStack {
                Label(model.provider.billingAndAccountTitle, systemImage: "creditcard")
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.ripul(.caption))
                    .foregroundStyle(.ripul(.textSecondary))
            }
        }
        .buttonStyle(.borderless)
        .uiKitIdentifier("CodingAccounts.billing")
    }

    @ViewBuilder private func machineStatus(_ machine: RemoteMachine) -> some View {
        let snapshot = model.snapshots[machine.id]
        if !machine.isOnline {
            // Known accounts retain this machine's dimmed icon. Unknown
            // offline machines get one compact status row instead.
            if snapshot?.entries.isEmpty != false {
                Label("\(machine.displayName) · Offline", systemImage: icon(machine))
                    .font(.ripul(.caption)).foregroundStyle(.ripul(.textSecondary))
            }
        } else if snapshot?.loaded != true {
            HStack { ProgressView(); Text("\(machine.displayName)…") }
                .font(.ripul(.caption)).foregroundStyle(.ripul(.textSecondary))
        } else if let error = snapshot?.error {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(machine.displayName): \(error)").font(.ripul(.caption)).foregroundStyle(.ripul(.warning))
                Button("Retry") { Task { await model.refresh(suppliedMachines: suppliedMachines) } }
                    .disabled(snapshot?.busy == true)
            }
        } else if snapshot?.operation?.isPending == true {
            Button { presentation = Presentation(machine: machine) } label: {
                HStack {
                    ProgressView()
                    Text("\(machine.displayName) · \(snapshot?.operation?.status == "waiting" ? "Waiting for replies…" : "Account change in progress…")")
                    Spacer()
                    Image(systemName: "chevron.right")
                }
            }.font(.ripul(.caption))
        } else if snapshot?.entries.isEmpty == true {
            // A Mac with no account. Its empty default folder used to stand here as an unfinished sign-in.
            Button { presentation = Presentation(machine: machine, addAccount: true) } label: {
                HStack {
                    Label("\(machine.displayName) · No \(model.provider.title) account", systemImage: icon(machine))
                    Spacer()
                    Text("Add")
                }
            }
            .font(.ripul(.caption))
            .buttonStyle(.borderless)
            .disabled(snapshot?.busy == true)
            .uiKitIdentifier("CodingAccounts.machine.\(machine.id).noAccount")
        }
    }

    @ViewBuilder private func managementSheet(_ request: Presentation) -> some View {
        switch model.provider {
        case .claude:
            if let account = request.signIn {
                // The account this profile had, or the one Add Computer chose for it.
                HostSignInSheet(machine: request.machine, bridge: model.bridge,
                                profile: account.localId, profileName: account.name, startSignInImmediately: true,
                                expectedEmail: account.email ?? account.pendingLink?.email)
            } else {
                ClaudeAccountSwitcherSheet(machine: request.machine, bridge: model.bridge, startsAddingAccount: request.addAccount,
                                           suggestedAccountName: request.accountToAdd?.name, suggestedAccountEmail: request.accountToAdd?.email,
                                           onAccountAdded: { profile in
                                               if let account = request.accountToAdd {
                                                   model.rememberAddition(account, machineId: request.machine.id, localId: profile.slug)
                                               }
                                           })
            }
        case .codex:
            CodexAccountSwitcherSheet(machineId: request.machine.id, machineName: request.machine.displayName,
                                      direct: request.machine.meta?["connection"] == "direct", bridge: model.bridge,
                                      signInAccountId: request.signIn?.localId, startsAddingAccount: request.addAccount,
                                      suggestedAccountName: request.accountToAdd?.name, suggestedAccountEmail: request.accountToAdd?.email)
        case .antigravity:
            if let account = request.signIn {
                AntigravitySignInSheet(machine: request.machine, bridge: model.bridge,
                                      profile: account.localId, profileName: account.name, startSignInImmediately: true)
            } else {
                AntigravityAccountSwitcherSheet(machine: request.machine, bridge: model.bridge, startsAddingAccount: request.addAccount,
                                                suggestedAccountName: request.accountToAdd?.name, suggestedAccountEmail: request.accountToAdd?.email,
                                                onAccountAdded: { profile in
                                                    if let account = request.accountToAdd {
                                                        model.rememberAddition(account, machineId: request.machine.id, localId: profile.slug)
                                                    }
                                                })
            }
        }
    }

    private func icon(_ machine: RemoteMachine) -> String { machineIcons[machine.id] ?? machine.defaultIconName }
    private func updateIcons() {
        machineIcons = model.bridge.sessionCache.map { RemoteMachine.machineIconMap(cache: $0) } ?? [:]
    }
}

/// The account to choose in the provider's sign-in flow. The account list
/// still groups by the identity returned by the Mac after sign-in succeeds.
struct CodingAccountAddComputerHint: View {
    let name: String
    let email: String?
    let machineName: String

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.ripul(.headline))
                if let email, email != name {
                    Text(email).font(.ripul(.subheadline)).foregroundStyle(.ripul(.textSecondary))
                }
                Text("Sign in to this account on \(machineName) to add this computer.")
                    .font(.ripul(.subheadline)).foregroundStyle(.ripul(.textSecondary))
            }
        }.ripulThemedListRows()
    }
}
