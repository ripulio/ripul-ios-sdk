import Foundation
import CryptoKit

// MARK: - UnifiedSession

/// A single session entry merging the JSONL scanner (ground truth) with any
/// matching Ripul web-app tab (decoration / fast-focus path).
public struct UnifiedSession: Identifiable, Codable {
    public let id: String
    public let title: String
    /// Last time any message was written in any app — the canonical sort key.
    public let lastUsed: Date
    /// Whether `lastUsed` came from a source that actually knows when the
    /// conversation last moved (the host's JSONL scan), as opposed to a
    /// stand-in like a local tab's creation time.
    ///
    /// Without this the merge had no way to tell a real activity timestamp from
    /// "when you opened the tab", so it kept whichever was NEWER — and a chat
    /// opened minutes ago always beat its own true last-activity of weeks back.
    /// Excluded-by-default on decode: rows cached before this existed carry an
    /// unknown provenance, so the first authoritative scan replaces them.
    public let hasKnownActivity: Bool
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
    /// key both the leading icon (via `ModelIdentity`) and the detail-row
    /// text off this — the row identifies the model in use, not the harness.
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
    /// True when `title` came from the host's JSONL scan rather than from a
    /// local tab. Provenance, not decoration: `rematchLocalSessions` consults
    /// it to decide whether a local name may overwrite this one.
    ///
    /// Two writers set `title` — `build` (here) and `rematchLocalSessions` —
    /// and neither used to know which answer was better, so a row whose two
    /// sources disagreed flipped between them on every tick. Field case: a
    /// session showing `Peter_Maude_(iPhone)` from the scan and its own raw
    /// `cli_<uuid>` from the local tab, alternating.
    public let titleFromScan: Bool

    public var isOpenInRipul: Bool { ripulSession != nil || cachedIsOpen }

    /// Strip the `cli_` prefix so local (`cli_<uuid>`) and remote (`<uuid>`)
    /// forms of the same session resolve to one canonical key.
    public static func canonicalKey(_ key: String) -> String {
        key.hasPrefix("cli_") ? String(key.dropFirst(4)) : key
    }

    /// The CLI session uuid a chat id resolves to — the uuid its JSONL is named
    /// by, and the ONLY identifier that is 1:1 with a conversation.
    ///
    /// `canonicalKey` above equates `cli_<uuid>` with a bare `<uuid>`, but a
    /// conversation started on the host carries a THIRD form: `chat_<ts>_<n>`,
    /// related to its uuid by SHA-256 and by nothing a string comparison can
    /// see. Matching on strings alone therefore treats one conversation as two
    /// — the host reports it under whichever identity its tab happens to hold,
    /// the other identity arrives as a local tab, and the list shows both.
    ///
    /// MUST match `sessionIdToCliUuid` (cliSessionUuid.ts) and
    /// `ClaudeCliServer.sessionToUuid` — all three name the same file.
    public static func cliUuid(for sessionId: String) -> String {
        let candidate = canonicalKey(sessionId)
        if isUuidShaped(candidate) { return candidate.lowercased() }

        // Non-uuid id (e.g. chat_<ts>) — hash the ORIGINAL id, prefix included.
        let hex = SHA256.hash(data: Data(sessionId.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let p1 = String(hex.prefix(8))
        let p2 = String(hex.dropFirst(8).prefix(4))
        let p3 = "4" + String(hex.dropFirst(13).prefix(3))
        let variantNibble = UInt8(String(hex.dropFirst(16).prefix(1)), radix: 16) ?? 0
        let variant = (variantNibble & 0x3) | 0x8
        let p4 = String(format: "%x", variant) + String(hex.dropFirst(17).prefix(3))
        let p5 = String(hex.dropFirst(20).prefix(12))
        return "\(p1)-\(p2)-\(p3)-\(p4)-\(p5)"
    }

    private static func isUuidShaped(_ s: String) -> Bool {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 5,
              parts[0].count == 8, parts[1].count == 4, parts[2].count == 4,
              parts[3].count == 4, parts[4].count == 12 else { return false }
        return s.allSatisfy { $0 == "-" || $0.isHexDigit }
    }

    // MARK: - Codable (exclude ripulSession)

    enum CodingKeys: String, CodingKey {
        case id, title, lastUsed, gitBranch, messageCount, projectName, projectPath
        case provider, providerLabel, model, machineName, machineId, matchKeys, cachedIsOpen
        case tags, metadataKey, hasKnownActivity, titleFromScan
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
        hasKnownActivity = try c.decodeIfPresent(Bool.self, forKey: .hasKnownActivity) ?? false
        // Same reasoning as hasKnownActivity: a row cached before this existed
        // has unknown title provenance, so assume the weaker one and let the
        // first real scan claim it.
        titleFromScan = try c.decodeIfPresent(Bool.self, forKey: .titleFromScan) ?? false
        ripulSession = nil
    }

    /// - Parameter cachedIsOpen: Overrides the open flag, which otherwise
    ///   follows `ripulSession`. Only the merge path passes this — it carries a
    ///   cached "was open" across a rebuild that ran before the local tab list
    ///   was available, so the green dot doesn't blink off at launch.
    public init(
        id: String, title: String, lastUsed: Date, hasKnownActivity: Bool = true,
        gitBranch: String?,
        messageCount: Int?, projectName: String?, projectPath: String? = nil,
        provider: String?,
        providerLabel: String?, model: String? = nil, machineName: String?, machineId: String? = nil,
        matchKeys: [String] = [], tags: [String] = [], metadataKey: String? = nil,
        cachedIsOpen: Bool? = nil,
        titleFromScan: Bool = false,
        ripulSession: ChatSession?
    ) {
        self.titleFromScan = titleFromScan
        self.id = id; self.title = title; self.lastUsed = lastUsed
        self.hasKnownActivity = hasKnownActivity
        self.gitBranch = gitBranch; self.messageCount = messageCount
        self.projectName = projectName; self.projectPath = projectPath
        self.provider = provider
        self.providerLabel = providerLabel; self.model = model; self.machineName = machineName
        self.machineId = machineId
        self.matchKeys = matchKeys; self.ripulSession = ripulSession
        self.cachedIsOpen = cachedIsOpen ?? (ripulSession != nil)
        self.tags = tags
        self.metadataKey = metadataKey ?? id
    }

    // MARK: - Merge

    /// Every key this row can be recognised by when merging it against the
    /// previously-displayed list: its own id, its match keys, and the canonical
    /// CLI uuid each of those resolves to. The uuid forms matter because the
    /// SAME conversation is emitted under different ids depending on which
    /// source won the rebuild (`chat_<ts>` as an orphan local, the host's id
    /// once a remote row covers it) — string keys alone can't equate those.
    public var mergeKeys: [String] {
        let base = [id] + matchKeys
        return base + base.map { UnifiedSession.cliUuid(for: $0) }
    }

    /// Copy of this row with a different (or no) matched Ripul tab, and
    /// optionally a refreshed title.
    ///
    /// Exists so the rematch path cannot silently drop fields: it used to
    /// re-run the memberwise init and omit `model`, `projectPath`, `tags` and
    /// `metadataKey`, all of which default to nil/empty — which is what made
    /// the row's leading icon fall back to the harness glyph mid-launch.
    public func withRipulSession(_ match: ChatSession?, title newTitle: String? = nil) -> UnifiedSession {
        UnifiedSession(
            id: id, title: newTitle ?? title, lastUsed: lastUsed,
            hasKnownActivity: hasKnownActivity, gitBranch: gitBranch,
            messageCount: messageCount, projectName: projectName, projectPath: projectPath,
            provider: provider, providerLabel: providerLabel, model: model,
            machineName: machineName, machineId: machineId,
            matchKeys: matchKeys, tags: tags, metadataKey: metadataKey,
            // A title supplied here came from the local tab, so the row is no
            // longer scan-titled; without a new title the provenance stands.
            titleFromScan: newTitle == nil ? titleFromScan : false,
            ripulSession: match
        )
    }

    /// True when this row represents the given local tab — the same identity
    /// test `build` uses, so a caller holding only a `ChatSession` (the chat
    /// screen holds the active tab, not a row) can find its row.
    public func represents(_ chat: ChatSession) -> Bool {
        if ripulSession?.id == chat.id { return true }
        var keys: Set<String> = [chat.id, chat.sourceChatId]
        if chat.sourceChatId.hasPrefix("cli_") {
            keys.insert(String(chat.sourceChatId.dropFirst(4)))
        }
        if let host = chat.hostChatId {
            keys.insert(host)
            if host.hasPrefix("cli_") { keys.insert(String(host.dropFirst(4))) }
        }
        keys.insert(UnifiedSession.cliUuid(for: chat.hostChatId ?? chat.sourceChatId))
        return !Set(mergeKeys).isDisjoint(with: keys)
    }

    /// Copy of this row reporting a different model.
    public func withModel(_ newModel: String?) -> UnifiedSession {
        UnifiedSession(
            id: id, title: title, lastUsed: lastUsed,
            hasKnownActivity: hasKnownActivity, gitBranch: gitBranch,
            messageCount: messageCount, projectName: projectName, projectPath: projectPath,
            provider: provider, providerLabel: providerLabel, model: newModel,
            machineName: machineName, machineId: machineId,
            matchKeys: matchKeys, tags: tags, metadataKey: metadataKey,
            cachedIsOpen: cachedIsOpen,
            titleFromScan: titleFromScan,
            ripulSession: ripulSession
        )
    }

    /// Copy of this row with the project name and path filled in from a source
    /// the builder didn't have (the host's own working directory).
    public func withProject(name: String?, path: String?) -> UnifiedSession {
        UnifiedSession(
            id: id, title: title, lastUsed: lastUsed,
            hasKnownActivity: hasKnownActivity, gitBranch: gitBranch,
            messageCount: messageCount, projectName: name ?? projectName,
            projectPath: path ?? projectPath,
            provider: provider, providerLabel: providerLabel, model: model,
            machineName: machineName, machineId: machineId,
            matchKeys: matchKeys, tags: tags, metadataKey: metadataKey,
            cachedIsOpen: cachedIsOpen,
            titleFromScan: titleFromScan,
            ripulSession: ripulSession
        )
    }

    /// Fill in the fields this row has no opinion about from the row that was
    /// on screen before it.
    ///
    /// Absence of evidence is not evidence of absence: a source that doesn't
    /// know a session's model (a local tab, a scan that hasn't landed) reports
    /// nil, and publishing that nil is what makes descriptive fields flicker
    /// between renders. Nil means "no opinion" and loses to any previously
    /// known value; a non-nil value always wins, so real changes still land.
    ///
    /// `lastUsed` follows provenance, not recency. It used to take the max, to
    /// stop a noisy file mtime from re-sorting the list under the user's
    /// finger. But max() cannot distinguish noise from a correction: once any
    /// wrong-but-recent value landed on a row — a bumped mtime, or a local
    /// tab's creation time standing in for activity — no accurate older value
    /// could ever replace it, and the ratchet was persisted to the cache, so
    /// the row stayed wrong across relaunches. A three-week-old conversation
    /// read as "50 minutes ago" indefinitely.
    ///
    /// So: a source that KNOWS the activity wins outright, even moving the row
    /// backwards. A source that is only guessing loses to a previously-known
    /// value, and two guesses fall back to the old max() behaviour.
    ///
    /// - Parameters:
    ///   - keepTagsWhenEmpty: Pass true when the tag map itself failed to load
    ///     (no data for ANY session), so empty tags read as "not fetched"
    ///     rather than "user removed them".
    ///   - keepOpenFlagWhenUnmatched: Pass true while the local tab list is
    ///     still loading — until then an unmatched row means "don't know yet",
    ///     not "closed".
    public func coalescing(
        over previous: UnifiedSession?,
        keepTagsWhenEmpty: Bool = false,
        keepOpenFlagWhenUnmatched: Bool = false
    ) -> UnifiedSession {
        guard let previous else { return self }
        let keepOpen = keepOpenFlagWhenUnmatched && ripulSession == nil && previous.isOpenInRipul
        let mergedLastUsed: Date = {
            if hasKnownActivity { return lastUsed }
            if previous.hasKnownActivity { return previous.lastUsed }
            return max(lastUsed, previous.lastUsed)
        }()
        return UnifiedSession(
            id: id,
            title: title,
            lastUsed: mergedLastUsed,
            hasKnownActivity: hasKnownActivity || previous.hasKnownActivity,
            gitBranch: gitBranch ?? previous.gitBranch,
            messageCount: messageCount ?? previous.messageCount,
            projectName: projectName ?? previous.projectName,
            projectPath: projectPath ?? previous.projectPath,
            provider: provider ?? previous.provider,
            providerLabel: providerLabel ?? previous.providerLabel,
            model: model ?? previous.model,
            machineName: machineName ?? previous.machineName,
            machineId: machineId ?? previous.machineId,
            matchKeys: matchKeys.isEmpty ? previous.matchKeys : matchKeys,
            tags: (tags.isEmpty && keepTagsWhenEmpty) ? previous.tags : tags,
            metadataKey: metadataKey,
            cachedIsOpen: keepOpen ? true : cachedIsOpen,
            ripulSession: ripulSession
        )
    }

    // MARK: - Cache

    /// v2: entries written before `hasKnownActivity` existed can hold a
    /// lastUsed the old max() ratchet locked in — a bumped file mtime or a tab's
    /// creation time that no correct value could displace. Reading them back
    /// would reseed exactly the wrong dates this key was bumped to clear, so
    /// the old cache is abandoned rather than migrated.
    private static let cacheKey = "ripulUnifiedSessionsCacheV2"

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
        // Every local tab that resolves to a given CLI uuid. A conversation can
        // be open under BOTH of its identities (`chat_<ts>` and the `cli_<uuid>`
        // twin minted for it); the string keys above can never equate those, so
        // one of them always fell through to the orphan-local pass below and
        // showed as a second row. Grouping by resolved uuid is what collapses
        // them — and the whole GROUP has to be covered, not just the first hit,
        // or the other member simply becomes the orphan instead.
        var localsByCliUuid: [String: [ChatSession]] = [:]
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
            // Prefer the host's identity for the conversation when we know it —
            // that is the id whose JSONL the host actually reads.
            let identitySource = s.hostChatId ?? s.sourceChatId
            localsByCliUuid[cliUuid(for: identitySource), default: []].append(s)
        }

        var result: [UnifiedSession] = []
        var coveredLocalIds = Set<String>()

        for r in remote {
            // Match priority: remote id, remote sourceChatId, then the host-provided
            // hostChatId (set by the Mac when it collapses a JSONL row into a Ripul tab).
            // Identity match, not string match: the remote row and a local tab
            // can name the same conversation in two shapes that share no
            // substring (`claude-cli:<uuid>` vs `chat_<ts>`). Resolve both to
            // the uuid the JSONL is named by and compare THAT; fall back to the
            // string lookups for anything not CLI-backed.
            let remoteUuid = cliUuid(for: r.hostChatId ?? r.sourceChatId)
            let uuidGroup = localsByCliUuid[remoteUuid] ?? []
            let ripulMatch = localById[r.id]
                ?? localById[r.sourceChatId]
                ?? (r.hostChatId.flatMap { localById[$0] })
                ?? uuidGroup.first
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
                // ...and every local that resolves to the same conversation,
                // whichever identity it is open under.
                for alt in uuidGroup {
                    coveredLocalIds.insert(alt.id)
                    coveredLocalIds.insert(alt.sourceChatId)
                }
            }
            let rowKeys = [r.id, r.sourceChatId, r.hostChatId].compactMap({ $0 })
            result.append(UnifiedSession(
                id: r.id,
                title: r.displayName,
                // lastModified is the scanner's real last-message time; createdAt
                // is only a stand-in, so a row falling back to it is guessing.
                lastUsed: r.lastModified ?? r.createdAt,
                hasKnownActivity: r.lastModified != nil,
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
                titleFromScan: true,
                ripulSession: ripulMatch
            ))
        }

        // Append Ripul-only sessions (non-CLI agents with no JSONL file).
        // Skip locals we just archived/closed — closeSession returns before the
        // web app removes the tab, so without this filter a flaky archive-all
        // resurrects the row as an "orphan local" with a stale green dot.
        // When no remote row covered a conversation (host asleep / scan failed),
        // its two identities would BOTH land here as orphans. Emit one per
        // conversation, preferring the `cli_<uuid>` identity — the canonical
        // form every other path resolves to, and the one whose content came
        // from the JSONL itself.
        var emittedOrphanUuids = Set<String>()
        let orphanSurvivors: Set<String> = {
            var byUuid: [String: ChatSession] = [:]
            for s in localSessions where !coveredLocalIds.contains(s.id)
                && !recentlyClosedLocalIds.contains(s.id) {
                let uuid = cliUuid(for: s.hostChatId ?? s.sourceChatId)
                guard let incumbent = byUuid[uuid] else { byUuid[uuid] = s; continue }
                let incumbentIsCli = canonicalKey(incumbent.hostChatId ?? incumbent.sourceChatId) != (incumbent.hostChatId ?? incumbent.sourceChatId)
                let challengerIsCli = canonicalKey(s.hostChatId ?? s.sourceChatId) != (s.hostChatId ?? s.sourceChatId)
                if challengerIsCli && !incumbentIsCli { byUuid[uuid] = s }
            }
            return Set(byUuid.values.map { $0.id })
        }()

        for s in localSessions where !coveredLocalIds.contains(s.id)
            && !recentlyClosedLocalIds.contains(s.id)
            && orphanSurvivors.contains(s.id) {
            let orphanUuid = cliUuid(for: s.hostChatId ?? s.sourceChatId)
            if !emittedOrphanUuids.insert(orphanUuid).inserted { continue }
            result.append(UnifiedSession(
                id: s.id,
                title: s.displayName,
                // A local tab knows when IT was opened, not when the conversation
                // last moved. Flagged as a guess so a real scan overrides it.
                lastUsed: s.createdAt,
                hasKnownActivity: false,
                // Facts published over SessionChannel, when the session sent
                // any. A local tab normally has none — the remote scan above
                // is where repo/branch come from — but a share-link guest is
                // never scanned (its pairing is a synthetic shared-<roomId>
                // machine holding no files), so this is the only route by
                // which its row learns what work the session is doing.
                gitBranch: s.gitBranch,
                messageCount: nil,
                projectName: s.projectName,
                // No absolute path travels with the facts, deliberately: the
                // row shows a project name, and a guest invited to a
                // conversation shouldn't receive the owner's directory layout.
                projectPath: nil,
                provider: s.provider,
                providerLabel: s.providerLabel,
                model: s.model,
                machineName: s.remoteMachineName,
                machineId: nil,
                tags: resolveTags([s.id, s.sourceChatId]),
                metadataKey: canonicalKey(s.sourceChatId),
                // Orphan: no scan row covered this conversation, so the local
                // tab is the ONLY title source and must stay free to update it.
                titleFromScan: false,
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
        lhs.hasKnownActivity == rhs.hasKnownActivity &&
        lhs.machineName == rhs.machineName &&
        // machineId is the routing ADDRESS for open/archive/delete. Omitting
        // it let a rebuild that only corrected the owner be dropped by the
        // "nothing changed" gate, freezing a wrong attribution on screen.
        lhs.machineId == rhs.machineId &&
        lhs.provider == rhs.provider &&
        lhs.providerLabel == rhs.providerLabel &&
        lhs.model == rhs.model &&
        lhs.messageCount == rhs.messageCount &&
        lhs.projectName == rhs.projectName &&
        lhs.gitBranch == rhs.gitBranch &&
        lhs.tags == rhs.tags &&
        // Both drive what the row shows: projectPath re-roots the folder tree,
        // cachedIsOpen is half of `isOpenInRipul` (the green dot). Omitting
        // them let a rebuild that ONLY corrects one of them be dropped by the
        // "nothing changed" gate, so the stale value stayed on screen.
        lhs.projectPath == rhs.projectPath &&
        lhs.cachedIsOpen == rhs.cachedIsOpen &&
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

        // Collapse cross-machine duplicates of one session id instead of
        // last-writer-wins (task-group completion order is nondeterministic,
        // so the winning machine flipped between refreshes). Prefer the row
        // backed by a real CLI scan (provider/lastModified present) over a
        // tab-fallback echo from a machine that merely has the chat open.
        var sessions: [RemoteSessionInfo] = []
        var names: [String: String] = [:]
        var indexById: [String: Int] = [:]
        func scanScore(_ s: RemoteSessionInfo) -> Int {
            (s.provider != nil ? 2 : 0) + (s.lastModified != nil ? 1 : 0)
        }
        for (name, list) in collected {
            for s in list {
                if let i = indexById[s.id] {
                    if scanScore(s) > scanScore(sessions[i]) {
                        sessions[i] = s
                        names[s.id] = name
                    }
                } else {
                    indexById[s.id] = sessions.count
                    sessions.append(s)
                    names[s.id] = name
                }
            }
        }
        return (sessions, names)
    }
}
