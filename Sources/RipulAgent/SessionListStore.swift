import Foundation
import Combine

/// Leaf `ObservableObject` holding the per-chat maps that drive the **session
/// list** (and the in-chat todo lozenge + Files "recently edited") and nothing
/// else. See the extended note below for why it exists.
///
/// Why this exists: `AgentBridge` is a 62-`@Published`-field `ObservableObject`
/// that the WKWebView-hosting `AgentView`/`AgentWebView`/`ChatComposer` observe.
/// SwiftUI invalidation is object-level, so mutating ANY `@Published` field on
/// the bridge re-runs the body of every view observing it — including the web
/// host. These maps are written on **every tool start/end event during a run**
/// yet are consumed ONLY by the session list. Leaving them on the bridge meant
/// every streaming tool event re-rendered the web host. By moving them onto this
/// dedicated leaf, a write fires `objectWillChange` on the store — NOT on
/// `AgentBridge` — so only views observing `bridge.sessionList` re-render.
///
/// Publishing is done MANUALLY (via `willSet` → `notify()`) rather than with
/// `@Published`, so `updatesSuppressed` can gate SwiftUI notifications: a debug
/// switch that freezes the session list's live updates (data still lands, only
/// the re-render is suppressed) to bisect whether the list contributes to heat.
@MainActor
public final class SessionListStore: ObservableObject {
    /// Debug switch. When true, mutations still land (data stays correct) but
    /// `objectWillChange` is NOT fired, so the session list / todo lozenge /
    /// Files-recents stop re-rendering. Used to bisect streaming heat.
    public var updatesSuppressed = false

    /// Explicit publisher so emission can be gated on `updatesSuppressed`.
    /// (Because none of the fields below use `@Published`, this is the store's
    /// sole `objectWillChange`.)
    public let objectWillChange = ObservableObjectPublisher()

    @inline(__always) private func notify() {
        if !updatesSuppressed { objectWillChange.send() }
    }

    /// Per-chat latest activity event (session-list subtitle while running).
    public var latestActivityByChatId: [String: AgentActivityEvent] = [:] { willSet { notify() } }

    /// Last time any activity was observed for a chat (list recency sort).
    /// Also mirrored to `lastActiveTimeSubject` (ungated) so persistence keeps
    /// working even while re-renders are suppressed.
    public var lastActiveTimeByChatId: [String: Date] = [:] {
        willSet { notify() }
        // Gated by suppression too: SessionManager turns this into an @Published
        // `lastActiveBySessionId`, which re-renders the session list (sort + times)
        // for running sessions — a live update that bypasses the store freeze
        // otherwise. Persistence still happens on background via a direct save, so
        // nothing is lost while frozen.
        didSet { if !updatesSuppressed { lastActiveTimeSubject.send(lastActiveTimeByChatId) } }
    }
    /// Fires on `lastActiveTimeByChatId` changes (unless updates are suppressed).
    /// SessionManager subscribes to this to persist timestamps (replaces the old
    /// `$lastActiveTimeByChatId` Published publisher).
    public let lastActiveTimeSubject = PassthroughSubject<[String: Date], Never>()

    /// Per-chat session-row actions declared by tools (e.g. "Show Plan").
    public var sessionActionsByChatId: [String: [SessionRowAction]] = [:] { willSet { notify() } }

    /// Authoritative TodoWrite state per chat.
    public var todoStates: [String: TodoState] = [:] { willSet { notify() } }

    /// Per-chat dismissal marker for the in-chat lozenge.
    public var dismissedTodoVersions: [String: Int] = [:] { willSet { notify() } }

    /// Per-chat "viewed in list" marker (session-list plan summary row).
    public var listViewedTodoVersions: [String: Int] = [:] { willSet { notify() } }

    /// Per-chat agent turn phase, stored RAW (running / awaitingInput /
    /// completed / failed). The display collapse happens in `turnPhase(for:)`
    /// so "completed" can be filtered against the viewed stamp — a hand should
    /// mean "a finished turn you HAVEN'T seen", not "a turn finished once".
    public var sessionPhases: [String: AgentTurnPhase] = [:] { willSet { notify() } }

    /// When the phase above was established (from the event's own timestamp).
    /// Compared against `lastViewedByChatId` to decide whether a completed
    /// turn still deserves the hand.
    public var phaseTimestampByChatId: [String: Date] = [:] { willSet { notify() } }

    /// Last time the user opened/watched each chat. Persisted — this is the
    /// half of "unseen completion" that must survive restarts locally (the
    /// completion timestamps come back from the web/host on reconnect).
    public var lastViewedByChatId: [String: Date] =
        (UserDefaults.standard.dictionary(forKey: SessionListStore.lastViewedKey) as? [String: Double])?
            .mapValues { Date(timeIntervalSince1970: $0) } ?? [:] {
        willSet { notify() }
    }

    private static let lastViewedKey = "ripulChatLastViewedAt"
    private static let maxLastViewedEntries = 300

    /// Record that the user has seen this chat (opened it, or watched a turn
    /// finish while it was the active chat). Clears its unseen-completion hand.
    public func markChatViewed(_ chatId: String, at date: Date = Date()) {
        if let existing = lastViewedByChatId[chatId], existing >= date { return }
        lastViewedByChatId[chatId] = date
        var toStore = lastViewedByChatId
        if toStore.count > Self.maxLastViewedEntries {
            let keep = toStore.sorted { $0.value > $1.value }.prefix(Self.maxLastViewedEntries)
            toStore = Dictionary(uniqueKeysWithValues: Array(keep))
            lastViewedByChatId = toStore
        }
        UserDefaults.standard.set(toStore.mapValues { $0.timeIntervalSince1970 }, forKey: Self.lastViewedKey)
    }

    /// Gated read — returns nil when updates are suppressed so rows that
    /// re-render from AgentBridge.objectWillChange don't show live phase changes.
    ///
    /// Collapse rules:
    /// - `.running` → spinner, always (live state).
    /// - `.awaitingInput` → hand, always — the agent is BLOCKED on you
    ///   (permission / ask_user); looking at it doesn't unblock it.
    /// - `.completed` / `.failed` → hand only while the completion is newer
    ///   than your last view of the chat; afterwards the row goes quiet.
    public func turnPhase(for chatId: String) -> AgentTurnPhase? {
        guard !updatesSuppressed else { return nil }
        guard let raw = sessionPhases[chatId] else { return nil }
        switch raw {
        case .running, .awaitingInput:
            return raw
        case .completed, .failed:
            // No timestamp (older sender) — keep the legacy always-hand behavior.
            guard let completedAt = phaseTimestampByChatId[chatId] else { return .awaitingInput }
            if let viewed = lastViewedByChatId[chatId], viewed >= completedAt { return nil }
            return .awaitingInput
        case .idle:
            return nil
        }
    }

    // MARK: - Computed reads (moved from AgentBridge so rows can drop the bridge @ObservedObject)

    /// In-progress plan for a chat, or nil if dismissed or absent.
    public func visibleTodoState(for chatId: String) -> TodoState? {
        guard let state = todoStates[chatId] else { return nil }
        if dismissedTodoVersions[chatId] == state.version { return nil }
        return state
    }

    /// Session-list variant — also hides the plan once the user has opened the
    /// chat (listViewedTodoVersions), while the in-chat lozenge is unaffected.
    public func visibleTodoStateForList(for chatId: String) -> TodoState? {
        guard let state = visibleTodoState(for: chatId) else { return nil }
        if let viewed = listViewedTodoVersions[chatId], viewed >= state.version { return nil }
        return state
    }

    /// Short tool label for the session list. Gated by updatesSuppressed.
    public func latestToolLabelForList(for chatId: String) -> String? {
        guard !updatesSuppressed else { return nil }
        guard let activity = latestActivityByChatId[chatId] else { return nil }
        switch activity {
        case .toolStart(let toolName, _, let toolLabel, _):
            return toolLabel ?? toolName
        case .toolEnd(let toolName, _, _, let toolLabel, _):
            return toolLabel ?? toolName
        default:
            return nil
        }
    }

    /// Full tool activity event (toolStart or toolEnd) for the session list. Gated.
    public func latestToolActivityForList(for chatId: String) -> AgentActivityEvent? {
        guard !updatesSuppressed else { return nil }
        guard let activity = latestActivityByChatId[chatId] else { return nil }
        switch activity {
        case .toolStart, .toolEnd: return activity
        default: return nil
        }
    }

    /// Absolute file paths the agent has recently edited (Files "Recently Edited").
    /// Written per Edit tool event during a run; persisted (debounced) to survive
    /// restarts.
    public var recentlyEditedFiles: [String] =
        UserDefaults.standard.stringArray(forKey: SessionListStore.recentlyEditedKey) ?? [] {
        willSet { notify() }
    }

    public static let maxRecentlyEditedFiles = 30
    private static let recentlyEditedKey = "ripulRecentlyEditedFiles"
    private var persistRecentWork: DispatchWorkItem?

    public init() {}

    /// Insert `path` at the front of `recentlyEditedFiles`, dedup, cap, and
    /// schedule a debounced persist.
    public func recordRecentlyEditedFile(_ path: String) {
        var list = recentlyEditedFiles
        if let existing = list.firstIndex(of: path) { list.remove(at: existing) }
        list.insert(path, at: 0)
        if list.count > Self.maxRecentlyEditedFiles {
            list = Array(list.prefix(Self.maxRecentlyEditedFiles))
        }
        recentlyEditedFiles = list
        scheduleRecentlyEditedPersist()
    }

    public func clearRecentlyEditedFiles() {
        recentlyEditedFiles = []
        persistRecentWork?.cancel()
        persistRecentWork = nil
        UserDefaults.standard.removeObject(forKey: Self.recentlyEditedKey)
    }

    public func removeRecentlyEditedFile(_ path: String) {
        guard let idx = recentlyEditedFiles.firstIndex(of: path) else { return }
        recentlyEditedFiles.remove(at: idx)
        scheduleRecentlyEditedPersist()
    }

    private func scheduleRecentlyEditedPersist() {
        persistRecentWork?.cancel()
        let snapshot = recentlyEditedFiles
        let work = DispatchWorkItem {
            UserDefaults.standard.set(snapshot, forKey: SessionListStore.recentlyEditedKey)
        }
        persistRecentWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }
}
