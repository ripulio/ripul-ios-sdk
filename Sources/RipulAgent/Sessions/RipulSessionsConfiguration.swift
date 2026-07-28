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
    /// HOST-CONTRIBUTED DEV TOOLS for the console's agent.
    ///
    /// The console registers its own built-ins (`console_logs`, `network_logs`,
    /// `inspect_screen`) so the developer driving from here can SEE the running app.
    /// These are the host app's contribution — tools that let that agent also ACT on it
    /// (set a theme knob, report the running build, tap a control).
    ///
    /// They are registered ADDITIVELY, so they neither replace nor are replaced by the
    /// console's built-ins. Note this is the DEV-assistant surface: it is deliberately
    /// separate from the host's end-user agent panel and its tools, which live on a
    /// different bridge. A host that wants a tool in both places passes it to both.
    public var devTools: [NativeTool]
    /// THE HOST'S END-USER TOOL SURFACE — what its users' agent can call.
    ///
    /// Declared here purely so the tool-collections editor can organise it. The
    /// console does NOT register these; they belong to the host's own agent
    /// panel on a different bridge, and registering them here would put
    /// end-user capabilities in the dev agent's hands.
    ///
    /// Without this, the editor can only see the console's own bridge — the
    /// developer surface — and reports every end-user tool as missing. That is
    /// exactly backwards: the end-user surface is the one whose context window
    /// real users pay for, so it is the one most worth grouping.
    ///
    /// WAC passes `WACNativeTools.all`. Hosts with more than two agent surfaces
    /// use `toolCatalogs` instead.
    public var endUserTools: [NativeTool]
    /// Additional named tool surfaces, for hosts with more than the end-user /
    /// developer pair. Merged with the catalog built from `endUserTools` and
    /// the console's own bridge.
    public var toolCatalogs: [RipulToolCatalog]
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
        devTools: [NativeTool] = [],
        endUserTools: [NativeTool] = [],
        toolCatalogs: [RipulToolCatalog] = [],
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
        self.devTools = devTools
        self.endUserTools = endUserTools
        self.toolCatalogs = toolCatalogs
        self.invitesSection = invitesSection
        self.foldersSection = foldersSection
        self.emptyStateOverride = emptyStateOverride
    }
}
