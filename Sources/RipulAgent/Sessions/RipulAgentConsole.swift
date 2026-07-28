#if os(iOS)
import SwiftUI

/// One-view drop-in developer console: sign-in gate + the whole Ripul agent
/// screen (`RipulAgentScreen`), all sharing a single `AgentBridge`.
///
/// A host embeds this behind a dev-only gate. The developer signs into their own
/// Ripul (Clerk) account (isolated via the configuration's `websiteDataStore` +
/// `cache`), the native list shows their paired host Macs and sessions, and
/// selecting/connecting one drives Claude on that Mac in the embedded chat —
/// with the exact UI of the first-party Ripul app.
///
/// Composition:
/// - The screen is always mounted so the shared bridge has a live web view —
///   that web view is what the auth store polls for the Clerk token and what
///   the relay connection runs through. It's hidden until signed in.
/// - Sign-in gate (matches the native app): a **returning** user (persisted
///   `wasPreviouslySignedIn`) gets a brief "Reconnecting" splash while the poller
///   restores the token from the shared data store's Clerk cookies — NOT the
///   sign-in prompt. Only a genuinely signed-out user sees `RipulSignInView`.
/// - DevTools: the screen posts `.ripulShowDevTools` (title-lozenge long-press,
///   "Console Logs" menu items); the console presents `ConsoleLogViewer`
///   directly, NOT via `.ripulDevTools()` — that modifier's `onAppear`
///   re-registers built-in tools and would clobber the console's
///   `InspectScreenTool` registration.
///
/// iOS-only: the screen it wraps is the iPhone agent screen. The macOS app's
/// screen is a separate layout (a future milestone can port it the same way).
@available(iOS 26.0, *)
public struct RipulAgentConsole: View {
    private let configuration: RipulSessionsConfiguration
    @StateObject private var bridge: AgentBridge
    @StateObject private var authStore: RipulClerkAuthStore
    @StateObject private var listModel: RipulSessionListModel
    /// Set when the user explicitly asks to sign in from the reconnect splash
    /// (e.g. to use a different account) — forces the sign-in view over the
    /// returning-user reconnect path.
    @State private var forceSignIn = false
    /// DevTools console sheet (ConsoleLogViewer), opened by the screen's
    /// `.ripulShowDevTools` posts.
    @State private var showDevTools = false
    /// One-shot guard for the additively-registered collection tools.
    @State private var didRegisterCollectionTools = false

    /// Tool surfaces the host owns, for the collections editor to organise.
    /// Empty `endUserTools` yields no end-user catalog rather than an empty
    /// one — a picker offering a surface with nothing in it is worse than not
    /// offering it.
    private var hostToolCatalogs: [RipulToolCatalog] {
        var catalogs: [RipulToolCatalog] = []
        if !configuration.endUserTools.isEmpty {
            catalogs.append(.endUser(configuration.endUserTools))
        }
        catalogs.append(contentsOf: configuration.toolCatalogs)
        return catalogs
    }

    private let slots: RipulAgentScreenSlots

    /// - Parameter bridge: optional externally-owned bridge. Pass one when the
    ///   host needs the same connection elsewhere (e.g. the dev-assistant
    ///   overlay's compact bar, which mirrors the active chat). Default: the
    ///   console creates and owns its bridge.
    public init(
        configuration: RipulSessionsConfiguration,
        slots: RipulAgentScreenSlots = .init(),
        bridge: AgentBridge? = nil
    ) {
        self.configuration = configuration
        self.slots = slots
        let authStore = RipulClerkAuthStore(cache: configuration.cache)
        _authStore = StateObject(wrappedValue: authStore)
        let bridge = bridge ?? AgentBridge()
        _bridge = StateObject(wrappedValue: bridge)
        _listModel = StateObject(wrappedValue: RipulSessionListModel(
            bridge: bridge,
            tokenProvider: { authStore.token },
            cache: configuration.cache
        ))
    }

    public var body: some View {
        ZStack {
            // Agent screen — always mounted (its web view = relay + Clerk token
            // source). Hidden until signed in.
            RipulAgentScreen(
                bridge: bridge,
                model: listModel,
                configuration: configuration,
                tokenProvider: { authStore.token },
                slots: slots
            )
            .opacity(authStore.isSignedIn ? 1 : 0)
            .allowsHitTesting(authStore.isSignedIn)

            if !authStore.isSignedIn {
                if authStore.wasPreviouslySignedIn && !forceSignIn {
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
        }
        .task {
            // Dev-assistant tools: logs + native screen inspection. Registered on
            // the console's own bridge so the agent driving from here can read logs
            // and `inspect_screen` the host app (which excludes this overlay).
            bridge.registerBuiltInTools([
                ConsoleLogsTool(bridge: bridge),
                NetworkLogsTool(bridge: bridge),
                InspectScreenTool(bridge: bridge),
                TapElementTool(),
                TypeTextTool(),
                ScrollElementTool(),
            ])
            // Host-contributed dev tools, registered ADDITIVELY via `register` rather than
            // `registerBuiltInTools` — the latter REPLACES the built-in list, which is how
            // `.ripulDevTools()` used to clobber InspectScreenTool.
            //
            // Without this slot a host app has no way to give the dev assistant tools: its
            // own registry goes to the end-user agent panel, which is a DIFFERENT bridge.
            // That gap is easy to miss, because both surfaces are "the app's tools".
            if !configuration.devTools.isEmpty {
                bridge.register(configuration.devTools)
            }
            // Tool-collection CRUD for the agent, the peer of the editor screen.
            // Enabled unconditionally because the console is already a
            // signed-in, dev-gated surface.
            //
            // `register` APPENDS, and `.task` re-runs if this view disappears
            // and returns (e.g. embedded in a TabView), so this is guarded.
            // Duplicate tool names are not cosmetic here: a repeated name in
            // the MCP tool set reads as a change to the bridge's tool-set
            // watcher and can loop `tools/list_changed`.
            if !didRegisterCollectionTools {
                didRegisterCollectionTools = true
                bridge.register(RipulDevToolCollectionTools.all(
                    isEnabled: true,
                    catalogs: { [configuration, bridge] in
                        var all: [RipulToolCatalog] = []
                        if !configuration.endUserTools.isEmpty {
                            all.append(.endUser(configuration.endUserTools))
                        }
                        all.append(contentsOf: configuration.toolCatalogs)
                        all.append(.developer(bridge.registeredToolSummaries))
                        return all
                    },
                    baseURL: configuration.baseURL,
                    tokenProvider: { authStore.token }
                ))
            }
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
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showDevTools = false }
                        }
                    }
                    // Unlocks the Tool Collections entry in the DevTools Tools
                    // tab. Injected here rather than inside the viewer because
                    // this is the surface that guarantees a signed-in developer.
                    .environment(
                        \.ripulToolCollectionsAccess,
                        RipulToolCollectionsAccess(
                            tokenProvider: { authStore.token },
                            // The host's own surfaces. `endUserTools` is
                            // declared, NOT registered — those tools belong to
                            // the app's agent panel on a different bridge, and
                            // registering them here would hand end-user
                            // capabilities to the dev agent.
                            hostCatalogs: hostToolCatalogs
                        )
                    )
            }
        }
        .animation(.easeInOut(duration: 0.25), value: authStore.isSignedIn)
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
        RipulBrandedLoadingView(
            status: "Reconnecting…",
            action: (title: "Sign in with a different account", handler: { forceSignIn = true })
        )
    }
}
#endif
