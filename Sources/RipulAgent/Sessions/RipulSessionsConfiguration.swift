import SwiftUI
import WebKit

/// Configuration for the drop-in `RipulAgentConsole` (and the pieces it composes).
///
/// A host (e.g. a third-party app's developer tool) constructs this with an
/// isolated cache suite and a dedicated `websiteDataStore` so the developer's
/// Ripul/Clerk session is kept separate from the host's own web content.
public struct RipulSessionsConfiguration {
    /// Backend + web-app origin. Drives the relay API and the embedded web view.
    public var baseURL: URL
    /// Public site key for embedded/site-key mode. Leave `nil` for the developer
    /// console (the developer signs into their own Ripul account via Clerk).
    public var siteKey: String?
    /// Isolated storage for all session-list caches (machines, sessions,
    /// last-active, icons, auth flags). Pass a private suite so keys never
    /// collide with the host app's own defaults.
    public var cache: RipulSessionCache
    /// Data store shared by the chat web view AND the sign-in web view, so the
    /// developer's Clerk cookies propagate between them and stay isolated from
    /// any other web content in the host app.
    public var websiteDataStore: WKWebsiteDataStore
    /// Theme passthrough for the embedded chat.
    public var theme: AgentTheme
    /// Whether the "New Ripul Agent" tile is offered on online machines.
    public var allowRipulAgents: Bool
    /// Whether host-defined quick actions are discovered/executed on machine
    /// rows (the first-party app: on; a dev console: off).
    public var quickActionsEnabled: Bool
    /// THE HOST'S TOOL REGISTRY — every native tool, registered once, tagged
    /// by audience (native-tool-registry phase 1).
    ///
    /// The console's `.developer` channel exposes the registry's
    /// developer-tagged entries (a host contributes dev-assistant tools with
    /// `registry.register(RipulDevThemeTools.all(...), audience: .developer)`),
    /// and the tool-collections editor reads the same registry for every
    /// surface — so what the editor organises and what each agent can call can
    /// no longer drift apart. End-user-tagged entries are NOT exposed here:
    /// they belong to the host's own agent panel (`AgentView(registry:)`), and
    /// phase 2's explicit testing mode is the only way this console borrows
    /// them.
    ///
    /// Pass the SAME registry instance to `AgentView` and this configuration.
    /// WAC registers `WACNativeTools.endUser` as `.endUser` and its theme dev
    /// tools as `.developer`.
    public var registry: RipulToolRegistry
    /// Offer site-key ↔ context assignment in Solution management. The
    /// first-party Ripul app (the platform admin surface) sets this; an
    /// ordinary SDK host leaves it off — its developer curates contexts and
    /// collections, but binding them to keys is a platform-admin act. The API
    /// gates it independently; this only decides whether the row is offered.
    public var showsSiteKeyAdmin: Bool
    /// Optional app-injected panels (nil = omitted).
    public var invitesSection: (() -> AnyView)?
    public var foldersSection: (() -> AnyView)?
    public var emptyStateOverride: (() -> AnyView)?

    public init(
        cache: RipulSessionCache,
        baseURL: URL = AgentConfiguration.defaultBaseURL,
        siteKey: String? = nil,
        websiteDataStore: WKWebsiteDataStore = .default(),
        theme: AgentTheme = .system,
        allowRipulAgents: Bool = false,
        quickActionsEnabled: Bool = false,
        registry: RipulToolRegistry = RipulToolRegistry(),
        showsSiteKeyAdmin: Bool = false,
        invitesSection: (() -> AnyView)? = nil,
        foldersSection: (() -> AnyView)? = nil,
        emptyStateOverride: (() -> AnyView)? = nil
    ) {
        self.cache = cache
        self.baseURL = baseURL
        self.siteKey = siteKey
        self.websiteDataStore = websiteDataStore
        self.theme = theme
        self.allowRipulAgents = allowRipulAgents
        self.quickActionsEnabled = quickActionsEnabled
        self.registry = registry
        self.showsSiteKeyAdmin = showsSiteKeyAdmin
        self.invitesSection = invitesSection
        self.foldersSection = foldersSection
        self.emptyStateOverride = emptyStateOverride
    }
}
