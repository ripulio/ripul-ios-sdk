import SwiftUI

/// One-view drop-in developer console: sign-in gate + native session list +
/// embedded chat, all sharing a single `AgentBridge`.
///
/// A host embeds this behind a dev-only gate. The developer signs into their own
/// Ripul (Clerk) account (isolated via the configuration's `websiteDataStore` +
/// `cache`), the native list shows their paired host Macs and sessions, and
/// selecting/connecting one drives Claude on that Mac in the embedded chat.
///
/// Composition:
/// - The chat `AgentView` is always mounted so the shared bridge has a live web
///   view — that web view is what the auth store polls for the Clerk token and
///   what the relay connection runs through. It's hidden until signed in.
/// - `RipulSessionsView` overlays the chat when signed in and not viewing a chat.
/// - Sign-in gate (matches the native app): a **returning** user (persisted
///   `wasPreviouslySignedIn`) gets a brief "Reconnecting" splash while the poller
///   restores the token from the shared data store's Clerk cookies — NOT the
///   sign-in prompt. Only a genuinely signed-out user sees `RipulSignInView`.
@available(iOS 26.0, macOS 26.0, *)
public struct RipulAgentConsole: View {
    private let configuration: RipulSessionsConfiguration
    @StateObject private var bridge = AgentBridge()
    @StateObject private var authStore: RipulClerkAuthStore
    @State private var showingChat = false
    /// Set when the user explicitly asks to sign in from the reconnect splash
    /// (e.g. to use a different account) — forces the sign-in view over the
    /// returning-user reconnect path.
    @State private var forceSignIn = false
    /// DevTools console sheet (ConsoleLogViewer), opened by long-pressing the
    /// session list's title lozenge.
    @State private var showDevTools = false
    @Namespace private var topBarNS
    @State private var renamingSession: ChatSession? = nil
    @State private var renameText = ""

    public init(configuration: RipulSessionsConfiguration) {
        self.configuration = configuration
        _authStore = StateObject(wrappedValue: RipulClerkAuthStore(cache: configuration.cache))
    }

    private var agentConfig: AgentConfiguration {
        var config = AgentConfiguration(baseURL: configuration.baseURL)
        config.siteKey = configuration.siteKey
        config.websiteDataStore = configuration.websiteDataStore
        config.theme = configuration.theme
        return config
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                // Chat surface — always mounted (bridge web view = relay + Clerk
                // token source). Hidden until signed in.
                AgentView(configuration: agentConfig, bridge: bridge) { _ in EmptyView() }
                    .opacity(authStore.isSignedIn ? 1 : 0)

                if authStore.isSignedIn {
                    // Session list — overlays the chat when not viewing a chat.
                    // Explicit top padding keeps its content out of the status bar /
                    // notch when the host renders the console full-bleed (WAC's
                    // overlay window ignores the safe area); background stays
                    // full-bleed opaque. (safeAreaInset does not reliably re-assert
                    // the safe area under an ignoresSafeArea parent.)
                    if !showingChat {
                        RipulSessionsView(
                            bridge: bridge,
                            cache: configuration.cache,
                            tokenProvider: { authStore.token },
                            onSelectSession: { session in select(session) },
                            onDismiss: { showingChat = true },
                            allowRipulAgents: configuration.allowRipulAgents,
                            invitesSection: configuration.invitesSection,
                            foldersSection: configuration.foldersSection,
                            emptyStateOverride: configuration.emptyStateOverride
                        )
                        // Extra padding so the list content clears the floating
                        // top bar (status-bar inset + 58pt bar height + 4pt gap).
                        .padding(.top, geo.safeAreaInsets.top + 62)
                        .background(.background)
                        .transition(.opacity)
                    }
                } else if authStore.wasPreviouslySignedIn && !forceSignIn {
                    // Returning user: reconnect to the persisted Clerk session (the
                    // poller restores the token from the shared data store) rather
                    // than re-prompting for sign-in.
                    reconnectingSplash
                } else {
                    // Genuinely signed out (or "use a different account").
                    RipulSignInView(
                        authToken: authStore,
                        bridge: bridge,
                        dataStore: configuration.websiteDataStore,
                        baseURL: configuration.baseURL
                    )
                }
            }
            .task {
                // Dev-assistant tools: logs + native screen inspection. Registered on
                // the console's own bridge so the agent driving from here can read logs
                // and `inspect_screen` the host app (which excludes this overlay).
                bridge.registerBuiltInTools([
                    ConsoleLogsTool(bridge: bridge),
                    NetworkLogsTool(bridge: bridge),
                    InspectScreenTool(bridge: bridge),
                ])
                authStore.startPolling(bridge: bridge)
                logWebBuildVersion()
            }
            .onChange(of: authStore.isSignedIn) { _, signedIn in
                if signedIn { forceSignIn = false }
            }
            .onReceive(NotificationCenter.default.publisher(for: .ripulShowDevTools)) { _ in
                showDevTools = true
            }
            .sheet(isPresented: $showDevTools) {
                NavigationStack {
                    ConsoleLogViewer(bridge: bridge)
                        .toolbar {
                            #if os(iOS)
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { showDevTools = false }
                            }
                            #else
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showDevTools = false }
                            }
                            #endif
                        }
                }
            }
            .sheet(item: $renamingSession) { _ in renameSheet }
            .animation(.easeInOut(duration: 0.25), value: authStore.isSignedIn)
            .animation(.easeInOut(duration: 0.25), value: showingChat)
            .overlay(alignment: .top) {
                if authStore.isSignedIn {
                    agentTopBarOverlay
                }
            }
        }
    }

    // MARK: - Top bar

    /// Full unified top bar — mirrors AgentScreen.topBarOverlay.
    /// Shown whenever the user is signed in; content morphs between the
    /// session-list state (!showingChat) and the chat state (showingChat).
    @ViewBuilder private var agentTopBarOverlay: some View {
        let showHeader = !showingChat || bridge.currentPageContext.showNativeHeader
        if showHeader {
            let session = bridge.sessions.first(where: { $0.id == bridge.activeSessionId })
            ZStack(alignment: .top) {
                ConsoleTopBarBackground()
                #if os(iOS)
                if #available(iOS 26.0, *) {
                    GlassEffectContainer {
                        ConsoleTopBarContent(
                            bridge: bridge,
                            showingChat: showingChat,
                            session: session,
                            onBack: {
                                if bridge.fileViewerTitle != nil {
                                    bridge.requestFileViewerClose()
                                } else {
                                    withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
                                        showingChat = false
                                    }
                                }
                            },
                            ns: topBarNS,
                            menu: { topBarMenu(session: session) }
                        )
                    }
                } else {
                    ConsoleTopBarContent(
                        bridge: bridge,
                        showingChat: showingChat,
                        session: session,
                        onBack: {
                            if bridge.fileViewerTitle != nil {
                                bridge.requestFileViewerClose()
                            } else {
                                withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
                                    showingChat = false
                                }
                            }
                        },
                        ns: topBarNS,
                        menu: { topBarMenu(session: session) }
                    )
                }
                #else
                ConsoleTopBarContent(
                    bridge: bridge,
                    showingChat: showingChat,
                    session: session,
                    onBack: {
                        if bridge.fileViewerTitle != nil {
                            bridge.requestFileViewerClose()
                        } else {
                            withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
                                showingChat = false
                            }
                        }
                    },
                    ns: topBarNS,
                    menu: { topBarMenu(session: session) }
                )
                #endif
            }
        }
    }

    /// Context-sensitive trailing menu items — mirrors AgentScreen's
    /// sessionListMenuItems (list) and agentMenuItems (chat).
    @ViewBuilder private func topBarMenu(session: ChatSession?) -> some View {
        if showingChat && bridge.fileViewerTitle == nil {
            // ── Chat menu ──
            Button {
                Task {
                    _ = await bridge.createNewChat()
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
                        showingChat = false
                    }
                }
            } label: {
                Label("New Chat", systemImage: "plus.message")
            }
            .uiKitIdentifier("AgentScreen.contextMenu.newChatButton")

            if let session {
                Button {
                    renameText = session.displayName
                    renamingSession = session
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .uiKitIdentifier("AgentScreen.contextMenu.renameButton")
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

        } else if bridge.fileViewerTitle != nil {
            // ── File viewer menu ──
            Button {
                bridge.fileViewerToggleWordWrap()
            } label: {
                Label("Toggle Word Wrap", systemImage: "text.word.spacing")
            }
            .uiKitIdentifier("AgentScreen.fileViewer.menu.wordWrapButton")

            if bridge.fileViewerIsMarkdown {
                Button {
                    bridge.fileViewerToggleRaw()
                } label: {
                    Label("Toggle Raw", systemImage: "doc.plaintext")
                }
                .uiKitIdentifier("AgentScreen.fileViewer.menu.toggleRawButton")
            }

        } else {
            // ── Session list menu ──
            Button {
                NotificationCenter.default.post(name: .ripulShowDevTools, object: nil)
            } label: {
                Label("Console Logs", systemImage: "doc.text.magnifyingglass")
            }
            .uiKitIdentifier("AgentScreen.listMenu.consoleLogsButton")
        }
    }

    /// Rename sheet — shown when `renamingSession` is set from the context menu.
    @ViewBuilder private var renameSheet: some View {
        NavigationStack {
            Form {
                Section("Session name") {
                    TextField("Name", text: $renameText)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle("Rename")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { renamingSession = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let session = renamingSession {
                            bridge.renameSession(
                                id: session.id,
                                sourceChatId: session.id,
                                displayName: renameText
                            )
                        }
                        renamingSession = nil
                    }
                    .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    /// Focus the tapped session in the web app BEFORE revealing the chat, exactly
    /// like the native app's session list — without this the chat shows whatever
    /// default tab the web app had (a fresh "new agent" screen) instead of the
    /// session that was just opened/imported. Skips focusSession when the chat is
    /// already the active tab (its web-side focus handshake stalls on an
    /// already-rendered chat — see the native app's SessionListScreen).
    private func select(_ session: ChatSession) {
        if bridge.activeSessionId == session.id {
            showingChat = true
            return
        }
        Task { @MainActor in
            await bridge.focusSession(id: session.id)
            showingChat = true
        }
    }

    /// Logs the embedded web app's bundle version + the LIVE/STALE verdict
    /// through the NATIVE log path (bridge.handleConsoleLog), so the DevTools
    /// console always shows which web build is running. The web app's own
    /// `[RIPUL] build=` boot line is a console.log, which its ConsoleWrapper
    /// suppresses in production — it never reaches the native buffer.
    private func logWebBuildVersion() {
        Task { @MainActor in
            for _ in 0..<60 {
                if bridge.isConnected { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard bridge.isConnected else { return }
            let running = (try? await bridge.callAsyncJavaScript(
                "return window.__ripulBuildVersion || 'unknown';"
            )) as? String ?? "unknown"

            var deployed: String?
            if let url = URL(string: "version.json", relativeTo: configuration.baseURL),
               let (data, _) = try? await URLSession.shared.data(from: url),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                deployed = json["version"] as? String
            }

            let verdict: String
            if let deployed {
                verdict = running == deployed ? "LIVE ✓" : "STALE ✗"
            } else {
                verdict = "deployed=?"
            }
            bridge.handleConsoleLog("[RIPUL] web build=\(running) deployed=\(deployed ?? "?") \(verdict) (native read)")
        }
    }

    private var reconnectingSplash: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Reconnecting…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Sign in with a different account") { forceSignIn = true }
                .font(.footnote)
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .uiKitIdentifier("RipulAgentConsole.reconnect.signIn")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .transition(.opacity)
    }
}
