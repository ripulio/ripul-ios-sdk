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
    /// Whether the signed-in account may see Solution management AT ALL. False
    /// omits the whole panel, not just its admin rows.
    ///
    /// Defaults to true because an ordinary SDK host's developer curates
    /// collections and contexts without being a Ripul platform admin — for them
    /// the panel is their own workbench. The first-party app passes the real
    /// admin state, because there the panel is an admin surface end to end.
    ///
    /// This hides UI; it is not the enforcement boundary. The API gates each
    /// route independently, and the admin-only screens behind these rows
    /// (site keys, models, users, billing) all demand an admin permission
    /// server-side. Note the converse: collections, macros and contexts are
    /// NOT admin-gated server-side, so hiding those rows is a curation choice
    /// rather than a lock.
    public var showsSolutionManagement: Bool
    /// Registered app slug for Ripul-hosted OTA builds, e.g. "ripul" / "wac".
    /// When set, Solution management offers a Builds row listing what has been
    /// published for this app and installing it in place. nil omits the row.
    ///
    /// Unlike the first-party app's Settings > Advanced > Builds, this is the
    /// route an SDK consumer actually has — their users never see Ripul's own
    /// Settings screen.
    public var buildsApp: String?
    /// Optional app-injected panels (nil = omitted). The invites panel is
    /// handed the list's own open/dismiss actions — accepting an invite has to
    /// land the user in the joined chat, which only the list can do.
    public var invitesSection: ((InvitesSectionActions) -> AnyView)?
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
        showsSolutionManagement: Bool = true,
        buildsApp: String? = nil,
        invitesSection: ((InvitesSectionActions) -> AnyView)? = nil,
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
        self.showsSolutionManagement = showsSolutionManagement
        self.buildsApp = buildsApp
        self.invitesSection = invitesSection
        self.foldersSection = foldersSection
        self.emptyStateOverride = emptyStateOverride
    }
}
