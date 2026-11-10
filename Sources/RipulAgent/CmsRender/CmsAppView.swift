#if os(iOS)
import SwiftUI

/// A tab the host app adds beside the site's own (an Account tab with Sign
/// out: the CMS does not own sign-in). Its content is drawn inside a
/// navigation stack of its own, so it can set a title and push with
/// `NavigationLink(value:)` and `navigationDestination`.
public struct CmsAppHostTab: Identifiable {
    public enum Placement {
        /// Before the site's tabs.
        case leading
        /// After the site's tabs (the usual place for Account or Settings).
        case trailing
    }

    public let id: String
    public let title: String
    public let systemImage: String
    public let badge: String?
    public let placement: Placement
    /// Shown only while the site isn't loaded (loading, failed, no access), never
    /// beside the site's own tabs: a way out (Sign out) when the site can't be
    /// reached, for an app whose site draws its account screen itself.
    public let onlyWhileSiteUnavailable: Bool
    let content: () -> AnyView

    /// - Parameters:
    ///   - id: Stable id. The tab's accessibility identifier is `tabbar.<id>`,
    ///     and `CmsAppController.select(hostTab:)` takes it.
    ///   - title: The tab's label.
    ///   - systemImage: An SF Symbol name.
    ///   - badge: Text for the tab's badge; nil for none.
    ///   - placement: Before or after the site's tabs.
    ///   - onlyWhileSiteUnavailable: Show it only while the site isn't loaded.
    public init<Content: View>(
        id: String,
        title: String,
        systemImage: String,
        badge: String? = nil,
        placement: Placement = .trailing,
        onlyWhileSiteUnavailable: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.badge = badge
        self.placement = placement
        self.onlyWhileSiteUnavailable = onlyWhileSiteUnavailable
        self.content = { AnyView(content()) }
    }
}

/// Opens pages in a `CmsAppView` from outside it: a link into the app, a
/// notification. Create one, keep it, pass it to the view. Requests made
/// before the site has loaded are carried out once it has.
@MainActor
public final class CmsAppController: ObservableObject {
    enum Request: Equatable {
        case page(slug: String, viewRef: String?)
        case hostTab(String)
    }

    @Published var pending: Request?

    public init() {}

    /// Open a page of the site. A tab's first page selects that tab, popped to
    /// that page; any other page is pushed onto the selected tab. A page this
    /// visitor cannot open is ignored, as a dead link is on the web.
    public func open(pageSlug: String, viewRef: String? = nil) {
        pending = .page(slug: pageSlug, viewRef: viewRef)
    }

    /// Open a link into the app: `<scheme>://ripul-page/<slug>`, the link a
    /// running record's Live Activity carries. True when it was one. Call it
    /// from the host's `.onOpenURL`.
    @discardableResult
    public func handle(url: URL) -> Bool {
        guard url.host == "ripul-page", let slug = url.pathComponents.dropFirst().first, !slug.isEmpty else { return false }
        open(pageSlug: slug)
        return true
    }

    /// Select one of the host's own tabs, by its id.
    public func select(hostTab id: String) {
        pending = .hostTab(id)
    }
}

/// A CMS site as a whole app: the site's `tabBar` block drawn as iOS's own
/// tab bar, one navigation stack per tab, and all tabs sharing one load of the
/// site and one data runtime. A site with no tab bar shows its landing page in
/// one stack, as `CmsPageView` does.
///
/// The bar is the system's `TabView`, never a drawing of one, and its surface
/// is never restyled: the site's theme may set the tint and nothing else.
///
/// ```swift
/// CmsAppView(
///     cmsId: "cms_abc",
///     clientConfig: config,
///     visitorSiteKey: "pk_…",
///     hostTabs: [
///         CmsAppHostTab(id: "account", title: "Account", systemImage: "person.crop.circle") {
///             AccountScreen()
///         }
///     ]
/// )
/// ```
///
/// What each iOS convention does and how is in `docs/cms-app-view.md`.
public struct CmsAppView: View {
    public let cmsId: String

    @StateObject private var loader: CmsPageLoader
    @ObservedObject private var controller: CmsAppController
    @Environment(\.colorScheme) private var colorScheme

    private let hostTabs: [CmsAppHostTab]
    private let hostActions: [String: @MainActor () -> Void]
    private let initialPageSlug: String?
    private let showsDeveloperTools: Bool
    private let showsShellChat: Bool
    private let statusTabTitle: String
    private let statusTabSystemImage: String

    /// - Parameters:
    ///   - cmsId: The CMS definition id.
    ///   - clientConfig: Auth, base URL and the app's `origin`, as for `CmsPageView`.
    ///   - visitorSiteKey: The site key's publishable key (visitor or member
    ///     mode); nil loads as the site's owner.
    ///   - hostTabs: The host app's own tabs, placed before or after the site's.
    ///     A host tab gives way to a site tab whose page slug is its id.
    ///   - hostActions: What the app does for a card's `open: { host: <name> }`, by
    ///     name (`"signOut"`). A button, tap or accessory naming one not here is left out.
    ///   - controller: Opens pages from outside the view (links into the app).
    ///   - initialPageSlug: A page to open once the site has loaded, instead of
    ///     the tab chosen last time.
    ///   - showsDeveloperTools: The runtime inspector (and, for a designer, the
    ///     Edit/Preview pill) on every page. Off for apps people use.
    ///   - showsShellChat: The site shell's floating chat ("Ask us") on every
    ///     tab, as the bottom accessory or the floating button. Off by default:
    ///     the chat is Ripul's web chat in a web view, and a CMS app shows native
    ///     controls only until a native chat exists.
    ///   - statusTabTitle, statusTabSystemImage: The tab that stands in for the
    ///     site's tabs while the site is loading, failed to load or refused
    ///     access, beside the host's own tabs (so Account and Sign out stay
    ///     reachable). Only drawn when there are host tabs.
    public init(
        cmsId: String,
        clientConfig: CmsClientConfig,
        visitorSiteKey: String? = nil,
        hostTabs: [CmsAppHostTab] = [],
        hostActions: [String: @MainActor () -> Void] = [:],
        controller: CmsAppController? = nil,
        initialPageSlug: String? = nil,
        showsDeveloperTools: Bool = false,
        showsShellChat: Bool = false,
        statusTabTitle: String = "Home",
        statusTabSystemImage: String = "house"
    ) {
        self.statusTabTitle = statusTabTitle
        self.statusTabSystemImage = statusTabSystemImage
        self.cmsId = cmsId
        self.hostTabs = hostTabs
        self.hostActions = hostActions
        self.initialPageSlug = initialPageSlug
        self.showsDeveloperTools = showsDeveloperTools
        self.showsShellChat = showsShellChat
        _controller = ObservedObject(wrappedValue: controller ?? CmsAppController())
        _loader = StateObject(wrappedValue: CmsPageLoader(cmsId: cmsId, clientConfig: clientConfig, visitorSiteKey: visitorSiteKey))
    }

    public var body: some View {
        Group {
            switch loader.state {
            case .loaded:
                CmsAppTabsView(
                    cmsId: cmsId,
                    loader: loader,
                    runtime: loader.runtime,
                    controller: controller,
                    hostTabs: hostTabs,
                    initialPageSlug: initialPageSlug,
                    showsDeveloperTools: showsDeveloperTools,
                    showsShellChat: showsShellChat
                )
            default:
                switch CmsAppLayout.whileNotLoaded(hostTabCount: hostTabs.count) {
                case .statusOnly:
                    CmsPageLoadStatusView(state: loader.state) { loader.load(pageSlug: nil) }
                case .statusBesideHostTabs:
                    CmsAppStatusTabsView(
                        cmsId: cmsId,
                        state: loader.state,
                        retry: { loader.load(pageSlug: nil) },
                        hostTabs: hostTabs,
                        title: statusTabTitle,
                        systemImage: statusTabSystemImage
                    )
                }
            }
        }
        // A site that forces light or dark sets it for the whole app: the
        // status bar, the tab bar and the pages agree.
        .modifier(CmsSiteColorScheme(runtime: loader.runtime, ownsWindow: true))
        .onAppear {
            loader.runtime.hostActions = hostActions
            // The site's account menu offers Sign out when the app handles it.
            if let signOut = hostActions["signOut"] { loader.runtime.onSignOut = signOut }
            loader.runtime.updateEffectiveDark(colorScheme == .dark)
            loader.load(pageSlug: nil)
        }
        .onChange(of: colorScheme) { newScheme in
            loader.runtime.updateEffectiveDark(newScheme == .dark)
        }
    }
}

/// While the site isn't loaded (loading, a failed load, no access) and the
/// host has tabs: the system tab bar with one status tab, standing in for the
/// site's tabs, beside the host's own. The host's Account or Settings screen
/// stays reachable when the site refuses the person, as after their session
/// ended elsewhere. A host tab chosen here is the one selected once the site
/// loads; the status tab is never remembered.
private struct CmsAppStatusTabsView: View {
    let state: CmsPageLoader.State
    let retry: () -> Void
    let hostTabs: [CmsAppHostTab]
    let title: String
    let systemImage: String

    @State private var selected: String
    @State private var hostPaths: [String: NavigationPath] = [:]
    @SceneStorage private var sceneTab: String
    private let memory: CmsAppTabMemory

    init(cmsId: String, state: CmsPageLoader.State, retry: @escaping () -> Void,
         hostTabs: [CmsAppHostTab], title: String, systemImage: String) {
        self.state = state
        self.retry = retry
        self.hostTabs = hostTabs
        self.title = title
        self.systemImage = systemImage
        let memory = CmsAppTabMemory(cmsId: cmsId)
        self.memory = memory
        _sceneTab = SceneStorage(wrappedValue: "", memory.key)
        let stored = memory.stored
        let hostIDs = hostTabs.map { CmsAppTabID.host($0.id) }
        _selected = State(initialValue: hostIDs.contains(stored) ? stored : CmsAppTabID.status)
    }

    private var ordered: [(id: String, host: CmsAppHostTab?)] {
        hostTabs.filter { $0.placement == .leading }.map { (CmsAppTabID.host($0.id), $0) }
            + [(CmsAppTabID.status, nil)]
            + hostTabs.filter { $0.placement == .trailing }.map { (CmsAppTabID.host($0.id), $0) }
    }

    private var selection: Binding<String> {
        Binding(get: { selected }, set: { newValue in
            if newValue == selected, newValue != CmsAppTabID.status {
                hostPaths[newValue] = NavigationPath()  // re-tap pops a host tab
            }
            selected = newValue
            if newValue != CmsAppTabID.status {
                sceneTab = newValue
                memory.stored = newValue
            }
        })
    }

    var body: some View {
        TabView(selection: selection) {
            ForEach(ordered, id: \.id) { entry in
                content(entry)
                    .tabItem {
                        if let host = entry.host {
                            Label(host.title, systemImage: host.systemImage)
                                .accessibilityIdentifier("tabbar.\(host.id)")
                        } else {
                            Label(title, systemImage: systemImage)
                                .accessibilityIdentifier("tabbar.status")
                        }
                    }
                    .tag(entry.id)
                    .badge(entry.host?.badge.map(Text.init))
            }
        }
    }

    @ViewBuilder
    private func content(_ entry: (id: String, host: CmsAppHostTab?)) -> some View {
        if let host = entry.host {
            NavigationStack(path: Binding(
                get: { hostPaths[entry.id] ?? NavigationPath() },
                set: { hostPaths[entry.id] = $0 }
            )) {
                host.content()
            }
        } else {
            CmsPageLoadStatusView(state: state, retry: retry)
        }
    }
}

/// The loaded app: a tab bar when the site has one, else one stack.
/// The reserved tab's icon on a bottom bar, where the disc covers it: its symbol
/// drawn into a bitmap that carries the feature button's label, so VoiceOver reads
/// "Finish shift", not the symbol's own name. One image per label, kept, so the bar
/// item changes only when the label does. (SwiftUI takes two images of the same
/// symbol as equal and kept the first label; the `Tab`'s and the `Label`'s own
/// `accessibilityLabel` don't reach the bar's button, and setting it through UIKit
/// cost every tab its `tabbar.<slug>` identifier.)
@MainActor
enum CmsFeatureTabIcon {
    private static var drawn: [String: UIImage] = [:]

    static func image(symbol: String, label: String) -> UIImage? {
        let key = symbol + "\u{1F}" + label
        if let image = drawn[key] { return image }
        guard let base = UIImage(systemName: symbol) else { return nil }
        let image = UIGraphicsImageRenderer(size: base.size).image { _ in base.draw(at: .zero) }
            .withRenderingMode(.alwaysTemplate)
        image.accessibilityLabel = label.isEmpty ? nil : label
        drawn[key] = image
        return image
    }
}

private struct CmsAppTabsView: View {
    let cmsId: String
    let loader: CmsPageLoader
    @ObservedObject var runtime: CmsRuntime
    @ObservedObject var controller: CmsAppController
    let hostTabs: [CmsAppHostTab]
    let initialPageSlug: String?
    let showsDeveloperTools: Bool
    let showsShellChat: Bool
    /// Compact width: the bar is along the bottom, where the disc covers the
    /// reserved tab (`featureTitle`).
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var nav: CmsAppNavigationState?
    @State private var didSetUp = false
    @State private var hostPaths: [String: NavigationPath] = [:]
    @State private var singlePath: [CmsAppRoute] = []
    @State private var scrollSignals: [String: Int] = [:]
    /// Bumped when the feature button's reserved tab is selected (VoiceOver,
    /// the sidebar, More, the keyboard): the overlay runs its action.
    @State private var featureSignal = 0
    /// Bumped by the reserved tab's VoiceOver action for the feature button's hold.
    @State private var featureHoldSignal = 0
    /// A page to open once the person's pages have been read again after signing in.
    @State private var afterSignIn: String?
    /// The selected tab, kept across launches, one per site: the scene's own
    /// state first, then the last tab chosen in any scene (a scene whose saved
    /// state iOS dropped, as after the app is killed, still opens there).
    @SceneStorage private var sceneTab: String
    private let memory: CmsAppTabMemory

    private var storedTab: String {
        get { sceneTab.isEmpty ? memory.stored : sceneTab }
        nonmutating set {
            sceneTab = newValue
            memory.stored = newValue
        }
    }

    init(cmsId: String, loader: CmsPageLoader, runtime: CmsRuntime, controller: CmsAppController,
         hostTabs: [CmsAppHostTab], initialPageSlug: String?, showsDeveloperTools: Bool, showsShellChat: Bool) {
        self.cmsId = cmsId
        self.loader = loader
        self.runtime = runtime
        self.controller = controller
        self.hostTabs = hostTabs
        self.initialPageSlug = initialPageSlug
        self.showsDeveloperTools = showsDeveloperTools
        self.showsShellChat = showsShellChat
        memory = CmsAppTabMemory(cmsId: cmsId)
        _sceneTab = SceneStorage(wrappedValue: "", memory.key)
    }

    // MARK: Site model

    private var tabBar: CmsTabBarConfig? {
        CmsTabBarConfig.find(shell: loader.shellPageId.flatMap { id in loader.allPages.first { $0.id == id } })
    }

    private var openableSlugs: Set<String> { Set(loader.availablePages.map(\.slug)) }

    /// The shell's floating chat ("Ask us"): CmsAppView draws no shell, so it
    /// keeps the chat itself, on every tab.
    private var shellChat: CmsBlock? {
        guard showsShellChat else { return nil }
        return CmsFloatingChat.find(shell: loader.shellPageId.flatMap { id in loader.allPages.first { $0.id == id } })
    }

    /// On iOS 26 the chat is the tab bar's bottom accessory, unless the site's
    /// tab bar already sets one (WAC's running shift): then, and on older
    /// systems, it is the floating button.
    private var chatInAccessory: Bool {
        guard #available(iOS 26, *) else { return false }
        return shellChat != nil && tabBar?.accessory == nil && !siteTabs.isEmpty
    }

    private func registerShellChat() {
        runtime.shellChat = shellChat
        runtime.shellChatInAccessory = chatInAccessory
    }

    /// The tab bar's toolbar blocks this person gets (`toolbar`).
    private var toolbarBlocks: [CmsBlock] {
        tabBar?.visibleToolbar(membership: runtime.membership, canDesign: runtime.canDesign) ?? []
    }

    private var siteTabs: [CmsAppSiteTab] {
        tabBar?.visibleTabs(openableSlugs: openableSlugs, membership: runtime.membership, canDesign: runtime.canDesign) ?? []
    }

    private enum TabKind {
        case site(CmsAppSiteTab)
        case host(CmsAppHostTab)
        /// The feature button's reserved slot (CmsTabBarFeatureView.swift).
        case feature
    }

    /// The feature button, when the site's bar has one for the iPhone.
    private var feature: CmsTabBarFeature? { tabBar?.featureButton }

    /// Its label and icon for the reserved tab: what VoiceOver, a sidebar and More show.
    private var featureLook: CmsTabBarFeature.Resolved? {
        feature?.resolve(row: feature?.query.flatMap { q in
            if case .ok(let r) = runtime.state(for: q) { return r.rows.first }
            return nil
        }) { q in
            if case .ok(let r) = runtime.state(for: q) { return r.rows.count }
            return nil
        }
    }

    /// The reserved tab's own title. On a bottom bar the disc is drawn over it,
    /// and iOS 26 and 27's glass bar ignores an item's title colour, so a label
    /// wider than the disc ("Finish shift") showed at its sides: there the title
    /// is empty and VoiceOver reads the label from the tab's icon
    /// (`CmsFeatureTabIcon`). A
    /// sidebar (regular width) shows the label, with no disc.
    private func featureTitle(_ label: String) -> String {
        sizeClass == .compact ? "" : label
    }

    private struct AppTab: Identifiable {
        let id: String
        let kind: TabKind
        let title: String
        let systemImage: String
        let accessibilityIdentifier: String
    }

    /// The host's tabs less those a site tab of the same id has taken over.
    /// Less those shown only while the site is unavailable.
    private var shownHostTabs: [CmsAppHostTab] {
        let loaded = hostTabs.filter { !$0.onlyWhileSiteUnavailable }
        let ids = CmsAppLayout.shownHostTabIDs(loaded.map(\.id), sitePageSlugs: siteTabs.map(\.pageSlug))
        return loaded.filter { ids.contains($0.id) }
    }

    private var tabs: [AppTab] {
        func host(_ tab: CmsAppHostTab) -> AppTab {
            AppTab(id: CmsAppTabID.host(tab.id), kind: .host(tab), title: tab.title,
                   systemImage: tab.systemImage, accessibilityIdentifier: "tabbar.\(tab.id)")
        }
        let hostTabs = shownHostTabs
        let site = siteTabs.map {
            AppTab(id: $0.id, kind: .site($0), title: $0.title, systemImage: $0.systemImage,
                   accessibilityIdentifier: $0.accessibilityIdentifier)
        }
        var all = hostTabs.filter { $0.placement == .leading }.map(host)
            + site
            + hostTabs.filter { $0.placement == .trailing }.map(host)
        // The feature button's slot counts every tab in the bar, the host's
        // included, so WAC Next's centre sits between Records and Jobs.
        if let feature, let look = featureLook, !site.isEmpty {
            let index = CmsTabBarFeature.slotIndex(feature.slot, tabCount: all.count)
            all.insert(AppTab(id: CmsAppTabID.feature, kind: .feature, title: featureTitle(look.label),
                              systemImage: CmsButtonMenu.symbolName(look.icon) ?? "circle.circle.fill",
                              accessibilityIdentifier: CmsTabBarFeatureSlotTracker.identifier), at: index)
        }
        return all
    }

    private func page(_ slug: String) -> CmsPage? {
        loader.availablePages.first { $0.slug == slug }
    }

    private var landingPage: CmsPage? {
        loader.landingPageId.flatMap { id in loader.availablePages.first { $0.id == id } }
            ?? loader.availablePages.first { $0.id != loader.shellPageId }
            ?? loader.availablePages.first
    }

    // MARK: Body

    var body: some View {
        let tabs = self.tabs
        Group {
            if siteTabs.isEmpty {
                singleStack
            } else {
                tabView(tabs)
            }
        }
        .onAppear { setUp(tabs); installFormPages(); anchorShellSources(); registerShellChat() }
        .onChange(of: loader.allPages.map(\.id)) { _, _ in registerShellChat() }
        .onReceive(runtime.$queries) { _ in anchorShellSources() }
        // A countdown, a summary or a page after a mutation (`action.after`).
        .modifier(CmsMutationAfterOverlay(runtime: runtime))
        .modifier(CmsRunningActivitySync(runtime: runtime))
        // Links inside pages (nav blocks, drill links) arrive here.
        .onReceive(runtime.$pendingNavigation) { navigation in
            guard let navigation else { return }
            runtime.pendingNavigation = nil
            open(navigation.pageSlug)
        }
        .onReceive(controller.$pending) { request in
            guard let request, nav != nil || siteTabs.isEmpty else { return }
            controller.pending = nil
            handle(request)
        }
        .onChange(of: runtime.signInGeneration) { _ in followSignIn() }
        // The site's own sign-in, for a page that needs a signed-in member.
        .ripulSheet(item: $runtime.signInRequest, size: .form) { request in
            if let signIn = runtime.siteSignIn {
                CmsSiteSignInSheet(signIn: signIn, formProps: signInFormProps) { signedIn in
                    if signedIn { afterSignIn = request.returnTo }
                    runtime.signInRequest = nil
                }
                .environmentObject(runtime)
            }
        }
        // The shell's chat opened from the tab bar's accessory: a sheet inside the
        // system's accessory never presents, so the app presents it.
        .ripulSheet(isPresented: $runtime.shellChatOpen) {
            if let chat = runtime.shellChat {
                CmsFloatingChatSheet(block: chat, open: $runtime.shellChatOpen)
                    .environmentObject(runtime)
            }
        }
    }

    /// The site's own sign-in form (its first `authForm`), whose heading and
    /// words the sheet uses: "Sign in to Sandsend Retreats".
    private var signInFormProps: [String: CmsJSON] {
        for page in loader.allPages {
            if let form = page.blocks?.allBlocks().first(where: { $0.type == "authForm" }) { return form.props }
        }
        return [:]
    }

    /// The record cursors the shell keeps. On the web the shell is always
    /// mounted, and a nav block's header card (`headerQuerySlug`: the company a
    /// drawer's card shows) selects its first record, so the pages that wait on
    /// that selection (`@companies_select.company_id`) load on any page.
    /// CmsAppView draws no shell, so it keeps them itself, as the native drawer
    /// does while closed.
    private var shellHeaderSources: [String] {
        guard let shell = loader.shellPageId.flatMap({ id in loader.allPages.first { $0.id == id } }) else { return [] }
        return (shell.blocks?.allBlocks() ?? []).compactMap { block in
            guard block.type == "sidebarNav" || block.type == "topNav" else { return nil }
            return block.props.string("headerQuerySlug").flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    private func anchorShellSources() {
        for source in shellHeaderSources {
            runtime.ensureLoaded(source)
            if runtime.selectedRow(source) == nil, case .ok(let result) = runtime.state(for: source),
               let first = result.rows.first {
                runtime.setSelectedRows(source, rows: [first])
            }
        }
    }

    private func setUp(_ tabs: [AppTab]) {
        // CmsAppView replaces the shell: no page is routed into an outlet.
        runtime.outletPage = nil
        guard !didSetUp else { return }
        didSetUp = true
        // With a tab bar, the tabs' state; without one, the one stack, whose
        // first page is the landing page. Either way the initial page and an
        // early controller request are routed now (a site with no tab bar
        // used to drop them).
        if !siteTabs.isEmpty {
            nav = CmsAppNavigationState(
                siteTabs: siteTabs.map { (id: $0.id, rootSlug: $0.pageSlug) },
                // The feature's slot is never selected, so never remembered.
                tabIDs: tabs.map(\.id).filter { $0 != CmsAppTabID.feature },
                selected: storedTab.isEmpty ? nil : CmsAppLayout.rememberedTab(
                    storedTab, shownHostTabIDs: shownHostTabs.map(\.id), sitePageSlugs: siteTabs.map(\.pageSlug))
            )
        }
        if let initialPageSlug, !initialPageSlug.isEmpty { open(initialPageSlug) }
        if let request = controller.pending {
            controller.pending = nil
            handle(request)
        }
        if let nav { storedTab = nav.selected }
    }

    private func handle(_ request: CmsAppController.Request) {
        switch request {
        case .page(let slug, let viewRef):
            if let viewRef {
                // Same channel as a nav item's targetViewRef.
                let parts = viewRef.split(separator: ":", maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    runtime.gridViewRequest = CmsRuntime.GridViewRequest(gridId: parts[0], viewId: parts[1])
                }
            }
            open(slug)
        case .hostTab(let id):
            // A host tab the site has taken over: its site tab.
            let tab = CmsAppLayout.rememberedTab(CmsAppTabID.host(id), shownHostTabIDs: shownHostTabs.map(\.id),
                                                 sitePageSlugs: siteTabs.map(\.pageSlug))
            if nav?.tabIDs.contains(tab) == true {
                nav?.selected = tab
                storedTab = tab
            }
        }
    }

    private func open(_ slug: String) {
        if !openableSlugs.contains(slug), needsSignIn(slug) { return }
        let section = CmsAppSection.shell(for: slug, pages: loader.allPages, siteShellId: loader.shellPageId)?.slug
        guard var state = nav else {
            // No tab bar: the one stack. Its first page is the landing page.
            guard openableSlugs.contains(slug) else { return }
            if slug == landingPage?.slug {
                singlePath = []
            } else if singlePath.last?.pageSlug != slug {
                if let section, openableSlugs.contains(section), !singlePath.contains(where: { $0.pageSlug == section }) {
                    singlePath.append(CmsAppRoute(pageSlug: section))
                }
                singlePath.append(CmsAppRoute(pageSlug: slug))
            }
            return
        }
        state.open(pageSlug: slug, openableSlugs: openableSlugs, sectionShell: section)
        nav = state
        storedTab = state.selected
    }

    /// A page of the site this person cannot open yet, on a site with its own
    /// sign-in (CmsSiteSignIn): signed out, the sign-in sheet, then the page;
    /// signed in a moment ago, the page once their pages have been read again
    /// (`signInGeneration`). False for a page that is not there for anyone.
    private func needsSignIn(_ slug: String) -> Bool {
        guard let signIn = runtime.siteSignIn, loader.allPages.contains(where: { $0.slug == slug }) else { return false }
        if signIn.isSignedIn {
            afterSignIn = slug
        } else {
            runtime.signInRequest = CmsSignInRequest(returnTo: slug)
        }
        return true
    }

    /// Signed in or out: the tabs and stacks this person now has, then the
    /// page they were headed for, if they may open it.
    private func followSignIn() {
        let tabs = self.tabs
        if let state = nav {
            nav = state.following(
                siteTabs: siteTabs.map { (id: $0.id, rootSlug: $0.pageSlug) },
                tabIDs: tabs.map(\.id).filter { $0 != CmsAppTabID.feature },
                openableSlugs: openableSlugs
            )
        } else if let cut = singlePath.firstIndex(where: { $0.formID == nil && !openableSlugs.contains($0.pageSlug) }) {
            singlePath = Array(singlePath.prefix(cut))
        }
        if let slug = afterSignIn {
            afterSignIn = nil
            if openableSlugs.contains(slug) { open(slug) }
        }
    }

    // MARK: Selection and re-tap

    /// The binding the bar writes through. Tapping the tab that is already
    /// selected writes the same value again: that is the re-tap.
    private var selection: Binding<String> {
        Binding(
            get: { nav?.selected ?? "" },
            set: { newValue in
                guard var state = nav else { return }
                // The feature button's slot runs its action; the tab selected stays.
                if newValue == CmsAppTabID.feature {
                    featureSignal += 1
                    return
                }
                if newValue == state.selected {
                    reselect(newValue)
                } else {
                    state.selected = newValue
                    nav = state
                    storedTab = newValue
                }
            }
        )
    }

    private func reselect(_ tab: String) {
        let depth = nav?.paths[tab]?.count ?? hostPaths[tab]?.count ?? 0
        switch CmsAppReselect.action(stackDepth: depth) {
        case .popToRoot:
            if nav?.rootSlugs[tab] != nil {
                nav?.paths[tab] = []
            } else {
                hostPaths[tab] = NavigationPath()
            }
        case .scrollToTop:
            scrollSignals[tab, default: 0] += 1
        }
    }

    private func pathBinding(_ tab: String) -> Binding<[CmsAppRoute]> {
        Binding(
            get: { nav?.paths[tab] ?? [] },
            set: { nav?.paths[tab] = $0 }
        )
    }

    private func hostPathBinding(_ tab: String) -> Binding<NavigationPath> {
        Binding(
            get: { hostPaths[tab] ?? NavigationPath() },
            set: { hostPaths[tab] = $0 }
        )
    }

    // MARK: The bar

    @ViewBuilder
    private func tabView(_ tabs: [AppTab]) -> some View {
        if #available(iOS 18, *) {
            TabView(selection: selection) {
                ForEach(tabs) { tab in
                    Tab(value: tab.id) {
                        tabContent(tab)
                    } label: {
                        tabLabel(tab)
                    }
                    .badge(badge(tab).map(Text.init))
                }
            }
            .tabViewStyle(.sidebarAdaptable)
            .modifier(CmsTabBarSystemBehaviours(
                accessory: tabBar?.accessory,
                chat: chatInAccessory ? shellChat : nil,
                minimizeOnScroll: tabBar?.minimizeOnScroll ?? true,
                runtime: runtime
            ))
            .modifier(CmsTabBarTint(runtime: runtime))
            .overlay { featureOverlay }
            // The side drawer over the whole app, tab bar included (WAC's
            // RecordMenu covers it); the shared runtime opens it for the
            // selected tab's page.
            .overlay { CmsDrawerOverlay(runtime: runtime) }
        } else {
            TabView(selection: selection) {
                ForEach(tabs) { tab in
                    tabContent(tab)
                        .tabItem { tabLabel(tab) }
                        .tag(tab.id)
                        .badge(badge(tab).map(Text.init))
                }
            }
            .modifier(CmsTabBarTint(runtime: runtime))
            .overlay { featureOverlay }
            .overlay { CmsDrawerOverlay(runtime: runtime) }
        }
    }

    /// The feature button's disc over its reserved tab, and its action's sheets.
    @ViewBuilder
    private var featureOverlay: some View {
        if let feature {
            let all = tabs
            CmsTabBarFeatureOverlay(feature: feature, hasAccessory: tabBar?.accessory != nil || chatInAccessory,
                                    selectSignal: featureSignal, holdSignal: featureHoldSignal,
                                    selection: nav?.selected ?? "", runtime: runtime,
                                    slotIndex: all.firstIndex { $0.id == CmsAppTabID.feature } ?? 0,
                                    buttonCount: all.count)
        }
    }

    /// The tab's label. Its identifier reaches the bar's button
    /// (`tabbar.<slug>`, for UI tests); VoiceOver's label, trait and
    /// "1 of 3" stay the system's.
    @ViewBuilder
    private func tabLabel(_ tab: AppTab) -> some View {
        if case .feature = tab.kind, let hold = featureLook?.hold {
            // The disc is drawn over this tab and hidden from VoiceOver, so the
            // hold is offered here as a named action ("WAC out").
            Label { Text(tab.title) } icon: { featureIcon(tab) }
                .accessibilityIdentifier(tab.accessibilityIdentifier)
                .accessibilityAction(named: Text(hold.label)) { featureHoldSignal += 1 }
        } else if case .feature = tab.kind {
            Label { Text(tab.title) } icon: { featureIcon(tab) }
                .accessibilityIdentifier(tab.accessibilityIdentifier)
        } else {
            Label(tab.title, systemImage: tab.systemImage)
                .accessibilityIdentifier(tab.accessibilityIdentifier)
        }
    }

    /// The reserved tab's icon. With no title (a bottom bar, `featureTitle`) the
    /// bar names the button by its image, and an SF Symbol's own name for it reads
    /// "Circle inside a filled circle": there the icon is the symbol drawn once per
    /// label, carrying the label (`CmsFeatureTabIcon`). A sidebar shows the title.
    private func featureIcon(_ tab: AppTab) -> Image {
        if tab.title.isEmpty, let drawn = CmsFeatureTabIcon.image(symbol: tab.systemImage, label: featureLook?.label ?? "") {
            return Image(uiImage: drawn)
        }
        return Image(systemName: tab.systemImage)
    }

    private func badge(_ tab: AppTab) -> String? {
        switch tab.kind {
        case .site(let site): return site.item.badgeText(runtime: runtime)
        case .host(let host): return host.badge
        case .feature: return nil
        }
    }

    @ViewBuilder
    private func tabContent(_ tab: AppTab) -> some View {
        let isSelected = nav?.selected == tab.id
        Group {
            switch tab.kind {
            case .site(let site):
                NavigationStack(path: pathBinding(tab.id)) {
                    pageView(site.pageSlug, isRoot: true, scrollSignal: scrollSignals[tab.id] ?? 0)
                        .navigationDestination(for: CmsAppRoute.self) { route in
                            destination(route)
                        }
                }
            case .host(let host):
                NavigationStack(path: hostPathBinding(tab.id)) {
                    host.content()
                }
                // The host's own screens can draw in the site's list style.
                .cmsSiteTheme(runtime.themeConfig)
            case .feature:
                // Never shown: selecting the slot runs the action instead.
                Color.clear.accessibilityHidden(true)
            }
        }
        .modifier(CmsAccessoryStrip(accessory: tabBar?.accessory, runtime: runtime))
        // The page-level overlays the shared runtime drives: drawn in the
        // selected tab only, so a drawer opens once, over that tab's pages.
        .overlay(alignment: .bottomTrailing) {
            if isSelected { CmsFloatingChatHost(runtime: runtime) }
        }
    }

    /// A pushed route: a record form opened as a page, else a site page.
    @ViewBuilder
    private func destination(_ route: CmsAppRoute) -> some View {
        if let id = route.formID {
            if let make = runtime.formPages[id] { make() } else { EmptyView() }
        } else if let shell = page(route.pageSlug), CmsAppSection.isSectionShell(shell, siteShellId: loader.shellPageId) {
            CmsAppSectionListView(
                shell: shell,
                openableSlugs: openableSlugs,
                open: { open($0) },
                isTabRoot: { slug in nav?.rootSlugs.values.contains(slug) == true || slug == landingPage?.slug },
                runtime: runtime
            )
        } else {
            pageView(route.pageSlug, isRoot: false, scrollSignal: 0)
        }
    }

    /// Record forms opened as pages (CmsMasthead.swift) push onto the
    /// selected tab's own stack, so the system's back and swipe return.
    private func installFormPages() {
        runtime.pushFormPage = { id, make in
            let route = CmsAppRoute(pageSlug: "", formID: id)
            if var state = nav {
                // A host tab's stack is the host's own: the form opens as a sheet there.
                guard state.rootSlugs[state.selected] != nil else { return false }
                runtime.formPages[id] = make
                state.paths[state.selected, default: []].append(route)
                nav = state
                return true
            }
            runtime.formPages[id] = make
            singlePath.append(route)
            return true
        }
        runtime.closeFormPage = { id in
            if var state = nav {
                for (tab, path) in state.paths {
                    if let i = path.firstIndex(where: { $0.formID == id }) { state.paths[tab] = Array(path.prefix(i)) }
                }
                nav = state
            } else if let i = singlePath.firstIndex(where: { $0.formID == id }) {
                singlePath = Array(singlePath.prefix(i))
            }
            runtime.formPages[id] = nil
        }
    }

    @ViewBuilder
    private func pageView(_ slug: String, isRoot: Bool, scrollSignal: Int) -> some View {
        if let page = page(slug) {
            CmsPageBody(
                page: page,
                runtime: runtime,
                designController: loader.designController,
                // A tab's root page has no back swipe to keep, so a page with
                // a side region opens it by the edge swipe (the strip only
                // shows where there is a region); a pushed page keeps the edge.
                edgeSwipeEnabled: isRoot,
                hostsPageOverlays: false,
                showsDesignTools: showsDeveloperTools,
                scrollToTopSignal: scrollSignal
            )
            .navigationBarTitleDisplayMode(isRoot ? .large : .inline)
            .toolbar {
                // The tab bar's toolbar blocks (a bell, the account avatar) on each
                // tab's first page, where a website keeps them in its top bar.
                if isRoot, !toolbarBlocks.isEmpty {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        ForEach(toolbarBlocks, id: \.id) { block in
                            CmsBlockRegistry.render(block, axis: .horizontal)
                                // The navigation bar is outside CmsPageBody, which hands the
                                // runtime to the blocks inside it: without this a block reading
                                // it stopped the app (wac for business, 3 November 2026).
                                .environmentObject(runtime)
                        }
                    }
                }
            }
            .onAppear { loader.applyPageContext(page) }
        } else {
            ContentUnavailableView("Page unavailable", systemImage: "doc.questionmark")
        }
    }

    // MARK: No tab bar

    private var singleStack: some View {
        NavigationStack(path: $singlePath) {
            Group {
                if let landing = landingPage {
                    pageView(landing.slug, isRoot: true, scrollSignal: 0)
                } else {
                    ContentUnavailableView("No pages", systemImage: "doc")
                }
            }
            .navigationDestination(for: CmsAppRoute.self) { route in
                destination(route)
            }
        }
        .overlay(alignment: .bottomTrailing) { CmsFloatingChatHost(runtime: runtime) }
        .overlay { CmsDrawerOverlay(runtime: runtime) }
    }
}

// MARK: - System behaviours

/// The site's tint, when its theme names a primary colour. Nothing else about
/// the bar is set: no appearance, no background, no shadow.
private struct CmsTabBarTint: ViewModifier {
    @ObservedObject var runtime: CmsRuntime

    func body(content: Content) -> some View {
        if runtime.themeConfig?.palette?.primary != nil {
            content.tint(runtime.theme.primary)
        } else {
            content
        }
    }
}

/// iOS 26's bottom accessory and the bar shrinking on scroll.
@available(iOS 18, *)
private struct CmsTabBarSystemBehaviours: ViewModifier {
    let accessory: CmsBlock?
    /// The shell's floating chat, when it is the accessory.
    let chat: CmsBlock?
    let minimizeOnScroll: Bool
    let runtime: CmsRuntime

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            let minimizing = content.tabBarMinimizeBehavior(minimizeOnScroll ? .onScrollDown : .never)
            if let accessory {
                minimizing.tabViewBottomAccessory {
                    CmsBlockView(block: accessory, axis: .horizontal)
                        .environmentObject(runtime)
                        .padding(.horizontal, 12)
                }
            } else if let chat {
                minimizing.tabViewBottomAccessory {
                    CmsChatAccessory(block: chat, runtime: runtime)
                }
            } else {
                minimizing
            }
        } else {
            content
        }
    }
}

/// Before iOS 26, the accessory shows in a plain strip just above the bar, in
/// each tab. On iOS 26 the system's accessory holds it instead.
private struct CmsAccessoryStrip: ViewModifier {
    let accessory: CmsBlock?
    let runtime: CmsRuntime

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
        } else if let accessory {
            content.safeAreaInset(edge: .bottom, spacing: 0) {
                CmsBlockView(block: accessory, axis: .vertical)
                    .environmentObject(runtime)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
        } else {
            content
        }
    }
}

#endif
