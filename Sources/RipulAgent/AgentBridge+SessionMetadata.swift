import Foundation

/// What is known about one chat beyond its messages: description, notes,
/// people, storage, and the tools it may use.
extension AgentBridge {
    /// A contributor to a session.
    public struct ContributorEntry: Hashable, Identifiable {
        public let clientId: String
        public let clientType: String
        public let displayName: String?
        public let lastSeenAt: String?
        public var id: String { clientId }
    }

    /// A persistent participant in a session (human or agent). Stamped on
    /// @-submit, default-respondent send, relay peerJoin, and local-user action.
    /// Survives app restart and DO eviction — the canonical "who is in this
    /// chat" list shared by the @-picker and the metadata panel.
    public struct ParticipantEntry: Hashable, Identifiable {
        public let id: String
        public let kind: String
        public let displayName: String?
        public let group: String?
        public let firstSeenAt: String?
        public let lastSeenAt: String?

        public init(
            id: String,
            kind: String,
            displayName: String? = nil,
            group: String? = nil,
            firstSeenAt: String? = nil,
            lastSeenAt: String? = nil
        ) {
            self.id = id
            self.kind = kind
            self.displayName = displayName
            self.group = group
            self.firstSeenAt = firstSeenAt
            self.lastSeenAt = lastSeenAt
        }
    }

    /// Where in the chat a milestone was reached: a message, a moment, or both.
    public struct MilestoneAnchor: Hashable {
        public let correlationId: String?
        /// Epoch milliseconds.
        public let ts: Double
    }

    /// A commit the chat made.
    public struct StoryCommit: Hashable, Identifiable {
        public let sha: String
        public let subject: String
        public let repo: String
        public let timestamp: String?
        public var id: String { sha }
    }

    /// Something the chat achieved, with the commits and deployments that
    /// went into it. The page brackets those (`storyFromMetadata`); nothing
    /// here works them out again.
    public struct StoryMilestone: Hashable, Identifiable {
        public let id: String
        public let title: String
        public let detail: String?
        /// "delivered" or "decided".
        public let kind: String
        public let at: String
        public let anchor: MilestoneAnchor?
        /// Where its stretch of work began: the previous milestone's anchor.
        public let startAnchor: MilestoneAnchor?
        /// A person wrote or changed it.
        public let persons: Bool
        /// "3 commits · 1 iPhone build", or empty.
        public let summary: String
        public let commits: [StoryCommit]
        public let deployments: [DeploymentEntry]

        public var isDecided: Bool { kind == "decided" }
    }

    /// A chat's milestones, newest first, and the work since the last one.
    public struct ChatStory: Hashable {
        public let goal: String?
        public let composerGoal: String?
        public let openSummary: String
        public let milestones: [StoryMilestone]

        public init(goal: String?, composerGoal: String? = nil, openSummary: String, milestones: [StoryMilestone]) {
            self.goal = goal
            self.composerGoal = composerGoal
            self.openSummary = openSummary
            self.milestones = milestones
        }

        public var isEmpty: Bool { goal == nil && composerGoal == nil && openSummary.isEmpty && milestones.isEmpty }
    }

    /// A message in the chat: its correlationId, and its time (epoch ms) when known.
    public struct MessageAnchor: Hashable {
        public let correlationId: String
        public let ts: Double?
    }

    /// A link the chat keeps to hand: an artefact it made, a page it deployed,
    /// or a message someone pinned. The agent keeps links with the `shortcut`
    /// tool; anyone in the chat pins a message from its bubble. A `key` one
    /// also shows in the chat's header lozenge.
    public struct ChatShortcut: Hashable, Identifiable {
        public let id: String
        public let title: String
        /// A link's address. A pinned message has none: its `url` is
        /// `ripul-message:<correlationId>` (`messageAnchor(from:)` reads it back),
        /// so places that only carry a URL can still jump to it.
        public let url: URL
        public let kind: String
        public let key: Bool
        /// A person added or changed it.
        public let persons: Bool
        /// A pinned message: where it is, who wrote it and who pinned it.
        public var anchor: MessageAnchor? = nil
        public var sender: String? = nil
        public var pinnedBy: String? = nil
        public var pinnedById: String? = nil

        public var isArtefact: Bool { kind == "artefact" }
        public var isMessage: Bool { anchor != nil }
        /// The address's host, for a second line under the title.
        public var host: String {
            let host = url.host ?? url.absoluteString
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        /// The second line under the title: a link's host, or who wrote and who pinned a message.
        public var subtitle: String {
            guard isMessage else { return host }
            return [sender, pinnedBy.map { "pinned by \($0)" } ?? "pinned message"].compactMap { $0 }.joined(separator: " · ")
        }
        public var symbol: String { isMessage ? "quote.bubble" : isArtefact ? "square.grid.2x2" : "link" }
    }

    /// The scheme a pinned message's `url` carries.
    static let messageShortcutScheme = "ripul-message"

    /// The message a pinned message's `url` points at, or nil for a link.
    public static func messageAnchor(from url: URL) -> MessageAnchor? {
        guard url.scheme == messageShortcutScheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let id = components.path.removingPercentEncoding ?? components.path
        guard !id.isEmpty else { return nil }
        let ts = components.queryItems?.first(where: { $0.name == "ts" })?.value.flatMap(Double.init)
        return MessageAnchor(correlationId: id, ts: ts)
    }

    /// How many key shortcuts the header shows. The panel shows them all.
    public static let headerShortcutLimit = 3

    /// Full session metadata fetched from the API.
    public struct SessionMetadata {
        public let id: String
        public let description: String?
        public let notes: [NoteEntry]
        public let filesEdited: [FileEditEntry]
        public let deployments: [DeploymentEntry]
        public let contributors: [ContributorEntry]
        public let participants: [ParticipantEntry]
        public let model: String?
        public let modelHistory: [String]
        public let createdAt: String?
        public let updatedAt: String?
        /// Nil when the page is on a build from before milestones.
        public let story: ChatStory?
        /// Key ones first, then the newest first.
        public let shortcuts: [ChatShortcut]
        /// The chat is someone else's (an invitation, or a team's Mac): its
        /// links are the owner's, and a pinned message is unpinned only by
        /// whoever pinned it.
        public var isChatMember = false
        /// The viewer as a participant (`human-<account>`).
        public var viewerId: String?

        /// Whether the viewer may unpin this pinned message.
        public func canUnpin(_ shortcut: ChatShortcut) -> Bool {
            !isChatMember || (viewerId != nil && shortcut.pinnedById == viewerId)
        }

        /// The ones the header lozenge shows.
        public var headerShortcuts: [ChatShortcut] {
            Array(shortcuts.filter(\.key).prefix(AgentBridge.headerShortcutLimit))
        }
    }

    /// Fetch full session metadata from the API for a live session.
    public func getSessionMetadata(sessionId: String) async -> SessionMetadata? {
        let reply = await callPage("__ripulGetSessionMetadata", [sessionId], .ifMissing("{ error: 'not ready' }"))
        guard let raw = reply.dictionary?["metadata"] as? [String: Any] else { return nil }
        var metadata = Self.parseSessionMetadata(raw, story: reply.dictionary?["story"] as? [String: Any])
        metadata.isChatMember = reply.dictionary?["chatRole"] as? String == "member"
        metadata.viewerId = reply.dictionary?["viewerId"] as? String
        return metadata
    }

    /// A message someone replied to and @'d the viewer on: on the viewer's
    /// "For your attention" list in the chat until they clear it.
    /// Docs: chatAttentionList.md.
    public struct ReadingItem: Hashable, Identifiable {
        public let id: String
        /// The message flagged, and its time when the reply carried it.
        public let anchor: MessageAnchor
        public let messageSender: String?
        public let excerpt: String
        /// What the reply said.
        public let note: String?
        public let fromName: String?
        public let createdAt: Date

        /// "Peter Maude flagged this for you".
        public var flaggedBy: String { fromName.map { "\($0) flagged this for you" } ?? "Flagged for you" }
    }

    /// Posted when the page says the viewer's list grew while the chat is open
    /// (`readingList:changed`, from a `session.readingList` frame sent only to
    /// the person flagged). `chatId` is the page's id for the chat.
    public static let readingListChangedNotification = Notification.Name("ripulReadingListChanged")

    /// The viewer's list in a chat, newest first. Nil when the page could not say.
    public func getReadingList(chatId: String) async -> [ReadingItem]? {
        let reply = await callPage("__ripulGetReadingList", [chatId], .ifMissing("{ error: 'not ready' }"))
        guard let raw = reply.dictionary?["items"] as? [[String: Any]] else { return nil }
        return Self.parseReadingItems(raw)
    }

    /// Clear items from the viewer's list (`ids`), or all of them (nil). Answers with what is left.
    public func clearReadingList(chatId: String, ids: [String]?) async -> [ReadingItem]? {
        let reply = await callPage("__ripulClearReadingList", [chatId, ids], .ifMissing("{ error: 'not ready' }"))
        guard let raw = reply.dictionary?["items"] as? [[String: Any]] else { return nil }
        return Self.parseReadingItems(raw)
    }

    static func parseReadingItems(_ raw: [[String: Any]]) -> [ReadingItem] {
        raw.compactMap { item in
            guard let id = item["id"] as? String, let messageId = item["messageId"] as? String,
                  let excerpt = item["excerpt"] as? String else { return nil }
            let created = (item["createdAt"] as? NSNumber)?.doubleValue ?? 0
            return ReadingItem(
                id: id,
                anchor: MessageAnchor(correlationId: messageId, ts: (item["messageTs"] as? NSNumber)?.doubleValue),
                messageSender: item["messageSender"] as? String,
                excerpt: excerpt,
                note: item["note"] as? String,
                fromName: item["fromName"] as? String,
                createdAt: Date(timeIntervalSince1970: created / 1000)
            )
        }
    }

    /// Scroll the chat to a message: a pinned one, or one flagged for the viewer.
    public func scrollToMessage(_ anchor: MessageAnchor) {
        scrollToChatAnchor(correlationId: anchor.correlationId, ts: anchor.ts)
    }

    /// Per-chat storage breakdown — total bytes + top buckets by tool/method.
    /// Surfaces what kinds of action are dominating a chat's persisted size,
    /// for the native session metadata debug panel.
    public struct SessionStorageBucket {
        public let name: String
        public let bytes: Int
        public let count: Int
    }

    public struct SessionStorageBreakdown {
        public let totalBytes: Int
        public let count: Int
        public let buckets: [SessionStorageBucket]
    }

    public func getSessionStorageBreakdown(sessionId: String, maxBuckets: Int = 8) async -> SessionStorageBreakdown? {
        let reply = await callPage("__ripulGetSessionStorageBreakdown", [sessionId, maxBuckets], .ifMissing("{ error: 'not ready' }"))
        guard let raw = reply.dictionary?["breakdown"] as? [String: Any] else { return nil }
        let totalBytes = (raw["totalBytes"] as? Int) ?? 0
        let count = (raw["count"] as? Int) ?? 0
        let bucketsRaw = (raw["buckets"] as? [[String: Any]]) ?? []
        let buckets: [SessionStorageBucket] = bucketsRaw.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            return SessionStorageBucket(
                name: name,
                bytes: (entry["bytes"] as? Int) ?? 0,
                count: (entry["count"] as? Int) ?? 0
            )
        }
        return SessionStorageBreakdown(totalBytes: totalBytes, count: count, buckets: buckets)
    }

    /// A message a person typed into the chat — an anchor the metadata panel
    /// jumps back to. Keyed by `correlationId`, which stays put as older
    /// history pages in above it.
    public struct HumanChatAnchor: Identifiable, Hashable {
        public let correlationId: String
        public let text: String
        public let timestamp: Date?
        public let senderDisplayName: String?
        public var id: String { correlationId }
    }

    /// The messages people typed into a loaded chat, oldest first. Calls
    /// `window.__ripulGetHumanChatAnchors`; nil when the page couldn't answer.
    public func getHumanChatAnchors(sessionId: String) async -> [HumanChatAnchor]? {
        let reply = await callPage("__ripulGetHumanChatAnchors", [sessionId], .ifMissing("{ error: 'not ready' }"))
        guard let raw = reply.dictionary?["messages"] as? [[String: Any]] else { return nil }
        return raw.compactMap { m in
            guard let correlationId = m["correlationId"] as? String,
                  let text = m["text"] as? String else { return nil }
            let ms = (m["timestamp"] as? NSNumber)?.doubleValue
            return HumanChatAnchor(
                correlationId: correlationId,
                text: text,
                timestamp: ms.map { Date(timeIntervalSince1970: $0 / 1000) },
                senderDisplayName: m["senderDisplayName"] as? String
            )
        }
    }

    /// Scroll the chat to one message by its correlationId. A message the
    /// scroller hasn't loaded is a no-op: there is no time to page back to.
    public func scrollToChatMessage(correlationId: String) {
        Task { _ = await callPage("__ripulScrollToChatMessage", [correlationId]) }
    }

    /// Scroll the chat to an anchor: a message, a moment (epoch milliseconds),
    /// or both. Given a time, the page loads older history until the anchor is
    /// there, and says so in the chat if that part is gone.
    public func scrollToChatAnchor(correlationId: String?, ts: Double?) {
        let id: Any = correlationId ?? NSNull()
        let time: Any = ts ?? NSNull()
        Task { _ = await callPage("__ripulScrollToChatMessage", [id, time]) }
    }

    /// Scroll the chat to where a milestone was reached.
    public func scrollToChatAnchor(_ anchor: MilestoneAnchor) {
        scrollToChatAnchor(correlationId: anchor.correlationId, ts: anchor.ts)
    }

    /// A single tool entry returned by `__ripulGetResolvedToolsForSession`.
    public struct CliToolEntry {
        public let name: String
        public let description: String
    }

    /// Fetch the resolved CLI tool list for a session — calls the same JS callable
    /// the MCP bridge uses on every `tools/list`, so this reflects exactly what
    /// Claude CLI sees (after interceptor chain, progressive discovery, etc.).
    public func getResolvedCliTools(sessionId: String) async -> [CliToolEntry]? {
        let reply = await callPage("__ripulGetResolvedToolsForSession", [sessionId], .ifMissing("{ error: 'not ready' }"))
        guard let toolsRaw = reply.dictionary?["tools"] as? [[String: Any]] else { return nil }
        return toolsRaw.compactMap { t in
            guard let name = t["name"] as? String else { return nil }
            return CliToolEntry(name: name, description: (t["description"] as? String) ?? "")
        }
    }

    /// A progressive-discovery tool category (a `tool_collections` row) with the
    /// chat's on/off state. Off = the category's tools AND its collapsed stub are
    /// hidden from that chat's tool list (web: `ChatTabDescriptor.disabledToolCategories`).
    public struct ChatToolCategory: Identifiable, Equatable {
        public var id: String { name }
        public let name: String
        public let label: String
        public let description: String
        /// Tools the category currently gathers from what this webview would offer
        /// the chat — on the phone an approximation of the Mac host's view.
        public let toolCount: Int
        public var enabled: Bool
    }

    /// List the tool categories the chat's tools/list is built from, with their
    /// per-chat switch state. Calls `window.__ripulGetChatToolCategories`.
    public func getChatToolCategories(chatId: String) async -> [ChatToolCategory]? {
        let reply = await callPage("__ripulGetChatToolCategories", [chatId], .ifMissing("{ error: 'not ready' }"))
        guard let raw = reply.dictionary?["categories"] as? [[String: Any]] else { return nil }
        return raw.compactMap { c in
            guard let name = c["name"] as? String else { return nil }
            return ChatToolCategory(
                name: name,
                label: (c["label"] as? String) ?? name,
                description: (c["description"] as? String) ?? "",
                toolCount: (c["toolCount"] as? Int) ?? 0,
                enabled: (c["enabled"] as? Bool) ?? true
            )
        }
    }

    /// Persist the categories hidden from a chat. Whole-list write: pass every
    /// disabled name; an empty list turns everything back on. The CLI bridge
    /// re-lists tools each turn, so the change lands without a restart.
    @discardableResult
    public func setChatToolCategories(chatId: String, disabled: [String]) async -> Bool {
        let reply = await callPage("__ripulSetChatToolCategories", [chatId, ["disabled": disabled]],
                                   .ifMissing("{ success: false, error: 'not ready' }"))
        guard reply.failure() == nil else { return false }
        let ok = (reply.dictionary?["success"] as? Bool) ?? false
        handleConsoleLog("LOG: [ToolCategories] native.setChatToolCategories chatId=\(chatId.suffix(12)) disabled=\(disabled) ok=\(ok)")
        return ok
    }

    /// The chat's full tool inventory for the tool browser — see
    /// `RipulToolInventory`. Calls `window.__ripulGetChatToolInventory`, which
    /// runs one tools/list resolution, so treat it like a probe, not a poll.
    public func getChatToolInventory(chatId: String) async -> RipulToolInventory? {
        let reply = await callPage("__ripulGetChatToolInventory", [chatId], .ifMissing("{ error: 'not ready' }"))
        guard let dict = reply.dictionary else { return nil }
        if let err = dict["error"] as? String, dict["categories"] == nil {
            NSLog("[AgentBridge] getChatToolInventory: %@", err)
            return nil
        }
        return RipulToolInventory.parse(dict)
    }

    /// Patch session metadata (description, notes, etc.) via the API.
    public func patchSessionMetadata(sessionId: String, patch: [String: Any]) async -> SessionMetadata? {
        let reply = await callPage("__ripulPatchSessionMetadata", [sessionId, patch], .ifMissing("{ error: 'not ready' }"))
        guard let raw = reply.dictionary?["metadata"] as? [String: Any] else { return nil }
        return Self.parseSessionMetadata(raw, story: reply.dictionary?["story"] as? [String: Any])
    }

    private static func parseAnchor(_ raw: Any?) -> MilestoneAnchor? {
        guard let dict = raw as? [String: Any], let ts = (dict["ts"] as? NSNumber)?.doubleValue else { return nil }
        return MilestoneAnchor(correlationId: dict["correlationId"] as? String, ts: ts)
    }

    private static func parseDeployments(_ raw: Any?) -> [DeploymentEntry] {
        (raw as? [[String: Any]])?.compactMap { entry -> DeploymentEntry? in
            guard let target = entry["target"] as? String else { return nil }
            return DeploymentEntry(
                id: entry["id"] as? String ?? UUID().uuidString,
                target: target,
                timestamp: entry["timestamp"] as? String
            )
        } ?? []
    }

    /// Parse the story the page bracketed (`storyFromMetadata`).
    static func parseChatStory(_ raw: [String: Any]?) -> ChatStory? {
        guard let raw else { return nil }
        let milestones = (raw["milestones"] as? [[String: Any]])?.compactMap { entry -> StoryMilestone? in
            guard let id = entry["id"] as? String, let title = entry["title"] as? String else { return nil }
            let commits = (entry["commits"] as? [[String: Any]])?.compactMap { commit -> StoryCommit? in
                guard let sha = commit["sha"] as? String else { return nil }
                return StoryCommit(
                    sha: sha,
                    subject: commit["subject"] as? String ?? "",
                    repo: commit["repo"] as? String ?? "",
                    timestamp: commit["timestamp"] as? String
                )
            } ?? []
            return StoryMilestone(
                id: id,
                title: title,
                detail: entry["detail"] as? String,
                kind: entry["kind"] as? String ?? "delivered",
                at: entry["at"] as? String ?? "",
                anchor: parseAnchor(entry["anchor"]),
                startAnchor: parseAnchor(entry["startAnchor"]),
                persons: entry["persons"] as? Bool ?? false,
                summary: entry["summary"] as? String ?? "",
                commits: commits,
                deployments: parseDeployments(entry["deployments"])
            )
        } ?? []
        let goal = (raw["goal"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let composerGoal = (raw["composerGoal"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let open = raw["open"] as? [String: Any]
        return ChatStory(goal: goal, composerGoal: composerGoal, openSummary: open?["summary"] as? String ?? "", milestones: milestones)
    }

    /// Parse the chat's shortcuts, key ones first, then the newest first:
    /// the order `shortcutsInOrder` gives on the page.
    static func parseShortcuts(_ raw: Any?) -> [ChatShortcut] {
        let parsed = (raw as? [[String: Any]] ?? []).compactMap { entry -> ChatShortcut? in
            if entry["kind"] as? String == "message" { return parseMessageShortcut(entry) }
            guard let id = entry["id"] as? String, let title = entry["title"] as? String,
                  let address = entry["url"] as? String, let url = URL(string: address),
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
            return ChatShortcut(
                id: id,
                title: title,
                url: url,
                kind: entry["kind"] as? String ?? "url",
                key: entry["key"] as? Bool ?? false,
                persons: entry["author"] as? String == "person" || entry["editedByPerson"] as? Bool == true
            )
        }
        return parsed.reversed().filter(\.key) + parsed.reversed().filter { !$0.key }
    }

    /// A pinned message: an anchor in place of an address.
    private static func parseMessageShortcut(_ entry: [String: Any]) -> ChatShortcut? {
        guard let id = entry["id"] as? String, let title = entry["title"] as? String,
              let anchor = entry["anchor"] as? [String: Any],
              let correlationId = anchor["correlationId"] as? String, !correlationId.isEmpty else { return nil }
        let ts = (anchor["ts"] as? NSNumber)?.doubleValue
        var components = URLComponents()
        components.scheme = messageShortcutScheme
        components.path = correlationId
        if let ts { components.queryItems = [URLQueryItem(name: "ts", value: String(Int64(ts)))] }
        guard let url = components.url else { return nil }
        return ChatShortcut(
            id: id,
            title: title,
            url: url,
            kind: "message",
            key: entry["key"] as? Bool ?? false,
            persons: entry["author"] as? String != "agent" || entry["editedByPerson"] as? Bool == true,
            anchor: MessageAnchor(correlationId: correlationId, ts: ts),
            sender: entry["sender"] as? String,
            pinnedBy: entry["pinnedBy"] as? String,
            pinnedById: entry["pinnedById"] as? String
        )
    }

    /// Parse a raw JSON dictionary into a SessionMetadata.
    private static func parseSessionMetadata(_ raw: [String: Any], story: [String: Any]? = nil) -> SessionMetadata {
        let filesEdited = (raw["filesEdited"] as? [[String: Any]])?.compactMap { entry -> FileEditEntry? in
            guard let name = entry["fileName"] as? String else { return nil }
            return FileEditEntry(
                fileName: name,
                filePath: entry["filePath"] as? String,
                editCount: (entry["editCount"] as? Int) ?? 1,
                lastSeenAt: entry["lastSeenAt"] as? String
            )
        } ?? []

        let notes = (raw["notes"] as? [[String: Any]])?.compactMap { entry -> NoteEntry? in
            guard let text = entry["text"] as? String else { return nil }
            return NoteEntry(
                id: entry["id"] as? String ?? UUID().uuidString,
                text: text,
                createdAt: entry["createdAt"] as? String,
                timestamp: entry["timestamp"] as? String
            )
        } ?? []

        let deployments = parseDeployments(raw["deployments"])

        let contributors = (raw["contributors"] as? [[String: Any]])?.compactMap { entry -> ContributorEntry? in
            guard let clientId = entry["clientId"] as? String,
                  let clientType = entry["clientType"] as? String else { return nil }
            return ContributorEntry(
                clientId: clientId,
                clientType: clientType,
                displayName: entry["displayName"] as? String,
                lastSeenAt: entry["lastSeenAt"] as? String
            )
        } ?? []

        let participants = (raw["participants"] as? [[String: Any]])?.compactMap { entry -> ParticipantEntry? in
            guard let id = entry["id"] as? String,
                  let kind = entry["kind"] as? String else { return nil }
            return ParticipantEntry(
                id: id,
                kind: kind,
                displayName: entry["displayName"] as? String,
                group: entry["group"] as? String,
                firstSeenAt: entry["firstSeenAt"] as? String,
                lastSeenAt: entry["lastSeenAt"] as? String
            )
        } ?? []

        return SessionMetadata(
            id: raw["id"] as? String ?? "",
            description: raw["description"] as? String,
            notes: notes,
            filesEdited: filesEdited,
            deployments: deployments,
            contributors: contributors,
            participants: participants,
            model: raw["model"] as? String,
            modelHistory: raw["modelHistory"] as? [String] ?? [],
            createdAt: raw["createdAt"] as? String,
            updatedAt: raw["updatedAt"] as? String,
            story: parseChatStory(story),
            shortcuts: parseShortcuts(raw["shortcuts"])
        )
    }
}
