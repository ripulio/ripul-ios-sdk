import SwiftUI
import WebKit

/// The session list's own actions, handed to an app-injected invites panel.
///
/// Accepting an invite creates a chat, and the user expects to be dropped into
/// it. Only the list knows how to do that (it owns the focus + slide), so it
/// lends the panel the same `openChat` its own rows use.
public struct InvitesSectionActions {
    /// Open a chat the way a session row does: focus the web view, then slide
    /// the chat in over the list.
    public let openChat: (ChatSession) -> Void
    /// Close the session list without opening anything.
    public let dismissList: () -> Void

    public init(
        openChat: @escaping (ChatSession) -> Void,
        dismissList: @escaping () -> Void
    ) {
        self.openChat = openChat
        self.dismissList = dismissList
    }
}

/// Configuration for the drop-in `RipulAgentConsole` (and the pieces it composes).
///
/// A host (e.g. a third-party app's developer tool) constructs this with an
/// isolated cache suite and a dedicated `websiteDataStore` so the developer's
/// Ripul/Clerk session is kept separate from the host's own web content.
public struct RipulSessionsConfiguration {
    /// Backend + web-app origin. Drives the relay API and the embedded web view.
    public var baseURL: URL
    public var standalone: Bool = false
    /// Bundled chat appearance, independent of the connection/account mode.
    public var chatPresentation: String? = nil
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
    public var composerContexts: [RipulComposerContext] = RipulComposerContext.developerDefaults
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
    /// Optional app-injected panels. An injected invites panel replaces the
    /// SDK's own; it is handed the list's own open/dismiss actions — accepting
    /// an invite has to land the user in the joined chat, which only the list
    /// can do.
    public var invitesSection: ((InvitesSectionActions) -> AnyView)?
    /// The invites source for the SDK's own invites panel, which renders when
    /// `invitesSection` is nil. Pass a host-owned manager when something else
    /// must refresh the same inbox (e.g. an invite push); leave nil and the
    /// agent screen runs its own from its token provider.
    public var inviteManager: RipulInviteManager?
    public var emptyStateOverride: (() -> AnyView)?
    /// Supplying this puts a "Solutions" row in the sessions overflow menu,
    /// which presents `RipulSolutionsScreen` (collections, contexts, the model
    /// catalog, macros, …) over the agent screen.
    ///
    /// nil — the default — omits the row, which is what the first-party app
    /// wants: it reaches Solutions from its own sidebar. An SDK host has no
    /// sidebar, and has had no route to the screen since `f291beca3` moved it
    /// off the sessions list; this is that route. The row additionally
    /// requires the developer audience, so passing this on an end-user surface
    /// still shows nothing.
    ///
    /// A builder rather than a value because the one thing a host cannot supply
    /// up front is the token: `RipulAgentConsole` creates the Clerk auth store
    /// itself, so a `RipulSessionsConfiguration` built as a static `let` — which
    /// is how an embedder writes one — has nothing to read a token from. The
    /// screen's own provider is handed back here instead.
    public var solutionManagement: ((_ tokenProvider: @escaping () -> String?) -> RipulSolutionManagement)?

    public init(
        cache: RipulSessionCache,
        baseURL: URL = AgentConfiguration.defaultBaseURL,
        siteKey: String? = nil,
        chatPresentation: String? = nil,
        websiteDataStore: WKWebsiteDataStore = .default(),
        theme: AgentTheme = .system,
        allowRipulAgents: Bool = false,
        quickActionsEnabled: Bool = false,
        registry: RipulToolRegistry = RipulToolRegistry(),
        invitesSection: ((InvitesSectionActions) -> AnyView)? = nil,
        inviteManager: RipulInviteManager? = nil,
        emptyStateOverride: (() -> AnyView)? = nil,
        solutionManagement: ((_ tokenProvider: @escaping () -> String?) -> RipulSolutionManagement)? = nil
    ) {
        self.cache = cache
        self.baseURL = baseURL
        self.siteKey = siteKey
        self.chatPresentation = chatPresentation
        self.websiteDataStore = websiteDataStore
        self.theme = theme
        self.allowRipulAgents = allowRipulAgents
        self.quickActionsEnabled = quickActionsEnabled
        self.registry = registry
        self.invitesSection = invitesSection
        self.inviteManager = inviteManager
        self.emptyStateOverride = emptyStateOverride
        self.solutionManagement = solutionManagement
    }
}
