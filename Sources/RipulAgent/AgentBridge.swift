import Combine
import Observation
import Foundation
import Network
import WebKit
#if canImport(UIKit)
import UIKit
#endif

private let protocolVersion = "1.0.0"
private let messagePrefix = "agent-framework:"

// MARK: - Native logging that reaches the log tools

/// Drop-in replacements for `NSLog` that ALSO append to the `RipulLog` buffer
/// `device_console_logs` / `host_console_logs` read — so native diagnostics are
/// readable by the tools, not just in Xcode/Console. Prefer these over a bare
/// `NSLog` for any native log worth surfacing. They tee to the OS log too, so a
/// message emitted before the bridge exists is still visible in Xcode.
///
/// The sink is `RipulLog`, NOT `AgentBridge.current`. It used to be the latter,
/// and everything written through these helpers was liable to vanish: `current`
/// is the most-recently-INITIALIZED bridge, so in an app that builds more than
/// one (the chat surface plus the dev console) it can point at a bridge whose
/// `consoleLogs` no reader ever merges. Proven on device — `VoiceModeController`
/// logged `[VOICE] start` through `handleConsoleLog` and the capture edges
/// through `nlog`, from the same function, and only the former ever arrived.
/// `RipulLog` is owned by nobody, lives from module load, and is merged by both
/// `ConsoleLogsTool` and the relay's `getConsoleLogs` responder.
///
/// Synchronous, like `RipulLog.append` itself: a line emitted microseconds
/// before a crash is already in the buffer. The old `Task { @MainActor }` hop
/// meant the last thing logged before a hang was the first thing lost.
public func nlog(_ message: String) {
    Foundation.NSLog("%@", message)   // Foundation.* bypasses the NSLog tee shadow (no double-append)
    RipulLog.shared.append("[native] \(message)", level: .log)
}
public func nwarn(_ message: String) {
    Foundation.NSLog("%@", message)
    RipulLog.shared.append("[native] \(message)", level: .warn)
}
public func nerror(_ message: String) {
    Foundation.NSLog("%@", message)
    RipulLog.shared.append("[native] \(message)", level: .error)
}

/// Which audience an `AgentBridge` channel serves. Fixed for the bridge's
/// lifetime in practice (set at construction): a channel is either the app's
/// end-user agent surface (`.endUser`, the default — `AgentView`'s bridges)
/// or the developer console / DevTools surface (`.developer` —
/// `RipulAgentConsole`, the dev-assistant overlay).
///
/// This is the hard, structural half of the one-way tool valve: a
/// `.endUser` channel can never expose a tool marked `RipulDeveloperOnlyTool`,
/// regardless of how it was registered. There is deliberately no override —
/// see docs/plans/native-tool-registry/phase-0-hard-gate-and-decision-record.md.
public enum RipulChannelAudience {
    case endUser
    case developer
}

@MainActor
@Observable
public final class AgentBridge: NSObject {
    /// Immutable for the bridge's lifetime — assigned in the designated
    /// initializer before `super.init()`. See `RipulChannelAudience`.
    public let composerContexts = RipulComposerContextStore()
    public let audience: RipulChannelAudience

    /// The host's tool registry this channel projects from. The bridge OWNS no
    /// tools (channel-bound built-ins aside) — it exposes
    /// `registry.entries(audience:)` for its exposed audiences. See
    /// `RipulToolRegistry`.
    public let registry: RipulToolRegistry

    /// Which registry audiences this channel exposes. Fixed at construction to
    /// the channel's own audience; phase 2 (absorption) widens a `.developer`
    /// channel's set on an explicit session-scoped opt-in
    /// (`setEndUserTesting`). Never widened on an `.endUser` channel — there
    /// is deliberately no API to do so. Published so the console's testing
    /// toggle reflects the live state.
    public private(set) var exposedAudiences: Set<RipulToolAudience>

    /// Assign a @Published value only when it differs. A write fires
    /// objectWillChange even when the value is identical, and this bridge is
    /// observed by the app's largest views (ContentView, RipulAgentScreen) —
    /// each needless write is a full re-render, ~50-120ms on iPhone, and the
    /// ones on session switch / send land mid-animation. Use this for any
    /// write that can repeat the current value (web echoes, polls, fetches).
    @inline(__always)
    func setIfChanged<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<AgentBridge, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    // Combine streams for the three tracked properties that have Combine
    // subscribers (what `$sessions` etc. provided under @Published): the
    // current value on subscribe, then every change.
    @ObservationIgnored private let sessionsStream = PropertyStream<[ChatSession]>()
    @ObservationIgnored private let isSessionsReadyStream = PropertyStream<Bool>()
    @ObservationIgnored private let activeSessionIdStream = PropertyStream<String?>()
    public var sessionsPublisher: AnyPublisher<[ChatSession], Never> { sessionsStream.publisher(current: sessions) }
    public var isSessionsReadyPublisher: AnyPublisher<Bool, Never> { isSessionsReadyStream.publisher(current: isSessionsReady) }
    public var activeSessionIdPublisher: AnyPublisher<String?, Never> { activeSessionIdStream.publisher(current: activeSessionId) }

    public var isConnected = false
    /// Set once by AgentWebView's navigationDelegate on the first `didFinish` for
    /// this bridge's web view. StandaloneFileViewer keeps its webview hidden
    /// (opacity 0, native black/white canvas showing through) until this flips,
    /// then fades it in — the page's own theme/background is already painted by
    /// didFinish, so the fade-in shows no WKWebView-internal white pre-paint
    /// surface (see docs/runbooks/file-viewer-entry-flash-handover.md). Unused by
    /// the main chat web view.
    public var didFinishFirstNavigation = false
    /// Per-thread native CPU sampler (this app process only, not WebKit).
    /// Off by default; a Settings toggle drives `start()`/`stop()`. Spikes are
    /// routed to the bridge console so they show up in `host_console_logs`.
    public let cpuSampler = CpuSampler()
    /// When true, native host UI (e.g. the session list) freezes to save resources
    /// while the host serves remotely. Written by HostRenderSuspensionController on
    /// macOS; mirrors the web "Suspend Host Session Rendering" flag.
    public var hostRenderSuspended = false
    public var isThemeReady = false
    /// Fires once when the web app's CachedStorage is initialized and
    /// `__ripulGetSessions` will return real data. Used by SessionManager
    /// to replace the 2-second polling loop with a push-triggered fetch.
    public var isSessionsReady = false { didSet { isSessionsReadyStream.send(isSessionsReady) } }
    public var wantsMinimize = false
    /// Set to true to request the Console Log viewer sheet. AgentView observes
    /// this and presents the sheet, then resets the flag.
    public var wantsShowConsoleLogs = false
    /// Set to true to request the View Inspector overlay. AgentView observes
    /// this and presents the overlay, then resets the flag.
    public var wantsShowViewInspector = false
    /// Set to true to request the Plan Review screen. AgentView observes this
    /// and presents the sheet, then resets the flag.
    public var wantsShowPlanReview = false
    public var sessions: [ChatSession] = ChatSession.loadCached() { didSet { sessionsStream.send(sessions) } }
    /// Tab IDs of ephemeral commit-viewer sessions that should be excluded
    /// from the sessions list. Managed by CommitsScreen (insert on open)
    /// and AgentScreen (remove on back-nav / close).
    /// Persisted to UserDefaults so app-kill during viewing doesn't leak tabs.
    @ObservationIgnored public private(set) var ephemeralSessionIds: Set<String> = {
        let arr = UserDefaults.standard.stringArray(forKey: "ripulEphemeralSessionIds") ?? []
        return Set(arr)
    }()

    private static let ephemeralKey = "ripulEphemeralSessionIds"

    private func persistEphemeralIds() {
        UserDefaults.standard.set(Array(ephemeralSessionIds), forKey: Self.ephemeralKey)
    }

    public func markSessionEphemeral(_ id: String) {
        ephemeralSessionIds.insert(id)
        persistEphemeralIds()
    }

    public func unmarkSessionEphemeral(_ id: String) {
        ephemeralSessionIds.remove(id)
        persistEphemeralIds()
    }

    /// When true, the native chat input is hidden even if the page context
    /// says to show it. Used by the commit viewer to enforce read-only mode.
    public var suppressNativeChatInput: Bool = false

    /// Close any ephemeral tabs left over from a previous session (e.g. app
    /// was killed while viewing a commit). Call once after the web view is ready.
    public func cleanupStaleEphemeralSessions() async {
        let stale = ephemeralSessionIds
        guard !stale.isEmpty else { return }
        NSLog("[AgentBridge] Cleaning up %d stale ephemeral session(s)", stale.count)
        for id in stale {
            await closeSession(id: id)
        }
        ephemeralSessionIds.removeAll()
        persistEphemeralIds()
    }

    public var activeSessionId: String? {
        didSet {
            guard activeSessionId != oldValue else { return }
            activeSessionIdStream.send(activeSessionId)
            // Entering a session by ANY route is reading it — the sessions
            // list, a deep link, a notification tap, Siri, the switcher. This
                // used to hang off focusSession alone, which is only one of
            // them, so sessions opened another way stayed unread by eye.
            if let id = activeSessionId { markSessionRead(id) }
            markActiveSessionTodoViewedInList()
            // The pause/play buttons are a projection of the ACTIVE chat's
            // phase — any change of active session must re-derive them.
            refreshActiveAgentFlags()
        }
    }

    /// The currently-active ChatSession, derived from `activeSessionId` and `sessions`.
    public var activeSession: ChatSession? {
        guard let activeSessionId else { return nil }
        return sessions.first(where: { $0.id == activeSessionId })
    }

    /// True when the active session is a Claude Code CLI session.
    /// Used to gate Plan/Edit-mode UI, which only applies to claude-cli.
    public var isActiveSessionClaudeCli: Bool {
        activeSession?.provider == "claude-cli"
    }
    public var lastSessionsError: String?
    /// Kept for source compatibility — no longer used for transitions.
    public var isSwitchingSession = false
    /// Set to the session id being navigated to; cleared to nil after the slide
    /// animation completes. SessionsListSections uses this to keep the row spinner
    /// running until the animation is done (not just until focusSession starts).
    /// Lives on navigationStore so writes don't fire bridge.objectWillChange.
    public var navigatingToSessionId: String? {
        get { navigationStore.navigatingToSessionId }
        set { navigationStore.navigatingToSessionId = newValue }
    }
    // Scroll-to-bottom button state lives in its OWN ObservableObject (NOT @Published
    // on the bridge) so that crossing the bottom threshold while scrolling does not
    // invalidate AgentView. AgentView hosts the WKWebView; re-rendering it on the
    // app main thread mid-scroll stalls the web view's scroll (proven by isolating
    // this exact post). Only the small button overlay observes scrollButton.
    public let scrollButton = ScrollButtonModel()
    /// Text to prefill in the native chat input (set by welcome card / prompt suggestion clicks).
    public var pendingInputText: String?
    /// Text to append to the native chat input without replacing existing content.
    public var pendingInputAppend: String?
    public var availableModels: [ModelInfo] = []
    public var selectedModelId: String?
    public var selectedEffort: String?   // CLI reasoning effort override (nil = default)
    public var modelSelectionEnabled: Bool = true
    public var lastModelsError: String?

    // MARK: Read state

    // The rules for what waits, what reads and what is pinned are in
    // AgentBridge+ReadState.swift. Only what has to be stored is here.

    /// Newest response preview per chat, harvested from `agent:activity`.
    /// In-memory: it only has to survive until the turn ends and the waiting
    /// entry is written, which is moments later.
    @ObservationIgnored var lastResponsePreviewByChatId: [String: String] = [:]

    /// The once-per-launch sweep for waiting entries with no reply has run.
    @ObservationIgnored var hasSweptWaitingReplies = false

    /// Whether the app is frontmost, as reported by the host's scene phase.
    ///
    /// A plain flag rather than reading `UIApplication.shared.applicationState`
    /// — that needs main-thread isolation and this is consulted from the phase
    /// writer, which is not guaranteed to be there. The host already knows the
    /// answer and tells us either way.
    @ObservationIgnored public internal(set) var appIsForeground = true

    // MARK: Sticky model

    /// Set by the host app so the bridge can persist session-list metadata for
    /// sessions IT creates. The sticky CLI path starts a session without
    /// `RipulSessionListModel` in the loop, so the raw-mode flag and provider
    /// label have to be written from here. Optional because an embedding host
    /// (WAC's dev console) may not run the session list at all.
    @ObservationIgnored public var sessionCache: RipulSessionCache? {
        didSet {
            restoreModelCatalogue()
            publishPinnedKeys()
        }
    }
    /// Model-catalogue fetch in flight. Lives in its own store: the flag flips
    /// true/false on every fetch (two re-renders across an await), and on the
    /// bridge that meant two ContentView + RipulAgentScreen passes per fetch
    /// for a spinner only the quick-launch strips show. Observe `modelLoading`
    /// (e.g. via `ModelLoadingReader`) where the spinner is drawn.
    public let modelLoading = RipulModelLoadingState()
    /// Snapshot read; not observable. See `modelLoading`.
    public var isLoadingModels: Bool { modelLoading.isLoading }
    @ObservationIgnored private var modelCacheUserId: String?
    @ObservationIgnored private var modelCacheGeneration = 0
    @ObservationIgnored private var modelRefreshPending = false

    /// The host supplies its persisted account on startup and updates it on
    /// authentication changes. Embedded hosts that omit this use no disk cache.
    public func setModelCatalogueAccount(_ userId: String?) {
        guard userId != modelCacheUserId else { return }
        if let previous = modelCacheUserId {
            sessionCache?.removeObject(forKey: "ripul.models.v1.\(previous)")
        }
        modelCacheUserId = userId
        modelCacheGeneration += 1
        availableModels = []
        selectedModelId = nil
        lastModelsError = nil
        restoreModelCatalogue()
        if isLoadingModels {
            modelRefreshPending = true
        } else if userId != nil, webView != nil {
            Task { await fetchModels() }
        }
    }

    private func restoreModelCatalogue() {
        guard let userId = modelCacheUserId,
              let data = sessionCache?.data(forKey: "ripul.models.v1.\(userId)"),
              let models = try? JSONDecoder().decode([ModelInfo].self, from: data),
              !models.isEmpty else { return }
        availableModels = models
        NSLog("[AgentBridge] models.cache-restored: %d models", models.count)
    }

    private static let stickyChoiceKey = "ripulStickyModelChoice"

    /// What a session started WITHOUT an explicit model should continue in —
    /// Siri's intent, the "+" button, `ripul://new-session`. Without it every
    /// such session snapped back to the web app's default rather than the
    /// thing the user was just working in.
    ///
    /// Two arms, because starting a session is two different acts. A plain API
    /// model is one fact: the catalog id. A CLI session is three — WHICH
    /// harness, WHICH model, and on WHICH machine — because the harness runs
    /// on the host, not here. Remembering only the model id would be enough to
    /// name a CLI session and not enough to start one.
    ///
    /// `lastKind` records which of the two the user actually reached for last,
    /// so the arms don't fight: picking an API model after a CLI session means
    /// the next plain session is that API model, and vice versa.
    public struct StickyModelChoice: Codable, Equatable {
        public enum Kind: String, Codable { case api, cli }

        public struct Cli: Codable, Equatable {
            /// nil = the machine's OWN default harness, i.e. what a plain "tap
            /// the machine" connect gives you. That path
            /// (`__ripulConnectToMachine`) lets the web choose the harness and
            /// never tells us which it picked, so the only faithful way to
            /// reproduce it is to run the same call again rather than guess a
            /// providerKey and pin the next session to the wrong harness.
            public var providerKey: String?
            /// nil = the provider's own default model.
            public var modelId: String?
            public var machineId: String
        }

        public var apiModelId: String?
        public var cli: Cli?
        public var lastKind: Kind
    }

    /// The persisted sticky choice, or nil if the user has not chosen anything
    /// yet.
    public var stickyChoice: StickyModelChoice? {
        get {
            guard let data = UserDefaults.standard.data(forKey: Self.stickyChoiceKey) else { return nil }
            return try? JSONDecoder().decode(StickyModelChoice.self, from: data)
        }
        set {
            guard let newValue, let data = try? JSONEncoder().encode(newValue) else {
                UserDefaults.standard.removeObject(forKey: Self.stickyChoiceKey)
                return
            }
            UserDefaults.standard.set(data, forKey: Self.stickyChoiceKey)
        }
    }

    /// Records a CLI session the user started, so the next plain new session
    /// starts another one just like it. Called from
    /// `connectToMachineWithProvider`, the single choke point for CLI session
    /// creation — which is also the only place all three facts are known.
    private func rememberCliSession(providerKey: String?, modelId: String?, machineId: String) {
        var choice = stickyChoice ?? StickyModelChoice(apiModelId: nil, cli: nil, lastKind: .cli)
        choice.cli = .init(providerKey: providerKey, modelId: modelId, machineId: machineId)
        choice.lastKind = .cli
        stickyChoice = choice
        handleConsoleLog("LOG: [MODELSW] native.sticky REMEMBER cli provider=\(providerKey ?? "machine-default") model=\(modelId ?? "default") machine=\(machineId)")
    }

    /// Records a model pick from a picker or from creating a session with an
    /// explicit model.
    ///
    /// A CLI id gets special handling: the picker that produced it had no
    /// machine attached, so on its own it cannot start a session. If we already
    /// remember a CLI session on the SAME harness, this is the user re-aiming
    /// that harness (Claude Code on Sonnet → Claude Code on Fable) and the
    /// remembered machine still applies. If we don't, there is no machine to
    /// bind to and the pick is skipped rather than stored half-formed.
    ///
    /// `nil` means "revert to the web default", which is itself a choice, so it
    /// clears the memory outright.
    func rememberModelPick(_ id: String?) {
        guard let id else {
            stickyChoice = nil
            handleConsoleLog("LOG: [MODELSW] native.sticky CLEARED")
            return
        }
        guard let model = availableModels.first(where: { $0.id == id }) else {
            // Catalog not loaded, or an id we can't see. Storing it unvalidated
            // would make it un-droppable later.
            handleConsoleLog("LOG: [MODELSW] native.sticky SKIP unresolved id=\(id)")
            return
        }

        var choice = stickyChoice ?? StickyModelChoice(apiModelId: nil, cli: nil, lastKind: .api)

        if model.isCli {
            guard let existing = choice.cli else {
                handleConsoleLog("LOG: [MODELSW] native.sticky SKIP no-machine-for id=\(id)")
                return
            }
            // The pick names the harness and the model; only the machine has to
            // come from what we already remember.
            let providerKey = ProviderConstants.byModelId(id)?.providerKey ?? existing.providerKey
            choice.cli = .init(providerKey: providerKey, modelId: id, machineId: existing.machineId)
            choice.lastKind = .cli
            stickyChoice = choice
            handleConsoleLog("LOG: [MODELSW] native.sticky REMEMBER cli-model id=\(id) provider=\(providerKey ?? "machine-default") machine=\(existing.machineId)")
            return
        }

        choice.apiModelId = id
        choice.lastKind = .api
        stickyChoice = choice
        handleConsoleLog("LOG: [MODELSW] native.sticky REMEMBER api id=\(id)")
    }

    /// The API model a session started with no explicit choice should use, or
    /// nil to let the web app pick. Re-validated against the live catalog on
    /// every call — a remembered model that has since been disabled or dropped
    /// must fall back rather than pin the session to something unusable.
    private func stickyApiModelForNewChat() -> String? {
        guard let id = stickyChoice?.apiModelId else { return nil }
        guard let model = availableModels.first(where: { $0.id == id }) else {
            handleConsoleLog("LOG: [MODELSW] native.sticky UNRESOLVED at create id=\(id)")
            return nil
        }
        // Subscription models are NOT excluded: they are created through this
        // same `createNewChat` path (the web routes them to the host's own
        // proxy), unlike CLI models which need a real connect call.
        guard model.enabled, !model.isCli else {
            handleConsoleLog("LOG: [MODELSW] native.sticky UNUSABLE at create id=\(id) enabled=\(model.enabled)")
            return nil
        }
        return id
    }

    /// Marks a freshly-created CLI session as raw-mode and labels it with its
    /// provider, the two facts the session list and agent screen read to render
    /// it as a CLI session rather than a plain chat.
    ///
    /// `RipulSessionListModel.connectWithProvider` already does this for
    /// sessions IT starts, but the sticky path starts one with the list model
    /// nowhere in the loop. Both writes are idempotent (a set insert and a
    /// dictionary assignment), so the overlap is harmless and the alternative —
    /// a CLI session that renders as an API chat — is not.
    private func persistCliSessionMetadata(tabId: String, providerKey: String) {
        guard let cache = sessionCache else {
            handleConsoleLog("LOG: [MODELSW] native.sticky CLI no sessionCache - skipping raw-mode label")
            return
        }
        var rawSessions = Set(cache.stringArray(forKey: "ripulRawModeSessions") ?? [])
        rawSessions.insert(tabId)
        cache.set(Array(rawSessions), forKey: "ripulRawModeSessions")

        var providers = cache.dictionary(forKey: "ripulSessionProviders") as? [String: String] ?? [:]
        providers[tabId] = ProviderConstants.byProviderKey(providerKey)?.displayLabel ?? providerKey
        cache.set(providers, forKey: "ripulSessionProviders")
    }

    /// Starts another CLI session like the last one the user started, on the
    /// same machine. Returns the new session's tab id, or nil to let the caller
    /// fall back to a plain API chat.
    ///
    /// Falling back rather than failing is the point: a CLI harness runs ON the
    /// host, so if that machine is asleep, gone from the registry, or refuses
    /// the connect, there is nothing to resume and the user still asked for a
    /// session. They get one — just not this one.
    private func resumeStickyCliSession() async -> String? {
        guard let choice = stickyChoice, choice.lastKind == .cli, let cli = choice.cli else { return nil }

        // An EMPTY list is "the web app hasn't published the registry yet", not
        // "you have no machines" — and on a Siri cold launch that is the normal
        // state for the first second or two. Treating it as "machine gone"
        // would silently downgrade every voice-started session to an API chat.
        // A list that IS populated and lacks our machine is genuine.
        var machines = await listMachines()
        for _ in 0..<6 where machines.isEmpty {
            try? await Task.sleep(nanoseconds: 500_000_000)
            machines = await listMachines()
        }

        // On a Mac host, a plain "New Chat" belongs to the Mac the user is
        // sitting at. Sticky resume is a convenience for clients that have no
        // machine of their own (the phone, where "continue what I was last in"
        // is the only sensible default) — letting it reach across to another
        // Mac meant pressing New Chat on the Studio silently reopened the
        // MacBook Pro, because that was where the last CLI session happened to
        // be. The machine rows are how you deliberately cross over.
        if let local = machines.first(where: { $0.isLocalHost }), local.machineId != cli.machineId {
            handleConsoleLog("LOG: [MODELSW] native.sticky CLI SKIP not-this-host sticky=\(cli.machineId) local=\(local.displayName)")
            return nil
        }

        guard let machine = machines.first(where: { $0.machineId == cli.machineId }) else {
            handleConsoleLog("LOG: [MODELSW] native.sticky CLI SKIP machine-unknown id=\(cli.machineId) known=\(machines.count)")
            return nil
        }
        guard machine.isOnline else {
            handleConsoleLog("LOG: [MODELSW] native.sticky CLI SKIP machine-offline \(machine.displayName)")
            return nil
        }

        // Reproduce the ACT, not an approximation of it: a harness the user
        // named explicitly goes back through the provider call; a plain machine
        // tap goes back through the plain connect and lets the web pick the
        // same default it picked last time.
        let (tabId, error): (String?, String?)
        if let providerKey = cli.providerKey {
            (tabId, error) = await connectToMachineWithProvider(
                machineId: cli.machineId,
                providerKey: providerKey,
                modelId: cli.modelId
            )
        } else {
            (tabId, error) = await connectToMachine(machineId: cli.machineId)
        }
        guard let tabId else {
            handleConsoleLog("LOG: [MODELSW] native.sticky CLI SKIP connect-failed: \(error ?? "unknown")")
            return nil
        }

        // Same new-chat handoff createNewChat does: a brand-new session has no
        // agent turn, so point the button projection at it before the sessions
        // push that makes it resolvable lands.
        pendingActiveSourceChatId = tabId
        refreshActiveAgentFlags()
        handleConsoleLog("LOG: [MODELSW] native.sticky CLI RESUMED provider=\(cli.providerKey ?? "machine-default") model=\(cli.modelId ?? "default") machine=\(machine.displayName)")
        return tabId
    }
    /// The most recent structured agent activity event from the web app.
    /// Not @Published — fires at very high frequency during agent runs and is only
    /// consumed via Combine (LiveActivityManager). Avoiding objectWillChange prevents
    /// every view observing AgentBridge from re-rendering on each activity event.
    @ObservationIgnored public var latestActivity: AgentActivityEvent? {
        didSet { if oldValue != latestActivity { latestActivitySubject.send(latestActivity) } }
    }
    /// Dedicated publisher for latestActivity changes (replaces $latestActivity).
    public let latestActivitySubject = PassthroughSubject<AgentActivityEvent?, Never>()
    /// Session-list-only per-chat maps, isolated onto their own leaf
    /// ObservableObject so writes (many per second during a run) re-render the
    /// session list WITHOUT re-rendering the WKWebView host that observes
    /// `AgentBridge`. See SessionListStore for the full rationale. Access the
    /// maps as `sessionList.latestActivityByChatId`, etc.
    public let sessionList = SessionListStore()

    /// Native chat scroller store — messages forwarded from the web app over the
    /// bridge (see `handleNativeChatMessage`). Its OWN leaf ObservableObject so
    /// high-frequency message/streaming writes re-render only the native scroller,
    /// not the WKWebView host. Same rationale as `sessionList` / `chatStatus`.
    public let nativeChat = NativeChatMessageStore()

    /// Debug: render the chat natively (NativeChatView over the web view) instead of
    /// the web-rendered scroller. The existing ChatComposer + top bar are reused.
    /// Flipped rarely (a settings toggle), so plain @Published is fine.
    public var nativeChatScrollerEnabled = false

    /// Navigation + model-display state on a leaf store so writes don't fire
    /// bridge.objectWillChange and re-render the WKWebView host or list containers.
    public let navigationStore = NavigationStore()

    /// True when the native chat input's text view is the first responder.
    /// Used to gate the keyboard-avoidance offset so that web inputs inside
    /// the WKWebView (e.g. metadata panel) don't shift the whole view up.
    public var nativeChatInputFocused: Bool = false
    /// Per-chat lifecycle sequence, used to drop out-of-order phase events.
    /// Sequences are per-chat monotonic counters on the web side — they must
    /// never be compared across chats.
    @ObservationIgnored private var sessionLifecycleSequences: [String: Int] = [:]
    /// Tracks whether we've logged the first stateSnapshot batch for startup diagnostics.
    @ObservationIgnored private var hasLoggedFirstSnapshotBatch = false
    /// High-frequency publisher for todo state changes. Sends `(chatId, newState?)`
    /// where a nil state indicates a dismissal. Mirrors the latestActivitySubject
    /// pattern above — used by LiveActivityManager without forcing every
    /// observer of AgentBridge to re-render.
    public let todoStateSubject = PassthroughSubject<(String, TodoState?), Never>()
    /// Turn state for the active chat, observable on its own so a turn change
    /// re-renders only the composer, not every view observing the bridge.
    public let turnState = RipulAgentTurnState()
    /// Authoritative lifecycle phase for the active chat turn. Derived — see
    /// `refreshActiveAgentFlags()`, the only writer. Observe `turnState`.
    public var agentTurnPhase: AgentTurnPhase {
        get { turnState.phase }
        set { turnState.phase = newValue }
    }
    /// Provider actions projected from the shared composer policy.
    public let composerActions = RipulComposerActionStore()

    /// Whether the agent is currently running (processing) for the active session.
    /// Derived from `chatTurnPhases[activeSourceChatId]` — never set directly.
    /// Observe `turnState.$isRunning`.
    public var isAgentRunning: Bool {
        get { turnState.isRunning }
        set { turnState.isRunning = newValue }
    }
    /// Whether the agent is paused (awaiting user input) for the active session.
    /// Derived from `chatTurnPhases[activeSourceChatId]` — never set directly.
    /// Observe `turnState.$isPaused`.
    public var isAgentPaused: Bool {
        get { turnState.isPaused }
        set { turnState.isPaused = newValue }
    }
    /// Raw (uncollapsed) turn phase per chat, keyed by sourceChatId. This is the
    /// single source of truth for the chat-box pause/play buttons; the collapsed
    /// `sessionList.sessionPhases` variant (completed/failed → awaitingInput) is
    /// for list-side "is this session mid-flight" reads. Entries are removed
    /// on `.idle`.
    @ObservationIgnored var chatTurnPhases: [String: AgentTurnPhase] = [:]
    /// sourceChatId of a just-created chat that isn't in `sessions` yet. Bridges
    /// the gap between `__ripulCreateChat` returning and the sessions push
    /// landing, so `activeSourceChatId` (and therefore the pause button) points
    /// at the new chat immediately instead of the previous one. Cleared once the
    /// active session resolves to the same sourceChatId.
    @ObservationIgnored private var pendingActiveSourceChatId: String?
    /// How thinking is displayed in LLM panels: "none", "folded", or "open".
    /// Lives on navigationStore so writes don't fire bridge.objectWillChange.
    public var showThinkingMode: String {
        get { navigationStore.showThinkingMode }
        set { navigationStore.showThinkingMode = newValue }
    }
    /// Guard against stale agent:status pushes during web app initialization.
    /// Set to true after the first syncAgentStatus completes post-connection.
    @ObservationIgnored var initialStatusSyncComplete = false
    /// Polling task that periodically syncs agent status while the agent is running.
    /// Ensures the button clears even if push notifications are lost.
    @ObservationIgnored private var statusPollingTask: Task<Void, Never>?
    /// Start polling agent status while the active chat is running. The pull
    /// result is applied per-chat by `syncAgentStatus`, so a poll can never
    /// poison another chat's state — it only corrects the chat it's about.
    private func startStatusPolling() {
        statusPollingTask?.cancel()
        statusPollingTask = Task { [weak self] in
            // Wait 5s before first poll
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            for _ in 0..<100 { // max ~5 min
                guard let self, !Task.isCancelled else { return }
                let (running, _) = await self.syncAgentStatus()
                if !running {
                    self.stopStatusPolling()
                    return
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private func stopStatusPolling() {
        statusPollingTask?.cancel()
        statusPollingTask = nil
    }

    func resetLifecycleState() {
        pendingActiveSourceChatId = nil
        stopStatusPolling()
        chatTurnPhases = [:]
        sessionList.sessionPhases = [:]
        sessionLifecycleSequences = [:]
        refreshActiveAgentFlags()
    }

    /// Recompute the active-chat button state (`agentTurnPhase`, `isAgentRunning`,
    /// `isAgentPaused`) as a projection of `chatTurnPhases[activeSourceChatId]`.
    /// This is the ONLY writer of those flags — events from background chats can
    /// never leak into the active chat's UI, and switching sessions immediately
    /// shows the target chat's true state (no reset-then-resync gap).
    private func refreshActiveAgentFlags() {
        // Hand off the pending new-chat override once the sessions list has
        // caught up and resolves the active session to the same chat.
        if let pending = pendingActiveSourceChatId,
           let activeSessionId,
           sessions.first(where: { $0.id == activeSessionId })?.sourceChatId == pending {
            pendingActiveSourceChatId = nil
        }

        let phase: AgentTurnPhase
        if let chatId = activeSourceChatId, let current = chatTurnPhases[chatId] {
            phase = current
        } else {
            phase = .idle
        }
        let running: Bool
        let paused: Bool
        switch phase {
        case .running:       running = true;  paused = false
        case .awaitingInput: running = true;  paused = true
        case .idle, .completed, .failed: running = false; paused = false
        }
        if agentTurnPhase != phase { agentTurnPhase = phase }
        if isAgentRunning != running { isAgentRunning = running }
        if isAgentPaused != paused { isAgentPaused = paused }
        if phase == .running {
            if statusPollingTask == nil { startStatusPolling() }
        } else {
            stopStatusPolling()
        }
    }

    /// The `sourceChatId` of the currently-active session — the chat whose
    /// per-chat phase drives the pause/play buttons via
    /// `refreshActiveAgentFlags()`. A just-created chat that hasn't landed in
    /// `sessions` yet is covered by `pendingActiveSourceChatId`.
    private var activeSourceChatId: String? {
        if let pending = pendingActiveSourceChatId { return pending }
        guard let activeSessionId else { return nil }
        return sessions.first(where: { $0.id == activeSessionId })?.sourceChatId
    }

    /// The active chat's id, for features that need to ask the web layer about
    /// "this chat" — plan review resolves its machine and working directory
    /// from it, the same way the repo tools do.
    ///
    /// Read-only on purpose: the active chat is set by session navigation, and
    /// a feature that could reassign it would desynchronise the pause buttons.
    public var currentSourceChatId: String? { activeSourceChatId }

    /// Update the per-session phase map for a single chat. Drops out-of-order
    /// events via per-chat sequence tracking.
    ///
    /// Phase meanings:
    /// - `.running`                 — spinner on the row (agent is working)
    /// - `.awaitingInput`           — mid-turn pause: permission / ask_user
    /// - `.completed` / `.failed`   — turn finished, user's next prompt needed
    /// - `.idle`                    — cleared (never ran anything)
    ///
    /// Treating `.completed` / `.failed` as "awaiting user" matches how people
    /// read the sessions list — a finished turn *is* waiting for you. Only
    /// `.running` draws on the row itself; "waiting" is carried by unread
    /// shading, which also knows whether you've read the reply.
    private func applySessionPhase(
        _ phase: AgentTurnPhase,
        chatId: String?,
        sequence: Int?,
        timestamp: Any? = nil
    ) {
        guard let chatId, !chatId.isEmpty else { return }
        if let sequence, let last = sessionLifecycleSequences[chatId], sequence < last {
            return
        }
        if let sequence {
            sessionLifecycleSequences[chatId] = sequence
        }
        // Confession line for wrong flips: the chat box's pause state dies
        // exactly when a live phase is downgraded here.
        if let previous = chatTurnPhases[chatId],
           previous == .running || previous == .awaitingInput,
           phase == .completed || phase == .failed || phase == .idle {
            Self.debugLog("[TURNSTATE] downgrade chat=…\(chatId.suffix(8)) \(previous.rawValue) -> \(phase.rawValue) seq=\(sequence.map(String.init) ?? "nil")")
        }
        let phaseDate = Self.parseEpochMs(timestamp) ?? Date()
        switch phase {
        case .running, .awaitingInput, .completed, .failed:
            // Stored RAW — turnPhase(for:) collapses at read time.
            sessionList.sessionPhases[chatId] = phase
            sessionList.phaseTimestampByChatId[chatId] = phaseDate
        case .idle:
            sessionList.sessionPhases.removeValue(forKey: chatId)
            sessionList.phaseTimestampByChatId.removeValue(forKey: chatId)
        }
        // Mirror the waiting set to disk from the SAME assignment that drives
        // the row indicator, so "what Siri says is waiting" and "what the list
        // shows as waiting" cannot disagree. They did: the first version fed
        // off completion PUSHES, which only land while the app is foregrounded,
        // so the spoken answer was almost always "nothing waiting" while a row
        // sat there plainly waiting.
        // The PARSED date, not the fallback: a replay carries the original
        // action's timestamp, and distinguishing "this turn just ended" from
        // "the app is being told about a turn that ended yesterday" is the
        // whole basis of the read watermark below.
        persistWaitingState(chatId: chatId, phase: phase, eventDate: Self.parseEpochMs(timestamp))
        // The raw phase map keeps completed/failed distinct — the chat box must
        // NOT show the paused/play state for a finished turn.
        if phase == .idle {
            chatTurnPhases.removeValue(forKey: chatId)
        } else {
            chatTurnPhases[chatId] = phase
        }
        // Drop any stale per-chat tool-call subtitle when the session
        // goes idle OR the turn completes/fails. We keep the label across
        // running ↔ awaitingInput transitions (CLI sessions frequently
        // sit on `.awaitingInput` mid-tool-run), but once a turn is truly
        // over we don't want the subtitle showing the last tool name
        // from the previous turn.
        if phase == .idle || phase == .completed || phase == .failed {
            sessionList.latestActivityByChatId.removeValue(forKey: chatId)
        }
        refreshActiveAgentFlags()
    }

    /// Route a lifecycle turn event into the per-chat phase maps. The active
    /// chat's buttons update as a side effect (`applySessionPhase` →
    /// `refreshActiveAgentFlags`); events for background chats only touch their
    /// own row indicators. Events without a `chatId` are dropped — attributing
    /// them to the active chat is exactly how another chat's state used to leak
    /// into a fresh session's pause button.
    /// A status push from the web: is the agent running, for the chat it names.
    private func handleAgentStatusPush(_ dict: [String: Any]) {
        // Ignore stale pushes during web app initialization — the pull-based
        // syncAgentStatus (run after connection) is the authoritative source.
        guard initialStatusSyncComplete else { return }
        guard let chatId = dict["chatId"] as? String, !chatId.isEmpty else { return }
        let decision = StatusPushDecision.decide(
            running: dict["isRunning"] as? Bool ?? false,
            paused: dict["isPaused"] as? Bool ?? false,
            current: chatTurnPhases[chatId],
            hasTurnEvents: sessionLifecycleSequences[chatId] != nil
        )
        switch decision {
        case .leave:
            break
        case .apply(let phase):
            applySessionPhase(phase, chatId: chatId, sequence: nil, timestamp: dict["timestamp"])
        case .pull(let reason):
            if reason == .liveChatSaidNotRunning {
                Self.debugLog("[TURNSTATE] status push not-running for status-only chat …\(chatId.suffix(8)) while native=\(chatTurnPhases[chatId]?.rawValue ?? "?") — pull-arbitrating instead of hard clear")
            }
            Task { await syncAgentStatus(chatId: chatId) }
        }
    }

    /// An activity event from the web: what the agent is doing right now.
    private func handleAgentActivity(_ dict: [String: Any]) {
        guard let eventDict = dict["event"] as? [String: Any],
              let event = AgentActivityEvent.from(dict: eventDict) else { return }
        latestActivity = event
        // Track Edit tool file paths for the "Recently Edited" section on
        // the Files screen. toolFilePath is an extension field on the wire
        // event that isn't carried by the Swift enum, so read it here.
        if let toolName = eventDict["toolName"] as? String, toolName == "Edit",
           let filePath = eventDict["toolFilePath"] as? String, !filePath.isEmpty {
            sessionList.recordRecentlyEditedFile(filePath)
        }
        guard let chatId = dict["chatId"] as? String, !chatId.isEmpty else { return }

        // The agent's own words already cross the bridge as a response
        // preview, so remembering the newest one per chat costs one
        // dictionary write and saves inventing a second channel for
        // exactly the same text. This is what Siri reads back.
        if case .response(let preview) = event {
            let cleaned = preview.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                lastResponsePreviewByChatId[chatId] = cleaned
                // Also patch an entry already on disk. The turn's phase
                // can flip to completed BEFORE the final preview lands,
                // in which case the entry was written with nothing and
                // would never be revisited — which is exactly what
                // shipped: a summary with no reply in it. Handling both
                // orders is cheaper than reasoning about which wins.
                backfillWaitingPreview(chatId: chatId, preview: cleaned)
            }
        }

        // Stamp last-active time for sort order, but only if the
        // event is genuinely fresher than the existing value —
        // replays/snapshots carry the original action's timestamp,
        // so we don't bump idle sessions to the top on host
        // restart or cross-device sync.
        advanceLastActive(chatId: chatId, eventTimestamp: dict["timestamp"])

        let subtitle = ActivitySubtitleDecision.decide(
            event: event,
            isFresh: isFreshActivityTimestamp(dict["timestamp"]),
            isAgentRunning: isAgentRunning
        )
        switch subtitle {
        case .storeSessionActions(let actions):
            if sessionList.sessionActionsByChatId[chatId] != actions { sessionList.sessionActionsByChatId[chatId] = actions }
        case .clear(let pullStatus):
            sessionList.latestActivityByChatId.removeValue(forKey: chatId)
            if pullStatus {
                Task { [weak self] in await self?.syncAgentStatus() }
            }
        case .latch:
            // Between-turn sticking is prevented by clearing on
            // completed/failed in applySessionPhase.
            if sessionList.latestActivityByChatId[chatId] != event { sessionList.latestActivityByChatId[chatId] = event }
        case .leave:
            break
        }
    }

    private func handleLifecycleEvent(_ phase: AgentTurnPhase, dict: [String: Any], isSnapshot: Bool = false) {
        guard let chatId = dict["chatId"] as? String, !chatId.isEmpty else {
            Self.debugLog("[AgentBridge] Dropping lifecycle event without chatId (phase=\(phase.rawValue))")
            return
        }
        applySessionPhase(phase, chatId: chatId, sequence: dict["sequence"] as? Int, timestamp: dict["timestamp"])
        // Stamp last-active time for session list sort order — but NOT on
        // snapshots, which fire for every session on connect and would
        // reset all timestamps to "just now".
        if !isSnapshot {
            advanceLastActive(chatId: chatId, eventTimestamp: dict["timestamp"])
        }
    }

    /// Update `sessionList.lastActiveTimeByChatId` from an incoming event.
    ///
    /// When the event carries a real timestamp (epoch ms on the wire), we
    /// trust it as authoritative — the web app reads it from the action's
    /// own `timestamp` field, which reflects when the action was genuinely
    /// created.  We write it unconditionally so a previously-polluted cache
    /// entry (e.g. from a build that stamped Date.now() for every action)
    /// can be corrected downward.
    ///
    /// When no parseable timestamp is present we fall back to Date() but
    /// only *advance* — this prevents a missing-timestamp event from
    /// overwriting a known-good older value.
    /// Parse an epoch-milliseconds wire timestamp into a Date, or nil.
    private static func parseEpochMs(_ raw: Any?) -> Date? {
        if let ms = raw as? TimeInterval, ms > 0 { return Date(timeIntervalSince1970: ms / 1000) }
        if let ms = raw as? Int, ms > 0 { return Date(timeIntervalSince1970: TimeInterval(ms) / 1000) }
        return nil
    }

    private func advanceLastActive(chatId: String, eventTimestamp: Any?) {
        let timestamp: Date
        if let parsed = Self.parseEpochMs(eventTimestamp) {
            // Preserve authoritative corrections in either direction.
            timestamp = parsed
        } else {
            timestamp = Date()
            if let existing = sessionList.lastActiveTimeByChatId[chatId], existing >= timestamp { return }
        }
        guard sessionList.lastActiveTimeByChatId[chatId] != timestamp else { return }
        sessionList.lastActiveTimeByChatId[chatId] = timestamp
    }

    private func handleLifecycleSnapshot(_ dict: [String: Any]) {
        guard let rawPhase = dict["phase"] as? String,
              let phase = AgentTurnPhase(rawValue: rawPhase) else {
            return
        }
        handleLifecycleEvent(phase, dict: dict, isSnapshot: true)

        if !hasLoggedFirstSnapshotBatch {
            hasLoggedFirstSnapshotBatch = true
        }
    }

    /// Set when the web view fails to load. Cleared on successful connection.
    public var loadError: String?

    // MARK: - WebView Crash Tracking

    static let crashEventsKey = "ripulWebViewCrashEvents"

    /// Process termination events recorded this session + persisted from prior sessions.
    public var crashEvents: [WebViewCrashEvent] = {
        guard let data = UserDefaults.standard.data(forKey: crashEventsKey) else { return [] }
        return (try? JSONDecoder().decode([WebViewCrashEvent].self, from: data)) ?? []
    }()

    /// Number of process terminations in this app session (since launch).
    @ObservationIgnored public internal(set) var sessionCrashCount: Int = 0

    static let healthReportsKey = "ripulWebViewHealthReports"

    /// Persisted health probe reports (survives app restarts).
    public var healthReports: [WebViewHealthReport] = {
        guard let data = UserDefaults.standard.data(forKey: healthReportsKey) else { return [] }
        return (try? JSONDecoder().decode([WebViewHealthReport].self, from: data)) ?? []
    }()

    /// Set by recordProcessTermination — triggers an auto-probe once the bridge reconnects.
    @ObservationIgnored var pendingPostCrashProbe = false

    /// Masthead configuration from the web app (text, image, colors for native glass lozenge).
    public var mastheadConfig: MastheadConfig?
    /// Active voice profile from the site key, for settings UI that shows it.
    public var voiceProfile: VoiceProfileConfig?
    /// Glass style for the native chat input: "regular", "clear", or "identity".
    public var chatInputGlassStyle: String?
    /// Layout mode for the native chat input: nil/"single" (default) or "twoRow" (buttons below text area).
    public var chatInputLayout: String?
    public private(set) var conversationModeSwitchers: [String: Bool] = [:]
    public private(set) var conversationModes: [String: String] = [:]
    /// Pending quoted replies per chat, mirrored from the web transcript.
    public private(set) var replyTargets: [String: RipulReplyTarget] = [:]

    public func replyTarget(for chatId: String?) -> RipulReplyTarget? {
        guard let chatId else { return nil }
        return replyTargets[chatId]
    }

    /// Native's cancel button. The web store is the authority, so clear it there
    /// too; the mirror clears immediately for a responsive strip either way.
    public func clearReplyTarget(chatId: String) async {
        if replyTargets[chatId] != nil { replyTargets[chatId] = nil }
        _ = await callPage("__ripulClearReplyTarget", [chatId], .orElse("{success:false}"), log: .none)
    }

    private func handleReplyTarget(_ dict: [String: Any]) {
        guard let chatId = dict["chatId"] as? String else { return }
        if let raw = dict["target"] as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: raw),
           let target = try? JSONDecoder().decode(RipulReplyTarget.self, from: data) {
            if replyTargets[chatId] != target { replyTargets[chatId] = target }
        } else if replyTargets[chatId] != nil {
            replyTargets[chatId] = nil
        }
    }
    public private(set) var messageSubmissionError: String?

    public func showsConversationMode(for chatId: String?) -> Bool {
        guard let chatId else { return false }
        return conversationModeSwitchers[chatId] ?? false
    }

    public func conversationMode(for chatId: String?) -> String {
        guard let chatId else { return "agent" }
        return conversationModes[chatId] ?? "agent"
    }

    public func refreshConversationMode(chatId: String) async {
        let reply = await callPage("__ripulGetConversationMode", [chatId], .orElse("{mode:'agent'}"), log: .none)
        guard let dict = reply.dictionary, let mode = dict["mode"] as? String else { return }
        if conversationModes[chatId] != mode { conversationModes[chatId] = mode }
        if let visible = dict["showModeSwitcher"] as? Bool, conversationModeSwitchers[chatId] != visible {
            conversationModeSwitchers[chatId] = visible
        }
    }

    public func setConversationMode(chatId: String, mode: String) async -> String? {
        let reply = await callPage("__ripulSetConversationMode", [chatId, mode],
                                   .orElse("{success:false,error:'Conversation mode is unavailable.'}"), log: .none)
        if let reason = reply.failure(detached: "Reconnect this conversation and try again.") { return reason }
        guard reply.succeeded else {
            return reply.dictionary?["error"] as? String ?? "The mode change was not confirmed."
        }
        if conversationModes[chatId] != mode { conversationModes[chatId] = mode }
        return nil
    }

    /// Whether to show "New to do" and "Pick to do" in the native chat "+" menu. Default true.
    public var chatInputShowTodos: Bool = true
    /// Whether to show "Quick Commands" in the native chat "+" menu. Default true.
    public var chatInputShowQuickCommands: Bool = true
    /// A file view request awaiting native sheet presentation.
    public var pendingFileView: FileViewRequest?
    /// Tool-call inspection updates stay off the bridge's own publisher.
    private var nativeToolUIFeatures: [String] {
        #if os(iOS)
        return ["toolCallDetails", "nativeToolStrip"] + defaultToolActions.features + (toolStripAnchor == nil ? [] : ["nativeToolStripAnchor", "nativeToolStripRows"]) + (nativeEmbeds == nil ? [] : nativeEmbedRenderers.features)
        #else
        return ["toolCallDetails", "nativeToolStrip"]
        #endif
    }
    public let toolCallDetails = ToolCallDetailsStore()
    @ObservationIgnored private lazy var defaultToolActions: ToolDefaultActionRegistry = {
        let actions = ToolDefaultActionRegistry()
        #if os(iOS)
        if #available(iOS 26.0, *) {
            actions.register("simulator.preview") { [weak self] request in
                guard let self, let chatId = request["chatId"] as? String, chatId == self.currentSourceChatId,
                      let machineId = request["machineId"] as? String, !machineId.isEmpty,
                      let payload = request["payload"] as? [String: Any], let target = payload["target"],
                      let data = try? JSONSerialization.data(withJSONObject: target),
                      let simulator = try? JSONDecoder().decode(SimulatorTarget.self, from: data),
                      UUID(uuidString: simulator.udid) != nil else { return }
                self.simulatorPreview.open(simulator, machineId: machineId, chatId: chatId)
            }
        }
        #endif
        return actions
    }()
    #if os(iOS)
    let simulatorPreview = SimulatorPreviewState()
    let browserPreview = BrowserPreviewState()
    public private(set) var browserPreviewAvailable = false

    /// Installed only by a host with its own local browser (the Ripul iPhone app).
    public func configureBrowserPreview(capture: @escaping (Int?) async throws -> BrowserPreviewSnapshot) {
        browserPreview.capture = capture
        browserPreviewAvailable = true
    }

    public func showBrowserPreview(tabId: Int? = nil, automatic: Bool = false) {
        guard let chatId = currentSourceChatId, browserPreviewAvailable else { return }
        browserPreview.open(chatId: chatId, tabId: tabId, automatic: automatic)
    }
    #endif
    public let toolStrip = NativeToolStripStore()
    #if os(iOS)
    @ObservationIgnored private var toolStripAnchor: NativeToolStripAnchorController?
    @ObservationIgnored var toolStripRows: NativeToolStripRowsController?
    public let nativeEmbedRenderers = NativeEmbedRegistry.standard()
    @ObservationIgnored var nativeEmbeds: NativeEmbedController?
    var toolStripAccessibilityElements: [Any] { (toolStripRows?.accessibilityElements ?? []) + (toolStripAnchor?.accessibilityElements ?? []) + (nativeEmbeds?.accessibilityElements ?? []) }
    #if DEBUG
    /// Read-only handles for ChatEntryMotionProbe (on-screen motion at chat entry).
    var probeWebView: WKWebView? { webView }
    /// Native lozenges' on-screen tops (presentation layers, window points).
    var probeToolStripScreenMinYs: [Int] { toolStripRows?.screenMinYs ?? [] }
    #endif
    func hitTestToolStrip(_ point: CGPoint, event: UIEvent?) -> UIView? {
        nativeEmbeds?.hitTest(point, event: event) ?? toolStripRows?.hitTest(point, event: event) ?? toolStripAnchor?.hitTest(point, event: event)
    }
    func detachToolStripAnchor() {
        nativeEmbeds?.clear(); nativeEmbeds = nil
        toolStripRows?.invalidate(); toolStripRows = nil
        toolStripAnchor?.invalidate(); toolStripAnchor = nil
    }
    #endif
    /// True while the web file viewer is open — native chat input should be hidden.
    public var fileViewerExpanded: Bool = false
    /// Filename shown in the native title bar while the file viewer is open; nil when closed.
    public var fileViewerTitle: String? = nil
    /// True when the file viewer is showing a markdown file (enables zoom/raw menu items).
    public var fileViewerIsMarkdown: Bool = false
    /// Full file path of the file currently shown in the viewer; nil when closed.
    public var fileViewerFilePath: String? = nil
    /// Source location and chat captured when a reference was tapped.
    @ObservationIgnored public var fileViewerLine: Int? = nil
    @ObservationIgnored public var fileViewerChatId: String? = nil
    /// When true, closing the file viewer should navigate back to the sessions list.
    @ObservationIgnored public var fileViewerReturnToSessions: Bool = false

    /// True while a web artefact's full page is open — the native chat input
    /// hides behind it, and the top bar shows the artefact's own back button.
    public var artefactPageExpanded: Bool = false
    /// Artefact title shown in the native title bar while its page is open; nil when closed.
    public var artefactPageTitle: String? = nil

    /// Current web page context — drives native chrome visibility.
    /// Updated by the web app via `page:context` messages and by the navigation
    /// delegate when the WKWebView leaves the app domain (OAuth redirects).
    public var currentPageContext: PageContext = .default

    @ObservationIgnored private weak var webView: WKWebView?
    /// The page this bridge is attached to now. A host that keeps its own
    /// channels on the page (the Mac's CLI bridges) routes to this one, never to
    /// a page SwiftUI has taken down but WebKit has not yet released.
    public var attachedWebView: WKWebView? { webView }
    #if os(iOS)
    /// The owning scene, never an arbitrary app-wide first window.
    public var hostingWindow: UIWindow? { webView?.window }
    #endif

    /// Channel-bound tools (a console's `console_logs`, `inspect_screen`, …):
    /// they capture this bridge at init, so they live on the channel, never in
    /// the shared registry. Everything else lives in `registry`.
    @ObservationIgnored private var builtInTools: [NativeTool] = []
    /// Token for this bridge's registry-change observer (see `deinit`).
    private let registryObserverId = UUID()
    @ObservationIgnored private var llmProvider: LLMProvider?
    @ObservationIgnored private var sessionsRetryCount = 0
    private static let maxSessionsRetries = 5
    @ObservationIgnored var connectionTimeoutTask: Task<Void, Never>?
    public let startupLoadState = StartupLoadState()
    /// nil: no authentication wait required; "unknown": auth loading;
    /// "alive": session found, awaiting token. Read without publishing polls.
    @ObservationIgnored public var startupAuthenticationState: (() -> String?)?
    @ObservationIgnored var startupBudget = StartupLoadBudget()
    @ObservationIgnored var startupMonitoring = false
    @ObservationIgnored var startupNavigationFinished = false
    /// When the navigation currently in flight began, so a heal can tell a load
    /// that is still running from one that has hung. Read together with
    /// `webView.isLoading` — a stale value on a settled page is inert.
    @ObservationIgnored var navigationBeganAt: Date?
    @ObservationIgnored var startupLastStage = ""
    @ObservationIgnored private var startupProgressObservation: NSKeyValueObservation?
    @ObservationIgnored var startupTimeoutError: String?

    /// Set this delegate to handle search result clicks from the universal search.
    @ObservationIgnored public weak var searchClickDelegate: SearchClickDelegate?

    /// Set this delegate to handle link navigation requests from interactWithUser options.
    @ObservationIgnored public weak var linkOpenDelegate: LinkOpenDelegate?

    /// Additional capabilities to merge into the handshake response.
    /// These override auto-detected values (e.g., set `"dom": true`).
    @ObservationIgnored public var extraCapabilities: [String: Any] = [:]

    /// Router for browser capability requests from the web app.
    /// Register capability handlers (e.g., TabsCapability, ScriptingCapability)
    /// to enable browser control from the native app.
    public let capabilityRouter = CapabilityRouter()

    /// Callback for custom message types not handled by the bridge.
    /// The message type (with `agent-framework:` prefix stripped) and full dict are passed.
    /// Return `true` if the message was handled, `false` to log it as unhandled.
    @ObservationIgnored public var onUnhandledMessage: ((_ messageType: String, _ message: [String: Any]) -> Bool)?

    /// Called when a CLI-provider session is successfully renamed.
    /// Parameters are (sourceChatId, confirmedDisplayName).
    @ObservationIgnored public var onCliSessionRenamed: ((_ sessionId: String, _ displayName: String, _ renamedAt: Double?) -> Void)?

    /// - Parameter registry: the host's tool registry this channel projects
    ///   from. Defaults to a fresh empty registry so a host with no native
    ///   tools never has to construct one.
    /// - Parameter audience: which channel this bridge serves. Defaults to
    ///   `.endUser` so a host that never considers the question gets the
    ///   restrictive setting; pass `.developer` for a console / DevTools
    ///   bridge (`RipulAgentConsole` constructs its own that way).
    ///
    /// Designated (not convenience) so `audience` can be a `let` assigned
    /// before `super.init()`: the gate's invariant is enforced by the type,
    /// not by a doc comment promising immutability.
    public init(registry: RipulToolRegistry = RipulToolRegistry(), audience: RipulChannelAudience = .endUser) {
        self.registry = registry
        self.audience = audience
        // The channel's exposure: its own audience's tools, nothing else.
        // Phase 2 (absorption) widens a `.developer` channel's exposure on an
        // explicit, session-scoped opt-in; an `.endUser` channel's exposure is
        // fixed by construction.
        self.exposedAudiences = audience == .developer ? [.developer] : [.endUser]
        super.init()
        AgentBridge.current = self
        // Late registrations (a host registering after the web app connected)
        // re-broadcast, so the tool list is live rather than
        // handshake-snapshotted. Registration happens on the main thread; the
        // Task hop keeps the closure valid under strict concurrency.
        registry.addObserver(registryObserverId) { [weak self] in
            Task { @MainActor in self?.broadcastToolsIfConnected() }
        }
        startNetworkPathMonitoring()
        startProcessLifecycleMonitoring()
        // Route CPU spikes into the bridge console (visible in host_console_logs
        // / device_console_logs). onSpike is invoked on the main thread.
        cpuSampler.onSpike = { [weak self] line in self?.handleConsoleLog(line) }
    }

    /// Most-recently-initialized bridge, so static / off-instance native logging
    /// (e.g. `debugLog`, the free `nlog()` helper) can reach the `consoleLogs`
    /// buffer that `device_console_logs` / `host_console_logs` read. Weak so it
    /// never keeps a bridge alive.
    public static weak var current: AgentBridge?

    /// Verbose per-message bridge tracing. OFF by default. These NSLog calls sit
    /// on the streaming hot path — `agent:activity` "thinking" events arrive at
    /// ~30 Hz, so an unconditional NSLog here is ~30+ synchronous main-thread
    /// log writes per second during a run (a confirmed thermal source on iPhone).
    /// NSLog output is invisible on-device without Xcode attached anyway, so this
    /// is pure cost in production. Flip it on only when debugging with Xcode; the
    /// in-app `consoleLogs` buffer (read by device_console_logs) is unaffected.
    public static var verboseBridgeLog = false

    /// `[SESSION-START]` latency instrumentation. OFF by default. These markers
    /// were added to measure the tap → input-ready window and are forced to WARN
    /// so they survive console-level gating — which also means they are loud.
    /// Unlike the web side they do not dedupe, and `loadRemoteSessions` alone
    /// emits up to four per call on a path that runs on every foreground,
    /// refresh and session action. Flip on only while chasing startup latency;
    /// `setSessionStartInstrumentation` pushes the same gate to the web view so
    /// one toggle covers web, iOS and macOS.
    public static var sessionStartInstrumentation = false

    /// Render the WKWebView opaque instead of transparent (thermal A/B test). A
    /// transparent web view must blend every repaint against the layers behind it;
    /// during streaming the chat repaints changing text ~30x/sec, so an opaque view
    /// (a cheap copy, no per-repaint blend) should run cooler if that blend is the
    /// heat. Read at web-view creation, so a relaunch is required to apply.
    public static var opaqueWebView = false

    /// One shared formatter: building an ISO8601DateFormatter loads ICU date
    /// symbols, and doing it per line was 77 of 78 samples in this function
    /// during a 2026-09-26 Mac host main-thread stall. ISO8601DateFormatter is
    /// thread-safe, and debugLog is called from any thread.
    private static let debugLogTimestampFormatter = ISO8601DateFormatter()

    /// Debug log to file (macOS unified log redacts NSLog content as <private>).
    /// ALSO mirrors into the `consoleLogs` buffer so native diagnostics are
    /// readable by `device_console_logs` / `host_console_logs`, not just on disk.
    public static func debugLog(_ message: String) {
        let ts = debugLogTimestampFormatter.string(from: Date())
        // Written off this thread, to /tmp/ripul-debug.log rolling over at 16 MB.
        DebugLogFile.shared.append("\(ts) \(message)\n")
        // Mirror into the unified buffer the log tools read (hop to the main actor;
        // debugLog may be called from any thread).
        Task { @MainActor in AgentBridge.current?.handleConsoleLog("LOG: [native] \(message)") }
    }

    // MARK: - Recently Edited Files

    // MARK: - Tool Registration

    // App-tool registration is a REGISTRY operation (`registry.register(_:audience:)`),
    // not a bridge one — the bridge only exposes a projection. The old
    // `register(_:)` / `setTools(_:)` are deleted, not deprecated (no
    // back-compat shims, repo doctrine).

    /// Register channel-bound tools (a console's `console_logs`,
    /// `inspect_screen`, …). SDK-internal: these capture their bridge at init,
    /// so they are instantiated per channel and never enter the shared
    /// registry. Replaces the previous set.
    internal func registerBuiltInTools(_ tools: [NativeTool]) {
        warnIfDeveloperOnlyOnEndUserChannel(tools)
        builtInTools = tools
        broadcastToolsIfConnected()
    }

    /// The hard gate's audit trail. Filtering itself happens in `allTools` (the
    /// one place both broadcast and invoke read from) regardless of whether
    /// this fires — this is diagnostic only, not a correctness check.
    ///
    /// NOT necessarily a bug: `.ripulDevTools(bridge:)` intentionally supports
    /// attaching to a host's own `.endUser` bridge (for a no-login local log
    /// viewer — see its doc comment), and this fires every time that happens.
    /// It is informational either way ("these registered tools are gated on
    /// this channel"), never a crash — deliberately, since the one case this
    /// SDK actually wants to catch hard (a console constructed with the wrong
    /// audience) is asserted separately, in `RipulAgentConsole.init`.
    ///
    /// Fires for SDK-provided dev tools only (`RipulDeveloperOnlyTool` is
    /// SDK-internal, so a host's own tools can never trigger it).
    private func warnIfDeveloperOnlyOnEndUserChannel(_ tools: [NativeTool]) {
        guard audience == .endUser else { return }
        let gated = tools.filter { $0 is RipulDeveloperOnlyTool }
        guard !gated.isEmpty else { return }
        let names = gated.map(\.name).joined(separator: ", ")
        NSLog("[RIPUL_GATE] Developer-only tool(s) registered on an .endUser channel, gated from the agent: %@", names)
    }

    /// The tools currently registered with this bridge — the live tool set of
    /// *this* build, which is more than any server-side view of it knows.
    ///
    /// Read-only by design: registration stays with `register` / `setTools`.
    /// The tool-collections editor uses this to show which tools a membership
    /// pattern captures before the developer saves.
    ///
    /// Names are canonical (no `host_` prefix — that is added downstream by the
    /// web layer), which is also what collection patterns match against.
    public var registeredToolSummaries: [RipulRegisteredTool] {
        let builtInNames = Set(builtInTools.map(\.name))
        return allTools.map { tool in
            RipulRegisteredTool(
                name: tool.name,
                description: tool.description,
                isBuiltIn: builtInNames.contains(tool.name)
            )
        }
    }

    /// Re-broadcast the current tool projection to a connected web app. Fired
    /// by registry changes, channel-tool registration, and exposure changes —
    /// the tool list is live, not handshake-snapshotted.
    private func broadcastToolsIfConnected() {
        guard isConnected else { return }
        send([
            "type": "\(messagePrefix)mcp:tools",
            "version": protocolVersion,
            "timestamp": currentTimestamp(),
            "tools": toolDefinitions,
        ])
    }

    // MARK: - Absorption (phase 2 — the permissive direction of the valve)

    /// Outcome of toggling end-user tool testing on a `.developer` channel.
    public enum AbsorptionToggleResult: Equatable {
        case on
        case off
        /// The toggle was refused: a dev tool and an end-user tool share a
        /// canonical name, which would make name-based invocation silently
        /// first-match. Fix the collision, then retry.
        case blocked(collidingNames: [String])
    }

    /// Whether this `.developer` channel currently absorbs the host's
    /// end-user tools. Session state by construction — it lives on the bridge
    /// instance, so a channel teardown resets it and nothing persists it.
    public var isEndUserTestingEnabled: Bool {
        exposedAudiences.contains(.endUser) && audience == .developer
    }

    /// Toggle testing mode: the console borrows the host's end-user tools —
    /// deliberate, session-scoped, attributed on every invocation
    /// (`absorbed: true` in the result envelope). The API is SPECIFIC to this
    /// widening on purpose: there is no general exposure override, so an
    /// `.endUser` channel has no equivalent call — the reverse direction of
    /// the valve stays structurally impossible (see the phase-2 doc).
    ///
    /// Absorbed tools execute against REAL app state — `pick_*` presents real
    /// UI, `create_*` writes real data. The console's confirmation sheet says
    /// this plainly; this affordance is not a sandbox.
    @discardableResult
    public func setEndUserTesting(_ on: Bool) -> AbsorptionToggleResult {
        precondition(
            audience == .developer,
            "setEndUserTesting is a developer-console affordance; an .endUser channel has no absorption"
        )
        if on {
            // Cross-set collision check at absorb time: the registry prevents
            // duplicates within itself, but channel-bound tools are not in it.
            let exposedNames = Set(exposedTools.map { RipulToolCollectionMatcher.canonicalName($0.name) })
            let collisions = registry.tools(audience: .endUser)
                .map(\.name)
                .filter { exposedNames.contains(RipulToolCollectionMatcher.canonicalName($0)) }
            if !collisions.isEmpty {
                NSLog("[RIPUL_ABSORB] Testing mode blocked by name collision(s): %@", collisions.joined(separator: ", "))
                return .blocked(collidingNames: collisions.sorted())
            }
            // Set mutations publish even when they change nothing.
            if !exposedAudiences.contains(.endUser) { exposedAudiences.insert(.endUser) }
        } else {
            if exposedAudiences.contains(.endUser) { exposedAudiences.remove(.endUser) }
        }
        broadcastToolsIfConnected()
        return on ? .on : .off
    }

    // MARK: - Attaching to the web view

    /// Configure a native LLM provider for on-device inference.
    /// When set, the handshake will advertise `llm: true` capability.
    public func setLLMProvider(_ provider: LLMProvider) {
        self.llmProvider = provider
        NSLog("[AgentBridge] LLM provider configured")
    }

    public func attach(to webView: WKWebView) {
        self.webView = webView
        #if os(iOS)
        detachToolStripAnchor()
        toolStripAnchor = webView is FullBleedWebView ? NativeToolStripAnchorController(webView: webView, store: toolStrip) : nil
        toolStripRows = webView is FullBleedWebView ? NativeToolStripRowsController(webView: webView, presenter: toolStrip, send: { [weak self] in self?.send($0) }) : nil
        nativeEmbeds = webView is FullBleedWebView ? NativeEmbedController(webView: webView, registry: nativeEmbedRenderers, send: { [weak self] in self?.send($0) }) : nil
        let inspectorCapability = "window.__ripulNativeInspectorAvailable = true; window.dispatchEvent(new Event('ripul:native-inspector'));"
        webView.configuration.userContentController.addUserScript(WKUserScript(source: inspectorCapability, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView.evaluateJavaScript(inspectorCapability, completionHandler: nil)
        #endif
        startupProgressObservation = webView.observe(\.estimatedProgress, options: [.old, .new]) { [weak self] observed, change in
            guard let progress = change.newValue, progress > (change.oldValue ?? 0) else { return }
            // A retired page loads a blank document; that is not startup progress.
            Task { @MainActor [weak self, weak observed] in
                guard let self, self.webView === observed else { return }
                self.recordStartupProgress()
            }
        }
        if !startupMonitoring { beginStartupMonitoring() }
        NSLog("[AgentBridge] Attached to WKWebView")
    }

    /// Master switch for native console logging. Off (the default) means no
    /// console.* output crosses the bridge (the JS `window.__ripulNativeLog` gate)
    /// and the hot-path NSLog traces stay silenced — the quiet/cool default. On
    /// restores the full firehose for debugging. Pushed live to the web view so a
    /// toggle change takes effect immediately, no reload. Uncaught errors are
    /// captured regardless (they bypass the console gate).
    public func setVerboseLogging(_ on: Bool) {
        AgentBridge.verboseBridgeLog = on
        evaluateJavaScript("window.__ripulNativeLog = \(on)")
    }

    /// Master switch for the `[SESSION-START]` latency markers. Off (the default)
    /// silences the native emitters and the web-side `sessionStartTimer` helpers
    /// alike. Pushed live so a toggle change takes effect without a reload.
    public func setSessionStartInstrumentation(_ on: Bool) {
        AgentBridge.sessionStartInstrumentation = on
        evaluateJavaScript("window.__ripulSessionStartTimer = \(on)")
    }

    // MARK: - Native chat input height

    /// Update the web app's bottom padding to match the measured native chat input height.
    /// Retries until the web callable is available (it registers after ChatTabContent mounts).
    @ObservationIgnored private var lastReportedInputHeight: Int = 0
    @ObservationIgnored private var pendingInputHeight: Int?
    public func setNativeChatInputHeight(_ px: Int) {
        guard px != lastReportedInputHeight else { return }
        lastReportedInputHeight = px
        pendingInputHeight = px
        pushInputHeightToWeb(px)
    }

    /// Re-push the last measured height after the web view reconnects.
    public func resendInputHeight() {
        if let px = pendingInputHeight {
            pushInputHeightToWeb(px)
        }
    }

    private func pushInputHeightToWeb(_ px: Int) {
        evaluateJavaScript("""
            window.__ripulNativeChatInputHeight = \(px);
            if (window.__ripulSetBottomPadding) {
                window.__ripulSetBottomPadding(\(px));
            } else {
                var _attempts = 0;
                var _iv = setInterval(function() {
                    _attempts++;
                    if (window.__ripulSetBottomPadding) {
                        window.__ripulSetBottomPadding(\(px));
                        clearInterval(_iv);
                    } else if (_attempts > 20) {
                        clearInterval(_iv);
                    }
                }, 250);
            }
        """)
    }

    // MARK: - Recovery state

    // What the app lifecycle, the network monitor, script failures, the probe,
    // the self-heal and the host-bridge backstop have to remember. An extension
    // cannot hold stored properties, so they are here; the code that uses them
    // is in AgentBridge+AppLifecycle, +Scripts and +WebContextHealth.

    /// A recovery reload that was requested while backgrounded and deferred until
    /// foreground (WKWebView drops loads while suspended).
    @ObservationIgnored var deferredRecoveryReload: (() -> Void)?

    @ObservationIgnored var pathMonitor: NWPathMonitor?
    let pathMonitorQueue = DispatchQueue(label: "io.ripul.network-path-monitor")
    /// Fingerprint of the last observed network path (reachability + active
    /// interface). We only force recovery when this actually changes, so the
    /// baseline callback and duplicate updates are ignored.
    @ObservationIgnored var lastPathFingerprint: String?

    deinit {
        pathMonitor?.cancel()
        registry.removeObserver(registryObserverId)
    }

    /// Consecutive `evaluateJavaScript` failures. A run of these is the
    /// signature of a wedged/terminated JS context (every script fails, even
    /// ones ending in a bridgeable literal) — the state that previously left
    /// the app permanently broken until a manual cache clear.
    @ObservationIgnored var consecutiveJsEvalFailures = 0

    /// The clock the heal ladder and the host-bridge backstop read. Explicit so
    /// their floors, windows and grace periods can be tested without waiting.
    @ObservationIgnored var recoveryClock: () -> Date = { Date() }

    /// Which rung comes next and whether it is too soon. The Mac host is often
    /// unattended, so its ladder keeps going past the third attempt.
    #if os(macOS)
    @ObservationIgnored var healLadder = HealLadder(persistent: true)
    #else
    @ObservationIgnored var healLadder = HealLadder(persistent: false)
    #endif
    @ObservationIgnored var healVerifyTask: Task<Void, Never>?
    @ObservationIgnored var deferredHealTask: Task<Void, Never>?

    /// Every caller of getHostStatus() reports here. Once the bridge has been
    /// unavailable for long enough, the page is probed and an unhealthy
    /// verdict goes to the same heal ladder.
    @ObservationIgnored var hostBridgeBackstop = HostBridgeBackstop()

    // MARK: - Receive messages from web app

    public func handleMessage(_ body: Any) {
        guard let dict = body as? [String: Any],
              let type = dict["type"] as? String,
              type.hasPrefix(messagePrefix) else {
            NSLog("[AgentBridge] Received non-bridge message: %@", String(describing: body))
            return
        }

        let messageType = String(type.dropFirst(messagePrefix.count))
        if AgentBridge.verboseBridgeLog {
            NSLog("[AgentBridge] ← Received: %@", messageType)
        }

        switch messageType {
        case "inspector:toggle":
            toggleElementDebugger()
        case "inspector:show":
            showInspector()
        case "handshake":
            handleHandshake(dict)
        case "host:info":
            handleHostInfo(dict)
        case "mcp:discover":
            handleMCPDiscover(dict)
        case "mcp:invoke":
            handleMCPInvoke(dict)
        case "llm:generate":
            handleLLMGenerate(dict)
        case "theme:ready":
            applyDeviceTheme()
            NSLog("[AgentBridge] Theme ready received")
            setIfChanged(\.isThemeReady, true)
        case "models:updated":
            if isLoadingModels {
                modelRefreshPending = true
            } else {
                Task { await fetchModels() }
            }
        case "sessions:ready":
            NSLog("[AgentBridge] Sessions ready received")
            setIfChanged(\.isSessionsReady, true)
            // The web's stores have just hydrated. Any pull that ran before
            // this answered empty and was kept on the cached list; pull again
            // now rather than waiting for the next focus or settings change.
            Task { [weak self] in await self?.fetchSessions() }
        case "workScope:changed":
            // The shared work scope moved — from this app, the web Plans
            // screen, or the web sessions list. Every native surface showing
            // it re-reads; nobody caches a second copy.
            NotificationCenter.default.post(
                name: .ripulWorkScopeChanged,
                object: nil,
                userInfo: ["path": dict["path"] as? String as Any]
            )
        case "search:click":
            handleSearchClick(dict)
        case "widget:minimize":
            setIfChanged(\.wantsMinimize, true)
        case "widget:restore":
            setIfChanged(\.wantsMinimize, false)
        case "theme:set:ack":
            break
        case "scroll:state":
            handleScrollState(dict)
        case "masthead:config":
            handleMastheadConfig(dict)
        case "voice:config":
            handleVoiceConfig(dict)
        case "conversation:mode":
            if let chatId = dict["chatId"] as? String, let visible = dict["showModeSwitcher"] as? Bool,
               conversationModeSwitchers[chatId] != visible {
                conversationModeSwitchers[chatId] = visible
            }
            if let chatId = dict["chatId"] as? String, let mode = dict["mode"] as? String,
               mode == "agent" || mode == "group", conversationModes[chatId] != mode {
                conversationModes[chatId] = mode
            }
        case "composer:replyTarget":
            handleReplyTarget(dict)
        case "composer:actions":
            if let chatId = dict["chatId"] as? String,
               let data = try? JSONSerialization.data(withJSONObject: dict),
               let state = try? JSONDecoder().decode(RipulComposerState.self, from: data) {
                composerActions.update(chatId: chatId, state: state)
            }
        case "chatInput:config":
            // Sent on every chat activation, i.e. mid-slide; almost always unchanged.
            setIfChanged(\.chatInputGlassStyle, dict["glassStyle"] as? String)
            setIfChanged(\.chatInputLayout, dict["layout"] as? String)
            setIfChanged(\.chatInputShowTodos, dict["showTodos"] as? Bool ?? true)
            setIfChanged(\.chatInputShowQuickCommands, dict["showQuickCommands"] as? Bool ?? true)
        case "sessions:list:response":
            handleSessionsListResponse(dict)
        case "chat:new:ack":
            handleChatNewAck(dict)
        case "capability":
            handleCapabilityRequest(dict)
        case "capability:ping":
            handleCapabilityPing(dict)
        case "host-prefs:set":
            handleHostPrefsSet(dict)
        case "host-token:set":
            handleHostTokenSet(dict)
        case "agent:turnStarted":
            handleLifecycleEvent(.running, dict: dict)
        case "agent:turnAwaitingInput":
            handleLifecycleEvent(.awaitingInput, dict: dict)
        case "agent:turnResumed":
            handleLifecycleEvent(.running, dict: dict)
        case "agent:turnCompleted":
            handleLifecycleEvent(.completed, dict: dict)
        case "agent:turnFailed":
            handleLifecycleEvent(.failed, dict: dict)
        case "agent:stateSnapshot":
            handleLifecycleSnapshot(dict)
        case "agent:status":
            handleAgentStatusPush(dict)
        case "agent:activity":
            handleAgentActivity(dict)
        case "todos:update":
            handleTodoStateUpdate(dict)
        case "session:archived":
            // A host archived a chat (another device, the Mac itself, or an
            // agent). The session list drops the row and closes this device's
            // leftover tab for it.
            NotificationCenter.default.post(
                name: Self.remoteSessionArchivedNotification, object: self,
                userInfo: ["sessionId": dict["sessionId"] as Any, "chatId": dict["chatId"] as Any]
            )
        case "chat:status":
            if let message = dict["message"] as? String {
                let chatId = dict["chatId"] as? String ?? "unknown"
                let persistent = dict["persistent"] as? Bool ?? false
                let entry = ChatStatusEntry(timestamp: Date(), chatId: chatId, message: message)
                chatStatusLog.append(entry)
                if chatStatusLog.count > maxChatStatusEntries {
                    chatStatusLog.removeFirst(chatStatusLog.count - maxChatStatusEntries)
                }
                if persistent {
                    chatStatus.persistentChatStatus = message
                } else {
                    chatStatus.latestChatStatus = message
                }
            }
        case "chat:message":
            handleNativeChatMessage(dict)
        case "chat:prefill":
            pendingInputText = dict["text"] as? String
        case "chat:append":
            pendingInputAppend = dict["text"] as? String
        case "composer:focusTrace":
            #if os(iOS)
            guard audience == .developer else { return }
            let trace = NativeComposerFocusTrace.shared
            switch dict["operation"] as? String {
            case "start": trace.start(in: webView?.window, seconds: dict["seconds"] as? Double ?? 90)
            case "stop": trace.stop()
            default: break
            }
            send(["type": "agent-framework:composer:focusTrace:result", "requestId": dict["requestId"] ?? "",
                  "trace": trace.snapshot()])
            #endif
        case "link:open":
            if let urlString = dict["url"] as? String, let url = URL(string: urlString) {
                NSLog("[AgentBridge] Link open — url: %@", urlString)
                linkOpenDelegate?.agentBridge(self, didRequestOpenLink: url)
            }
        case "nativeEmbed:update", "nativeEmbed:anchor", "nativeEmbed:clear":
            #if os(iOS)
            nativeEmbeds?.receive(dict)
            #endif
        case "toolStrip:anchor":
            #if os(iOS)
            toolStripAnchor?.receive(dict)
            #endif
        case "toolStrip:update":
            toolStrip.receive(dict)
        case "toolStrip:clear":
            if let ownerId = dict["ownerId"] as? String { toolStrip.clear(ownerId: ownerId) }
        case "toolDefaultAction:perform":
            defaultToolActions.perform(dict)
        case "toolStripRow:update":
            #if os(iOS)
            toolStripRows?.receive(dict)
            #endif
        case "toolStripRow:anchor":
            #if os(iOS)
            toolStripRows?.receiveAnchor(dict)
            #endif
        case "toolStripRow:clear":
            #if os(iOS)
            if let ownerId = dict["ownerId"] as? String { toolStripRows?.clear(ownerId: ownerId, groupId: dict["groupId"] as? String) }
            #endif
        case "toolCallDetails:open":
            toolCallDetails.receive(dict, opening: true)
        case "toolCallDetails:update":
            toolCallDetails.receive(dict, opening: false)
        case "toolCallDetails:close":
            if let id = dict["requestId"] as? String { toolCallDetails.close(requestId: id) }
        case "file:view":
            if let filePath = dict["filePath"] as? String {
                let content = dict["content"] as? String
                let language = dict["language"] as? String
                NSLog("[AgentBridge] File view — path: %@", filePath)
                pendingFileView = FileViewRequest(
                    id: UUID().uuidString,
                    filePath: filePath,
                    content: content,
                    language: language
                )
            }
        case "fileViewer:expand":
            let title = dict["title"] as? String
            let isMarkdown = dict["isMarkdown"] as? Bool ?? false
            let filePath = dict["filePath"] as? String
            NSLog("[AgentBridge] File viewer expand — title: %@, isMarkdown: %d, path: %@", title ?? "nil", isMarkdown, filePath ?? "nil")
            let line = dict["line"] as? Int
            fileViewerLine = line.flatMap { $0 > 0 ? $0 : nil }
            fileViewerChatId = dict["chatId"] as? String
            setIfChanged(\.fileViewerFilePath, filePath)
            setIfChanged(\.fileViewerIsMarkdown, isMarkdown)
            setIfChanged(\.fileViewerExpanded, true)
            setIfChanged(\.fileViewerTitle, title)
        case "fileViewer:collapse":
            // Often an echo of requestFileViewerClose, which already cleared these.
            NSLog("[AgentBridge] File viewer collapse")
            setIfChanged(\.fileViewerExpanded, false)
            setIfChanged(\.fileViewerTitle, nil)
            setIfChanged(\.fileViewerIsMarkdown, false)
            setIfChanged(\.fileViewerFilePath, nil)
            fileViewerLine = nil
            fileViewerChatId = nil
        case "artefact:expand":
            let title = dict["title"] as? String
            NSLog("[AgentBridge] Artefact page expand — title: %@", title ?? "nil")
            setIfChanged(\.artefactPageExpanded, true)
            setIfChanged(\.artefactPageTitle, title)
        case "artefact:collapse":
            // The web echoes this after requestArtefactPageClose already cleared it.
            NSLog("[AgentBridge] Artefact page collapse")
            setIfChanged(\.artefactPageExpanded, false)
            setIfChanged(\.artefactPageTitle, nil)
        case "page:context":
            let page = dict["page"] as? String ?? "chat"
            let showHeader = dict["showNativeHeader"] as? Bool ?? true
            let showInput = dict["showNativeChatInput"] as? Bool ?? true
            let showControls = dict["showSessionControls"] as? Bool ?? true
            let safeArea = dict["safeAreaMode"] as? String ?? "full"
            NSLog("[AgentBridge] Page context — page: %@, header: %d, input: %d, controls: %d, safeArea: %@",
                  page, showHeader, showInput, showControls, safeArea)
            setIfChanged(\.currentPageContext, PageContext(
                page: page,
                showNativeHeader: showHeader,
                showNativeChatInput: showInput,
                showSessionControls: showControls,
                safeAreaMode: safeArea,
                mirrorUrl: dict["mirrorUrl"] as? String
            ))
        case "getConsoleLogs":
            let requestId = dict["requestId"] as? String ?? ""
            // Native logs live in the host-owned RipulLog buffer (so they exist from
            // launch, before this bridge did); web console lines live here. The relay's
            // device_console_logs promises both, so merge by timestamp.
            let logs = RipulLog.merged(with: consoleLogs).map { e -> [String: Any] in
                var entry: [String: Any] = [
                    "level": e.level,
                    "message": e.message,
                    "ts": Int64(e.timestamp.timeIntervalSince1970 * 1000)
                ]
                if let stack = e.stack { entry["stack"] = stack }
                return entry
            }
            if let data = try? JSONSerialization.data(withJSONObject: logs),
               let json = String(data: data, encoding: .utf8) {
                evaluateJavaScript("window.__agentBridgeReceive({type:'agent-framework:consoleLogs:response',requestId:'\(requestId)',logs:\(json)})")
            }
        case "getNetworkLogs":
            let requestId = dict["requestId"] as? String ?? ""
            let logs = networkLogs.map { e -> [String: Any] in
                var entry: [String: Any] = [
                    "method": e.method,
                    "url": e.url,
                    "status": e.status,
                    "statusText": e.statusText,
                    "durationMs": e.durationMs,
                    "requestSize": e.requestSize,
                    "responseSize": e.responseSize,
                    "reqHeaders": e.requestHeaders,
                    "resHeaders": e.responseHeaders,
                    "ts": Int64(e.timestamp.timeIntervalSince1970 * 1000)
                ]
                if let error = e.error { entry["error"] = error }
                return entry
            }
            if let data = try? JSONSerialization.data(withJSONObject: logs),
               let json = String(data: data, encoding: .utf8) {
                evaluateJavaScript("window.__agentBridgeReceive({type:'agent-framework:networkLogs:response',requestId:'\(requestId)',logs:\(json)})")
            }
        case "kill":
            let reason = dict["reason"] as? String ?? "remote_user"
            NSLog("[AgentBridge] Kill command received (reason: %@) — exiting for guardian restart", reason)
            #if os(macOS)
            // _exit() terminates immediately — no cleanup handlers, no quit file.
            // The guardian (in its own process group) detects the exit and restarts.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                _exit(0)
            }
            #endif
        default:
            if onUnhandledMessage?(messageType, dict) != true {
                NSLog("[AgentBridge] Unhandled message: %@", messageType)
            }
        }
    }

    @ObservationIgnored var jsErrorMessages: [String] = []
    @ObservationIgnored var jsErrorDebounce: DispatchWorkItem?

    /// Detailed error log for the user to copy and share with the developer.
    public var loadErrorDetails: String?

    // MARK: - Logs

    /// The web app's console and network output, and what of the console is
    /// kept across launches. `AgentBridge+Logs.swift` is how the app reaches it.
    let logs = BridgeLogStore()

    /// Rolling buffer of CLI pipeline status messages for native diagnostic display.
    /// Not @Published — appended frequently and only consumed by ChatStatusLogView sheet.
    /// Views see updates whenever any other @Published property triggers a re-render,
    /// or via the dedicated subject.
    @ObservationIgnored public var chatStatusLog: [ChatStatusEntry] = [] {
        didSet { chatStatusLogSubject.send(()) }
    }
    /// Dedicated publisher for chatStatusLog changes (replaces implicit @Published).
    public let chatStatusLogSubject = PassthroughSubject<Void, Never>()
    /// Chat-status line fields (latest / persistent), isolated onto their own leaf
    /// so per-pipeline-stage writes don't re-render the WKWebView host. Access as
    /// `chatStatus.latestChatStatus` / `chatStatus.persistentChatStatus`.
    public let chatStatus = ChatStatusStore()
    private let maxChatStatusEntries = 200

    /// Unified log sink for both web-view and native-originated log entries.
    ///
    /// Receives log entries from two sources:
    ///   - Web-view console.* calls, forwarded via the agentLog WKScriptMessageHandler
    ///     registered in AgentWebView (intercepts every console.log/warn/error call).
    ///   - Swift code calling this method directly to inject native log lines into the
    ///     same buffer (e.g. SessionManager startup timeline, relay listRemoteSessions).
    ///
    /// The consoleLogs array is what device_console_logs exposes — it is a single
    /// unified stream of both web and native log output.
    public func handleConsoleLog(_ message: String) {
        // Intercept the curtainLowered signal emitted by V2ChatScroller when the
        // new chat's pre-warm sweep finishes. Restore wkWebView.alpha to reveal
        // the new chat cleanly. This message is posted via agentLog so it shares
        // the existing message channel without needing a new handler registration.
        // Foundation.* so the NSLog tee shadow doesn't re-ingest what we're already
        // appending below (would double-append + recurse). Gated: this fires once
        // per bridged web console.log, which floods during streaming; NSLog is
        // synchronous main-thread I/O and invisible on-device without Xcode. The
        // in-app buffer append below is the on-device log path and stays live.
        if AgentBridge.verboseBridgeLog {
            Foundation.NSLog("[JS] %@", message)
        }

        let entry = logs.appendConsole(message)

        // Collect JS errors that occur before the bridge connects.
        // Wait long enough for the bridge to finish its normal handshake
        // before surfacing an error — transient startup errors are common
        // and don't mean the app is broken.
        if !isConnected && entry.level == "ERROR" {
            jsErrorMessages.append(entry.message)

            jsErrorDebounce?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self, !self.isConnected else { return }
                self.loadError = "Something went wrong loading the app."
                self.loadErrorDetails = self.jsErrorMessages.joined(separator: "\n")
            }
            jsErrorDebounce = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: item)
        }
    }

    public func clearChatStatusLog() {
        chatStatusLog.removeAll()
        chatStatus.latestChatStatus = nil
        chatStatus.persistentChatStatus = nil
    }

    // MARK: - Sending to the agent

    /// Start a new chat with an optional prompt via the bridge protocol.
    /// The web app handles chat creation and prompt auto-execution.
    public func startNewChat(prompt: String? = nil) async {
        guard attachedWebView != nil else {
            NSLog("[AgentBridge] Cannot startNewChat — webView is nil")
            return
        }
        NSLog("[AgentBridge] → Starting new chat (prompt: %@)", prompt != nil ? "yes" : "no")
        let reply = await callPage("__ripulCreateChat", [],
                                   .ifMissing("{ success: false, error: '__ripulCreateChat not defined' }"))
        guard reply.error == nil else { return }
        guard let chatId = reply.dictionary?["chatId"] as? String else {
            NSLog("[AgentBridge] startNewChat failed: %@", String(describing: reply.value))
            return
        }
        NSLog("[AgentBridge] New chat created: %@", chatId)
        // Point the button projection at the new chat immediately —
        // without this, a running previous chat's pause button carries
        // over onto the brand-new (idle) chat until the sessions push
        // catches up.
        pendingActiveSourceChatId = chatId
        refreshActiveAgentFlags()
        if let prompt {
            _ = await callPage("__ripulSubmitMessage", [prompt], .orElse("{ success: false }"), log: .none)
        }
        await fetchSessions()
    }

    /// Submit a message to the active chat session via the web app's
    /// global `__ripulSubmitMessage` callable.
    /// - Parameters:
    ///   - text: The message text.
    ///   - imageAttachments: Optional array of base64-encoded images.
    ///     Each element must have keys: `id`, `mediaType`, `data`, and optionally `name`.
    ///   - addressedTo: Optional array of participant IDs picked from the native
    ///     @-mention picker. Populates `addressedTo` on the resulting chat action
    ///     so LLMProxy can route the turn to the correct agent.
    @discardableResult
    public func submitMessage(
        _ text: String,
        imageAttachments: [[String: String]]? = nil,
        addressedTo: [String]? = nil,
        modality: String? = nil
    ) async -> Bool {
        setIfChanged(\.messageSubmissionError, nil)
        guard attachedWebView != nil else { return false }
        let contextSession = currentSourceChatId
        let contextAttachments = composerContexts.attachments(for: contextSession)
        let combinedImages = RipulContextAttachment.images(imageAttachments, attachments: contextAttachments)
        // Images, addressees and modality (e.g. "voice") are positional. An
        // absent one goes as `undefined`, so the others keep their places.
        let absent: Any? = Self.undefinedArgument
        let reply = await callPage("__ripulSubmitMessage", [
            RipulContextAttachment.message(text, attachments: contextAttachments),
            combinedImages.isEmpty ? absent : combinedImages,
            addressedTo?.isEmpty == false ? addressedTo : absent,
            modality.map { $0 as Any } ?? absent,
        ], .orElse("{ success: false }"))
        if let error = reply.error {
            messageSubmissionError = error.localizedDescription
            return false
        }
        guard let dict = reply.dictionary else { return false }
        let success = dict["success"] as? Bool ?? false
        if !success { messageSubmissionError = dict["error"] as? String }
        if success { composerContexts.didSend(contextAttachments, session: contextSession) }
        return success
    }

    public func refreshComposerActions(chatId: String) async {
        let reply = await callPage("__ripulGetComposerState", [chatId],
                                   .orElse("{actions:[],runningSendLabel:'Send'}"), log: .none)
        if let error = reply.error {
            handleConsoleLog("[ComposerActions] Refresh failed: \(error.localizedDescription)")
            return
        }
        // isValidJSONObject first: handed a bare number or string, data(withJSONObject:)
        // raises an Objective-C exception, which `try?` does not catch.
        if let raw = reply.value, JSONSerialization.isValidJSONObject(raw),
           let data = try? JSONSerialization.data(withJSONObject: raw),
           let state = try? JSONDecoder().decode(RipulComposerState.self, from: data) {
            composerActions.update(chatId: chatId, state: state)
        }
    }

    /// Returns an error on unconfirmed delivery; the native draft stays owned
    /// by the composer until this operation has been acknowledged.
    public func submitComposerAction(chatId: String, action: String, text: String,
                                     imageAttachments: [[String: String]]?) async -> String? {
        guard attachedWebView != nil, currentSourceChatId == chatId else { return "The active chat changed." }
        let contextAttachments = composerContexts.attachments(for: chatId)
        let input: [String: Any] = [
            "text": RipulContextAttachment.message(text, attachments: contextAttachments),
            "imageAttachments": RipulContextAttachment.images(imageAttachments, attachments: contextAttachments),
        ]
        let reply = await callPage("__ripulSubmitComposerAction", [chatId, action, input],
                                   .orElse("{success:false, error:'Composer actions are unavailable.'}"), log: .none)
        if let error = reply.error { return error.localizedDescription }
        guard reply.succeeded else {
            return reply.dictionary?["error"] as? String ?? "Message delivery was not confirmed."
        }
        composerContexts.didSend(contextAttachments, session: chatId)
        return nil
    }

    /// Send a human note to the chat stream. Notes appear as first-class panels
    /// but are NOT sent to the agent — they are for human-to-human communication.
    @discardableResult
    public func submitNote(_ text: String) async -> Bool {
        // senderDisplayName is resolved on the web side from the logged-in Clerk user
        let reply = await callPage("__ripulSubmitNote", [text], .orElse("{ success: false }"))
        return reply.dictionary?["success"] as? Bool ?? false
    }

    /// Interrupt (pause) the currently running agent for the active session.
    @discardableResult
    public func interruptAgent() async -> Bool {
        // Interrupt the chat the NATIVE UI is showing — the web's own notion of
        // "active chat" can lag ours, and interrupting whatever it happens to be
        // on is how a pause tap used to no-op against an empty chat while the
        // genuinely-running one kept going.
        let target = activeSourceChatId
        let reply = await callPage("__ripulInterruptAgent", [target], .orElse("{ success: false }"))
        guard let dict = reply.dictionary else { return false }
        let success = dict["success"] as? Bool ?? false
        if success, let target {
            // Optimistically mark the turn over so the button clears
            // immediately — the web's lifecycle event may lag, or never
            // arrive if a remote host's connection is lost.
            applySessionPhase(.completed, chatId: target, sequence: nil)
        }
        return success
    }

    /// Fetch the current show-thinking mode from the web app.
    public func syncShowThinking() async {
        let reply = await callPage("__ripulGetShowThinking", [], .orElse("{ success: false, mode: 'none' }"))
        if let mode = reply.dictionary?["mode"] as? String {
            await MainActor.run { showThinkingMode = mode }
        }
    }

    /// Set inline thinking display mode in the web app ("none", "folded", or "open").
    @discardableResult
    public func setShowThinking(_ mode: String) async -> Bool {
        let reply = await callPage("__ripulSetShowThinking", [mode], .orElse("{ success: false }"))
        guard reply.succeeded else { return false }
        await MainActor.run { showThinkingMode = mode }
        return true
    }

    /// Resume a paused agent, optionally with additional context.
    @discardableResult
    public func resumeAgent(context: String? = nil) async -> Bool {
        // No context, or only white space, goes as `undefined`.
        var ctx: Any? = Self.undefinedArgument
        if let context, !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { ctx = context }
        // Scope the resume to the native active chat (same reasoning as
        // interruptAgent — the web's active chat may differ from ours).
        let reply = await callPage("__ripulResumeAgent", [ctx, activeSourceChatId], .orElse("{ success: false }"))
        guard let dict = reply.dictionary else { return false }
        let success = dict["success"] as? Bool ?? false
        if !success {
            NSLog("[AgentBridge] resumeAgent returned failure: %@", dict["error"] as? String ?? "unknown")
        }
        return success
    }

    /// Interrogate the web app for the current agent status of a chat (the
    /// native active chat by default) and apply the answer per-chat. The active
    /// chat's `isAgentRunning`/`isAgentPaused` update as a side effect when the
    /// answer concerns it. Call after session transitions to correct stale state.
    @discardableResult
    public func syncAgentStatus(chatId: String? = nil) async -> (isRunning: Bool, isPaused: Bool) {
        let target = chatId ?? activeSourceChatId
        let reply = await runPage(
            """
            if (window.__ripulGetAgentLifecycleSnapshot) {
                return await window.__ripulGetAgentLifecycleSnapshot(targetChatId);
            }
            return await window.__ripulGetAgentStatus?.(targetChatId) ?? { isRunning: false, isPaused: false };
            """,
            arguments: ["targetChatId": target.map { $0 as Any } ?? NSNull()])
        if reply.isDetached { return (false, false) }
        if let dict = reply.dictionary {
            // Trust the chatId STAMPED ON THE RESPONSE, never assume it's
            // the chat we asked about — an older web build ignores the
            // argument and answers for its own active tab. Keyed application
            // makes a mismatched answer harmless: it updates that chat's
            // row, not the active chat's buttons.
            let respChatId = dict["chatId"] as? String
            if let rawPhase = dict["phase"] as? String,
               let phase = AgentTurnPhase(rawValue: rawPhase) {
                if let respChatId, !respChatId.isEmpty {
                    applySessionPhase(phase, chatId: respChatId, sequence: dict["sequence"] as? Int, timestamp: dict["timestamp"])
                }
                return (isAgentRunning, isAgentPaused)
            }
            // Legacy status shape ({ isRunning, isPaused, chatId }).
            let running = dict["isRunning"] as? Bool ?? false
            let paused = dict["isPaused"] as? Bool ?? false
            if let respChatId, !respChatId.isEmpty {
                if running || paused {
                    applySessionPhase(paused ? .awaitingInput : .running, chatId: respChatId, sequence: nil, timestamp: dict["timestamp"])
                } else if chatTurnPhases[respChatId] != nil {
                    applySessionPhase(.completed, chatId: respChatId, sequence: nil, timestamp: dict["timestamp"])
                }
            }
        }
        return (isAgentRunning, isAgentPaused)
    }

    // MARK: - The session list

    /// Apply the active-session id reported by a sessions-list response, but let
    /// an in-flight navigation win. focusSession sets `activeSessionId` then kicks
    /// off `fetchSessions`; the web app's list response can lag that focus and
    /// report the PREVIOUS active session, clobbering the just-tapped row and
    /// dropping its selection highlight. While `navigatingToSessionId` is set
    /// (cleared after the slide settles), it is the authoritative target.
    private func applyActiveSessionIdFromResponse(_ activeId: String?) {
        let target = navigatingToSessionId ?? activeId
        if let target, activeSessionId != target { activeSessionId = target }
        // Refresh even when the id didn't change: the sessions list content may
        // have (a just-created chat becoming resolvable), which changes what
        // `activeSourceChatId` maps to and hands off the pending override.
        refreshActiveAgentFlags()
    }

    /// Whether an `agent:activity` event is fresh enough to drive a LIVE "what's
    /// it doing now" subtitle. On startup/reconnect the web app replays historical
    /// activity events carrying their ORIGINAL (old) timestamps (same property
    /// `advanceLastActive` relies on). Latching those shows a stale tool subtitle
    /// that hides the row's age and never clears — the finished turn's `completion`
    /// was never received because the app was closed when it landed. A missing or
    /// unparseable timestamp is treated as live to avoid regressing events that
    /// don't carry one.
    private func isFreshActivityTimestamp(_ raw: Any?) -> Bool {
        let ms: TimeInterval?
        if let v = raw as? TimeInterval { ms = v }
        else if let v = raw as? Int { ms = TimeInterval(v) }
        else { ms = nil }
        guard let ms, ms > 0 else { return true }
        return Date().timeIntervalSince1970 - ms / 1000 < 60
    }

    /// Fetch the current list of chat sessions by calling the web app's
    /// global function directly. Updates `sessions` and `activeSessionId`.
    @ObservationIgnored private var fetchSessionsCallCount = 0
    @ObservationIgnored private var sessionFocusRevision = 0
    public func fetchSessions() async {
        // Entries written before the reply-fetch existed — or while the web
        // was unreachable — have no text and would otherwise stay mute for
        // ever, since a reply is only pulled when a turn ENDS. Sweeping here
        // means they fill themselves the next time the app runs, rather than
        // needing the session to complete another turn first.
        defer {
            Task { @MainActor in
                // Hydrate the rows from disk too — the published set starts
                // empty on launch, so without this nothing is marked unread
                // until the next turn ends.
                publishUnreadIds()
                await backfillMissingReplies()
            }
        }
        fetchSessionsCallCount += 1
        let focusRevision = sessionFocusRevision
        let fetchStart = CFAbsoluteTimeGetCurrent()
        guard let webView else {
            if fetchSessionsCallCount <= 3 {
                Self.debugLog("[AgentBridge] fetchSessions #\(fetchSessionsCallCount): webView is nil")
            }
            lastSessionsError = "webView is nil"
            return
        }
        // Liveness heartbeat only — every 100th call (~20min) is plenty to
        // confirm polling is alive. Every 10th was ~1.5k lines a day.
        if fetchSessionsCallCount <= 3 || fetchSessionsCallCount % 100 == 0 {
            Self.debugLog("[AgentBridge] fetchSessions #\(fetchSessionsCallCount), sessions=\(sessions.count), cliSessions=\(sessions.filter { $0.provider == "claude-cli" || $0.provider == "codex-cli" }.count)")
        }

        do {
            // callAsyncJavaScript awaits the Promise — evaluateJavaScript does not.
            let result = try await webView.callAsyncJavaScript(
                """
                if (!window.__ripulGetSessions) return {sessions:[], activeId:null, error:'__ripulGetSessions not defined'};
                return await window.__ripulGetSessions();
                """,
                contentWorld: .page
            )

            guard let dict = result as? [String: Any] else {
                lastSessionsError = "result not [String:Any]: \(String(describing: result))"
                return
            }

            // Surface any error from the JS side
            let jsError = dict["error"] as? String

            guard let sessionsArray = dict["sessions"] as? [[String: Any]] else {
                lastSessionsError = jsError ?? "no sessions key, dict keys: \(Array(dict.keys))"
                return
            }

            let activeId = dict["activeId"] as? String
            let parsed: [ChatSession] = sessionsArray.compactMap(ChatSession.fromWire)

            // Filter out ephemeral commit-viewer sessions (tracked explicitly
            // by CommitsScreen via ephemeralSessionIds, persisted to UserDefaults).
            let filtered = parsed.filter { !self.ephemeralSessionIds.contains($0.id) }

            if !filtered.isEmpty {
                // Only update if changed to avoid unnecessary SwiftUI re-renders
                if self.sessions != filtered {
                    // Detect CLI session renames and propagate to JSONL files.
                    // Only fire for displayNames that came from CLI history or
                    // an explicit user rename ("cli" / "user"). Auto-generated
                    // values ("auto" — descriptor in-memory or date fallback)
                    // would write themselves back to the JSONL as a
                    // `custom-title`, locking out Claude's own ai-title.
                    let oldByID = Dictionary(self.sessions.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
                    let isInitialLoad = oldByID.isEmpty
                    // Only real renames earn a line. This previously appended
                    // every CLI session with old→new on every refresh, even when
                    // nothing changed: ~10KB per line, ~3MB/day, and it pushed
                    // the signals that matter clean out of the window.
                    var renameNotes: [String] = []
                    var skipAuto = 0
                    var initialSync = 0
                    for session in filtered {
                        // claude-cli only: onCliSessionRenamed is wired to
                        // ClaudeCliServer, the sole server with a title-write
                        // endpoint. Codex sessions would misfire into the wrong
                        // store (failed lookup + pointless retry).
                        if session.provider == "claude-cli" {
                            let oldName = oldByID[session.id]?.displayName ?? "(new)"
                            // Older hosts don't send displayNameSource — treat as "user" for back-compat.
                            let source = session.displayNameSource ?? "user"
                            let isAuthoritative = source == "cli" || source == "user"
                            if !isAuthoritative {
                                skipAuto += 1
                            } else if isInitialLoad {
                                // Sync all CLI session names on first load so reconnects pick up renames
                                initialSync += 1
                                self.onCliSessionRenamed?(session.sourceChatId, session.displayName, session.displayNameRenamedAt)
                            } else if let old = oldByID[session.id], old.displayName != session.displayName {
                                renameNotes.append("[\(session.sourceChatId): '\(oldName)'→'\(session.displayName)' src=\(source) RENAME_DETECTED]")
                                self.onCliSessionRenamed?(session.sourceChatId, session.displayName, session.displayNameRenamedAt)
                            }
                        }
                    }
                    if self.sessions.count != filtered.count || !renameNotes.isEmpty || initialSync > 0 {
                        var renameLog = "[AgentBridge] sessions changed (\(self.sessions.count)→\(filtered.count))"
                        if initialSync > 0 || skipAuto > 0 {
                            renameLog += " initialSync=\(initialSync) skipAuto=\(skipAuto)"
                        }
                        if !renameNotes.isEmpty { renameLog += " " + renameNotes.joined(separator: " ") }
                        Self.debugLog(renameLog)
                    }
                    self.sessions = filtered
                    ChatSession.saveToCache(filtered)
                }
                if focusRevision == sessionFocusRevision { applyActiveSessionIdFromResponse(activeId) }
                setIfChanged(\.lastSessionsError, nil)
            } else {
                setIfChanged(\.lastSessionsError, jsError ?? "0 sessions parsed from \(sessionsArray.count) items")
                if focusRevision == sessionFocusRevision { applyActiveSessionIdFromResponse(activeId) }
            }
        } catch {
            setIfChanged(\.lastSessionsError, "callAsyncJS: \(error.localizedDescription)")
        }
    }

    /// Legacy message-based request (kept for handshake auto-request).
    public func requestSessions() {
        send([
            "type": "\(messagePrefix)sessions:list",
            "version": protocolVersion,
            "timestamp": currentTimestamp(),
            "requestId": UUID().uuidString,
        ])
    }

    /// Switch the web app to a specific chat session.
    /// The window-level curtain view — added directly to UIWindow so it is
    /// part of the SAME CATransaction batch that gets committed before any
    /// transition animation frame. SwiftUI @Published changes cannot guarantee
    /// Called by the dedicated curtainLowered WKScriptMessageHandler — kept for
    /// compatibility but now a no-op since the curtain approach is removed.
    @MainActor
    public func lowerWindowCurtain() { /* no-op — curtain approach removed */ }

    // MARK: - Drag freeze (swipe-back gesture)

    /// Disable WKWebView interaction during a swipe gesture so the user can't
    /// accidentally scroll the chat while dragging. Call on first gesture .changed.
    /// Does NOT add a visual overlay — the content stays visible.
    public func beginDrag() {
        #if os(iOS)
        webView?.isUserInteractionEnabled = false
        #endif
    }

    /// Re-enable WKWebView interaction after the gesture ends.
    public func endDrag(delay: Double = 0) {
        #if os(iOS)
        if delay <= 0 {
            webView?.isUserInteractionEnabled = true
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.webView?.isUserInteractionEnabled = true
            }
        }
        #endif
    }

    // MARK: - Focusing a session

    /// Focus a chat session. __ripulFocusSession now awaits the V2ChatScroller
    /// sweep before returning, so this call only completes once the new chat
    /// content is fully rendered. The caller (tap handler) then triggers the
    /// native navigation — the sheet dismissal IS the slide-in transition.
    public func focusSession(id: String) async {
        guard !Task.isCancelled else { return }
        guard let webView else {
            NSLog("[AgentBridge] focusSession: webView is nil")
            return
        }
        let focusStart = CFAbsoluteTimeGetCurrent()
        sessionFocusRevision += 1
        handleConsoleLog("LOG: [STARTUP] focusSession START id=\(id.suffix(8))")
        // Clear any new-chat override, then let the activeSessionId didSet
        // re-derive the buttons from the target chat's known phase — switching
        // into a running chat shows its pause button immediately, and a chat
        // with no phase entry shows none.
        pendingActiveSourceChatId = nil
        // The didSet already ignores an identical id; skip the publish too, so
        // re-opening the current chat doesn't re-render the shell mid-slide.
        setIfChanged(\.activeSessionId, id)
        // Opening a session is reading it — drop it from the waiting set so
        // Siri stops offering something you are now looking at.
        markSessionRead(id)
        do {
            _ = try await webView.callAsyncJavaScript(
                "if (window.__ripulFocusSession) await window.__ripulFocusSession(sessionId);",
                arguments: ["sessionId": id],
                contentWorld: .page
            )
            guard !Task.isCancelled else { return }
            let focusMs = Int((CFAbsoluteTimeGetCurrent() - focusStart) * 1000)
            handleConsoleLog("LOG: [STARTUP] focusSession DONE (\(focusMs)ms)")
        } catch {
            NSLog("[AgentBridge] focusSession error: %@", error.localizedDescription)
        }
        guard !Task.isCancelled else { return }
        // Defer post-focus catch-up past the native open slide. fetchSessions()
        // re-publishes the session list (and syncAgentStatus/syncShowThinking poke
        // the web view), which re-renders the view DURING the slide-in and visibly
        // stutters it — this is the one thing the different-chat open does that the
        // same-chat re-entry (smooth) does not. The work is non-urgent catch-up, so
        // let the slide settle first.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self, self.activeSessionId == id else { return }
            await self.syncAgentStatus()
            await self.syncShowThinking()
            await self.fetchSessions()
        }
    }

    // MARK: - Loading the model list

    /// Fetch available models from the web app's model catalog.
    /// Updates `availableModels`, `selectedModelId`, and `modelSelectionEnabled`.
    /// Waits for the JS callable to be registered before calling.
    public func fetchModels() async {
        guard !isLoadingModels else { return }
        modelLoading.isLoading = true
        defer { modelLoading.isLoading = false }
        repeat {
            modelRefreshPending = false
            for attempt in 1...3 {
                guard !Task.isCancelled else { return }
                let success = await fetchModelsOnce()
                if success { break }
                if attempt < 3 {
                    NSLog("[AgentBridge] fetchModels: empty on attempt %d, retrying in 2s...", attempt)
                    do { try await Task.sleep(nanoseconds: 2_000_000_000) }
                    catch { return }
                }
            }
        } while modelRefreshPending
    }

    private func fetchModelsOnce() async -> Bool {
        let generation = modelCacheGeneration
        // Every @Published write re-renders every view observing the bridge
        // (ContentView and AgentScreen included), changed or not, so this
        // fetch writes only what actually changed. `lastModelsError` is set
        // once per outcome — no clear-then-reset around the await, which cost
        // two re-renders per attempt while an error persisted.

        guard let webView else {
            setIfChanged(\.lastModelsError, "WebView not available")
            return false
        }

        do {
            // Wait for __ripulGetModels to be defined (registered by registerNativeCallables),
            // then call it with a timeout. This doesn't depend on the bridge handshake —
            // callAsyncJavaScript works as soon as the web app has registered the callable.
            let result = try await webView.callAsyncJavaScript(
                """
                // Poll for up to 10s for the callable to be registered
                for (let i = 0; i < 40; i++) {
                    if (window.__ripulGetModels) break;
                    await new Promise(r => setTimeout(r, 250));
                }
                if (!window.__ripulGetModels) return {models:[], selectedModelId:null, error:'__ripulGetModels not defined after 10s'};
                try {
                    const r = await Promise.race([
                        window.__ripulGetModels(),
                        new Promise((_, reject) => setTimeout(() => reject(new Error('__ripulGetModels timed out after 15s')), 15000))
                    ]);
                    return r;
                } catch (e) {
                    return {models:[], selectedModelId:null, error: String(e)};
                }
                """,
                contentWorld: .page
            )

            guard generation == modelCacheGeneration else { return false }
            guard let dict = result as? [String: Any] else {
                setIfChanged(\.lastModelsError, "Unexpected response format")
                return false
            }

            if let error = dict["error"] as? String {
                setIfChanged(\.lastModelsError, error)
                NSLog("[AgentBridge] fetchModels error: %@", error)
                return false
            }

            guard let modelsArray = dict["models"] as? [[String: Any]] else {
                setIfChanged(\.lastModelsError, "No models array in response")
                return false
            }

            let parsed: [ModelInfo] = modelsArray.compactMap { item in
                guard let id = item["id"] as? String,
                      let name = item["name"] as? String,
                      let modelId = item["modelId"] as? String,
                      let provider = item["provider"] as? String else { return nil }
                return ModelInfo(
                    id: id,
                    name: name,
                    modelId: modelId,
                    provider: provider,
                    group: (item["group"] as? String) ?? provider,
                    description: item["description"] as? String,
                    supportsThinking: (item["supportsThinking"] as? Bool) ?? false,
                    type: item["type"] as? String,
                    url: (item["url"] as? String) ?? "",
                    enabled: (item["enabled"] as? Bool) ?? true,
                    sortOrder: item["sortOrder"] as? Int,
                    cliModelId: item["cliModelId"] as? String,
                    cliRawMode: (item["cliRawMode"] as? Bool) ?? false,
                    cliEffort: item["cliEffort"] as? String,
                    cliMode: item["cliMode"] as? String,
                    cliSupportedEfforts: item["cliSupportedEfforts"] as? [String],
                    cliDefaultEffort: item["cliDefaultEffort"] as? String,
                    perMInput: (item["perMInput"] as? NSNumber)?.doubleValue,
                    perMOutput: (item["perMOutput"] as? NSNumber)?.doubleValue,
                    tier: item["tier"] as? String,
                    pickable: item["pickable"] as? Bool
                )
            }

            if parsed.isEmpty {
                setIfChanged(\.lastModelsError, "No models available (raw count: \(modelsArray.count))")
                // Do NOT overwrite a previously-good catalog with an empty one:
                // a single timed-out/hung fetch (relay round-trip on the phone,
                // web app mid-boot) used to zero `availableModels` here, which
                // silently hides the quick-launch New Session pill until the
                // next fully-clean fetch. Keep last-good; only an explicit
                // non-empty response replaces the list.
                if availableModels.isEmpty {
                    setIfChanged(\.selectedModelId, dict["selectedModelId"] as? String)
                    setIfChanged(\.modelSelectionEnabled, (dict["modelSelectionEnabled"] as? Bool) ?? true)
                }
                NSLog("[AgentBridge] fetchModels error: empty response (keeping %d cached models)", availableModels.count)
                return false
            }

            let responseUserId = dict["userId"] as? String
            if let expected = modelCacheUserId, responseUserId != expected {
                setIfChanged(\.lastModelsError, "Waiting for account models")
                return false
            }
            if self.availableModels != parsed { self.availableModels = parsed }
            if let userId = modelCacheUserId, responseUserId == userId,
               let data = try? JSONEncoder().encode(parsed) {
                sessionCache?.set(data, forKey: "ripul.models.v1.\(userId)")
            }
            let selected = dict["selectedModelId"] as? String
            if self.selectedModelId != selected { self.selectedModelId = selected }
            let selectionEnabled = (dict["modelSelectionEnabled"] as? Bool) ?? true
            if self.modelSelectionEnabled != selectionEnabled { self.modelSelectionEnabled = selectionEnabled }
            setIfChanged(\.lastModelsError, nil)
            NSLog("[AgentBridge] fetchModels: %d models, selected: %@",
                  parsed.count, self.selectedModelId ?? "nil")
            return !parsed.isEmpty
        } catch {
            setIfChanged(\.lastModelsError, error.localizedDescription)
            NSLog("[AgentBridge] fetchModels error: %@", error.localizedDescription)
            return false
        }
    }

    // MARK: - Importing, closing and leaving sessions

    /// Import a Claude CLI session into the web app.
    /// Creates a new chat tab populated with the session's conversation history.
    /// - Parameters:
    ///   - messages: Array of JSONL message dictionaries (user/assistant/custom-title entries)
    ///   - sessionId: The CLI session UUID (used for --resume)
    ///   - title: Display title for the chat tab
    /// - Returns: true if import succeeded
    @discardableResult
    public func importCliSession(
        messages: [[String: Any]],
        sessionId: String,
        title: String,
        subAgentSessions: [(agentId: String, messages: [[String: Any]])] = []
    ) async -> Bool {
        guard let webView else { return false }
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: messages)
            let messagesJson = String(data: jsonData, encoding: .utf8) ?? "[]"

            // Build sub-agent sessions JSON array
            var subAgentsJson = "[]"
            if !subAgentSessions.isEmpty {
                let subAgentsArray: [[String: Any]] = subAgentSessions.map { session in
                    ["agentId": session.agentId, "messages": session.messages]
                }
                let subAgentsData = try JSONSerialization.data(withJSONObject: subAgentsArray)
                subAgentsJson = String(data: subAgentsData, encoding: .utf8) ?? "[]"
            }

            let result = try await webView.callAsyncJavaScript(
                """
                if (!window.__ripulImportCliSession) return { success: false, error: '__ripulImportCliSession not defined' };
                const messages = JSON.parse(messagesJson);
                const subAgentSessions = JSON.parse(subAgentsJson);
                const params = { sessionId, title, messages };
                if (subAgentSessions.length > 0) params.subAgentSessions = subAgentSessions;
                return await window.__ripulImportCliSession(params);
                """,
                arguments: [
                    "messagesJson": messagesJson,
                    "subAgentsJson": subAgentsJson,
                    "sessionId": sessionId,
                    "title": title,
                ],
                contentWorld: .page
            )

            if let dict = result as? [String: Any],
               let success = dict["success"] as? Bool, success {
                let subCount = subAgentSessions.count
                NSLog("[AgentBridge] importCliSession: imported %d messages + %d sub-agents for session %@", messages.count, subCount, sessionId)
                await fetchSessions()
                return true
            }

            let error = (result as? [String: Any])?["error"] as? String ?? "unknown"
            NSLog("[AgentBridge] importCliSession failed: %@", error)
            return false
        } catch {
            NSLog("[AgentBridge] importCliSession error: %@", error.localizedDescription)
            return false
        }
    }

    /// Close (delete) a chat session tab.
    public func closeSession(id: String) async {
        let reply = await callPage("__ripulCloseSession", [id])
        guard reply.failure() == nil else { return }
        // Remove from local state immediately
        let closed = sessions.first(where: { $0.id == id })
        // removeAll publishes even when nothing matches.
        if sessions.contains(where: { $0.id == id }) { sessions.removeAll { $0.id == id } }
        if let sourceChatId = closed?.sourceChatId {
            sessionList.sessionPhases.removeValue(forKey: sourceChatId)
            sessionLifecycleSequences.removeValue(forKey: sourceChatId)
        }
        if activeSessionId == id {
            activeSessionId = sessions.first?.id
        }
    }

    /// End an invited guest's own membership in a shared chat (requires a
    /// fresh owner invitation to rejoin), then close its local tab. Distinct
    /// from `closeSession`, which only ever hides a chat locally.
    public func leaveSharedChat(id: String) async -> (success: Bool, error: String?) {
        let reply = await callPage("__ripulLeaveSharedChat", [id], log: .none)
        if let reason = reply.failure(detached: "Reconnect and try again.") { return (false, reason) }
        guard reply.succeeded else {
            return (false, reply.dictionary?["error"] as? String ?? "Couldn't leave this chat.")
        }
        let closed = sessions.first(where: { $0.id == id })
        // removeAll publishes even when nothing matches.
        if sessions.contains(where: { $0.id == id }) { sessions.removeAll { $0.id == id } }
        if let sourceChatId = closed?.sourceChatId {
            sessionList.sessionPhases.removeValue(forKey: sourceChatId)
            sessionLifecycleSequences.removeValue(forKey: sourceChatId)
        }
        if activeSessionId == id {
            activeSessionId = sessions.first?.id
        }
        return (true, nil)
    }

    /// Outcome of accepting a share invite.
    public struct ShareLinkJoinResult {
        /// Local chat tab id the shared session landed in. Match against
        /// `ChatSession.id` / `.sourceChatId` to open it.
        public let tabId: String?
        public let label: String?
        public let error: String?
        public var ok: Bool { tabId != nil }
    }

    /// Accept a share invite: join the room, create the local tab + pairing,
    /// and subscribe for history. Returns the tab it landed in so the caller
    /// can open it — a fire-and-forget hash change looked identical whether
    /// the join worked or not.
    public func joinShareLink(token: String) async -> ShareLinkJoinResult {
        let reply = await callPage("__ripulJoinShareLink", [token], .ifMissing("{ ok: false, error: 'App is still starting up' }"))
        if let reason = reply.failure() { return ShareLinkJoinResult(tabId: nil, label: nil, error: reason) }
        guard let dict = reply.dictionary else {
            return ShareLinkJoinResult(tabId: nil, label: nil, error: "No response from the web app")
        }
        if dict["ok"] as? Bool == true, let tabId = dict["tabId"] as? String {
            // Pull the new tab into `sessions` now rather than waiting out
            // the 3s poll — the caller is about to look for it.
            await fetchSessions()
            return ShareLinkJoinResult(tabId: tabId, label: dict["label"] as? String, error: nil)
        }
        return ShareLinkJoinResult(
            tabId: nil, label: nil,
            error: dict["error"] as? String ?? "Failed to join session"
        )
    }

    /// Truncate a chat session, keeping only the most recent `keepCount` actions.
    /// Returns the number of actions removed, or -1 on failure.
    public func truncateSession(chatId: String, keepCount: Int) async -> (removed: Int, error: String?) {
        let reply = await callPage("__ripulTruncateSession", [chatId, keepCount])
        if let reason = reply.failure() { return (-1, reason) }
        guard reply.succeeded, let dict = reply.dictionary else {
            return (-1, reply.dictionary?["error"] as? String ?? "Unknown error")
        }
        return (dict["removed"] as? Int ?? 0, nil)
    }

    /// Force-restart the SessionChannel DO backing the given chat. Owner-only
    /// (server stamps authorId=ownerId for Clerk JWT requests). Used from the
    /// `/rr.` debug panel when a chat's DO is stuck on a pre-deploy code
    /// version — Cloudflare keeps existing DO instances on their old code
    /// until they evict on idle, and the reconnect loop keeps them alive.
    public func evictSessionChannel(chatId: String) async -> (success: Bool, error: String?) {
        let reply = await callPage("__ripulEvictSessionChannel", [chatId])
        if let reason = reply.failure() { return (false, reason) }
        guard reply.succeeded else { return (false, reply.dictionary?["error"] as? String ?? "Unknown error") }
        return (true, nil)
    }

    // MARK: - Starting a session on a Mac

    /// Race an async operation against a timeout. Safe on @MainActor (serial).
    private func withBridgeTimeout<T>(seconds: TimeInterval = 20, operation: @escaping @MainActor () async throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            var didResume = false
            Task { @MainActor in
                do {
                    let result = try await operation()
                    guard !didResume else { return }
                    didResume = true
                    continuation.resume(returning: result)
                } catch {
                    guard !didResume else { return }
                    didResume = true
                    continuation.resume(throwing: error)
                }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !didResume else { return }
                didResume = true
                continuation.resume(throwing: NSError(
                    domain: "AgentBridge", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Connection timed out after \(Int(seconds))s — the remote machine may be unresponsive. Try restarting the host."]
                ))
            }
        }
    }

    /// Make the creation reply navigable without rebuilding the entire session
    /// list. A push may have beaten the reply; preserve its richer row then.
    private func publishCreatedSession(_ session: ChatSession) {
        if !sessions.contains(where: { $0.id == session.id }) {
            sessions.insert(session, at: 0)
        }
        activeSessionId = session.id
        pendingActiveSourceChatId = session.sourceChatId
        refreshActiveAgentFlags()
        logSessionStartMarker("ios.creation_navigation_ready", chatId: session.sourceChatId)
        Task { [weak self] in
            // Match post-focus refresh: avoid republishing the list mid-slide.
            try? await Task.sleep(nanoseconds: 800_000_000)
            await self?.fetchSessions()
        }
    }

    /// Connect to a remote machine: creates a new chat tab and pairs it.
    /// Returns the tab ID on success, or nil on failure.
    public func connectToMachine(machineId: String) async -> (tabId: String?, error: String?) {
        guard let webView else {
            return (nil, "webView is nil")
        }
        do {
            let result = try await withBridgeTimeout { [webView] in
                try await webView.callAsyncJavaScript(
                    """
                    if (!window.__ripulConnectToMachine) return {success:false, error:'not ready'};
                    var r = await window.__ripulConnectToMachine(machineId);
                    return JSON.parse(JSON.stringify(r));
                    """,
                    arguments: ["machineId": machineId],
                    contentWorld: .page
                )
            }
            guard let dict = result as? [String: Any] else {
                let classified = await classifyJsCallFailure("empty/unbridgeable result", callable: "__ripulConnectToMachine")
                return (nil, classified)
            }
            if let success = dict["success"] as? Bool, success {
                let tabId = dict["tabId"] as? String
                let machineName = dict["machineName"] as? String ?? machineId
                NSLog("[AgentBridge] connectToMachine: paired to %@, tab %@", machineName, tabId ?? "?")
                // Tapping a machine to start a session on it is a CLI choice
                // just as much as picking a harness explicitly — it is in fact
                // the most common way to make one. nil providerKey records
                // "whatever this machine defaults to", which is exactly what
                // the user asked for and exactly what resuming will re-run.
                rememberCliSession(providerKey: nil, modelId: nil, machineId: machineId)
                guard let session = ChatSession.creationSeed(from: dict) else {
                    return (nil, "Creation reply is missing the new session identity.")
                }
                publishCreatedSession(session)
                return (tabId, nil)
            } else {
                var error = dict["error"] as? String ?? "Unknown error"
                if let code = dict["errorCode"] as? String { error = "\(code): \(error)" }
                NSLog("[AgentBridge] connectToMachine failed: %@", error)
                handleConsoleLog("ERROR: [CONN_DIAG] connectToMachine(\(machineId)) failed: \(error)")
                if let diag = await fetchWebDiagnostics() {
                    handleConsoleLog("WARN: [CONN_DIAG] diagnostics: \(diag)")
                }
                return (nil, error)
            }
        } catch {
            NSLog("[AgentBridge] connectToMachine error: %@", error.localizedDescription)
            let classified = await classifyJsCallFailure(error.localizedDescription, callable: "__ripulConnectToMachine")
            return (nil, classified)
        }
    }

    /// Connect to a remote machine in Claude Code mode: creates a session,
    /// sets the model to claude-cli, and enables raw mode in one step.
    /// Connect to a remote machine in CLI provider mode: creates a session,
    /// sets the model to the provider's default, and enables raw mode.
    /// providerKey is e.g. "claude-cli", "codex-cli", "antigravity-cli".
    /// - Parameter modelId: Catalog model to pin the new chat to (e.g.
    ///   "claude-cli-raw-opus"). This is what makes a quick-start shortcut mean
    ///   a MODEL rather than a harness. Pass nil for "a session on this
    ///   harness" and the provider's declared default is used.
    public func connectToMachineWithProvider(machineId: String, providerKey: String, modelId: String? = nil, workingDirectory: String? = nil) async -> (tabId: String?, error: String?) {
        logSessionStartMarker("ios.connect_with_provider_enter", extra: "machineId=\(machineId) provider=\(providerKey) model=\(modelId ?? "default")")
        guard let webView else {
            return (nil, "webView is nil")
        }
        do {
            logSessionStartMarker("ios.connect_with_provider_js_start")
            let result = try await withBridgeTimeout { [webView] in
                try await webView.callAsyncJavaScript(
                    """
                    if (!window.__ripulConnectToMachineWithProvider) return {success:false, error:'not ready'};
                    var r = await window.__ripulConnectToMachineWithProvider(machineId, providerKey, modelId || undefined, workingDirectory || undefined);
                    return JSON.parse(JSON.stringify(r));
                    """,
                    // A nil argument bridges as NSNull, not `undefined` — hence
                    // the `|| undefined` above.
                    arguments: ["machineId": machineId, "providerKey": providerKey, "modelId": modelId.map { $0 as Any } ?? NSNull(), "workingDirectory": workingDirectory.map { $0 as Any } ?? NSNull()],
                    contentWorld: .page
                )
            }
            logSessionStartMarker("ios.connect_with_provider_js_end")
            guard let dict = result as? [String: Any] else {
                let classified = await classifyJsCallFailure("empty/unbridgeable result", callable: "__ripulConnectToMachineWithProvider")
                return (nil, classified)
            }
            if let success = dict["success"] as? Bool, success {
                let tabId = dict["tabId"] as? String
                NSLog("[AgentBridge] connectToMachineWithProvider(%@): tab %@", providerKey, tabId ?? "?")
                // Mirror what the web actually stamped. This used to hardcode
                // "\(providerKey)-raw-default", which for claude-cli is not the
                // real default (claude-cli-raw-sonnet) — so the native model
                // label disagreed with the chat's own override.
                self.selectedModelId = modelId ?? ProviderConstants.defaultModelId(for: providerKey)
                // Starting a CLI session IS the user expressing a preference —
                // and this is the only place all three facts it takes to start
                // another one (harness, model, machine) are known together.
                rememberCliSession(providerKey: providerKey, modelId: modelId, machineId: machineId)
                // Only the explicit-harness path marks raw-mode — the plain
                // machine connect never did, and matching it exactly is the
                // point of reproducing the act rather than normalising it.
                if let tabId { persistCliSessionMetadata(tabId: tabId, providerKey: providerKey) }
                guard let session = ChatSession.creationSeed(
                    from: dict, providerKey: providerKey,
                    modelId: modelId ?? ProviderConstants.defaultModelId(for: providerKey)
                ) else {
                    return (nil, "Creation reply is missing the new session identity.")
                }
                publishCreatedSession(session)
                return (tabId, nil)
            } else {
                var error = dict["error"] as? String ?? "Unknown error"
                if let code = dict["errorCode"] as? String { error = "\(code): \(error)" }
                handleConsoleLog("ERROR: [CONN_DIAG] connectToMachineWithProvider(\(providerKey)) failed: \(error)")
                if let diag = await fetchWebDiagnostics() {
                    handleConsoleLog("WARN: [CONN_DIAG] diagnostics: \(diag)")
                }
                return (nil, error)
            }
        } catch {
            NSLog("[AgentBridge] connectToMachineWithProvider(%@) error: %@", providerKey, error.localizedDescription)
            let classified = await classifyJsCallFailure(error.localizedDescription, callable: "__ripulConnectToMachineWithProvider")
            return (nil, classified)
        }
    }

    // MARK: - Session tags

    /// Bulk-fetch the user's session tags as `{ sessionId: [tags] }`.
    /// One authed request via the web app's metadata service — used to decorate
    /// the native session list with lozenges. Returns empty on any failure.
    public func getSessionTags() async -> [String: [String]] {
        let reply = await callPage("__ripulGetSessionTags", [], .ifMissing("{}"))
        guard let dict = reply.dictionary else { return [:] }
        var out: [String: [String]] = [:]
        for (key, value) in dict {
            if let arr = value as? [String] {
                out[key] = arr
            } else if let arr = value as? [Any] {
                out[key] = arr.compactMap { $0 as? String }
            }
        }
        return out
    }

    /// Every id a group chat (one with another person in it) may be listed
    /// under — drives the session list's Group Chats filter. Nil when the web
    /// app couldn't read the roster, so the caller keeps its last answer.
    public func getGroupChatIds() async -> Set<String>? {
        let reply = await callPage("__ripulGetGroupChatIds", [], .ifMissing("null"))
        guard let ids = reply.value as? [Any] else { return nil }
        return Set(ids.compactMap { $0 as? String })
    }

    /// Replace the tag set for a session (keyed by its metadata id / sourceChatId).
    /// Returns true on success.
    @discardableResult
    public func setSessionTags(sessionId: String, tags: [String]) async -> Bool {
        await callPage("__ripulSetSessionTags", [sessionId, tags], .ifMissing("{ok:false}")).dictionary?["ok"] as? Bool ?? false
    }

    // MARK: - Deleting, opening, creating and renaming sessions

    /// Delete a session: stops thread, clears chat actions, deletes local thread
    /// data, and closes the tab. By default also archives the CLI session JSONL
    /// on the remote host, which hides it from the underlying CLI (Claude Code,
    /// Codex). Pass `keepRemote: true` to skip the remote archive so the CLI
    /// still sees the session in its own list (e.g. for a "Remove from Ripul"
    /// action that only clears Ripul-side state).
    /// Returns (success, results, errors). Keep the native row on failure so a
    /// refused remote deletion cannot briefly disappear and then reappear.
    public func deleteSession(tabId: String, machineId: String?, remoteSessionId: String?, keepRemote: Bool = false) async -> (success: Bool, results: [String], errors: [String]) {
        let reply = await callPage("__ripulDeleteSession", [tabId, machineId, remoteSessionId, keepRemote],
                                   .ifMissing("{success:false, results:[], errors:['not ready']}"))
        if let reason = reply.failure() { return (false, [], [reason]) }
        guard let dict = reply.dictionary else { return (false, [], ["Unexpected result"]) }
        let success = dict["success"] as? Bool ?? false
        let results = dict["results"] as? [String] ?? []
        let errors = dict["errors"] as? [String] ?? []
        NSLog("[AgentBridge] deleteSession: success=%@ results=%@ errors=%@",
              success ? "true" : "false", results.joined(separator: ", "), errors.joined(separator: ", "))

        guard success else { return (false, results, errors) }

        // Remove from local state and persist so the zombie can't return from cache
        let deleted = sessions.first(where: { $0.id == tabId })
        if sessions.contains(where: { $0.id == tabId }) { sessions.removeAll { $0.id == tabId } }
        ChatSession.saveToCache(sessions)
        if let sourceChatId = deleted?.sourceChatId {
            sessionList.sessionPhases.removeValue(forKey: sourceChatId)
            sessionLifecycleSequences.removeValue(forKey: sourceChatId)
        }
        if activeSessionId == tabId {
            activeSessionId = sessions.first?.id
        }

        return (success, results, errors)
    }

    /// Clear the SDK's local session caches (session list, cached list on disk,
    /// per-session phases and lifecycle sequences) WITHOUT touching auth or
    /// settings. Pairs with the web-side `__ripulClearSessionData` callable —
    /// call both to give this device a provably-clean local slate; the web
    /// view's reload then repopulates everything fresh.
    public func clearLocalSessionState() {
        sessions.removeAll()
        ChatSession.saveToCache(sessions)
        sessionList.sessionPhases.removeAll()
        sessionLifecycleSequences.removeAll()
        activeSessionId = nil
    }

    /// Repair the device's relay/connection state.
    ///
    /// First tries the web app's graceful reset (`__ripulRepairConnection`), which
    /// closes tabs, drops relay pairings/session-origin maps, clears persisted seq
    /// cursors and CLI bookkeeping, then reloads. If the JS context is dead, falls
    /// back to `purgeWebStateAndReload()` — a scorched-earth localStorage/IndexedDB
    /// purge that preserves cookies. Host settings and machine identity survive
    /// either path because they are mirrored natively (HostPreferences) and
    /// re-injected after the reload.
    public func repairConnection() async -> (success: Bool, message: String) {
        guard let webView else {
            return (false, "webView is nil")
        }

        // User manually intervened — cancel any automatic heal retries and reset
        // the ladder so the fresh boot starts cheap.
        deferredHealTask?.cancel()
        deferredHealTask = nil
        healVerifyTask?.cancel()
        healVerifyTask = nil
        healLadder.reset()

        // Attempt 1: graceful web-side reset.
        do {
            let result = try await webView.callAsyncJavaScript(
                """
                if (!window.__ripulRepairConnection) return {success:false, error:'not ready'};
                return await window.__ripulRepairConnection();
                """,
                arguments: [:],
                contentWorld: .page
            )
            if let dict = result as? [String: Any],
               let success = dict["success"] as? Bool,
               success {
                clearLocalSessionState()
                return (true, "Connection reset requested. The web view is reloading.")
            }
            let error = (result as? [String: Any])?["error"] as? String ?? "graceful reset declined"
            handleConsoleLog("WARN: [REPAIR_CONN] graceful reset failed: \(error); escalating to purge")
        } catch {
            let classified = await classifyJsCallFailure(error.localizedDescription, callable: "__ripulRepairConnection")
            handleConsoleLog("WARN: [REPAIR_CONN] graceful reset threw: \(classified); escalating to purge")
        }

        // Attempt 2: native fallback — purge web state (cookies preserved) and reload.
        purgeWebStateAndReload()
        clearLocalSessionState()
        return (true, "Connection reset with fallback purge. The web view is reloading.")
    }

    /// Open/reconnect to an existing session on a remote machine.
    /// Returns the local tab ID and provider metadata on success, or nil + error on failure.
    public func openRemoteSession(machineId: String, sessionId: String, displayName: String? = nil, forceReimport: Bool = false, focus: Bool = true) async -> (tabId: String?, provider: String?, providerLabel: String?, error: String?) {
        guard let webView else {
            return (nil, nil, nil, "webView is nil")
        }
        do {
            // Every name the script uses has to be bound, a missing display
            // name included: an unbound one is a ReferenceError, not `undefined`.
            let args: [String: Any] = [
                "machineId": machineId, "sessionId": sessionId, "forceReimport": forceReimport, "focus": focus,
                "displayName": displayName.map { $0 as Any } ?? NSNull(),
            ]
            let result = try await webView.callAsyncJavaScript(
                """
                if (!window.__ripulOpenRemoteSession) return {success:false, error:'not ready'};
                var opts = {forceReimport: forceReimport, focus: focus};
                var r = await window.__ripulOpenRemoteSession(machineId, sessionId, displayName ?? undefined, opts);
                return JSON.parse(JSON.stringify(r));
                """,
                arguments: args,
                contentWorld: .page
            )
            guard let dict = result as? [String: Any] else {
                let classified = await classifyJsCallFailure("empty/unbridgeable result", callable: "__ripulOpenRemoteSession")
                return (nil, nil, nil, classified)
            }
            if let success = dict["success"] as? Bool, success {
                let tabId = dict["tabId"] as? String
                let provider = dict["provider"] as? String
                let providerLabel = dict["providerLabel"] as? String
                NSLog("[AgentBridge] openRemoteSession: opened %@ on %@, tab %@, provider %@", sessionId, machineId, tabId ?? "?", provider ?? "none")
                // Do NOT block the return on a full session-list rebuild.
                // fetchSessions() runs __ripulGetSessions — a 118-row unified-list
                // rebuild that was measured at ~20s on a WARM re-entry while the web
                // view was busy, and it ran on every open before the caller could
                // navigate. The tab is already open by this point, so refresh the
                // native list in the BACKGROUND and return immediately. Callers that
                // need the new tab in `sessions` right away (a fresh open, where the
                // tab was just created) re-fetch on a lookup miss; warm re-entries
                // already have the tab and skip the fetch entirely — which is what
                // makes re-entry instant instead of 20s.
                Task { [weak self] in await self?.fetchSessions() }
                return (tabId, provider, providerLabel, nil)
            } else {
                // Prefix the web app's stable errorCode so ConnectionDiagnosis can
                // classify without string-sniffing the human message.
                var error = dict["error"] as? String ?? "Unknown error"
                if let code = dict["errorCode"] as? String { error = "\(code): \(error)" }
                NSLog("[AgentBridge] openRemoteSession failed: %@", error)
                handleConsoleLog("ERROR: [CONN_DIAG] openRemoteSession(\(sessionId)) failed: \(error)")
                // A failed host/bridge may also stall diagnostics. Return the
                // known failure immediately so the native list can show it.
                Task { [weak self] in
                    if let diag = await self?.fetchWebDiagnostics() {
                        self?.handleConsoleLog("WARN: [CONN_DIAG] diagnostics: \(diag)")
                    }
                }
                return (nil, nil, nil, error)
            }
        } catch {
            NSLog("[AgentBridge] openRemoteSession error: %@", error.localizedDescription)
            let classified = await classifyJsCallFailure(error.localizedDescription, callable: "__ripulOpenRemoteSession")
            return (nil, nil, nil, classified)
        }
    }

    /// Create a new chat tab via direct JS call.
    /// Create a new chat. `modelOverride` pins the new chat to a catalog model
    /// at birth — a non-CLI id (e.g. "backend-claude-fable-5") creates a
    /// regular web chat that runs through the LLM proxy instead of a CLI
    /// session.
    public func createNewChat(modelOverride: String? = nil, machineId: String? = nil, workingDirectory: String? = nil) async -> String? {
        logSessionStartMarker("ios.bridge_createNewChat_enter", extra: "isConnected=\(isConnected)")
        guard let webView else {
            NSLog("[AgentBridge] createNewChat: webView is nil")
            logSessionStartMarker("ios.bridge_createNewChat_no_webview")
            return nil
        }

        // No explicit choice (Siri, the "+" button, ripul://new-session) →
        // continue whatever the user was last working in. If that was a CLI
        // session, this returns a real CLI session rather than an API chat;
        // if the machine is unreachable it returns nil and we fall through to
        // the API path below, which is what "no model specified" meant before.
        if modelOverride == nil, machineId == nil, let cliTabId = await resumeStickyCliSession() {
            return cliTabId
        }
        let effectiveModel = modelOverride ?? stickyApiModelForNewChat()
        if modelOverride == nil, let effectiveModel {
            handleConsoleLog("LOG: [MODELSW] native.createNewChat sticky-default id=\(effectiveModel)")
        }

        do {
            logSessionStartMarker("ios.bridge_js_call_start")
            let modelArgument: Any = effectiveModel ?? NSNull()
            let result = try await webView.callAsyncJavaScript(
                """
                if (!window.__ripulCreateChat) return {success:false, error:'not ready'};
                return await window.__ripulCreateChat(workingDirectory, { modelOverride: modelOverride || undefined, machineId: machineId || undefined });
                """,
                arguments: ["modelOverride": modelArgument, "machineId": machineId.map { $0 as Any } ?? NSNull(), "workingDirectory": workingDirectory.map { $0 as Any } ?? NSNull()],
                contentWorld: .page
            )

            guard let dict = result as? [String: Any],
                  let success = dict["success"] as? Bool, success,
                  let chatId = dict["chatId"] as? String else {
                NSLog("[AgentBridge] createNewChat: unexpected result: %@",
                      String(describing: result))
                logSessionStartMarker("ios.bridge_js_call_end", extra: "result=unexpected")
                return nil
            }
            NSLog("[AgentBridge] createNewChat: created %@", chatId)
            // Creating a session FROM a picker is a deliberate choice too, so
            // the next plain new session continues in it. Only on success —
            // a model that failed to start is not a preference.
            if let modelOverride { rememberModelPick(modelOverride) }
            // A brand-new chat has no agent turn — point the button projection
            // at it immediately (the sessions push that makes it resolvable in
            // `sessions` lags this call by hundreds of ms).
            pendingActiveSourceChatId = chatId
            refreshActiveAgentFlags()
            logSessionStartMarker("ios.bridge_js_call_end", chatId: chatId)
            return chatId
        } catch {
            NSLog("[AgentBridge] createNewChat error: %@", error.localizedDescription)
            logSessionStartMarker("ios.bridge_js_call_error", extra: "err=\(error.localizedDescription)")
            return nil
        }
    }

    /// Rename a chat session. Updates both web storage and local state.
    /// Rename a session via a direct JS round-trip call.
    /// Updates local state only after the web app confirms persistence.
    public func renameSession(id: String, sourceChatId: String, displayName: String) {
        guard attachedWebView != nil else { return }
        // Optimistically update local state immediately for UI responsiveness
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index].displayName = displayName
        }
        Task { @MainActor in
            let reply = await callPage("__ripulRenameSession", [sourceChatId, displayName, id],
                                       .orElse("{ success: false }"), caller: "renameSession")
            guard reply.error == nil else { return }
            guard reply.succeeded, let confirmedName = reply.dictionary?["displayName"] as? String else {
                NSLog("[AgentBridge] renameSession: web did not confirm, result: %@", String(describing: reply.value))
                return
            }
            // Web mints the rename-event stamp; carry it into the JSONL
            // write so the CLI server's stale-stamp guard sees the true
            // event time.
            let confirmedRenamedAt = (reply.dictionary?["renamedAt"] as? NSNumber)?.doubleValue
            if let index = sessions.firstIndex(where: { $0.id == id }) {
                // One write, and none when the optimistic rename already
                // matches: each element write publishes the whole array.
                var confirmed = sessions[index]
                confirmed.displayName = confirmedName
                confirmed.displayNameRenamedAt = confirmedRenamedAt ?? confirmed.displayNameRenamedAt
                if confirmed != sessions[index] { sessions[index] = confirmed }
            }
            NSLog("[AgentBridge] renameSession confirmed: %@", confirmedName)
            // Propagate to CLI session file if this is a CLI-provider session
            if let session = self.sessions.first(where: { $0.id == id }),
               session.provider == "claude-cli" {
                self.onCliSessionRenamed?(sourceChatId, confirmedName, confirmedRenamedAt)
            }
        }
    }

    // MARK: - Send messages to web app

    public func setTheme(_ theme: AgentTheme) {
        let requestId = UUID().uuidString
        send([
            "type": "\(messagePrefix)theme:set",
            "version": protocolVersion,
            "timestamp": currentTimestamp(),
            "requestId": requestId,
            "theme": theme.rawValue,
        ])
    }

    // MARK: - Private helpers

    /// Every tool this channel could conceivably name, ungated and regardless
    /// of exposure. The ONLY legitimate readers are `exposedTools`/`allTools`
    /// (which apply exposure + the audience gate) and the invoke-path
    /// diagnostic that distinguishes "gated / not exposed" from "no such
    /// tool". Adding a third tool source means changing this one property, so
    /// the gate can never be left behind.
    private var unfilteredTools: [NativeTool] {
        builtInTools + registry.allEntries.map(\.tool)
    }

    /// The channel's projection of the registry: channel-bound tools plus the
    /// entries of every exposed audience, in registration order.
    private var exposedTools: [NativeTool] {
        builtInTools + registry.allEntries
            .filter { exposedAudiences.contains($0.audience) }
            .map(\.tool)
    }

    /// The single source both discovery (`toolDefinitions`) and invocation
    /// (`tool(named:)`) read from — which is what makes the audience gate
    /// below a genuine choke point rather than something each caller has to
    /// remember to apply. Exposure (the registry projection above) narrows by
    /// audience tag; the phase-0 marker gate then re-asserts that an
    /// `.endUser` channel never sees or can invoke a `RipulDeveloperOnlyTool`,
    /// no matter what a registration call or a future exposure tweak did.
    private var allTools: [NativeTool] {
        guard audience == .endUser else { return exposedTools }
        return exposedTools.filter { !($0 is RipulDeveloperOnlyTool) }
    }

    private var toolDefinitions: [[String: Any]] {
        allTools.map { $0.definition }
    }

    private func tool(named name: String) -> NativeTool? {
        allTools.first { $0.name == name }
    }

    // MARK: - Private handlers

    private func handleHandshake(_ message: [String: Any]) {
        NSLog("[AgentBridge] → Sending handshake:ack")
        var caps: [String: Any] = [
            "mcp": true,
            "dom": false,
            "storage": false,
            "llm": llmProvider != nil,
            "searchClick": searchClickDelegate != nil,
        ]
        for cap in capabilityRouter.availableCapabilities { caps[cap] = true }
        for (k, v) in extraCapabilities { caps[k] = v }

        send([
            "type": "\(messagePrefix)handshake:ack",
            "version": protocolVersion,
            "timestamp": currentTimestamp(),
            "capabilities": caps,
            "hostOrigin": "ripul-native://app",
        ])
        setIfChanged(\.isConnected, true)
        logSessionStartMarker("ios.bridge_connected")
        recordStartupProgress()
        setIfChanged(\.loadError, nil)
        setIfChanged(\.loadErrorDetails, nil)
        jsErrorMessages = []
        jsErrorDebounce?.cancel()
        // Re-push measured chat input height now that the web app is ready
        resendInputHeight()

        if !allTools.isEmpty {
            let defs = toolDefinitions
            NSLog("[AgentBridge] → Broadcasting mcp:tools (%d tools)", defs.count)
            send([
                "type": "\(messagePrefix)mcp:tools",
                "version": protocolVersion,
                "timestamp": currentTimestamp(),
                "tools": defs,
            ])
        }

        // Auto-request sessions for native UI
        requestSessions()

        // A handshake means a FRESH web page (first load, reload, or a heal
        // reload after a crash). Its lifecycle store restarts at sequence 0, so
        // sequences recorded against the previous page are meaningless — keeping
        // them makes the ordering gate in applySessionPhase drop every snapshot
        // the new page sends, freezing the pause button on pre-reload state.
        // Phases are deliberately kept so the UI doesn't blank while resyncing.
        sessionLifecycleSequences.removeAll()

        // Sync agent button state then start accepting agent:status pushes.
        // The delay allows the web app to finish initializing before we query.
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5s
            await syncAgentStatus()
            initialStatusSyncComplete = true
        }

        // Post-crash auto-probe: runs after the bridge reconnects following a process termination
        if pendingPostCrashProbe {
            pendingPostCrashProbe = false
            Task {
                // Wait for the web app to settle after reload
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3s
                await probeWebViewHealth(trigger: "post-crash")
            }
        }
    }

    private func handleHostInfo(_ message: [String: Any]) {
        let requestId = message["requestId"] as? String ?? UUID().uuidString
        NSLog("[AgentBridge] → Sending host:info:response")
        send([
            "type": "\(messagePrefix)host:info:response",
            "version": protocolVersion,
            "timestamp": currentTimestamp(),
            "requestId": requestId,
            "url": "ripul-native://app",
            "title": "Ripul Native App (iOS)",
            "origin": "ripul-native://app",
        ])
    }

    private func handleMCPDiscover(_ message: [String: Any]) {
        let requestId = message["requestId"] as? String ?? UUID().uuidString
        let defs = toolDefinitions
        send([
            "type": "\(messagePrefix)mcp:tools",
            "version": protocolVersion,
            "timestamp": currentTimestamp(),
            "requestId": requestId,
            "tools": defs,
        ])
    }

    private func handleMCPInvoke(_ message: [String: Any]) {
        let requestId = message["requestId"] as? String ?? UUID().uuidString
        let toolName = message["toolName"] as? String ?? ""
        let args = message["args"] as? [String: Any] ?? [:]

        if let argsData = try? JSONSerialization.data(withJSONObject: args, options: .fragmentsAllowed),
           let argsJSON = String(data: argsData, encoding: .utf8) {
            NSLog("[AgentBridge] → Invoking tool: %@ args: %@", toolName, argsJSON)
        } else {
            NSLog("[AgentBridge] → Invoking tool: %@ with requestId: %@", toolName, requestId)
        }

        guard let tool = tool(named: toolName) else {
            // Distinguish "gated / not exposed" from "genuinely doesn't exist"
            // in the native log only — the wire error stays a generic "not
            // found" so an .endUser channel never hints that a developer-only
            // tool exists.
            if audience == .endUser, unfilteredTools.contains(where: { $0.name == toolName && $0 is RipulDeveloperOnlyTool }) {
                NSLog("[RIPUL_GATE] Refused invoke of developer-only tool on .endUser channel: %@", toolName)
            } else if unfilteredTools.contains(where: { $0.name == toolName }) {
                NSLog("[AgentBridge] Tool registered under an audience this channel does not expose: %@", toolName)
            } else {
                NSLog("[AgentBridge] Tool not found: %@", toolName)
            }
            send([
                "type": "\(messagePrefix)mcp:error",
                "version": protocolVersion,
                "timestamp": currentTimestamp(),
                "requestId": requestId,
                "error": "Tool not found: \(toolName)",
            ])
            return
        }

        // Attribution for cross-audience borrowing (phase 2): the CHANNEL
        // stamps the invocation — tools stay principal-free. An absorbed call
        // is one whose registry audience is `.endUser` on a `.developer`
        // channel (channel-bound tools have no registry entry, so they never
        // read as absorbed).
        let absorbed = audience == .developer && registry.audience(ofToolNamed: toolName) == RipulToolAudience.endUser
        if absorbed {
            NSLog("[RIPUL_ABSORB] tool=%@ channel=developer", toolName)
        }

        Task { @MainActor in
            do {
                let result = try await tool.execute(args: args)
                NSLog("[AgentBridge] Tool %@ succeeded", toolName)

                // Validate that the result is JSON-serializable before sending.
                // If the tool returns a dict with non-JSON types (Date, Decimal, etc.)
                // JSONSerialization will fail silently in send(), losing the result.
                let safeResult: Any
                if let dict = result as? [String: Any],
                   !JSONSerialization.isValidJSONObject(["test": dict]) {
                    NSLog("[AgentBridge] Tool %@ result is not JSON-serializable, converting to description", toolName)
                    safeResult = ["_raw": String(describing: dict)]
                } else {
                    safeResult = result
                }

                var envelope: [String: Any] = [
                    "type": "\(messagePrefix)mcp:result",
                    "version": protocolVersion,
                    "timestamp": self.currentTimestamp(),
                    "requestId": requestId,
                    "result": safeResult,
                ]
                // Additive field: the web/chat side badges the call ("ran as
                // developer, borrowed from End-user tools"); unknown fields
                // are ignored elsewhere.
                if absorbed { envelope["absorbed"] = true }
                self.send(envelope)
            } catch {
                NSLog("[AgentBridge] Tool %@ failed: %@", toolName, error.localizedDescription)
                self.send([
                    "type": "\(messagePrefix)mcp:error",
                    "version": protocolVersion,
                    "timestamp": self.currentTimestamp(),
                    "requestId": requestId,
                    "error": error.localizedDescription,
                ])
            }
        }
    }

    private func handleLLMGenerate(_ message: [String: Any]) {
        let requestId = message["requestId"] as? String ?? UUID().uuidString
        let threadId = message["threadId"] as? String ?? ""
        let systemPrompt = message["systemPrompt"] as? String ?? ""
        let timeline = message["timeline"] as? [[String: Any]] ?? []
        let tools = message["tools"] as? [[String: Any]] ?? []

        NSLog("[AgentBridge] LLM generate request — thread: %@, messages: %d, tools: %d",
              threadId, timeline.count, tools.count)

        guard let llmProvider else {
            NSLog("[AgentBridge] No LLM provider configured")
            send([
                "type": "\(messagePrefix)llm:generate:error",
                "version": protocolVersion,
                "timestamp": currentTimestamp(),
                "requestId": requestId,
                "error": "No LLM provider configured on native side",
                "code": "model_unavailable",
            ])
            return
        }

        Task { @MainActor in
            do {
                let result = try await llmProvider.generate(
                    threadId: threadId,
                    systemPrompt: systemPrompt,
                    timeline: timeline,
                    tools: tools
                )
                NSLog("[AgentBridge] LLM generated tool call: %@", result.toolName)
                self.send([
                    "type": "\(messagePrefix)llm:generate:response",
                    "version": protocolVersion,
                    "timestamp": self.currentTimestamp(),
                    "requestId": requestId,
                    "toolName": result.toolName,
                    "toolArgs": result.toolArgs,
                    "inputTokens": result.inputTokens,
                    "outputTokens": result.outputTokens,
                ])
            } catch {
                NSLog("[AgentBridge] LLM generate failed: %@", error.localizedDescription)
                self.send([
                    "type": "\(messagePrefix)llm:generate:error",
                    "version": protocolVersion,
                    "timestamp": self.currentTimestamp(),
                    "requestId": requestId,
                    "error": error.localizedDescription,
                    "code": "unknown",
                ])
            }
        }
    }

    private func handleSearchClick(_ message: [String: Any]) {
        let requestId = message["requestId"] as? String ?? UUID().uuidString
        let resultType = message["resultType"] as? String ?? "unknown"
        let resultId = message["resultId"] as? String
        let title = message["title"] as? String
        let url = message["url"] as? String
        let metadata = message["metadata"] as? [String: Any] ?? [:]

        NSLog("[AgentBridge] Search click — type: %@, id: %@, title: %@",
              resultType, resultId ?? "nil", title ?? "nil")

        let context = SearchClickContext(
            resultType: resultType,
            resultId: resultId,
            title: title,
            url: url,
            metadata: metadata
        )

        let handled = searchClickDelegate?.agentBridge(self, didClickSearchResult: context) ?? false

        send([
            "type": "\(messagePrefix)search:click:ack",
            "version": protocolVersion,
            "timestamp": currentTimestamp(),
            "requestId": requestId,
            "handled": handled,
        ])
    }

    private func handleScrollState(_ message: [String: Any]) {
        let show = message["showButton"] as? Bool ?? false
        if scrollButton.show != show {
            scrollButton.show = show
        }
        let count = message["unreadCount"] as? Int ?? 0
        if scrollButton.unreadCount != count {
            scrollButton.unreadCount = count
        }
    }

    /// Native chat scroller pipe.
    ///
    /// The web app forwards raw chat actions from `ChatActionsManager` over the
    /// bridge so the chat renders natively while the WKWebView stays a comms
    /// conduit. Routes into `nativeChat` (the scroller store) and logs a one-line
    /// trace so the pipe stays observable (ordering, ids, streaming).
    /// Enable from the web side via `window.__ripulSetNativeChatForwarding(true)`.
    private func handleNativeChatMessage(_ message: [String: Any]) {
        let kind = message["kind"] as? String ?? "?"
        if kind == "backfill", let messages = message["messages"] as? [[String: Any]] {
            nativeChat.applyBackfill(messages)
            return
        }
        if kind == "reset" {
            nativeChat.clear()
            handleConsoleLog("LOG: [NativeChat] reset (backfill starting)")
            return
        }
        guard let msg = message["message"] as? [String: Any] else {
            handleConsoleLog("LOG: [NativeChat] \(kind) — malformed (no message payload)")
            return
        }
        let messageId = msg["messageId"] as? String ?? "?"
        if kind == "update" {
            nativeChat.applyUpdate(msg)
            let thinking = msg["thinking"] as? [String: Any]
            let streaming = (thinking?["isStreaming"] as? Bool).map { String($0) } ?? "-"
            let len = (thinking?["content"] as? String)?.count ?? 0
            handleConsoleLog("LOG: [NativeChat] update id=\(messageId.suffix(6)) thinkingLen=\(len) streaming=\(streaming)")
        } else {
            nativeChat.applyAdd(msg)
            let role = msg["role"] as? String ?? "?"
            let method = msg["method"] as? String ?? "?"
            let content = msg["content"] as? String ?? ""
            let preview = content.count > 60 ? String(content.prefix(60)) + "…" : content
            handleConsoleLog("LOG: [NativeChat] add id=\(messageId.suffix(6)) role=\(role) method=\(method) count=\(nativeChat.messages.count) content=\"\(preview)\"")
        }
    }

    private func handleMastheadConfig(_ message: [String: Any]) {
        let text = message["text"] as? String
        let imageUrl = message["imageUrl"] as? String

        guard text != nil || imageUrl != nil else {
            setIfChanged(\.mastheadConfig, nil)
            updateNativeHeaderHeight()
            return
        }

        NSLog("[AgentBridge] Masthead config — text: %@, imageUrl: %@, imageWidth: %@",
              text ?? "(nil)", imageUrl ?? "(nil)", message["imageWidth"] as? String ?? "(nil)")

        // Re-sent on every chat activation; usually identical.
        setIfChanged(\.mastheadConfig, MastheadConfig(
            text: text,
            imageUrl: imageUrl,
            backgroundColor: message["backgroundColor"] as? String,
            textColor: message["textColor"] as? String,
            height: (message["height"] as? NSNumber).map { CGFloat($0.doubleValue) },
            imageWidth: message["imageWidth"] as? String,
            fontSize: (message["fontSize"] as? NSNumber).map { CGFloat($0.doubleValue) },
            topOffset: (message["topOffset"] as? NSNumber).map { CGFloat($0.doubleValue) },
            glassStyle: message["glassStyle"] as? String
        ))
        updateNativeHeaderHeight()
    }

    /// Adopt the resolved voice settings from the web app's site key profile.
    /// The SDK runs its own TTS/STT, so without this the web read-aloud would
    /// honour the site key and native voice mode would ignore it.
    private func handleVoiceConfig(_ message: [String: Any]) {
        let profile = VoiceProfileConfig(
            profileId: message["profileId"] as? String,
            profileName: message["profileName"] as? String,
            ttsProviderId: message["ttsProviderId"] as? String,
            voiceId: message["voiceId"] as? String,
            ttsModelId: message["ttsModelId"] as? String,
            pace: (message["pace"] as? NSNumber)?.doubleValue,
            expressiveness: (message["expressiveness"] as? NSNumber)?.doubleValue,
            sttProviderId: message["sttProviderId"] as? String,
            language: message["language"] as? String,
            keyterms: message["keyterms"] as? [String] ?? [],
            voiceEnabled: message["voiceEnabled"] as? Bool ?? true,
            readAloudEnabled: message["readAloudEnabled"] as? Bool ?? true,
            voiceModeEnabled: message["voiceModeEnabled"] as? Bool ?? true,
            voiceModeStyle: message["voiceModeStyle"] as? String,
            autoSpeakReplies: message["autoSpeakReplies"] as? Bool ?? false,
            allowUserOverride: message["allowUserOverride"] as? Bool ?? true
        )
        guard profile != SpeechPreferences.activeProfile else { return }
        SpeechPreferences.activeProfile = profile
        voiceProfile = profile
        handleConsoleLog(
            "LOG: [Voice] profile=\(profile.profileName ?? profile.profileId ?? "(none)") "
            + "locked=\(!profile.allowUserOverride) voice=\(profile.voiceId ?? "auto") "
            + "lang=\(profile.language ?? "-")"
        )
    }

    /// The native bar's row moved (a pose change) — recompute the web
    /// clearance under it. No-op until the page has loaded once.
    public func refreshNativeHeaderHeight() {
        guard didFinishFirstNavigation else { return }
        updateNativeHeaderHeight()
    }

    /// Re-inject `--native-header-height` CSS variable to account for the masthead.
    private func updateNativeHeaderHeight() {
        guard let webView else { return }
        let mastheadExtra = mastheadConfig != nil ? Int(mastheadConfig?.height ?? 48) + 12 : 0
        let totalHeight: Int
        #if os(iOS)
        // The row the native bar occupies in the OWNING window — a corner
        // camera (iPhone Duo open) pulls it above the rectangular inset;
        // content below it still clears the camera's band.
        let clearance = webView.window.map { WindowTopChromeLayout.clearance(for: $0) }
            ?? WindowTopChromeClearance(top: 54, safeTop: 54)
        totalHeight = Int(clearance.contentClearance(below: 44)) + mastheadExtra
        #else
        totalHeight = 44 + mastheadExtra
        #endif
        let js = "document.documentElement.style.setProperty('--native-header-height', '\(totalHeight)px')"
        webView.evaluateJavaScript(js) { _, error in
            if let error {
                NSLog("[AgentBridge] Failed to update native header height: %@", error.localizedDescription)
            } else {
                NSLog("[AgentBridge] Updated --native-header-height: %dpx (masthead: %d)", totalHeight, mastheadExtra)
            }
        }
    }

    /// Tell the web view to scroll the active chat to the bottom.
    ///
    /// Calls the module-level `__ripulScrollToBottom` which finds the
    /// visible Virtuoso scroller via DOM query and emits an EventBus
    /// event so the active React component resets auto-scroll state.
    /// Start a machine's new-chat working-folder lookup ahead of the create —
    /// called when the New Chat sheet opens, so its relay round trips overlap
    /// the user choosing instead of following the tap. Fire-and-forget.
    public func prewarmNewChat(machineId: String) {
        webView?.callAsyncJavaScript(
            "return await window.__ripulPrewarmNewChat?.(machineId) ?? false;",
            arguments: ["machineId": machineId], in: nil, in: .page
        ) { _ in }
    }

    public func scrollToBottom() {
        NSLog("[AgentBridge] scrollToBottom -> JS bridge")
        evaluateVoidJavaScript("window.__ripulScrollToBottom?.()")
    }

    /// Navigate to the next or previous user message in the chat.
    /// - Parameter direction: `"up"` for previous, `"down"` for next.
    public func scrollToUserMessage(direction: String = "up") {
        NSLog("[AgentBridge] scrollToUserMessage(\(direction)) -> JS bridge")
        evaluateVoidJavaScript("window.__ripulScrollToUserMessage?.('\(direction)')")
    }

    /// Toggle the on-page element debugger HUD (`ElementDebuggerOverlay`).
    /// Called from the iPhone title-lozenge double-tap.
    public func toggleElementDebugger() {
        #if os(iOS)
        if RipulViewExplorer.isPresented { RipulViewExplorer.dismiss() }
        else { showInspector() }
        #else
        evaluateVoidJavaScript("window.__ripulToggleElementDebugger?.()")
        #endif
    }

    public func showInspector() {
        #if os(iOS)
        RipulViewExplorer.present(in: webView?.window ?? RipulChrome.appWindow(), bridge: self)
        #else
        evaluateVoidJavaScript("window.__ripulUpdateUserSettings?.({ enableElementDebugger: true })")
        #endif
    }

    #if os(iOS)
    /// The composer's `@` → Element: pick one element in the View Explorer
    /// and bring it back to this chat's composer as a Selected element chip.
    /// Returns the element's name in the message ("Element A") for the text
    /// to use, or nil when the Explorer was closed without adding one.
    public func pickElementForChat() async -> String? {
        await withCheckedContinuation { continuation in
            RipulViewExplorer.pickElementForChat(bridge: self, in: webView?.window ?? RipulChrome.appWindow(),
                                                 onFinish: { continuation.resume(returning: $0) })
        }
    }
    #endif

    /// Ask the web file viewer to close (triggered by the native back button).
    public func requestFileViewerClose() {
        NSLog("[AgentBridge] requestFileViewerClose")
        // Clear native state directly so the native file-viewer panel dismisses
        // immediately. The viewer is now a native StandaloneFileViewer panel (not the
        // in-chat web viewer), so we must not depend on a web round-trip to clear it.
        fileViewerExpanded = false
        fileViewerTitle = nil
        fileViewerFilePath = nil
        fileViewerLine = nil
        fileViewerChatId = nil
        // Also close the (web-only) in-chat viewer if one is showing; harmless on native.
        evaluateVoidJavaScript("window.__ripulCloseFileViewer?.()")
    }

    /// Ask the web artefact page to close (triggered by the native back button
    /// or the back swipe).
    ///
    /// Unlike the file viewer, this page lives in THIS web view, so the web side
    /// owns the dismissal and reports it back as `artefact:collapse`. Clear the
    /// title anyway, so the bar reverts even if the page has already gone (a
    /// chat switch, a reload) and cannot leave the chat wearing the wrong bar.
    public func requestArtefactPageClose() {
        NSLog("[AgentBridge] requestArtefactPageClose")
        artefactPageExpanded = false
        artefactPageTitle = nil
        evaluateVoidJavaScript("window.__ripulCloseArtefactPage?.()")
    }

    /// Zoom in the markdown file viewer.
    public func fileViewerZoomIn() {
        evaluateVoidJavaScript("window.__ripulFileViewerZoomIn?.()")
    }

    /// Zoom out the markdown file viewer.
    public func fileViewerZoomOut() {
        evaluateVoidJavaScript("window.__ripulFileViewerZoomOut?.()")
    }

    /// Reset the markdown file viewer zoom to default.
    public func fileViewerZoomReset() {
        evaluateVoidJavaScript("window.__ripulFileViewerZoomReset?.()")
    }

    /// Toggle between rendered and raw markdown in the file viewer.
    public func fileViewerToggleRaw() {
        evaluateVoidJavaScript("window.__ripulFileViewerToggleRaw?.()")
    }

    /// Toggle word wrap in the Monaco file viewer.
    public func fileViewerToggleWordWrap() {
        evaluateVoidJavaScript("window.__ripulFileViewerToggleWordWrap?.()")
    }

    /// Emit a TodoItemCreate event in the web app to open the "Add To Do" dialog.
    public func emitTodoItemCreate() {
        evaluateVoidJavaScript("window.__ripulCreateTodoItem?.()")
    }

    /// Fetch the signed-in user's todo items from the web app, along with the
    /// currently active chat id so the picker can group "this chat" on top.
    /// Errors are caught internally and surface as an empty result so the
    /// native picker can show "No items" rather than crash.
    public func listTodoItems() async -> RipulTodoItemsResult {
        let reply = await callPage("__ripulListTodoItems", [],
                                   .ifMissing("{ items: [], currentChatId: null, error: '__ripulListTodoItems not defined' }"))
        guard let dict = reply.dictionary else { return RipulTodoItemsResult(items: [], currentChatId: nil) }
        let currentChatId = dict["currentChatId"] as? String
        let rawItems = dict["items"] as? [[String: Any]] ?? []
        let items: [RipulTodoItem] = rawItems.compactMap { item in
            guard let id = item["id"] as? String,
                  let text = item["text"] as? String else { return nil }
            let chatId = item["chatId"] as? String
            let chatName = item["chatName"] as? String
            let completed = item["completed"] as? Bool ?? false
            return RipulTodoItem(
                id: id,
                chatId: chatId,
                chatName: chatName,
                text: text,
                completed: completed
            )
        }
        return RipulTodoItemsResult(items: items, currentChatId: currentChatId)
    }

    /// Open a file in the web file viewer (e.g. from native Saved Files sheet).
    public func openFavoriteFile(_ path: String) {
        if let data = try? JSONEncoder().encode(path),
           let jsonStr = String(data: data, encoding: .utf8) {
            evaluateVoidJavaScript("window.__ripulOpenFileViewer?.(\(jsonStr))")
        }
    }

    /// Result of creating a new chat with a prefilled prompt. Callers need both
    /// ids: `chatId` (the sourceChatId — what the composer's pending-prefill and
    /// eventBus key off) and `tabId` (the descriptor id — what setRawMode,
    /// setChatModel, and `ChatSession.id` all use). They are often the same but
    /// can diverge for remote-paired tabs. `machineId` is non-nil when the new
    /// chat inherited a remote-machine pairing from the previously active chat.
    public struct NewChatResult {
        public let chatId: String
        public let tabId: String
        public let machineId: String?
    }

    /// Create a new chat and prefill its composer with `prompt`. Does not
    /// auto-send — the user reviews/edits before submitting. Returns both ids
    /// on success, or nil on failure.
    public func startNewChatWithPrompt(_ prompt: String) async -> NewChatResult? {
        let reply = await callPage("__ripulStartNewChatWithPrompt", [prompt],
                                   .ifMissing("{ success: false, error: '__ripulStartNewChatWithPrompt not defined' }"),
                                   detachedIsFailure: true)
        guard let dict = reply.dictionary else { return nil }
        if let success = dict["success"] as? Bool, success,
           let chatId = dict["chatId"] as? String,
           let tabId = dict["tabId"] as? String {
            let machineId = dict["machineId"] as? String
            // Same new-chat handoff as createNewChat/startNewChat.
            pendingActiveSourceChatId = chatId
            refreshActiveAgentFlags()
            return NewChatResult(chatId: chatId, tabId: tabId, machineId: machineId)
        }
        if let err = dict["error"] as? String {
            NSLog("[AgentBridge] startNewChatWithPrompt: web error %@", err)
        }
        return nil
    }

    /// Log a message to this web view's JS console (visible via device_console_logs).
    /// For native-side diagnostics that need to be visible without Xcode.
    public func logToWebConsole(_ message: String) {
        guard let data = try? JSONEncoder().encode(message),
              let jsonStr = String(data: data, encoding: .utf8) else { return }
        evaluateJavaScript("console.log(\(jsonStr))")
    }

    private func handleSessionsListResponse(_ message: [String: Any]) {
        guard let sessionsArray = message["sessions"] as? [[String: Any]] else { return }
        let activeId = message["activeId"] as? String

        // Same decoder as the pull path — see `ChatSession.fromWire`.
        let parsed: [ChatSession] = sessionsArray.compactMap(ChatSession.fromWire)

        // Filter out ephemeral commit-viewer sessions (tracked explicitly
        // by CommitsScreen via ephemeralSessionIds, persisted to UserDefaults).
        let filtered = parsed.filter { !self.ephemeralSessionIds.contains($0.id) }

        // Only update sessions when we get data. Never clear a good cached
        // list with an empty response (timing race during web app init).
        if !filtered.isEmpty {
            // Detect CLI session renames before overwriting self.sessions.
            // Only fire for displayNames sourced from CLI history or explicit
            // user renames; "auto" values (descriptor in-memory or date
            // fallback) must NOT round-trip into the JSONL.
            if self.sessions != filtered {
                let oldByID = Dictionary(self.sessions.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
                let isInitialLoad = oldByID.isEmpty
                // SKIP_AUTO and INITIAL_SYNC are the steady state for ~95 CLI
                // sessions on every refresh — narrating each one produced 6.8k
                // lines / 1.1MB a day and buried the signals that matter. Count
                // them; only an actual rename earns its own line.
                var skipAuto = 0
                var initialSync = 0
                for session in filtered {
                    // claude-cli only — see the matching gate in the
                    // sessions-changed path above.
                    if session.provider == "claude-cli" {
                        let source = session.displayNameSource ?? "user"
                        let isAuthoritative = source == "cli" || source == "user"
                        if !isAuthoritative {
                            skipAuto += 1
                        } else if isInitialLoad {
                            initialSync += 1
                            self.onCliSessionRenamed?(session.sourceChatId, session.displayName, session.displayNameRenamedAt)
                        } else if let old = oldByID[session.id], old.displayName != session.displayName {
                            Self.debugLog("[AgentBridge] handleSessionsListResponse: CLI rename detected '\(old.displayName)' → '\(session.displayName)' src=\(source) (sourceChatId=\(session.sourceChatId))")
                            self.onCliSessionRenamed?(session.sourceChatId, session.displayName, session.displayNameRenamedAt)
                        }
                    }
                }
                if initialSync > 0 {
                    Self.debugLog("[AgentBridge] handleSessionsListResponse: initialSync=\(initialSync) skipAuto=\(skipAuto)")
                }
                // Publish only on change, like the pull path. An unconditional
                // assignment re-fired every `$sessions` sink on every push and
                // re-ran the unified rebuild for nothing.
                self.sessions = filtered
                ChatSession.saveToCache(filtered)
            }
            applyActiveSessionIdFromResponse(activeId)
            sessionsRetryCount = 0
            NSLog("[AgentBridge] Sessions updated: %d sessions (%d commit-view filtered), active: %@",
                  filtered.count, parsed.count - filtered.count, activeId ?? "nil")
        } else if sessions.isEmpty {
            // Only update active ID when we truly have no sessions yet
            applyActiveSessionIdFromResponse(activeId)
            NSLog("[AgentBridge] Empty sessions response (no cache)")
        } else {
            // Keep cached sessions, just update active ID
            applyActiveSessionIdFromResponse(activeId)
            NSLog("[AgentBridge] Empty sessions response, keeping %d cached sessions", sessions.count)
        }

        // If the web app returned empty sessions and we have no cache,
        // it may not have initialized its chat tab state yet. Retry.
        if parsed.isEmpty && sessions.isEmpty && sessionsRetryCount < Self.maxSessionsRetries {
            sessionsRetryCount += 1
            let attempt = sessionsRetryCount
            NSLog("[AgentBridge] No sessions, retrying (%d/%d)...", attempt, Self.maxSessionsRetries)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.requestSessions()
            }
        }
    }

    private func handleChatNewAck(_ message: [String: Any]) {
        let success = message["success"] as? Bool ?? false
        let chatId = message["chatId"] as? String
        NSLog("[AgentBridge] Chat new ack: success=%@, chatId=%@",
              success ? "true" : "false", chatId ?? "nil")

        if success {
            // Request updated sessions list so the native UI reflects the new tab.
            // Small delay to give the web app time to finalize the tab state.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.requestSessions()
            }
        }
    }

    // MARK: - Todo State (pinned lozenge + Dynamic Island)

    private func handleTodoStateUpdate(_ dict: [String: Any]) {
        guard let chatId = dict["chatId"] as? String,
              let version = dict["stateVersion"] as? Int,
              let itemDicts = dict["todos"] as? [[String: Any]] else {
            NSLog("[AgentBridge] todos:update — missing fields")
            return
        }

        // Ordering guard — drop out-of-order updates.
        if let existing = sessionList.todoStates[chatId], existing.version >= version {
            return
        }

        let items: [TodoItem] = itemDicts.compactMap { d in
            guard let content = d["content"] as? String,
                  let status = d["status"] as? String else { return nil }
            return TodoItem(
                content: content,
                status: status,
                activeForm: d["activeForm"] as? String
            )
        }
        let state = TodoState(version: version, todos: items, updatedAt: Date())
        sessionList.todoStates[chatId] = state
        todoStateSubject.send((chatId, state))
        NSLog("[AgentBridge] todos:update chatId=%@ version=%d items=%d",
              chatId, version, items.count)

        // If the user is already inside this chat, mark the new version as
        // viewed immediately so the session list doesn't flash the plan
        // summary row the instant they navigate back out. The title-bar
        // lozenge (which uses `sessionList.dismissedTodoVersions`) is unaffected.
        if let activeId = activeSessionId,
           let session = sessions.first(where: { $0.id == activeId }),
           session.sourceChatId == chatId {
            sessionList.listViewedTodoVersions[chatId] = version
        }
    }

    /// Called by the native lozenge's Dismiss button. Scopes the dismissal to
    /// the current version only — the next TodoWrite update (new version)
    /// re-shows the lozenge automatically.
    public func dismissTodoState(chatId: String) {
        guard let current = sessionList.todoStates[chatId] else { return }
        sessionList.dismissedTodoVersions[chatId] = current.version
        // Signal high-frequency consumers (Live Activity) to clear.
        todoStateSubject.send((chatId, nil))
    }

    /// Returns the todo state that should currently be visible for a chat,
    /// honoring any dismissal. Used by the title-bar lozenge to decide
    /// whether to render.
    // These methods delegate to SessionListStore so call sites that haven't
    // yet migrated to reading from bridge.sessionList directly keep compiling.
    public func visibleTodoState(for chatId: String) -> TodoState? {
        sessionList.visibleTodoState(for: chatId)
    }

    public func visibleTodoStateForList(for chatId: String) -> TodoState? {
        sessionList.visibleTodoStateForList(for: chatId)
    }

    public func latestToolLabelForList(for chatId: String) -> String? {
        sessionList.latestToolLabelForList(for: chatId)
    }

    public func latestToolActivityForList(for chatId: String) -> AgentActivityEvent? {
        sessionList.latestToolActivityForList(for: chatId)
    }

    /// Mark the currently-active session's todo state as viewed in the
    /// session list. Called automatically on `activeSessionId` changes and
    /// when a new todo update lands for a chat the user is already viewing.
    private func markActiveSessionTodoViewedInList() {
        guard let activeId = activeSessionId,
              let session = sessions.first(where: { $0.id == activeId }),
              let state = sessionList.todoStates[session.sourceChatId] else { return }
        sessionList.listViewedTodoVersions[session.sourceChatId] = state.version
    }

    // MARK: - Browser Capability Routing

    private func handleCapabilityRequest(_ message: [String: Any]) {
        let requestId = message["id"] as? String ?? UUID().uuidString
        let capability = message["capability"] as? String ?? ""
        let method = message["method"] as? String ?? ""
        let args = message["args"] as? [Any] ?? []

        // Gated like the other bridge hot-path logs (83f500d29): the web's
        // deployed-tools discovery polls tabs.query every 2s, so this line was
        // ~1,800 device-console entries an hour on every native client.
        if AgentBridge.verboseBridgeLog {
            NSLog("[AgentBridge] Capability request: %@.%@", capability, method)
        }

        Task { @MainActor in
            do {
                let result = try await self.capabilityRouter.invoke(
                    capability: capability,
                    method: method,
                    args: args
                )
                // Validate JSON serializability before sending
                if !JSONSerialization.isValidJSONObject(["r": result]) {
                    // Wrap primitive in array for validation
                    self.send([
                        "type": "\(messagePrefix)capability:response",
                        "version": protocolVersion,
                        "timestamp": currentTimestamp(),
                        "id": requestId,
                        "success": true,
                        "result": "\(result)",
                    ])
                } else {
                    self.send([
                        "type": "\(messagePrefix)capability:response",
                        "version": protocolVersion,
                        "timestamp": currentTimestamp(),
                        "id": requestId,
                        "success": true,
                        "result": result,
                    ])
                }
            } catch {
                let capError = error as? CapabilityError
                self.send([
                    "type": "\(messagePrefix)capability:response",
                    "version": protocolVersion,
                    "timestamp": currentTimestamp(),
                    "id": requestId,
                    "success": false,
                    "error": error.localizedDescription,
                    "errorCode": capError?.errorCode ?? "EXECUTION_FAILED",
                ])
            }
        }
    }

    /// Web → native mirror of host-mode preferences (hostEnabled / machineName).
    /// Mirrored in UserDefaults so a web-data wipe or heal purge can't silently
    /// disable hosting; the values are re-injected as window.__ripulHostPrefs on
    /// the next load (AgentWebView.hostPreferencesScript) and refreshed live here.
    private func handleHostPrefsSet(_ dict: [String: Any]) {
        if let enabled = dict["hostEnabled"] as? Bool {
            HostPreferences.hostEnabled = enabled
        }
        if let name = dict["machineName"] as? String {
            HostPreferences.machineName = name
        }
        pushHostPrefsToPage()
    }

    /// Web → native mirror of the long-lived machine token. Stored in the
    /// keychain so it survives web-data purges and can keep host comms alive
    /// when the Clerk session expires.
    private func handleHostTokenSet(_ dict: [String: Any]) {
        guard let token = dict["token"] as? String,
              let userId = dict["userId"] as? String,
              let machineId = dict["machineId"] as? String else {
            NSLog("[AgentBridge] Ignoring malformed host-token:set")
            return
        }
        let expiry = (dict["expiry"] as? TimeInterval).flatMap { Date(timeIntervalSince1970: $0) }
        MachineTokenStore.setToken(token, userId: userId, machineId: machineId, expiry: expiry)
        pushHostTokenToPage()
    }

    /// Refresh the live page's host token mirror.
    func pushHostTokenToPage() {
        if let token = MachineTokenStore.token {
            let escaped = token
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            evaluateJavaScript("window.__ripulHostToken = \"\(escaped)\";")
        } else {
            evaluateJavaScript("window.__ripulHostToken = null;")
        }
    }

    /// Refresh the live page's host-prefs mirror so reloads of THIS webview see
    /// the latest values (the documentStart script is baked at webview creation).
    func pushHostPrefsToPage() {
        evaluateJavaScript("window.__ripulHostPrefs = \(HostPreferences.injectionJSON);")
    }

    private func handleCapabilityPing(_ message: [String: Any]) {
        let requestId = message["id"] as? String ?? UUID().uuidString
        let caps = capabilityRouter.availableCapabilities + ["mcp"]
        send([
            "type": "\(messagePrefix)capability:pong",
            "version": protocolVersion,
            "timestamp": currentTimestamp(),
            "id": requestId,
            "success": true,
            "result": caps,
            "uiFeatures": nativeToolUIFeatures,
        ])

        // Capability ping proves the bridge is alive — treat it like a handshake.
        // The NativeBridgedContext sends capability:ping instead of the legacy handshake.
        if !isConnected {
            isConnected = true
            recordStartupProgress()
            loadError = nil
            loadErrorDetails = nil
            jsErrorMessages = []
            jsErrorDebounce?.cancel()
            NSLog("[AgentBridge] Bridge connected via capability:ping")

            // Fresh web page — drop stale per-chat sequences (see the matching
            // note in the handshake path above).
            sessionLifecycleSequences.removeAll()

            // Broadcast MCP tools if any are registered
            if !allTools.isEmpty {
                let defs = toolDefinitions
                send([
                    "type": "\(messagePrefix)mcp:tools",
                    "version": protocolVersion,
                    "timestamp": currentTimestamp(),
                    "tools": defs,
                ])
            }

            // Sync agent button state after a short delay so it overrides any stale
            // agent:status pushes the web app emits during initialization.
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5s
                await syncAgentStatus()
            }

            // Post-crash auto-probe
            if pendingPostCrashProbe {
                pendingPostCrashProbe = false
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000) // 3s
                    await probeWebViewHealth(trigger: "post-crash")
                }
            }
        }
    }

    // MARK: - Transport

    #if DEBUG
    /// Test-only observation seam: every outbound message, before the webView
    /// check. `internal` (not `public`) so only `@testable import` in this
    /// package's test target can reach it — a host can never set this.
    /// `#if DEBUG`-only so it doesn't exist in a release binary at all.
    /// Lets tests assert on `mcp:tools` broadcasts and `mcp:error`/`mcp:result`
    /// without a real WKWebView. See ChannelGateTests.
    @ObservationIgnored var testOutboundSink: (([String: Any]) -> Void)?
    #endif

    public func send(_ message: [String: Any]) {
        #if DEBUG
        testOutboundSink?(message)
        #endif
        guard let webView else {
            NSLog("[AgentBridge] Cannot send — webView is nil")
            return
        }

        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let json = String(data: data, encoding: .utf8) else {
            NSLog("[AgentBridge] Failed to serialize message — sending fallback error")
            sendSerializationFallback(message: message, webView: webView)
            return
        }

        let js = "window.__agentBridgeReceive(\(json))"
        #if DEBUG
        // [PERFMIN] native→web traffic by type: each is an evaluateJavaScript
        // round trip through JavaScriptCore on the main thread.
        MainThreadSampler.count("toWeb." + NSObject.shortType(message))
        #endif
        webView.evaluateJavaScript(js) { _, error in
            if let error {
                NSLog("[AgentBridge] JS eval error: %@", error.localizedDescription)
            }
        }
    }

    /// Last-resort fallback when `send()` can't serialize a message.
    /// Constructs a minimal mcp:error JSON string by hand so the LLM
    /// always sees *something* instead of a silent drop.
    private func sendSerializationFallback(message: [String: Any], webView: WKWebView) {
        let requestId = (message["requestId"] as? String ?? "unknown")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let messageType = message["type"] as? String ?? "unknown"

        let fallback = """
        {"type":"\(messagePrefix)mcp:error","version":"\(protocolVersion)",\
        "timestamp":\(currentTimestamp()),"requestId":"\(requestId)",\
        "error":"Native bridge failed to serialize the response for \(messageType). \
        The tool may have succeeded but returned non-JSON-safe data."}
        """
        let js = "window.__agentBridgeReceive(\(fallback))"
        webView.evaluateJavaScript(js) { _, error in
            if let error {
                NSLog("[AgentBridge] Fallback JS eval error: %@", error.localizedDescription)
            }
        }
    }

    private func currentTimestamp() -> Int {
        Int(Date().timeIntervalSince1970 * 1000)
    }
}
