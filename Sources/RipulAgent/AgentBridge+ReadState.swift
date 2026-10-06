import Foundation

/// Read state as the bridge sees it: deciding from turn events which chats
/// are waiting on the user, what counts as having read one, and pins.
///
/// What is decided here is kept by `SessionReadLedger`, which needs only the
/// session cache. That is how Siri's "what's waiting" reads it without the app.
extension AgentBridge {
    /// A session whose turn has ended and which is now waiting on the user.
    public struct WaitingSession: Codable, Identifiable {
        public let chatId: String
        public let title: String
        public let at: Date
        /// What the agent last said in this chat, as the web previewed it.
        /// Optional because a turn can end without one — a failure, or a chat
        /// whose last event arrived before the app was listening.
        public let preview: String?
        public var id: String { chatId }

        public init(chatId: String, title: String, at: Date, preview: String? = nil) {
            self.chatId = chatId
            self.title = title
            self.at = at
            self.preview = preview
        }
    }

    var readLedger: SessionReadLedger { SessionReadLedger(cache: sessionCache) }

    // MARK: - Reading the ledger without a bridge

    /// The waiting set, readable with nothing else running.
    public static func waitingSessions(cache: RipulSessionCache?) -> [WaitingSession] {
        SessionReadLedger(cache: cache).waiting
    }

    /// Drops a session from the unread set — opening it is reading it. Matches
    /// both names of a CLI chat.
    public static func clearWaiting(chatId: String, cache: RipulSessionCache?) {
        SessionReadLedger(cache: cache).clearWaiting(chatId: chatId)
    }

    static func spokenPreview(_ raw: String?) -> String? { SessionReadLedger.spokenPreview(raw) }
    static func canonicalChatKey(_ chatId: String) -> String { SessionReadLedger.canonicalChatKey(chatId) }
    static func pinnedKeys(cache: RipulSessionCache?) -> Set<String> { SessionReadLedger(cache: cache).pinnedKeys }
    static func readStamps(cache: RipulSessionCache?) -> [String: Date] { SessionReadLedger(cache: cache).readStamps }
    static func stampRead(chatId: String, cache: RipulSessionCache?) { SessionReadLedger(cache: cache).stampRead(chatId: chatId) }

    // MARK: - What makes a chat wait

    /// Adds or removes one session, mirroring the live phase.
    ///
    /// `completed` and `failed` mean the agent stopped and it is your move;
    /// `awaitingInput` is a mid-turn prompt, which is also your move. `running`
    /// and `idle` are not.
    func persistWaitingState(chatId: String, phase: AgentTurnPhase, eventDate: Date?) {
        guard sessionCache != nil else { return }
        let ledger = readLedger

        // Only a TRANSITION counts. The same phase is re-asserted constantly —
        // status pushes, session refreshes, snapshot replays — and the device
        // log shows one chat writing `completed` three times inside a second.
        // Reads `chatTurnPhases` because at this point in the caller it still
        // holds the PREVIOUS value; `sessionList.sessionPhases` has already
        // been overwritten with the new one and cannot answer this.
        guard chatTurnPhases[chatId] != phase else { return }

        // A turn STARTING is not you reading the last one. This used to fall
        // through to the write below with the entry filtered out, so an agent
        // beginning new work silently cleared an unread reply nobody had seen.
        // Only opening the session clears it.
        switch phase {
        case .running, .idle: return
        case .completed, .failed, .awaitingInput: break
        }

        let date = eventDate ?? Date()

        // THE WATERMARK. On a cold start `chatTurnPhases` is empty, so every
        // session's first status push reads as a nil -> completed transition
        // and re-marked the whole list unread — read state did not survive a
        // relaunch. Edge detection alone cannot fix that, because on a fresh
        // process there is no previous edge to compare against.
        //
        // So compare the turn's own timestamp against when the session was
        // last read. A replay of yesterday's completion is older than the
        // read stamp and stays read; a turn that genuinely just ended is
        // newer and marks unread. A missing timestamp is treated as
        // rehydration rather than news — the alternative re-marks everything
        // on launch, which is the bug being fixed.
        if let readAt = ledger.readStamps[SessionReadLedger.canonicalChatKey(chatId)] {
            // Both branches leave the entry read, and both fire once per
            // session on a cold start — 39 lines of "nothing changed" in a
            // 344-line buffer, which is what buried the signal. Silent by
            // design: only the write below, which changes state, logs.
            guard let eventDate else { return }
            guard eventDate > readAt else { return }
        }

        var entries = ledger.waiting.filter { $0.chatId != chatId }
        // Watching it IS reading it: the entry stays filtered out, so the
        // session ends up read rather than unread.
        if !isViewingChat(chatId) {
            let title = sessions.first(where: { $0.id == chatId || $0.sourceChatId == chatId })?
                .displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            entries.append(WaitingSession(
                chatId: chatId,
                title: (title?.isEmpty == false) ? title! : "Untitled session",
                at: date,
                // Carried at write time, not read time: by the time Siri asks,
                // the app may not be running to have a live map at all.
                preview: SessionReadLedger.spokenPreview(lastResponsePreviewByChatId[chatId])
            ))
            handleConsoleLog(
                "LOG: [WAITING] \(phase.rawValue) chat=…\(chatId.suffix(8)) reply=\(lastResponsePreviewByChatId[chatId] == nil ? "none-yet" : "captured")"
            )
            // Activity previews only fire for chats the web view is actively
            // streaming, so for a CLI session finishing on a remote machine
            // there is never one — proven on device: every write logged
            // reply=none-yet and nothing ever backfilled. Ask the web directly
            // instead; it can load the chat's actions even when unviewed.
            if lastResponsePreviewByChatId[chatId] == nil {
                Task { @MainActor in await fetchAndStoreReply(chatId: chatId) }
            }
        }
        ledger.setWaiting(entries)
        publishUnreadIds()
    }

    /// True when this chat is the one on screen, in an app that is frontmost.
    ///
    /// A turn finishing while you WATCH it is already read, so marking it
    /// unread would put a dot on the very row you are looking at and have Siri
    /// offer to read you back something you just watched arrive.
    private func isViewingChat(_ chatId: String) -> Bool {
        guard appIsForeground else { return false }
        let activeAliases = [activeSessionId, activeSession?.sourceChatId]
        for case let candidate? in activeAliases {
            if candidate == chatId { return true }
            if candidate.hasPrefix("cli_"), String(candidate.dropFirst(4)) == chatId { return true }
            if "cli_\(candidate)" == chatId { return true }
        }
        return false
    }

    // MARK: - What the agent last said

    /// Fills in replies for waiting entries that have none.
    ///
    /// Runs once per launch, from `fetchSessions`, which is the first moment
    /// the web is reliably answering. Bounded to the entries Siri would
    /// actually read — filling the tail nobody hears would be work for nothing.
    func backfillMissingReplies() async {
        guard !hasSweptWaitingReplies, sessionCache != nil else { return }
        let missing = readLedger.waiting
            .filter { ($0.preview ?? "").isEmpty }
            .prefix(3)
        guard !missing.isEmpty else { return }
        hasSweptWaitingReplies = true
        handleConsoleLog("LOG: [WAITING] sweeping \(missing.count) entr\(missing.count == 1 ? "y" : "ies") with no reply")
        for entry in missing {
            await fetchAndStoreReply(chatId: entry.chatId)
        }
    }

    /// Pulls the turn's final assistant text from the web and stores it against
    /// the waiting entry, so Siri can read it back later with nothing running.
    ///
    /// A pull, not a push, because the completion signal for the sessions that
    /// matter — CLI turns finishing on a remote machine — arrives as a bare
    /// status phase with no text attached. The web can still resolve it: the
    /// chat's actions are loadable from KV even when nobody is viewing them.
    private func fetchAndStoreReply(chatId: String) async {
        guard attachedWebView != nil else { return }
        let reply = await callPage("__ripulGetLastAssistantText", [chatId], .ifMissing("null"), log: .none)
        if let error = reply.error {
            handleConsoleLog("LOG: [WAITING] reply fetch chat=…\(chatId.suffix(8)) error=\(error.localizedDescription)")
            return
        }
        guard let dict = reply.dictionary else {
            handleConsoleLog("LOG: [WAITING] reply fetch chat=…\(chatId.suffix(8)) result=unavailable")
            return
        }
        // An empty answer is the ordinary outcome here — most chats have
        // no loadable reply — so it is not logged. `unavailable` (the web
        // didn't answer) and the error path above still are.
        guard let text = dict["text"] as? String, !text.isEmpty else { return }
        backfillWaitingPreview(chatId: chatId, preview: text)
    }

    /// Fills in the reply on a waiting entry that was written before the reply
    /// arrived. No-op when the chat isn't waiting, or already has one.
    func backfillWaitingPreview(chatId: String, preview: String) {
        guard readLedger.fillPreview(chatId: chatId, preview: preview) else { return }
        handleConsoleLog("LOG: [WAITING] backfilled reply for chat …\(chatId.suffix(8))")
    }

    // MARK: - Reading and unreading

    /// Marks a session read — you have looked at it.
    ///
    /// Read means SEEN BY EYE, not "announced by Siri". Siri reading a summary
    /// aloud deliberately does not clear anything: hearing that a session
    /// finished is not the same as having read what it said, and clearing on
    /// the announcement would make the list forget the moment you asked.
    func markSessionRead(_ chatId: String) {
        let ledger = readLedger
        ledger.clearWaiting(chatId: chatId)
        ledger.stampRead(chatId: chatId)
        if let source = sessions.first(where: { $0.id == chatId })?.sourceChatId {
            ledger.clearWaiting(chatId: source)
            ledger.stampRead(chatId: source)
        }
        publishUnreadIds()
    }

    /// Marks a list row read by hand, from its context menu.
    ///
    /// Clears every alias the row answers to rather than one id: the entry may
    /// be stored under any of them, and missing it would leave the row bold.
    public func markSessionRead(_ session: UnifiedSession) {
        let ledger = readLedger
        for key in session.readStateKeys {
            ledger.clearWaiting(chatId: key)
            ledger.stampRead(chatId: key)
        }
        publishUnreadIds()
    }

    /// Marks a list row unread by hand — "come back to this".
    ///
    /// Written as an ordinary waiting entry, so it behaves like a turn that
    /// finished unseen: Siri offers it, and opening the session clears it.
    public func markSessionUnread(_ session: UnifiedSession) {
        guard sessionCache != nil else { return }
        let ledger = readLedger
        let chatId = session.ripulSession?.sourceChatId ?? session.id
        var entries = ledger.waiting.filter { $0.chatId != chatId }
        entries.append(WaitingSession(chatId: chatId, title: session.title, at: Date()))
        ledger.setWaiting(entries)
        publishUnreadIds()
    }

    /// Mirrors the persisted unread set onto the store the session rows watch.
    ///
    /// Two representations because they answer different questions: the file
    /// survives the app not running, which is what Siri needs; the published
    /// set drives SwiftUI, which the file cannot.
    func publishUnreadIds() {
        sessionList.unreadChatIds = Set(readLedger.waiting.map(\.chatId))
    }

    // MARK: - Pins

    /// Pins or unpins a list row.
    public func setSessionPinned(_ pinned: Bool, _ session: UnifiedSession) {
        guard sessionCache != nil else { return }
        readLedger.setPinned(pinned, names: session.readStateKeys)
        publishPinnedKeys()
    }

    func publishPinnedKeys() {
        sessionList.pinnedChatKeys = readLedger.pinnedKeys
    }
}
