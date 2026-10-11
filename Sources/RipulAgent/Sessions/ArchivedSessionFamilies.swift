import Foundation

/// The archive laid out as the session list is: an archived chat that an agent
/// started sits under the chat that started it, when that chat is archived too.
///
/// Before this the archive was one flat list by date. A chat and the five it
/// started were six unrelated rows, and bringing the work back meant finding
/// and restoring each one.
public struct ArchivedSessionFamilies {
    public typealias Archived = AgentBridge.ArchivedSessionInfo

    /// Every row in family order: a chat, then the chats it started, each
    /// followed by its own. A family sits where its most recently archived
    /// member would.
    public let rows: [Archived]
    private let depthByKey: [String: Int]
    private let underByKey: [String: [Archived]]

    /// How far under its starter a row sits: 0 for a chat by itself or at the
    /// head of a family, 1 for a chat it started, 2 for anything deeper.
    public func depth(of row: Archived) -> Int { depthByKey[Self.key(row)] ?? 0 }

    /// The archived chats this one started, and theirs, in family order: what
    /// comes back with it.
    public func under(_ row: Archived) -> [Archived] { underByKey[Self.key(row)] ?? [] }

    /// An archive's id is only its own Mac's: a chat moved between Macs can be archived on both.
    private static func key(_ row: Archived) -> String { "\(row.machineId ?? "")|\(row.id)" }

    public static func arrange(_ archived: [Archived]) -> ArchivedSessionFamilies {
        var rowByKey: [String: Archived] = [:]
        for row in archived where rowByKey[key(row)] == nil { rowByKey[key(row)] = row }
        // The session list's own layout, so a starter is found the same way:
        // on the chat's own Mac, or on the Mac its id names.
        let sessions = archived.map { row -> UnifiedSession in
            // `claude-cli:<uuid>`; a starter is named by its chat id, `cli_<uuid>`.
            let uuid = row.id.split(separator: ":", maxSplits: 1).last.map(String.init) ?? row.id
            return UnifiedSession(
                id: key(row), title: row.displayName, lastUsed: row.archivedAt, gitBranch: nil, messageCount: nil,
                projectName: row.projectName, provider: row.provider, providerLabel: nil, machineName: nil,
                machineId: row.machineId, matchKeys: [row.id, "cli_\(uuid)", uuid], startedBy: row.startedBy,
                ripulSession: nil)
        }
        let layout = SessionFamilies.arrange(sessions, folds: false, recency: { Int($0.lastUsed.timeIntervalSince1970) })
        return ArchivedSessionFamilies(
            rows: layout.all.compactMap { rowByKey[$0.id] },
            depthByKey: layout.depth,
            underByKey: layout.under.mapValues { chats in chats.compactMap { rowByKey[$0.id] } })
    }
}
