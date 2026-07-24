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
        ZStack {
            // Chat surface — always mounted (bridge web view = relay + Clerk
            // token source). Hidden until signed in.
            AgentView(configuration: agentConfig, bridge: bridge) { _ in EmptyView() }
                .opacity(authStore.isSignedIn ? 1 : 0)

            if authStore.isSignedIn {
                // Session list — overlays the chat when not viewing a chat.
                if !showingChat {
                    RipulSessionsView(
                        bridge: bridge,
                        cache: configuration.cache,
                        tokenProvider: { authStore.token },
                        onSelectSession: { _ in showingChat = true },
                        onDismiss: { showingChat = true },
                        allowRipulAgents: configuration.allowRipulAgents,
                        invitesSection: configuration.invitesSection,
                        foldersSection: configuration.foldersSection,
                        emptyStateOverride: configuration.emptyStateOverride
                    )
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
        }
        .onChange(of: authStore.isSignedIn) { _, signedIn in
            if signedIn { forceSignIn = false }
        }
        .animation(.easeInOut(duration: 0.25), value: authStore.isSignedIn)
        .animation(.easeInOut(duration: 0.25), value: showingChat)
        .overlay(alignment: .topLeading) {
            // Back-to-list control while viewing a chat.
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
                .padding(.top, 8)
                .padding(.leading, 12)
                .uiKitIdentifier("RipulAgentConsole.backToList")
            }
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
