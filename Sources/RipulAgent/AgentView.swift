import SwiftUI

#if canImport(PhotosUI)
import PhotosUI
#endif

#if os(iOS)
import UIKit
#endif

/// Preference key to propagate the measured chat input height up the view tree.
private struct ChatInputHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Scroll-to-bottom button state, deliberately separate from AgentBridge so that
/// frequent scroll-state updates do not invalidate AgentView (the WKWebView host).
@MainActor
public final class ScrollButtonModel: ObservableObject {
    @Published public var show = false
    @Published public var unreadCount = 0
    public init() {}
}

/// Renders the scroll-to-bottom button from `ScrollButtonModel`. Because only this
/// tiny view observes the model, a scroll-state flip re-renders just the button —
/// AgentView (and the WKWebView it hosts) is never invalidated mid-scroll, which
/// was stalling the web view's scroll.
@available(iOS 16.0, macOS 14.0, *)
struct ScrollToBottomOverlay: View {
    @ObservedObject var model: ScrollButtonModel
    let onTap: () -> Void
    var body: some View {
        // Reserve a constant transparent area so showing/hiding the button never
        // changes layout. Its hit target must stay inside the composer's UIKit
        // hosting bounds; drawing above a zero-height overlay puts it outside.
        // The input remains bottom-aligned, and only this child observes the model.
        Color.clear
            .frame(height: 64)
            .overlay(alignment: .bottom) {
                if model.show {
                    ScrollToBottomButton(unreadCount: model.unreadCount, action: onTap)
                        #if os(iOS)
                        .background(KeyboardOverlayHitRegion())
                        #endif
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8) // gap above the chat input
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.45), value: model.show)
    }
}

@available(iOS 16.0, macOS 14.0, *)
@MainActor
public struct AgentView<TopBar: View>: View {
    public let configuration: AgentConfiguration
    public weak var searchClickDelegate: SearchClickDelegate?
    public weak var linkOpenDelegate: LinkOpenDelegate?
    public var onMinimize: (() -> Void)?
    private let topBar: ((AgentBridge) -> TopBar)?
    /// Auth token source for speech providers that call the worker API
    /// (ElevenLabs dictation). Nil falls back to the machine token.
    private var tokenProvider: (() -> String?)?
    /// Hands-free voice conversation loop (entered by long-pressing the
    /// composer mic — typed text in the composer goes in as the first
    /// utterance). Availability-free class; speech is gated internally.
    @StateObject private var voiceMode = VoiceModeController()
    /// When false, the web view respects safe areas so it stays confined to its
    /// container (e.g. a NavigationSplitView detail column) instead of full-bleeding
    /// to the window. Defaults true to preserve the full-screen iPhone behaviour.
    private var fillsSafeArea: Bool = true

    @StateObject private var bridge: AgentBridge
    private let skipBridgeSetup: Bool
    private var simulatorPreviewAction: ((SimulatorTarget, String, String) -> Void)? {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            return { target, machineId, chatId in
                guard bridge.currentSourceChatId == chatId else { return }
                bridge.simulatorPreview.open(target, machineId: machineId, chatId: chatId)
            }
        }
        #endif
        return nil
    }
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var readyConfig: AgentConfiguration?
    // Chat text / attachments / plan-mode / addressed-participants state lives in
    // the ChatComposer child, NOT here. Keeping it here meant every keystroke
    // invalidated AgentView.body — re-rendering the WKWebView host subtree, the
    // top bar, and the glass composer background. See ChatComposer below.
    @State private var showingQuickCommands = false
    @State private var showingDebugCommands = false
    @State private var showingConsoleLogs = false
    @State private var showingPlanReview = false

    /// Extracted from the body chain deliberately: AgentView's modifier chain
    /// is at the Swift type-checker's limit, and inlining this sheet tips it
    /// into "unable to type-check this expression in reasonable time".
    @ViewBuilder
    private var planReviewSheet: some View {
        // The list view does not own a NavigationStack (it is also pushed as a
        // link destination), so presenting it as a sheet supplies one.
        NavigationStack {
            Group {
                // Plans resolve against the active chat's machine and working
                // directory, so with no chat there is nothing to look in.
                if let chatId = bridge.currentSourceChatId {
                    PlanReviewScreen(bridge: bridge.planReviewBridge(), chatId: chatId)
                } else {
                    ContentUnavailableView(
                        "No active chat",
                        systemImage: "bubble.left.and.exclamationmark.bubble.right",
                        description: Text("Plans are read from the working directory of the chat you're in. Open a session first.")
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingPlanReview = false }
                }
            }
        }
    }
    @State private var chatInputMeasuredHeight: CGFloat = 0

    @StateObject private var messageHistory = MessageHistory()

    #if os(iOS)
    @StateObject private var keyboard = KeyboardObserver()
    #endif

    /// Creates an AgentView that manages its own bridge internally.
    /// - Parameter registry: the host's tool registry; the view's `.endUser`
    ///   bridge exposes its endUser-tagged entries. Omit for a toolless view.
    public init(
        configuration: AgentConfiguration,
        registry: RipulToolRegistry? = nil,
        searchClickDelegate: SearchClickDelegate? = nil,
        linkOpenDelegate: LinkOpenDelegate? = nil,
        onMinimize: (() -> Void)? = nil,
        @ViewBuilder topBar: @escaping (AgentBridge) -> TopBar
    ) {
        self.configuration = configuration
        self.searchClickDelegate = searchClickDelegate
        self.linkOpenDelegate = linkOpenDelegate
        self.onMinimize = onMinimize
        self.topBar = topBar
        self._bridge = StateObject(wrappedValue: AgentBridge(registry: registry ?? RipulToolRegistry()))
        self.skipBridgeSetup = false
    }

    /// Creates an AgentView using an externally-managed bridge.
    /// The caller is responsible for registering tools and setting delegates on the bridge.
    public init(
        configuration: AgentConfiguration,
        bridge: AgentBridge,
        onMinimize: (() -> Void)? = nil,
        fillsSafeArea: Bool = true,
        tokenProvider: (() -> String?)? = nil,
        @ViewBuilder topBar: @escaping (AgentBridge) -> TopBar
    ) {
        self.configuration = configuration
        self.searchClickDelegate = nil
        self.linkOpenDelegate = nil
        self.onMinimize = onMinimize
        self.topBar = topBar
        self._bridge = StateObject(wrappedValue: bridge)
        self.skipBridgeSetup = true
        self.fillsSafeArea = fillsSafeArea
        self.tokenProvider = tokenProvider
    }

    /// Enters hands-free mode on behalf of Siri's "Talk to Ripul" intent —
    /// the same thing the mic long-press does, minus the finger.
    ///
    /// Deliberately does NOT clear the latch when it declines for readiness.
    /// A Siri cold launch arrives here well before the web view has booted,
    /// and starting the loop with nothing to send to would look like the
    /// feature failing. The request survives until it can actually be honoured;
    /// the observer re-runs this when the bridge connects.
    private func honorVoiceModeRequest() {
        guard RipulVoiceModeRequest.pending else { return }

        // Reasons to give up rather than wait: the site key's voice profile
        // switched hands-free off, or a session is already running (a second
        // request is a no-op, exactly like a second long-press).
        guard SpeechPreferences.voiceModeEnabled else {
            RipulVoiceModeRequest.pending = false
            bridge.handleConsoleLog("LOG: [VOICE] siri request declined - voice mode disabled for this site key")
            return
        }
        guard !voiceMode.isActive else {
            RipulVoiceModeRequest.pending = false
            return
        }

        // Reasons to keep waiting.
        guard bridge.isConnected, readyConfig != nil else { return }

        RipulVoiceModeRequest.pending = false
        bridge.handleConsoleLog("LOG: [VOICE] siri request honored - entering hands-free mode")

        Task { @MainActor in
            // Siri still holds the audio session at the moment the intent
            // returns; claiming the mic immediately loses the race and the
            // recogniser comes up deaf. This hands the session back first.
            // Tuned by ear — raise it if the first utterance gets clipped.
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard RipulVoiceModeRequest.pending == false, !voiceMode.isActive else { return }
            // Compact explicitly, not via the preference: asking out loud to
            // talk is a request to converse ALONGSIDE the chat, and the
            // preference resolves through three layers (device override,
            // web-pushed profile, SDK fallback) that this path cannot see.
            voiceMode.start(bridge: bridge, tokenProvider: tokenProvider, presentation: .compact)
        }
    }

    public var body: some View {
        ZStack(alignment: .top) {
            #if os(iOS)
            (colorScheme == .dark ? Color(uiColor: .black) : Color(uiColor: .white))
                .ignoresSafeArea(edges: .top)
            #else
            Color.clear
            #endif

            if let config = readyConfig {
                AgentWebView(configuration: config, bridge: bridge)
                #if os(iOS)
                    // fillsSafeArea: ignore all edges (full-bleed iPhone). Otherwise
                    // ignore only the vertical edges — the web view fills to the top
                    // (no black gap above the chat top bar) but respects the leading/
                    // trailing insets so it stays confined to its split column.
                    .ignoresSafeArea(.all, edges: fillsSafeArea ? .all : .vertical)
                    // Slide the entire WKWebView up by the full keyboard frame height.
                    // Only applies when the native chat input is active — on sign-in and
                    // other non-chat pages the web view handles keyboard avoidance itself
                    // (the browser scrolls the focused input into the visual viewport).
                    // Uses rawHeight (not safe-area-adjusted) because the web view ignores safe areas.
                    // Animation is driven by withAnimation in KeyboardObserver, not here.
                    .offset(y: bridge.currentPageContext.showNativeChatInput && !bridge.suppressNativeChatInput && bridge.nativeChatInputFocused && keyboard.rawHeight > 0 ? -keyboard.rawHeight : 0)
                #endif
            }

            // Native chat scroller (debug): drawn OVER the WKWebView (which stays
            // mounted for comms) but UNDER the top bar and the ChatComposer overlay,
            // so the real native composer + chrome are reused — no throwaway input.
            if bridge.nativeChatScrollerEnabled, readyConfig != nil {
                NativeChatView(store: bridge.nativeChat)
                    .padding(.bottom, nativeScrollerBottomInset)
                    .background(nativeScrollerBackground)
                    #if os(iOS)
                    .ignoresSafeArea(.keyboard)
                    #endif
            }

            if let topBar {
                topBar(bridge)
            }

        }
        .animation(.easeInOut(duration: 0.25), value: voiceMode.isActive)
        .modifier(SpeechInputWarningModifier(message: $voiceMode.microphoneWarning))
        .onReceive(NotificationCenter.default.publisher(for: DeviceSpeechCredentials.changed)) { _ in voiceMode.stop() }
        .onRipulVoiceModeRequest(isConnected: bridge.isConnected) { honorVoiceModeRequest() }
        .onChange(of: bridge.nativeChatScrollerEnabled) { on in
            bridge.evaluateJavaScript("window.__ripulSetNativeChatForwarding?.(\(on), 'debug')")
            // Suspend/restore the web chat render tree so MessagePipeline + React
            // reconciliation stop when native is rendering. Comms (relay, eventBus,
            // ChatActionsManager) stay alive — only the DOM render is paused.
            bridge.evaluateJavaScript("window.__ripulSetHostRenderSuspended?.(\(on))")
        }
        .onAppear {
            bridge.composerContexts.availableOptions = configuration.composerContexts
            let on = bridge.nativeChatScrollerEnabled
            // Always sync render-suspension state on appear — clears crash-while-suspended
            // localStorage so the web never starts suspended when native chat is off.
            bridge.evaluateJavaScript("window.__ripulSetHostRenderSuspended?.(\(on))")
            if on { bridge.evaluateJavaScript("window.__ripulSetNativeChatForwarding?.(true, 'debug')") }
        }
        .overlay(alignment: .bottom) {
            if !bridge.fileViewerExpanded && bridge.currentPageContext.showNativeChatInput && !bridge.suppressNativeChatInput {
                // Leaf-isolated composer: owns the chat text state so typing
                // re-renders ONLY this child, never AgentView.body (which hosts the
                // WKWebView, the top bar, and reads many bridge.* properties).
                ChatComposer(
                    bridge: bridge,
                    composerActionStore: bridge.composerActions,
                    contextOptions: configuration.composerContexts,
                    tokenProvider: tokenProvider,
                    onEnterVoiceMode: { [weak bridge] utterance in
                        guard let bridge else { return false }
                        // A site key's voice profile can switch hands-free mode
                        // off; a second long-press while a session is live is
                        // ignored. Either way the composer keeps its text.
                        guard SpeechPreferences.voiceModeEnabled, !voiceMode.isActive else { return false }
                        voiceMode.start(
                            bridge: bridge,
                            tokenProvider: tokenProvider,
                            initialUtterance: utterance.isEmpty ? nil : utterance
                        )
                        return true
                    },
                    messageHistory: messageHistory,
                    bottomInset: composerContentBottomInset,
                    onQuickCommands: { showingQuickCommands = true },
                    onDebugCommands: { showingDebugCommands = true },
                    onShowConsoleLogs: { showingConsoleLogs = true },
                    onHeightChange: { height in
                        chatInputMeasuredHeight = height
                        #if os(iOS)
                        // Skip web padding updates while the keyboard is active — the
                        // native .offset() handles avoidance. Firing here during the
                        // keyboard animation causes a delayed JS bridge call that
                        // scrolls Virtuoso.
                        guard keyboard.rawHeight == 0 else { return }
                        #endif
                        updateWebBottomPadding()
                    }
                )
                .modifier(KeyboardAttachedOverlayModifier())
            }
        }
        // Hands-free voice mode — attached AFTER the composer overlay so it
        // stacks above it (modifier overlays ignore in-ZStack zIndex; the
        // full-screen X was previously buried under the chat box).
        // Presentation per user preference: immersive orb, or a docked pill
        // that keeps the chat + composer visible.
        .overlay {
            if voiceMode.isActive {
                // Controller state, not the preference — the preference only
                // chooses how a session opens, and the overlay's minimise /
                // expand controls move it afterwards.
                if voiceMode.presentation == .compact {
                    VStack {
                        Spacer()
                        VoiceModeCompactPanel(controller: voiceMode, tokenProvider: tokenProvider)
                            .padding(.bottom, 92)
                    }
                    .transition(.opacity)
                } else {
                    VoiceModeOverlay(controller: voiceMode, bridge: bridge, tokenProvider: tokenProvider)
                        .transition(.opacity)
                }
            }
        }
        #if os(iOS)
        .onChange(of: keyboard.rawHeight) { newHeight in
            // Re-sync web padding once keyboard fully dismisses, in case the
            // chat input changed size while the keyboard was up.
            if newHeight == 0 {
                updateWebBottomPadding()
            }
        }
        .ignoresSafeArea(.keyboard)
        #endif
        .onChange(of: bridge.currentPageContext) { context in
            if !context.showNativeChatInput || bridge.suppressNativeChatInput {
                bridge.setNativeChatInputHeight(0)
            } else {
                updateWebBottomPadding()
            }
        }
        .onChange(of: bridge.suppressNativeChatInput) { suppressed in
            if suppressed {
                bridge.setNativeChatInputHeight(0)
            } else if bridge.currentPageContext.showNativeChatInput {
                updateWebBottomPadding()
            }
        }
        .onChange(of: colorScheme) { newScheme in
            let theme: AgentTheme = newScheme == .dark ? .dark : .light
            bridge.setTheme(theme)
        }
        .onChange(of: bridge.wantsMinimize) { wantsMinimize in
            if wantsMinimize {
                if let onMinimize {
                    onMinimize()
                } else {
                    dismiss()
                }
            }
        }
        .onChange(of: bridge.wantsShowConsoleLogs) { wants in
            if wants {
                showingConsoleLogs = true
                bridge.wantsShowConsoleLogs = false
            }
        }
        .onChange(of: bridge.wantsShowViewInspector) { wants in
            if wants {
                bridge.showInspector()
                bridge.wantsShowViewInspector = false
            }
        }
        .onChange(of: bridge.wantsShowPlanReview) { wants in
            if wants {
                showingPlanReview = true
                bridge.wantsShowPlanReview = false
            }
        }
        .sheet(isPresented: $showingQuickCommands) {
            QuickCommandsSheet(bridge: bridge)
        }
        .sheet(isPresented: $showingPlanReview) { planReviewSheet }
        .sheet(isPresented: $showingDebugCommands) {
            QuickCommandsSheet(bridge: bridge, debugMode: true)
        }
        #if os(iOS)
        .sheet(isPresented: $showingConsoleLogs) {
            NavigationStack {
                ConsoleLogViewer(bridge: bridge)
                    .navigationTitle("Console Logs")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showingConsoleLogs = false }
                        }
                    }
            }
        }
        #endif
        .sheet(item: $bridge.pendingUserInteraction) { question in
            UserInteractionSheet(question: question, onRespond: { answer in
                bridge.respondToUserInteraction(answer: answer)
            }, onOpenLink: { url in
                bridge.linkOpenDelegate?.agentBridge(bridge, didRequestOpenLink: url)
                bridge.pendingUserInteraction = nil
            })
        }
        .sheet(item: $bridge.pendingTextQuestion) { question in
            UserTextInputSheet(question: question, onRespond: { answer in
                bridge.respondToTextQuestion(answer: answer)
            }, onOpenLink: { url in
                bridge.linkOpenDelegate?.agentBridge(bridge, didRequestOpenLink: url)
                bridge.pendingTextQuestion = nil
            })
        }
        .sheet(item: $bridge.pendingDateQuestion) { question in
            UserDatePickerSheet(question: question, onRespond: { answer in
                bridge.respondToDateQuestion(answer: answer)
            }, onOpenLink: { url in
                bridge.linkOpenDelegate?.agentBridge(bridge, didRequestOpenLink: url)
                bridge.pendingDateQuestion = nil
            })
        }
        .sheet(item: $bridge.pendingFileView) { request in
            FileViewerSheet(request: request)
        }
        .modifier(ToolCallDetailsPresenter(store: bridge.toolCallDetails, onDismiss: { requestId in
            bridge.send([
                "type": "agent-framework:toolCallDetails:dismissed",
                "requestId": requestId,
            ])
        }, onViewSimulator: simulatorPreviewAction))
        .modifier(SimulatorPreviewPresenter(bridge: bridge))
        .modifier(BrowserPreviewPresenter(bridge: bridge))
        .task {
            if !skipBridgeSetup {
                bridge.searchClickDelegate = searchClickDelegate
                bridge.linkOpenDelegate = linkOpenDelegate
            }

            var config = configuration
            if config.standalone {
                do {
                    config.baseURL = try await BundledAgentRuntime.shared.start()
                    config.siteKey = nil; config.sessionToken = nil; config.siteKeyConfig = nil
                    config.clerkContextId = nil
                } catch {
                    bridge.loadError = error.localizedDescription
                    return
                }
            }
            if let siteKey = config.siteKey, config.siteKeyConfig == nil {
                let baseURL = config.baseURL
                if let cached = SiteKeyValidator.cachedResult(siteKey: siteKey, baseURL: baseURL) {
                    // WARM LAUNCH: do not hold the web view for a network
                    // round-trip (measured 3.7s on iPhone cold start). Hand the
                    // web the cached pair only while the token is fresh — the
                    // web treats token+config as pre-validated and skips its
                    // own validate. With a stale token pass NOTHING: the web
                    // then validates itself, in parallel with its own boot,
                    // which is still ~3.7s sooner than validating here first.
                    if cached.tokenFresh, let token = cached.result.sessionToken {
                        config.sessionToken = token
                        config.siteKeyConfig = cached.result.configJSON
                    }
                    NSLog("[SiteKeyValidator] launch cache hit (age %.0fs, tokenFresh %@) — starting web view now, revalidating in background",
                          cached.ageSeconds, cached.tokenFresh ? "true" : "false")
                    // Refresh the cache for the next launch. readyConfig is NOT
                    // touched afterwards — a reload here would undo the win.
                    Task.detached(priority: .utility) {
                        _ = await SiteKeyValidator.validate(siteKey: siteKey, baseURL: baseURL)
                    }
                } else {
                    // FIRST LAUNCH (no cache yet): validate first, as before.
                    let result = await SiteKeyValidator.validate(
                        siteKey: siteKey, baseURL: baseURL
                    )
                    if let token = result.sessionToken {
                        config.sessionToken = token
                    }
                    config.siteKeyConfig = result.configJSON
                }
            }
            readyConfig = config
        }
    }

    // MARK: - Chat Input

    /// iOS spacing and movement belong to the UIKit keyboard attachment.
    private var composerContentBottomInset: CGFloat {
        #if os(iOS)
        return 0
        #else
        return 8
        #endif
    }

    /// The debug native scroller still needs the composer's occupied bottom area.
    /// The composer itself is positioned independently by UIKit's keyboard guide.
    private var composerBottomInset: CGFloat {
        #if os(iOS)
        return keyboard.height + 8
        #else
        return 8
        #endif
    }

    /// Bottom inset for the native scroller so its last message clears the reused
    /// ChatComposer (which sits below it). Mirrors `updateWebBottomPadding`:
    /// measured input height + resting inset + the 32pt composer fade gradient + 8.
    /// Without the fade term the last message slips ~32pt under the composer.
    private var nativeScrollerBottomInset: CGFloat {
        let fadeGradientHeight: CGFloat = 32
        #if os(iOS)
        let safeBottom = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets.bottom }
            .first ?? 0
        return chatInputMeasuredHeight + composerBottomInset + safeBottom + fadeGradientHeight + 8
        #else
        return chatInputMeasuredHeight + composerBottomInset + fadeGradientHeight + 8
        #endif
    }

    /// Opaque backing so the native scroller fully covers the web-rendered chat.
    private var nativeScrollerBackground: some View {
        #if os(iOS)
        return (colorScheme == .dark ? Color(uiColor: .black) : Color(uiColor: .white))
            .ignoresSafeArea()
        #else
        return Color(nsColor: .windowBackgroundColor)
        #endif
    }

    private func updateWebBottomPadding() {
        guard chatInputMeasuredHeight > 0 else { return }
        let bottomPad: CGFloat
        #if os(iOS)
        let safeBottom = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets.bottom }
            .first ?? 0
        // Resting padding only — keyboard shift is handled natively via WKWebView offset
        bottomPad = 8 + safeBottom
        #else
        bottomPad = 8
        #endif
        let fadeGradientHeight: CGFloat = 32
        let totalHeight = Int(chatInputMeasuredHeight + bottomPad + fadeGradientHeight + 8)
        bridge.setNativeChatInputHeight(totalHeight)
    }

}

// MARK: - Convenience inits without top bar

@available(iOS 16.0, macOS 14.0, *)
public extension AgentView where TopBar == EmptyView {
    /// Creates an AgentView with no top bar, managing its own bridge.
    /// - Parameter registry: the host's tool registry; the view's `.endUser`
    ///   bridge exposes its endUser-tagged entries. Omit for a toolless view.
    init(
        configuration: AgentConfiguration,
        registry: RipulToolRegistry? = nil,
        searchClickDelegate: SearchClickDelegate? = nil,
        linkOpenDelegate: LinkOpenDelegate? = nil,
        onMinimize: (() -> Void)? = nil
    ) {
        self.configuration = configuration
        self.searchClickDelegate = searchClickDelegate
        self.linkOpenDelegate = linkOpenDelegate
        self.onMinimize = onMinimize
        self.topBar = nil
        self._bridge = StateObject(wrappedValue: AgentBridge(registry: registry ?? RipulToolRegistry()))
        self.skipBridgeSetup = false
    }

    /// Creates an AgentView with no top bar, using an externally-managed bridge.
    init(
        configuration: AgentConfiguration,
        bridge: AgentBridge,
        onMinimize: (() -> Void)? = nil
    ) {
        self.configuration = configuration
        self.searchClickDelegate = nil
        self.linkOpenDelegate = nil
        self.onMinimize = onMinimize
        self.topBar = nil
        self._bridge = StateObject(wrappedValue: bridge)
        self.skipBridgeSetup = true
    }
}

// MARK: - ChatComposer
//
// Leaf-isolated chat composer. Owns the chat text / attachments / plan-mode /
// addressed-participants state so that a keystroke re-renders ONLY this view —
// not AgentView.body, which hosts the WKWebView, the top bar, and reads many
// bridge.* properties. Previously this state lived on AgentView, so every
// keystroke invalidated the whole body and re-rasterised the glass composer,
// spiking CPU. Same pattern AgentView already uses for the scroll button.
@available(iOS 16.0, macOS 14.0, *)
private struct ChatComposer: View {
    @ObservedObject var bridge: AgentBridge
    @ObservedObject var composerActionStore: RipulComposerActionStore
    var contextOptions: [RipulComposerContext]
    var tokenProvider: (() -> String?)?
    /// Mic long-press. Receives the composer's current text (empty when the
    /// box is blank); returns true when voice mode actually started, so the
    /// composer can consume the text (history + clear) only on a real start.
    var onEnterVoiceMode: ((String) -> Bool)?
    @ObservedObject var messageHistory: MessageHistory
    /// Content spacing only; iOS keyboard movement belongs to the outer UIKit host.
    let bottomInset: CGFloat
    let onQuickCommands: () -> Void
    let onDebugCommands: () -> Void
    let onShowConsoleLogs: () -> Void
    let onHeightChange: (CGFloat) -> Void

    private struct ArtefactChatTarget: Identifiable { let id: String }
    @State private var artefactChatTarget: ArtefactChatTarget?
    @State private var composerActionPending = false
    @State private var composerActionError: String?
    @State private var chatMessage = ""
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var imageAttachments: [NativeImageAttachment] = []
    @State private var addressedParticipants: [String] = []
    @State private var conversationModePending = false
    private var isGroupMode: Bool { bridge.conversationMode(for: bridge.currentSourceChatId) == "group" }

    private var conversationModeControl: some View {
        RipulConversationModeControl(mode: isGroupMode ? "group" : "agent", pending: conversationModePending,
            onChange: changeConversationMode, onMention: {
                chatMessage += (chatMessage.isEmpty || chatMessage.hasSuffix(" ") ? "" : " ") + "@Agent "
            })
    }

    private func changeConversationMode(_ mode: String) {
        guard !conversationModePending, let chatId = bridge.currentSourceChatId else { return }
        conversationModePending = true
        Task {
            let error = await bridge.setConversationMode(chatId: chatId, mode: mode)
            conversationModePending = false
            if let error { composerActionError = error }
        }
    }

    /// Stable provider instance for the composer mic (ElevenLabs holds a live
    /// WebSocket/engine, so identity must survive re-renders). Recreated on
    /// appear so a changed dictation-provider preference takes effect when
    /// the user returns to the chat.
    @State private var speechProvider: Any? = nil
    @AppStorage(SpeechPreferences.dictationProviderKey, store: SpeechPreferences.store) private var dictationProviderPreference = "apple"

    var body: some View {
        VStack(spacing: 0) {
            // Observes bridge.scrollButton (its OWN ObservableObject), so a
            // scroll-state flip re-renders only this child.
            ScrollToBottomOverlay(model: bridge.scrollButton) {
                bridge.scrollToBottom()
            }

            VStack(spacing: 8) {
                NativeToolStrip(store: bridge.toolStrip) { [weak bridge] event in bridge?.send(event) }
                if !BundledAgentRuntime.isEnabled { conversationModeControl }
                chatInput
            }
                .task(id: bridge.currentSourceChatId) {
                    if let chatId = bridge.currentSourceChatId {
                        await bridge.refreshComposerActions(chatId: chatId)
                        await bridge.refreshConversationMode(chatId: chatId)
                    }
                }
                .sheet(item: $artefactChatTarget) { target in
                    ArtefactChatPicker(bridge: bridge, chatID: target.id)
                }
                .alert("Message not confirmed", isPresented: Binding(
                    get: { composerActionError != nil }, set: { if !$0 { composerActionError = nil } }
                )) { Button("OK", role: .cancel) { composerActionError = nil } }
                message: { Text(composerActionError ?? "") }
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ChatInputHeightKey.self, value: geo.size.height)
                    }
                )
                .padding(.horizontal, 12)
                .padding(.top, 32)
                .background(
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .opacity(0.6)
                        .mask(
                            VStack(spacing: 0) {
                                LinearGradient(
                                    colors: [.clear, .black],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                                .frame(height: 32)
                                Color.black
                            }
                        )
                        .allowsHitTesting(false)
                )
                .overlay(alignment: .bottom) {
                    // Extend blur below the chat input into safe area
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .opacity(0.6)
                        .frame(height: 12)
                        .mask(
                            LinearGradient(
                                colors: [.black, .clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .offset(y: 12)
                        .allowsHitTesting(false)
                }
        }
        .padding(.bottom, bottomInset)
        .onPreferenceChange(ChatInputHeightKey.self) { height in
            onHeightChange(height)
        }
        .onChange(of: selectedPhotos) { newItems in
            Task {
                imageAttachments = await PhotoAttachmentHelper.process(newItems)
            }
        }
        .onChange(of: chatMessage) { newValue in
            if newValue.lowercased().hasPrefix(debugCommandTrigger) {
                chatMessage = ""
                onDebugCommands()
            }
        }
        .onChange(of: bridge.pendingInputText) { text in
            if let text {
                chatMessage = text
                bridge.pendingInputText = nil
            }
        }
        .onChange(of: bridge.pendingInputAppend) { text in
            if let text {
                chatMessage += text
                bridge.pendingInputAppend = nil
            }
        }
    }

    // MARK: Chat input

    #if os(iOS)
    private var chatInput: some View {
        NativeChatInput(
            text: $chatMessage,
            imageAttachments: $imageAttachments,
            selectedPhotos: $selectedPhotos,
            isAgentRunning: bridge.isAgentRunning && bridge.pendingUserInteraction == nil && bridge.pendingTextQuestion == nil && bridge.pendingDateQuestion == nil,
            isAgentPaused: bridge.isAgentPaused && !isGroupMode,
            onSubmit: handleSubmit,
            onSubmitNote: BundledAgentRuntime.isEnabled || isGroupMode ? nil : handleNoteSubmit,
            conversationMode: isGroupMode ? "group" : "agent",
            runningSendLabel: isGroupMode ? "Send" : composerActionStore.runningSendLabel(for: bridge.currentSourceChatId),
            composerActions: isGroupMode ? [] : composerActionStore.actions(for: bridge.currentSourceChatId),
            composerActionPending: composerActionPending,
            onComposerAction: handleComposerAction,
            onPause: { Task { await bridge.interruptAgent() } },
            onNewChat: handleNewChat,
            onQuickCommands: bridge.chatInputShowQuickCommands ? onQuickCommands : nil,
            onAddArtefact: BundledAgentRuntime.isEnabled ? nil : {
                if let id = bridge.currentSourceChatId { artefactChatTarget = ArtefactChatTarget(id: id) }
            },
            onAddTodoItem: bridge.chatInputShowTodos ? { bridge.emitTodoItemCreate() } : nil,
            onFetchTodoItems: bridge.chatInputShowTodos ? { await bridge.listTodoItems() } : nil,
            messageHistory: messageHistory,
            chatInputGlassStyle: bridge.chatInputGlassStyle,
            chatInputLayout: bridge.chatInputLayout,
            onQueryFiles: { query in
                let results = await bridge.queryAutocomplete(category: "files", query: query)
                return results.compactMap { dict in
                    guard let path = dict["path"] as? String else { return nil }
                    let isDir = dict["isDirectory"] as? Bool ?? false
                    return FileSuggestion(path: path, isDirectory: isDir)
                }
            },
            onQueryElements: {
                let results = await bridge.queryAutocomplete(category: "ui", query: "")
                return results.compactMap { dict in
                    guard let dataUi = dict["dataUi"] as? String else { return nil }
                    return ElementSuggestion(dataUi: dataUi)
                }
            },
            onQueryParticipants: {
                let dicts = await bridge.queryAutocomplete(category: "people", query: "")
                return dicts.compactMap { dict in
                    guard let id = dict["id"] as? String,
                          let name = dict["name"] as? String else { return nil }
                    let group = dict["group"] as? String
                    return ParticipantSuggestion(id: id, name: name, group: group)
                }
            },
            onQueryBranches: { query in
                let dicts = await bridge.queryAutocomplete(category: "branches", query: query)
                return dicts.compactMap { dict in
                    guard let name = dict["name"] as? String,
                          let token = dict["token"] as? String else { return nil }
                    return BranchSuggestion(
                        id: token,
                        name: name,
                        description: dict["description"] as? String,
                        remote: dict["remote"] as? Bool ?? false,
                        token: token
                    )
                }
            },
            addressedParticipants: $addressedParticipants,
            onFocusChanged: { focused in
                bridge.nativeChatInputFocused = focused
            },
            onPlusLongPress: { onShowConsoleLogs() },
            onQuerySlashCommands: bridge.chatInputShowQuickCommands ? { await bridge.getSlashCommands() } : nil,
            onSubmitSlashCommand: bridge.chatInputShowQuickCommands ? { message in handleSlashSubmit(message) } : nil,
            speechProvider: speechProvider,
            onEnterVoiceMode: onEnterVoiceMode == nil ? nil : handleEnterVoiceMode,
            contextStore: bridge.composerContexts,
            contextSessionID: bridge.currentSourceChatId,
            contextOptions: contextOptions
        )
        .onAppear { speechProvider = makeSpeechProvider() }
        .onReceive(NotificationCenter.default.publisher(for: DeviceSpeechCredentials.changed)) { _ in refreshSpeechProvider() }
        .onChange(of: dictationProviderPreference) { _ in refreshSpeechProvider() }
        // The composer is the bottom counterpart to the title bar: pull DOWN
        // from the top or UP from the bottom, both toward the middle, where the
        // grid appears. Same gesture, mirrored — see ScreenSwitcherPullModifier.
        .screenSwitcherPull(
            .up,
            // Not while typing. An upward drag inside a focused text field is
            // text selection, and the keyboard is covering the grid anyway.
            enabled: !bridge.nativeChatInputFocused,
            // Horizontal stays with the field, which owns it for cursor
            // placement and selection.
            allowsHorizontal: false
        )
    }
    #elseif os(macOS)
    private var chatInput: some View {
        NativeChatInput(
            text: $chatMessage,
            imageAttachments: $imageAttachments,
            selectedPhotos: $selectedPhotos,
            isAgentRunning: bridge.isAgentRunning && bridge.pendingUserInteraction == nil && bridge.pendingTextQuestion == nil && bridge.pendingDateQuestion == nil,
            isAgentPaused: bridge.isAgentPaused && !isGroupMode,
            onSubmit: handleSubmit,
            onSubmitNote: BundledAgentRuntime.isEnabled || isGroupMode ? nil : handleNoteSubmit,
            conversationMode: isGroupMode ? "group" : "agent",
            runningSendLabel: isGroupMode ? "Send" : composerActionStore.runningSendLabel(for: bridge.currentSourceChatId),
            composerActions: isGroupMode ? [] : composerActionStore.actions(for: bridge.currentSourceChatId),
            composerActionPending: composerActionPending,
            onComposerAction: handleComposerAction,
            onPause: { Task { await bridge.interruptAgent() } },
            onNewChat: handleNewChat,
            onQuickCommands: bridge.chatInputShowQuickCommands ? onQuickCommands : nil,
            onAddArtefact: BundledAgentRuntime.isEnabled ? nil : {
                if let id = bridge.currentSourceChatId { artefactChatTarget = ArtefactChatTarget(id: id) }
            },
            onAddTodoItem: bridge.chatInputShowTodos ? { bridge.emitTodoItemCreate() } : nil,
            onFetchTodoItems: bridge.chatInputShowTodos ? { await bridge.listTodoItems() } : nil,
            messageHistory: messageHistory,
            chatInputGlassStyle: bridge.chatInputGlassStyle,
            chatInputLayout: bridge.chatInputLayout,
            onQueryFiles: { query in
                let results = await bridge.queryAutocomplete(category: "files", query: query)
                return results.compactMap { dict in
                    guard let path = dict["path"] as? String else { return nil }
                    let isDir = dict["isDirectory"] as? Bool ?? false
                    return FileSuggestion(path: path, isDirectory: isDir)
                }
            },
            onQueryElements: {
                let results = await bridge.queryAutocomplete(category: "ui", query: "")
                return results.compactMap { dict in
                    guard let dataUi = dict["dataUi"] as? String else { return nil }
                    return ElementSuggestion(dataUi: dataUi)
                }
            },
            onQueryParticipants: {
                let dicts = await bridge.queryAutocomplete(category: "people", query: "")
                return dicts.compactMap { dict in
                    guard let id = dict["id"] as? String,
                          let name = dict["name"] as? String else { return nil }
                    let group = dict["group"] as? String
                    return ParticipantSuggestion(id: id, name: name, group: group)
                }
            },
            onQueryBranches: { query in
                let dicts = await bridge.queryAutocomplete(category: "branches", query: query)
                return dicts.compactMap { dict in
                    guard let name = dict["name"] as? String,
                          let token = dict["token"] as? String else { return nil }
                    return BranchSuggestion(
                        id: token,
                        name: name,
                        description: dict["description"] as? String,
                        remote: dict["remote"] as? Bool ?? false,
                        token: token
                    )
                }
            },
            addressedParticipants: $addressedParticipants,
            speechProvider: speechProvider,
            onEnterVoiceMode: onEnterVoiceMode == nil ? nil : handleEnterVoiceMode,
            contextStore: bridge.composerContexts,
            contextSessionID: bridge.currentSourceChatId,
            contextOptions: contextOptions
        )
        .onAppear { speechProvider = makeSpeechProvider() }
        .onReceive(NotificationCenter.default.publisher(for: DeviceSpeechCredentials.changed)) { _ in refreshSpeechProvider() }
        .onChange(of: dictationProviderPreference) { _ in refreshSpeechProvider() }
    }
    #endif

    /// Mic tap (seedFromComposer false) enters voice mode with a live mic;
    /// long-press (true) hands the composer's text to voice mode as the first
    /// utterance. The text is consumed (history + clear) only when voice mode
    /// actually started — a refused start (voice profile off, session already
    /// live) leaves the composer untouched and returns false so the mic can
    /// fall back to dictation.
    private func handleEnterVoiceMode(seedFromComposer: Bool) -> Bool {
        guard let onEnterVoiceMode else { return false }
        let utterance = seedFromComposer
            ? chatMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        guard onEnterVoiceMode(utterance) else { return false }
        if !utterance.isEmpty {
            recordHistory(utterance)
            chatMessage = ""
        }
        return true
    }

    /// Dictation provider for the composer mic, resolved from
    /// SpeechPreferences ("apple" default, "elevenlabs" via worker routes).
    /// Returned as Any? because the speech layer is @available(26+) while
    /// the SDK floor is lower; the composer unwraps it behind #available.
    private func refreshSpeechProvider() {
        if #available(iOS 26.0, macOS 26.0, *) {
            (speechProvider as? any NativeSpeechProviding)?.stopTranscription()
        }
        speechProvider = makeSpeechProvider()
    }

    private func makeSpeechProvider() -> Any? {
        if #available(iOS 26.0, macOS 26.0, *) {
            return NativeSpeechProviderFactory.dictation(tokenProvider: {
                self.tokenProvider?() ?? (BundledAgentRuntime.isEnabled ? nil : MachineTokenStore.token)
            })
        }
        return nil
    }

    // MARK: Submit handlers

    private func handleSubmit() {
        let message = chatMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if isGroupMode {
            guard !composerActionPending, let chatId = bridge.currentSourceChatId,
                  !message.isEmpty || !imageAttachments.isEmpty || !bridge.composerContexts.attachments(for: chatId).isEmpty else { return }
            let originalText = chatMessage
            let images = imageAttachments
            let addressed = addressedParticipants
            composerActionPending = true
            Task {
                let accepted = await bridge.submitMessage(message,
                    imageAttachments: images.isEmpty ? nil : images.map { $0.toDictionary() },
                    addressedTo: addressed.isEmpty ? nil : addressed)
                composerActionPending = false
                guard bridge.currentSourceChatId == chatId else { return }
                if accepted {
                    recordHistory(message)
                    if chatMessage == originalText { chatMessage = ""; addressedParticipants = [] }
                    imageAttachments.removeAll { image in images.contains { $0.id == image.id } }
                    selectedPhotos = []
                } else { composerActionError = "Message delivery was not confirmed. Your draft has been kept." }
            }
            return
        }
        if bridge.isAgentPaused && !isGroupMode {
            let addressed = addressedParticipants
            chatMessage = ""
            imageAttachments = []
            selectedPhotos = []
            addressedParticipants = []
            if message.isEmpty && bridge.composerContexts.attachments(for: bridge.currentSourceChatId).isEmpty {
                Task { await bridge.resumeAgent() }
            } else {
                recordHistory(message)
                Task {
                    await bridge.submitMessage(
                        message,
                        imageAttachments: nil,
                        addressedTo: addressed.isEmpty ? nil : addressed
                    )
                }
            }
        } else {
            guard !message.isEmpty || !imageAttachments.isEmpty || !bridge.composerContexts.attachments(for: bridge.currentSourceChatId).isEmpty else { return }
            if !message.isEmpty { recordHistory(message) }
            let images = imageAttachments
            let addressed = addressedParticipants
            chatMessage = ""
            imageAttachments = []
            selectedPhotos = []
            addressedParticipants = []
            Task {
                let imgDicts: [[String: String]]? = images.isEmpty ? nil : images.map { $0.toDictionary() }
                await bridge.submitMessage(
                    message,
                    imageAttachments: imgDicts,
                    addressedTo: addressed.isEmpty ? nil : addressed
                )
            }
        }
        #if os(iOS)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }

    private func handleComposerAction(_ action: String) {
        guard !composerActionPending, let chatId = bridge.currentSourceChatId else { return }
        let message = chatMessage
        let images = imageAttachments
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty || !bridge.composerContexts.attachments(for: chatId).isEmpty else { return }
        guard addressedParticipants.isEmpty else {
            composerActionError = "Steering updates the current agent. Remove the participant selection or send a follow-up."
            return
        }
        composerActionPending = true
        Task {
            let error = await bridge.submitComposerAction(chatId: chatId, action: action, text: message,
                imageAttachments: images.isEmpty ? nil : images.map { $0.toDictionary() })
            composerActionPending = false
            guard bridge.currentSourceChatId == chatId else { return }
            if let error { composerActionError = error; return }
            recordHistory(message)
            if chatMessage == message { chatMessage = "" }
            imageAttachments.removeAll { image in images.contains { $0.id == image.id } }
            if imageAttachments.isEmpty { selectedPhotos = [] }
        }
    }

    private func handleNoteSubmit() {
        let message = chatMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        recordHistory(message)
        chatMessage = ""
        Task { await bridge.submitNote(message) }
        #if os(iOS)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }

    /// Submit a slash command picked from the native slash menu ("/cmd" or
    /// "/cmd option"). Same path as QuickCommandsSheet — the web app executes it.
    private func handleSlashSubmit(_ message: String) {
        recordHistory(message)
        chatMessage = ""
        Task { await bridge.submitMessage(message) }
        #if os(iOS)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }

    private func handleNewChat() {
        chatMessage = ""
        imageAttachments = []
        selectedPhotos = []
        Task {
            await bridge.startNewChat()
        }
    }

    private func recordHistory(_ message: String) {
        messageHistory.record(message)
    }
}
