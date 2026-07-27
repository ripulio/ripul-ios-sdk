import Foundation

// MARK: - UnifiedSession

/// A single session entry merging the JSONL scanner (ground truth) with any
/// matching Ripul web-app tab (decoration / fast-focus path).
public struct UnifiedSession: Identifiable, Codable {
    public let id: String
    public let title: String
    /// Last time any message was written in any app — the canonical sort key.
    public let lastUsed: Date
    public let gitBranch: String?
    public let messageCount: Int?
    public let projectName: String?
    /// Absolute working directory of the session, when known — used to re-root
    /// the Folders panel to the selected project.
    public let projectPath: String?
    public let provider: String?
    public let providerLabel: String?
    /// Model of the most recent assistant message in the session JSONL
    /// (e.g. "claude-opus-4-6"), resolved by the host scanner. Session rows
    /// show this in place of the harness label — the leading icon already
    /// identifies the harness, so the text slot carries the model in use.
    public let model: String?
    /// The machine this session lives on (for openRemoteSession routing).
    public let machineName: String?
    /// Stable machine identifier — survives display-name renames and is the only
    /// safe key for routing archive / delete / open requests to the owning host.
    public let machineId: String?
    /// All keys this session can be matched by (id, sourceChatId, hostChatId, etc.).
    /// Persisted so that rematchLocalSessions() can find matches from cache.
    public let matchKeys: [String]
    /// Non-nil when this session is already open as a Ripul web-app tab.
    /// Excluded from Codable — re-matched on each rebuild.
    public let ripulSession: ChatSession?
    /// Persisted snapshot of whether this session was open in Ripul at cache time.
    /// Allows green dots to show immediately from cache before the web view loads.
    public let cachedIsOpen: Bool
    /// User-authored labels, shown as lozenges after the repo/branch on the
    /// subtitle line. Injected at build time from the bulk `getSessionTags()` map.
    public let tags: [String]
    /// Canonical key for reading/writing this session's metadata blob (tags,
    /// notes, …) — the bare sourceChatId. Used when the user edits tags.
    public let metadataKey: String

    public var isOpenInRipul: Bool { ripulSession != nil || cachedIsOpen }

    /// Strip the `cli_` prefix so local (`cli_<uuid>`) and remote (`<uuid>`)
    /// forms of the same session resolve to one canonical key.
    public static func canonicalKey(_ key: String) -> String {
        key.hasPrefix("cli_") ? String(key.dropFirst(4)) : key
    }

    // MARK: - Codable (exclude ripulSession)

    enum CodingKeys: String, CodingKey {
        case id, title, lastUsed, gitBranch, messageCount, projectName, projectPath
        case provider, providerLabel, model, machineName, machineId, matchKeys, cachedIsOpen
        case tags, metadataKey
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        lastUsed = try c.decode(Date.self, forKey: .lastUsed)
        gitBranch = try c.decodeIfPresent(String.self, forKey: .gitBranch)
        messageCount = try c.decodeIfPresent(Int.self, forKey: .messageCount)
        projectName = try c.decodeIfPresent(String.self, forKey: .projectName)
        projectPath = try c.decodeIfPresent(String.self, forKey: .projectPath)
        provider = try c.decodeIfPresent(String.self, forKey: .provider)
        providerLabel = try c.decodeIfPresent(String.self, forKey: .providerLabel)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        machineName = try c.decodeIfPresent(String.self, forKey: .machineName)
        machineId = try c.decodeIfPresent(String.self, forKey: .machineId)
        matchKeys = try c.decodeIfPresent([String].self, forKey: .matchKeys) ?? []
        cachedIsOpen = try c.decodeIfPresent(Bool.self, forKey: .cachedIsOpen) ?? false
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        metadataKey = try c.decodeIfPresent(String.self, forKey: .metadataKey) ?? id
        ripulSession = nil
    }

    public init(
        id: String, title: String, lastUsed: Date, gitBranch: String?,
        messageCount: Int?, projectName: String?, projectPath: String? = nil,
        provider: String?,
        providerLabel: String?, model: String? = nil, machineName: String?, machineId: String? = nil,
        matchKeys: [String] = [], tags: [String] = [], metadataKey: String? = nil,
        ripulSession: ChatSession?
    ) {
        self.id = id; self.title = title; self.lastUsed = lastUsed
        self.gitBranch = gitBranch; self.messageCount = messageCount
        self.projectName = projectName; self.projectPath = projectPath
        self.provider = provider
        self.providerLabel = providerLabel; self.model = model; self.machineName = machineName
        self.machineId = machineId
        self.matchKeys = matchKeys; self.ripulSession = ripulSession
        self.cachedIsOpen = ripulSession != nil
        self.tags = tags
        self.metadataKey = metadataKey ?? id
    }

    // MARK: - Cache

    private static let cacheKey = "ripulUnifiedSessionsCache"

    public static func loadCached(cache: RipulSessionCache) -> [UnifiedSession] {
        guard let data = cache.data(forKey: cacheKey) else { return [] }
        return (try? JSONDecoder().decode([UnifiedSession].self, from: data)) ?? []
    }

    public static func saveToCache(_ sessions: [UnifiedSession], cache: RipulSessionCache) {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        cache.set(data, forKey: cacheKey)
    }

    /// Resolved provider definition from shared/providers.json.
    public var resolvedProvider: ProviderDef? {
        ProviderConstants.resolve(provider: provider, providerLabel: providerLabel)
    }

    /// Whether this session belongs to any CLI provider (Claude Code, Codex, Antigravity, etc.).
    public var isCliSession: Bool { resolvedProvider?.isCli == true }

    /// Human-readable model name for the session row, e.g. "Opus 4.6" from
    /// "claude-opus-4-6". Non-Claude ids (e.g. a Kimi alias) pass through
    /// unchanged. nil when the host couldn't resolve a model.
    public var modelDisplayName: String? {
        guard let model, !model.isEmpty else { return nil }
        return UnifiedSession.prettifyModelId(model)
    }

    /// "claude-opus-4-6" → "Opus 4.6", "claude-haiku-4-5-20251001" → "Haiku 4.5",
    /// "claude-sonnet-5" → "Sonnet 5". Anything not matching the Claude
    /// family-version shape (custom aliases, other providers) is returned raw.
    public static func prettifyModelId(_ raw: String) -> String {
        guard raw.hasPrefix("claude-") else { return raw }
        let tokens = String(raw.dropFirst("claude-".count)).split(separator: "-").map(String.init)
        guard let family = tokens.first, family.allSatisfy({ $0.isLetter }) else { return raw }
        // Keep leading short numeric tokens as the version; an 8-digit token
        // is a date stamp and stops the run (never rendered).
        let versionTokens = tokens.dropFirst().prefix(while: { $0.allSatisfy(\.isNumber) && $0.count <= 2 })
        let version = versionTokens.joined(separator: ".")
        return version.isEmpty ? family.capitalized : "\(family.capitalized) \(version)"
    }

    /// Merge JSONL-sourced remote sessions with live Ripul tab state.
    /// JSONL entries are primary; Ripul tabs that have no JSONL counterpart
    /// (pure agent sessions) are appended at the end.
    ///
    /// - Parameter machineNames: Maps remote session ID → machine display name,
    ///   so each session is tagged with the machine it actually lives on.
    public static func build(
        from remote: [RemoteSessionInfo],
        localSessions: [ChatSession],
        machineNames: [String: String],
        recentlyClosedLocalIds: Set<String> = [],
        tagsByKey: [String: [String]] = [:]
    ) -> [UnifiedSession] {
        // Resolve a session's tags by trying each of its keys (and the
        // cli_-stripped form) against the bulk map — tolerates local/remote
        // key-form differences for the same session.
        func resolveTags(_ keys: [String]) -> [String] {
            for key in keys {
                if let t = tagsByKey[key], !t.isEmpty { return t }
                let canon = canonicalKey(key)
                if canon != key, let t = tagsByKey[canon], !t.isEmpty { return t }
            }
            return []
        }

        // Build lookup: various ID forms → ChatSession.
        //
        // Tabs opened on this device via openRemoteSession have opaque local IDs
        // (e.g. "remote-open_<ts>_<rand>") that do not match any JSONL session key.
        // The only link is the pairing's hostChatId ("cli_<UUID>"), so we also key
        // on that (and its stripped form) to dedup against remote rows whose id is
        // "claude-cli:<UUID>" (sourceChatId = bare UUID).
        var localById: [String: ChatSession] = [:]
        for s in localSessions {
            localById[s.id] = s
            localById[s.sourceChatId] = s
            let stripped = s.sourceChatId.hasPrefix("cli_")
                ? String(s.sourceChatId.dropFirst(4))
                : s.sourceChatId
            localById[stripped] = s
            if let host = s.hostChatId {
                localById[host] = s
                if host.hasPrefix("cli_") {
                    localById[String(host.dropFirst(4))] = s
                }
            }
        }

        var result: [UnifiedSession] = []
        var coveredLocalIds = Set<String>()

        for r in remote {
            // Match priority: remote id, remote sourceChatId, then the host-provided
            // hostChatId (set by the Mac when it collapses a JSONL row into a Ripul tab).
            let ripulMatch = localById[r.id]
                ?? localById[r.sourceChatId]
                ?? (r.hostChatId.flatMap { localById[$0] })
            if let m = ripulMatch {
                coveredLocalIds.insert(m.id)
                coveredLocalIds.insert(m.sourceChatId)
                // Cover ALL local sessions reachable via any of the remote row's keys.
                // The same underlying session may exist as both a chat_* tab (from pairing)
                // and a remote-open_* tab (from openRemoteSession). Without this, only one
                // gets covered and the other appears as an orphan duplicate.
                for key in [r.id, r.sourceChatId, r.hostChatId].compactMap({ $0 }) {
                    if let alt = localById[key] {
                        coveredLocalIds.insert(alt.id)
                        coveredLocalIds.insert(alt.sourceChatId)
                    }
                }
            }
            let rowKeys = [r.id, r.sourceChatId, r.hostChatId].compactMap({ $0 })
            result.append(UnifiedSession(
                id: r.id,
                title: r.displayName,
                lastUsed: r.lastModified ?? r.createdAt,
                gitBranch: r.gitBranch,
                messageCount: r.messageCount,
                projectName: r.projectName,
                projectPath: r.cwd,
                provider: r.provider ?? ripulMatch?.provider,
                providerLabel: r.providerLabel ?? ripulMatch?.providerLabel,
                model: r.model,
                machineName: machineNames[r.id] ?? machineNames[r.sourceChatId],
                machineId: r.machineId,
                matchKeys: rowKeys,
                tags: resolveTags(rowKeys),
                metadataKey: canonicalKey(r.sourceChatId),
                ripulSession: ripulMatch
            ))
        }

        // Append Ripul-only sessions (non-CLI agents with no JSONL file).
        // Skip locals we just archived/closed — closeSession returns before the
        // web app removes the tab, so without this filter a flaky archive-all
        // resurrects the row as an "orphan local" with a stale green dot.
        for s in localSessions where !coveredLocalIds.contains(s.id)
            && !recentlyClosedLocalIds.contains(s.id) {
            result.append(UnifiedSession(
                id: s.id,
                title: s.displayName,
                lastUsed: s.createdAt,
                gitBranch: nil,
                messageCount: nil,
                projectName: nil,
                projectPath: nil,
                provider: s.provider,
                providerLabel: s.providerLabel,
                machineName: s.remoteMachineName,
                machineId: nil,
                tags: resolveTags([s.id, s.sourceChatId]),
                metadataKey: canonicalKey(s.sourceChatId),
                ripulSession: s
            ))
        }

        NSLog("[UnifiedDedup] built %d rows (%d remote + %d orphan local) from %d local keys",
              result.count, remote.count, result.count - remote.count, localById.count)
        return result.sorted { $0.lastUsed > $1.lastUsed }
    }
}

// MARK: - Equatable (display-relevant fields only)

extension UnifiedSession: Equatable {
    public static func == (lhs: UnifiedSession, rhs: UnifiedSession) -> Bool {
        lhs.id == rhs.id &&
        lhs.title == rhs.title &&
        lhs.lastUsed == rhs.lastUsed &&
        lhs.machineName == rhs.machineName &&
        lhs.provider == rhs.provider &&
        lhs.providerLabel == rhs.providerLabel &&
        lhs.model == rhs.model &&
        lhs.messageCount == rhs.messageCount &&
        lhs.projectName == rhs.projectName &&
        lhs.gitBranch == rhs.gitBranch &&
        lhs.tags == rhs.tags &&
        lhs.ripulSession?.id == rhs.ripulSession?.id
    }
}

// MARK: - Remote Session Scan

/// Fans out over online, enabled machines and fetches each one's sessions via the
/// relay bridge (`listRemoteSessions`) — the same primitive the iPhone's
/// SessionManager uses. Pure and side-effect-free: returns the flattened sessions
/// plus an id→machineName map, ready to hand straight to `UnifiedSession.build(...)`.
///
/// Shared so the Mac's Agents list and the iPhone run ONE scan path, not copies —
/// this is what surfaces Claude-Code-only (on-disk) sessions in the list, since the
/// scan returns every session a host knows about, not just open Ripul tabs.
public enum RemoteSessionScan {
    public static func fetch(
        machines: [RemoteMachine],
        bridge: AgentBridge,
        cache: RipulSessionCache
    ) async -> (sessions: [RemoteSessionInfo], machineNames: [String: String]) {
        let online = machines.filter { $0.isOnline && !$0.isDisabled(cache: cache) }
        guard !online.isEmpty else { return ([], [:]) }

        var collected: [(String, [RemoteSessionInfo])] = []
        await withTaskGroup(of: (String, [RemoteSessionInfo]).self) { group in
            for machine in online {
                group.addTask {
                    (machine.displayName, await bridge.listRemoteSessions(machineId: machine.machineId))
                }
            }
            for await pair in group { collected.append(pair) }
        }

        var sessions: [RemoteSessionInfo] = []
        var names: [String: String] = [:]
        for (name, list) in collected {
            sessions.append(contentsOf: list)
            for s in list { names[s.id] = name }
        }
        return (sessions, names)
    }
}
