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
    @Published private var pendingLinks: [String: CodingAccountPendingLink] = [:]
    private static let pendingLinksKey = "ripul.codingAccountPendingLinks.v1"
    private var pendingLinksRevision = 0
    private var refreshing = false

    init(provider: CodingAccountProvider, bridge: AgentBridge) {
        self.provider = provider
        self.bridge = bridge
        if let data = bridge.sessionCache?.data(forKey: Self.pendingLinksKey),
           let saved = try? JSONDecoder().decode([String: CodingAccountPendingLink].self, from: data) {
            pendingLinks = saved
        }
    }

    var groups: [CodingAccountGroup] {
        CodingAccountGroup.make(linkedEntries).filter { !$0.isUnidentified }
    }

    var unfinishedAccounts: [CodingAccountEntry] { linkedEntries.filter(\.isUnidentified) }

    private var linkedEntries: [CodingAccountEntry] {
        machines.flatMap { snapshots[$0.id]?.entries ?? [] }.map { entry in
            var entry = entry
            if entry.normalizedEmail == nil {
                entry.pendingLink = pendingLinks[linkKey(machineId: entry.machineId, localId: entry.localId)]
            }
            return entry
        }
    }

    func rememberAddition(_ account: CodingAccountGroup, machineId: String, localId: String) {
        guard let email = account.email else { return }
        pendingLinks[linkKey(machineId: machineId, localId: localId)] =
            CodingAccountPendingLink(accountId: account.id, name: account.name, email: email)
        pendingLinksRevision += 1
        savePendingLinks()
    }

    private func linkKey(machineId: String, localId: String) -> String {
        "\(provider.rawValue)/\(machineId)/\(localId)"
    }

    private func savePendingLinks() {
        // Other provider screens share this cache; replace only our provider.
        var saved: [String: CodingAccountPendingLink] = [:]
        if let data = bridge.sessionCache?.data(forKey: Self.pendingLinksKey) {
            saved = (try? JSONDecoder().decode([String: CodingAccountPendingLink].self, from: data)) ?? [:]
        }
        let prefix = "\(provider.rawValue)/"
        saved = saved.filter { !$0.key.hasPrefix(prefix) }
        saved.merge(pendingLinks.filter { $0.key.hasPrefix(prefix) }) { _, new in new }
        if let data = try? JSONEncoder().encode(saved) {
            bridge.sessionCache?.set(data, forKey: Self.pendingLinksKey)
        }
    }

    private func reconcilePendingLinks(_ entries: [CodingAccountEntry], machineId: String, revision: Int) {
        // A list request started before profile creation can return afterward.
        // It must not erase the new link just because its snapshot is older.
        guard revision == pendingLinksRevision else { return }
        let prefix = "\(provider.rawValue)/\(machineId)/"
        let awaitingIdentity = Set(entries.filter { $0.normalizedEmail == nil }.map {
            linkKey(machineId: machineId, localId: $0.localId)
        })
        let remaining = pendingLinks.filter { !$0.key.hasPrefix(prefix) || awaitingIdentity.contains($0.key) }
        if remaining != pendingLinks {
            pendingLinks = remaining
            pendingLinksRevision += 1
            savePendingLinks()
        }
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
        let linksRevision = pendingLinksRevision
        var snapshot = snapshots[machine.id] ?? Snapshot()
        guard !snapshot.loading, !snapshot.requesting else { return }
        snapshot.loading = true
        snapshot.error = nil
        snapshots[machine.id] = snapshot
        switch provider {
        case .claude:
            let result = await bridge.fetchClaudeAccounts(machineId: machine.id)
            if result.error == nil {
                // Claude Code's own folder with nothing signed in is no account, and no unfinished sign-in.
                snapshot.entries = result.accounts.filter { !$0.isEmptyDefault }.map {
                    var entry = entry(machine, id: $0.slug, name: $0.displayName, email: $0.email, plan: $0.plan,
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
                snapshot.entries = result.accounts.filter { !$0.isEmptyDefault }.map {
                    entry(machine, id: $0.slug, name: $0.displayName, email: $0.email, plan: $0.plan,
                          usage: $0.usage, active: $0.slug == result.active,
                          needsLogin: !$0.loggedIn || $0.usage?.error != nil)
                }
            }
            snapshot.error = result.error
        }
        snapshot.loading = false
        snapshot.loaded = true
        if snapshot.error == nil { reconcilePendingLinks(snapshot.entries, machineId: machine.id, revision: linksRevision) }
        // A cancelled screen task must not strand the next refresh as busy.
        snapshots[machine.id] = snapshot
    }

    /// What renaming an account did, by computer name.
    struct RenameOutcome {
        var renamed: [String] = []
        /// Its Ripul predates renaming.
        var needsUpdate: [String] = []
        /// Offline, or the rename did not go through.
        var notReached: [String] = []
    }

    /// Renames a Claude account everywhere: each of its profiles, on every
    /// computer that holds it, takes the name. Only the label changes; the
    /// sign-ins stay where they are. An offline computer keeps its old name.
    func renameAccount(_ account: CodingAccountGroup, to name: String) async -> RenameOutcome {
        var outcome = RenameOutcome()
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard provider == .claude, !name.isEmpty else { return outcome }
        for machine in machines where account.machineIds.contains(machine.id) {
            guard machine.isOnline else { outcome.notReached.append(machine.displayName); continue }
            var renamed: Set<String> = []
            var needsUpdate = false
            for entry in account.accounts(on: machine.id) {
                let result = await bridge.renameClaudeAccount(machineId: machine.id, slug: entry.localId, name: name)
                if result.ok { renamed.insert(entry.localId) } else { needsUpdate = needsUpdate || result.needsUpdate }
            }
            // Show the new name now; the next listing confirms it.
            if !renamed.isEmpty, var snapshot = snapshots[machine.id] {
                snapshot.entries = snapshot.entries.map { entry in
                    var entry = entry
                    if renamed.contains(entry.localId) { entry.name = name }
                    return entry
                }
                snapshots[machine.id] = snapshot
            }
            if renamed.count == account.accounts(on: machine.id).count { outcome.renamed.append(machine.displayName) }
            else if needsUpdate { outcome.needsUpdate.append(machine.displayName) }
            else { outcome.notReached.append(machine.displayName) }
        }
        return outcome
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
