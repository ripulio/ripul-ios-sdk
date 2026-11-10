import SwiftUI
@testable import RipulAgent

/// Ripul's Home as far as scrolling goes (2 November 2026, Peter: "Scrolling
/// the Home Screen, it jumps around"): the real Jump back in
/// (`GlassSessionsList` in its `.recent` presentation, the same rows and
/// families) in a scrolling column with sections of fixed height under it,
/// laid out as `HomeScreen` lays them out.
///
/// `--home-demo` makes the chats behave as working agents do: those following
/// a plan go between running a tool and thinking every 0.75 s (a row with a
/// plan showed the running tool on a third line), and every 3 s another chat
/// speaks and becomes the most recent.
struct HomeScrollHarness: View {
    @State private var store = SessionListStore()
    @State private var bridge = AgentBridge()
    @StateObject private var navigation = NavigationStore()
    @State private var search = ""
    @State private var renaming: ChatSession?
    @State private var renameText = ""

    private static let arguments = ProcessInfo.processInfo.arguments
    private static let cache: UserDefaultsSessionCache = {
        let cache = UserDefaultsSessionCache(suiteName: "io.ripul.home-scroll-harness")
        // Every family starts open, as on a phone that has never closed one.
        cache.removeObject(forKey: "ripulClosedSessionFamilies")
        return cache
    }()
    private static let now = Date()

    /// Chats an agent is working in, open in Ripul so their rows show it.
    private static let working = ["records", "jobs", "look", "employer", "trainyard", "sql"]
    /// Of those, the ones following a plan: their rows grow a line while a tool runs.
    private static let planned = ["records", "jobs", "employer"]
    /// Who speaks next, in turn: each becomes the most recent chat.
    private static let speakers = ["records", "employer", "trainyard", "sql", "jobs", "notes"]

    private static func chat(_ title: String, _ key: String, hoursAgo: Double, startedBy starter: (String, String)? = nil,
                             model: String = "claude-opus-5-5") -> UnifiedSession {
        UnifiedSession(
            id: "claude-cli:\(key)", title: title, lastUsed: now.addingTimeInterval(-hoursAgo * 3600),
            gitBranch: "main", messageCount: 20, projectName: "ripul", provider: "claude-cli", providerLabel: "Claude Code",
            model: model, machineName: "Studio", machineId: "studio", matchKeys: ["claude-cli:\(key)", "cli_\(key)"],
            startedBy: starter.map { SessionStartedBy(agentId: "cli_\($0.0)", sessionId: "claude-cli:\($0.0)", title: $0.1) },
            ripulSession: working.contains(key)
                ? ChatSession(id: "cli_\(key)", sourceChatId: "cli_\(key)", displayName: title, createdAt: now) : nil)
    }

    private static let sessions: [UnifiedSession] = [
        chat("Cloud sql update", "sql", hoursAgo: 2),
        chat("Employer - AI - Reconcile", "employer", hoursAgo: 3, model: "gpt-6"),
        chat("WAC Android", "android", hoursAgo: 5),
        chat("WAC Android records and events porter", "records", hoursAgo: 4, startedBy: ("android", "WAC Android")),
        chat("WAC Android jobs and employers porter", "jobs", hoursAgo: 4.2, startedBy: ("android", "WAC Android")),
        chat("WAC Android look and navigation porter", "look", hoursAgo: 4.4, startedBy: ("android", "WAC Android")),
        chat("Train yard Mac builds", "trainyard", hoursAgo: 6),
        chat("Meeting notes", "notes", hoursAgo: 7),
        chat("Home screen concept", "home", hoursAgo: 8),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Good afternoon, Peter").font(.title2.weight(.semibold))
                ForEach(Self.sections, id: \.self) { name in
                    section(name)
                }
            }
            .padding(20)
        }
        .accessibilityIdentifier("HomeScrollHarness")
        .task { await runDemo() }
    }

    private static let sections = ["resume", "running", "places", "made", "everything", "help"]

    @ViewBuilder
    private func section(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(name.capitalized)
                .font(.title3.weight(.semibold))
                .accessibilityIdentifier("HomeScrollHarness.\(name)")
            if name == "resume" {
                jumpBackIn
            } else {
                // Each other section is a card of a fixed height, as Home's are while their data holds.
                RoundedRectangle(cornerRadius: 16).fill(.quaternary)
                    .frame(height: name == "everything" ? 420 : name == "places" ? 220 : 120)
            }
        }
    }

    private var jumpBackIn: some View {
        GlassSessionsList(
            bridge: bridge, sessionStore: store, navigationStore: navigation, cache: Self.cache,
            machines: [], connectingMachineId: nil, callbacks: SessionsListCallbacks(),
            unifiedSessions: Self.sessions, isLoadingRemoteSessions: false, hasResolvedMachines: true,
            openingUnifiedSessionId: nil, archivingUnifiedSessionId: nil, deletingUnifiedSessionId: nil,
            leavingUnifiedSessionId: nil, deletingFromHost: false, lastActiveBySessionId: [:],
            onOpenUnifiedSession: { _ in }, onArchiveUnifiedSession: { _ in }, onDeleteUnifiedSession: { _ in },
            onRemoveFromRipulUnifiedSession: { _ in }, onRemoveInvitedUnifiedSession: { _ in },
            onLeaveInvitedUnifiedSession: { _ in }, onMoveUnifiedSession: { _, _ in },
            onBatchArchive: { _ in }, onBatchDelete: { _ in },
            presentation: .recent(limit: 3, autoSort: !Self.arguments.contains("--home-scroll-ui-tests")),
            searchText: $search, renamingSession: $renaming, renameText: $renameText)
            .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func runDemo() async {
        guard Self.arguments.contains("--home-demo") else { return }
        for key in Self.planned {
            store.todoStates["cli_\(key)"] = TodoState(version: 1, todos: [
                TodoItem(content: "Port the screen", status: "completed", activeForm: nil),
                TodoItem(content: "Wire the data", status: "in_progress", activeForm: "Wiring the data"),
                TodoItem(content: "Check it on the phone", status: "pending", activeForm: nil),
            ], updatedAt: Self.now)
        }
        // Speaking moves a chat into a newer 30-second step of the list's
        // recency each time, as minutes of work do on a phone.
        let base = Self.now.addingTimeInterval(-3600)
        var tick = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(750))
            tick += 1
            for (index, key) in Self.working.enumerated() {
                switch (tick + index) % 3 {
                case 0:
                    store.latestActivityByChatId["cli_\(key)"] = .toolStart(
                        toolName: "Bash", toolId: "\(key)-\(tick)", toolLabel: "Bash", toolDetail: "swift build")
                case 1:
                    store.latestActivityByChatId["cli_\(key)"] = .toolStart(
                        toolName: "Grep", toolId: "\(key)-\(tick)", toolLabel: "Search", toolDetail: "UnifiedSessionRow")
                default:
                    store.latestActivityByChatId["cli_\(key)"] = .thinking
                }
            }
            if tick % 4 == 0 {
                let speaker = Self.speakers[(tick / 4 - 1) % Self.speakers.count]
                store.lastActiveTimeByChatId["claude-cli:\(speaker)"] = base.addingTimeInterval(Double(tick) * 60)
            }
        }
    }
}
