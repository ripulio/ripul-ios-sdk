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
    /// Macro library sheet (docs/plans/automation-macros/phase-4-…), opened
    /// by `.ripulShowMacroLibrary` posts — same pattern as `showDevTools`.
    @State private var showMacroLibrary = false

    private let slots: RipulAgentScreenSlots
    /// CRUD for recorded macros (docs/plans/automation-macros/). Owns no
    /// state of its own beyond the token closure — safe to construct once
    /// in `init` alongside `listModel`.
    private let macroClient: RipulMacroClient

    /// - Parameter bridge: optional externally-owned bridge, which MUST be a
    ///   `.developer`-audience bridge built on the configuration's registry
    ///   (`AgentBridge(registry: configuration.registry, audience: .developer)`).
    ///   Pass one when the host needs the same connection elsewhere (e.g. the
    ///   dev-assistant overlay's compact bar, which mirrors the active chat).
    ///   Default: the console creates its own `.developer` bridge.
    public init(
        configuration: RipulSessionsConfiguration,
        slots: RipulAgentScreenSlots = .init(),
        bridge: AgentBridge? = nil
    ) {
        self.configuration = configuration
        self.slots = slots
        let authStore = RipulClerkAuthStore(cache: configuration.cache)
        _authStore = StateObject(wrappedValue: authStore)
        self.macroClient = RipulMacroClient(baseURL: configuration.baseURL, tokenProvider: { authStore.token })
        let bridge = bridge ?? AgentBridge(registry: configuration.registry, audience: .developer)
        assert(
            bridge.audience == .developer,
            "RipulAgentConsole requires a .developer-audience AgentBridge — construct the " +
            "passed-in bridge with AgentBridge(registry: configuration.registry, audience: .developer), " +
            "or omit `bridge:` to let the console create its own. An .endUser bridge here " +
            "would silently refuse this console's own dev tools."
        )
        assert(
            bridge.registry === configuration.registry,
            "RipulAgentConsole's bridge must project from the SAME registry as its " +
            "configuration — otherwise the editor and the agent see different tool sets."
        )
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
            // The console's CHANNEL-BOUND tools, in one replacing call:
            // logs + native screen inspection (so the agent driving from here
            // can SEE the running app) plus tool-collection CRUD (the peer of
            // the editor screen; enabled unconditionally because the console
            // is already a signed-in, dev-gated surface).
            //
            // One call, replacement semantics — `.task` re-runs when this view
            // disappears and returns (e.g. embedded in a TabView), and a
            // repeated name in the MCP tool set reads as a change to the
            // bridge's tool-set watcher and can loop `tools/list_changed`.
            //
            // Host-contributed dev tools are NOT registered here: they are
            // developer-tagged entries in `configuration.registry`, which this
            // `.developer` channel already projects.
            bridge.registerBuiltInTools([
                ConsoleLogsTool(bridge: bridge),
                NetworkLogsTool(bridge: bridge),
                InspectScreenTool(bridge: bridge),
                TapElementTool(),
                TypeTextTool(),
                ScrollElementTool(),
                WaitForElementTool(),
                ExplorerProbeTool(),
            ] + RipulDevToolCollectionTools.all(
                isEnabled: true,
                catalogs: { [configuration, bridge] in
                    configuration.registry.editorCatalogs()
                        + [.developer(bridge.registeredToolSummaries)]
                },
                baseURL: configuration.baseURL,
                tokenProvider: { authStore.token }
            ))
            // Automation macros (docs/plans/automation-macros/phase-4-…):
            // the View Explorer stays host-agnostic (its own design
            // principle) — this is what turns a finished recording into
            // something persisted and, once published, agent-callable.
            // Overwrites any host-set closure on THIS console's attach, same
            // replacement semantics as registerBuiltInTools above.
            RipulViewExplorer.macroRecordedAction = { [macroClient] macro in
                Task { @MainActor in
                    do {
                        _ = try await macroClient.create(macro)
                    } catch {
                        NSLog("[RIPUL_MACROS] failed to persist recorded macro '%@': %@", macro.name, error.localizedDescription)
                    }
                    await refreshMacroTools()
                    // Recorded from the library's "Record new" button → bring
                    // the user back to the library (with the new macro listed)
                    // on their next console expand.
                    if MacroDeepLink.pendingLibraryOpen {
                        MacroDeepLink.pendingLibraryOpen = false
                        NotificationCenter.default.post(name: .ripulShowMacroLibrary, object: nil)
                    }
                }
            }
            await refreshMacroTools()
            authStore.startPolling(bridge: bridge)
            logWebBuildVersion()
            if authStore.isSignedIn { fetchSeededContexts() }
        }
        .onChange(of: authStore.isSignedIn) { _, signedIn in
            if signedIn {
                forceSignIn = false
                fetchSeededContexts()
            }
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
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ripulShowMacroLibrary)) { _ in
            showMacroLibrary = true
        }
        .sheet(isPresented: $showMacroLibrary) {
            MacroLibraryScreen(client: macroClient, onChange: { Task { await refreshMacroTools() } })
        }
        .animation(.easeInOut(duration: 0.25), value: authStore.isSignedIn)
    }

    /// Fetch → dedup → partition → register (docs/plans/automation-macros/
    /// phase-4-…): `.developer` for drafts (immediately console-testable),
    /// `.endUser` for published ones (reachable by the host's real end-user
    /// agent). Safe to call repeatedly — `setTools` replaces each audience's
    /// entries wholesale, so re-registering after a publish/unpublish/delete
    /// takes effect in the SAME session, no restart (deliberately unlike
    /// tool_collections' restart-only model — see README decision #5).
    private func refreshMacroTools() async {
        await MacroRegistrySync.refresh(client: macroClient, registry: configuration.registry)
    }

    /// Console bootstrap (native-tool-registry phase 3): idempotently ensure
    /// this account's seeded `User`/`Developer` contexts exist server-side and
    /// cache the Developer id — that is how it reaches the web view URL
    /// (`RipulAgentScreen.agentConfig`) without being hardcoded, and how
    /// accounts that predate seeding get their pair lazily on first console
    /// touch. The token can lag `isSignedIn` by a poll cycle, so retry briefly.
    private func fetchSeededContexts() {
        Task {
            var token = authStore.token
            for _ in 0..<10 where token == nil {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                token = authStore.token
            }
            guard let token,
                  let url = URL(string: "api/admin/solution-contexts/seeded", relativeTo: configuration.baseURL)
            else { return }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let devContextId = json["devContextId"] as? String
            else { return }
            configuration.cache.set(devContextId, forKey: RipulSeededContextCache.devContextIdKey)
            bridge.handleConsoleLog("[SELFTEST] seeded dev context cached: \(devContextId)")
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
        RipulBrandedLoadingView(
            status: "Reconnecting…",
            action: (title: "Sign in with a different account", handler: { forceSignIn = true })
        )
    }
}
#endif
