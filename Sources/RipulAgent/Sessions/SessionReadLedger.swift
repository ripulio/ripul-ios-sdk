import Foundation

/// Which chats are waiting on the user, when each was last read, and which are
/// pinned. Local to this device.
///
/// Kept in the session cache rather than derived, because one of its readers
/// — the "what's waiting" App Intent — deliberately does NOT open the app, so
/// it has no bridge, no web view and no live phase map to consult. This is
/// that map's durable shadow, and a cache is all it needs.
struct SessionReadLedger {
    let cache: RipulSessionCache?

    private static let waitingKey = "ripulWaitingSessions"
    private static let readStampsKey = "ripulSessionReadAt"
    private static let pinnedKey = "ripulPinnedSessions"
    private static let sessionIconsKey = "ripulSessionIcons"

    // MARK: - Waiting

    /// The waiting chats, newest first.
    var waiting: [AgentBridge.WaitingSession] {
        guard let data = cache?.data(forKey: Self.waitingKey),
              let decoded = try? JSONDecoder().decode([AgentBridge.WaitingSession].self, from: data)
        else { return [] }
        return decoded.sorted { $0.at > $1.at }
    }

    /// Replace the list, keeping the fifty newest.
    func setWaiting(_ entries: [AgentBridge.WaitingSession]) {
        write(Array(entries.sorted { $0.at > $1.at }.prefix(50)))
    }

    private func write(_ entries: [AgentBridge.WaitingSession]) {
        guard let cache, let data = try? JSONEncoder().encode(entries) else { return }
        cache.set(data, forKey: Self.waitingKey)
    }

    /// Drops a chat from the waiting list — opening it is reading it.
    ///
    /// Matches every CLI alias of the id. The stored entry may be keyed by the
    /// bare uuid while the caller holds `cli_<uuid>` (or vice versa), and an
    /// exact-match clear would silently leave the session unread for ever —
    /// which reads as Siri nagging about something you have already dealt with.
    func clearWaiting(chatId: String) {
        guard cache != nil else { return }
        let aliases: Set<String> = chatId.hasPrefix("cli_")
            ? [chatId, String(chatId.dropFirst(4))]
            : [chatId, "cli_\(chatId)"]
        let all = waiting
        let remaining = all.filter { !aliases.contains($0.chatId) }
        guard remaining.count != all.count else { return }
        write(remaining)
    }

    /// Fills in the reply on a waiting entry that was written before the reply
    /// arrived. False when the chat isn't waiting, or already has one.
    func fillPreview(chatId: String, preview: String) -> Bool {
        guard cache != nil else { return false }
        var entries = waiting
        guard let index = entries.firstIndex(where: { $0.chatId == chatId }) else { return false }
        let existing = entries[index]
        guard existing.preview?.isEmpty != false else { return false }
        entries[index] = AgentBridge.WaitingSession(
            chatId: existing.chatId,
            title: existing.title,
            at: existing.at,
            preview: Self.spokenPreview(preview)
        )
        write(entries)
        return true
    }

    /// Trims a response preview to something bearable read aloud.
    ///
    /// Spoken text has no skim. A screen-length reply that is fine to glance at
    /// is a minute of talking, so this takes whole sentences up to a budget and
    /// stops — cutting mid-sentence sounds like a fault rather than a summary.
    static func spokenPreview(_ raw: String?) -> String? {
        guard let raw else { return nil }
        // Markdown and code fences read as noise, so drop the obvious markers.
        let flat = raw
            .replacingOccurrences(of: "```", with: " ")
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flat.isEmpty else { return nil }
        guard flat.count > 220 else { return flat }

        var out = ""
        for sentence in flat.split(separator: ".", omittingEmptySubsequences: true) {
            let candidate = out.isEmpty ? String(sentence) : out + "." + sentence
            if candidate.count > 220 { break }
            out = candidate
        }
        if out.isEmpty { out = String(flat.prefix(220)) }
        return out.trimmingCharacters(in: .whitespaces) + "."
    }

    // MARK: - Read stamps

    /// One canonical name per session. CLI sessions appear as `cli_<uuid>`
    /// live and as the bare uuid from the scanner; keying the stamps by either
    /// would let the same session hold two contradictory read states.
    static func canonicalChatKey(_ chatId: String) -> String {
        chatId.hasPrefix("cli_") ? String(chatId.dropFirst(4)) : chatId
    }

    /// When each session was last read, by canonical id.
    var readStamps: [String: Date] {
        guard let data = cache?.data(forKey: Self.readStampsKey),
              let decoded = try? JSONDecoder().decode([String: Date].self, from: data)
        else { return [:] }
        return decoded
    }

    /// Records "seen at now", which is what later completions are measured
    /// against. Survives relaunch, which the in-memory phase map does not.
    func stampRead(chatId: String) {
        guard let cache else { return }
        var stamps = readStamps
        stamps[Self.canonicalChatKey(chatId)] = Date()
        // Bounded: this grows one entry per session ever opened and nothing
        // else prunes it. Keeps the most recent, which is all a watermark
        // comparison can ever consult.
        if stamps.count > 300 {
            stamps = Dictionary(uniqueKeysWithValues:
                stamps.sorted { $0.value > $1.value }.prefix(200).map { ($0.key, $0.value) })
        }
        guard let data = try? JSONEncoder().encode(stamps) else { return }
        cache.set(data, forKey: Self.readStampsKey)
    }

    // MARK: - Pins

    /// Pinned sessions, by canonical id.
    var pinnedKeys: Set<String> {
        guard let data = cache?.data(forKey: Self.pinnedKey),
              let decoded = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(decoded)
    }

    /// Pins or unpins every name a row answers to, not one id: a row's own id
    /// can change as sources merge (an orphan `chat_<ts>` becoming the host's
    /// id), and a pin stored under only the old one would silently fall off.
    func setPinned(_ pinned: Bool, names: [String]) {
        guard let cache else { return }
        var keys = pinnedKeys
        let aliases = names.map(Self.canonicalChatKey)
        if pinned { keys.formUnion(aliases) } else { keys.subtract(aliases) }
        guard let data = try? JSONEncoder().encode(keys.sorted()) else { return }
        cache.set(data, forKey: Self.pinnedKey)
    }

    // MARK: - Custom session icons

    /// Candidate keys a session id may resolve to when reading a custom icon:
    /// the `cli_`-stripped canonical form and, for `<provider>:<uuid>` ids,
    /// the bare `<uuid>` suffix.
    static func iconLookupKeys(for chatId: String) -> [String] {
        let canonical = canonicalChatKey(chatId)
        guard let colon = canonical.firstIndex(of: ":") else { return [canonical] }
        let suffix = String(canonical[canonical.index(after: colon)...])
        return suffix.isEmpty || suffix == canonical ? [canonical] : [canonical, suffix]
    }

    /// Every storage key an icon write/remove should cover for `names`,
    /// including the deterministic CLI UUID each alias resolves to so a
    /// local `chat_<ts>` tab and its remote `<provider>:<uuid>` scan row
    /// share the same icon.
    static func iconStorageKeys(for names: [String]) -> Set<String> {
        var out: Set<String> = []
        for name in names where !name.isEmpty {
            for key in iconLookupKeys(for: name) {
                out.insert(key)
                out.insert(UnifiedSession.cliUuid(for: key))
            }
        }
        return out
    }

    /// User-chosen SF Symbol icons, keyed by canonical session id.
    var customIcons: [String: String] {
        cache?.dictionary(forKey: Self.sessionIconsKey) as? [String: String] ?? [:]
    }

    /// Sets or removes the custom SF Symbol icon for every name a session answers to.
    func setCustomIcon(_ icon: String?, names: [String]) {
        guard let cache else { return }
        var icons = customIcons
        let keys = Self.iconStorageKeys(for: names)
        let trimmed = icon?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            for key in keys { icons[key] = trimmed }
        } else {
            for key in keys { icons.removeValue(forKey: key) }
        }
        cache.set(icons, forKey: Self.sessionIconsKey)
    }

    /// Replaces every custom icon at once: one write for a read of the server's.
    func setCustomIcons(_ icons: [String: String]) {
        cache?.set(icons, forKey: Self.sessionIconsKey)
    }

    /// A row of the list as its icon is known: the key the server keeps the
    /// chat's icon under, and every name the row answers to.
    struct IconRow {
        let metadataKey: String
        let names: [String]
    }

    /// A Mac's own chats (`mac_…`) never go to the server, so neither do their icons.
    static func iconStaysOnDevice(_ metadataKey: String) -> Bool {
        metadataKey.isEmpty || metadataKey.hasPrefix("mac_")
    }

    /// What this device keeps after reading the icons the server holds
    /// (`server`, by metadata key, "" for one the person cleared), and what it
    /// should send the server, by metadata key.
    ///
    /// The server wins: its icon goes under every name the chat answers to,
    /// and its cleared icon removes this device's copy. Two things are this
    /// device's to say. A choice the server has not confirmed (`unsaved`) is
    /// left as it is. An icon the server has never heard of, set here while
    /// icons stayed on the device that set them, is sent.
    static func mergingServerIcons(local: [String: String], server: [String: String],
                                   rows: [IconRow], unsaved: Set<String>)
        -> (icons: [String: String], send: [String: String]) {
        var icons = local
        func put(_ icon: String, under names: [String]) {
            for key in iconStorageKeys(for: names) {
                if icon.isEmpty { icons.removeValue(forKey: key) } else { icons[key] = icon }
            }
        }
        let held = Set(unsaved.map(canonicalChatKey))
        // By the server's own names first: that reaches a chat not listed yet.
        for (key, icon) in server where !iconStaysOnDevice(key) && !held.contains(canonicalChatKey(key)) {
            put(icon, under: [key])
        }
        var send: [String: String] = [:]
        for row in rows where !iconStaysOnDevice(row.metadataKey) && !held.contains(canonicalChatKey(row.metadataKey)) {
            let names = [row.metadataKey] + row.names
            if let icon = names.lazy.compactMap({ server[$0] ?? server[canonicalChatKey($0)] }).first {
                put(icon, under: names)
            } else if let mine = names.flatMap(iconLookupKeys(for:)).lazy.compactMap({ local[$0] }).first {
                send[row.metadataKey] = mine
            }
        }
        return (icons, send)
    }
}
