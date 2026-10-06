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
    }

    /// Fetch full session metadata from the API for a live session.
    public func getSessionMetadata(sessionId: String) async -> SessionMetadata? {
        let reply = await callPage("__ripulGetSessionMetadata", [sessionId], .ifMissing("{ error: 'not ready' }"))
        guard let raw = reply.dictionary?["metadata"] as? [String: Any] else { return nil }
        return Self.parseSessionMetadata(raw)
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
        return Self.parseSessionMetadata(raw)
    }

    /// Parse a raw JSON dictionary into a SessionMetadata.
    private static func parseSessionMetadata(_ raw: [String: Any]) -> SessionMetadata {
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

        let deployments = (raw["deployments"] as? [[String: Any]])?.compactMap { entry -> DeploymentEntry? in
            guard let target = entry["target"] as? String else { return nil }
            return DeploymentEntry(
                id: entry["id"] as? String ?? UUID().uuidString,
                target: target,
                timestamp: entry["timestamp"] as? String
            )
        } ?? []

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
            updatedAt: raw["updatedAt"] as? String
        )
    }
}
