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
/// - `RipulSignInView` (its own web view, same data store → shared cookies)
///   gates until a Clerk session exists.
@available(iOS 26.0, macOS 26.0, *)
public struct RipulAgentConsole: View {
    private let configuration: RipulSessionsConfiguration
    @StateObject private var bridge = AgentBridge()
    @StateObject private var authStore: RipulClerkAuthStore
    @State private var showingChat = false

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

            // Session list — overlays the chat when signed in and not in a chat.
            if authStore.isSignedIn && !showingChat {
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

            // Sign-in gate.
            if !authStore.isSignedIn {
                RipulSignInView(
                    authToken: authStore,
                    bridge: bridge,
                    dataStore: configuration.websiteDataStore,
                    baseURL: configuration.baseURL
                )
            }
        }
        .task { authStore.startPolling(bridge: bridge) }
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
}
