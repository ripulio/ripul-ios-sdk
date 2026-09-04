#if os(iOS)
import SwiftUI
import WebKit

/// Spring for the chat <-> session-list slide. Used for gesture settles and for
/// closing back to the list. Bump `response` to slow it further.
private let chatSlideSpring: Animation = .spring(response: 0.45, dampingFraction: 0.86)

/// Animation for OPENING a chat by picking a session (list -> chat). An ease-out
/// (easeOutQuint) curve: quick off the mark, then a pronounced deceleration that
/// brakes gently into the final position with no bounce — a soft landing at the
/// end. `duration` controls how fast the open feels.
private let chatOpenAnimation: Animation = .timingCurve(0.22, 1.0, 0.36, 1.0, duration: 0.625)

public extension Notification.Name {
    /// Posted by a host (e.g. the app's CommitsScreen) to open a read-only
    /// committed session in the agent screen, or (without commit keys) to focus
    /// a session. userInfo: commitShortSha, commitSessionTitle, commitMachineId,
    /// commitSessionId, session.
    static let ripulFocusSession = Notification.Name("ripulFocusSession")
    /// Posted by a host to start a "discuss this file" chat. userInfo: path, line?.
    static let ripulDiscussFile = Notification.Name("ripulDiscussFile")
}

/// App-coupling slots for `RipulAgentScreen`. The first-party Ripul app injects
/// all of these; a developer-console host (e.g. WAC) injects none. Every slot
/// defaults to "feature absent", never "feature broken".
public struct RipulAgentScreenSlots {
    /// Compact leading action in list mode opens the host's sidebar, and a
    /// right-drag on the list does the same. nil = no sidebar chrome.
    public var showingSidebar: Binding<Bool>?
    /// File-viewer menu "Saved Files" jumps to the host's files tab.
    public var onNavigateToFiles: (() -> Void)?
    /// Commit-view dismiss jumps to the host's commits tab.
    public var onNavigateToCommits: (() -> Void)?
    /// "Invite by Email" — host presents its invite UI for the share URL.
    /// Also injects the Invite-by-Email activity into the share sheet.
    public var onInviteByEmail: ((String) -> Void)?
    /// Screen-tip button builder (e.g. the app's ScreenTipButton) for the
    /// list-mode title lozenge.
    public var screenTip: ((String) -> AnyView)?
    /// `ripul://choose` hand-off state; picking a session returns it to the
    /// calling app instead of opening it.
    public var chooseMode: RipulChooseMode?
    /// Host chrome rendered in the top bar's trailing edge, AFTER the context
    /// menu (e.g. WAC's minimize-to-bubble). Style it with `GlassButton` /
    /// `GlassCircleModifier` to match the bar's own buttons exactly.
    public var topBarTrailingAccessory: (() -> AnyView)?
    /// The host renders its own root bar over the session LIST (the
    /// first-party Agents|Plans shell: stock segmented control + the same
    /// SessionListMenu). This screen's bar then hides in list mode only —
    /// chat, metadata, commit and file-viewer states keep the unified bar
    /// with all of its earned machinery. nil/false = standalone screen,
    /// bar always on.
    public var hidesListModeBar: Bool

    public init(
        showingSidebar: Binding<Bool>? = nil,
        onNavigateToFiles: (() -> Void)? = nil,
        onNavigateToCommits: (() -> Void)? = nil,
        onInviteByEmail: ((String) -> Void)? = nil,
        screenTip: ((String) -> AnyView)? = nil,
        chooseMode: RipulChooseMode? = nil,
        topBarTrailingAccessory: (() -> AnyView)? = nil,
        hidesListModeBar: Bool = false
    ) {
        self.showingSidebar = showingSidebar
        self.onNavigateToFiles = onNavigateToFiles
        self.onNavigateToCommits = onNavigateToCommits
        self.onInviteByEmail = onInviteByEmail
        self.screenTip = screenTip
        self.chooseMode = chooseMode
        self.topBarTrailingAccessory = topBarTrailingAccessory
        self.hidesListModeBar = hidesListModeBar
    }
}

/// The whole agent screen, 1:1 with the first-party Ripul app: session list +
/// chat with the thumb-tracked slide, morphing unified glass top bar, metadata
/// panel (right-edge swipe / docked inspector), native file viewer, commit
/// view, raw-mode/model/effort menus, and the native chat composer.
///
/// Ported from `iOS/AgentScreen.swift` for the M8 whole-screen extraction.
/// Deviations from the app original are exactly the injected slots
/// (`RipulAgentScreenSlots`) and `UserDefaults.appDefaults` →
/// `configuration.cache`. Keep everything else identical.
@available(iOS 26.0, *)
public struct RipulAgentScreen: View {
    @ObservedObject var bridge: AgentBridge
    @ObservedObject var model: RipulSessionListModel
    let configuration: RipulSessionsConfiguration
    let tokenProvider: () -> String?
    let slots: RipulAgentScreenSlots

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Starts on the session LIST, exactly like the app (ContentView seeds
    /// showingSessionList = true) - landing on an empty chat instead is the
    /// single most visible 'nothing like Ripul' break for SDK hosts.
    @State private var fallbackShowingSessionList = true
    /// External owner of the list<->chat visibility (e.g. the app's ContentView,
    /// which drives it from deep links). nil = the screen owns the state.
    private let externalShowingSessionList: Binding<Bool>?
    private var showingSessionList: Binding<Bool> {
        externalShowingSessionList ?? $fallbackShowingSessionList
    }
    @State private var renamingSession: ChatSession?
    @State private var renameText = ""
    /// Non-nil while the shared model picker is up, naming what it will change.
    @State private var modelPickerTarget: ModelPickerTarget?

    /// What the picker sheet is repointing: the global model override, or one
    /// CLI session's raw model. The two used to be separate nested `Menu`
    /// trees; they are now the same picker with a different model list.
    private enum ModelPickerTarget: Identifiable {
        case global
        case raw(sessionId: String)
        /// Not repointing anything — starting a session with the picked model.
        case newSession

        var id: String {
            switch self {
            case .global: return "global"
            case .raw(let sessionId): return "raw:\(sessionId)"
            case .newSession: return "newSession"
            }
        }
    }
    @State private var rawModeSessions: Set<String> = []
    @State private var sessionProviders: [String: String] = [:]
    @State private var sessionModelIds: [String: String] = [:]
    /// Expanded/contracted state of the chat title lozenge. A single tap
    /// toggles it and the choice is remembered across chats AND launches,
    /// because it is a preferred layout, not a one-off reveal.
    ///
    /// @State with a manual write-through, NOT @AppStorage: an @AppStorage
    /// mutation re-enters the view through the UserDefaults publisher OUTSIDE
    /// the withAnimation transaction, so the lozenge snapped open instead of
    /// morphing. Same fix, same reason as the sidebar machine disclosures.
    /// Namespace for the title lozenge's glass morph. Owned HERE, not by the
    /// bar: the two states are two glass shapes sharing one id, and the id has
    /// to live with the branches for the container to morph between them.
    @Namespace private var titleGlassNS
    @State private var chatTitleLozengeExpanded =
        UserDefaults.standard.bool(forKey: "ripul.chatTitleLozengeExpanded")
    /// Machine display name → SF Symbol, for the top-bar row's machine glyph.
    /// Cached rather than derived per body pass — the bar re-renders on every
    /// live activity tick and this reads the defaults suite.
    @State private var machineIcons: [String: String] = [:]
    @State private var codexModelsByMachineId: [String: [ModelInfo]] = [:]
    @State private var codexModelLoadsInFlight = Set<String>()
    @State private var rawModeError: String = ""
    @State private var showRawModeError = false
    @State private var forkError: String = ""
    @State private var showForkError = false
    @State private var favoriteDirectories: [String] = []
    @State private var sessionWorkingDirectory: String?
    @State private var hostWorkingDirectory: String?
    @State private var favoriteFiles: [String] = []
    // Metadata panel — offset from right edge (screenWidth = hidden, 0 = fully visible).
    @State private var metadataOffset: CGFloat = UIScreen.main.bounds.width
    @State private var showingMetadata = false
    // File viewer panel — slides a native StandaloneFileViewer over the chat using the
    // SAME SlidePanelOverlay as the metadata panel and the Files tab, so it slides in
    // and thumb-tracks back exactly like navigating into/out of a chat session.
    @State private var fileViewerOffset: CGFloat = UIScreen.main.bounds.width
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var elementDebuggerActive = false
    /// Debug: overlay the native chat scroller on top of the (still-live) web view.
    @State private var showNativeChatScroller = false

    /// Context when viewing a session opened from the commits browser.
    private struct CommitViewInfo {
        let shortSha: String
        let sessionTitle: String
        let machineId: String
        let tabId: String
        let sessionId: String?
    }
    @State private var commitViewInfo: CommitViewInfo?
    @State private var parentGlobalY: CGFloat = 0
    /// Window-level top inset for the floating top bar, fed by
    /// `WindowSafeAreaTopReader` — see topBarOverlay for why it can be neither
    /// inherited from the hierarchy nor read from UIApplication during body.
    @State private var safeAreaTop: CGFloat = 54

    private var cache: RipulSessionCache { configuration.cache }

    public init(
        bridge: AgentBridge,
        model: RipulSessionListModel,
        configuration: RipulSessionsConfiguration,
        tokenProvider: @escaping () -> String?,
        slots: RipulAgentScreenSlots = .init(),
        showingSessionList: Binding<Bool>? = nil
    ) {
        self.bridge = bridge
        self.model = model
        self.configuration = configuration
        self.tokenProvider = tokenProvider
        self.slots = slots
        self.externalShowingSessionList = showingSessionList
    }

    // MARK: - Shared content (used by both the compact slide-over and the regular split)

    /// Web-view configuration — identical across layouts, and identical to the
    /// first-party app: /popup, native chrome hidden, native chat composer.
    private var agentConfig: AgentConfiguration {
        var config = AgentConfiguration(
            baseURL: configuration.baseURL,
            path: "/popup",
            siteKey: configuration.siteKey,
            theme: configuration.theme == .system ? (colorScheme == .dark ? .dark : .light) : configuration.theme,
            nativeApp: true,
            hideHeader: true,
            hideTabSwitcher: true,
            hideChatInput: true,
            nativeChatInputHeight: 140
        )
        config.websiteDataStore = configuration.websiteDataStore
        // Console auto-entry (native-tool-registry phase 3): a cached seeded
        // Developer-context id — written by RipulAgentConsole after its
        // authenticated bootstrap fetch — rides the URL as `context=<id>`; the
        // web app enters it once its contexts load. Clerk mode only: alongside
        // a siteKey the web side refuses client-side entry anyway, so the
        // param is not emitted. First-ever console launch has nothing cached
        // and boots with no context (today's behavior); every later launch
        // auto-enters.
        if configuration.siteKey == nil,
           let devContextId = configuration.cache.object(forKey: RipulSeededContextCache.devContextIdKey) as? String {
            config.clerkContextId = devContextId
        }
        return config
    }

    /// The agent web view. Compact wraps it in the edge-swipe rig (full-bleed);
    /// the regular split passes fillsSafeArea: false so the WKWebView stays confined
    /// to its detail column instead of drawing under the sidebar.
    private func agentWebView(fillsSafeArea: Bool) -> some View {
        // The native scroller is rendered INSIDE AgentView (over the web view, under
        // the reused ChatComposer) — we just sync the debug flag onto the bridge.
        AgentView(configuration: agentConfig, bridge: bridge, fillsSafeArea: fillsSafeArea, tokenProvider: tokenProvider) { _ in EmptyView() }
            .onAppear { bridge.nativeChatScrollerEnabled = showNativeChatScroller }
            .onChange(of: showNativeChatScroller) { bridge.nativeChatScrollerEnabled = $0 }
    }

    /// Session metadata content, shared by the compact slide-out overlay and the
    /// regular docked inspector.
    private var metadataPanel: some View {
        SessionMetadataPanel(
            bridge: bridge,
            session: bridge.sessions.first(where: { $0.id == bridge.activeSessionId })
        )
    }

    /// The session list, shared by both layouts. `dismiss` is the only per-layout
    /// difference: the compact slide-over closes itself on select/new-chat; the
    /// regular sidebar is persistent and passes a no-op.
    private func sessionListColumn(dismiss: @escaping () -> Void) -> some View {
        RipulSessionsView(
            bridge: bridge,
            cache: configuration.cache,
            tokenProvider: tokenProvider,
            onSelectSession: { session in
                // Choose mode: return this session to the calling app instead of
                // opening it. (Set by a `ripul://choose` hand-off — see RipulChooseMode.)
                if let chooseMode = slots.chooseMode, chooseMode.active {
                    chooseMode.pick(session)
                    withAnimation(.easeInOut(duration: 0.28)) { showingSessionList.wrappedValue = false }
                    return
                }
                let alreadyActive = bridge.activeSessionId == session.id
                if alreadyActive {
                    // Re-entering the already-loaded chat. Skip focusSession (its
                    // __ripulFocusSession blocks ~3s on a V2ChatScroller sweep-timeout
                    // that never fires for an already-rendered chat) and skip the row
                    // spinner. Flip showingSessionList from INSIDE a Task, on a clean
                    // render tick — NOT synchronously in the row tap. A synchronous
                    // flip conflates the container rebuild with the offset change and
                    // the slide SNAPS deterministically on re-entry; the deferred flip
                    // (the same path the other branch uses) reliably slides. One frame
                    // of sleep lets the tap's render settle before the flip.
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 16_000_000)
                        withAnimation(chatOpenAnimation) {
                            showingSessionList.wrappedValue = false
                        }
                        try? await Task.sleep(nanoseconds: 700_000_000) // just past the 0.625s open slide
                        bridge.scrollToBottom()
                    }
                } else {
                    // Different session: show the row spinner, then flip the web view
                    // BEFORE sliding (focusSession awaits window.__ripulFocusSession)
                    // so the chat never slides in showing the prior session.
                    bridge.navigatingToSessionId = session.id
                    Task { @MainActor in
                        await bridge.focusSession(id: session.id)
                        withAnimation(chatOpenAnimation) {
                            showingSessionList.wrappedValue = false
                        }
                        // Defer the remaining @Published churn past the open animation.
                        try? await Task.sleep(nanoseconds: 700_000_000) // just past the 0.625s open slide
                        bridge.scrollToBottom()
                        bridge.navigatingToSessionId = nil
                    }
                }
            },
            onDismiss: { dismiss() },
            allowRipulAgents: configuration.allowRipulAgents,
            invitesSection: configuration.invitesSection,
            foldersSection: configuration.foldersSection,
            // nil omits the panel entirely — GlassSessionsList renders it only
            // when present, so the role gate needs no plumbing further down.
            solutionManagement: configuration.showsSolutionManagement
                ? RipulSolutionManagement(
                    registry: configuration.registry,
                    baseURL: configuration.baseURL,
                    tokenProvider: tokenProvider,
                    showsSiteKeyAdmin: configuration.showsSiteKeyAdmin,
                    buildsApp: configuration.buildsApp
                )
                : nil,
            emptyStateOverride: configuration.emptyStateOverride,
            model: model,
            chooseMode: slots.chooseMode,
            showsTitleLozenge: false,
            // The host's app-nav sidebar is a pinned rail at regular width, so
            // there is nothing for a right-drag on the list to slide open.
            showingSidebar: horizontalSizeClass == .regular ? nil : slots.showingSidebar,
            quickActionsEnabled: configuration.quickActionsEnabled,
            // Regular width pins the list as a split-view column with its own
            // navigation-bar strip, and the floating bar is overlaid on the
            // chat detail only — reserving 52pt here would be a stranded gap.
            reservesTopBarSpace: horizontalSizeClass != .regular
        )
    }

    // Regular-width (iPad / Mac Catalyst): persistent sidebar (session list) + chat
    // detail. Same content as the compact slide-over — only the container differs.
    private var regularSplit: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sessionListColumn(dismiss: {})
                .navigationSplitViewColumnWidth(min: 420, ideal: 420)
        } detail: {
            // fillsSafeArea: false keeps the WKWebView confined to its column instead
            // of full-bleeding under the translucent sidebar. The top bar (glass +
            // buttons) is overlaid here so it covers only the chat, not the other columns.
            agentWebView(fillsSafeArea: false)
                .overlay(alignment: .top) {
                    // Ignore the top safe-area inset here so the title bar sits flush
                    // with the top of the chat column (otherwise it floats ~50px down
                    // inside the glass on Mac Catalyst, which has no status bar).
                    topBarOverlay
                        .ignoresSafeArea(edges: .top)
                }
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder private var layout: some View {
        if horizontalSizeClass == .regular {
            regularSplit
        } else {
            compactBody
        }
    }

    /// True while the tab-mirror overlay owns the webview. The agent screen's
    /// edge-swipe affordances must stand down then: their UIKit recognizers
    /// arbitrate over every horizontal touch (delaying webview delivery — the
    /// mirror camera's jank), and a right-edge swipe opening the CHAT's
    /// metadata panel over a mirrored browser is a category error.
    private var mirrorOwnsWebview: Bool { bridge.currentPageContext.page == "tabMirror" }

    private var compactBody: some View {
        AgentChatDragContainer(
            showingSessionList: showingSessionList,
            showingMetadata: showingMetadata,
            suppressEdgeSwipe: mirrorOwnsWebview,
            bridge: bridge,
            isFileViewerOpen: bridge.fileViewerTitle != nil,
            hasCommitView: commitViewInfo != nil,
            onCommitViewDismiss: dismissCommitView,
            onFileViewerSwipeCommit: { bridge.requestFileViewerClose() },
            sessionList: {
                sessionListColumn(dismiss: {
                    withAnimation(.easeInOut(duration: 0.28)) {
                        showingSessionList.wrappedValue = false
                    }
                })
            },
            chat: {
                agentWebView(fillsSafeArea: true)
                    .overlay(alignment: .trailing) {
                        if !showingSessionList.wrappedValue && !showingMetadata && !mirrorOwnsWebview {
                            RightEdgeSwipeView(
                                onChanged: { offset in
                                    guard bridge.fileViewerTitle == nil else { return }
                                    var t = Transaction()
                                    t.disablesAnimations = true
                                    let screenWidth = UIScreen.main.bounds.width
                                    withTransaction(t) { metadataOffset = screenWidth - offset }
                                },
                                onEnded: { offset, velocity in
                                    guard bridge.fileViewerTitle == nil else { return }
                                    let screenWidth = UIScreen.main.bounds.width
                                    let shouldCommit = offset > screenWidth * 0.35 || velocity > 400
                                    if shouldCommit {
                                        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                                            metadataOffset = 0
                                            showingMetadata = true
                                        }
                                    } else {
                                        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                                            metadataOffset = screenWidth
                                        }
                                    }
                                },
                                onCancelled: {
                                    guard bridge.fileViewerTitle == nil else { return }
                                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                                        metadataOffset = UIScreen.main.bounds.width
                                    }
                                }
                            )
                            .frame(width: 20)
                            .ignoresSafeArea()
                        }
                    }
            }
        )
    }

    public var body: some View {
        layout
        .ignoresSafeArea(.keyboard)
        .background {
            GeometryReader { geo in
                Color.clear.preference(key: KeyboardStableYKey.self, value: geo.frame(in: .global).minY)
            }
        }
        .onPreferenceChange(KeyboardStableYKey.self) { parentGlobalY = $0 }
        .background(WindowSafeAreaTopReader { safeAreaTop = $0 })
        // Metadata panel — compact: slides in from the right edge; regular (iPad /
        // Mac Catalyst): docks as a trailing inspector column.
        .overlay {
            if horizontalSizeClass != .regular {
                SlidePanelOverlay(
                    isPresented: $showingMetadata,
                    offset: $metadataOffset
                ) {
                    metadataPanel
                }
            }
        }
        // File viewer — slides a native StandaloneFileViewer over the chat (its own
        // isolated web view, no chat-flash), using the SAME SlidePanelOverlay slide +
        // thumb-tracking drag-back as navigating into/out of a chat session. Driven by
        // the web's fileViewer:expand intent via bridge.fileViewerFilePath.
        .overlay {
            SlidePanelOverlay(
                isPresented: Binding(
                    get: { bridge.fileViewerTitle != nil },
                    set: { presented in if !presented { bridge.requestFileViewerClose() } }
                ),
                offset: $fileViewerOffset
            ) {
                if let path = bridge.fileViewerFilePath {
                    StandaloneFileViewer(
                        filePath: path,
                        chatId: bridge.activeSessionId,
                        readBridge: bridge,
                        siteKey: configuration.siteKey,
                        baseURL: configuration.baseURL
                    )
                }
            }
        }
        // On a wide screen the metadata panel is always docked as a permanent
        // trailing column (no toggle); compact uses the slide-out overlay above.
        .inspector(isPresented: .constant(horizontalSizeClass == .regular)) {
            metadataPanel
                .inspectorColumnWidth(min: 280, ideal: 340, max: 480)
        }
        // Floating top bar — compact only. On the regular split it's applied to the
        // chat detail instead, so the glass strip doesn't span the sidebar / metadata
        // columns.
        .overlay(alignment: .top) {
            if horizontalSizeClass != .regular {
                // Pin to the physical top; topBarOverlay adds the window inset
                // back. Previously this branch inherited the inset while the
                // regular branch zeroed it — see topBarOverlay.
                topBarOverlay
                    .ignoresSafeArea(edges: .top)
            }
        }
        // Read-only banner when viewing a committed session
        .overlay(alignment: .bottom) {
            if let info = commitViewInfo,
               bridge.sessions.first(where: { $0.id == bridge.activeSessionId })?.id == info.tabId || bridge.activeSessionId == info.tabId {
                CommitViewBanner(
                    shortSha: info.shortSha,
                    onResume: { resumeCommitSession(info) }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: commitViewInfo != nil)
        .uiKitIdentifier("AgentScreen")
        .renameSessionAlert(renamingSession: $renamingSession, renameText: $renameText, bridge: bridge)
        .alert("CLI Error", isPresented: $showRawModeError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(rawModeError)
        }
        .alert("Fork Failed", isPresented: $showForkError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(forkError)
        }
        .sheet(item: $modelPickerTarget) { target in
            modelPickerSheet(for: target)
        }
        .onChange(of: showingSessionList.wrappedValue) { showing in
            if showing {
                Task { await model.loadMachinesFromAPI() }
            } else {
                rawModeSessions = Set(cache.stringArray(forKey: "ripulRawModeSessions") ?? [])
                sessionProviders = cache.dictionary(forKey: "ripulSessionProviders") as? [String: String] ?? [:]
                sessionModelIds = cache.dictionary(forKey: "ripulSessionModelIds") as? [String: String] ?? [:]
                // Refreshed on the way out of the list rather than via its own
                // .onChange(of: model.machines): body's modifier chain is
                // already at the type checker's limit, and one more closure on
                // it fails the iOS build outright. Machines change rarely and
                // the list is the only place they can be renamed or re-iconed.
                machineIcons = RemoteMachine.iconsByDisplayName(machines: model.machines, cache: cache)
            }
        }
        .onChange(of: bridge.fileViewerTitle) { _, title in
            if title != nil {
                // Slide the native file viewer in over the chat, braking into place
                // exactly like opening a chat session (chatOpenAnimation). The
                // SlidePanelOverlay owns the thumb-tracked drag-back out.
                withAnimation(chatOpenAnimation) {
                    fileViewerOffset = 0
                }
            } else if bridge.fileViewerReturnToSessions {
                bridge.fileViewerReturnToSessions = false
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    showingSessionList.wrappedValue = true
                }
            }
        }
        .task {
            // Seed persisted view state (the app's @AppStorage equivalents).
            rawModeSessions = Set(cache.stringArray(forKey: "ripulRawModeSessions") ?? [])
            sessionProviders = cache.dictionary(forKey: "ripulSessionProviders") as? [String: String] ?? [:]
            sessionModelIds = cache.dictionary(forKey: "ripulSessionModelIds") as? [String: String] ?? [:]
            machineIcons = RemoteMachine.iconsByDisplayName(machines: model.machines, cache: cache)
            favoriteFiles = cache.stringArray(forKey: "ripulFavoriteFiles") ?? []
            elementDebuggerActive = cache.bool(forKey: "elementDebuggerActive")
            showNativeChatScroller = cache.bool(forKey: "showNativeChatScroller")

            Task { await bridge.fetchEffort() }
            if bridge.availableModels.isEmpty {
                Task { await bridge.fetchModels() }
            }
            // Seed from last-known-good so the Working Directory menu has the
            // host's favourites immediately, then refresh live — the relay
            // chain (webview callable → event bus → room RPC → host CLI
            // server) is often still booting at this point, and a failed
            // one-shot fetch here left the menu empty for the app's lifetime.
            if favoriteDirectories.isEmpty {
                favoriteDirectories = cache.stringArray(forKey: "ripulFavoriteDirectories") ?? []
            }
            Task { await refreshFavoriteDirectories() }
            if let activeSession = bridge.sessions.first(where: { $0.id == bridge.activeSessionId }) {
                await refreshCodexModelsIfNeeded(for: activeSession)
            }
        }
        .onChange(of: tokenProvider()) { newToken in
            if newToken != nil {
                Task { await model.refreshAfterAuth() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            Task { await model.refresh() }
            Task { await refreshFavoriteDirectories() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ripulDiscussFile)) { notification in
            if let path = notification.userInfo?["path"] as? String {
                let line = notification.userInfo?["line"] as? Int
                startDiscussSession(path: path, line: line)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ripulFocusSession)) { notification in
            if let shortSha = notification.userInfo?["commitShortSha"] as? String,
               let title = notification.userInfo?["commitSessionTitle"] as? String,
               let machineId = notification.userInfo?["commitMachineId"] as? String,
               let session = notification.userInfo?["session"] as? ChatSession {
                let sessionId = notification.userInfo?["commitSessionId"] as? String
                commitViewInfo = CommitViewInfo(
                    shortSha: shortSha,
                    sessionTitle: title,
                    machineId: machineId,
                    tabId: session.id,
                    sessionId: sessionId
                )
                bridge.suppressNativeChatInput = true
            }
        }
        .onChange(of: bridge.activeSessionId) { newId in
            if let info = commitViewInfo, newId != info.tabId {
                bridge.unmarkSessionEphemeral(info.tabId)
                commitViewInfo = nil
                bridge.suppressNativeChatInput = false
            }
            if let newId, let session = bridge.sessions.first(where: { $0.id == newId }) {
                Task { await refreshCodexModelsIfNeeded(for: session) }
                Task { await refreshFavoriteDirectories() }
            }
        }
        .onChange(of: bridge.sessions) { _ in
            if let activeSession = bridge.sessions.first(where: { $0.id == bridge.activeSessionId }) {
                Task { await refreshCodexModelsIfNeeded(for: activeSession) }
            }
        }
    }

    // MARK: - Unified Top Bar (morphs between list and chat modes)

    // Floating top bar (glass strip + buttons). Full-width on compact; on the
    // regular split it's overlaid on just the chat detail so the glass doesn't
    // run across the sidebar and metadata columns.
    /// Both mount points pin this with `.ignoresSafeArea(edges: .top)` and
    /// `safeAreaTop` adds the **window's** inset back, so the bar's position is
    /// stated, not inherited. Neither obvious source for that inset works:
    ///
    /// - **Not the hierarchy** (a `GeometryReader`'s `safeAreaInsets`):
    ///   ancestors consume or zero the region — that was the original bug.
    ///   `agentTopBarContent` carries only `.padding(.top, 4)`, so an inherited
    ///   inset dropped the lozenge to physical-top + 4, under the notch, and
    ///   `safeAreaGlass` hid the evidence because it bleeds to the physical top
    ///   either way.
    /// - **Not `UIApplication`/`UIWindow` read during `body`**:
    ///   `UIWindow.safeAreaInsets` computes status-bar visibility, which queries
    ///   a SwiftUI preference, which synchronously re-enters this very body
    ///   evaluation — one nested pass through these frames overflows the
    ///   main-thread stack in Debug builds (deterministic launch crash,
    ///   ___chkstk_darwin SIGSEGV).
    ///
    /// So `WindowSafeAreaTopReader` (mounted on `body`'s root) reads the window
    /// inset from UIKit callbacks outside any SwiftUI update and feeds the
    /// `safeAreaTop` state. Catalyst has no status bar, so its inset reports 0
    /// and the bar sits flush as before.
    @ViewBuilder private var topBarOverlay: some View {
        if bridge.currentPageContext.showNativeHeader {
            // Hidden (not removed) while the host's root bar covers list
            // mode, so the glass containers stay mounted and the reappear on
            // chat entry is a fade on the same value the bar's own content
            // already animates on.
            // Yields at regular width too. The host's root bar floats over the
            // whole split there, so keeping this one would stack the screen's
            // "Agents" lozenge behind the root bar's Agents|Plans picker.
            let hiddenForHostBar = slots.hidesListModeBar
                && showingSessionList.wrappedValue
                && !showingMetadata
                && bridge.fileViewerTitle == nil
            ZStack(alignment: .top) {
                safeAreaGlass
                unifiedTopBar
                    .padding(.top, safeAreaTop)
                // The chat title morph, a SIBLING of the bar rather than its
                // centre slot — see `chatTitleMorphOverlay`. Same placement
                // maths as the slot it replaces: the bar's 12pt gutter plus
                // the symmetric centre inset, and the bar's 4pt top padding.
                chatTitleMorphOverlay
                    .padding(.horizontal, 12 + centerLozengeInset)
                    .padding(.top, safeAreaTop + 4)
            }
            .offset(y: parentGlobalY < 0 ? -parentGlobalY : 0)
            .opacity(hiddenForHostBar ? 0 : 1)
            .allowsHitTesting(!hiddenForHostBar)
            // TEMPORARILY no .animation(value: hiddenForHostBar) here: an
            // ancestor value-animation can strip inherited transactions from
            // its whole subtree when its own value is unchanged, and this one
            // sits above the lozenge morph and the diagnostic twin. The
            // hide/show fade snaps until this is re-plumbed.
        }
    }

    /// Single top bar that stays fixed during swipe and morphs its content on completion.
    @ViewBuilder
    private var unifiedTopBar: some View {
        let activeSession = bridge.sessions.first(where: { $0.id == bridge.activeSessionId })

        // File viewer overrides everything with its own bar
        if let fileTitle = bridge.fileViewerTitle {
            fileViewerTopBar(title: fileTitle)
        } else {
            // NO glass container at this level. The lozenge morph's container
            // lives in `titleLozengeContent`, wrapped immediately around the
            // two branches — a container here would nest around it (nested
            // containers don't compose), and a container this far from the
            // branches, across the GlassTopBar component boundary, never
            // morphed either. The bar's edge buttons draw their glass
            // standalone, which needs no container.
            agentTopBarContent(session: activeSession)
        }
    }

    /// Inset so the pill doesn't overlap with buttons on either side.
    /// Trailing side can have two buttons (scrollUp 44 + spacing 8 + menu 44
    /// = 96px), so pad symmetrically to the larger side when the scroll button
    /// is visible. A host accessory button adds another 52px (44 + 8).
    private var centerLozengeInset: CGFloat {
        // Chat used to pad to 108 to clear a scroll-up accessory; that button
        // now exists ONLY inside the expanded lozenge, so both modes use the
        // single-button 56 — and the expanded form gets the freed width.
        56 + (slots.topBarTrailingAccessory != nil ? 52 : 0)
    }

    /// The agent bar IS `GlassTopBar` — this screen supplies slot content only.
    /// Everything that used to justify a fork (screen-centred lozenge, glass
    /// morph namespace, contextual menu, host accessory) is a parameter now, and
    /// the swipe-down screen overview comes along for free.
    @ViewBuilder
    private func agentTopBarContent(session: ChatSession?) -> some View {
        GlassTopBar(
            title: "",
            // No AnyView. Erasing this slot's type stops SwiftUI retaining
            // the `.animation(_:value:)` inside titleLozengeContent across
            // updates, so the morph never animated at all.
            center: { titleLozengeContent(session: session) },
            // In a chat the centre slot draws its own glass in BOTH states so
            // the contracted capsule and the expanded panel are one glass id
            // leaving and re-entering the container — which is the morph.
            // Elsewhere the lozenge names a screen and the bar's pill is right.
            centerOwnsGlass: expandedTitleAvailable,
            leading: agentLeading(session: session),
            trailingOuter: agentHostAccessory,
            // Kick a favourites refresh as the menu opens. The fetch is async
            // so this presentation may still show the cached list, but Menu
            // content is rebuilt from state between presentations — the next
            // open is fresh even if every earlier trigger raced the relay boot.
            onMenuOpen: { Task { await refreshFavoriteDirectories() } },
            centerInset: centerLozengeInset,
            onDoubleTapTitle: {
                bridge.logToWebConsole("[AgentScreen] title lozenge double-tap -> bridge.toggleElementDebugger")
                bridge.toggleElementDebugger()
            },
            // No tap here in chat: the morphing pill is `chatTitleMorphOverlay`,
            // stacked over this slot, and it owns the single/double taps.
            // Elsewhere the lozenge names a screen and never had a tap.
            onTapTitle: nil,
            menuKey: agentMenuKey(session: session)
        ) {
            agentMenuContent(session: session)
        }
        // Sync the title bar to the chat<->list slide so the lozenge, title and
        // buttons travel on the SAME timeline as the panel. Mirror the container's
        // slideAnimation: brake (chatOpenAnimation) when opening into the chat,
        // spring (chatSlideSpring) when closing back to the list. The previous
        // fixed 0.6s spring desynced from the (variable) slide duration — e.g. the
        // lozenge settled in 0.6s while the panel was still travelling.
        .animation(showingSessionList.wrappedValue ? chatSlideSpring : chatOpenAnimation, value: showingSessionList.wrappedValue)
        .animation(.spring(response: 0.6, dampingFraction: 0.65), value: showingMetadata)
        // No .animation(value: chatTitleLozengeExpanded) here — the morph's
        // spring lives on its glass container in `titleLozengeContent`.
        // A second implicit transaction on the same value would compete with
        // it and re-introduce the snap.
    }

    /// Expanded AND in a state where expansion is meaningful. The pill shape,
    /// the header's line limit and the disclosed block all key off this one
    /// value so they can never disagree mid-animation.
    private var titleLozengeExpandedNow: Bool {
        chatTitleLozengeExpanded && expandedTitleAvailable
    }

    /// Whether the expanded lozenge (and its tap toggle) applies right now:
    /// chat only. List/metadata/commit/file-viewer states name a screen or a
    /// file, not a chat, so the lozenge there keeps its old tap-through
    /// behaviour and never morphs.
    private var expandedTitleAvailable: Bool {
        !showingSessionList.wrappedValue
            && !showingMetadata
            && bridge.fileViewerTitle == nil
            && commitViewInfo == nil
    }

    private func toggleTitleLozenge() {
        // withAnimation at the mutation site — the driver WAC's Glass Sandbox
        // morphs with on this same phone. (The .animation(value:) container
        // driver, copied from BrowserScreen, snapped in this screen every
        // time.) Persist + console log stay deferred a tick so no
        // bridge/WebKit work runs inside the morph's transaction.
        // Tuned on-device: 0.5/0.58 read as latent. Shorter response = the
        // growth starts and lands faster; lower damping = a visible bounce.
        withAnimation(.spring(response: 0.32, dampingFraction: 0.55)) {
            chatTitleLozengeExpanded.toggle()
        }
        let expanded = chatTitleLozengeExpanded
        Task { @MainActor in
            UserDefaults.standard.set(expanded, forKey: "ripul.chatTitleLozengeExpanded")
            bridge.logToWebConsole("[AgentScreen] title lozenge tap -> expanded=\(expanded)")
        }
    }

    /// Contents of the lozenge's expanded form. Strings derive from the SAME
    /// sources as the compact row (`unifiedRow`, `topBarSubtitle`,
    /// `ModelIdentity`) so the two presentations can never disagree about
    /// what chat this is.
    // NOT @ViewBuilder: the metadata builder accumulates `rows` with appends
    // inside `if`s, which produce `()` and can't be builder branches.
    private func expandedTitleContent(session: ChatSession?) -> some View {
        let unified = session.flatMap { unifiedRow(for: $0) }
        return ExpandedChatTitleContent(
            metadata: expandedTitleMetadata(session: session, unified: unified),
            onPreviousUserMessage: { bridge.scrollToUserMessage(direction: "up") },
            onNextUserMessage: { bridge.scrollToUserMessage(direction: "down") },
            onScrollToBottom: { bridge.scrollToBottom() }
        )
    }

    private func expandedTitleMetadata(session: ChatSession?, unified: UnifiedSession?) -> [ExpandedChatTitleContent.MetadataRow] {
        let pickedModelId: String? = session.flatMap { sessionModelIds[$0.id] }
        let modelIdentity = ModelIdentity.resolve(modelId: pickedModelId)
            ?? unified.flatMap { ModelIdentity.resolve(modelId: $0.model) }

        var rows: [ExpandedChatTitleContent.MetadataRow] = []
        if let identity = modelIdentity {
            let providerBit = unified?.providerLabel.flatMap { $0.isEmpty ? nil : $0 }
            rows.append(.init(
                icon: "cpu",
                text: [identity.label, providerBit].compactMap { $0 }.joined(separator: " \u{00B7}")
            ))
        } else if let session, let sub = topBarSubtitle(session: session) {
            rows.append(.init(icon: "cpu", text: sub))
        }
        if let machine = unified?.machineName ?? session?.remoteMachineName, !machine.isEmpty {
            rows.append(.init(icon: "desktopcomputer", text: machine))
        }
        let projectPathName = unified?.projectPath.map { URL(fileURLWithPath: $0).lastPathComponent }
        if let project = unified?.projectName ?? projectPathName, !project.isEmpty {
            let branch = unified?.gitBranch.flatMap { $0.isEmpty ? nil : $0 }
            rows.append(.init(
                icon: "folder",
                text: [project, branch].compactMap { $0 }.joined(separator: " \u{00B7}")
            ))
        }
        if let unified {
            var activityBits: [String] = []
            if let count = unified.messageCount { activityBits.append("\(count) messages") }
            activityBits.append("active \(RelativeTimeText.string(for: unified.lastUsed, relativeTo: Date()))")
            rows.append(.init(icon: "clock", text: activityBits.joined(separator: " \u{00B7}")))
        }
        if let tags = unified?.tags, !tags.isEmpty {
            rows.append(.init(icon: "tag", text: tags.joined(separator: " \u{00B7}")))
        }
        return rows
    }

    /// Leading button — morphs between chevron.left and line.3.horizontal.
    /// Hidden on regular width: the session list is a pinned sidebar there, so
    /// navigating "back" to it (the burger) is redundant. Also hidden in list
    /// mode when the host has no sidebar to open.
    private func agentLeading(session: ChatSession?) -> (() -> AnyView)? {
        guard horizontalSizeClass != .regular,
              !showingSessionList.wrappedValue || slots.showingSidebar != nil
        else { return nil }
        let inList = showingSessionList.wrappedValue
        let action = unifiedLeadingAction(session: session)
        return {
            AnyView(
                Button(action: action) {
                    // Cross-fade burger<->chevron with plain opacity. This is the
                    // whole reason the leading slot is overridden instead of using
                    // the bar's default symbol-replace: contentTransition runs on
                    // its own timeline and would not lock to the slide, whereas
                    // opacity is a plain animatable property governed by the bar's
                    // .animation(value: showingSessionList) — so it travels on the
                    // exact same timeline as the panel.
                    ZStack {
                        Image(systemName: "line.3.horizontal").opacity(inList ? 1 : 0)
                        Image(systemName: "chevron.left").opacity(inList ? 0 : 1)
                    }
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .modifier(GlassCircleModifier(glassStyle: "regular"))
                }
                .uiKitIdentifier("AgentScreen.topBar.leadingButton")
            )
        }
    }

    /// Host chrome (e.g. WAC's minimize button). It sits OUTBOARD of the
    /// screen's own ellipsis — hence `trailingOuter`, not `trailingAccessory`.
    private var agentHostAccessory: (() -> AnyView)? {
        guard let accessory = slots.topBarTrailingAccessory else { return nil }
        return { AnyView(accessory().transition(.scale.combined(with: .opacity))) }
    }

    /// Split out of the bar expression: with all three branches inline the type
    /// checker gives up ("unable to type-check in reasonable time") on iOS.
    @ViewBuilder
    private func agentMenuContent(session: ChatSession?) -> some View {
        if showingMetadata {
            metadataMenuItems
        } else if showingSessionList.wrappedValue {
            sessionListMenuItems
        } else {
            if let info = commitViewInfo, session?.id == info.tabId {
                Button {
                    resumeCommitSession(info)
                } label: {
                    Label("Resume Session", systemImage: "play.fill")
                }
                .uiKitIdentifier("AgentScreen.contextMenu.resumeButton")
            }
            agentMenuItems(session: session)
        }
    }

    @ViewBuilder
    private var metadataMenuItems: some View {
        Button {
            NotificationCenter.default.post(name: .ripulShowDevTools, object: nil)
        } label: {
            Label("Console Logs", systemImage: "doc.text.magnifyingglass")
        }
        .uiKitIdentifier("AgentScreen.metadataMenu.consoleLogsButton")
    }

    // MARK: - Unified Bar Properties

    private func unifiedLeadingAction(session: ChatSession?) -> () -> Void {
        if showingMetadata {
            return { showingMetadata = false }
        }
        if let info = commitViewInfo, session?.id == info.tabId {
            return { dismissCommitView() }
        }
        if showingSessionList.wrappedValue {
            return {
                if let showingSidebar = slots.showingSidebar {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { showingSidebar.wrappedValue = true }
                }
            }
        } else {
            return {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    showingSessionList.wrappedValue = true
                }
            }
        }
    }

    /// Contents of the top-bar pill. Kept as its own function rather than
    /// inlined in `agentTopBarContent`: with both branches inline the type
    /// checker gives up on the enclosing expression ("unable to type-check in
    /// reasonable time") when building for iOS. Not `@ViewBuilder` — the body
    /// binds `expanded` before returning a single container.
    private func titleLozengeContent(session: ChatSession?) -> some View {
        Group {
            if expandedTitleAvailable {
                // In a chat the morphing pill does NOT live in this slot at
                // all — it is `chatTitleMorphOverlay`, a sibling of the bar in
                // `topBarOverlay`. Six attempts at running the Liquid Glass
                // morph through the bar's slot indirection snapped; the
                // overlay gives the morph the address pill's flat topology
                // with no component boundary above it. This placeholder only
                // reserves the bar's compact height so the edge buttons and
                // the switcher-pull surface keep their geometry.
                Color.clear.frame(height: 44)
            } else {
                // List / metadata / commit / file viewer: the lozenge names a
                // screen, there is nothing to expand, and the bar supplies the
                // pill as it does for every other screen.
                lozengeHeader(session: session, expanded: false)
            }
        }
    }

    /// The chat title pill and its expanded panel, mounted BESIDE the bar in
    /// `topBarOverlay` rather than inside the bar's centre slot.
    ///
    /// This is a SINGLE-SHAPE morph — Glass Lab experiment #4's technique,
    /// and the only morphing technique the Lab proved works for this case on
    /// this device. One persistent view carries the glass; its padding,
    /// width, corner radius and disclosed content animate INSIDE it under
    /// `withAnimation`, and the glass re-renders crisply at each frame.
    ///
    /// Do NOT rewrite this as two branches handing off a shared
    /// `glassEffectID` (the BrowserScreen recipe, tried seven times): the Lab
    /// showed a same-id swap between two views does not morph here in either
    /// animation driver — it snaps. Experiments #1/#5 (grow-out, merge) work,
    /// so containers and ids are fine for OTHER shapes of morph; the
    /// pill-to-panel handoff specifically is not one of them.
    @ViewBuilder
    private var chatTitleMorphOverlay: some View {
        if expandedTitleAvailable {
            let session = bridge.sessions.first(where: { $0.id == bridge.activeSessionId })
            let expanded = chatTitleLozengeExpanded
            VStack(alignment: .leading, spacing: expanded ? 9 : 0) {
                lozengeHeader(session: session, expanded: expanded)
                if expanded {
                    // No .transition: the reveal is the panel's height growth
                    // alone. A transition would translate/fade the block while
                    // the frame is also animating and the two fight.
                    expandedTitleContent(session: session)
                }
            }
            .padding(.horizontal, expanded ? 14 : 12)
            .padding(.vertical, expanded ? 10 : 0)
            .frame(minHeight: 44)
            // Pinned to the full width the bar allows when expanded, so the
            // panel does not resize itself as its own metadata changes — a
            // running tool call rewrites that text constantly. Collapsed hugs
            // its content and the overlay's ZStack centres it, matching the
            // bar pill it replaces.
            .frame(maxWidth: expanded ? .infinity : nil, alignment: .leading)
            // 22 circular at the compact 44pt height IS a capsule, so the
            // contracted pill is geometrically unchanged; 16 continuous is
            // the app-wide panel radius. One shape type either way keeps the
            // radius interpolating instead of cutting.
            .contentShape(.rect(cornerRadius: expanded ? 16 : 22))
            .glassEffect(.regular, in: .rect(cornerRadius: expanded ? 16 : 22))
            // Driven by withAnimation inside toggleTitleLozenge — no
            // .animation(value:) here.
            // Single tap ONLY — no double-tap on this view. A double-tap
            // recognizer makes the single tap wait out the double-tap window
            // (~300ms) before firing, which read as the morph lagging the
            // finger. The element debugger the double-tap used to open is
            // still reachable via long-press -> dev tools. Buttons inside the
            // expanded panel win over the tap.
            .onTapGesture(count: 1) { toggleTitleLozenge() }
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 1.0).onEnded { _ in
                    NotificationCenter.default.post(name: .ripulShowDevTools, object: nil)
                }
            )
            .uiKitIdentifier("RipulAgentScreen.chatTitleMorphLozenge")
        }
    }


    /// The lozenge's identity line, shared by both states so the chat is named
    /// the same way whether the pill is a capsule or a panel.
    @ViewBuilder
    private func lozengeHeader(session: ChatSession?, expanded: Bool) -> some View {
        if let unified = unifiedRow(for: session) {
            // Same component as the session list, compact presentation. The
            // header used to derive its own model from the picker cache, which
            // falls back to the provider's DEFAULT when the user has never
            // picked — so it named a model the session wasn't running, and
            // disagreed with the list row for the same session. One component,
            // one derivation.
            let pickedModelId: String? = session.flatMap { sessionModelIds[$0.id] }
            let icon: String? = unified.machineName.flatMap { machineIcons[$0] }
            UnifiedSessionRow(
                sessionStore: bridge.sessionList,
                session: unified,
                presentation: .lozenge,
                modelIdOverride: pickedModelId,
                machineIcon: icon,
                titleLineLimit: expanded ? 2 : 1
            )
            .frame(maxWidth: expanded ? .infinity : nil, alignment: .leading)
        } else {
            VStack(spacing: 1) {
                HStack(spacing: 4) {
                    Text(unifiedTitle(session: session))
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .contentTransition(.interpolate)
                    if showingSessionList.wrappedValue, let screenTip = slots.screenTip {
                        screenTip("agent")
                    }
                }
                if let sub = unifiedSubtitle(session: session) {
                    Text(sub)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .contentTransition(.interpolate)
                }
            }
        }
    }

    /// The session-list row for the chat currently on screen.
    ///
    /// nil in the list / metadata / commit / file-viewer states — the bar names
    /// the screen there, not a session — and for a brand-new chat that hasn't
    /// reached the list yet. All of those fall back to the plain title pair.
    private func unifiedRow(for session: ChatSession?) -> UnifiedSession? {
        guard !showingSessionList.wrappedValue,
              !showingMetadata,
              bridge.fileViewerTitle == nil,
              let session else { return nil }
        if let info = commitViewInfo, session.id == info.tabId { return nil }
        return model.unifiedSessions.first { $0.represents(session) }
    }

    private func unifiedTitle(session: ChatSession?) -> String {
        if showingMetadata { return "Session Info" }
        if let info = commitViewInfo, session?.id == info.tabId {
            return info.sessionTitle
        }
        return showingSessionList.wrappedValue ? "Agents" : (session?.displayName ?? "New Chat")
    }

    private func unifiedSubtitle(session: ChatSession?) -> String? {
        if showingMetadata { return session?.displayName }
        if let info = commitViewInfo, session?.id == info.tabId {
            return info.shortSha
        }
        return showingSessionList.wrappedValue ? nil : topBarSubtitle(session: session)
    }

    @ViewBuilder
    private func fileViewerTopBar(title: String) -> some View {
        GlassTopBar(
            title: title,
            subtitle: "Viewing File",
            onBack: { bridge.requestFileViewerClose() }
        ) {
            let isFav = bridge.fileViewerFilePath.map { favoriteFiles.contains($0) } ?? false
            Button {
                if let path = bridge.fileViewerFilePath {
                    toggleFavorite(path: path)
                }
            } label: {
                Label(isFav ? "Unfavourite" : "Favourite", systemImage: isFav ? "star.fill" : "star")
            }
            .uiKitIdentifier("AgentScreen.fileViewer.menu.favouriteButton")

            if let onNavigateToFiles = slots.onNavigateToFiles {
                Button {
                    onNavigateToFiles()
                } label: {
                    Label("Saved Files", systemImage: "folder.fill")
                }
                .uiKitIdentifier("AgentScreen.fileViewer.menu.savedFilesButton")
            }

            Section {
                ControlGroup {
                    // Drive the isolated StandaloneFileViewer (its OWN web view) via the
                    // same NotificationCenter events the Files tab posts — NOT the main
                    // chat bridge, which no longer hosts the viewer.
                    Button { NotificationCenter.default.post(name: .ripulFileViewerZoomOut, object: nil) } label: {
                        Label("Zoom Out", systemImage: "minus.magnifyingglass")
                    }
                    .uiKitIdentifier("AgentScreen.fileViewer.menu.zoomOutButton")
                    Button { NotificationCenter.default.post(name: .ripulFileViewerZoomReset, object: nil) } label: {
                        Label("Reset", systemImage: "1.magnifyingglass")
                    }
                    .uiKitIdentifier("AgentScreen.fileViewer.menu.zoomResetButton")
                    Button { NotificationCenter.default.post(name: .ripulFileViewerZoomIn, object: nil) } label: {
                        Label("Zoom In", systemImage: "plus.magnifyingglass")
                    }
                    .uiKitIdentifier("AgentScreen.fileViewer.menu.zoomInButton")
                }
            }
            .menuActionDismissBehavior(.disabled)

            Divider()
            Button { NotificationCenter.default.post(name: .ripulFileViewerToggleWordWrap, object: nil) } label: {
                Label("Toggle Word Wrap", systemImage: "text.word.spacing")
            }
            .uiKitIdentifier("AgentScreen.fileViewer.menu.wordWrapButton")

            if bridge.fileViewerIsMarkdown {
                Divider()
                Button { NotificationCenter.default.post(name: .ripulFileViewerToggleRaw, object: nil) } label: {
                    Label("Toggle Raw", systemImage: "doc.plaintext")
                }
                .uiKitIdentifier("AgentScreen.fileViewer.menu.toggleRawButton")
            }
        }
    }

    private func topBarSubtitle(session: ChatSession?) -> String? {
        guard let session else { return nil }
        if rawModeSessions.contains(session.id) || ProviderConstants.isCliProvider(session.provider) {
            let provider = sessionProviders[session.id] ?? session.providerLabel ?? ProviderConstants.legacyLabel(for: session.provider ?? ProviderConstants.defaultCliProvider.providerKey ?? "claude-cli")
            let rawModels = rawModelsForSession(session)
            let currentModelId = currentRawModelId(for: session)
            let modelName = rawModels.first(where: { $0.id == currentModelId })?.name ?? ""
            return formatLozengeModel(name: modelName, provider: provider)
        }
        return session.remoteMachineName
    }

    // MARK: - Menu Items

    /// Extracted to the public SessionListMenu so the first-party shell's
    /// root bar can offer the same actions — one menu, two chromes.
    @ViewBuilder
    private var sessionListMenuItems: some View {
        SessionListMenu(
            bridge: bridge,
            model: model,
            cache: cache,
            showingSessionList: showingSessionList,
            onShowModelPicker: { modelPickerTarget = .newSession }
        )
    }

    /// Every state input the CURRENT mode's menu renders, flattened. This keys
    /// the menu host's `.equatable()` gate (see GlassTopBar.menuKey): while
    /// the key is unchanged, screen-body re-runs — which happen on every
    /// bridge publish during streaming — cannot re-resolve the menu, and an
    /// OPEN menu therefore stops flashing. The mode prefix guarantees a
    /// re-resolve when `agentMenuContent` switches branches. MAINTENANCE: a
    /// new state-dependent menu item must add its inputs here, or it renders
    /// stale until an existing input changes.
    private func agentMenuKey(session: ChatSession?) -> String {
        if showingMetadata { return "meta" }
        if showingSessionList.wrappedValue {
            // SessionListMenu renders from the machines roster (default-machine
            // entries) and deliberately does not observe it — this key is what
            // refreshes it.
            let defaultMachineId = (cache.object(forKey: "ripulDefaultMachineId") as? String) ?? ""
            let machines = model.machines
                .map { "\($0.machineId):\($0.isOnline ? "1" : "0"):\($0.displayName)" }
                .joined(separator: ",")
            return "list|\(defaultMachineId)|\(machines)"
        }
        var parts: [String] = [
            "chat",
            session?.id ?? "-",
            session?.provider ?? "-",
            session?.remoteMachineName == nil ? "local" : "remote",
            (commitViewInfo != nil && session?.id == commitViewInfo?.tabId) ? "commit" : "-",
            showNativeChatScroller ? "native" : "web",
            bridge.navigationStore.showThinkingMode,
            session.map { rawModeSessions.contains($0.id) ? "raw" : "std" } ?? "-",
            favoriteDirectories.joined(separator: ","),
            sessionWorkingDirectory ?? "-",
            hostWorkingDirectory ?? "-",
            slots.onInviteByEmail != nil ? "invite" : "-",
            cache.bool(forKey: "showElementDebuggerMenu") ? (elementDebuggerActive ? "dbg1" : "dbg0") : "-",
            cache.bool(forKey: "enableNoteInjection") ? "notes" : "-",
            bridge.selectedEffort ?? "-",
        ]
        if let session, rawModeSessions.contains(session.id) || ProviderConstants.isCliProvider(session.provider) {
            let rawModels = rawModelsForSession(session)
            let currentModelId = currentRawModelId(for: session)
            parts.append(rawModels.first(where: { $0.id == currentModelId }).map { shortModelName($0.name) } ?? "Default")
        } else {
            parts.append(selectedModelName)
        }
        return parts.joined(separator: "|")
    }

    @ViewBuilder
    private func agentMenuItems(session: ChatSession?) -> some View {
        Button {
            Task {
                bridge.logSessionStartMarker("ios.tap", extra: "source=AgentScreen.menu.newChat")
                _ = await bridge.createNewChat()
            }
        } label: {
            Label("New Chat", systemImage: "plus.message")
        }
        .uiKitIdentifier("AgentScreen.contextMenu.newChatButton")

        // Was a nested menu over the hardcoded "Anthropic API" group; now the
        // shared picker, so every catalog model can start a session and each one
        // says who pays for it.
        Button {
            modelPickerTarget = .newSession
        } label: {
            Label("New session from model…", systemImage: "square.stack.3d.up")
        }
        .uiKitIdentifier("AgentScreen.contextMenu.newFromModelButton")

        Toggle(isOn: Binding(
            get: { showNativeChatScroller },
            set: { newValue in
                showNativeChatScroller = newValue
                cache.set(newValue, forKey: "showNativeChatScroller")
            }
        )) {
            Label("Native Chat (beta)", systemImage: "swift")
        }
        .uiKitIdentifier("AgentScreen.contextMenu.nativeChatToggle")

        if let session {
            Button {
                renameText = ""
                renamingSession = session
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .uiKitIdentifier("AgentScreen.contextMenu.renameButton")

            Button {
                Task { await shareSession(session) }
            } label: {
                Label("Share Link", systemImage: "square.and.arrow.up")
            }
            .uiKitIdentifier("AgentScreen.contextMenu.shareLinkButton")

            if slots.onInviteByEmail != nil {
                Button {
                    Task { await showInviteByEmail(session) }
                } label: {
                    Label("Invite by Email", systemImage: "person.badge.plus")
                }
                .uiKitIdentifier("AgentScreen.contextMenu.inviteByEmailButton")
            }

            if session.remoteMachineName != nil {
                Button {
                    Task { await forkSession(session) }
                } label: {
                    Label("Fork Conversation", systemImage: "arrow.triangle.branch")
                }
                .uiKitIdentifier("AgentScreen.contextMenu.forkButton")
            }
        }

        Button {
            bridge.clearCacheAndReload()
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        .uiKitIdentifier("AgentScreen.contextMenu.refreshButton")

        Button {
            NotificationCenter.default.post(name: .ripulShowDevTools, object: nil)
        } label: {
            Label("Console Logs", systemImage: "doc.text.magnifyingglass")
        }
        .uiKitIdentifier("AgentScreen.contextMenu.consoleLogsButton")

        Picker(selection: Binding(
            get: { bridge.navigationStore.showThinkingMode },
            set: { mode in Task { await bridge.setShowThinking(mode) } }
        ), label: Label("Thinking", systemImage: "brain.head.profile")) {
            Text("None").tag("none")
            Text("Folded").tag("folded")
            Text("Open").tag("open")
        }
        .pickerStyle(.palette)
        .uiKitIdentifier("AgentScreen.contextMenu.thinkingPicker")

        if let session, session.remoteMachineName != nil {
            if !rawModeSessions.contains(session.id) {
                Button {
                    enableRawMode(session: session)
                } label: {
                    Label("Enable \(ProviderConstants.defaultCliProvider.label)", systemImage: "terminal")
                }
                .uiKitIdentifier("AgentScreen.contextMenu.enableClaudeButton")
            }

            Menu {
                Button {
                    Task {
                        let success = await bridge.setWorkingDirectory(sessionId: session.id, directory: nil)
                        if success {
                            sessionWorkingDirectory = nil
                        } else {
                            bridge.logToWebConsole("[AgentScreen] Failed to reset working directory for \(session.id)")
                        }
                    }
                } label: {
                    HStack {
                        Text("Default")
                        if sessionWorkingDirectory == nil, hostWorkingDirectory == nil {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }

                ForEach(favoriteDirectories, id: \.self) { dir in
                    Button {
                        Task {
                            let success = await bridge.setWorkingDirectory(sessionId: session.id, directory: dir)
                            if success {
                                sessionWorkingDirectory = dir
                            } else {
                                bridge.logToWebConsole("[AgentScreen] Failed to set working directory to \(dir) for \(session.id)")
                            }
                        }
                    } label: {
                        HStack {
                            Text(dir)
                            if sessionWorkingDirectory == dir || (sessionWorkingDirectory == nil && hostWorkingDirectory == dir) {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Label("Working Directory", systemImage: "folder.badge.gearshape")
            }
            .uiKitIdentifier("AgentScreen.contextMenu.workingDirectoryMenu")
        }

        if cache.bool(forKey: "showElementDebuggerMenu") {
            Button {
                let next = !elementDebuggerActive
                elementDebuggerActive = next
                cache.set(next, forKey: "elementDebuggerActive")
                bridge.evaluateJavaScript(
                    "window.__ripulUpdateUserSettings?.((s) => ({ ...s, enableElementDebugger: \(next) }))"
                )
            } label: {
                Label(elementDebuggerActive ? "Disable Debugger" : "Enable Debugger", systemImage: elementDebuggerActive ? "hand.tap.fill" : "hand.tap")
            }
            .uiKitIdentifier("AgentScreen.contextMenu.elementDebuggerToggle")
        }

        if cache.bool(forKey: "enableNoteInjection") {
            Button {
                bridge.evaluateJavaScript("window.__ripulOpenNoteInjectionDialog?.()")
            } label: {
                Label("Insert User Notes...", systemImage: "note.text.badge.plus")
            }
            .uiKitIdentifier("AgentScreen.contextMenu.insertNotesButton")
        }

        Divider()

        // Both branches open the SAME picker — sections, pins, search, billing
        // subtitles — differing only in which models it lists. They used to be
        // two nested `Menu` trees, which meant the chat's model change was the
        // one place in the app you couldn't see what a model would cost or pin
        // the one you keep coming back to.
        if let session, rawModeSessions.contains(session.id) || ProviderConstants.isCliProvider(session.provider) {
            let rawModels = rawModelsForSession(session)
            let currentModelId = currentRawModelId(for: session)
            let currentModelName = rawModels.first(where: { $0.id == currentModelId }).map { shortModelName($0.name) } ?? "Default"
            Button {
                modelPickerTarget = .raw(sessionId: session.id)
            } label: {
                Label(currentModelName, systemImage: "cpu")
            }
            .uiKitIdentifier("AgentScreen.contextMenu.rawModelMenu")
        } else {
            Button {
                modelPickerTarget = .global
            } label: {
                Label(selectedModelName, systemImage: "cpu")
            }
            .uiKitIdentifier("AgentScreen.contextMenu.modelMenu")
        }

        // Reasoning effort (orthogonal to the model) — CLI sessions.
        if let session, rawModeSessions.contains(session.id) || ProviderConstants.isCliProvider(session.provider) {
            Menu {
                Button { Task { await bridge.setEffort(nil) } } label: {
                    HStack {
                        Text("Default")
                        if bridge.selectedEffort == nil { Image(systemName: "checkmark") }
                    }
                }
                ForEach(["low", "medium", "high", "xhigh", "max"], id: \.self) { level in
                    Button { Task { await bridge.setEffort(level) } } label: {
                        HStack {
                            Text(level == "xhigh" ? "XHigh" : level.capitalized)
                            if bridge.selectedEffort == level { Image(systemName: "checkmark") }
                            }
                    }
                }
            } label: {
                Label(
                    bridge.selectedEffort.map { "Effort · \($0 == "xhigh" ? "XHigh" : $0.capitalized)" } ?? "Effort",
                    systemImage: "gauge.with.dots.needle.33percent"
                )
            }
            .uiKitIdentifier("AgentScreen.contextMenu.effortMenu")
        }

        if let session {
            Divider()

            Button {
                Task { await truncateSession(session) }
            } label: {
                Label("Truncate", systemImage: "scissors")
            }
            .uiKitIdentifier("AgentScreen.contextMenu.truncateButton")

            Button(role: .destructive) {
                Task { await bridge.closeSession(id: session.id) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .uiKitIdentifier("AgentScreen.contextMenu.deleteButton")
        }
    }

    // MARK: - Actions

    private func enableRawMode(session: ChatSession) {
        rawModeSessions.insert(session.id)
        let resolvedDef = ProviderConstants.byModelId(bridge.selectedModelId) ?? ProviderConstants.defaultCliProvider
        let provider = resolvedDef.displayLabel
        let defaultModelId = resolvedDef.defaultModelId ?? ProviderConstants.defaultModelId(for: resolvedDef.providerKey ?? ProviderConstants.defaultCliProvider.providerKey ?? "claude-cli")
        sessionProviders[session.id] = provider
        sessionModelIds[session.id] = defaultModelId
        cache.set(Array(rawModeSessions), forKey: "ripulRawModeSessions")
        cache.set(sessionProviders, forKey: "ripulSessionProviders")
        cache.set(sessionModelIds, forKey: "ripulSessionModelIds")
        Task {
            let (success, errorMsg) = await bridge.setRawMode(sessionId: session.id, enabled: true)
            if !success {
                rawModeSessions.remove(session.id)
                sessionProviders.removeValue(forKey: session.id)
                sessionModelIds.removeValue(forKey: session.id)
                cache.set(Array(rawModeSessions), forKey: "ripulRawModeSessions")
                cache.set(sessionProviders, forKey: "ripulSessionProviders")
                cache.set(sessionModelIds, forKey: "ripulSessionModelIds")
                if let msg = errorMsg {
                    rawModeError = msg
                    showRawModeError = true
                }
            }
        }
    }

    private func forkSession(_ session: ChatSession) async {
        let displayName = session.displayName
        let isRaw = rawModeSessions.contains(session.id)
        let provider = sessionProviders[session.id]
        let result = await bridge.forkSession(sourceChatId: session.sourceChatId, displayName: displayName)
        if result.success {
            await bridge.fetchSessions()
            if isRaw, let newChatId = result.newChatId,
               let forkedSession = bridge.sessions.first(where: { $0.sourceChatId == newChatId }) {
                let forkProvider = provider ?? ProviderConstants.defaultCliProvider.displayLabel
                rawModeSessions.insert(forkedSession.id)
                sessionProviders[forkedSession.id] = forkProvider
                if let sourceModelId = sessionModelIds[session.id] {
                    sessionModelIds[forkedSession.id] = sourceModelId
                }
                var rawSet = Set(cache.stringArray(forKey: "ripulRawModeSessions") ?? [])
                rawSet.insert(forkedSession.id)
                cache.set(Array(rawSet), forKey: "ripulRawModeSessions")
                var providers = cache.dictionary(forKey: "ripulSessionProviders") as? [String: String] ?? [:]
                providers[forkedSession.id] = forkProvider
                cache.set(providers, forKey: "ripulSessionProviders")
                cache.set(sessionModelIds, forKey: "ripulSessionModelIds")
            }
        } else {
            forkError = result.error ?? "Fork failed"
            showForkError = true
        }
    }

    private func shareSession(_ session: ChatSession) async {
        do {
            let result = try await bridge.callAsyncJavaScript(
                "return await window.__ripulCreateShareLink?.()"
            )
            guard let urlString = result as? String,
                  let shareURL = URL(string: urlString) else {
                bridge.logToWebConsole("[Share] No share URL returned")
                return
            }
            let shareURLStr = urlString
            var activities: [UIActivity] = []
            if let onInviteByEmail = slots.onInviteByEmail {
                let inviteActivity = InviteByEmailActivity()
                inviteActivity.onPerform = { _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        onInviteByEmail(shareURLStr)
                    }
                }
                activities.append(inviteActivity)
            }
            let activityVC = UIActivityViewController(
                activityItems: [shareURL],
                applicationActivities: activities
            )
            // compactMap, not `.first as?` — with CarPlay connected a
            // CPTemplateApplicationScene can be first in connectedScenes.
            if let windowScene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first,
               let rootVC = windowScene.windows.first?.rootViewController {
                rootVC.present(activityVC, animated: true)
            }
        } catch {
            bridge.logToWebConsole("[Share] Failed to create share link: \(error.localizedDescription)")
        }
    }

    private func showInviteByEmail(_ session: ChatSession) async {
        guard let onInviteByEmail = slots.onInviteByEmail else { return }
        do {
            let result = try await bridge.callAsyncJavaScript(
                "return await window.__ripulCreateShareLink?.()"
            )
            guard let urlString = result as? String else {
                bridge.logToWebConsole("[Invite] No share URL returned")
                return
            }
            onInviteByEmail(urlString)
        } catch {
            bridge.logToWebConsole("[Invite] Failed to create share link: \(error.localizedDescription)")
        }
    }

    private func truncateSession(_ session: ChatSession) async {
        let (removed, error) = await bridge.truncateSession(chatId: session.sourceChatId, keepCount: 50)
        if let error {
            bridge.logToWebConsole("[AgentScreen] truncate error: \(error)")
        } else {
            bridge.logToWebConsole("[AgentScreen] truncated \(removed) actions from \(session.sourceChatId)")
        }
    }

    // MARK: - Resume Commit Session

    private func dismissCommitView() {
        guard let info = commitViewInfo else { return }
        bridge.unmarkSessionEphemeral(info.tabId)
        bridge.suppressNativeChatInput = false
        Task { await bridge.closeSession(id: info.tabId) }
        commitViewInfo = nil
        slots.onNavigateToCommits?()
    }

    private func resumeCommitSession(_ info: CommitViewInfo) {
        bridge.handleConsoleLog("[RESUME] resumeCommitSession START tabId=\(info.tabId.suffix(20)) title=\(info.sessionTitle) sha=\(info.shortSha) sessionId=\(info.sessionId ?? "nil")")
        bridge.handleConsoleLog("[RESUME] sessions.count=\(bridge.sessions.count) ephemeral=\(bridge.ephemeralSessionIds) activeId=\(bridge.activeSessionId ?? "nil")")
        bridge.unmarkSessionEphemeral(info.tabId)
        bridge.suppressNativeChatInput = false
        // Restore the archived session so the CLI can resume it
        if let sessionId = info.sessionId {
            Task {
                bridge.handleConsoleLog("[RESUME] restoreRemoteSession machineId=\(info.machineId) sessionId=\(sessionId)")
                let result = await bridge.restoreRemoteSession(
                    machineId: info.machineId,
                    sessionId: sessionId
                )
                bridge.handleConsoleLog("[RESUME] restoreRemoteSession result=\(String(describing: result))")
            }
        }
        // The session was ephemeral (filtered out of bridge.sessions).
        // Refresh sessions so it reappears, then rename it. Keep
        // commitViewInfo set until the rename lands so the title
        // doesn't flash "New Chat".
        Task {
            bridge.handleConsoleLog("[RESUME] fetchSessions (pre-rename) sessions.count=\(bridge.sessions.count)")
            await bridge.fetchSessions()
            bridge.handleConsoleLog("[RESUME] fetchSessions done sessions.count=\(bridge.sessions.count)")
            if let session = bridge.sessions.first(where: { $0.id == info.tabId }) {
                bridge.handleConsoleLog("[RESUME] found session, renaming: id=\(session.id.suffix(20)) sourceChatId=\(session.sourceChatId.suffix(20)) currentName=\(session.displayName)")
                bridge.renameSession(
                    id: session.id,
                    sourceChatId: session.sourceChatId,
                    displayName: "\(info.sessionTitle) · \(info.shortSha)"
                )
            } else {
                bridge.handleConsoleLog("[RESUME] WARNING: session NOT found in bridge.sessions after fetch! Looking for tabId=\(info.tabId.suffix(20))")
                let ids = bridge.sessions.map { $0.id.suffix(20) }
                bridge.handleConsoleLog("[RESUME] available session IDs: \(ids)")
            }
            commitViewInfo = nil
        }
    }

    // MARK: - Discuss File

    private func startDiscussSession(path: String, line: Int?) {
        let filename = URL(fileURLWithPath: path).lastPathComponent
        let prompt: String
        if let line {
            prompt = "Let's discuss `\(filename)` around line \(line).\n\nPath: `\(path)`"
        } else {
            prompt = "Let's discuss `\(filename)`.\n\nPath: `\(path)`"
        }
        withAnimation(.easeInOut(duration: 0.28)) {
            showingSessionList.wrappedValue = false
        }
        Task {
            guard let result = await bridge.startNewChatWithPrompt(prompt) else { return }
            let tabId = result.tabId
            await bridge.focusSession(id: tabId)

            guard result.machineId != nil else { return }
            let defaultModelId = ProviderConstants.defaultCliProvider.defaultModelId ?? ProviderConstants.defaultModelId(for: ProviderConstants.defaultCliProvider.providerKey ?? "claude-cli")
            rawModeSessions.insert(tabId)
            sessionProviders[tabId] = ProviderConstants.defaultCliProvider.displayLabel
            sessionModelIds[tabId] = defaultModelId
            cache.set(Array(rawModeSessions), forKey: "ripulRawModeSessions")
            cache.set(sessionProviders, forKey: "ripulSessionProviders")
            cache.set(sessionModelIds, forKey: "ripulSessionModelIds")
            _ = await bridge.setRawMode(sessionId: tabId, enabled: true)
            _ = await bridge.setChatModel(chatId: tabId, modelId: defaultModelId)
        }
    }

    // MARK: - Favourite Files

    private func toggleFavorite(path: String) {
        if let idx = favoriteFiles.firstIndex(of: path) {
            favoriteFiles.remove(at: idx)
        } else {
            favoriteFiles.append(path)
        }
        cache.set(favoriteFiles, forKey: "ripulFavoriteFiles")
    }

    // MARK: - Model Picker

    /// The shared picker, pointed at whichever model the menu asked about.
    ///
    /// Effort rides along in both cases: it is set globally on the bridge, so it
    /// is the same control either way, and it belongs next to the model rather
    /// than three items further down a menu.
    @ViewBuilder
    private func modelPickerSheet(for target: ModelPickerTarget) -> some View {
        let effort = ModelPickerEffort(current: bridge.selectedEffort) { level in
            Task { await bridge.setEffort(level) }
        }
        switch target {
        case .global:
            ModelPickerSheetContent(
                models: bridge.availableModels,
                cache: cache,
                selectedId: bridge.selectedModelId,
                showsDefaultRow: true,
                effort: effort,
                identifierPrefix: "AgentScreen.modelPicker",
                isLoading: bridge.availableModels.isEmpty,
                loadFailure: bridge.lastModelsError,
                onRetry: { Task { await bridge.fetchModels() } },
                onPick: { picked in
                    bridge.handleConsoleLog("LOG: [MODELSW] native.contextMenu.tap surface=AgentScreen.globalModelMenu from=\(bridge.selectedModelId ?? "default") to=\(picked?.id ?? "default")")
                    Task { await bridge.setModel(picked?.id) }
                    modelPickerTarget = nil
                },
                onDismiss: { modelPickerTarget = nil }
            )
            .task { if bridge.availableModels.isEmpty { await bridge.fetchModels() } }

        case .newSession:
            NewSessionModelPicker(
                bridge: bridge,
                model: model,
                cache: cache,
                showingSessionList: showingSessionList,
                onDismiss: { modelPickerTarget = nil }
            )

        case .raw(let sessionId):
            if let session = bridge.sessions.first(where: { $0.id == sessionId }) {
                ModelPickerSheetContent(
                    models: rawModelsForSession(session),
                    // Only this harness's models are listed, but the pin list is
                    // global — seed it from the whole catalog or pinning here
                    // would wipe every other harness's shortcut.
                    pinCatalog: bridge.availableModels,
                    cache: cache,
                    selectedId: currentRawModelId(for: session),
                    effort: effort,
                    identifierPrefix: "AgentScreen.rawModelPicker",
                    onPick: { picked in
                        guard let picked else { return }
                        pickRawModel(picked, for: session)
                        modelPickerTarget = nil
                    },
                    onDismiss: { modelPickerTarget = nil }
                )
            }
        }
    }

    private func pickRawModel(_ picked: ModelInfo, for session: ChatSession) {
        let from = currentRawModelId(for: session)
        bridge.handleConsoleLog("LOG: [MODELSW] native.contextMenu.tap surface=AgentScreen.rawModelMenu sessionId=\(session.id.suffix(12)) sourceChatId=\(session.sourceChatId.suffix(12)) from=\(from) to=\(picked.id)")
        sessionModelIds[session.id] = picked.id
        cache.set(sessionModelIds, forKey: "ripulSessionModelIds")
        // The top bar picks this up from state immediately; the list rows read
        // the same pick from the cache on the next rebuild, so nudge one now
        // rather than leaving them naming the previous model until the next scan.
        model.refreshPickedModelSelections()
        Task { await bridge.setChatModel(chatId: session.sourceChatId, modelId: picked.id) }
    }

    // MARK: - Model Helpers

    private var selectedModelName: String {
        if let selectedId = bridge.selectedModelId,
           let model = bridge.availableModels.first(where: { $0.id == selectedId }) {
            return model.name
        }
        return "Default"
    }

    private func rawModelsForSession(_ session: ChatSession) -> [ModelInfo] {
        let providerLabel = sessionProviders[session.id]
            ?? session.providerLabel
            ?? ProviderConstants.legacyLabel(for: session.provider ?? ProviderConstants.defaultCliProvider.providerKey ?? "claude-cli")
        // Resolve definition from the label
        let def = ProviderConstants.resolve(provider: session.provider, providerLabel: providerLabel)
        let prefix = def?.modelIdPrefix ?? ProviderConstants.defaultCliProvider.modelIdPrefix ?? "cli-raw-"
        if def?.providerKey == ProviderConstants.codex.providerKey,
           let machineId = codexModelMachineId(for: session),
           let discovered = codexModelsByMachineId[machineId],
           !discovered.isEmpty {
            return discovered
        }
        return bridge.availableModels.filter { $0.id.hasPrefix(prefix) }
    }

    private func shortModelName(_ name: String) -> String {
        for p in ProviderConstants.cliProviders {
            let prefix = "\(p.displayLabel) ("
            if name.hasPrefix(prefix) && name.hasSuffix(")") {
                return String(name.dropFirst(prefix.count).dropLast())
            }
        }
        return name
    }

    private func currentRawModelId(for session: ChatSession) -> String {
        if let stored = sessionModelIds[session.id] { return stored }
        let def = ProviderConstants.resolve(provider: session.provider, providerLabel: sessionProviders[session.id] ?? session.providerLabel)
        return def?.defaultModelId ?? ProviderConstants.defaultModelId(for: session.provider ?? ProviderConstants.defaultCliProvider.providerKey ?? "claude-cli")
    }

    private func codexModelMachineId(for session: ChatSession) -> String? {
        guard let machineName = session.remoteMachineName else { return nil }
        return model.machines.first {
            $0.machineId == machineName || $0.displayName == machineName
        }?.machineId
    }

    private func refreshCodexModelsIfNeeded(for session: ChatSession) async {
        // Allow discovery for sessions already in raw mode OR sessions whose
        // provider is Codex (e.g. opened via connectWithProvider before the
        // user has toggled raw mode on).
        let isCodexSession = session.provider == ProviderConstants.codex.providerKey
        guard rawModeSessions.contains(session.id) || isCodexSession else { return }
        let provider = sessionProviders[session.id] ?? session.providerLabel ?? ""
        guard provider == ProviderConstants.codex.displayLabel || isCodexSession else { return }
        guard let machineId = codexModelMachineId(for: session) else { return }
        guard codexModelsByMachineId[machineId] == nil, !codexModelLoadsInFlight.contains(machineId) else { return }

        codexModelLoadsInFlight.insert(machineId)
        let models = await bridge.discoverCodexModels(machineId: machineId)
        if !models.isEmpty {
            codexModelsByMachineId[machineId] = models
        }
        codexModelLoadsInFlight.remove(machineId)
    }

    /// Refresh the host's favourite working directories (Working Directory
    /// submenu). The fetch round-trips the relay to the host's CLI server and
    /// can fail while that chain boots; an empty result is indistinguishable
    /// from "host has no favourites", so empty keeps the last-known-good list
    /// (persisted to the cache) instead of blanking the menu — macOS reads
    /// its local workspace directly and never has this failure mode.
    private func refreshFavoriteDirectories() async {
        let result = await bridge.getFavoriteDirectories()
        let dirs = result.directories
        let current = result.current

        if dirs.isEmpty {
            bridge.logToWebConsole("[AgentScreen] refreshFavoriteDirectories: empty result (relay/host unreachable or no favourites) — keeping \(favoriteDirectories.count) cached")
        } else {
            if dirs != favoriteDirectories {
                favoriteDirectories = dirs
            }
            cache.set(dirs, forKey: "ripulFavoriteDirectories")
        }

        if let current, current != hostWorkingDirectory {
            hostWorkingDirectory = current
        }
    }

    private func formatLozengeModel(name: String, provider: String) -> String {
        let short = shortModelName(name)
        let parts = short.split(separator: "·", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
        let def = ProviderConstants.resolve(provider: nil, providerLabel: provider)
        let prefix = def?.label ?? "CLI"
        return prefix + " • " + parts.joined(separator: " • ")
    }

    // MARK: - Safe Area Glass

    /// Extracted to the public TopSafeAreaGlass so the shell's root bar draws
    /// the same strip.
    private var safeAreaGlass: some View {
        TopSafeAreaGlass()
    }
}

// MARK: - Agent Chat Drag Container

/// Isolates the interactive chat -> session-list drag from RipulAgentScreen's large
/// body. During finger tracking, only this small wrapper updates its offset state
/// while the heavy AgentView stays stable.
private struct AgentChatDragContainer<SessionList: View, Chat: View>: View {
    @Binding var showingSessionList: Bool
    let showingMetadata: Bool
    /// Mirror active — the left-edge back-swipe stands down (see
    /// mirrorOwnsWebview). Passed as a plain value because this container
    /// does not observe the bridge (by design — see the init comment).
    let suppressEdgeSwipe: Bool
    let bridge: AgentBridge
    let isFileViewerOpen: Bool
    let hasCommitView: Bool
    let onCommitViewDismiss: () -> Void
    let onFileViewerSwipeCommit: () -> Void
    // Stored view VALUES, resolved once in init — NOT closures re-invoked in body.
    // This is the whole point: during finger tracking, the container's @State
    // changes (dragOffset/gestureActive) must not re-run the session-list or chat
    // bodies. They stay stable values and only the SlideEffect offset changes, so
    // the drag is a pure layer transform.
    let sessionList: SessionList
    let chat: Chat

    @State private var dragOffset: CGFloat = 0
    @State private var gestureActive = false
    // True for the brief window a gesture is springing back to rest, so that
    // settle uses the spring rather than the pick-a-session brake.
    @State private var gestureSettling = false

    private var screenWidth: CGFloat { UIScreen.main.bounds.width }

    /// While dragging, track the finger directly. Otherwise derive from
    /// showingSessionList so programmatic shows/hides animate in the same frame
    /// (no onChange/settledOffset round-trip).
    private var effectiveOffset: CGFloat {
        gestureActive ? dragOffset : (showingSessionList ? screenWidth : 0)
    }

    /// Which animation drives the slide. Finger-down = none (1:1 tracking).
    /// Picking a session (programmatic list -> chat open) brakes into position.
    /// Gesture settles and closing back to the list use the standard spring, so
    /// the manual swipe-back is unchanged.
    private var slideAnimation: Animation? {
        if gestureActive { return nil }
        if gestureSettling || showingSessionList { return chatSlideSpring }
        return chatOpenAnimation
    }

    init(
        showingSessionList: Binding<Bool>,
        showingMetadata: Bool,
        suppressEdgeSwipe: Bool = false,
        bridge: AgentBridge,
        isFileViewerOpen: Bool,
        hasCommitView: Bool,
        onCommitViewDismiss: @escaping () -> Void,
        onFileViewerSwipeCommit: @escaping () -> Void,
        @ViewBuilder sessionList: () -> SessionList,
        @ViewBuilder chat: () -> Chat
    ) {
        self._showingSessionList = showingSessionList
        self.showingMetadata = showingMetadata
        self.suppressEdgeSwipe = suppressEdgeSwipe
        self.bridge = bridge
        self.isFileViewerOpen = isFileViewerOpen
        self.hasCommitView = hasCommitView
        self.onCommitViewDismiss = onCommitViewDismiss
        self.onFileViewerSwipeCommit = onFileViewerSwipeCommit
        self.sessionList = sessionList()
        self.chat = chat()
    }

    var body: some View {
        ZStack {
            sessionList
                .allowsHitTesting(showingSessionList)

            chat
                .overlay(alignment: .leading) {
                    if !showingSessionList && !showingMetadata && !suppressEdgeSwipe {
                        InteractiveEdgeSwipeView(
                            onChanged: handleChanged,
                            onEnded: { offset, velocity in
                                handleEnded(offset: offset, velocity: velocity)
                            },
                            onCancelled: handleCancelled
                        )
                        .frame(width: 20)
                        .ignoresSafeArea()
                    }
                }
                .modifier(SlideEffect(offset: effectiveOffset))
                .allowsHitTesting(!showingSessionList && !showingMetadata)
        }
        .animation(slideAnimation, value: effectiveOffset)
        .onChange(of: showingSessionList) { _ in
            // Any list<->chat transition clears the gesture-settle flag. This
            // replaces a 600ms timer that could fire mid-slide (flipping the flag
            // and restarting the animation -> snap). Clearing it here means a
            // re-entry tap always finds gestureSettling=false, so its brake
            // matches the container and the slide never snaps.
            gestureSettling = false
        }
    }

    /// Mark a gesture's spring-back-to-rest so `slideAnimation` uses the spring
    /// (not the pick-a-session brake) for a settle. Cleared on the next
    /// list<->chat transition (see onChange above), so it can't race a timer.
    private func beginGestureSettle() {
        gestureSettling = true
    }

    private func handleChanged(_ offset: CGFloat) {
        guard !isFileViewerOpen else { return }
        bridge.beginDrag()
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            gestureActive = true
            dragOffset = offset
        }
    }

    private func handleEnded(offset: CGFloat, velocity: CGFloat) {
        beginGestureSettle()
        if isFileViewerOpen {
            bridge.endDrag()
            withAnimation(chatSlideSpring) { gestureActive = false }
            if offset > 40 { onFileViewerSwipeCommit() }
            return
        }

        let shouldCommit = offset > screenWidth * 0.35 || velocity > 400
        if shouldCommit {
            if hasCommitView {
                bridge.endDrag(delay: 0.35)
                withAnimation(chatSlideSpring) {
                    gestureActive = false
                }
                onCommitViewDismiss()
            } else {
                bridge.endDrag(delay: 0.5)
                withAnimation(chatSlideSpring) {
                    gestureActive = false
                    showingSessionList = true
                }
            }
        } else {
            bridge.endDrag(delay: 0.22)
            withAnimation(chatSlideSpring) {
                gestureActive = false
            }
        }
    }

    private func handleCancelled() {
        beginGestureSettle()
        bridge.endDrag(delay: 0.18)
        withAnimation(chatSlideSpring) {
            gestureActive = false
        }
    }
}

// MARK: - Commit View Banner

/// Bottom banner shown when viewing a read-only committed session.
/// Replaces the chat input area with a clear indicator and a resume button.
private struct CommitViewBanner: View {
    let shortSha: String
    let onResume: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "eye")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text("Read Only")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("Viewing commit \(shortSha)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: onResume) {
                Label("Resume", systemImage: "play.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.blue, in: Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 22)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.1), radius: 8, y: -2)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }
}
#endif
