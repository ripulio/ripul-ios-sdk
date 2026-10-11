import SwiftUI

/// Chats an agent started, placed under the chat that started them.
///
/// The list is otherwise one row a chat, most recent first, so an agent and
/// the agents it started drifted apart as each did its own work, and a started
/// chat had to say where it came from in its title. A family moves as one: it
/// sits where its most recently active member would, the starter first and the
/// chats it started indented beneath it.
struct SessionFamilies: Equatable {
    /// A control drawn after a row: the family it ends has more started chats
    /// than are shown, or is showing all of them and can be folded again.
    struct Fold: Equatable {
        /// The chat at the head of the family, whose started chats these are.
        let parentId: String
        /// How many started chats the fold holds.
        let count: Int
        let isOpen: Bool
    }

    /// What the chat at the head of a family shows about the chats under it.
    struct Head: Equatable {
        /// Every chat under it, however deep.
        let started: Int
        /// The person has put its started chats away.
        let isClosed: Bool
        /// Closed, with a chat under it that is working or asking.
        let needsLooking: Bool
    }

    /// Every row in family order, including those folded away.
    let all: [UnifiedSession]
    /// The rows to draw.
    let visible: [UnifiedSession]
    /// How far a row is indented: 1 for a started chat, 2 for a chat that one
    /// started. A row by itself, or at the head of a family, has no entry.
    let depth: [String: Int]
    /// By the id of the row each control follows.
    let folds: [String: Fold]
    /// By the id of each chat that has started others.
    let heads: [String: Head]
    /// Started chats in the same folder as the chat they sit under. The row
    /// above already names it, so only a chat working somewhere else says where.
    let sharesFolder: Set<String>
    /// Of those, the ones on the same branch too. A branch is only the same
    /// branch in the same folder: `main` in another repository is not.
    let sharesBranch: Set<String>

    /// Quiet started chats shown under a parent before the rest fold away. One
    /// that is working, or has stopped to ask something, is always shown.
    static let quietShown = 3
    static let deepest = 2

    /// - Parameters:
    ///   - open: Heads of families whose folds the person has opened.
    ///   - closed: Heads of families whose started chats the person has put away.
    ///   - folds: False shows every row, as a search must: a match may be a folded chat.
    ///   - recency: A row's place in time; larger is more recent. Called once a row.
    ///   - mustShow: A started chat that may not be folded away.
    static func arrange(
        _ sessions: [UnifiedSession],
        open: Set<String> = [],
        closed: Set<String> = [],
        folds foldsFamilies: Bool = true,
        isPinned: (UnifiedSession) -> Bool = { _ in false },
        recency: (UnifiedSession) -> Int,
        mustShow: (UnifiedSession) -> Bool = { _ in false }
    ) -> SessionFamilies {
        let pinned = sessions.map(isPinned)
        let ownRecency = sessions.map(recency)

        // Who is under whom. Only a list with a started chat pays for the index.
        var parent = [Int?](repeating: nil, count: sessions.count)
        if sessions.contains(where: { $0.startedBy != nil }) {
            var rowByKey: [String: Int] = [:]
            for (index, session) in sessions.enumerated() {
                for key in [session.id] + session.matchKeys where rowByKey[key] == nil { rowByKey[key] = index }
            }
            for (index, session) in sessions.enumerated() {
                guard let starter = session.startedBy,
                      let found = [starter.sessionId, starter.agentId].compactMap({ $0 }).lazy.compactMap({ rowByKey[$0] }).first,
                      found != index else { continue }
                // An id means something on the Mac that issued it and nothing on another.
                if let here = session.machineId, let there = sessions[found].machineId, here != there { continue }
                parent[index] = found
            }
            // Two chats naming each other would each wait for the other to be placed.
            for index in sessions.indices {
                var seen: Set<Int> = [index]
                var above = parent[index]
                while let next = above {
                    if !seen.insert(next).inserted { parent[index] = nil; break }
                    above = parent[next]
                }
            }
        }

        var children = [[Int]](repeating: [], count: sessions.count)
        var heads: [Int] = []
        for index in sessions.indices {
            if let above = parent[index] { children[above].append(index) } else { heads.append(index) }
        }

        // A family sits where its most recently active member would.
        var recencyOfFamily = ownRecency
        var lastUsedOfFamily = sessions.map(\.lastUsed)
        func lift(_ index: Int) {
            for child in children[index] {
                lift(child)
                recencyOfFamily[index] = max(recencyOfFamily[index], recencyOfFamily[child])
                lastUsedOfFamily[index] = max(lastUsedOfFamily[index], lastUsedOfFamily[child])
            }
        }
        heads.forEach(lift)
        heads.sort { a, b in
            if pinned[a] != pinned[b] { return pinned[a] }
            if recencyOfFamily[a] != recencyOfFamily[b] { return recencyOfFamily[a] > recencyOfFamily[b] }
            return lastUsedOfFamily[a] > lastUsedOfFamily[b]
        }

        var all: [UnifiedSession] = []
        var visible: [UnifiedSession] = []
        var depth: [String: Int] = [:]
        var folds: [String: Fold] = [:]
        var headsById: [String: Head] = [:]
        var sharesFolder: Set<String> = []
        var sharesBranch: Set<String> = []
        all.reserveCapacity(sessions.count)
        visible.reserveCapacity(sessions.count)

        /// Places a chat and everything under it. Returns how many chats are
        /// under it, and whether any of them is working or asking.
        @discardableResult
        func place(_ index: Int, level: Int, shown: Bool) -> (under: Int, asking: Bool) {
            let session = sessions[index]
            all.append(session)
            if shown { visible.append(session) }
            if level > 0 { depth[session.id] = min(level, deepest) }

            let started = children[index].sorted { a, b in
                recencyOfFamily[a] != recencyOfFamily[b] ? recencyOfFamily[a] > recencyOfFamily[b] : lastUsedOfFamily[a] > lastUsedOfFamily[b]
            }
            guard !started.isEmpty else { return (0, false) }

            // Put away by the person. A search still shows every match.
            let isClosed = level == 0 && foldsFamilies && closed.contains(session.id)

            // Only the head of a family folds: one control a family, after its last row.
            var folded: Set<Int> = []
            var fold: Fold?
            if level == 0 && foldsFamilies && !isClosed {
                let quiet = started.filter { !mustShow(sessions[$0]) }
                let beyond = Array(quiet.dropFirst(quietShown))
                // A control costs a row: it has to hide at least two to earn it.
                if beyond.count >= 2 {
                    let isOpen = open.contains(session.id)
                    if !isOpen { folded = Set(beyond) }
                    fold = Fold(parentId: session.id, count: beyond.count, isOpen: isOpen)
                }
            }
            var under = 0
            var asking = false
            for child in started {
                if sessions[child].projectName == session.projectName {
                    sharesFolder.insert(sessions[child].id)
                    if sessions[child].gitBranch == session.gitBranch { sharesBranch.insert(sessions[child].id) }
                }
                let below = place(child, level: level + 1, shown: shown && !isClosed && !folded.contains(child))
                under += 1 + below.under
                asking = asking || below.asking || mustShow(sessions[child])
            }
            if let fold, shown, let last = visible.last { folds[last.id] = fold }
            if level == 0 { headsById[session.id] = Head(started: under, isClosed: isClosed, needsLooking: isClosed && asking) }
            return (under, asking)
        }
        for head in heads { place(head, level: 0, shown: true) }

        return SessionFamilies(all: all, visible: visible, depth: depth, folds: folds, heads: headsById,
                               sharesFolder: sharesFolder, sharesBranch: sharesBranch)
    }
}

/// The control at the end of a family that has more started chats than it shows.
struct SessionFamilyFoldButton: View {
    let fold: SessionFamilies.Fold
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(fold.isOpen ? "Show fewer" : "\(fold.count) more", systemImage: fold.isOpen ? "chevron.up" : "ellipsis")
                .font(.ripul(.caption, weight: .medium))
                .foregroundStyle(.ripul(.textSecondary))
                // In line with the started chats above it.
                .padding(.leading, 26)
                .padding(.top, 8)
                .padding(.bottom, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(fold.isOpen ? "Show fewer started chats" : "Show \(fold.count) more started chats")
        .uiKitIdentifier("GlassSessionsList.sessions.familyFold")
    }
}
