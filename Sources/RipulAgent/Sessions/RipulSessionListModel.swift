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

    /// Stable error-code prefix the web app stamps on open failures where the
    /// host PROVED the session is gone (deleted or archived there) — see
    /// `AgentOpenSessionResponse.errorCode` in relayProtocol.ts. AgentBridge
    /// prefixes the human message with `code: `, so a prefix match classifies
    /// without string-sniffing the message itself.
    private static let sessionNotFoundPrefix = "session-not-found:"

    // MARK: - Published (view observes these)

    @Published public private(set) var unifiedSessions: [UnifiedSession]
    @Published public private(set) var machines: [RemoteMachine] = []
    /// True once a machines fetch has SUCCEEDED at least once on this install
    /// (persisted). The embedded first-run onboarding must not appear before
    /// this: an empty list ahead of the first successful fetch means "offline /
    /// not loaded yet", not "new account" — otherwise bad connectivity drops
    /// returning users onto the marketing cards.
    @Published public private(set) var hasSuccessfulMachinesResponse: Bool = false
    /// Per-window startup fact; a persisted successful fetch is not current auth readiness.
    @Published public private(set) var hasCompletedAuthRefresh = false
    @Published public private(set) var isLoadingRemoteSessions = false
    @Published public var openingUnifiedSessionId: String?
    @Published public var archivingUnifiedSessionId: String?
    @Published public var deletingUnifiedSessionId: String?
    @Published public var leavingUnifiedSessionId: String?
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

    /// Remote sessions grouped by machineId — source of truth.
    /// Preserves sessions from not-yet-responded machines during incremental
    /// refresh. Keyed by the stable machineId, NEVER display name: names
    /// collide by default ("Mac", "My Machine") and are mutable, so name keys
    /// let two machines overwrite each other's buckets — which read as chats
    /// "moving" between machines. Display names are derived at rebuild time.
    private var remoteSessionsByMachineId: [String: [RemoteSessionInfo]] = [:]
    /// Flattened view of `remoteSessionsByMachineId`, minus archived IDs.
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

    /// How many rebuilds ran during the current `loadRemoteSessions` pass, and
    /// how long they held the main actor. Reset per pass, reported on
    /// `ios.sessions_load_end` — the before/after signal for rebuild coalescing.
    private var rebuildCount = 0
    private var rebuildElapsed: TimeInterval = 0

    /// Debug switch restoring the pre-coalescing behaviour: one full rebuild per
    /// answering machine. Exists so the two can be compared on-device without a
    /// rebuild of the app, against identical machine and session counts.
    public static let perMachineRebuildKey = "sessionListPerMachineRebuild"

    /// Facts signature last folded into `unifiedSessions`. Empty on launch, so
    /// the first sink carrying any published facts forces one rebuild.
    private var lastAppliedFactsSignature: String = ""
    private var lastLoadCompleted: Date?
    private var initialLoadTask: Task<Void, Never>?
    private var sessionOpenTask: Task<Void, Never>?
    private var sessionOpenRequestID: UUID?
    private var hasRefreshedAfterAuth = false

    // MARK: - Dependencies

    private let bridge: AgentBridge
    private let tokenProvider: () -> String?
    private let cache: RipulSessionCache
    private let dataSource: (any RipulSessionDataSource)?
    public var usesDirectConnections: Bool { dataSource != nil }
    private var sessionsCancellable: AnyCancellable?
    private var sessionsReadyCancellable: AnyCancellable?
    private var lastActiveTimeCancellable: AnyCancellable?
    private var savedLastActiveTimes: [String: Date]?
    private var machineRefreshTimer: Timer?
    private var lifecycleObservers: [NSObjectProtocol] = []

    private static let lastActiveTimeCacheKey = "ripulLastActiveTimeByChatId"
    /// Resolved last-active times keyed by UnifiedSession.id — stable across
    /// restarts (unlike chatId which requires ripulSession to resolve).
    private static let lastActiveBySessionIdCacheKey = "ripulLastActiveBySessionId"
    @Published public private(set) var lastActiveBySessionId: [String: Date] = [:]
    /// Last remote scan result per machine. Persisted so a launch starts from
    /// the last known inputs rather than from nothing — see
    /// `restoreRemoteSessionsFromCache`. v2: keyed by machineId; the old
    /// name-keyed cache (and its companion `ripulSessionMachineNames` map,
    /// which was last-writer-wins and never pruned) is abandoned, not
    /// migrated — display names can't be re-keyed to ids safely.
    private static let remoteSessionsCacheKey = "ripulRemoteSessionsByMachineIdV2"

    // MARK: - Init

    private let startupTime = CFAbsoluteTimeGetCurrent()

    public init(bridge: AgentBridge, tokenProvider: @escaping () -> String?, cache: RipulSessionCache,
                dataSource: (any RipulSessionDataSource)? = nil) {
        self.bridge = bridge
        self.tokenProvider = tokenProvider
        self.cache = cache
        self.dataSource = dataSource

        self.machines = RemoteMachine.loadCached(cache: cache)
        self.hasSuccessfulMachinesResponse =
            cache.bool(forKey: "ripul.hasSuccessfulMachinesFetch")

        let cached = UnifiedSession.loadCached(cache: cache)
        let openCount = cached.filter(\.cachedIsOpen).count
        self.unifiedSessions = cached
        log("debug_timeline \(elapsed()) init: \(cached.count) cached sessions (\(openCount) cachedIsOpen), bridge.sessions=\(bridge.sessions.count)")

        // Restore the last remote scan per machine. The unified list is derived
        // from these inputs, so without them the first rebuild of the launch
        // rebuilds from an EMPTY remote set and every row that isn't an open
        // local tab disappears until its machine answers.
        restoreRemoteSessionsFromCache()

        // Restore persisted last-active timestamps so sort order is
        // correct immediately on launch, before any live events arrive.
        // Two caches: chatId-keyed (feeds bridge for live lookups) and
        // sessionId-keyed (stable across restarts, used on cold start
        // before ripulSession is matched).
        if let data = cache.data(forKey: Self.lastActiveTimeCacheKey),
           let dict = try? JSONDecoder().decode([String: Date].self, from: data) {
            bridge.sessionList.lastActiveTimeByChatId = dict
            savedLastActiveTimes = dict
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
                //
                // Facts (project / branch / model, published over SessionChannel)
                // need the same escape hatch for a different reason: they land
                // AFTER the row exists — a guest joins, the row is built, and the
                // DO delivers them a moment later — and they change neither the
                // id nor the title, which is all `rematchLocalSessions` watches.
                // `withRipulSession` also carries the row's own gitBranch across
                // verbatim, so even a triggered rematch keeps the nil. Without
                // this the row stayed blank until a relaunch rebuilt it.
                let factsSignature = currentFactsSignature()
                if hasUnrepresentedLocalSession() || factsSignature != lastAppliedFactsSignature {
                    lastAppliedFactsSignature = factsSignature
                    rebuildUnifiedSessions()
                } else {
                    rematchLocalSessions()
                }
            }

        // Persist last-active timestamps whenever they change.
        // Throttled to avoid excessive writes during rapid tool calls.
        lastActiveTimeCancellable = bridge.sessionList.lastActiveTimeSubject
            .removeDuplicates()
            .throttle(for: .seconds(2), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] dict in
                self?.saveLastActiveTimes(dict)
            }

        // Also save when app goes to background — the throttle might not
        // have flushed yet when the system kills the process.
        #if os(iOS)
        lifecycleObservers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.saveLastActiveTimes(bridge.sessionList.lastActiveTimeByChatId)
        })
        #endif
    }

    private func saveLastActiveTimes(_ dict: [String: Date]) {
        // Save the raw chatId-keyed dict for bridge restore.
        if savedLastActiveTimes != dict, let data = try? JSONEncoder().encode(dict) {
            cache.set(data, forKey: Self.lastActiveTimeCacheKey)
            savedLastActiveTimes = dict
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
        guard updated != lastActiveBySessionId else { return }
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
        hasCompletedAuthRefresh = true
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
        if dataSource != nil { await loadDirectSessions(); return }
        await loadMachinesFromAPI()
        // A user with no reachable machine (an invited guest, or an owner whose
        // Mac is asleep) has exactly one live source of rows: the web app's tab
        // list. `loadRemoteSessions` returns at its no-machines guard without
        // touching it, so without this a foreground refresh did nothing.
        if scannableMachines.isEmpty { await bridge.fetchSessions() }
        await loadRemoteSessions(force: true)
    }

    // MARK: - Remote sessions

    public func loadRemoteSessions(force: Bool = false) async {
        if dataSource != nil { await loadDirectSessions(); return }
        bridge.logSessionStartMarker("ios.sessions_load_enter", extra: "force=\(force) machines=\(machines.count) isLoading=\(isLoadingRemoteSessions)")
        guard !machines.isEmpty else {
            log("loadRemoteSessions: no machines")
            bridge.logSessionStartMarker("ios.sessions_load_skip", extra: "reason=no_machines")
            // Nothing to wait for: the tab list is the truth. Build (and
            // persist) from it now rather than on some later publish.
            rebuildUnifiedSessions()
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
        // No `sessions_load_start` marker: it fired on the same millisecond as
        // `sessions_load_enter` directly above and carried no field of its own.
        // `enter` says a pass began, `_skip` says why one didn't, `_end` carries
        // the timings — a fourth line in that sequence is pure duplication.
        // Rebuild accounting for THIS pass. `rebuildMs` is what the main actor —
        // and therefore touch delivery — actually lost to rebuilding, and
        // `changed` is how many machines came back with new data: the number the
        // per-machine path runs one rebuild for. Coalesced, `rebuilds` should
        // read 1 against a `changed` of however many machines answered.
        rebuildCount = 0
        rebuildElapsed = 0
        var changedMachines = 0
        let passStarted = Date()
        defer {
            isLoadingRemoteSessions = false
            lastLoadCompleted = Date()
            bridge.logSessionStartMarker(
                "ios.sessions_load_end",
                extra: "rebuilds=\(rebuildCount)"
                    + " changed=\(changedMachines)"
                    + " rebuildMs=\(Int(rebuildElapsed * 1000))"
                    + " passMs=\(Int(Date().timeIntervalSince(passStarted) * 1000))"
                    + " rows=\(unifiedSessions.count)"
            )
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
                // Same as having no machine: no scan can arrive, so settle the
                // list from the tab list instead of leaving it frozen.
                rebuildUnifiedSessions()
                return
            }
        }

        // Rebuild once per PASS, not once per machine — unless there is nothing
        // on screen yet.
        //
        // The per-machine rebuild exists so a slow machine can't leave the list
        // looking empty while it is still being waited on. That only buys
        // anything when the list has no rows to show; once rows are up (every
        // foreground refresh, and any launch seeded from cache) each answering
        // machine re-ran the whole rebuild — derivedMachineNames, then
        // UnifiedSession.build over EVERY session of EVERY machine, a merge map
        // over every existing row, and two whole-collection JSON encodes — all
        // on the main actor, M times for M machines.
        //
        // Foreground is where that bites hardest: every machine's timestamps
        // have moved while the app was away, so none of them take the no-change
        // bail and the amplification is at full strength exactly when the user
        // is tapping. UIKit delivers touches on the main thread, so the cost is
        // not merely a slow list — it is an app that ignores input until the
        // last machine's rebuild has drained.
        //
        // The debug key forces the old per-machine behaviour back on, so the
        // two can be A/B'd on-device against the SAME machine count and session
        // count — the only way the before/after is a measurement rather than an
        // extrapolation. Same pattern as `suppressSessionListUpdates`.
        let forcePerMachine = cache.bool(forKey: Self.perMachineRebuildKey)
        let progressive = unifiedSessions.isEmpty || forcePerMachine
        var pendingRebuild = false

        // Fetch all machines in parallel. Update per-machine so sessions from
        // not-yet-responded machines are preserved (no visual disappearance).
        await withTaskGroup(of: (String, [RemoteSessionInfo]).self) { group in
            for machine in onlineMachines {
                group.addTask {
                    let sessions = await self.bridge.listRemoteSessions(machineId: machine.machineId)
                    return (machine.machineId, sessions)
                }
            }
            for await (machineId, sessions) in group {
                let old = remoteSessionsByMachineId[machineId] ?? []
                // Update per-machine store — only a machine's own answer may
                // replace its bucket.
                remoteSessionsByMachineId[machineId] = sessions

                // A machine answered — that's what this flag means, and it has
                // to be set before the no-change bail below. Since the launch
                // now starts from the CACHED scan results, the first response
                // often matches what we already had; leaving the flag false in
                // that case stopped the row cache from ever being rewritten.
                if !hasLoadedRemoteSessions {
                    hasLoadedRemoteSessions = true
                }

                // Only rebuild if this machine's data actually changed
                guard sessions != old else { continue }
                changedMachines += 1

                if progressive {
                    reflowRemoteSessions()
                    rebuildUnifiedSessions()
                } else {
                    pendingRebuild = true
                }
            }
        }

        if pendingRebuild {
            reflowRemoteSessions()
            rebuildUnifiedSessions()
        }

        // Final check: if all machines returned empty and we had sessions before,
        // rebuild once so the list reflects the empty state. (The coalesced
        // rebuild above already reflowed to empty in that case, so this only
        // fires on the progressive path or when nothing was marked dirty.)
        if remoteSessionsByMachineId.values.allSatisfy({ $0.isEmpty }) && !remoteSessions.isEmpty {
            remoteSessions = []
            rebuildUnifiedSessions()
        }
    }

    /// Flatten every machine's bucket into the working array, minus anything
    /// archived out from under us. O(all sessions) — which is why the pass above
    /// runs it once rather than per answering machine.
    private func reflowRemoteSessions() {
        var flat = remoteSessionsByMachineId.values.flatMap { $0 }
        if !recentlyArchivedIds.isEmpty {
            flat.removeAll { recentlyArchivedIds.contains($0.id) }
        }
        remoteSessions = flat
    }

    // MARK: - Machines

    public func loadMachinesFromAPI() async {
        if dataSource != nil { await loadDirectSessions(); return }
        guard let token = tokenProvider() else {
            log("loadMachinesFromAPI: no auth token — skipped")
            return
        }
        guard let fetched = await MachineDirectory.fetch(token: token) else {
            // Fetch FAILED (network / non-200) — keep cache and do NOT mark
            // resolved: "unreachable" must never look like "new account".
            //
            // Report how OLD the kept cache is, not just how big. A record past
            // the 5-minute liveness TTL reads as offline, which takes every
            // machine out of the session scan — "keeping 1 machines" looks
            // healthy while describing data that is days stale and inert.
            let oldest = machines.map(\.lastSeenAt).min() ?? "n/a"
            log("loadMachinesFromAPI: fetch failed — keeping existing \(machines.count) machines "
                + "(oldest lastSeenAt=\(oldest), online=\(machines.filter(\.isOnline).count))")
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
            // An account with no reachable machine has just had that
            // confirmed. Rows built from the tab list before this answer
            // arrived may not have been persisted yet; a rebuild now writes them.
            if scannableMachines.isEmpty { rebuildUnifiedSessions() }
            return
        }
        if fetched != machines {
            machines = fetched
        }
        RemoteMachine.saveToCache(fetched, cache: cache)
    }

    // MARK: - Open session

    private func loadDirectSessions() async {
        guard let dataSource, !isLoadingRemoteSessions else { return }
        isLoadingRemoteSessions = true
        defer { isLoadingRemoteSessions = false }
        do {
            let snapshot = try await dataSource.load()
            let retained = Set(snapshot.machines.map(\.machineId))
            remoteSessionsByMachineId = remoteSessionsByMachineId.filter { retained.contains($0.key) }
            for (machine, sessions) in snapshot.sessionsByMachineID where retained.contains(machine) {
                remoteSessionsByMachineId[machine] = sessions
            }
            machines = snapshot.machines
            hasSuccessfulMachinesResponse = true
            hasLoadedRemoteSessions = true
            remoteSessions = remoteSessionsByMachineId.values.flatMap { $0 }
            RemoteMachine.saveToCache(machines, cache: cache)
            cache.set(true, forKey: "ripul.hasSuccessfulMachinesFetch")
            rebuildUnifiedSessions()
        } catch {
            connectError = error.localizedDescription
        }
    }

    func openSession(
        _ session: UnifiedSession,
        onSelect: @escaping @MainActor (ChatSession) async -> Void,
        onDismiss: @escaping () -> Void
    ) {
        // Repeated taps on the same request are harmless. A DIFFERENT row is
        // new intent, not a duplicate: cancel the old continuation immediately.
        guard openingUnifiedSessionId != session.id else { return }
        sessionOpenTask?.cancel()
        let requestID = UUID()
        sessionOpenRequestID = requestID
        openingUnifiedSessionId = session.id
        bridge.navigatingToSessionId = nil
        openSessionError = nil
        bridge.logSessionStartMarker("ios.open_session_start", extra: "sessionId=\(session.id)")
        sessionOpenTask = Task { [weak self] in
            guard let self else { return }
            defer {
                // An old request must not clear the newer row's spinner.
                if sessionOpenRequestID == requestID {
                    openingUnifiedSessionId = nil
                    sessionOpenTask = nil
                    sessionOpenRequestID = nil
                }
            }
            do {
                try Task.checkCancellation()
                guard let tab = try await prepareSession(session) else { return }
                try Task.checkCancellation()
                // Keep ownership through focus/readiness and the native slide.
                // The callback runs in this task so cancellation reaches it too.
                await onSelect(tab)
                try Task.checkCancellation()
                if dataSource == nil, session.machineName != nil {
                    // Catch up after the slide, as before. These chat-scoped
                    // writes must not hold the opening indicator or block taps.
                    Task { [weak self] in
                        guard let self else { return }
                        if let modelId = SessionModelSelectionCache.modelId(cache: cache, session: session, liveTabId: tab.id) {
                            _ = await bridge.setChatModel(chatId: tab.sourceChatId, modelId: modelId)
                        }
                        await loadRemoteSessions()
                    }
                }
            } catch is CancellationError {
                bridge.logSessionStartMarker("ios.open_session_superseded", extra: "sessionId=\(session.id)")
            } catch {
                guard !Task.isCancelled else { return }
                reportOpenSessionFailure(error.localizedDescription, session: session)
            }
        }
    }

    /// Load a tab without selecting it. Remote JS may outlive Swift cancellation;
    /// it must never focus a chat as a side effect of finishing an older load.
    private func prepareSession(_ session: UnifiedSession) async throws -> ChatSession? {
        if let dataSource { return try await dataSource.open(session, bridge: bridge) }
        let isRemote = session.machineName != nil

        // Remote tabs must still use the relay warm/cold history check. A
        // restored remote tab can be an empty shell after a webview restart.
        if !isRemote, let tab = session.ripulSession { return tab }
        if !isRemote, session.cachedIsOpen {
            var allKeys = Set(session.matchKeys + [session.id])
            for key in session.matchKeys where key.hasPrefix("cli_") {
                allKeys.insert(String(key.dropFirst(4)))
            }
            if let tab = findBridgeSession(matchingKeys: allKeys) { return tab }
            for _ in 0..<150 {
                try await Task.sleep(nanoseconds: 200_000_000)
                if let tab = findBridgeSession(matchingKeys: allKeys) { return tab }
            }
            reportOpenSessionFailure("session-restore-timeout: \"\(session.title)\" didn't finish restoring. Try opening it again.", session: session)
            return nil
        }

        // Only the owning host may load this history. An already-live tab is
        // still usable when that host cannot currently be resolved.
        guard let ownerMachineId = resolvedMachineId(for: session) else {
            if let tab = session.ripulSession { return tab }
            reportOpenSessionFailure(
                "machine-unavailable: " + (session.machineName.map { "\"\($0)\" isn't connected — this chat lives there." }
                    ?? "This chat's machine isn't connected."), session: session)
            return nil
        }
        let (tabId, provider, providerLabel, error) = await bridge.openRemoteSession(
            machineId: ownerMachineId, sessionId: session.id, displayName: session.title, focus: false)
        try Task.checkCancellation()
        guard let tabId else {
            if let error, error.hasPrefix(Self.sessionNotFoundPrefix) {
                if let tabId = session.ripulSession?.id { recentlyClosedLocalIds.insert(tabId) }
                recentlyArchivedIds.insert(session.id)
                for key in session.matchKeys { recentlyArchivedIds.insert(key) }
                removeFromRemoteBuckets(sessionId: session.id)
                remoteSessions.removeAll { $0.id == session.id }
                rebuildUnifiedSessions()
                let message = String(error.dropFirst(Self.sessionNotFoundPrefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                reportOpenSessionFailure(Self.sessionNotFoundPrefix + " " + (message.isEmpty
                    ? "This session was deleted on its host machine. The entry has been removed."
                    : message), session: session)
            } else {
                reportOpenSessionFailure(error ?? "Failed to open session.", session: session)
            }
            return nil
        }
        if ProviderConstants.isCliProvider(provider) {
            let label = providerLabel ?? ProviderConstants.legacyLabel(for: provider ?? ProviderConstants.defaultCliProvider.providerKey ?? "claude-cli")
            persistRawModeSession(tabId, provider: label)
            await bridge.setRawMode(sessionId: tabId, enabled: true)
            try Task.checkCancellation()
        }
        var tab = bridge.sessions.first { $0.id == tabId }
        if tab == nil {
            await bridge.fetchSessions()
            try Task.checkCancellation()
            tab = bridge.sessions.first { $0.id == tabId }
        }
        guard let tab else {
            reportOpenSessionFailure("session-open-incomplete: \"\(session.title)\" couldn't be loaded after the host opened it. Try again.", session: session)
            return nil
        }
        return tab
    }

    private func reportOpenSessionFailure(_ error: String, session: UnifiedSession) {
        openSessionError = error
        bridge.handleConsoleLog("ERROR: [SESSION-OPEN] sessionId=\(session.id) machineId=\(session.machineId ?? "unknown") error=\(error)")
        bridge.logSessionStartMarker("ios.open_session_failed", extra: "sessionId=\(session.id) error=\(error)")
    }

    // MARK: - Archive session

    func archiveSession(_ session: UnifiedSession) {
        guard dataSource == nil else { return }
        archivingUnifiedSessionId = session.id

        Task {
            defer { archivingUnifiedSessionId = nil }

            if let ripulTab = session.ripulSession {
                await bridge.closeSession(id: ripulTab.id)
            }

            if session.isCliSession {
                // Owner only — archiving via "any online machine" hit the
                // wrong disk whenever the owner was the machine that was off.
                guard let ownerMachineId = resolvedMachineId(for: session) else {
                    openSessionError = session.machineName.map { "\"\($0)\" isn't connected — archive this chat when it's back." }
                        ?? "This chat's machine isn't connected."
                    return
                }
                let (success, error) = await bridge.archiveRemoteSession(machineId: ownerMachineId, sessionId: session.id)
                if !success {
                    openSessionError = error ?? "Archive failed."
                    return
                }
            }

            recentlyArchivedIds.insert(session.id)
            removeFromRemoteBuckets(sessionId: session.id)
            remoteSessions.removeAll { $0.id == session.id }
            rebuildUnifiedSessions()
            await loadRemoteSessions()
        }
    }

    // MARK: - Invited chats (share-link guest sessions)
    //
    // A chat reached only through someone else's accepted share invitation has
    // no host machine of our own to archive or delete against — `archiveSession`
    // and `deleteSession` are shaped around owning a machine, and routing a
    // guest session through them either short-circuits before removing the row
    // (archiveSession, when `isCliSession` is true and no owning machine
    // resolves — the local tab was already closed, but the in-memory list
    // never learns that, so the row sits there until the app relaunches) or
    // depends on host-side steps that mean nothing for a chat we don't own.
    // These two methods are the whole story for an invited chat: no machine
    // resolution, no early return, no owner-shaped side effects.

    /// Hide an invited chat locally. Membership is untouched — reopening the
    /// same invitation brings it right back with full history.
    func removeInvitedSession(_ session: UnifiedSession) {
        guard dataSource == nil else { return }
        guard let tabId = session.ripulSession?.id else { return }
        Task {
            await bridge.closeSession(id: tabId)
            recentlyArchivedIds.insert(session.id)
            for key in session.matchKeys { recentlyArchivedIds.insert(key) }
            removeFromRemoteBuckets(sessionId: session.id)
            remoteSessions.removeAll { $0.id == session.id }
            rebuildUnifiedSessions()
        }
    }

    /// End an invited chat's membership (needs a fresh owner invitation to
    /// rejoin), then hide it locally. The only guest-side action that is
    /// actually destructive — the caller is expected to confirm first.
    func leaveInvitedSession(_ session: UnifiedSession) {
        guard dataSource == nil else { return }
        guard let tabId = session.ripulSession?.id else { return }
        leavingUnifiedSessionId = session.id
        Task {
            defer { leavingUnifiedSessionId = nil }
            let (success, error) = await bridge.leaveSharedChat(id: tabId)
            guard success else {
                openSessionError = error ?? "Couldn't leave this chat."
                return
            }
            recentlyArchivedIds.insert(session.id)
            for key in session.matchKeys { recentlyArchivedIds.insert(key) }
            removeFromRemoteBuckets(sessionId: session.id)
            remoteSessions.removeAll { $0.id == session.id }
            rebuildUnifiedSessions()
        }
    }

    // MARK: - Move session to another machine

    func moveSession(_ session: UnifiedSession, to target: RemoteMachine) {
        guard dataSource == nil else { return }
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
        guard dataSource == nil else { return }
        deletingUnifiedSessionId = session.id

        // Find the OWNING machine for any session with a remote presence.
        // nil (owner offline/unknown) degrades to a local-only delete rather
        // than archiving on whichever other machine happened to be online.
        let machineId: String? = resolvedMachineId(for: session)
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

            if success {
            // Remove only after the requested deletion succeeded
            recentlyArchivedIds.insert(session.id)
            // Also filter by all match keys so the session can't reappear under a different ID
            for key in session.matchKeys { recentlyArchivedIds.insert(key) }
            removeFromRemoteBuckets(sessionId: session.id)
            remoteSessions.removeAll { $0.id == session.id }
            rebuildUnifiedSessions()

            }

            if !success {
                let summary = ([
                    errors.isEmpty ? nil : "Failed:\n• " + errors.joined(separator: "\n• "),
                    results.isEmpty ? nil : "Completed:\n• " + results.joined(separator: "\n• "),
                ] as [String?]).compactMap { $0 }.joined(separator: "\n\n")
                openSessionError = "Couldn't delete this session.\n\n\(summary)"
            }

            // Give the remote host time to process the archive before re-fetching
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await loadRemoteSessions()
        }
    }

    // MARK: - Archive (shared core)

    /// Resolve which machine OWNS this session for routing. The stable
    /// machineId stamped at fetch time is the address; display name resolves
    /// only legacy rows that predate the stamp. NEVER guesses beyond that:
    /// the old "exactly one machine online" fallback fired precisely when one
    /// of two machines went offline and routed the op to the survivor — and
    /// the "any online machine" guards that used to sit at the open/archive/
    /// delete call sites did the same. Unresolvable owner = nil; callers
    /// degrade honestly (error, or local-only) instead of guessing.
    private func resolvedMachineId(for session: UnifiedSession) -> String? {
        if let id = session.machineId { return id }
        if let name = session.machineName {
            return machines.first(where: { $0.displayName == name })?.machineId
        }
        return nil
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
        removeFromRemoteBuckets(sessionId: session.id)
        remoteSessions.removeAll { $0.id == session.id }

        return errorMessage
    }

    /// Remove a session row from EVERY machine bucket by id. Attribution-proof
    /// on purpose: the old form looked the bucket up through the (global,
    /// last-writer-wins) id→name map, so a mis-attributed row was removed from
    /// the wrong bucket and resurrected from the right one on the next rebuild.
    private func removeFromRemoteBuckets(sessionId: String) {
        for key in remoteSessionsByMachineId.keys {
            remoteSessionsByMachineId[key]?.removeAll { $0.id == sessionId }
        }
    }

    // MARK: - Batch archive sessions (selection path)

    func batchArchiveSessions(_ sessions: [UnifiedSession]) {
        guard dataSource == nil else { return }
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
        guard dataSource == nil else { return }
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
        guard dataSource == nil else { return }
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
                removeFromRemoteBuckets(sessionId: session.id)
                remoteSessions.removeAll { $0.id == session.id }
            }

            rebuildUnifiedSessions()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await loadRemoteSessions()
        }
    }

    // MARK: - Archived sessions

    public func loadArchivedSessions() {
        guard dataSource == nil else { return }
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
        guard dataSource == nil else { return }
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
        guard dataSource == nil else { return }
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
        guard dataSource == nil else { return }
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
        onSelect: @escaping @MainActor (ChatSession) async -> Void,
        onDismiss: @escaping () -> Void
    ) async {
        guard machine.isOnline else {
            connectError = "\(machine.displayName) is offline."
            return
        }
        connectingMachineId = machine.machineId
        bridge.logSessionStartMarker("ios.tap", extra: "source=connect machine=\(machine.machineId)")
        let (tabId, error) = await bridge.connectToMachine(machineId: machine.machineId)
        connectingMachineId = nil

        if let tabId, let session = bridge.sessions.first(where: { $0.id == tabId }) {
            await onSelect(session)
        } else if tabId != nil {
            onDismiss()
        } else {
            connectError = error ?? "Failed to connect."
        }
    }

    /// Connect to a machine in CLI provider mode.
    /// providerKey is e.g. "claude-cli", "codex-cli", "antigravity-cli".
    /// - Parameter modelId: Catalog model to pin the new session to. Passed by
    ///   the model-aligned quick-start strip; nil from harness-shaped entry
    ///   points, which take the provider default.
    func connectWithProvider(
        _ providerKey: String,
        modelId: String? = nil,
        to machine: RemoteMachine,
        onSelect: @escaping @MainActor (ChatSession) async -> Void,
        onDismiss: @escaping () -> Void
    ) async {
        guard machine.isOnline else {
            connectError = "\(machine.displayName) is offline."
            return
        }
        connectingMachineId = machine.machineId
        bridge.logSessionStartMarker("ios.tap", extra: "source=connectWithProvider provider=\(providerKey) model=\(modelId ?? "default")")
        let (tabId, error) = await bridge.connectToMachineWithProvider(machineId: machine.machineId, providerKey: providerKey, modelId: modelId)
        connectingMachineId = nil

        if let tabId {
            let label = ProviderConstants.byProviderKey(providerKey)?.displayLabel ?? providerKey
            persistRawModeSession(tabId, provider: label)
            if let session = bridge.sessions.first(where: { $0.id == tabId }) {
                await onSelect(session)
            } else {
                onDismiss()
            }
            await loadRemoteSessions()
        } else {
            connectError = error ?? "Failed to connect."
        }
    }

    func restartMachine(_ machine: RemoteMachine) async {
        guard dataSource == nil else { return }
        restartingMachineId = machine.machineId

        async let webKill = bridge.killMachine(machineId: machine.machineId, reason: "remote_restart")
        async let httpKill = requestKillViaAPI(machineId: machine.machineId, reason: "remote_restart")
        let (webResult, httpResult) = await (webKill, httpKill)

        guard webResult.success || httpResult else {
            restartingMachineId = nil
            connectError = webResult.error ?? "Failed to restart host."
            return
        }

        // NEITHER result proves the host died. Both channels end in the same
        // HTTP POST that stores a kill signal in KV: `webResult` is the web
        // app's killMachine, which returns success the moment that POST
        // returns 200, and `httpKill` is this model making the same POST
        // directly. The guardian does send a real `machine:killAck` after
        // confirming process death, but nothing correlates it back to a
        // request — so success here means "signal enqueued", nothing more.
        //
        // An enqueued signal that no guardian ever reads looks identical to a
        // completed restart if you only check that the host is online. So the
        // only honest evidence is an observed offline→online transition, and
        // that is what we require.
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
            } else if wentOffline {
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

    // MARK: - Remote input cache

    /// Persist the per-machine scan results the unified list is derived from.
    /// Called from the same place as the unified-row cache, so archive, delete
    /// and move all flow through it.
    private func saveRemoteSessionsToCache() {
        if let data = try? JSONEncoder().encode(remoteSessionsByMachineId) {
            cache.set(data, forKey: Self.remoteSessionsCacheKey)
        }
    }

    /// Seed `remoteSessionsByMachineId` from the previous launch so rows
    /// survive until their owning machine actually answers. Only that machine
    /// may retract its own sessions.
    ///
    /// Machines that have left the account, or that the user disabled, are
    /// dropped — both are evidence of absence and must not outlive a relaunch.
    /// `hasLoadedRemoteSessions` deliberately stays false: this data renders,
    /// but it isn't confirmed, so it doesn't get written back to the cache
    /// until a live scan replaces it.
    private func restoreRemoteSessionsFromCache() {
        guard let data = cache.data(forKey: Self.remoteSessionsCacheKey),
              var byMachine = try? JSONDecoder().decode([String: [RemoteSessionInfo]].self, from: data)
        else { return }

        if !machines.isEmpty {
            let visible = Set(machines.filter { !$0.isDisabled(cache: cache) }.map(\.machineId))
            byMachine = byMachine.filter { visible.contains($0.key) }
        }
        remoteSessionsByMachineId = byMachine
        remoteSessions = byMachine.values.flatMap { $0 }
        log("debug_timeline \(elapsed()) restored \(remoteSessions.count) remote sessions across \(byMachine.count) machines")
    }

    /// Display names derived FRESH from the buckets on every rebuild — never a
    /// long-lived map. The old `sessionMachineNames` was global, last-writer-
    /// wins across machines, never pruned, and persisted across launches, so a
    /// single duplicate echo re-attributed a session's machine label forever.
    /// A machine absent from the registry contributes no name; coalescing then
    /// keeps the row's previously-known label.
    private func derivedMachineNames() -> [String: String] {
        var names: [String: String] = [:]
        for (machineId, list) in remoteSessionsByMachineId {
            guard let display = machines.first(where: { $0.machineId == machineId })?.displayName else { continue }
            for s in list {
                names[s.id] = display
            }
        }
        return names
    }

    // MARK: - Rebuild (imperative — no .onChange)

    /// Rebuild unified sessions from current remote + local data.
    /// Called directly after every mutation — never from `.onChange`.
    ///
    /// Timing wrapper. The rebuild is the main actor's largest single cost on a
    /// foreground refresh, and it is invoked from a dozen call sites — so what
    /// matters is not one rebuild's duration but how many run per load pass and
    /// what they add up to. Both are reported on `ios.sessions_load_end`.
    private func rebuildUnifiedSessions() {
        let started = Date()
        performRebuildUnifiedSessions()
        rebuildCount += 1
        rebuildElapsed += Date().timeIntervalSince(started)
    }

    /// Whether the remote scan has said everything it is going to say for now.
    ///
    /// `hasLoadedRemoteSessions` flips only when a machine answers. A user with
    /// NO machines — an invited guest with the app but no Mac — never gets
    /// that answer, so on its own the flag stayed false for the life of the
    /// process. Every rebuild then degraded to a rematch (which cannot add a
    /// row, so a chat joined in-run never appeared until relaunch) and the row
    /// cache was never written (so every launch started from an empty list).
    /// A successful machines fetch that returned none IS the settled answer:
    /// the local tab list is the whole truth for that account.
    private var remoteScanSettled: Bool {
        // No machine that could answer a scan — none known, or every known one
        // offline or disabled — means the tab list is the whole truth right
        // now. Deliberately not gated on the machines fetch having succeeded,
        // and not on `machines.isEmpty` alone: the machines cache is never
        // cleared by an empty registry answer (an owner's offline Mac must
        // keep its row), so a device that was once signed in as an owner can
        // carry a stale machine record for ever. That record answers nothing,
        // and waiting on it froze the list. An owner's scan supersedes these
        // rows the moment a machine really answers.
        hasLoadedRemoteSessions || scannableMachines.isEmpty
    }

    /// Machines a scan could actually reach right now.
    private var scannableMachines: [RemoteMachine] {
        machines.filter { $0.isOnline && !$0.isDisabled(cache: cache) }
    }

    /// True once the current `unifiedSessions` has been written to the row
    /// cache under a settled scan. Rows built BEFORE the scan settled were
    /// never persisted, and if nothing changed afterwards they never would
    /// be — every launch then started empty.
    private var rowsPersisted = false

    private func performRebuildUnifiedSessions() {
        // One line per decision, on the bridge console, so a list that stays
        // empty or frozen on a device says WHY without a debugger attached.
        log("debug_timeline \(elapsed()) rebuild: settled=\(remoteScanSettled) loaded=\(hasLoadedRemoteSessions)"
            + " machines=\(machines.count) scannable=\(scannableMachines.count) remote=\(remoteSessions.count)"
            + " local=\(bridge.sessions.count) rows=\(unifiedSessions.count)")
        // Guard: don't overwrite cache with local-only data before remote loads.
        // Rows the scan has not confirmed stay as they are — but a local tab
        // with NO row at all (a chat just joined or created) is appended
        // regardless: nothing about a pending scan justifies hiding it.
        if remoteSessions.isEmpty && !remoteScanSettled && !unifiedSessions.isEmpty {
            rematchLocalSessions()
            appendUnrepresentedLocalRows()
            return
        }

        // Prune recentlyClosedLocalIds entries whose ChatSession is already gone
        // from bridge.sessions — they no longer affect rendering and we don't
        // want the set to grow unboundedly.
        let liveLocalIds = Set(bridge.sessions.map(\.id))
        recentlyClosedLocalIds = recentlyClosedLocalIds.intersection(liveLocalIds)

        let built = UnifiedSession.build(
            from: remoteSessions,
            localSessions: dataSource == nil ? bridge.sessions : bridge.sessions.filter { tab in
                remoteSessions.contains { $0.sourceChatId == tab.sourceChatId || $0.hostChatId == tab.id }
            },
            machineNames: derivedMachineNames(),
            recentlyClosedLocalIds: recentlyClosedLocalIds,
            tagsByKey: sessionTagsByKey
        )

        // Merge each freshly-built row over the row it replaces, so a source
        // that doesn't carry a field can't blank it. `build` is a total
        // function of whatever inputs have arrived, and at launch they arrive
        // one at a time — without this, every partial input publishes a
        // complete-looking row whose unknown fields read as "gone".
        //
        // Row *existence* is untouched: a row build didn't emit is still
        // dropped, so archive / delete / host-side removal land immediately.
        var previousByKey: [String: UnifiedSession] = [:]
        for row in unifiedSessions {
            for key in row.mergeKeys where previousByKey[key] == nil {
                previousByKey[key] = row
            }
        }
        // Read once, not once per row: resolving a pick used to re-read (and
        // re-bridge from the plist) the whole picker dictionary for every row.
        let pickedModels = SessionModelSelectionCache.loadMap(cache: cache)
        let updated = built.map { row -> UnifiedSession in
            let previous = row.mergeKeys.lazy.compactMap { previousByKey[$0] }.first
            let merged = row.coalescing(
                over: previous,
                keepTagsWhenEmpty: sessionTagsByKey.isEmpty,
                keepOpenFlagWhenUnmatched: !bridge.isSessionsReady
            )
            return applyPickedModel(merged, pickedModels: pickedModels)
        }

        // Skip publish if nothing changed — keeps the list visually stable.
        // The cache write below is NOT skipped on that account: rows built
        // before the scan settled still need persisting once it has.
        let changed = updated != unifiedSessions
        if changed { unifiedSessions = updated }

        // Cache: persist once we've confirmed remote data is real, or when
        // all remote sessions have been deleted (empty is a valid state), or
        // when there is no machine to scan and the tab list is the truth.
        if remoteScanSettled && (changed || !rowsPersisted) {
            UnifiedSession.saveToCache(updated, cache: cache)
            saveRemoteSessionsToCache()
            rowsPersisted = true
        } else if changed {
            rowsPersisted = false
        }
    }

    /// Overlay the user's explicit model pick onto a row.
    ///
    /// The host scanner reports the model of the LAST ASSISTANT MESSAGE, so a
    /// fresh pick doesn't show up until the session has answered once more.
    /// The picker cache is the authoritative record of what it will answer
    /// with next, and is what the open path re-applies on resume. Applied only
    /// when the picked id resolves to a known family, so an unrecognised
    /// catalog id can't replace a good scanned value with a raw string.
    private func applyPickedModel(
        _ row: UnifiedSession,
        pickedModels: [String: String]
    ) -> UnifiedSession {
        guard let picked = SessionModelSelectionCache.modelId(
                map: pickedModels, session: row, liveTabId: row.ripulSession?.id),
              picked != row.model,
              ModelIdentity.resolve(modelId: picked) != nil
        else { return row }
        return row.withModel(picked)
    }

    /// Re-run the rebuild so a just-made model pick shows on the rows without
    /// waiting for the next scan. Cheap: the rebuild bails when nothing moved.
    public func refreshPickedModelSelections() {
        rebuildUnifiedSessions()
    }

    /// Rows for local tabs the list does not represent at all, built from the
    /// tabs alone and appended. Used on the path where the full rebuild is
    /// withheld (scan not settled, cached rows to protect): the cached rows
    /// stay untouched, and a chat the user just joined still shows up.
    private func appendUnrepresentedLocalRows() {
        let represented = Set(unifiedSessions.compactMap { $0.ripulSession?.id })
        let fresh = bridge.sessions.filter {
            !represented.contains($0.id) && !recentlyClosedLocalIds.contains($0.id)
        }
        guard !fresh.isEmpty else { return }
        // A cached remote row can already name the tab's conversation by one of
        // its keys while awaiting its scan; that is a match for the rematch
        // pass, not a new row.
        let known = Set(unifiedSessions.flatMap(\.mergeKeys))
        let additions = UnifiedSession.build(
            from: [], localSessions: fresh, machineNames: [:],
            recentlyClosedLocalIds: recentlyClosedLocalIds, tagsByKey: sessionTagsByKey
        ).filter { Set($0.mergeKeys).isDisjoint(with: known) }
        guard !additions.isEmpty else { return }
        log("debug_timeline \(elapsed()) appended \(additions.count) local row(s) ahead of the scan")
        unifiedSessions = (unifiedSessions + additions).sorted { $0.lastUsed > $1.lastUsed }
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
            // A local name may only overwrite a scan-derived title when it is a
            // REAL title — source "cli" (JSONL custom-title) or "user" (a Ripul
            // rename awaiting round-trip). Source "auto" is a descriptor name or
            // a date fallback: no better than the scan's answer, and letting it
            // win is what made rows alternate between the two, since this path
            // and `build` fire on different triggers and kept overwriting each
            // other. A row with no scan row behind it (an orphan local) has no
            // competing source, so it always accepts its tab's name.
            let localTitleIsReal = match?.displayNameSource.map { $0 == "cli" || $0 == "user" } ?? true
            let mayRetitle = localTitleIsReal || !updated[i].titleFromScan
            let nameChanged = match != nil && mayRetitle && match?.displayName != updated[i].title
            // A row with no scan behind it has its tab as the ONLY source of
            // provider and model. A share-link guest's tab learns its model
            // from SessionChannel facts long after the row was built, so the
            // row must follow the tab when those move — carrying the old nil
            // across verbatim is what kept the default icon until relaunch.
            let tabFactsChanged = match.map { updated[i].tabFactsDiffer(from: $0) } ?? false
            if matchChanged || nameChanged || tabFactsChanged {
                // Carry every other field across verbatim. This path knows
                // about tabs and nothing else — re-deriving the row from its
                // parts here is how `model` (and project path, tags and
                // metadataKey) used to get blanked on the way through.
                // `title: nil` keeps the existing one. Required, not cosmetic:
                // this branch also runs when only the MATCH changed, and passing
                // the local name unconditionally would apply it right past the
                // gate above.
                var row = updated[i].withRipulSession(match, title: mayRetitle ? match?.displayName : nil)
                if tabFactsChanged, let match { row = row.adoptingTabFacts(match) }
                updated[i] = row
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

    /// Fingerprint of every published fact currently on `bridge.sessions`.
    ///
    /// Rebuilding is driven by a CHANGE in this, deliberately, rather than by
    /// "a row still has no branch". The latter never settles: a remote row whose
    /// scan legitimately found no branch would rebuild on every sink tick,
    /// forever. A signature converges — once the facts stop moving, so do we.
    private func currentFactsSignature() -> String {
        bridge.sessions
            .filter { $0.projectName != nil || $0.gitBranch != nil || $0.model != nil || $0.provider != nil }
            .map { "\($0.id)|\($0.projectName ?? "")|\($0.gitBranch ?? "")|\($0.model ?? "")|\($0.provider ?? "")|\($0.providerLabel ?? "")" }
            .sorted()
            .joined(separator: ";")
    }

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
        // "Empty" means the WEB answered empty or with an error — not merely
        // that the disk cache is empty. The bridge keeps its cached array on an
        // empty reply without publishing, so a cache-seeded launch whose first
        // web answer was `0 live descriptors` used to stop here with a list
        // that never rebuilt.
        // Fifteen seconds covers a cold web view still hydrating its stores
        // on an older phone; the loop stops the moment a real list arrives.
        var attempts = 0
        while (bridge.sessions.isEmpty || bridge.lastSessionsError != nil) && attempts < 15 {
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
