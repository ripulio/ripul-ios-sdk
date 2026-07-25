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

    public init(
        showingSidebar: Binding<Bool>? = nil,
        onNavigateToFiles: (() -> Void)? = nil,
        onNavigateToCommits: (() -> Void)? = nil,
        onInviteByEmail: ((String) -> Void)? = nil,
        screenTip: ((String) -> AnyView)? = nil,
        chooseMode: RipulChooseMode? = nil
    ) {
        self.showingSidebar = showingSidebar
        self.onNavigateToFiles = onNavigateToFiles
        self.onNavigateToCommits = onNavigateToCommits
        self.onInviteByEmail = onInviteByEmail
        self.screenTip = screenTip
        self.chooseMode = chooseMode
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
    @State private var showingSessionList = false
    @State private var renamingSession: ChatSession?
    @State private var renameText = ""
    @State private var rawModeSessions: Set<String> = []
    @State private var sessionProviders: [String: String] = [:]
    @State private var sessionModelIds: [String: String] = [:]
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
    @Namespace private var topBarNS

    private var cache: RipulSessionCache { configuration.cache }

    public init(
        bridge: AgentBridge,
        model: RipulSessionListModel,
        configuration: RipulSessionsConfiguration,
        tokenProvider: @escaping () -> String?,
        slots: RipulAgentScreenSlots = .init()
    ) {
        self.bridge = bridge
        self.model = model
        self.configuration = configuration
        self.tokenProvider = tokenProvider
        self.slots = slots
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
        return config
    }

    /// The agent web view. Compact wraps it in the edge-swipe rig (full-bleed);
    /// the regular split passes fillsSafeArea: false so the WKWebView stays confined
    /// to its detail column instead of drawing under the sidebar.
    private func agentWebView(fillsSafeArea: Bool) -> some View {
        // The native scroller is rendered INSIDE AgentView (over the web view, under
        // the reused ChatComposer) — we just sync the debug flag onto the bridge.
        AgentView(configuration: agentConfig, bridge: bridge, fillsSafeArea: fillsSafeArea) { _ in EmptyView() }
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
                    withAnimation(.easeInOut(duration: 0.28)) { showingSessionList = false }
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
                            showingSessionList = false
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
                            showingSessionList = false
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
            emptyStateOverride: configuration.emptyStateOverride,
            model: model,
            chooseMode: slots.chooseMode,
            showsTitleLozenge: false,
            showingSidebar: slots.showingSidebar
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

    private var compactBody: some View {
        AgentChatDragContainer(
            showingSessionList: $showingSessionList,
            showingMetadata: showingMetadata,
            bridge: bridge,
            isFileViewerOpen: bridge.fileViewerTitle != nil,
            hasCommitView: commitViewInfo != nil,
            onCommitViewDismiss: dismissCommitView,
            onFileViewerSwipeCommit: { bridge.requestFileViewerClose() },
            sessionList: {
                sessionListColumn(dismiss: {
                    withAnimation(.easeInOut(duration: 0.28)) {
                        showingSessionList = false
                    }
                })
            },
            chat: {
                agentWebView(fillsSafeArea: true)
                    .overlay(alignment: .trailing) {
                        if !showingSessionList && !showingMetadata {
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
                topBarOverlay
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
        .onChange(of: showingSessionList) { showing in
            if showing {
                Task { await model.loadMachinesFromAPI() }
            } else {
                rawModeSessions = Set(cache.stringArray(forKey: "ripulRawModeSessions") ?? [])
                sessionProviders = cache.dictionary(forKey: "ripulSessionProviders") as? [String: String] ?? [:]
                sessionModelIds = cache.dictionary(forKey: "ripulSessionModelIds") as? [String: String] ?? [:]
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
                    showingSessionList = true
                }
            }
        }
        .task {
            // Seed persisted view state (the app's @AppStorage equivalents).
            rawModeSessions = Set(cache.stringArray(forKey: "ripulRawModeSessions") ?? [])
            sessionProviders = cache.dictionary(forKey: "ripulSessionProviders") as? [String: String] ?? [:]
            sessionModelIds = cache.dictionary(forKey: "ripulSessionModelIds") as? [String: String] ?? [:]
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
    @ViewBuilder private var topBarOverlay: some View {
        if bridge.currentPageContext.showNativeHeader {
            ZStack(alignment: .top) {
                safeAreaGlass
                unifiedTopBar
            }
            .offset(y: parentGlobalY < 0 ? -parentGlobalY : 0)
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
            if #available(iOS 26.0, *) {
                GlassEffectContainer {
                    agentTopBarContent(session: activeSession)
                }
            } else {
                agentTopBarContent(session: activeSession)
            }
        }
    }

    @ViewBuilder
    private func agentTopBarContent(session: ChatSession?) -> some View {
        ZStack {
            // Center layer: title lozenge — stays screen-centered regardless of button count
            VStack(spacing: 1) {
                HStack(spacing: 4) {
                    Text(unifiedTitle(session: session))
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .contentTransition(.interpolate)
                    if showingSessionList, let screenTip = slots.screenTip {
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
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .modifier(GlassPillModifier())
            .modifier(GlassEffectIDModifier(id: "title", namespace: topBarNS))
            // Inset so the pill doesn't overlap with buttons on either side.
            // Trailing side can have two buttons (scrollUp 44 + spacing 8 + menu 44 = 96px),
            // so pad symmetrically to the larger side when the scroll button is visible.
            .padding(.horizontal, (!showingSessionList && !showingMetadata && bridge.fileViewerTitle == nil) ? 108 : 56)
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 1.0).onEnded { _ in
                    NotificationCenter.default.post(name: .ripulShowDevTools, object: nil)
                }
            )
            .onTapGesture(count: 2) {
                bridge.logToWebConsole("[AgentScreen] title lozenge double-tap -> bridge.toggleElementDebugger")
                bridge.toggleElementDebugger()
            }
            .uiKitIdentifier("AgentScreen.topBar.titleLozenge")

            // Edge layer: buttons at leading/trailing
            HStack(spacing: 8) {
                // Leading button — morphs between chevron.left and line.3.horizontal.
                // Hidden on regular width: the session list is a pinned sidebar there,
                // so navigating "back" to it (the burger) is redundant.
                // Also hidden in list mode when the host has no sidebar to open.
                if horizontalSizeClass != .regular && (!showingSessionList || slots.showingSidebar != nil) {
                    Button(action: unifiedLeadingAction(session: session)) {
                        // Cross-fade burger<->chevron with plain opacity. contentTransition
                        // (.symbolEffect/.interpolate) ran on its own timeline and would not
                        // lock to the slide; opacity is a plain animatable property, so it is
                        // governed by the top bar's .animation(value: showingSessionList) and
                        // travels on the exact same timeline as the panel.
                        ZStack {
                            Image(systemName: "line.3.horizontal")
                                .opacity(showingSessionList ? 1 : 0)
                            Image(systemName: "chevron.left")
                                .opacity(showingSessionList ? 0 : 1)
                        }
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 44, height: 44)
                            .modifier(GlassCircleModifier(glassStyle: "regular"))
                            .modifier(GlassEffectIDModifier(id: "leading", namespace: topBarNS))
                    }
                    .uiKitIdentifier("AgentScreen.topBar.leadingButton")
                }

                Spacer()

                // Navigate to previous user message (only in chat view)
                if !showingSessionList && !showingMetadata && bridge.fileViewerTitle == nil {
                    Button {
                        bridge.scrollToUserMessage(direction: "up")
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 44, height: 44)
                            .modifier(GlassCircleModifier(glassStyle: "regular"))
                    }
                    .transition(.scale.combined(with: .opacity))
                    .uiKitIdentifier("AgentScreen.topBar.scrollUpButton")
                }

                // Trailing menu — content changes but circle stays
                Menu {
                if showingMetadata {
                    metadataMenuItems
                } else if showingSessionList {
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
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .modifier(GlassCircleModifier(glassStyle: "regular"))
                    .modifier(GlassEffectIDModifier(id: "trailing", namespace: topBarNS))
            }
            // Kick a favourites refresh as the menu opens. The fetch is async
            // so this presentation may still show the cached list, but Menu
            // content is rebuilt from state between presentations — the next
            // open is fresh even if every earlier trigger raced the relay boot.
            .simultaneousGesture(TapGesture().onEnded {
                Task { await refreshFavoriteDirectories() }
            })
            .uiKitIdentifier("AgentScreen.topBar.trailingMenu")
            } // HStack (buttons)
        } // ZStack
        .padding(.horizontal, 12)
        .padding(.top, 4)
        // Sync the title bar to the chat<->list slide so the lozenge, title and
        // buttons travel on the SAME timeline as the panel. Mirror the container's
        // slideAnimation: brake (chatOpenAnimation) when opening into the chat,
        // spring (chatSlideSpring) when closing back to the list. The previous
        // fixed 0.6s spring desynced from the (variable) slide duration — e.g. the
        // lozenge settled in 0.6s while the panel was still travelling.
        .animation(showingSessionList ? chatSlideSpring : chatOpenAnimation, value: showingSessionList)
        .animation(.spring(response: 0.6, dampingFraction: 0.65), value: showingMetadata)
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
        if showingSessionList {
            return {
                if let showingSidebar = slots.showingSidebar {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { showingSidebar.wrappedValue = true }
                }
            }
        } else {
            return {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    showingSessionList = true
                }
            }
        }
    }

    private func unifiedTitle(session: ChatSession?) -> String {
        if showingMetadata { return "Session Info" }
        if let info = commitViewInfo, session?.id == info.tabId {
            return info.sessionTitle
        }
        return showingSessionList ? "Agents" : (session?.displayName ?? "New Chat")
    }

    private func unifiedSubtitle(session: ChatSession?) -> String? {
        if showingMetadata { return session?.displayName }
        if let info = commitViewInfo, session?.id == info.tabId {
            return info.shortSha
        }
        return showingSessionList ? nil : topBarSubtitle(session: session)
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

    private var defaultMachine: RemoteMachine? {
        let defaultMachineId = (cache.object(forKey: "ripulDefaultMachineId") as? String) ?? ""
        return model.machines.first { $0.machineId == defaultMachineId && $0.isOnline && !$0.isDisabled(cache: cache) }
    }

    @ViewBuilder
    private var sessionListMenuItems: some View {
        if let machine = defaultMachine {
            ForEach(ProviderConstants.cliProviders, id: \.id) { provider in
                Button {
                    Task {
                        await model.connectWithProvider(provider.providerKey!, to: machine, onSelect: { session in
                            withAnimation(.easeInOut(duration: 0.28)) {
                                showingSessionList = false
                            }
                            Task {
                                await bridge.focusSession(id: session.id)
                                bridge.scrollToBottom()
                            }
                        }, onDismiss: {
                            withAnimation(.easeInOut(duration: 0.28)) {
                                showingSessionList = false
                            }
                        })
                    }
                } label: {
                    Label("New \(provider.label)", systemImage: provider.sfSymbol)
                }
                .uiKitIdentifier("AgentScreen.listMenu.new\(provider.id)Button")
            }

            Divider()
        }

        Button {
            Task { await model.refresh() }
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        .uiKitIdentifier("AgentScreen.listMenu.refreshButton")

        Button {
            NotificationCenter.default.post(name: .ripulShowDevTools, object: nil)
        } label: {
            Label("Console Logs", systemImage: "doc.text.magnifyingglass")
        }
        .uiKitIdentifier("AgentScreen.listMenu.consoleLogsButton")
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

        if let session, rawModeSessions.contains(session.id) || ProviderConstants.isCliProvider(session.provider) {
            let rawModels = rawModelsForSession(session)
            let currentModelId = currentRawModelId(for: session)
            let currentModelName = rawModels.first(where: { $0.id == currentModelId }).map { shortModelName($0.name) } ?? "Default"
            Menu {
                ForEach(rawModels) { model in
                    Button {
                        sessionModelIds[session.id] = model.id
                        cache.set(sessionModelIds, forKey: "ripulSessionModelIds")
                        Task { await bridge.setChatModel(chatId: session.sourceChatId, modelId: model.id) }
                    } label: {
                        HStack {
                            Text(shortModelName(model.name))
                            if model.id == currentModelId {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Label(currentModelName, systemImage: "cpu")
            }
            .uiKitIdentifier("AgentScreen.contextMenu.rawModelMenu")
        } else {
            Menu {
                Button {
                    Task { await bridge.setModel(nil) }
                } label: {
                    HStack {
                        Text("Default")
                        if bridge.selectedModelId == nil {
                            Image(systemName: "checkmark")
                        }
                    }
                }

                ForEach(groupedModels, id: \.group) { group in
                    Menu(group.group) {
                        ForEach(group.models) { model in
                            Button {
                                Task { await bridge.setModel(model.id) }
                            } label: {
                                HStack {
                                    Text(model.name)
                                    if bridge.selectedModelId == model.id {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                }
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
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
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
            showingSessionList = false
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

    // MARK: - Model Helpers

    private var selectedModelName: String {
        if let selectedId = bridge.selectedModelId,
           let model = bridge.availableModels.first(where: { $0.id == selectedId }) {
            return model.name
        }
        return "Default"
    }

    private var groupedModels: [(group: String, models: [ModelInfo])] {
        let dict = Dictionary(grouping: bridge.availableModels, by: { $0.group })
        return dict.sorted { $0.key < $1.key }
            .map { (group: $0.key, models: $0.value) }
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

    private var safeAreaGlass: some View {
        VStack(spacing: 0) {
            if #available(iOS 26.0, *) {
                Rectangle()
                    .fill(.clear)
                    .frame(height: 130)
                    .glassEffect(.clear, in: .rect)
                    .mask(safeAreaMask)
            } else {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(0.6)
                    .frame(height: 130)
                    .mask(safeAreaMask)
            }
            Spacer()
        }
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
    }

    private var safeAreaMask: some View {
        VStack(spacing: 0) {
            Color.black.frame(height: 98)
            LinearGradient(
                colors: [.black, .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 32)
        }
    }
}

// MARK: - Agent Chat Drag Container

/// Isolates the interactive chat -> session-list drag from RipulAgentScreen's large
/// body. During finger tracking, only this small wrapper updates its offset state
/// while the heavy AgentView stays stable.
private struct AgentChatDragContainer<SessionList: View, Chat: View>: View {
    @Binding var showingSessionList: Bool
    let showingMetadata: Bool
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
                    if !showingSessionList && !showingMetadata {
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
