import SwiftUI

/// Account-first Settings, shared by all coding providers and native clients.
struct CodingAccountsSettingsList: View {
    let suppliedMachines: [RemoteMachine]?
    @StateObject private var model: CodingAccountsSettingsModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var presentation: Presentation?
    @State private var refreshToken = UUID()
    @State private var machineIcons: [String: String] = [:]

    private struct Presentation: Identifiable {
        let machine: RemoteMachine
        var signIn: CodingAccountEntry?
        var addAccount = false
        var id: String { "\(machine.id)/\(signIn?.localId ?? (addAccount ? "add" : "manage"))" }
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
                Section {
                    ForEach(model.groups) { account in accountRow(account) }
                    ForEach(model.machines) { machine in machineStatus(machine) }
                    Menu {
                        ForEach(model.machines) { machine in
                            Button { presentation = Presentation(machine: machine, addAccount: true) } label: {
                                Label(machine.displayName, systemImage: icon(machine))
                            }
                            .disabled(!machine.isOnline || model.snapshots[machine.id]?.busy == true)
                        }
                    } label: { Label("Add account", systemImage: "plus") }
                    .uiKitIdentifier("CodingAccounts.add")
                } footer: { RipulSectionFooter {
                    Text("Tap a machine icon to switch or manage its account. A checkmark shows the account in use on that machine.")
                } }.ripulThemedListRows()
            }
        }
        .ripulThemedList()
        .modifier(CodingAccountsListWidth())
        .navigationTitle("\(model.provider.title) accounts")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
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
    }

    private func accountRow(_ account: CodingAccountGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    accountIdentity(account).frame(minWidth: 130, maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 0) { machineButtons(account) }.fixedSize()
                }
                VStack(alignment: .leading, spacing: 2) {
                    accountIdentity(account)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44, maximum: 44), spacing: 0)], alignment: .leading, spacing: 0) {
                        machineButtons(account)
                    }
                }
            }
            if account.entries.contains(where: { !$0.needsLogin }) || account.usage != nil {
                CodingAccountUsageView(usage: account.usage, plan: account.plan, showsPlan: false)
            }
        }
        .padding(.vertical, 6)
        .uiKitIdentifier("CodingAccounts.account.\(account.id)")
    }

    private func accountIdentity(_ account: CodingAccountGroup) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(account.name).font(.ripul(.body, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                CodingAccountPlanBadge(usage: account.usage, plan: account.plan)
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
                    }
                }
            } label: {
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
                    .opacity(machine.isOnline ? 1 : 0.5)
                    .frame(width: 44, height: 44)
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
        }
    }

    @ViewBuilder private func managementSheet(_ request: Presentation) -> some View {
        switch model.provider {
        case .claude:
            if let account = request.signIn {
                HostSignInSheet(machine: request.machine, bridge: model.bridge,
                                profile: account.localId, profileName: account.name, startSignInImmediately: true)
            } else {
                ClaudeAccountSwitcherSheet(machine: request.machine, bridge: model.bridge, startsAddingAccount: request.addAccount)
            }
        case .codex:
            CodexAccountSwitcherSheet(machineId: request.machine.id, machineName: request.machine.displayName,
                                      direct: request.machine.meta?["connection"] == "direct", bridge: model.bridge,
                                      signInAccountId: request.signIn?.localId, startsAddingAccount: request.addAccount)
        case .antigravity:
            if let account = request.signIn {
                AntigravitySignInSheet(machine: request.machine, bridge: model.bridge,
                                      profile: account.localId, profileName: account.name, startSignInImmediately: true)
            } else {
                AntigravityAccountSwitcherSheet(machine: request.machine, bridge: model.bridge, startsAddingAccount: request.addAccount)
            }
        }
    }

    private func icon(_ machine: RemoteMachine) -> String { machineIcons[machine.id] ?? machine.defaultIconName }
    private func updateIcons() {
        machineIcons = model.bridge.sessionCache.map { RemoteMachine.machineIconMap(cache: $0) } ?? [:]
    }
}
