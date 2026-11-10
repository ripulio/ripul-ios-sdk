#if DEBUG
import Foundation
import Observation

/// `-ripul.debug.syntheticChats <n>`: n made-up chats after the real ones in
/// every session list, so a list as long as a busy account's can be measured on
/// a simulator with none (Peter's Duo held about 300 on 5 November 2026, and
/// arranging them took up to 345 ms). Every fifth was started by the one before,
/// so the list arranges families as his does. `touch()` changes one, as a Mac's
/// report of a changed chat does, and the lists take them again. Shown only:
/// the views add them, so nothing saves them (docs/main-thread.md).
@MainActor
@Observable
public final class SyntheticSessionRows {
    public static let shared = SyntheticSessionRows()
    public static let count = UserDefaults.standard.integer(forKey: "ripul.debug.syntheticChats")

    public private(set) var rows: [UnifiedSession] = []
    /// `rows`, read without following it: a list nobody can see.
    @ObservationIgnored public private(set) var rowsUnobserved: [UnifiedSession] = []
    @ObservationIgnored private var touches = 0

    private init() {
        guard Self.count > 0 else { return }
        let now = Date()
        rows = (0..<Self.count).map { Self.row($0, messages: 10 + $0, now: now) }
        rowsUnobserved = rows
    }

    /// One chat gains a message, as when its Mac reports it.
    public func touch() {
        guard !rows.isEmpty else { return }
        touches += 1
        let index = touches % rows.count
        rows[index] = Self.row(index, messages: (rows[index].messageCount ?? 0) + 1, now: Date())
        rowsUnobserved = rows
    }

    private static func row(_ index: Int, messages: Int, now: Date) -> UnifiedSession {
        UnifiedSession(
            id: "synthetic-chat-\(index)", title: "Synthetic chat \(index)",
            lastUsed: now.addingTimeInterval(-86_400 - Double(index) * 600),
            gitBranch: index % 3 == 0 ? "main" : "feature-\(index % 7)",
            messageCount: messages, projectName: "project-\(index % 12)",
            provider: "claude-cli", providerLabel: "Claude Code",
            machineName: "Synthetic Mac", machineId: "synthetic-mac",
            matchKeys: ["cli_synthetic-\(index)", "synthetic-\(index)"],
            startedBy: index % 5 == 4 ? SessionStartedBy(agentId: "synthetic-\(index - 1)") : nil,
            ripulSession: nil)
    }
}
#endif
