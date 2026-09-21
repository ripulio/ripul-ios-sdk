import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public struct CodexSavedAccount: Decodable, Identifiable {
    public let id: String
    public let name: String
    public let email: String
    public let plan: String?
    public let needsLogin: Bool
    public let usage: CodingAccountUsage?
}
public struct CodexAccountOperation: Decodable {
    public let id: String
    public let kind: String
    public let status: String
    public let accountId: String?
    public let userCode: String?
    public let verificationUrl: String?
    public let expiresAt: Double?
    public let error: String?
    public var isPending: Bool { ["waiting", "signingIn", "switching"].contains(status) }
}
public struct CodexAccountsState: Decodable {
    public let ok: Bool
    public let accounts: [CodexSavedAccount]?
    public let active: String?
    public let operation: CodexAccountOperation?
    public let error: String?
}

extension AgentBridge {
    public func codexAccounts(machineId: String, direct: Bool = false, action: String = "list",
                              accountId: String? = nil, name: String? = nil) async throws -> CodexAccountsState {
        var params: [String: Any] = ["action": action, "requestId": UUID().uuidString]
        if let accountId { params["accountId"] = accountId }
        if let name { params["name"] = name }
        let result: Any?
        if direct {
            result = try await capabilityRouter.invoke(capability: "directMac", method: "request", args: [[
                "op": "machine", "action": "codex.accounts", "directHostId": machineId, "params": params
            ]])
        } else {
            let data = try JSONSerialization.data(withJSONObject: ["machineId": machineId, "params": params], options: [.sortedKeys])
            let literal = String(decoding: data, as: UTF8.self)
            result = try await callAsyncJavaScript("""
                const request = \(literal);
                if (!window.__ripulRemoteCodexAccounts) return { ok: false, error: 'Update Ripul to use Codex accounts.' };
                return await window.__ripulRemoteCodexAccounts(request.machineId, request.params);
                """)
        }
        guard let result else { throw NSError(domain: "CodexAccounts", code: 1, userInfo: [NSLocalizedDescriptionKey: "The Mac did not respond."]) }
        return try JSONDecoder().decode(CodexAccountsState.self, from: JSONSerialization.data(withJSONObject: result))
    }
}

public struct CodexAccountSwitcherSheet: View {
    let machineId: String
    let machineName: String
    let direct: Bool
    let bridge: AgentBridge
    @Environment(\.dismiss) private var dismiss

    public init(machineId: String, machineName: String, direct: Bool = false, bridge: AgentBridge) {
        self.machineId = machineId; self.machineName = machineName; self.direct = direct; self.bridge = bridge
    }
    public var body: some View {
        NavigationStack {
            List { CodexAccountSection(machineId: machineId, machineName: machineName, direct: direct, bridge: bridge) }
                .navigationTitle("Codex accounts")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.uiKitIdentifier("CodexAccounts.done") } }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 420)
        #endif
        .ripulSheet(.page, detents: [.medium, .large])
    }
}

/// A Mac's accounts and sign-in controls, embedded directly in the containing list.
struct CodexAccountSection: View {
    let machineId: String
    let machineName: String
    let direct: Bool
    let bridge: AgentBridge
    var isOnline = true
    var refreshToken: UUID? = nil
    @Environment(\.scenePhase) private var scenePhase
    @State private var state: CodexAccountsState?
    @State private var error: String?
    @State private var requesting = false
    @State private var copied = false
    @State private var removal: CodexSavedAccount?
    @State private var renaming: CodexSavedAccount?
    @State private var newName = ""

    private var busy: Bool { requesting || state?.operation?.isPending == true }
    var body: some View {
        Section {
            if !isOnline {
                Text("Connect to this Mac to manage accounts.").foregroundStyle(.secondary)
            } else {
                if state == nil && error == nil { ProgressView("Loading accounts…") }
                ForEach(state?.accounts ?? []) { account in
                    Button {
                        if account.id != state?.active || account.needsLogin {
                            Task { await perform(account.needsLogin ? "login" : "switch", accountId: account.id) }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 12) {
                                Image(systemName: account.id == state?.active ? "checkmark.circle.fill" : "person.crop.circle")
                                    .foregroundStyle(account.id == state?.active ? Color.accentColor : Color.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(account.name).foregroundStyle(.primary)
                                    if account.name != account.email { Text(account.email).font(.caption).foregroundStyle(.secondary) }
                                    if account.needsLogin { Text("Sign in again").font(.caption).foregroundStyle(.orange) }
                                }
                                Spacer()
                                if account.id == state?.active { Text("Active").font(.caption).foregroundStyle(.secondary) }
                                if state?.operation?.isPending == true && state?.operation?.accountId == account.id { ProgressView() }
                            }
                            CodingAccountUsageView(usage: account.usage, plan: account.plan)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                    .uiKitIdentifier("CodexAccounts.account.\(account.id)")
                    .contextMenu {
                        Button("Rename") { newName = account.name; renaming = account }.disabled(busy)
                        Button("Remove", role: .destructive) { removal = account }.disabled(busy || account.id == state?.active)
                    }
                }
                if let operation = state?.operation, operation.isPending { operationRows(operation) }
                if let message = error ?? state?.operation?.error {
                    Text(message).foregroundStyle(.orange).textSelection(.enabled).uiKitIdentifier("CodexAccounts.error")
                }
                Button { Task { await perform("login") } } label: { Label("Add account", systemImage: "plus") }
                    .disabled(busy).uiKitIdentifier("CodexAccounts.add")
                if state == nil && error != nil { Button("Retry") { Task { await refresh() } } }
            }
        } header: {
            HStack {
                Label(machineName, systemImage: "desktopcomputer")
                Spacer()
                if !isOnline { Text("Offline") }
            }
        } footer: {
            if isOnline {
                Text("One account is used by all Codex chats on this Mac, including VS Code. Your conversations stay available when you switch.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: refreshToken) {
            guard isOnline else { return }
            while !Task.isCancelled {
                await refresh()
                do { try await Task.sleep(nanoseconds: state?.operation?.isPending == true ? 1_500_000_000 : 8_000_000_000) } catch { break }
            }
        }
        .onChange(of: scenePhase) { phase in if phase == .active { Task { await refresh() } } }
        .confirmationDialog("Remove \(removal?.name ?? "account")?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } })) {
            Button("Remove saved sign-in", role: .destructive) { if let account = removal { Task { await perform("delete", accountId: account.id) } }; removal = nil }
        } message: { Text("Your conversations will stay on the Mac.") }
        .alert("Account name", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") { if let account = renaming { Task { await perform("rename", accountId: account.id, name: newName) } }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }
    @ViewBuilder private func operationRows(_ operation: CodexAccountOperation) -> some View {
        Group {
            if operation.status == "signingIn", let code = operation.userCode {
                Text("Sign in on your phone").font(.headline)
                Text(code).font(.system(.title2, design: .monospaced).weight(.semibold)).textSelection(.enabled)
                    .uiKitIdentifier("CodexAccounts.code")
                Text("Copy the code, open OpenAI, and sign in to the account you want to add.").font(.subheadline).foregroundStyle(.secondary)
                Button(copied ? "Code copied — open OpenAI" : "Copy code and open OpenAI") { openSignIn(operation) }
                    .buttonStyle(.borderedProminent).uiKitIdentifier("CodexAccounts.openSignIn")
                if let expires = operation.expiresAt {
                    HStack { Text("Code window remaining"); Text(Date(timeIntervalSince1970: expires / 1000), style: .timer) }
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                HStack { ProgressView(); Text(operation.status == "waiting" ? "Waiting for current replies to finish…" : "Switching account…") }
            }
            if operation.status != "switching" { Button("Cancel", role: .cancel) { Task { await perform("cancel") } }.disabled(requesting).uiKitIdentifier("CodexAccounts.cancel") }
        }
    }
    private func openSignIn(_ operation: CodexAccountOperation) {
        guard let code = operation.userCode, let address = operation.verificationUrl,
              let url = URL(string: address), url.scheme == "https", url.host == "auth.openai.com" else { return }
        #if canImport(UIKit)
        UIPasteboard.general.string = code
        UIApplication.shared.open(url)
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string)
        NSWorkspace.shared.open(url)
        #endif
        copied = true
    }
    private func refresh() async {
        guard isOnline && !requesting else { return }
        do { let result = try await bridge.codexAccounts(machineId: machineId, direct: direct)
            guard !Task.isCancelled else { return }
            if result.ok { state = result; error = nil } else { error = result.error }
        } catch { self.error = error.localizedDescription }
    }
    private func perform(_ action: String, accountId: String? = nil, name: String? = nil) async {
        requesting = true; error = nil; copied = false
        do { let result = try await bridge.codexAccounts(machineId: machineId, direct: direct, action: action, accountId: accountId, name: name)
            if result.ok { state = result } else { error = result.error }
        } catch { self.error = error.localizedDescription }
        requesting = false
    }
}

public struct CodexAccountsSettingsScreen: View {
    let bridge: AgentBridge
    let suppliedMachines: [RemoteMachine]?
    @State private var machines: [RemoteMachine] = []
    @State private var refreshToken = UUID()
    @State private var loading = true
    public init(bridge: AgentBridge, machines: [RemoteMachine]? = nil) { self.bridge = bridge; self.suppliedMachines = machines }
    public var body: some View {
        List {
            if loading { ProgressView("Loading Macs…") }
            else if machines.isEmpty { Text("Pair with a Mac to manage its Codex accounts.").foregroundStyle(.secondary) }
            ForEach(machines) { machine in
                CodexAccountSection(machineId: machine.machineId, machineName: machine.displayName,
                    direct: machine.meta?["connection"] == "direct", bridge: bridge,
                    isOnline: machine.isOnline, refreshToken: refreshToken)
            }
        }
        .navigationTitle("Codex accounts")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
        .refreshable { await load(); refreshToken = UUID() }
        .onChange(of: suppliedMachines) { _, _ in Task { await load() } }
    }
    private func load() async {
        if let suppliedMachines { machines = suppliedMachines.filter { $0.can("cli") } }
        else { machines = await bridge.listMachines().filter { $0.can("cli") } }
        loading = false
    }
}
