import SwiftUI

/// Chats kept under another chat: the ones an agent started, under the chat
/// that started them, and the ones a person put there by hand.
///
/// A person's own choice comes first. It can put any chat under any other (a
/// chat used as a container for a piece of work), and it can take a started
/// chat out from under its starter.
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
        /// Closed: the chats under it, in family order. Their rows are not
        /// there, so the head's row says for them what theirs would: that one
        /// is mid-turn, and when one of them was last active.
        let putAway: [UnifiedSession]
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
    /// By the id of each chat that has started others, at any depth: every
    /// chat under it, in family order. What goes with it when it is archived.
    let under: [String: [UnifiedSession]]
    /// By the id of each chat that sits under another: that chat.
    let above: [String: UnifiedSession]
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
    ///   - mustShow: A started chat that may not be folded away. Called once a started chat.
    ///   - placedUnder: Where the person has put a chat: the key of the chat it is under,
    ///     "" for by itself, nil when they have made no choice. Called once a row.
    static func arrange(
        _ sessions: [UnifiedSession],
        open: Set<String> = [],
        closed: Set<String> = [],
        folds foldsFamilies: Bool = true,
        isPinned: (UnifiedSession) -> Bool = { _ in false },
        recency: (UnifiedSession) -> Int,
        mustShow: (UnifiedSession) -> Bool = { _ in false },
        heldOrder: [String]? = nil,
        placedUnder: (UnifiedSession) -> String? = { _ in nil }
    ) -> SessionFamilies {
        let pinned = sessions.map(isPinned)
        let ownRecency = sessions.map(recency)

        // Who is under whom. Only a list with a started or a placed chat pays for the index.
        var parent = [Int?](repeating: nil, count: sessions.count)
        let chosen = sessions.map(placedUnder)
        if chosen.contains(where: { $0 != nil }) || sessions.contains(where: { $0.startedBy != nil }) {
            // A chat moved between Macs leaves its id on both, so an id can name several rows.
            var rowsByKey: [String: [Int]] = [:]
            for (index, session) in sessions.enumerated() {
                for key in [session.id, session.metadataKey] + session.matchKeys where rowsByKey[key]?.last != index {
                    rowsByKey[key, default: []].append(index)
                }
            }
            for (index, session) in sessions.enumerated() {
                // The person's choice comes first, and is theirs across Macs:
                // a chat they named, or by itself. A chat they named that is
                // not in the list leaves this one by itself too.
                if let under = chosen[index] {
                    guard !under.isEmpty else { continue }
                    parent[index] = [under, UnifiedSession.canonicalKey(under)].lazy
                        .compactMap { rowsByKey[$0]?.first { $0 != index } }.first
                    continue
                }
                guard let starter = session.startedBy else { continue }
                // An id means something on the Mac that issued it and nothing on
                // another: the starter is looked for on this chat's own Mac, or,
                // when another Mac's agent started it, on the Mac its id names.
                var wanted: [(key: String, machineId: String?)] = []
                if let row = starter.sessionId { wanted.append((row, session.machineId)) }
                if let other = SessionFamilies.onAnotherMac(starter.agentId) {
                    wanted.append((other.id, other.machineId))
                } else {
                    wanted.append((starter.agentId, session.machineId))
                }
                parent[index] = wanted.lazy.compactMap { want in
                    rowsByKey[want.key]?.first { found in
                        guard found != index else { return false }
                        // A row with no Mac, or a chat with none, cannot be told apart by one.
                        guard let here = want.machineId, let there = sessions[found].machineId else { return true }
                        return here == there
                    }
                }.first
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

        // A started chat stays in sight while it must be shown, or a chat under
        // it must: folding it away would take that one with it.
        var staysShown = [Bool](repeating: false, count: sessions.count)
        @discardableResult
        func mark(_ index: Int) -> Bool {
            var stays = mustShow(sessions[index])
            for child in children[index] where mark(child) { stays = true }
            staysShown[index] = stays
            return stays
        }
        for head in heads { for child in children[head] { mark(child) } }

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
        // Compare siblings only, so freezing order never separates a family.
        let heldRanks = Dictionary((heldOrder ?? []).enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        func heldComparison(_ a: Int, _ b: Int) -> Bool? {
            guard heldOrder != nil else { return nil }
            let ra = heldRanks[sessions[a].id] ?? Int.max
            let rb = heldRanks[sessions[b].id] ?? Int.max
            return ra == rb ? nil : ra < rb
        }
        heads.sort { a, b in
            if let held = heldComparison(a, b) { return held }
            if pinned[a] != pinned[b] { return pinned[a] }
            if recencyOfFamily[a] != recencyOfFamily[b] { return recencyOfFamily[a] > recencyOfFamily[b] }
            return lastUsedOfFamily[a] > lastUsedOfFamily[b]
        }

        var all: [UnifiedSession] = []
        var visible: [UnifiedSession] = []
        var depth: [String: Int] = [:]
        var folds: [String: Fold] = [:]
        var headsById: [String: Head] = [:]
        var under: [String: [UnifiedSession]] = [:]
        var above: [String: UnifiedSession] = [:]
        var sharesFolder: Set<String> = []
        var sharesBranch: Set<String> = []
        all.reserveCapacity(sessions.count)
        visible.reserveCapacity(sessions.count)

        /// Places a chat and everything under it. Returns how many chats are under it.
        @discardableResult
        func place(_ index: Int, level: Int, shown: Bool) -> Int {
            let session = sessions[index]
            all.append(session)
            let firstUnder = all.count
            if shown { visible.append(session) }
            if level > 0 { depth[session.id] = min(level, deepest) }

            let started = children[index].sorted { a, b in
                if let held = heldComparison(a, b) { return held }
                return recencyOfFamily[a] != recencyOfFamily[b] ? recencyOfFamily[a] > recencyOfFamily[b] : lastUsedOfFamily[a] > lastUsedOfFamily[b]
            }
            guard !started.isEmpty else { return 0 }

            // Put away by the person. A search still shows every match.
            let isClosed = level == 0 && foldsFamilies && closed.contains(session.id)

            // Only the head of a family folds: one control a family, after its last row.
            var folded: Set<Int> = []
            var fold: Fold?
            if level == 0 && foldsFamilies && !isClosed {
                let quiet = started.filter { !staysShown[$0] }
                let beyond = Array(quiet.dropFirst(quietShown))
                // A control costs a row: it has to hide at least two to earn it.
                if beyond.count >= 2 {
                    let isOpen = open.contains(session.id)
                    if !isOpen { folded = Set(beyond) }
                    fold = Fold(parentId: session.id, count: beyond.count, isOpen: isOpen)
                }
            }
            var count = 0
            for child in started {
                above[sessions[child].id] = session
                if sessions[child].projectName == session.projectName {
                    sharesFolder.insert(sessions[child].id)
                    if sessions[child].gitBranch == session.gitBranch { sharesBranch.insert(sessions[child].id) }
                }
                count += 1 + place(child, level: level + 1, shown: shown && !isClosed && !folded.contains(child))
            }
            // Everything placed since this chat is under it.
            let chatsUnder = Array(all[firstUnder...])
            under[session.id] = chatsUnder
            if let fold, shown, let last = visible.last { folds[last.id] = fold }
            if level == 0 {
                headsById[session.id] = Head(started: count, isClosed: isClosed,
                                             needsLooking: isClosed && started.contains { staysShown[$0] },
                                             putAway: isClosed ? chatsUnder : [])
            }
            return count
        }
        for head in heads { place(head, level: 0, shown: true) }

        return SessionFamilies(all: all, visible: visible, depth: depth, folds: folds, heads: headsById, under: under,
                               above: above, sharesFolder: sharesFolder, sharesBranch: sharesBranch)
    }
}

extension SessionFamilies {
    /// Whether one chat may be put under another: not under itself, and not
    /// under a chat that is under it, which would make a ring of them.
    func canPlace(_ id: String, under target: String) -> Bool {
        id != target && !(under[id]?.contains { $0.id == target } ?? false)
    }

    /// What a session row carries when it is dragged. A prefix of our own, so
    /// text dragged in from elsewhere is not taken for a chat.
    static func dragPayload(for session: UnifiedSession) -> String { dragPrefix + session.id }

    /// The id of the chat a drag carries, or nil for anything else.
    static func draggedSessionId(_ payload: String) -> String? {
        payload.hasPrefix(dragPrefix) ? String(payload.dropFirst(dragPrefix.count)) : nil
    }

    private static let dragPrefix = "ripul-session:"
}

extension SessionListStore {
    /// Whether a chat is mid-turn, as far as this device can tell. One open
    /// here as a tab has a live phase. One that is not has only what its own
    /// Mac said when its list was last read, and a chat an agent has just
    /// started is nearly always one nobody has opened here.
    func isRunning(_ session: UnifiedSession) -> Bool {
        guard let chatId = session.ripulSession?.sourceChatId else { return session.runningOnHost }
        return turnPhase(for: chatId) == .running
    }

    /// Mid-turn, or stopped to ask its person something: what a list must not fold out of sight.
    func isWorkingOrAsking(_ session: UnifiedSession) -> Bool {
        guard let chatId = session.ripulSession?.sourceChatId else { return session.runningOnHost }
        return isWorkingOrAsking(chatId)
    }
}

extension SessionFamilies {
    /// An agent on another Mac, as the Mac that was told of it names it:
    /// `machine-608A…/cli_<uuid>` (the web app's `remoteAgents.ts`). Chat ids
    /// and machine ids hold no slash, so no id of the Mac itself has this form.
    static func onAnotherMac(_ id: String) -> (machineId: String, id: String)? {
        let prefix = "machine-"
        guard id.hasPrefix(prefix), let cut = id.firstIndex(of: "/") else { return nil }
        let machineId = id[..<cut], local = id[id.index(after: cut)...]
        guard machineId.count > prefix.count, !local.isEmpty else { return nil }
        return (String(machineId), String(local))
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
        .accessibilityLabel(fold.isOpen ? "Show fewer chats under it" : "Show \(fold.count) more chats under it")
        .uiKitIdentifier("GlassSessionsList.sessions.familyFold")
    }
}
