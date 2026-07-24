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
                        .padding(.top, geo.safeAreaInsets.top)
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
            .animation(.easeInOut(duration: 0.25), value: authStore.isSignedIn)
            .animation(.easeInOut(duration: 0.25), value: showingChat)
            .overlay(alignment: .topLeading) {
                // Back-to-list control while viewing a chat — padded below the
                // physical safe area (the host may render the console full-bleed).
                if authStore.isSignedIn && showingChat {
                    Button {
                        showingChat = false
                    } label: {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 40, height: 40)
                    }
                    .modifier(GlassCircleModifier(glassStyle: "regular"))
                    .buttonStyle(.plain)
                    .padding(.top, geo.safeAreaInsets.top + 8)
                    .padding(.leading, 12)
                    .uiKitIdentifier("RipulAgentConsole.backToList")
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
