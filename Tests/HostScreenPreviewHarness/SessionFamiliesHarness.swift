import SwiftUI
@testable import RipulAgent

/// The session list's family layout with the real rows: a chat, the chats it
/// started, and the control that folds the quiet ones away.
struct SessionFamiliesHarness: View {
    @State private var store = SessionListStore()
    @State private var open: Set<String> = []
    @State private var closed: Set<String> = []

    private static let now = Date()
    /// - Parameter running: Mid-turn on its Mac and not open on this device, as a chat an agent has just started is.
    private static func chat(_ title: String, minutesAgo: Double, model: String = "claude-opus-5-5", branch: String? = "main",
                             startedBy starter: (id: String, title: String)? = nil, id: String? = nil,
                             running: Bool = false) -> UnifiedSession {
        let key = id ?? title
        return UnifiedSession(
            id: "claude-cli:\(key)", title: title, lastUsed: now.addingTimeInterval(-minutesAgo * 60),
            gitBranch: branch, messageCount: 12, projectName: "ripul", provider: "claude-cli", providerLabel: "Claude Code",
            model: model, machineName: "Studio", machineId: "studio", matchKeys: ["claude-cli:\(key)", "cli_\(key)"],
            startedBy: starter.map { SessionStartedBy(agentId: "cli_\($0.id)", sessionId: "claude-cli:\($0.id)", title: $0.title) },
            runningOnHost: running,
            ripulSession: nil)
    }

    private static let design = (id: "design", title: "Design alignment")
    private static let sessions: [UnifiedSession] = [
        chat("Tool panel renders", minutesAgo: 14),
        chat("Design alignment", minutesAgo: 95, id: "design"),
        chat("Theme: chat panels", minutesAgo: 1, startedBy: design, id: "panels"),
        // Mid-turn, two steps under the head: the head has to say so when the family is put away.
        chat("Check the bubble colours for contrast", minutesAgo: 3, model: "claude-haiku-4-5",
             startedBy: (id: "panels", title: "Theme: chat panels"), running: true),
        chat("Theme: session rows", minutesAgo: 4, startedBy: design),
        // On a branch of its own, so it is the one started chat that says where it is.
        chat("Theme: tool sheets", minutesAgo: 9, branch: "tool-sheets", startedBy: design),
        chat("Theme: settings screens", minutesAgo: 16, startedBy: design),
        chat("Theme: plan review", minutesAgo: 21, startedBy: design),
        chat("Theme: browser", minutesAgo: 33, startedBy: design),
        chat("Thermals", minutesAgo: 40, branch: "thermals"),
        // Its starter is not in the list, so it says whose it is.
        chat("Port the parser to the new grammar", minutesAgo: 55, model: "gpt-5-codex", startedBy: (id: "gone", title: "Codex migration")),
    ]

    var body: some View {
        // The list's own reading of the store for what may not be folded away.
        let families = SessionFamilies.arrange(
            Self.sessions, open: open, closed: closed, recency: { Int($0.lastUsed.timeIntervalSince1970 / 30) },
            mustShow: { store.isWorkingOrAsking($0) })
        NavigationStack {
            GlassRichList(
                items: families.visible, emptyState: nil, identifierPrefix: "SessionFamiliesHarness",
                onTap: { _ in },
                row: { session in
                    VStack(alignment: .leading, spacing: 0) {
                        UnifiedSessionRow(
                            sessionStore: store, session: session,
                            hideProjectName: families.sharesFolder.contains(session.id),
                            hideBranch: families.sharesBranch.contains(session.id),
                            familyDepth: families.depth[session.id] ?? 0,
                            startedChats: families.heads[session.id]?.started ?? 0,
                            startedChatsClosed: families.heads[session.id]?.isClosed ?? false,
                            startedChatsNeedLooking: families.heads[session.id]?.needsLooking ?? false,
                            startedChatsPutAway: families.heads[session.id]?.putAway ?? [],
                            onToggleStartedChats: {
                                if closed.contains(session.id) { closed.remove(session.id) } else { closed.insert(session.id) }
                            })
                        if let fold = families.folds[session.id] {
                            SessionFamilyFoldButton(fold: fold) {
                                if fold.isOpen { open.remove(fold.parentId) } else { open.insert(fold.parentId) }
                            }
                        }
                    }
                },
                swipe: { _ in EmptyView() },
                rowMenu: { _ in EmptyView() })
            .navigationTitle("Sessions")
        }
    }
}
