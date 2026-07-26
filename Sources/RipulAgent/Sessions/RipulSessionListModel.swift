import Combine
import Foundation
#if os(iOS)
import UIKit
#endif

/// Manages session state imperatively — no SwiftUI `.onChange` timing races.
///
/// The view observes only `@Published` properties. All state transitions
/// (fetch → merge → cache) happen in imperative async methods where ordering
/// is guaranteed.
@MainActor
public final class RipulSessionListModel: ObservableObject {

    // MARK: - Published (view observes these)

    @Published public private(set) var unifiedSessions: [UnifiedSession]
    @Published public private(set) var machines: [RemoteMachine] = []
    /// True once a machines fetch has SUCCEEDED at least once on this install
    /// (persisted). The embedded first-run onboarding must not appear before
    /// this: an empty list ahead of the first successful fetch means "offline /
    /// not loaded yet", not "new account" — otherwise bad connectivity drops
    /// returning users onto the marketing cards.
    @Published public private(set) var hasSuccessfulMachinesResponse: Bool = false
    @Published public private(set) var isLoadingRemoteSessions = false
    @Published public var openingUnifiedSessionId: String?
    @Published public var archivingUnifiedSessionId: String?
    @Published public var deletingUnifiedSessionId: String?
    /// True while the in-flight delete will archive the CLI session on a
    /// remote host (the slow network step). Lets the row label distinguish
    /// "Removing from host…" from a fast local-only "Removing…".
    @Published public var deletingFromHost: Bool = false
    @Published public var connectingMachineId: String?
    @Published public var connectError: String?
    @Published public var openSessionError: String?
    @Published public var restartingMachineId: String?
    @Published public var restartSucceededId: String?
    @Published public private(set) var archivedSessions: [AgentBridge.ArchivedSessionInfo] = []
    @Published public private(set) var isLoadingArchivedSessions = false
    @Published public var restoringArchivedSessionId: String?

    // MARK: - Archive All progress

    public struct ArchiveAllState {
        public var current: Int = 0
        public var total: Int = 0
        public var currentTitle: String = ""
        public var archivedTitles: [String] = []
        public var errors: [String] = []
        public var isComplete: Bool = false
        public var isPaused: Bool = false
    }
    @Published public var archiveAllState: ArchiveAllState? = nil

    // MARK: - Internal state (NOT published — no onChange races)

    /// Remote sessions grouped by machine display name — source of truth.
    /// Preserves sessions from not-yet-responded machines during incremental refresh.
    private var remoteSessionsByMachine: [String: [RemoteSessionInfo]] = [:]
    /// Maps remote session ID → machine display name.
    private var sessionMachineNames: [String: String] = [:]
    /// Flattened view of `remoteSessionsByMachine`, minus archived IDs.
    private var remoteSessions: [RemoteSessionInfo] = []
    private var hasLoadedRemoteSessions = false
    /// Bulk map of sessionId → tags, fetched once per session load and injected
    /// into `UnifiedSession.build` so rows render tag lozenges.
    private var sessionTagsByKey: [String: [String]] = [:]
    private var recentlyArchivedIds: Set<String> = []
    /// Local ChatSession IDs we just closed via bridge.closeSession. Keeps them
    /// hidden from the unified list until the web app removes the tab, so a
    /// flaky archive-all can't resurrect rows as orphan locals.
    private var recentlyClosedLocalIds: Set<String> = []
    private var lastLoadCompleted: Date?
    private var initialLoadTask: Task<Void, Never>?
    private var hasRefreshedAfterAuth = false

    // MARK: - Dependencies

    private let bridge: AgentBridge
    private let tokenProvider: () -> String?
    private let cache: RipulSessionCache
    private var sessionsCancellable: AnyCancellable?
    private var sessionsReadyCancellable: AnyCancellable?
    private var lastActiveTimeCancellable: AnyCancellable?
    private var machineRefreshTimer: Timer?
    private var lifecycleObservers: [NSObjectProtocol] = []

    private static let lastActiveTimeCacheKey = "ripulLastActiveTimeByChatId"
    /// Resolved last-active times keyed by UnifiedSession.id — stable across
    /// restarts (unlike chatId which requires ripulSession to resolve).
    private static let lastActiveBySessionIdCacheKey = "ripulLastActiveBySessionId"
    @Published public private(set) var lastActiveBySessionId: [String: Date] = [:]

    // MARK: - Init

    private let startupTime = CFAbsoluteTimeGetCurrent()

    public init(bridge: AgentBridge, tokenProvider: @escaping () -> String?, cache: RipulSessionCache) {
        self.bridge = bridge
        self.tokenProvider = tokenProvider
        self.cache = cache

        self.machines = RemoteMachine.loadCached(cache: cache)
        self.hasSuccessfulMachinesResponse =
            cache.bool(forKey: "ripul.hasSuccessfulMachinesFetch")

        let cached = UnifiedSession.loadCached(cache: cache)
        let openCount = cached.filter(\.cachedIsOpen).count
        self.unifiedSessions = cached
        log("debug_timeline \(elapsed()) init: \(cached.count) cached sessions (\(openCount) cachedIsOpen), bridge.sessions=\(bridge.sessions.count)")

        // Restore persisted last-active timestamps so sort order is
        // correct immediately on launch, before any live events arrive.
        // Two caches: chatId-keyed (feeds bridge for live lookups) and
        // sessionId-keyed (stable across restarts, used on cold start
        // before ripulSession is matched).
        if let data = cache.data(forKey: Self.lastActiveTimeCacheKey),
           let dict = try? JSONDecoder().decode([String: Date].self, from: data) {
            bridge.sessionList.lastActiveTimeByChatId = dict
            log("debug_timeline \(elapsed()) restored \(dict.count) lastActiveTime entries (chatId-keyed)")
        }
        if let data = cache.data(forKey: Self.lastActiveBySessionIdCacheKey),
           let dict = try? JSONDecoder().decode([String: Date].self, from: data) {
            lastActiveBySessionId = dict
            log("debug_timeline \(elapsed()) restored \(dict.count) lastActiveTime entries (sessionId-keyed)")
        } else {
            log("debug_timeline \(elapsed()) no sessionId-keyed lastActiveTime cache found")
        }

        // Observe bridge.sessions for live rematch (green dots).
        // Throttled to avoid thrashing during bulk pairing / session updates.
        sessionsCancellable = bridge.$sessions
            .dropFirst()
            .throttle(for: .milliseconds(500), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in
                guard let self else { return }
                // bridge.sessions changed. The light rematch only updates the
                // ripulSession (green dot) on rows that ALREADY exist — it can't
                // surface a brand-new local-only chat, because no row exists for
                // it yet. If a local session isn't represented in the unified
                // list, do a full rebuild so a just-created chat appears without
                // a pull-to-refresh; otherwise keep the cheap rematch to avoid
                // re-sorting the whole list on every live activity tick.
                if hasUnrepresentedLocalSession() {
                    rebuildUnifiedSessions()
                } else {
                    rematchLocalSessions()
                }
            }

        // Persist last-active timestamps whenever they change.
        // Throttled to avoid excessive writes during rapid tool calls.
        lastActiveTimeCancellable = bridge.sessionList.lastActiveTimeSubject
            .throttle(for: .seconds(2), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] dict in
                self?.saveLastActiveTimes(dict)
            }

        // Also save when app goes to background — the throttle might not
        // have flushed yet when the system kills the process.
        #if os(iOS)
        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.saveLastActiveTimes(bridge.sessionList.lastActiveTimeByChatId)
        }
        #endif
    }

    private func saveLastActiveTimes(_ dict: [String: Date]) {
        // Save the raw chatId-keyed dict for bridge restore.
        if let data = try? JSONEncoder().encode(dict) {
            cache.set(data, forKey: Self.lastActiveTimeCacheKey)
        }
        // Also resolve to sessionId-keyed cache for cold start (when
        // ripulSession is nil and matchKeys may not overlap with chatIds).
        resolveAndSaveBySessionId()
    }

    /// Map chatId timestamps → UnifiedSession.id timestamps using the
    /// current session list (which has ripulSession matched).
    private func resolveAndSaveBySessionId() {
        var updated = lastActiveBySessionId
        for session in unifiedSessions {
            var best: Date = updated[session.id] ?? .distantPast
            // Check via ripulSession (live matched)
            if let ripul = session.ripulSession {
                if let t = bridge.sessionList.lastActiveTimeByChatId[ripul.id] { best = max(best, t) }
                if let t = bridge.sessionList.lastActiveTimeByChatId[ripul.sourceChatId] { best = max(best, t) }
            }
            // Check via matchKeys
            for key in session.matchKeys {
                if let t = bridge.sessionList.lastActiveTimeByChatId[key] { best = max(best, t) }
            }
            if best > .distantPast {
                updated[session.id] = best
            }
        }
        lastActiveBySessionId = updated
        if let data = try? JSONEncoder().encode(updated) {
            cache.set(data, forKey: Self.lastActiveBySessionIdCacheKey)
        }
    }

    deinit {
        machineRefreshTimer?.invalidate()
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
    }

    private func elapsed() -> String {
        String(format: "+%.1fs", CFAbsoluteTimeGetCurrent() - startupTime)
    }

    // MARK: - Initial load (replaces the view's .task block)

    public func initialLoad() {
        log("debug_timeline \(elapsed()) initialLoad called")
        // Fetch local sessions in background — Combine sink will rematch green dots.
        Task { [weak self] in await self?.fetchSessionsUntilLoaded() }

        // Don't call loadRemoteSessions here — relay needs auth (Clerk JWT) to
        // establish WebSocket connections. Without auth, the relay creates temporary
        // connections that fail and enter a 10s×3 retry loop (~33s wasted).
        // refreshAfterAuth() handles the first real load once auth arrives.
        initialLoadTask = Task { [weak self] in
            guard let self else { return }
            log("debug_timeline \(elapsed()) loadMachinesFromAPI START (pre-auth, from cache)")
            await loadMachinesFromAPI()
            log("debug_timeline \(elapsed()) loadMachinesFromAPI END — \(machines.count) machines")
        }

        // Periodic refresh keeps lastSeenAt timestamps fresh so isOnline stays
        // accurate. Without this, machines appear offline after the TTL expires
        // because SwiftUI has no way to re-evaluate the time-based computed property.
        startMachineRefreshTimer()
        startLifecycleObservers()
    }

    /// The 30s machine poll is a UI-freshness aid — it must not keep the radio
    /// warm while the app is backgrounded. AgentScreen's willEnterForeground
    /// refresh() covers the immediate re-fetch on return.
    private func startLifecycleObservers() {
        #if os(iOS)
        guard lifecycleObservers.isEmpty else { return }
        lifecycleObservers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.stopMachineRefreshTimer() }
        })
        lifecycleObservers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.startMachineRefreshTimer() }
        })
        #endif
    }

    public func stopMachineRefreshTimer() {
        machineRefreshTimer?.invalidate()
        machineRefreshTimer = nil
    }

    private func startMachineRefreshTimer() {
        machineRefreshTimer?.invalidate()
        machineRefreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await loadMachinesFromAPI()
            }
        }
    }

    /// Called when auth token becomes available — cancels the initial retry loop
    /// and runs a fresh load with a real token.
    public func refreshAfterAuth() async {
        guard !hasRefreshedAfterAuth else { return }
        hasRefreshedAfterAuth = true
        // Cancel initialLoad if still running (just machine fetch, no relay)
        initialLoadTask?.cancel()
        initialLoadTask = nil
        await loadMachinesFromAPI()
        // Re-fetch local sessions so relay pairings (hostChatId) are up-to-date
        // before the rebuild. The push-triggered fetch may have run before the
        // relay connected, producing sessions without hostChatId dedup keys.
        await bridge.fetchSessions()
        // Load remote sessions in background — don't block the session list on relay connections.
        // loadRemoteSessions already does incremental rebuildUnifiedSessions() as each machine
        // responds, so local sessions appear immediately and remote ones trickle in.
        Task { [weak self] in
            guard let self else { return }
            await self.loadRemoteSessions(force: true)
        }
    }

    /// Called on foreground / manual refresh. Invites are not fetched here —
    /// ContentView's scenePhase handler already covers foreground, and the
    /// invite UI fetches on open.
    public func refresh() async {
        await loadMachinesFromAPI()
        await loadRemoteSessions(force: true)
    }

    // MARK: - Remote sessions

    public func loadRemoteSessions(force: Bool = false) async {
        bridge.logSessionStartMarker("ios.sessions_load_enter", extra: "force=\(force) machines=\(machines.count) isLoading=\(isLoadingRemoteSessions)")
        guard !machines.isEmpty else {
            log("loadRemoteSessions: no machines")
            bridge.logSessionStartMarker("ios.sessions_load_skip", extra: "reason=no_machines")
            return
        }
        guard !isLoadingRemoteSessions else {
            log("loadRemoteSessions: skipped (already loading)")
            bridge.logSessionStartMarker("ios.sessions_load_skip", extra: "reason=already_loading")
            return
        }
        // Cooldown: skip if last load completed < 5s ago (unless forced)
        if !force, let last = lastLoadCompleted, Date().timeIntervalSince(last) < 5 {
            log("loadRemoteSessions: skipped (cooldown, \(String(format: "%.1f", Date().timeIntervalSince(last)))s ago)")
            bridge.logSessionStartMarker("ios.sessions_load_skip", extra: "reason=cooldown")
            return
        }
        isLoadingRemoteSessions = true
        bridge.logSessionStartMarker("ios.sessions_load_start")
        defer {
            isLoadingRemoteSessions = false
            lastLoadCompleted = Date()
            bridge.logSessionStartMarker("ios.sessions_load_end")
        }

        // Refresh the tag map up front so the per-machine rebuilds below already
        // carry lozenges. Cheap (one authed request) and failure-tolerant.
        sessionTagsByKey = await bridge.getSessionTags()

        var onlineMachines = machines.filter { $0.isOnline && !$0.isDisabled(cache: cache) }
        let disabledCount = machines.filter { $0.isDisabled(cache: cache) }.count
        log("loadRemoteSessions: \(machines.count) machines (\(onlineMachines.count) online, \(disabledCount) disabled)")

        // If all machines appear offline, the cache is probably stale — refresh from API
        if onlineMachines.isEmpty && !machines.isEmpty && disabledCount < machines.count {
            log("loadRemoteSessions: all machines offline (stale cache?) — refreshing from API")
            await loadMachinesFromAPI()
            onlineMachines = machines.filter { $0.isOnline && !$0.isDisabled(cache: cache) }
            log("loadRemoteSessions: after refresh — \(machines.count) machines (\(onlineMachines.count) online)")
            if onlineMachines.isEmpty {
                log("loadRemoteSessions: still no online machines after refresh")
                return
            }
        }

        // Fetch all machines in parallel. Update per-machine so sessions from
        // not-yet-responded machines are preserved (no visual disappearance).
        await withTaskGroup(of: (String, [RemoteSessionInfo]).self) { group in
            for machine in onlineMachines {
                group.addTask {
                    let sessions = await self.bridge.listRemoteSessions(machineId: machine.machineId)
                    return (machine.displayName, sessions)
                }
            }
            for await (name, sessions) in group {
                let old = remoteSessionsByMachine[name] ?? []
                // Update per-machine store
                remoteSessionsByMachine[name] = sessions
                for s in sessions { sessionMachineNames[s.id] = name }

                // Only rebuild if this machine's data actually changed
                guard sessions != old else { continue }

                // Flatten all machines into the working array
                var flat = remoteSessionsByMachine.values.flatMap { $0 }
                if !recentlyArchivedIds.isEmpty {
                    flat.removeAll { recentlyArchivedIds.contains($0.id) }
                }
                remoteSessions = flat
                if !hasLoadedRemoteSessions {
                    hasLoadedRemoteSessions = true
                }
                rebuildUnifiedSessions()
            }
        }

        // Final check: if all machines returned empty and we had sessions before,
        // rebuild once so the list reflects the empty state.
        if remoteSessionsByMachine.values.allSatisfy({ $0.isEmpty }) && !remoteSessions.isEmpty {
            remoteSessions = []
            rebuildUnifiedSessions()
        }
    }

    // MARK: - Machines

    public func loadMachinesFromAPI() async {
        guard let token = tokenProvider() else {
            log("loadMachinesFromAPI: no auth token — skipped")
            return
        }
        guard let fetched = await MachineDirectory.fetch(token: token) else {
            // Fetch FAILED (network / non-200) — keep cache and do NOT mark
            // resolved: "unreachable" must never look like "new account".
            log("loadMachinesFromAPI: fetch failed — keeping existing \(machines.count) machines")
            return
        }
        if !hasSuccessfulMachinesResponse {
            hasSuccessfulMachinesResponse = true
            cache.set(true, forKey: "ripul.hasSuccessfulMachinesFetch")
        }
        // Don't overwrite good data with empty API responses — a transient
        // server-side gap (host past registry TTL) would wipe list AND cache.
        guard !fetched.isEmpty else {
            log("loadMachinesFromAPI: empty response — keeping existing \(machines.count) machines")
            return
        }
        if fetched != machines {
            machines = fetched
        }
        RemoteMachine.saveToCache(fetched, cache: cache)
    }

    // MARK: - Open session

    func openSession(
        _ session: UnifiedSession,
        onSelect: @escaping (ChatSession) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        openingUnifiedSessionId = session.id
        let isRemote = session.machineName != nil
        log("debug_timeline \(elapsed()) openSession: '\(session.title)' ripulSession=\(session.ripulSession != nil) cachedIsOpen=\(session.cachedIsOpen) isRemote=\(isRemote)")

        // The fast paths below (select an already-open / restored web tab
        // directly) are only safe for sessions whose history the web view can
        // restore by itself. REMOTE (relay-seeded) sessions can't: their
        // history lives only in the web view's memory — no DO subscription
        // (OOM guard), no local persistence — so after an app restart the
        // restored tab is an empty shell and only the relay open path
        // (agent:openSession → seed) can refill it. The web's
        // openRemoteSession has a warm-store check: when the chat is still
        // live it focuses instantly with NO relay round-trip, and when it's
        // cold it re-seeds. So remote taps ALWAYS route through it — never
        // through the tab-select shortcuts. (This was the "stuck spinner /
        // no history until Remove-from-Ripul" bug: re-entry taps selected
        // the cold restored tab and the re-seed path never ran.)

        // Fast path: session is already live in the web view.
        // Defer via Task so SwiftUI renders the highlighted row + spinner
        // for at least one frame before dismissing.
        if !isRemote, let ripulTab = session.ripulSession {
            // Fast path: already live in web view
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 150_000_000) // 150ms
                openingUnifiedSessionId = nil
                onSelect(ripulTab)
            }
            return
        }

        // Cached-open path: session was open before app restart.
        // Don't try relay-open — the web view will restore it.
        // Dismiss now, focus when the session appears in bridge.sessions.
        if !isRemote, session.cachedIsOpen {
            log("debug_timeline \(elapsed()) openSession: cachedIsOpen — looking for '\(session.title)' (matchKeys=\(session.matchKeys)), bridge.sessions=\(bridge.sessions.count)")

            // Build lookup keys the same way rematchLocalSessions does:
            // include stripped cli_ prefixes so "0d3319fa..." matches "cli_0d3319fa..."
            var allKeys = Set(session.matchKeys + [session.id])
            for key in session.matchKeys {
                if key.hasPrefix("cli_") { allKeys.insert(String(key.dropFirst(4))) }
            }

            // Try immediate match — bridge.sessions may already be populated
            if let tab = findBridgeSession(matchingKeys: allKeys) {
                log("debug_timeline \(elapsed()) openSession: IMMEDIATE match for '\(session.title)'")
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    openingUnifiedSessionId = nil
                    onSelect(tab)
                }
                return
            }

            // Not found yet — dismiss and poll
            onDismiss()
            Task { [weak self] in
                guard let self else { return }
                for tick in 0..<150 {  // 30s timeout (150 × 200ms)
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    if let tab = findBridgeSession(matchingKeys: allKeys) {
                        log("debug_timeline \(elapsed()) openSession: FOUND '\(session.title)' after \(tick * 200)ms wait")
                        openingUnifiedSessionId = nil
                        onSelect(tab)
                        return
                    }
                    if tick > 0 && tick % 10 == 0 {
                        log("debug_timeline \(elapsed()) openSession: still waiting for '\(session.title)' (\(tick * 200)ms, bridge.sessions=\(bridge.sessions.count))")
                    }
                }
                log("debug_timeline \(elapsed()) openSession: TIMED OUT waiting for '\(session.title)'")
                openingUnifiedSessionId = nil
            }
            return
        }

        // Remote-open path: open (or re-seed) via relay. For remote sessions
        // this is now ALSO the re-entry path — see the fast-path gating above.
        guard let machine = machines.first(where: { $0.displayName == session.machineName })
                          ?? machines.first(where: { $0.isOnline }) else {
            // No machine connectable (list still loading, or host offline).
            // If the web view has a live tab for this session, degrade to the
            // legacy tab-select so navigation still works — history may be
            // cold until it's re-tapped with the host reachable.
            if let ripulTab = session.ripulSession {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    openingUnifiedSessionId = nil
                    onSelect(ripulTab)
                }
                return
            }
            openSessionError = "No connected machine available."
            openingUnifiedSessionId = nil
            return
        }

        Task {
            let (tabId, provider, providerLabel, error) =
                await bridge.openRemoteSession(machineId: machine.machineId, sessionId: session.id, displayName: session.title)
            openingUnifiedSessionId = nil

            if let tabId {
                let isCliSession = ProviderConstants.isCliProvider(provider)
                if isCliSession {
                    let label = providerLabel ?? ProviderConstants.legacyLabel(for: provider ?? ProviderConstants.defaultCliProvider.providerKey ?? "claude-cli")
                    persistRawModeSession(tabId, provider: label)
                    await bridge.setRawMode(sessionId: tabId, enabled: true)
                }
                if let newSession = bridge.sessions.first(where: { $0.id == tabId }) {
                    onSelect(newSession)
                } else {
                    onDismiss()
                }
                await loadRemoteSessions()
            } else {
                openSessionError = error ?? "Failed to open session."
            }
        }
    }

    // MARK: - Archive session

    func archiveSession(_ session: UnifiedSession) {
        archivingUnifiedSessionId = session.id

        Task {
            defer { archivingUnifiedSessionId = nil }

            if let ripulTab = session.ripulSession {
                await bridge.closeSession(id: ripulTab.id)
            }

            if session.isCliSession {
                guard let machine = machines.first(where: { $0.displayName == session.machineName })
                                  ?? machines.first(where: { $0.isOnline }) else {
                    openSessionError = "No connected machine to archive on."
                    return
                }
                let (success, error) = await bridge.archiveRemoteSession(machineId: machine.machineId, sessionId: session.id)
                if !success {
                    openSessionError = error ?? "Archive failed."
                    return
                }
            }

            recentlyArchivedIds.insert(session.id)
            if let mn = sessionMachineNames[session.id] {
                remoteSessionsByMachine[mn]?.removeAll { $0.id == session.id }
            }
            remoteSessions.removeAll { $0.id == session.id }
            rebuildUnifiedSessions()
            await loadRemoteSessions()
        }
    }

    // MARK: - Move session to another machine

    func moveSession(_ session: UnifiedSession, to target: RemoteMachine) {
        // Use the ripul tab's id as the paired chatId if we have one; otherwise
        // fall back to the unified session id (which may be the sourceChatId).
        let sourceChatId = session.ripulSession?.id ?? session.id
        openingUnifiedSessionId = session.id

        Task {
            defer { openingUnifiedSessionId = nil }
            let (success, _, _, cwdFallback, targetName, error) = await bridge.moveSession(
                sourceChatId: sourceChatId,
                targetMachineId: target.machineId,
                displayName: session.title
            )
            if success {
                let label = targetName ?? target.displayName
                if cwdFallback {
                    openSessionError = "Moved to \(label). Original working directory not found on target — using default."
                }
                await loadRemoteSessions()
            } else {
                openSessionError = error ?? "Failed to move session."
            }
        }
    }

    // MARK: - Delete session

    /// Delete a session from Ripul. By default also archives the CLI JSONL on
    /// the remote host, which hides it from the underlying CLI (Claude Code,
    /// Codex). Pass `keepRemote: true` to leave the remote session intact so
    /// it still appears in the CLI's own session list.
    func deleteSession(_ session: UnifiedSession, keepRemote: Bool = false) {
        deletingUnifiedSessionId = session.id

        // Find the machine for any session with a remote presence
        let machineId: String? = session.machineName.flatMap { name in
            machines.first(where: { $0.displayName == name })?.machineId
                ?? machines.first(where: { $0.isOnline })?.machineId
        }
        deletingFromHost = !keepRemote && machineId != nil

        Task {
            defer {
                deletingUnifiedSessionId = nil
                deletingFromHost = false
            }

            let tabId = session.ripulSession?.id ?? session.id
            let (success, results, errors) = await bridge.deleteSession(
                tabId: tabId,
                machineId: machineId,
                remoteSessionId: session.id,
                keepRemote: keepRemote
            )

            // Remove from local state regardless of remote success
            recentlyArchivedIds.insert(session.id)
            // Also filter by all match keys so the session can't reappear under a different ID
            for key in session.matchKeys { recentlyArchivedIds.insert(key) }
            if let mn = sessionMachineNames[session.id] {
                remoteSessionsByMachine[mn]?.removeAll { $0.id == session.id }
            }
            remoteSessions.removeAll { $0.id == session.id }
            rebuildUnifiedSessions()

            if !success {
                let summary = ([
                    errors.isEmpty ? nil : "Failed:\n• " + errors.joined(separator: "\n• "),
                    results.isEmpty ? nil : "Completed:\n• " + results.joined(separator: "\n• "),
                ] as [String?]).compactMap { $0 }.joined(separator: "\n\n")
                openSessionError = "Session removed locally.\n\n\(summary)"
            }

            // Give the remote host time to process the archive before re-fetching
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await loadRemoteSessions()
        }
    }

    // MARK: - Archive (shared core)

    /// Resolve which machine owns this session for routing. Prefers the stable
    /// machineId stamped at fetch time; only falls back to "the online machine"
    /// when exactly one host is online (no ambiguity). Never routes by display
    /// name — that's how rows landed on the wrong host before.
    private func resolvedMachineId(for session: UnifiedSession) -> String? {
        if let id = session.machineId { return id }
        let online = machines.filter { $0.isOnline }
        return online.count == 1 ? online.first?.machineId : nil
    }

    /// Archive one session: close the local tab (tracked so it can't resurrect
    /// as an orphan local), archive the remote via the owning machine, and
    /// remove from the local caches. Returns a user-facing error string on
    /// failure, or nil on success. Does NOT rebuild or refetch — the caller
    /// decides when to do that (per-item vs. batched).
    @discardableResult
    private func archiveOne(_ session: UnifiedSession) async -> String? {
        if let ripulTab = session.ripulSession {
            recentlyClosedLocalIds.insert(ripulTab.id)
            await bridge.closeSession(id: ripulTab.id)
        }

        var errorMessage: String?
        if session.isCliSession {
            if let mid = resolvedMachineId(for: session) {
                let (success, error) = await bridge.archiveRemoteSession(machineId: mid, sessionId: session.id)
                if !success {
                    errorMessage = error ?? "Failed: \(session.title)"
                }
            } else {
                errorMessage = "No owning machine for: \(session.title)"
            }
        }

        recentlyArchivedIds.insert(session.id)
        if let mn = sessionMachineNames[session.id] {
            remoteSessionsByMachine[mn]?.removeAll { $0.id == session.id }
        }
        remoteSessions.removeAll { $0.id == session.id }

        return errorMessage
    }

    // MARK: - Batch archive sessions (selection path)

    func batchArchiveSessions(_ sessions: [UnifiedSession]) {
        guard !sessions.isEmpty else { return }

        Task {
            for session in sessions {
                await archiveOne(session)
            }

            rebuildUnifiedSessions()
            await loadRemoteSessions()
        }
    }

    // MARK: - Archive All sessions (with progress)

    public func startArchiveAll() {
        guard archiveAllState == nil || archiveAllState?.isComplete == true else { return }

        let sessions = unifiedSessions
        guard !sessions.isEmpty else {
            archiveAllState = ArchiveAllState(current: 0, total: 0, isComplete: true)
            return
        }

        archiveAllState = ArchiveAllState(current: 0, total: sessions.count, currentTitle: sessions.first?.title ?? "")

        Task {
            for session in sessions {
                // Pause: spin until resumed
                while archiveAllState?.isPaused == true {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }

                archiveAllState?.currentTitle = session.title

                if let error = await archiveOne(session) {
                    archiveAllState?.errors.append(error)
                }

                rebuildUnifiedSessions()
                archiveAllState?.archivedTitles.insert(session.title, at: 0)
                archiveAllState?.current += 1

                // Delay between sessions so progress is visible
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }

            archiveAllState?.isComplete = true
            await loadRemoteSessions()
        }
    }

    public func toggleArchiveAllPause() {
        archiveAllState?.isPaused.toggle()
    }

    public func clearArchiveAllState() {
        archiveAllState = nil
    }

    // MARK: - Batch delete sessions

    func batchDeleteSessions(_ sessions: [UnifiedSession]) {
        guard !sessions.isEmpty else { return }

        Task {
            for session in sessions {
                let tabId = session.ripulSession?.id ?? session.id
                if let local = session.ripulSession {
                    recentlyClosedLocalIds.insert(local.id)
                }
                let _ = await bridge.deleteSession(
                    tabId: tabId,
                    machineId: resolvedMachineId(for: session),
                    remoteSessionId: session.id
                )

                recentlyArchivedIds.insert(session.id)
                for key in session.matchKeys { recentlyArchivedIds.insert(key) }
                if let mn = sessionMachineNames[session.id] {
                    remoteSessionsByMachine[mn]?.removeAll { $0.id == session.id }
                }
                remoteSessions.removeAll { $0.id == session.id }
            }

            rebuildUnifiedSessions()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await loadRemoteSessions()
        }
    }

    // MARK: - Archived sessions

    public func loadArchivedSessions() {
        guard !isLoadingArchivedSessions else { return }
        isLoadingArchivedSessions = true

        Task {
            defer { isLoadingArchivedSessions = false }

            var all: [AgentBridge.ArchivedSessionInfo] = []
            let onlineMachines = machines.filter(\.isOnline)
            bridge.handleConsoleLog("LOG: [ARCHIVE-DEBUG] iPhone: onlineMachines=\(onlineMachines.map(\.machineId).joined(separator: ",")) totalMachines=\(machines.count)")
            for machine in onlineMachines {
                let sessions = await bridge.listArchivedSessions(machineId: machine.machineId)
                bridge.handleConsoleLog("LOG: [ARCHIVE-DEBUG] iPhone: fetched \(sessions.count) archives from machineId=\(machine.machineId) sampleMachineId=\(sessions.first?.machineId ?? "nil")")
                all.append(contentsOf: sessions)
            }
            all.sort { $0.archivedAt > $1.archivedAt }
            archivedSessions = all
        }
    }

    public func restoreArchivedSession(_ session: AgentBridge.ArchivedSessionInfo) {
        restoringArchivedSessionId = session.id

        Task {
            defer { restoringArchivedSessionId = nil }

            guard let sourceMachineId = session.machineId else {
                openSessionError = "Archive is missing its source machine — please refresh the archived sessions list."
                return
            }
            guard let machine = machines.first(where: { $0.machineId == sourceMachineId }) else {
                openSessionError = "The machine that owns this archive is not connected."
                return
            }
            guard machine.isOnline else {
                openSessionError = "\(machine.displayName) is offline — bring it online to restore this archive."
                return
            }
            let (success, error) = await bridge.restoreArchivedSession(machineId: machine.machineId, sessionId: session.id)
            if success {
                archivedSessions.removeAll { $0.id == session.id }
                await loadRemoteSessions()
            } else {
                openSessionError = error ?? "Restore failed."
            }
        }
    }

    public func deleteArchivedSession(_ session: AgentBridge.ArchivedSessionInfo) {
        Task {
            guard let sourceMachineId = session.machineId else {
                openSessionError = "Archive is missing its source machine — please refresh the archived sessions list."
                return
            }
            guard let machine = machines.first(where: { $0.machineId == sourceMachineId }) else {
                openSessionError = "The machine that owns this archive is not connected."
                return
            }
            guard machine.isOnline else {
                openSessionError = "\(machine.displayName) is offline — bring it online to delete this archive."
                return
            }
            let (success, error) = await bridge.deleteArchivedSession(machineId: machine.machineId, sessionId: session.id)
            if success {
                archivedSessions.removeAll { $0.id == session.id }
            } else {
                openSessionError = error ?? "Delete failed."
            }
        }
    }

    public func batchDeleteArchivedSessions(_ sessions: [AgentBridge.ArchivedSessionInfo]) {
        guard !sessions.isEmpty else { return }
        Task {
            var failures: [String] = []
            for session in sessions {
                guard let sourceMachineId = session.machineId,
                      let machine = machines.first(where: { $0.machineId == sourceMachineId }),
                      machine.isOnline else {
                    failures.append(session.displayName)
                    continue
                }
                let (success, error) = await bridge.deleteArchivedSession(machineId: machine.machineId, sessionId: session.id)
                if success {
                    archivedSessions.removeAll { $0.id == session.id }
                } else {
                    failures.append("\(session.displayName): \(error ?? "unknown error")")
                }
            }
            if !failures.isEmpty {
                openSessionError = "Failed to delete \(failures.count) archive\(failures.count == 1 ? "" : "s"):\n• " + failures.joined(separator: "\n• ")
            }
        }
    }

    // MARK: - Connect to machine

    func connect(
        to machine: RemoteMachine,
        onSelect: @escaping (ChatSession) -> Void,
        onDismiss: @escaping () -> Void
    ) async {
        guard machine.isOnline else {
            connectError = "\(machine.displayName) is offline."
            return
        }
        connectingMachineId = machine.machineId
        let (tabId, error) = await bridge.connectToMachine(machineId: machine.machineId)
        connectingMachineId = nil

        if let tabId, let session = bridge.sessions.first(where: { $0.id == tabId }) {
            onSelect(session)
        } else if tabId != nil {
            onDismiss()
        } else {
            connectError = error ?? "Failed to connect."
        }
    }

    /// Connect to a machine in CLI provider mode.
    /// providerKey is e.g. "claude-cli", "codex-cli", "antigravity-cli".
    func connectWithProvider(
        _ providerKey: String,
        to machine: RemoteMachine,
        onSelect: @escaping (ChatSession) -> Void,
        onDismiss: @escaping () -> Void
    ) async {
        guard machine.isOnline else {
            connectError = "\(machine.displayName) is offline."
            return
        }
        connectingMachineId = machine.machineId
        let (tabId, error) = await bridge.connectToMachineWithProvider(machineId: machine.machineId, providerKey: providerKey)
        connectingMachineId = nil

        if let tabId {
            let label = ProviderConstants.byProviderKey(providerKey)?.displayLabel ?? providerKey
            persistRawModeSession(tabId, provider: label)
            if let session = bridge.sessions.first(where: { $0.id == tabId }) {
                onSelect(session)
            } else {
                onDismiss()
            }
            await loadRemoteSessions()
        } else {
            connectError = error ?? "Failed to connect."
        }
    }

    func restartMachine(_ machine: RemoteMachine) async {
        restartingMachineId = machine.machineId

        async let webKill = bridge.killMachine(machineId: machine.machineId, reason: "remote_restart")
        async let httpKill = requestKillViaAPI(machineId: machine.machineId, reason: "remote_restart")
        let (webResult, httpResult) = await (webKill, httpKill)

        guard webResult.success || httpResult else {
            restartingMachineId = nil
            connectError = webResult.error ?? "Failed to restart host."
            return
        }

        // The WebSocket killAck is sent by the guardian only AFTER the process
        // death is confirmed — with it, "online again" proves a real restart.
        // The KV path (httpKill) merely ENQUEUES a signal, so on that path a
        // host that never went down would immediately read as "online" and the
        // old code showed "Restarted" for a restart that never happened (a
        // stale guardian silently dropping kills). Without a confirmed kill,
        // require an observed offline→online transition before claiming success.
        let killConfirmed = webResult.success
        let deadline = Date().addingTimeInterval(60)
        var wentOffline = false
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await refresh()
            guard let updated = machines.first(where: { $0.machineId == machine.machineId }) else {
                wentOffline = true // vanished from the list = down
                continue
            }
            if !updated.isOnline {
                wentOffline = true
            } else if killConfirmed || wentOffline {
                restartingMachineId = nil
                restartSucceededId = machine.machineId
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if restartSucceededId == machine.machineId { restartSucceededId = nil }
                }
                return
            }
        }

        restartingMachineId = nil
        connectError = wentOffline
            ? "Host went down but didn't come back online within 60 seconds."
            : "Host never went offline — the restart likely didn't execute (host guardian may be stale). Try again after relaunching the host app."
    }

    // MARK: - Rebuild (imperative — no .onChange)

    /// Rebuild unified sessions from current remote + local data.
    /// Called directly after every mutation — never from `.onChange`.
    private func rebuildUnifiedSessions() {
        // Guard: don't overwrite cache with local-only data before remote loads
        if remoteSessions.isEmpty && !hasLoadedRemoteSessions && !unifiedSessions.isEmpty {
            rematchLocalSessions()
            return
        }

        // Prune recentlyClosedLocalIds entries whose ChatSession is already gone
        // from bridge.sessions — they no longer affect rendering and we don't
        // want the set to grow unboundedly.
        let liveLocalIds = Set(bridge.sessions.map(\.id))
        recentlyClosedLocalIds = recentlyClosedLocalIds.intersection(liveLocalIds)

        let updated = UnifiedSession.build(
            from: remoteSessions,
            localSessions: bridge.sessions,
            machineNames: sessionMachineNames,
            recentlyClosedLocalIds: recentlyClosedLocalIds,
            tagsByKey: sessionTagsByKey
        )

        // Skip publish + cache if nothing changed — keeps the list visually stable
        guard updated != unifiedSessions else { return }

        unifiedSessions = updated

        // Cache: persist once we've confirmed remote data is real, or when
        // all remote sessions have been deleted (empty is a valid state).
        if hasLoadedRemoteSessions {
            UnifiedSession.saveToCache(updated, cache: cache)
        }
    }

    /// Re-match ripulSession on cached items without full rebuild.
    private func rematchLocalSessions() {
        let beforeOpen = unifiedSessions.filter(\.isOpenInRipul).count
        var localByKey: [String: ChatSession] = [:]
        for s in bridge.sessions {
            localByKey[s.id] = s
            localByKey[s.sourceChatId] = s
            let stripped = s.sourceChatId.hasPrefix("cli_")
                ? String(s.sourceChatId.dropFirst(4))
                : s.sourceChatId
            localByKey[stripped] = s
            if let host = s.hostChatId {
                localByKey[host] = s
                if host.hasPrefix("cli_") {
                    localByKey[String(host.dropFirst(4))] = s
                }
            }
        }
        var updated = unifiedSessions
        var changed = false
        for i in updated.indices {
            var match: ChatSession?
            for key in updated[i].matchKeys {
                if let found = localByKey[key] {
                    match = found
                    break
                }
            }
            if match == nil { match = localByKey[updated[i].id] }
            let matchChanged = match?.id != updated[i].ripulSession?.id
            let nameChanged = match != nil && match?.displayName != updated[i].title
            if matchChanged || nameChanged {
                updated[i] = UnifiedSession(
                    id: updated[i].id, title: match?.displayName ?? updated[i].title,
                    lastUsed: updated[i].lastUsed, gitBranch: updated[i].gitBranch,
                    messageCount: updated[i].messageCount, projectName: updated[i].projectName,
                    provider: updated[i].provider, providerLabel: updated[i].providerLabel,
                    machineName: updated[i].machineName, machineId: updated[i].machineId,
                    matchKeys: updated[i].matchKeys,
                    ripulSession: match
                )
                changed = true
            }
        }
        if changed {
            let afterOpen = updated.filter(\.isOpenInRipul).count
            log("debug_timeline \(elapsed()) rematchLocalSessions: \(beforeOpen) → \(afterOpen) open (from \(bridge.sessions.count) bridge sessions)")
            unifiedSessions = updated
        }
    }

    // MARK: - Helpers

    /// True when `bridge.sessions` holds a local session that has no row in the
    /// current unified list — e.g. a chat just created in the web app. Such a
    /// session can't be surfaced by `rematchLocalSessions` (which only updates
    /// existing rows), so its presence means we need a full rebuild. Sessions we
    /// just closed locally are ignored — they're intentionally hidden until the
    /// web app drops the tab.
    private func hasUnrepresentedLocalSession() -> Bool {
        let representedLocalIds = Set(unifiedSessions.compactMap { $0.ripulSession?.id })
        for s in bridge.sessions where !recentlyClosedLocalIds.contains(s.id) {
            if !representedLocalIds.contains(s.id) { return true }
        }
        return false
    }

    /// Find a bridge session matching any of the given keys, using the same
    /// cli_ prefix stripping that rematchLocalSessions uses.
    private func findBridgeSession(matchingKeys allKeys: Set<String>) -> ChatSession? {
        for s in bridge.sessions {
            if allKeys.contains(s.id) || allKeys.contains(s.sourceChatId) { return s }
            let stripped = s.sourceChatId.hasPrefix("cli_")
                ? String(s.sourceChatId.dropFirst(4)) : s.sourceChatId
            if allKeys.contains(stripped) { return s }
            if let host = s.hostChatId {
                if allKeys.contains(host) { return s }
                if host.hasPrefix("cli_"), allKeys.contains(String(host.dropFirst(4))) { return s }
            }
        }
        return nil
    }

    private func fetchSessionsUntilLoaded() async {
        log("debug_timeline \(elapsed()) fetchSessionsUntilLoaded START")

        // Fast path: web app already signalled sessions:ready
        if bridge.isSessionsReady {
            log("debug_timeline \(elapsed()) fetchSessionsUntilLoaded: sessions already ready (push)")
            await bridge.fetchSessions()
            log("debug_timeline \(elapsed()) fetchSessionsUntilLoaded END — \(bridge.sessions.count) sessions (push, immediate)")
            return
        }

        // Wait for the push signal from the web app (sessions:ready).
        // This replaces the old 2-second polling loop with a reactive approach:
        // the web app fires sessions:ready as soon as CachedStorage is initialized,
        // and we fetch immediately — eliminating up to 2s of polling latency.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var resumed = false
            sessionsReadyCancellable = bridge.$isSessionsReady
                .filter { $0 }
                .first()
                .sink { [weak self] _ in
                    guard !resumed else { return }
                    resumed = true
                    self?.log("debug_timeline \(self?.elapsed() ?? "?") fetchSessionsUntilLoaded: sessions:ready push received")
                    continuation.resume()
                }

            // Fallback: if the push never arrives (e.g. old web app version),
            // resume after 5s so we don't block forever.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !resumed else { return }
                resumed = true
                self?.log("debug_timeline \(self?.elapsed() ?? "?") fetchSessionsUntilLoaded: fallback timeout (5s)")
                continuation.resume()
            }
        }

        await bridge.fetchSessions()

        // If sessions are still empty (web app not fully ready), do a few retries.
        var attempts = 0
        while bridge.sessions.isEmpty && attempts < 5 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { break }
            await bridge.fetchSessions()
            attempts += 1
            log("debug_timeline \(elapsed()) fetchSessionsUntilLoaded retry \(attempts) — bridge.sessions=\(bridge.sessions.count)")
        }
        log("debug_timeline \(elapsed()) fetchSessionsUntilLoaded END — \(bridge.sessions.count) sessions after \(attempts) retries")

        // Clean up any ephemeral commit-viewer tabs left by a previous
        // app-kill. Now that the web view is ready, close them and clear
        // the persisted set so they never appear in the sessions list.
        await bridge.cleanupStaleEphemeralSessions()
    }

    private func log(_ msg: String) {
        // Route startup timeline logs to bridge console with [STARTUP] prefix
        // so they interleave cleanly with web-side [STARTUP] events.
        if msg.contains("debug_timeline") {
            let detail = msg.replacingOccurrences(of: "debug_timeline ", with: "")
            bridge.handleConsoleLog("LOG: [STARTUP] \(detail)")
        }
    }

    private func persistRawModeSession(_ tabId: String, provider: String) {
        var rawSessions = Set(cache.stringArray(forKey: "ripulRawModeSessions") ?? [])
        rawSessions.insert(tabId)
        cache.set(Array(rawSessions), forKey: "ripulRawModeSessions")

        var providers = cache.dictionary(forKey: "ripulSessionProviders") as? [String: String] ?? [:]
        providers[tabId] = provider
        cache.set(providers, forKey: "ripulSessionProviders")
    }

    private func requestKillViaAPI(machineId: String, reason: String) async -> Bool {
        guard let token = tokenProvider() else { return false }
        let encodedId = machineId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? machineId
        guard let url = URL(string: "\(AgentConfiguration.defaultBaseURL.absoluteString)/api/v1/relay/machines/\(encodedId)/kill") else {
            return false
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["reason": reason])
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    func toggleMachineDisabled(_ machine: RemoteMachine) {
        let newState = !machine.isDisabled(cache: cache)
        RemoteMachine.setDisabled(machine.machineId, disabled: newState, cache: cache)
        log("machine '\(machine.displayName)' \(newState ? "DISABLED" : "ENABLED")")
        // Trigger UI update via machines re-publish
        objectWillChange.send()
    }

    public func buildSessionProviders() -> [String: String] {
        var map = cache.dictionary(forKey: "ripulSessionProviders") as? [String: String] ?? [:]
        for session in bridge.sessions {
            if let label = session.providerLabel {
                map[session.id] = label
            }
        }
        return map
    }
}
