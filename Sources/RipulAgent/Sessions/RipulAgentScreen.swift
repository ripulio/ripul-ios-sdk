#if os(iOS)
import SwiftUI
import WebKit

/// Lets host chrome begin beside the actual, resizable sessions column.
public struct RipulSessionColumnWidthKey: PreferenceKey {
    public static let defaultValue: CGFloat = 0
    public static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

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
    public var onNewChat: ((String?) -> Void)?
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
    /// Host presentation preferences in the screen's ellipsis menu, in both list
    /// and chat mode. Kept separate from per-session actions.
    public var hostMenuItems: (() -> AnyView)?
    /// The host renders its own root bar over the session LIST (the
    /// first-party Agents|Plans shell: stock segmented control + the same
    /// SessionListMenu). This screen's bar then hides in list mode only —
    /// chat, metadata, commit and file-viewer states keep the unified bar
    /// with all of its earned machinery. nil/false = standalone screen,
    /// bar always on.
    public var hidesListModeBar: Bool
    public var sessionColumnVisibility: Binding<NavigationSplitViewVisibility>?
    /// First three rows in the displayed session list, after filtering/sorting.
    public var onListedSessionsChanged: (([RipulListedSession]) -> Void)?

    public init(
        showingSidebar: Binding<Bool>? = nil,
        onNavigateToFiles: (() -> Void)? = nil,
        onNavigateToCommits: (() -> Void)? = nil,
        onInviteByEmail: ((String) -> Void)? = nil,
        screenTip: ((String) -> AnyView)? = nil,
        chooseMode: RipulChooseMode? = nil,
        topBarTrailingAccessory: (() -> AnyView)? = nil,
        onListedSessionsChanged: (([RipulListedSession]) -> Void)? = nil,
        hostMenuItems: (() -> AnyView)? = nil,
        hidesListModeBar: Bool = false,
        sessionColumnVisibility: Binding<NavigationSplitViewVisibility>? = nil,
        onNewChat: ((String?) -> Void)? = nil
    ) {
        self.showingSidebar = showingSidebar
        self.onNavigateToFiles = onNavigateToFiles
        self.onNavigateToCommits = onNavigateToCommits
        self.onInviteByEmail = onInviteByEmail
        self.screenTip = screenTip
        self.chooseMode = chooseMode
        self.topBarTrailingAccessory = topBarTrailingAccessory
        self.hostMenuItems = hostMenuItems
        self.hidesListModeBar = hidesListModeBar
        self.sessionColumnVisibility = sessionColumnVisibility
        self.onListedSessionsChanged = onListedSessionsChanged
        self.onNewChat = onNewChat
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
    @Environment(\.ripulWindowContext) private var workspace
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @ObservedObject var bridge: AgentBridge
    @ObservedObject var model: RipulSessionListModel
    let configuration: RipulSessionsConfiguration
    let tokenProvider: () -> String?
    let slots: RipulAgentScreenSlots

    @Environment(\.colorScheme) private var colorScheme
    @State private var availableWidth: CGFloat = 0
    @State private var dockedMetadataWidth: CGFloat = 0
    private var chatAreaWidth: CGFloat { max(1, availableWidth - (metadataIsDocked ? dockedMetadataWidth : 0)) }
    private var canShowSessionSplit: Bool {
        WorkspaceColumns.showsSessionAndChat(width: availableWidth, hasActiveChat: bridge.activeSessionId != nil)
    }
    private var showsSessionSplit: Bool {
        #if targetEnvironment(macCatalyst)
        canShowSessionSplit && columnVisibility.wrappedValue != .detailOnly
        #else
        canShowSessionSplit
        #endif
    }
    // Touch layouts keep their automatic proportion until the user drags the
    // divider. Retain that choice while compact/folded without remounting chat.
    @State private var preferredSessionWidth: CGFloat? = {
        #if targetEnvironment(macCatalyst)
        return 420
        #else
        return nil
        #endif
    }()
    private var resizableSessionWidth: CGFloat? {
        preferredSessionWidth
    }
    private var resizeSessionPane: ((CGFloat) -> Void)? {
        { width in
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { preferredSessionWidth = width }
        }
    }
    private var sessionPaneWidth: CGFloat {
        WorkspaceColumns.sessionListWidth(in: chatAreaWidth, preferred: resizableSessionWidth)
    }
    private var detailOverlayWidth: CGFloat {
        showsSessionSplit ? max(1, chatAreaWidth - sessionPaneWidth - 1) : chatAreaWidth
    }
    private var metadataIsDocked: Bool {
        WorkspaceColumns.showsMetadata(width: availableWidth, hasActiveChat: bridge.activeSessionId != nil)
    }
    private var isListMode: Bool { showingSessionList.wrappedValue && !showsSessionSplit }
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
    @StateObject private var codexFastMode = CodexFastModeSettings()
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
    @State private var directoryStateSession: String?
    @State private var directoryLoading = false
    @State private var directoryWriting = false
    @State private var directoryError: String?
    @State private var directoryRequest = UUID()
    @State private var showingWorkingDirectoryPicker = false
    /// Session the open working-directory picker will write to. Captured when
    /// the picker opens rather than read from `bridge.activeSessionId` at pick
    /// time, so a background session switch can't redirect the write.
    @State private var workingDirectoryPickerSession: String?
    @State private var favoriteFiles: [String] = []
    // Metadata panel — offset from right edge (screenWidth = hidden, 0 = fully visible).
    @State private var metadataOffset: CGFloat = 1
    @State private var showingMetadata = false
    // File viewer panel — slides a native StandaloneFileViewer over the chat using the
    // SAME SlidePanelOverlay as the metadata panel and the Files tab, so it slides in
    // and thumb-tracks back exactly like navigating into/out of a chat session.
    @State private var fileViewerOffset: CGFloat = 1
    @State private var localColumnVisibility: NavigationSplitViewVisibility = .all
    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        slots.sessionColumnVisibility ?? $localColumnVisibility
    }
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
    /// Where the floating top bar sits in its window, fed by `WindowTopChrome`
    /// — see topBarOverlay for why it can be neither inherited from the
    /// hierarchy nor read from UIApplication during body. `top` is the window's
    /// safe inset except beside a corner camera (iPhone Duo open), where the
    /// row joins the band next to it and `left`/`right` keep it clear.
    @State private var topChrome = WindowTopChromeClearance()

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
        config.websiteDataStore = workspace?.websiteDataStore ?? configuration.websiteDataStore
        if let id = workspace?.id.uuidString {
            config.configureWebView = { configuration in
                configuration.userContentController.addUserScript(WKUserScript(
                    source: "window.__ripulWorkspaceID = '\(id)';",
                    injectionTime: .atDocumentStart, forMainFrameOnly: true))
            }
        }
        config.standalone = configuration.standalone
        config.chatPresentation = configuration.chatPresentation
        config.composerContexts = configuration.composerContexts
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
                let restoring = workspace?.isRestoringSelection == true
                workspace?.isRestoringSelection = false
                let waitsForSlide = !showsSessionSplit && !restoring
                let row = model.unifiedSessions.first { $0.matchKeys.contains(session.sourceChatId) || $0.matchKeys.contains(session.id) }
                workspace?.selectedSessionID = row?.id ?? session.sourceChatId
                workspace?.title = session.displayName ?? row?.title ?? "Ripul"
                bridge.navigatingToSessionId = session.id
                defer {
                    // The model cancels this entire callback when another row
                    // is tapped. Its old completion cannot clear the new target.
                    if !Task.isCancelled, bridge.navigatingToSessionId == session.id {
                        bridge.navigatingToSessionId = nil
                    }
                }
                // One render tick is enough for tap feedback. Focus also checks
                // readiness for an already-active tab whose previous open was
                // superseded; activeSessionId alone does not prove it is ready.
                try? await Task.sleep(nanoseconds: 16_000_000)
                guard !Task.isCancelled else { return }
                await bridge.focusSession(id: session.id)
                guard !Task.isCancelled else { return }
                bridge.logSessionStartMarker("ios.navigation_requested", chatId: session.sourceChatId)
                withAnimation(chatOpenAnimation, completionCriteria: .removed) {
                    if !restoring { showingSessionList.wrappedValue = false }
                } completion: {
                    bridge.logSessionStartMarker("ios.navigation_animation_complete", chatId: session.sourceChatId)
                }
                if waitsForSlide { try? await Task.sleep(nanoseconds: 700_000_000) }
                guard !Task.isCancelled else { return }
                if workspace == nil { bridge.scrollToBottom() }
            },
            onDismiss: { dismiss() },
            allowRipulAgents: configuration.allowRipulAgents,
            invitesSection: configuration.invitesSection,
            emptyStateOverride: configuration.emptyStateOverride,
            model: model,
            chooseMode: slots.chooseMode,
            showsTitleLozenge: false,
            // The host's app-nav sidebar is a pinned rail at regular width, so
            // there is nothing for a right-drag on the list to slide open.
            showingSidebar: slots.showingSidebar,
            quickActionsEnabled: configuration.quickActionsEnabled,
            // The list has either the host's Agents/Plans bar or our Sessions
            // bar above it at every width. Docking metadata must not remove
            // that header's clearance and put Machines underneath its buttons.
            reservesTopBarSpace: true,
            onListedSessionsChanged: slots.onListedSessionsChanged
        )
        // SessionChatColumns extends both panes through the vertical safe area
        // so chat can draw behind the glass. Restore the list's window clearance
        // explicitly, in addition to its app-header reservation. Local geometry
        // reports zero here because the column has already consumed the inset.
        // The list's own 52pt reservation follows the bar's row; content still
        // clears the rectangular safe area when the row sits beside a camera.
        .padding(.top, topChrome.contentClearance(below: 52) - 52)
        .environment(\.createNewChat, slots.onNewChat)
        .environment(\.cloudSessionFeaturesEnabled, !configuration.standalone)
    }

    // All platforms keep the same list/chat container mounted across width changes.
    private var layout: some View { compactBody }

    /// True while the tab-mirror overlay owns the webview. The agent screen's
    /// edge-swipe affordances must stand down then: their UIKit recognizers
    /// arbitrate over every horizontal touch (delaying webview delivery — the
    /// mirror camera's jank), and a right-edge swipe opening the CHAT's
    /// metadata panel over a mirrored browser is a category error.
    private var mirrorOwnsWebview: Bool { bridge.currentPageContext.page == "tabMirror" }

    private var compactBody: some View {
        AgentChatDragContainer(
            screenWidth: chatAreaWidth,
            split: showsSessionSplit,
            preferredListWidth: resizableSessionWidth,
            onResizeList: resizeSessionPane,
            showingSessionList: showingSessionList,
            showingMetadata: showingMetadata,
            suppressEdgeSwipe: mirrorOwnsWebview,
            bridge: bridge,
            backGestureClosesOverlay: bridge.fileViewerTitle != nil || bridge.artefactPageTitle != nil,
            hasCommitView: commitViewInfo != nil,
            onCommitViewDismiss: dismissCommitView,
            onOverlayBackSwipe: {
                // The file viewer wins the bar, so it wins the gesture too.
                if bridge.fileViewerTitle != nil { bridge.requestFileViewerClose() }
                else { bridge.requestArtefactPageClose() }
            },
            sessionList: {
                sessionListColumn(dismiss: {
                    withAnimation(.easeInOut(duration: 0.28)) {
                        showingSessionList.wrappedValue = false
                    }
                })
                .overlay(alignment: .top) {
                    if showsSessionSplit && !slots.hidesListModeBar {
                        GlassTopBar(title: "Sessions", showLeading: slots.showingSidebar != nil,
                            onLeading: { slots.showingSidebar?.wrappedValue = true }) {
                            sessionListMenuItems
                        }
                        .topChromeExclusion(topChrome)
                        .padding(.top, topChrome.top)
                    }
                }
            },
            chat: {
                agentWebView(fillsSafeArea: !showsSessionSplit)
                    .overlay(alignment: .trailing) {
                        if !isListMode && !showingMetadata && !mirrorOwnsWebview {
                            RightEdgeSwipeView(
                                onChanged: { offset in
                                    guard bridge.fileViewerTitle == nil else { return }
                                    var t = Transaction()
                                    t.disablesAnimations = true
                                    let screenWidth = detailOverlayWidth
                                    withTransaction(t) { metadataOffset = screenWidth - offset }
                                },
                                onEnded: { offset, velocity in
                                    guard bridge.fileViewerTitle == nil else { return }
                                    let screenWidth = detailOverlayWidth
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
                                        metadataOffset = detailOverlayWidth
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

    private var decoratedLayout: some View {
        layout
        .ignoresSafeArea(.keyboard)
        .background {
            GeometryReader { geo in
                Color.clear.preference(key: KeyboardStableYKey.self, value: geo.frame(in: .global).minY)
            }
        }
        .onPreferenceChange(KeyboardStableYKey.self) { parentGlobalY = $0 }
        .background(WindowTopChrome { topChrome = $0 })
        // Metadata panel — compact: slides in from the right edge; regular (iPad /
        // Mac Catalyst): docks as a trailing inspector column.
        .overlay {
            if !metadataIsDocked {
                SlidePanelOverlay(
                    isPresented: $showingMetadata,
                    offset: $metadataOffset,
                    containerWidth: detailOverlayWidth
                ) {
                    metadataPanel
                }
                .padding(.leading, showsSessionSplit ? sessionPaneWidth + 1 : 0)
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
                offset: $fileViewerOffset,
                containerWidth: detailOverlayWidth
            ) {
                if let path = bridge.fileViewerFilePath {
                    StandaloneFileViewer(
                        filePath: path,
                        chatId: bridge.fileViewerChatId ?? bridge.activeSessionId,
                        line: bridge.fileViewerLine,
                        readBridge: bridge,
                        siteKey: configuration.siteKey,
                        baseURL: configuration.baseURL
                    )
                    .id("\(path):\(bridge.fileViewerLine ?? 0):\(bridge.fileViewerChatId ?? "")")
                }
            }
            .padding(.leading, showsSessionSplit ? sessionPaneWidth + 1 : 0)
        }
        // On a wide screen the metadata panel is always docked as a permanent
        // trailing column (no toggle); compact uses the slide-out overlay above.
        // Keep metadata outside the chat/file overlays. A native inspector can
        // adapt into a sheet during resizing, even as this layout is replaced;
        // the inline pane cannot leave that detached presentation behind.
        .modifier(DockedMetadataPane(panel: metadataPanel, isPresented: metadataIsDocked))
        // Floating top bar — compact only. On the regular split it's applied to the
        // chat detail instead, so the glass strip doesn't span the sidebar / metadata
        // columns.
        .overlay(alignment: .top) {
            topBarOverlay
                .padding(.leading, showsSessionSplit ? sessionPaneWidth + 1 : 0)
                .padding(.trailing, metadataIsDocked ? dockedMetadataWidth : 0)
                .ignoresSafeArea(edges: .top)
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
    }

    public var body: some View {
        decoratedLayout
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .onPreferenceChange(RipulMetadataColumnWidthKey.self) { dockedMetadataWidth = $0 }
        .onChange(of: metadataIsDocked) { _, docked in
            if docked { showingMetadata = false }
        }
        .onChange(of: detailOverlayWidth) { _, width in
            if !showingMetadata { metadataOffset = width }
            if bridge.fileViewerTitle == nil { fileViewerOffset = width }
        }
        .preference(key: RipulSessionColumnWidthKey.self, value: showsSessionSplit ? sessionPaneWidth + 1 : 0)
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
            modelPickerSheet(for: target).ripulSheet(.page)
        }
        .modifier(workingDirectoryPickerSheet)
        .modifier(AppWorkingDirectorySheet(bridge: bridge))
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

            if !configuration.standalone {
            Task { await bridge.fetchEffort() }
            // Cached models make the picker immediate; always refresh in the background.
            Task { await bridge.fetchModels() }
            Task { await refreshFavoriteDirectories() }
            if let activeSession = bridge.sessions.first(where: { $0.id == bridge.activeSessionId }) {
                await refreshCodexModelsIfNeeded(for: activeSession)
            }
            }
        }
        .background {
            Color.clear.frame(width: 0, height: 0)
                .task(id: codexFastModeContext) {
                    let session = bridge.sessions.first { $0.id == bridge.activeSessionId }
                    await codexFastMode.refresh(bridge: bridge, chatId: session?.sourceChatId,
                        modelId: session.flatMap { sessionModelIds[$0.id] })
                }
        }
        .onChange(of: tokenProvider()) { newToken in
            if newToken != nil {
                Task { await model.refreshAfterAuth() }
            }
        }
        // `onChange` fires only on a CHANGE. A token already in hand at first
        // render (a relaunch with a cached session) never changed, so the
        // authenticated refresh — machines, then the tab list — never ran.
        // `refreshAfterAuth` is idempotent, so this is safe alongside it.
        .task {
            if tokenProvider() != nil { await model.refreshAfterAuth() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            Task { await model.refresh() }
            if !configuration.standalone { Task { await refreshFavoriteDirectories() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ripulDiscussFile)) { notification in
            guard notification.object as? AgentBridge === bridge else { return }
            if let path = notification.userInfo?["path"] as? String {
                let line = notification.userInfo?["line"] as? Int
                startDiscussSession(path: path, line: line)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ripulFocusSession)) { notification in
            guard notification.object as? AgentBridge === bridge else { return }
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
            if let session = bridge.sessions.first(where: { $0.id == newId }) {
                let row = model.unifiedSessions.first { $0.matchKeys.contains(session.sourceChatId) || $0.matchKeys.contains(session.id) }
                workspace?.selectedSessionID = row?.id ?? session.sourceChatId
                workspace?.title = session.displayName ?? row?.title ?? "Ripul"
            }
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
    /// `topChrome.top` adds the **window's** clearance back, so the bar's
    /// position is stated, not inherited. Neither obvious source for that
    /// inset works:
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
    /// So `WindowTopChrome` (mounted on `body`'s root) reads the window inset,
    /// status bar and reserved regions from UIKit callbacks outside any SwiftUI
    /// update and feeds the `topChrome` state. Catalyst has no status bar, so
    /// its inset reports 0 and the bar sits flush as before. Beside a corner
    /// camera the row moves up into the band and `topChromeExclusion` keeps
    /// its controls out of the camera's reserved region.
    @ViewBuilder private var topBarOverlay: some View {
        if configuration.standalone || bridge.currentPageContext.showNativeHeader {
            // Hidden (not removed) while the host's root bar covers list
            // mode, so the glass containers stay mounted and the reappear on
            // chat entry is a fade on the same value the bar's own content
            // already animates on.
            // Yields at regular width too. The host's root bar floats over the
            // whole split there, so keeping this one would stack the screen's
            // "Agents" lozenge behind the root bar's Agents|Plans picker.
            let hiddenForHostBar = slots.hidesListModeBar
                && isListMode
                && !showingMetadata
                && bridge.fileViewerTitle == nil
            ZStack(alignment: .top) {
                safeAreaGlass
                unifiedTopBar
                    .topChromeExclusion(topChrome)
                    .padding(.top, topChrome.top)
                    .opacity(titleLozengeExpandedNow ? 0 : 1)
                    .allowsHitTesting(!titleLozengeExpandedNow)
                    .accessibilityHidden(titleLozengeExpandedNow)
                // The chat title morph, a SIBLING of the bar rather than its
                // centre slot. Only the collapsed pill reserves the edge
                // buttons' space; the open panel covers them, including the
                // host's minimise button, within the bar's 12pt gutters.
                chatTitleMorphOverlay
                    .padding(.horizontal, titleLozengeExpandedNow ? 12 : 12 + centerLozengeInset)
                    .topChromeExclusion(topChrome)
                    .padding(.top, topChrome.top + 4)
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
        } else if let artefactTitle = bridge.artefactPageTitle {
            artefactPageTopBar(title: artefactTitle)
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
            onDoubleTapTitle: toggleTitleInspector,
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
        .animation(isListMode ? chatSlideSpring : chatOpenAnimation, value: isListMode)
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
        !isListMode
            && !showingMetadata
            && bridge.fileViewerTitle == nil
            && commitViewInfo == nil
    }

    private func toggleTitleInspector() {
        bridge.logToWebConsole("[AgentScreen] title lozenge double-tap -> Inspector")
        bridge.toggleElementDebugger()
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
        // Describe this chat's fixed origin, independently of the app startup
        // preference. Keep it in the expanded title, off the conversation canvas.
        if let session {
            if session.sourceChatId.hasPrefix("mac_") || session.hostChatId?.hasPrefix("mac_") == true {
                rows.append(.init(icon: "externaldrive", text: "Direct · History on the Mac"))
            } else if session.remoteMachineName != nil {
                rows.append(.init(icon: "cloud", text: "Relay · History in Ripul cloud"))
            }
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
    /// Hidden only when the session list actually fits beside the chat.
    /// A regular size class alone does not guarantee that. Also hidden in list
    /// mode when the host has no sidebar to open.
    private func agentLeading(session: ChatSession?) -> (() -> AnyView)? {
        #if targetEnvironment(macCatalyst)
        if canShowSessionSplit {
            return {
                AnyView(Button {
                    showingSessionList.wrappedValue = false
                    columnVisibility.wrappedValue = columnVisibility.wrappedValue == .detailOnly ? .all : .detailOnly
                } label: {
                    Image(systemName: "sidebar.left")
                        .frame(width: 44, height: 44)
                        .modifier(GlassCircleModifier(glassStyle: "regular"))
                }
                .accessibilityLabel("Toggle Sessions Sidebar")
                .uiKitIdentifier("AgentScreen.topBar.sessionColumnToggle"))
            }
        }
        #endif
        guard (!showsSessionSplit || showingMetadata || commitViewInfo != nil),
              !isListMode || slots.showingSidebar != nil
        else { return nil }
        let inList = isListMode
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
                .accessibilityLabel(inList ? "Show app sidebar" : "Back to sessions")
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
        if !isListMode, let session, supportsMultipleWindows, let open = workspace?.openWindow {
            Button("Open in New Window", systemImage: "rectangle.on.rectangle") {
                let row = model.unifiedSessions.first { $0.matchKeys.contains(session.sourceChatId) || $0.matchKeys.contains(session.id) }
                open(row?.id ?? session.sourceChatId)
            }
            .accessibilityIdentifier("Workspace.openSessionWindow")
        }
        if showingMetadata {
            metadataMenuItems
        } else if isListMode {
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
            if !metadataIsDocked {
                Button {
                    metadataOffset = detailOverlayWidth
                    showingMetadata = true
                } label: { Label("Session Info", systemImage: "info.circle") }
                .uiKitIdentifier("AgentScreen.contextMenu.sessionInfo")
            }
            agentMenuItems(session: session)
        }
        if let hostMenuItems = slots.hostMenuItems {
            Section { hostMenuItems() }
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
        if isListMode {
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
            VStack(alignment: .leading, spacing: 0) {
                lozengeHeader(session: session, expanded: expanded)
                    .frame(maxWidth: expanded ? .infinity : nil, alignment: .leading)
                    .padding(.horizontal, expanded ? 14 : 12)
                    .padding(.top, expanded ? 10 : 0)
                    .padding(.bottom, expanded ? 9 : 0)
                    .frame(minHeight: expanded ? nil : 44)
                    .contentShape(Rectangle())
                    // This visible overlay owns both taps; the bar's recognizer
                    // is underneath it. The header excludes the disclosed
                    // controls so their taps cannot also collapse the panel.
                    .modifier(TitleTapGestures(
                        onTap: toggleTitleLozenge,
                        onDoubleTap: toggleTitleInspector
                    ))
                if expanded {
                    // No .transition: the reveal is the panel's height growth
                    // alone. A transition would translate/fade the block while
                    // the frame is also animating and the two fight.
                    expandedTitleContent(session: session)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 10)
                }
            }
            .frame(minHeight: 44)
            // The panel gets the full bar width, independent of edge buttons.
            // Keep a readable minimum, capped to fit even a narrow column.
            // Collapsed still hugs its content in the original centre slot.
            .frame(minWidth: expanded ? min(320, max(0, detailOverlayWidth - 24 - topChrome.left - topChrome.right)) : nil,
                   maxWidth: expanded ? .infinity : nil, alignment: .leading)
            // 22 circular at the compact 44pt height IS a capsule, so the
            // contracted pill is geometrically unchanged; 16 continuous is
            // the app-wide panel radius. One shape type either way keeps the
            // radius interpolating instead of cutting.
            .contentShape(.rect(cornerRadius: expanded ? 16 : 22))
            .glassEffect(.regular, in: .rect(cornerRadius: expanded ? 16 : 22))
            // Driven by withAnimation inside toggleTitleLozenge — no
            // .animation(value:) here.
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 1.0).onEnded { _ in
                    NotificationCenter.default.post(name: .ripulShowDevTools, object: nil)
                }
            )
            #if os(iOS)
            // The overview pull, mounted HERE as well as on the bar row. This
            // pill is a sibling stacked over the bar, not a child of it, so a
            // drag that begins on it never reaches the row's recogniser — the
            // exact spot every other screen's lozenge invites you to pull from
            // went dead in chat when the morphing pill took the slot over. The
            // taps above are exclusive only against each other; a 3pt move
            // fails them and the pull carries on. Off while the panel is
            // disclosed, where a vertical drag reads as a stray touch on its
            // controls rather than a request for the board.
            .screenSwitcherPull(.down, enabled: !expanded, allowsHorizontal: true)
            #endif
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
                    if isListMode, let screenTip = slots.screenTip {
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
        guard !isListMode,
              !showingMetadata,
              bridge.fileViewerTitle == nil,
              bridge.artefactPageTitle == nil,
              let session else { return nil }
        if let info = commitViewInfo, session.id == info.tabId { return nil }
        return model.unifiedSessions.first { $0.represents(session) }
    }

    private func unifiedTitle(session: ChatSession?) -> String {
        if showingMetadata { return "Session Info" }
        if let info = commitViewInfo, session?.id == info.tabId {
            return info.sessionTitle
        }
        return isListMode ? "Agents" : (session?.displayName ?? "New Chat")
    }

    private func unifiedSubtitle(session: ChatSession?) -> String? {
        if showingMetadata { return session?.displayName }
        if let info = commitViewInfo, session?.id == info.tabId {
            return info.shortSha
        }
        return isListMode ? nil : topBarSubtitle(session: session)
    }

    /// An artefact's full page borrows the file viewer's bar: ONE native back
    /// button, so the web page draws none of its own. No menu — an artefact owns
    /// everything else about its draw.
    @ViewBuilder
    private func artefactPageTopBar(title: String) -> some View {
        GlassTopBar(
            title: title,
            subtitle: "Artefact",
            onLeading: { bridge.requestArtefactPageClose() },
            trailingOuter: agentHostAccessory,
            centerInset: centerLozengeInset
        ) {
            EmptyView()
        }
    }

    @ViewBuilder
    private func fileViewerTopBar(title: String) -> some View {
        GlassTopBar(
            title: title,
            subtitle: "Viewing File",
            onLeading: { bridge.requestFileViewerClose() },
            trailingOuter: agentHostAccessory,
            centerInset: centerLozengeInset
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
            onShowModelPicker: {
                if let newChat = slots.onNewChat { newChat(nil) }
                else { modelPickerTarget = .newSession }
            },
            usesUnifiedCreation: slots.onNewChat != nil
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
    private var codexFastModeContext: String {
        let session = bridge.sessions.first { $0.id == bridge.activeSessionId }
        return [session?.sourceChatId ?? "", session.map { currentRawModelId(for: $0) } ?? "",
                String(bridge.availableModels.count), String(bridge.isConnected), String(bridge.isSessionsReady)].joined(separator: "|")
    }

    private func agentMenuKey(session: ChatSession?) -> String {
        if showingMetadata { return "meta" }
        if isListMode {
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
            session.map { rawModeSessions.contains($0.id) ? "raw" : "std" } ?? "-",
            favoriteDirectories.joined(separator: ","),
            sessionWorkingDirectory ?? "-",
            hostWorkingDirectory ?? "-",
            slots.onInviteByEmail != nil ? "invite" : "-",
            cache.bool(forKey: "showElementDebuggerMenu") ? (elementDebuggerActive ? "dbg1" : "dbg0") : "-",
            cache.bool(forKey: "enableNoteInjection") ? "notes" : "-",
            bridge.selectedEffort ?? "-",
            codexFastMode.menuKey,
        ]
        #if os(iOS)
        parts.append(bridge.browserPreviewAvailable ? "browser-preview" : "no-browser-preview")
        #endif
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
            if let newChat = slots.onNewChat { newChat(nil); return }
            Task {
                bridge.logSessionStartMarker("ios.tap", extra: "source=AgentScreen.menu.newChat")
                _ = await bridge.createNewChat()
            }
        } label: {
            Label("New Chat", systemImage: "plus.message")
        }
        .uiKitIdentifier("AgentScreen.contextMenu.newChatButton")

        // Where the turn runs, which model runs it, how hard it thinks. These
        // three decide what sending a message actually does, so they lead the
        // menu — everything below is a session action or a debug switch. Effort
        // travels with the model on purpose: the level is global but the range
        // is per-model, and split apart they read as unrelated controls.
        if !configuration.standalone, let session, session.remoteMachineName != nil {
            // Opens a sheet rather than a submenu: every favourite shares the
            // same long parent path, so as flat menu rows they read as one
            // repeated string truncated before the part that differs. A menu
            // row cannot show the repo name larger than its path — UIMenu keeps
            // the title and drops the layout — so the list moved to a real view.
            Button {
                workingDirectoryPickerSession = session.id
                showingWorkingDirectoryPicker = true
                Task { await refreshFavoriteDirectories(sessionId: session.id) }
            } label: {
                Label(workingDirectoryMenuTitle, systemImage: "folder.badge.gearshape")
            }
            .uiKitIdentifier("AgentScreen.contextMenu.workingDirectoryMenu")
        }

        if !configuration.standalone {
        // Both branches open the SAME picker — sections, pins, search, billing
        // subtitles — differing only in which models it lists. They used to be
        // two nested `Menu` trees, which meant the chat's model change was the
        // one place in the app you couldn't see what a model would cost or pin
        // the one you keep coming back to.
        // A chat reached through someone else's invitation runs on THEIR host
        // with THEIR model and effort. Now that a guest's row carries the real
        // provider (so the CLI branches below would otherwise apply), offer no
        // model or effort control at all — the relay refuses those commands
        // from a guest, and a picker that silently does nothing is worse than
        // none.
        if let session, session.isSharedGuest == true {
            EmptyView()
        } else if let session, rawModeSessions.contains(session.id) || ProviderConstants.isCliProvider(session.provider) {
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
        if let session, session.isSharedGuest != true,
           rawModeSessions.contains(session.id) || ProviderConstants.isCliProvider(session.provider) {
            Menu {
                Button { Task { await bridge.setEffort(nil) } } label: {
                    HStack {
                        Text("Default")
                        if bridge.selectedEffort == nil { Image(systemName: "checkmark") }
                    }
                }
                ForEach(effortLevels(for: session), id: \.self) { level in
                    Button { Task { await bridge.setEffort(level) } } label: {
                        HStack {
                            Text(ModelPickerEffort.label(level))
                            if bridge.selectedEffort == level { Image(systemName: "checkmark") }
                            }
                    }
                }
            } label: {
                Label(
                    bridge.selectedEffort.map { "Effort · \(ModelPickerEffort.label($0))" } ?? "Effort",
                    systemImage: "gauge.with.dots.needle.33percent"
                )
            }
            .uiKitIdentifier("AgentScreen.contextMenu.effortMenu")
        }

        }
        if let session {
            CodexFastModeMenu(settings: codexFastMode) { enabled in
                Task { await codexFastMode.setEnabled(enabled, bridge: bridge, modelId: sessionModelIds[session.id]) }
            }
        }
        Divider()

        if slots.onNewChat == nil {
            // Was a nested menu over the hardcoded "Anthropic API" group; now the
            // shared picker, so every catalog model can start a session and each one
            // says who pays for it.
            Button {
                if let newChat = slots.onNewChat { newChat(nil) }
                else { modelPickerTarget = .newSession }
            } label: {
                Label("New session from model…", systemImage: "square.stack.3d.up")
            }
            .uiKitIdentifier("AgentScreen.contextMenu.newFromModelButton")
        }

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
            #if os(iOS)
            if bridge.browserPreviewAvailable {
                Button { bridge.showBrowserPreview() } label: {
                    Label("View browser", systemImage: "pip")
                }
                .uiKitIdentifier("AgentScreen.contextMenu.viewBrowserButton")
            }
            #endif
            Button {
                renameText = ""
                renamingSession = session
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .uiKitIdentifier("AgentScreen.contextMenu.renameButton")

            if !configuration.standalone {
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

        if !configuration.standalone, let session, session.remoteMachineName != nil, !rawModeSessions.contains(session.id) {
            Button {
                enableRawMode(session: session)
            } label: {
                Label("Enable \(ProviderConstants.defaultCliProvider.label)", systemImage: "terminal")
            }
            .uiKitIdentifier("AgentScreen.contextMenu.enableClaudeButton")
        }

        if cache.bool(forKey: "showElementDebuggerMenu") {
            Button {
                bridge.toggleElementDebugger()
            } label: {
                Label("Inspector", systemImage: "viewfinder")
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

        if !configuration.standalone, let session {
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
            // Present from the requesting workspace, including its iPad popover anchor.
            if let rootVC = bridge.hostingWindow?.rootViewController {
                activityVC.popoverPresentationController?.sourceView = rootVC.view
                activityVC.popoverPresentationController?.sourceRect = CGRect(x: rootVC.view.bounds.midX, y: rootVC.view.bounds.midY, width: 1, height: 1)
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
        switch target {
        case .global:
            ModelPickerSheetContent(
                models: bridge.availableModels,
                cache: cache,
                selectedId: bridge.selectedModelId,
                showsDefaultRow: true,
                effort: effortControl(forModelId: bridge.selectedModelId),
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
                    effort: effortControl(forModelId: currentRawModelId(for: session)),
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

    /// Effort control scoped to the model it is shown beside. The chosen level
    /// is a global override, but WHICH levels exist is per-model — Codex reports
    /// its range per slug (GPT-6-Astra accepts `ultra`; older rows don't), so a
    /// shared control built from a literal list offers the wrong menu on one of
    /// them. Models that report nothing fall back to the static range.
    private func effortControl(forModelId modelId: String?) -> ModelPickerEffort {
        ModelPickerEffort(
            current: bridge.selectedEffort,
            model: modelId.flatMap { id in bridge.availableModels.first(where: { $0.id == id }) },
            onChange: { level in Task { await bridge.setEffort(level) } }
        )
    }

    /// Reasoning levels to offer for a session's current model.
    private func effortLevels(for session: ChatSession) -> [String] {
        guard let model = bridge.availableModels.first(where: { $0.id == currentRawModelId(for: session) }),
              let supported = model.cliSupportedEfforts,
              !supported.isEmpty
        else { return ModelPickerEffort.fallbackLevels }
        return supported
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
        guard !configuration.standalone else { return }
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

    // MARK: - Working Directory

    /// Where the next turn would actually run: the session's override if it has
    /// one, otherwise its recorded directory or the host default.
    private var effectiveWorkingDirectory: String? {
        guard directoryStateSession == bridge.activeSessionId else { return recordedWorkingDirectory(bridge.activeSessionId) }
        return sessionWorkingDirectory ?? recordedWorkingDirectory(bridge.activeSessionId) ?? hostWorkingDirectory
    }

    private func recordedWorkingDirectory(_ sessionId: String?) -> String? {
        guard let sessionId else { return nil }
        return model.unifiedSessions.first { $0.ripulSession?.id == sessionId }?.projectPath
    }

    /// The menu row reads as the repo name once a directory is in effect, so
    /// the current working directory is legible without opening the picker —
    /// the model row earns its place in the menu the same way.
    private var workingDirectoryMenuTitle: String {
        guard let dir = effectiveWorkingDirectory, !dir.isEmpty else { return "Working Directory" }
        return DirectoryPathDisplay.parse(dir).name
    }

    private var workingDirectoryPickerSheet: WorkingDirectoryPickerSheet {
        WorkingDirectoryPickerSheet(
            isPresented: $showingWorkingDirectoryPicker,
            directories: directoryStateSession == workingDirectoryPickerSession ? favoriteDirectories : [],
            selection: sessionWorkingDirectory,
            defaultPath: recordedWorkingDirectory(workingDirectoryPickerSession) ?? hostWorkingDirectory,
            identifierPrefix: "AgentScreen.workingDirectoryPicker",
            isLoading: directoryLoading,
            error: directoryError,
            onRetry: { Task { await refreshFavoriteDirectories(sessionId: workingDirectoryPickerSession) } },
            dismissOnPick: false,
            onPick: { picked in applyWorkingDirectory(picked) }
        )
    }

    private func applyWorkingDirectory(_ directory: String?) {
        guard let sessionId = workingDirectoryPickerSession, !directoryLoading else { return }
        directoryWriting = true
        directoryRequest = UUID() // invalidate any read started before this write
        directoryLoading = true
        directoryError = nil
        Task {
            let success = await bridge.setWorkingDirectory(sessionId: sessionId, directory: directory)
            directoryWriting = false
            directoryLoading = false
            guard workingDirectoryPickerSession == sessionId else { return }
            if success {
                sessionWorkingDirectory = directory
                directoryStateSession = sessionId
                showingWorkingDirectoryPicker = false
            } else {
                directoryError = "The host did not confirm the directory change. Reconnect and retry."
            }
        }
    }

    /// Always read fresh from this conversation's host. No shared app cache:
    /// a cached list from another host must never become selectable here.
    private func refreshFavoriteDirectories(sessionId requestedSession: String? = nil) async {
        guard !configuration.standalone else { return }
        guard !directoryWriting, let sessionId = requestedSession ?? bridge.activeSessionId else { return }
        if showingWorkingDirectoryPicker, let pickerSession = workingDirectoryPickerSession, sessionId != pickerSession { return }
        let request = UUID()
        directoryRequest = request
        directoryStateSession = sessionId
        favoriteDirectories = []
        sessionWorkingDirectory = nil
        hostWorkingDirectory = nil
        directoryError = nil
        directoryLoading = true
        do {
            let result = try await bridge.getFavoriteDirectories(sessionId: sessionId)
            guard directoryRequest == request else { return }
            favoriteDirectories = result.directories
            if let pinned = result.sessionDirectory, !favoriteDirectories.contains(pinned) { favoriteDirectories.append(pinned) }
            hostWorkingDirectory = result.current
            sessionWorkingDirectory = result.sessionDirectory
        } catch {
            guard directoryRequest == request else { return }
            directoryError = error.localizedDescription
        }
        directoryLoading = false
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
        TopSafeAreaGlass(topInset: topChrome.top)
    }
}

// MARK: - Agent Chat Drag Container

/// Isolates the interactive chat -> session-list drag from RipulAgentScreen's large
/// body. During finger tracking, only this small wrapper updates its offset state
/// while the heavy AgentView stays stable.
private struct AgentChatDragContainer<SessionList: View, Chat: View>: View {
    let screenWidth: CGFloat
    let split: Bool
    let preferredListWidth: CGFloat?
    let onResizeList: ((CGFloat) -> Void)?
    @Binding var showingSessionList: Bool
    let showingMetadata: Bool
    /// Mirror active — the left-edge back-swipe stands down (see
    /// mirrorOwnsWebview). Passed as a plain value because this container
    /// does not observe the bridge (by design — see the init comment).
    let suppressEdgeSwipe: Bool
    let bridge: AgentBridge
    let backGestureClosesOverlay: Bool
    let hasCommitView: Bool
    let onCommitViewDismiss: () -> Void
    let onOverlayBackSwipe: () -> Void
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
        screenWidth: CGFloat,
        split: Bool,
        preferredListWidth: CGFloat? = nil,
        onResizeList: ((CGFloat) -> Void)? = nil,
        showingSessionList: Binding<Bool>,
        showingMetadata: Bool,
        suppressEdgeSwipe: Bool = false,
        bridge: AgentBridge,
        backGestureClosesOverlay: Bool,
        hasCommitView: Bool,
        onCommitViewDismiss: @escaping () -> Void,
        onOverlayBackSwipe: @escaping () -> Void,
        @ViewBuilder sessionList: () -> SessionList,
        @ViewBuilder chat: () -> Chat
    ) {
        self.screenWidth = screenWidth
        self.split = split
        self.preferredListWidth = preferredListWidth
        self.onResizeList = onResizeList
        self._showingSessionList = showingSessionList
        self.showingMetadata = showingMetadata
        self.suppressEdgeSwipe = suppressEdgeSwipe
        self.bridge = bridge
        self.backGestureClosesOverlay = backGestureClosesOverlay
        self.hasCommitView = hasCommitView
        self.onCommitViewDismiss = onCommitViewDismiss
        self.onOverlayBackSwipe = onOverlayBackSwipe
        self.sessionList = sessionList()
        self.chat = chat()
    }

    var body: some View {
        SessionChatColumns(width: screenWidth, showsBoth: split,
            showingList: showingSessionList, chatOffset: effectiveOffset,
            canInteractWithChat: !showingMetadata, list: sessionList,
            chat: chat.overlay(alignment: .leading) {
                if !split && !showingSessionList && !showingMetadata && !suppressEdgeSwipe {
                    InteractiveEdgeSwipeView(
                        onChanged: handleChanged,
                        onEnded: { offset, velocity in handleEnded(offset: offset, velocity: velocity) },
                        onCancelled: handleCancelled,
                        maxOffset: screenWidth
                    )
                    .frame(width: 20)
                    .ignoresSafeArea()
                }
            }, preferredListWidth: preferredListWidth, onResizeList: onResizeList)
        // Animate navigation, not the window width embedded in effectiveOffset.
        // Gesture settling already supplies its own explicit transaction.
        .animation(split ? nil : slideAnimation, value: showingSessionList)
        .onChange(of: split) { _, _ in gestureActive = false; gestureSettling = false }
        .onChange(of: showingSessionList) { _ in
            // Any list<->chat transition clears the gesture-settle flag. This
            // replaces a 600ms timer that could fire mid-slide (flipping the flag
            // and restarting the animation -> snap). Clearing it here means a
            // re-entry tap always finds gestureSettling=false, so its brake
            // matches the container and the slide never snaps.
            gestureSettling = false
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            settleAfterInterruption()
        }
    }

    /// A finger-tracked slide the system took the touch from — backgrounded
    /// mid-swipe, a call, Control Centre — can come back with `gestureActive`
    /// still latched on a partial `dragOffset` (the recogniser's cancel never
    /// reached us) and the web view still non-interactive behind it
    /// (`beginDrag`). The chat then sits part-way across the screen, dead to
    /// touch, until the next edge swipe. Treat it as the cancel it was; a
    /// container at rest is untouched.
    private func settleAfterInterruption() {
        guard gestureActive else { return }
        NSLog("[FGSETTLE] chat slide settled from offset=\(Int(dragOffset))/\(Int(screenWidth)) list=\(showingSessionList)")
        handleCancelled()
    }

    /// Mark a gesture's spring-back-to-rest so `slideAnimation` uses the spring
    /// (not the pick-a-session brake) for a settle. Cleared on the next
    /// list<->chat transition (see onChange above), so it can't race a timer.
    private func beginGestureSettle() {
        gestureSettling = true
    }

    private func handleChanged(_ offset: CGFloat) {
        guard !backGestureClosesOverlay else { return }
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
        if backGestureClosesOverlay {
            bridge.endDrag()
            withAnimation(chatSlideSpring) { gestureActive = false }
            if offset > 40 { onOverlayBackSwipe() }
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
