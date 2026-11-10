import Foundation

/// The `tabBar` nav block (TabBarBlock on the web), placed on the site's
/// shell page. `CmsAppView` draws it as the system's own tab bar; the
/// in-page renderer (`CmsPageView`) draws nothing for it. The shape both
/// renderers build to is in `docs/plans/cms-app-tab-bar.md`, "The agreed
/// shape"; the iPhone side is described in `docs/cms-app-view.md`.
struct CmsTabBarConfig {
    /// The tabs as authored (decoded with the shared nav item model). Only the
    /// tab fields are read: label, icon, targetPageSlug, targetViewRef, badge,
    /// badgeTone, visibility, requiredRoles, platforms.
    var items: [CmsNavItem]
    /// One block shown just above the bar (`{ type, props }`).
    var accessory: CmsBlock?
    /// iOS 26: the bar shrinks while scrolling down. Default true.
    var minimizeOnScroll: Bool
    /// An outsized, branded button in a slot of the bar that runs an action
    /// instead of opening a tab (CmsTabBarFeature.swift).
    var featureButton: CmsTabBarFeature?
    /// Blocks in the navigation bar of every tab's first page, at the trailing
    /// end (`toolbar`: nav items each with an embedded `block`, such as the bell
    /// and the account avatar a website keeps at the right of its top bar).
    var toolbar: [CmsNavItem]

    static let blockType = "tabBar"

    init(items: [CmsNavItem], accessory: CmsBlock? = nil, minimizeOnScroll: Bool = true,
         featureButton: CmsTabBarFeature? = nil, toolbar: [CmsNavItem] = []) {
        self.items = items
        self.accessory = accessory
        self.minimizeOnScroll = minimizeOnScroll
        self.featureButton = featureButton
        self.toolbar = toolbar
    }

    /// Decode a `tabBar` block's raw props. Every prop is optional.
    init(block: CmsBlock) {
        self.init(
            items: CmsNavItem.decodeList(block.props["items"]),
            accessory: CmsNavItem.embedBlock(block.props["accessory"], id: "tabBar.accessory"),
            minimizeOnScroll: block.props.bool("minimizeOnScroll") ?? true,
            featureButton: CmsTabBarFeature(block.props["featureButton"]).flatMap { $0.showsNatively ? $0 : nil },
            toolbar: CmsNavItem.decodeList(block.props["toolbar"])
        )
    }

    /// The toolbar's blocks this visitor gets, in authored order: an item with an
    /// embedded block that the person may see (`canViewNavItem`) and whose
    /// `platforms` include `native`. Anything else a nav item carries is ignored.
    func visibleToolbar(membership: CmsPortalMembership?, canDesign: Bool) -> [CmsBlock] {
        toolbar.enumerated().compactMap { index, item in
            guard item.showsNatively, item.canView(membership: membership, canDesign: canDesign),
                  var block = item.embed else { return nil }
            // Each its own identity, so two of one type are two items.
            block.id = "tabBar.toolbar.\(index)"
            return block
        }
    }

    /// The site's tab bar: the first `tabBar` block on the shell page, searched
    /// through its whole block tree. nil when there is no shell or no tab bar
    /// on it (`check_site` warns about one placed elsewhere; neither renderer
    /// reads it there).
    static func find(shell: CmsPage?) -> CmsTabBarConfig? {
        guard let block = shell?.blocks?.allBlocks().first(where: { $0.type == blockType }) else { return nil }
        return CmsTabBarConfig(block: block)
    }

    /// The tabs this visitor gets, in authored order: an item is kept when the
    /// person may see it (`canViewNavItem`) and its page is one they can open
    /// (`openableSlugs`, already filtered by page visibility). Fields a tab
    /// does not use (children, url, an action, an embedded block, iconOnly,
    /// the divider flag) are ignored, never acted on. An item whose `platforms`
    /// leaves out `native` is skipped (tab ids are by page, so the order and
    /// the remembered tab hold around it). Headings are dropped,
    /// and so is a slot item (`slotId`, which `CmsNavItem.decode` already
    /// leaves out), as on the web. A second tab for the same page is dropped,
    /// since a page is the first page of one tab only.
    func visibleTabs(
        openableSlugs: Set<String>,
        membership: CmsPortalMembership?,
        canDesign: Bool
    ) -> [CmsAppSiteTab] {
        var seen = Set<String>()
        return items.compactMap { item in
            guard !item.heading, item.showsNatively,
                  item.canView(membership: membership, canDesign: canDesign),
                  let slug = item.targetPageSlug, openableSlugs.contains(slug),
                  seen.insert(slug).inserted else { return nil }
            return CmsAppSiteTab(item: item, pageSlug: slug)
        }
    }
}

/// One of the site's tabs, resolved for this visitor.
struct CmsAppSiteTab: Identifiable {
    let item: CmsNavItem
    /// The tab's first page.
    let pageSlug: String

    var id: String { CmsAppTabID.site(pageSlug) }
    var title: String { item.label.isEmpty ? pageSlug : item.label }
    var systemImage: String { CmsNavIcon.symbol(for: item.icon) ?? "doc.text" }
    /// `tabbar.<page slug>`, for UI tests.
    var accessibilityIdentifier: String { "tabbar.\(pageSlug)" }
}

/// Tab selection values. A site tab and a host tab can never collide.
enum CmsAppTabID {
    static func site(_ pageSlug: String) -> String { "page:\(pageSlug)" }
    static func host(_ id: String) -> String { "host:\(id)" }
    /// The tab standing in for the site's while it isn't loaded.
    static let status = "status"
    /// The feature button's reserved slot: selecting it runs its action, and
    /// the selected tab stays as it was.
    static let feature = "feature"
}

/// What `CmsAppView` draws while the site isn't loaded (loading, a failed
/// load, no access).
enum CmsAppLayout: Equatable {
    /// The status view alone (no host tabs to keep).
    case statusOnly
    /// The system tab bar: a status tab beside the host's own tabs, so an
    /// Account or Settings screen stays reachable.
    case statusBesideHostTabs

    static func whileNotLoaded(hostTabCount: Int) -> CmsAppLayout {
        hostTabCount > 0 ? .statusBesideHostTabs : .statusOnly
    }

    /// The host tabs drawn beside the site's: a host tab gives way to a site tab whose
    /// page has its id, so a site can take over a screen the app drew until then (WAC
    /// Next's Account) by configuration alone. While the site isn't loaded every host
    /// tab stays.
    static func shownHostTabIDs(_ hostTabIDs: [String], sitePageSlugs: [String]) -> [String] {
        let site = Set(sitePageSlugs)
        return hostTabIDs.filter { !site.contains($0) }
    }

    /// The remembered tab, carried over when a host tab has given way: the site tab
    /// of the same id takes its place.
    static func rememberedTab(_ stored: String, shownHostTabIDs: [String], sitePageSlugs: [String]) -> String {
        let prefix = CmsAppTabID.host("")
        guard stored.hasPrefix(prefix) else { return stored }
        let id = String(stored.dropFirst(prefix.count))
        if !shownHostTabIDs.contains(id), sitePageSlugs.contains(id) { return CmsAppTabID.site(id) }
        return stored
    }
}

/// A page pushed onto a tab's stack.
struct CmsAppRoute: Hashable {
    let pageSlug: String
    /// A record form opened as a page (`CmsRuntime.formPages`), not a site page.
    var formID: UUID? = nil
}

/// The tabs' selection and stacks, kept apart from SwiftUI so the routing and
/// re-tap rules can be tested. Host tabs' stacks are the host's own
/// (`NavigationPath`), so only their depth reaches the re-tap rule.
struct CmsAppNavigationState: Equatable {
    /// Tab ids in bar order (host tabs included).
    var tabIDs: [String]
    /// First page of each site tab, by tab id.
    var rootSlugs: [String: String]
    var selected: String
    /// Pages pushed onto each site tab, below its first page.
    var paths: [String: [CmsAppRoute]] = [:]

    init(siteTabs: [(id: String, rootSlug: String)], tabIDs: [String], selected: String? = nil) {
        self.tabIDs = tabIDs
        self.rootSlugs = Dictionary(siteTabs.map { ($0.id, $0.rootSlug) }, uniquingKeysWith: { first, _ in first })
        let restored = selected.flatMap { tabIDs.contains($0) ? $0 : nil }
        self.selected = restored ?? tabIDs.first ?? ""
    }

    enum OpenOutcome: Equatable {
        /// The page is a tab's first page: that tab is selected and popped to it.
        case selectedTab(String)
        /// The page was pushed onto this tab's stack.
        case pushed(tab: String)
        /// Already on screen; nothing changed.
        case unchanged
        /// No such page for this visitor (a dead link, as on the web).
        case ignored
    }

    /// Open a page, from a link inside a page or from the host.
    ///
    /// 1. The first page of a tab: select that tab and pop it to that page.
    /// 2. Any other page the visitor can open: push it onto the selected tab.
    ///    When a host tab is selected, it goes onto the first site tab instead,
    ///    since a host tab's stack belongs to the host.
    /// 3. Opening the page already on top of the stack does nothing.
    ///
    /// A page with a section shell of its own (`sectionShell`, CmsAppSection)
    /// pushes that section's list first, unless the stack is already in it.
    @discardableResult
    mutating func open(pageSlug: String, openableSlugs: Set<String>, sectionShell: String? = nil) -> OpenOutcome {
        if let tab = tabIDs.first(where: { rootSlugs[$0] == pageSlug }) {
            if selected == tab && (paths[tab] ?? []).isEmpty { return .unchanged }
            selected = tab
            paths[tab] = []
            return .selectedTab(tab)
        }
        guard openableSlugs.contains(pageSlug) else { return .ignored }
        let target: String
        if rootSlugs[selected] != nil {
            target = selected
        } else if let firstSite = tabIDs.first(where: { rootSlugs[$0] != nil }) {
            target = firstSite
        } else {
            return .ignored
        }
        if selected == target, paths[target]?.last?.pageSlug == pageSlug { return .unchanged }
        selected = target
        if let sectionShell, openableSlugs.contains(sectionShell),
           !(paths[target] ?? []).contains(where: { $0.pageSlug == sectionShell && $0.formID == nil }) {
            paths[target, default: []].append(CmsAppRoute(pageSlug: sectionShell))
        }
        paths[target, default: []].append(CmsAppRoute(pageSlug: pageSlug))
        return .pushed(tab: target)
    }

    /// After signing in or out: the tabs this person now has, each keeping its
    /// stack up to the first page they can no longer open (a record form
    /// stays with the page under it). The selection stays when it still exists.
    func following(siteTabs: [(id: String, rootSlug: String)], tabIDs: [String], openableSlugs: Set<String>) -> CmsAppNavigationState {
        var next = CmsAppNavigationState(siteTabs: siteTabs, tabIDs: tabIDs, selected: selected)
        for (tab, path) in paths where next.rootSlugs[tab] != nil {
            let cut = path.firstIndex { $0.formID == nil && !openableSlugs.contains($0.pageSlug) }
            next.paths[tab] = cut.map { Array(path.prefix($0)) } ?? path
        }
        return next
    }

    /// The page on top of a site tab's stack.
    func topSlug(of tab: String) -> String? {
        paths[tab]?.last(where: { $0.formID == nil })?.pageSlug ?? rootSlugs[tab]
    }
}

/// What tapping the tab that is already selected does — UIKit's own rule for
/// a tab bar controller: the first tap pops to the tab's first page, the next
/// one scrolls that page to the top.
enum CmsAppReselect: Equatable {
    case popToRoot
    case scrollToTop

    static func action(stackDepth: Int) -> CmsAppReselect {
        stackDepth > 0 ? .popToRoot : .scrollToTop
    }
}

/// The `UserDefaults` half of the remembered tab, per site; the scene's own
/// `@SceneStorage` under the same key is read first.
struct CmsAppTabMemory {
    let key: String
    var defaults: UserDefaults = .standard

    init(cmsId: String, defaults: UserDefaults = .standard) {
        self.key = "io.ripul.cms.app.tab.\(cmsId)"
        self.defaults = defaults
    }

    var stored: String {
        get { defaults.string(forKey: key) ?? "" }
        nonmutating set { defaults.set(newValue, forKey: key) }
    }
}
