import SwiftUI

/// Every coding account on every Mac, Claude, Codex and Antigravity together,
/// for a summary such as Ripul's Home (Peter, 2 November 2026). It reads the
/// three Settings lists' own model (`CodingAccountsSettingsModel`), so an
/// account here is the account Settings shows: one person's login, gathered
/// across the Macs that hold it, with one reading of its usage.
@MainActor public final class CodingAccountsOverview: ObservableObject {
    /// What the summary can say.
    public enum Reading: Equatable {
        /// Not read yet, or no Mac that runs agents answered: say nothing.
        case unknown
        /// No Mac that runs agents is set up.
        case noMacs
        /// Every online Mac answered. An empty list means nobody is signed in.
        case read
    }

    /// One login, as Settings groups it.
    public struct Account: Identifiable, Equatable {
        public let id: String
        public let provider: CodingAccountProvider
        public let name: String
        public let email: String?
        /// As the provider names it; `CodingAccountPlanBadge` words it.
        public let plan: String?
        public let usage: CodingAccountUsage?
        /// The Macs holding it, by name.
        public let machines: [String]
        /// The Macs where it has to be signed in again, by name.
        public let signedOutOn: [String]
        /// In use on at least one Mac.
        public let isActive: Bool
        /// The Macs where it is the one in use, by name: a new chat there runs on it.
        public let activeOn: [String]

        /// Signed out everywhere it is kept.
        public var needsSignIn: Bool { !signedOutOn.isEmpty && signedOutOn.count == machines.count }

        /// The limit nearest to full, when the reading is current: an account
        /// the host could not refresh keeps windows that may be weeks old.
        public var tightestWindow: CodingAccountUsage.Window? {
            guard let usage, usage.error == nil else { return nil }
            return usage.windows.max { $0.usedPercent < $1.usedPercent }
        }

        /// A current reading says one of its limits is used up: a new chat on it stops at once.
        public var atLimit: Bool { (tightestWindow?.usedPercent ?? 0) >= 100 }
    }

    @Published public private(set) var accounts: [Account] = []
    @Published public private(set) var reading: Reading = .unknown
    /// The Macs that run agents, as last listed: where an account can be added.
    @Published public private(set) var machines: [RemoteMachine] = []
    public private(set) var refreshedAt: Date?

    private var models: [CodingAccountsSettingsModel] = []
    private weak var modelsBridge: AgentBridge?
    private var running: Task<Void, Never>?

    public init() {}

    /// Reads every Mac's accounts again. One machine list serves the three
    /// providers (`machines`, or the bridge's own list), and what they say is
    /// published once, when all have answered: published as each answered, a
    /// summary on a scrolling screen grew up to three times in a reading and
    /// moved what was under it (Home, 2 November 2026).
    ///
    /// A complete reading younger than `maxAge`, of the same online Macs, is
    /// kept. Anything less is read again: at launch the page answers "not
    /// ready" to every call, and that must not stand for five minutes.
    ///
    /// The reading runs in a task of its own, so a caller's cancelled task (a
    /// screen's `.task` restarting as it appears) neither cancels the Macs'
    /// answers nor drops them. A second caller waits for the one under way.
    public func refresh(bridge: AgentBridge, machines supplied: [RemoteMachine]? = nil,
                        olderThan maxAge: TimeInterval = 0) async {
        if reading == .read, let refreshedAt, Date().timeIntervalSince(refreshedAt) < maxAge,
           supplied.map(Self.onlineKey) ?? readKey == readKey { return }
        if let running { await running.value; return }
        let task = Task { await self.read(bridge: bridge, supplied: supplied) }
        running = task
        await task.value
        if running == task { running = nil }
    }

    /// The online Macs that run agents, as one string, to tell a new set from the last one read.
    private static func onlineKey(_ machines: [RemoteMachine]) -> String {
        machines.filter { $0.isOnline && $0.can("cli") }.map(\.id).sorted().joined(separator: ",")
    }

    private var readKey: String?

    private func read(bridge: AgentBridge, supplied: [RemoteMachine]?) async {
        if models.isEmpty || modelsBridge !== bridge {
            models = CodingAccountProvider.allCases.map { CodingAccountsSettingsModel(provider: $0, bridge: bridge) }
            modelsBridge = bridge
        }
        var discovered = supplied ?? []
        if supplied == nil { discovered = await bridge.listMachines() }
        let models = self.models
        let macs = discovered
        await withTaskGroup(of: Void.self) { group in
            for model in models { group.addTask { await model.refresh(suppliedMachines: macs) } }
        }
        refreshedAt = Date()
        readKey = Self.onlineKey(discovered)
        publish()
    }

    private func publish() {
        let read = models.map { model in
            ProviderReading(provider: model.provider, groups: model.groups,
                            machines: model.machines.map { (id: $0.id, name: $0.displayName, online: $0.isOnline) },
                            answered: Set(model.snapshots.filter { $0.value.loaded }.map(\.key)),
                            answeredWithoutError: Set(model.snapshots.filter { $0.value.loaded && $0.value.error == nil }.map(\.key)))
        }
        let summary = Self.summarise(read)
        if accounts != summary.accounts { accounts = summary.accounts }
        if reading != summary.reading { reading = summary.reading }
        let listed = models.first?.machines ?? []
        if listed.map(\.id) != machines.map(\.id) || listed.map(\.isOnline) != machines.map(\.isOnline) { machines = listed }
    }

    /// One provider's list, as the summary needs it.
    struct ProviderReading {
        let provider: CodingAccountProvider
        let groups: [CodingAccountGroup]
        /// Macs that run agents.
        let machines: [(id: String, name: String, online: Bool)]
        /// Macs that have answered for this provider, an error included.
        let answered: Set<String>
        /// Macs whose answer listed the accounts.
        let answeredWithoutError: Set<String>
    }

    /// The accounts in the providers' order, each provider's in use first, and
    /// what can be said about them.
    static func summarise(_ providers: [ProviderReading]) -> (accounts: [Account], reading: Reading) {
        let macs = providers.flatMap(\.machines)
        guard !macs.isEmpty else { return ([], providers.isEmpty ? .unknown : .noMacs) }
        let online = Set(macs.filter(\.online).map(\.id))
        // Unknown while any online Mac has still not answered for a provider,
        // so "nobody is signed in" is never said early; and while any gave
        // only errors ("not ready" at launch, a timeout), so it is never said
        // wrongly. One agent failing on a Mac (not installed there) is an answer.
        let everyoneAnswered = !online.isEmpty
            && providers.allSatisfy { online.isSubset(of: $0.answered) }
            && online.allSatisfy { mac in providers.contains { $0.answeredWithoutError.contains(mac) } }
        let accounts = providers.flatMap { provider -> [Account] in
            let names = Dictionary(provider.machines.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            return provider.groups.map { group in
                Account(id: "\(provider.provider.rawValue)/\(group.id)", provider: provider.provider,
                        name: group.name, email: group.email, plan: group.plan, usage: group.usage,
                        machines: group.machineIds.map { names[$0] ?? "A Mac" },
                        signedOutOn: group.machineIds.filter { id in
                            group.entries.filter { $0.machineId == id }.allSatisfy(\.needsLogin)
                        }.map { names[$0] ?? "A Mac" },
                        isActive: group.entries.contains(where: \.isActive),
                        activeOn: group.machineIds.filter { id in
                            group.entries.contains { $0.machineId == id && $0.isActive && !$0.needsLogin }
                        }.map { names[$0] ?? "A Mac" })
            }
            .sorted { a, b in a.isActive != b.isActive ? a.isActive : a.name.localizedStandardCompare(b.name) == .orderedAscending }
        }
        if !accounts.isEmpty { return (accounts, .read) }
        return ([], everyoneAnswered ? .read : .unknown)
    }
}

/// One provider's accounts on every Mac, as Settings lists them, for a summary
/// that opens them (Home): sign in, switch, add, and each account's limits.
public struct CodingAccountsScreen: View {
    let provider: CodingAccountProvider
    let bridge: AgentBridge

    public init(provider: CodingAccountProvider, bridge: AgentBridge) {
        self.provider = provider
        self.bridge = bridge
    }

    public var body: some View {
        CodingAccountsSettingsList(provider: provider, bridge: bridge)
    }
}

/// Adding an account on one Mac: the provider's own sheet, opened on Add, as
/// the Settings list's Add account does.
public struct CodingAccountAddSheet: View {
    let provider: CodingAccountProvider
    let machine: RemoteMachine
    let bridge: AgentBridge

    public init(provider: CodingAccountProvider, machine: RemoteMachine, bridge: AgentBridge) {
        self.provider = provider
        self.machine = machine
        self.bridge = bridge
    }

    public var body: some View {
        switch provider {
        case .claude:
            ClaudeAccountSwitcherSheet(machine: machine, bridge: bridge, startsAddingAccount: true)
        case .codex:
            CodexAccountSwitcherSheet(machineId: machine.id, machineName: machine.displayName,
                                      direct: machine.meta?["connection"] == "direct", bridge: bridge,
                                      startsAddingAccount: true)
        case .antigravity:
            AntigravityAccountSwitcherSheet(machine: machine, bridge: bridge, startsAddingAccount: true)
        }
    }
}
