import Foundation
import Combine
import Observation

/// Per-chat live state that drives the **session list** (and the in-chat todo
/// lozenge, plan controls and Files "recently edited"). Kept off `AgentBridge`
/// so bridge traffic never re-renders the list.
///
/// ## Observation granularity
/// These maps change on every tool start/end and activity event of every
/// running chat. As an `ObservableObject` any one write re-rendered every
/// observer — every session row on every screen, for any chat — which is how
/// the list became a sustained re-render (and context-menu flicker, and heat)
/// source for the whole length of a turn.
///
/// Now each chat key has a `SessionActivityCell` (`@Observable`), and every
/// per-chat read (`turnPhase(for:)`, `visibleTodoStateForList(for:)`, …) goes
/// through the cell, so a row re-renders only when *its* chat changes. The
/// maps themselves stay the write API (`AgentBridge` mutates them as before)
/// but are unobserved storage: each write diffs old vs new and updates only the
/// cells whose value actually changed. Bulk readers observe
/// `recencyRevision`, which moves only when the recency *order* may change.
///
/// `updatesSuppressed` (Settings debug switch) still freezes the UI: data lands
/// in the maps, cells stop updating, and re-enabling resyncs every cell.
@MainActor
@Observable
public final class SessionListStore {
    @ObservationIgnored public var updatesSuppressed = false {
        didSet { if oldValue && !updatesSuppressed { resyncAllCells() } }
    }

    @ObservationIgnored private var cells: [String: SessionActivityCell] = [:]

    /// The observable per-chat state for `chatId` (created on first read).
    public func cell(_ chatId: String) -> SessionActivityCell {
        if let cell = cells[chatId] { return cell }
        let cell = SessionActivityCell()
        cells[chatId] = cell
        if !updatesSuppressed { load(cell, chatId) }
        return cell
    }

    /// Moves whenever a last-active change could reorder a recency-sorted list:
    /// a new chat, or a chat whose new time passed another chat's. A running
    /// chat already on top advances without touching it.
    public private(set) var recencyRevision = 0

    // MARK: - Storage maps (write API; unobserved — read per chat via `cell`)

    /// Chats whose last agent turn has not been looked at. Ids arrive in both
    /// CLI forms, so test membership through `isUnread(anyOf:)`.
    @ObservationIgnored public var unreadChatIds: Set<String> = [] {
        didSet {
            guard oldValue != unreadChatIds else { return }
            for key in oldValue.symmetricDifference(unreadChatIds) { update(key) { $0.unread = self.unreadChatIds.contains(key) } }
        }
    }

    /// Sessions pinned to the top of the list, by canonical id (no `cli_`).
    /// Observed as a whole: a pin reorders the list, so every reader should
    /// re-render, and it changes only when you pin or unpin something.
    public var pinnedChatKeys: Set<String> = []

    /// True when any of the supplied aliases for one session is pinned.
    public func isPinned(anyOf keys: [String]) -> Bool {
        keys.contains { pinnedChatKeys.contains(AgentBridge.canonicalChatKey($0)) }
    }

    /// Per-chat latest activity event (session-list subtitle while running).
    @ObservationIgnored public var latestActivityByChatId: [String: AgentActivityEvent] = [:] {
        didSet { diff(oldValue, latestActivityByChatId) { cell, value in cell.latestActivity = value } }
    }

    /// Last time any activity was observed for a chat (list recency sort).
    /// Mirrored to `lastActiveTimeSubject` for persistence.
    @ObservationIgnored public var lastActiveTimeByChatId: [String: Date] = [:] {
        didSet {
            guard oldValue != lastActiveTimeByChatId else { return }
            diff(oldValue, lastActiveTimeByChatId) { cell, value in cell.lastActive = value }
            if !updatesSuppressed {
                if recencyOrderMayChange(from: oldValue, to: lastActiveTimeByChatId) { recencyRevision &+= 1 }
                lastActiveTimeSubject.send(lastActiveTimeByChatId)
            }
        }
    }
    /// Fires on `lastActiveTimeByChatId` changes (unless updates are suppressed).
    @ObservationIgnored public let lastActiveTimeSubject = PassthroughSubject<[String: Date], Never>()

    /// Per-chat session-row actions declared by tools (e.g. "Show Plan").
    @ObservationIgnored public var sessionActionsByChatId: [String: [SessionRowAction]] = [:] {
        didSet { diff(oldValue, sessionActionsByChatId) { cell, value in cell.sessionActions = value } }
    }

    /// Authoritative TodoWrite state per chat.
    @ObservationIgnored public var todoStates: [String: TodoState] = [:] {
        didSet { diff(oldValue, todoStates) { cell, value in cell.todoState = value } }
    }

    /// Per-chat dismissal marker for the in-chat lozenge.
    @ObservationIgnored public var dismissedTodoVersions: [String: Int] = [:] {
        didSet { diff(oldValue, dismissedTodoVersions) { cell, value in cell.dismissedTodoVersion = value } }
    }

    /// Per-chat "viewed in list" marker (session-list plan summary row).
    @ObservationIgnored public var listViewedTodoVersions: [String: Int] = [:] {
        didSet { diff(oldValue, listViewedTodoVersions) { cell, value in cell.listViewedTodoVersion = value } }
    }

    /// Per-chat agent turn phase, stored RAW (running / awaitingInput /
    /// completed / failed). The display collapse happens in `turnPhase(for:)`.
    @ObservationIgnored public var sessionPhases: [String: AgentTurnPhase] = [:] {
        didSet { diff(oldValue, sessionPhases) { cell, value in cell.rawPhase = value } }
    }

    /// When the phase above was established. No view reads it.
    @ObservationIgnored public var phaseTimestampByChatId: [String: Date] = [:]

    // MARK: - Per-chat reads (fine-grained: each goes through the chat's cell)

    /// True when any of the supplied aliases for one session is unread.
    public func isUnread(anyOf keys: [String?]) -> Bool {
        for case let key? in keys where !key.isEmpty {
            if cell(key).unread { return true }
            if key.hasPrefix("cli_"), cell(String(key.dropFirst(4))).unread { return true }
            if cell("cli_\(key)").unread { return true }
        }
        return false
    }

    /// Collapsed phase for display: running / awaitingInput; completed and
    /// failed read as awaitingInput ("your move"); idle is nil. Nil while
    /// updates are suppressed.
    public func turnPhase(for chatId: String) -> AgentTurnPhase? {
        guard !updatesSuppressed, let raw = cell(chatId).rawPhase else { return nil }
        switch raw {
        case .running, .awaitingInput: return raw
        case .completed, .failed: return .awaitingInput
        case .idle: return nil
        }
    }

    /// Raw phase for a chat (no collapse), through its cell.
    public func rawPhase(for chatId: String) -> AgentTurnPhase? { cell(chatId).rawPhase }

    /// Last-active time for a chat, through its cell.
    public func lastActive(for chatId: String) -> Date? { cell(chatId).lastActive }

    /// Session-row actions for a chat, through its cell.
    public func sessionActions(for chatId: String) -> [SessionRowAction]? { cell(chatId).sessionActions }

    /// In-progress plan for a chat, or nil if dismissed or absent.
    public func visibleTodoState(for chatId: String) -> TodoState? {
        let cell = cell(chatId)
        guard let state = cell.todoState else { return nil }
        if cell.dismissedTodoVersion == state.version { return nil }
        return state
    }

    /// Session-list variant — also hides the plan once the user has opened the chat.
    public func visibleTodoStateForList(for chatId: String) -> TodoState? {
        guard let state = visibleTodoState(for: chatId) else { return nil }
        if let viewed = cell(chatId).listViewedTodoVersion, viewed >= state.version { return nil }
        return state
    }

    /// Short tool label for the session list. Gated by updatesSuppressed.
    public func latestToolLabelForList(for chatId: String) -> String? {
        guard !updatesSuppressed, let activity = cell(chatId).latestActivity else { return nil }
        return activity.displayName
    }

    /// Full tool activity event (toolStart or toolEnd) for the session list. Gated.
    public func latestToolActivityForList(for chatId: String) -> AgentActivityEvent? {
        guard !updatesSuppressed, let activity = cell(chatId).latestActivity else { return nil }
        switch activity {
        case .toolStart, .toolEnd: return activity
        default: return nil
        }
    }

    // MARK: - Recently edited files (bulk; observed as a whole by Files)

    public var recentlyEditedFiles: [String] =
        UserDefaults.standard.stringArray(forKey: SessionListStore.recentlyEditedKey) ?? []

    public static let maxRecentlyEditedFiles = 30
    private static let recentlyEditedKey = "ripulRecentlyEditedFiles"
    @ObservationIgnored private var persistRecentWork: DispatchWorkItem?

    public init() {}

    public func recordRecentlyEditedFile(_ path: String) {
        var list = recentlyEditedFiles
        if let existing = list.firstIndex(of: path) { list.remove(at: existing) }
        list.insert(path, at: 0)
        if list.count > Self.maxRecentlyEditedFiles { list = Array(list.prefix(Self.maxRecentlyEditedFiles)) }
        guard list != recentlyEditedFiles else { return }
        recentlyEditedFiles = list
        scheduleRecentlyEditedPersist()
    }

    public func clearRecentlyEditedFiles() {
        if !recentlyEditedFiles.isEmpty { recentlyEditedFiles = [] }
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

    // MARK: - Cell sync

    /// Apply per-key changes between two maps to existing cells only (a cell
    /// that has never been read loads its values when first created).
    private func diff<Value: Equatable>(_ old: [String: Value], _ new: [String: Value],
                                        apply: (SessionActivityCell, Value?) -> Void) {
        guard !updatesSuppressed, !cells.isEmpty, old != new else { return }
        for (key, value) in new where old[key] != value {
            if let cell = cells[key] { apply(cell, value) }
        }
        for key in old.keys where new[key] == nil {
            if let cell = cells[key] { apply(cell, nil) }
        }
    }

    private func update(_ key: String, _ body: (SessionActivityCell) -> Void) {
        guard !updatesSuppressed, let cell = cells[key] else { return }
        body(cell)
    }

    private func load(_ cell: SessionActivityCell, _ key: String) {
        cell.unread = unreadChatIds.contains(key)
        cell.latestActivity = latestActivityByChatId[key]
        cell.lastActive = lastActiveTimeByChatId[key]
        cell.sessionActions = sessionActionsByChatId[key]
        cell.todoState = todoStates[key]
        cell.dismissedTodoVersion = dismissedTodoVersions[key]
        cell.listViewedTodoVersion = listViewedTodoVersions[key]
        cell.rawPhase = sessionPhases[key]
    }

    private func resyncAllCells() {
        for (key, cell) in cells { load(cell, key) }
        recencyRevision &+= 1
    }

    /// Whether an updated time could reorder the chats: a new key, or one whose
    /// time crossed another key's. The common case — the running chat, already
    /// most recent, advancing — reorders nothing.
    private func recencyOrderMayChange(from old: [String: Date], to new: [String: Date]) -> Bool {
        if old.count != new.count { return true }
        for (key, time) in new {
            guard let previous = old[key] else { return true }
            guard previous != time else { continue }
            let low = min(previous, time), high = max(previous, time)
            for (other, otherTime) in new where other != key && otherTime > low && otherTime < high { return true }
        }
        return false
    }
}

/// Live list state for one chat key. Every property is set only on a real
/// change, so reading it costs a re-render only when this chat changes.
@MainActor
@Observable
public final class SessionActivityCell {
    public internal(set) var unread = false
    public internal(set) var latestActivity: AgentActivityEvent?
    public internal(set) var lastActive: Date?
    public internal(set) var sessionActions: [SessionRowAction]?
    public internal(set) var todoState: TodoState?
    public internal(set) var dismissedTodoVersion: Int?
    public internal(set) var listViewedTodoVersion: Int?
    public internal(set) var rawPhase: AgentTurnPhase?
    init() {}
}
