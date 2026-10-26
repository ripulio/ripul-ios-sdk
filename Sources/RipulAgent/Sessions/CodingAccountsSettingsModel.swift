import SwiftUI

/// Settings gathers all hosts before drawing account rows. The existing
/// single-machine sheets still own profile creation, removal and sign-in.
@MainActor final class CodingAccountsSettingsModel: ObservableObject {
    struct Snapshot {
        var entries: [CodingAccountEntry] = []
        var loading = false
        var requesting = false
        var loaded = false
        var error: String?
        var operation: CodexAccountOperation?
        var busy: Bool { loading || requesting || operation?.isPending == true }
    }

    let provider: CodingAccountProvider
    let bridge: AgentBridge
    @Published private(set) var machines: [RemoteMachine] = []
    @Published private(set) var snapshots: [String: Snapshot] = [:]
    @Published private(set) var loading = true
    private var refreshing = false

    init(provider: CodingAccountProvider, bridge: AgentBridge) {
        self.provider = provider
        self.bridge = bridge
    }

    var groups: [CodingAccountGroup] {
        CodingAccountGroup.make(machines.flatMap { snapshots[$0.id]?.entries ?? [] })
    }

    var pollInterval: UInt64 {
        if provider != .codex { return 60_000_000_000 }
        return snapshots.values.contains { $0.operation?.isPending == true } ? 1_500_000_000 : 8_000_000_000
    }

    func refresh(suppliedMachines: [RemoteMachine]?) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false; loading = false }
        let discovered: [RemoteMachine]
        if let suppliedMachines { discovered = suppliedMachines }
        else { discovered = await bridge.listMachines() }
        guard !Task.isCancelled else { return }
        machines = discovered.filter { $0.can("cli") }.sorted {
            let order = $0.displayName.localizedStandardCompare($1.displayName)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        snapshots = snapshots.filter { id, _ in machines.contains { $0.id == id } }
        await withTaskGroup(of: Void.self) { group in
            for machine in machines where machine.isOnline {
                group.addTask { await self.refresh(machine) }
            }
        }
    }

    private func refresh(_ machine: RemoteMachine) async {
        var snapshot = snapshots[machine.id] ?? Snapshot()
        guard !snapshot.loading, !snapshot.requesting else { return }
        snapshot.loading = true
        snapshot.error = nil
        snapshots[machine.id] = snapshot
        switch provider {
        case .claude:
            let result = await bridge.fetchClaudeAccounts(machineId: machine.id)
            if result.error == nil {
                snapshot.entries = result.accounts.map {
                    var entry = entry(machine, id: $0.slug, name: $0.name, email: $0.email, plan: $0.plan,
                                      usage: $0.usage, active: $0.slug == result.active,
                                      needsLogin: !$0.loggedIn || $0.signInEnded || $0.usage?.error != nil)
                    entry.signInEndsAt = $0.signInEndsAt
                    entry.signInEnded = $0.signInEnded
                    return entry
                }
            }
            snapshot.error = result.error
        case .codex:
            do {
                let result = try await bridge.codexAccounts(machineId: machine.id, direct: isDirect(machine))
                apply(result, machine: machine, to: &snapshot)
            } catch { snapshot.error = error.localizedDescription }
        case .antigravity:
            let result = await bridge.fetchAntigravityAccounts(machineId: machine.id, direct: isDirect(machine))
            if result.error == nil {
                snapshot.entries = result.accounts.map {
                    entry(machine, id: $0.slug, name: $0.name, email: $0.email, plan: $0.plan,
                          usage: $0.usage, active: $0.slug == result.active,
                          needsLogin: !$0.loggedIn || $0.usage?.error != nil)
                }
            }
            snapshot.error = result.error
        }
        snapshot.loading = false
        snapshot.loaded = true
        // A cancelled screen task must not strand the next refresh as busy.
        snapshots[machine.id] = snapshot
    }

    func switchAccount(_ account: CodingAccountEntry, on machine: RemoteMachine) async {
        guard machine.isOnline, !account.needsLogin, !account.isActive,
              var snapshot = snapshots[machine.id], !snapshot.busy else { return }
        snapshot.requesting = true
        snapshot.error = nil
        snapshots[machine.id] = snapshot
        var active: String?
        switch provider {
        case .claude:
            let result = await bridge.switchClaudeAccount(machineId: machine.id, slug: account.localId)
            if result.ok { active = result.active ?? account.localId }
            else { snapshot.error = result.error ?? "Could not switch accounts." }
        case .codex:
            do {
                let result = try await bridge.codexAccounts(machineId: machine.id, direct: isDirect(machine),
                                                            action: "switch", accountId: account.localId)
                apply(result, machine: machine, to: &snapshot)
            } catch { snapshot.error = error.localizedDescription }
        case .antigravity:
            let result = await bridge.switchAntigravityAccount(machineId: machine.id, direct: isDirect(machine), slug: account.localId)
            if result.ok { active = result.active ?? account.localId }
            else { snapshot.error = result.error ?? "Could not switch accounts." }
        }
        if let active {
            snapshot.entries = snapshot.entries.map {
                entry(machine, id: $0.localId, name: $0.name, email: $0.email, plan: $0.plan,
                      usage: $0.usage, active: $0.localId == active, needsLogin: $0.needsLogin)
            }
        }
        snapshot.requesting = false
        snapshots[machine.id] = snapshot
    }

    private func apply(_ result: CodexAccountsState, machine: RemoteMachine, to snapshot: inout Snapshot) {
        guard result.ok else { snapshot.error = result.error ?? "Could not load accounts."; return }
        snapshot.entries = (result.accounts ?? []).map {
            entry(machine, id: $0.id, name: $0.name, email: $0.email, plan: $0.plan,
                  usage: $0.usage, active: $0.id == result.active, needsLogin: $0.needsLogin)
        }
        snapshot.operation = result.operation
        snapshot.error = result.operation?.error
    }

    private func entry(_ machine: RemoteMachine, id: String, name: String, email: String?, plan: String?,
                       usage: CodingAccountUsage?, active: Bool, needsLogin: Bool) -> CodingAccountEntry {
        CodingAccountEntry(provider: provider, machineId: machine.id, localId: id, name: name,
                           email: email, plan: plan, usage: usage, isActive: active, needsLogin: needsLogin)
    }

    private func isDirect(_ machine: RemoteMachine) -> Bool { machine.meta?["connection"] == "direct" }
}
