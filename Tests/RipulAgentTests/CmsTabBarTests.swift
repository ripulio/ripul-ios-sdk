import XCTest
@testable import RipulAgent

/// The `tabBar` block on iPhone: decoding, who sees which tab, routing a link
/// to the right tab, and what a re-tap of the selected tab does
/// (docs/cms-app-view.md).
final class CmsTabBarTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private func page(_ slug: String, requiresAuth: Bool? = false, roles: [String]? = nil, blocks: String? = nil) throws -> CmsPage {
        var fields = [#""id": "id-\#(slug)""#, #""slug": "\#(slug)""#, #""title": "\#(slug.capitalized)""#, #""bodyType": "blocks""#]
        if let requiresAuth { fields.append(#""requiresAuth": \#(requiresAuth)"#) }
        if let roles { fields.append(#""requiredRoles": [\#(roles.map { "\"\($0)\"" }.joined(separator: ","))]"#) }
        if let blocks { fields.append(#""blocks": \#(blocks)"#) }
        return try decode(CmsPage.self, "{" + fields.joined(separator: ",") + "}")
    }

    private func shell(tabBarProps: String) throws -> CmsPage {
        try page("shell", blocks: """
        {"layout": "list", "items": [
            {"id": "b1", "type": "text", "props": {"text": "Hi"}},
            {"id": "b2", "type": "container", "props": {}, "children": {"layout": "list", "items": [
                {"id": "tb", "type": "tabBar", "props": \(tabBarProps)}
            ]}}
        ]}
        """)
    }

    private let member = CmsPortalMembership(isMember: true, role: "staff", canDesign: false, email: nil)

    // MARK: The shell's floating chat ("Ask us")

    private func shell(chats: String) throws -> CmsPage {
        try page("shell", blocks: """
        {"layout": "list", "items": [
            {"id": "tb", "type": "tabBar", "props": {}},
            {"id": "wrap", "type": "container", "props": {}, "children": {"layout": "list", "items": [\(chats)]}}
        ]}
        """)
    }

    /// The first agentChat with `fab` anywhere in the shell, as the web shows it
    /// on every page; a docked one, a hidden one or one for desktops only is not.
    func testShellChatIsTheFirstFloatingOneShownOnPhones() throws {
        XCTAssertEqual(CmsFloatingChat.find(shell: try shell(chats: """
            {"id": "docked", "type": "agentChat", "props": {}},
            {"id": "ask", "type": "agentChat", "props": {"fab": true, "fabLabel": "Ask us"}}
            """))?.id, "ask")
        XCTAssertNil(CmsFloatingChat.find(shell: try shell(chats: """
            {"id": "desk", "type": "agentChat", "visibleOn": ["desktop"], "props": {"fab": true}},
            {"id": "off", "type": "agentChat", "hidden": true, "props": {"fab": true}}
            """)))
        XCTAssertEqual(CmsFloatingChat.find(shell: try shell(chats: """
            {"id": "both", "type": "agentChat", "visibleOn": ["mobile", "desktop"], "props": {"fab": true}}
            """))?.id, "both")
        XCTAssertNil(CmsFloatingChat.find(shell: nil))
    }

    func testFloatingChatLabel() throws {
        let page = try shell(chats: """
            {"id": "a", "type": "agentChat", "props": {"fab": true, "fabLabel": "Ask us", "title": "Chat with us"}},
            {"id": "b", "type": "agentChat", "props": {"fab": true, "fabLabel": "", "title": "Chat with us"}},
            {"id": "c", "type": "agentChat", "props": {"fab": true}}
            """)
        let chats = page.blocks?.allBlocks().filter { $0.type == "agentChat" } ?? []
        XCTAssertEqual(chats.map(CmsFloatingChat.label), ["Ask us", "Chat with us", "Chat"])
    }

    // MARK: Decoding

    func testDecodesItemsAccessoryAndMinimize() throws {
        let shell = try shell(tabBarProps: """
        {"items": [
            {"label": "Shifts", "icon": "calendar", "targetPageSlug": "shifts", "badge": "3", "badgeTone": "error"},
            {"label": "Jobs", "icon": "work", "targetPageSlug": "jobs", "targetViewRef": "grid:open"}
        ],
         "accessory": {"type": "actionButton", "props": {"label": "Clock in"}},
         "minimizeOnScroll": false}
        """)
        let config = try XCTUnwrap(CmsTabBarConfig.find(shell: shell))
        XCTAssertEqual(config.items.map(\.label), ["Shifts", "Jobs"])
        XCTAssertEqual(config.items[0].badge, "3")
        XCTAssertEqual(config.items[0].badgeTone, "error")
        XCTAssertEqual(config.items[1].targetViewRef, "grid:open")
        XCTAssertEqual(config.accessory?.type, "actionButton")
        XCTAssertEqual(config.accessory?.props.string("label"), "Clock in")
        XCTAssertFalse(config.minimizeOnScroll)
    }

    func testDefaultsWhenPropsAreAbsent() throws {
        let config = try XCTUnwrap(CmsTabBarConfig.find(shell: try shell(tabBarProps: "{}")))
        XCTAssertTrue(config.items.isEmpty)
        XCTAssertNil(config.accessory)
        XCTAssertTrue(config.minimizeOnScroll, "minimizeOnScroll defaults on")
        XCTAssertTrue(config.toolbar.isEmpty)
    }

    /// The toolbar (wac for business's bell and avatar): blocks in order, for the
    /// people who may see them, on the iPhone only, each its own identity.
    func testToolbarBlocksFollowVisibilityAndPlatform() throws {
        let shell = try shell(tabBarProps: """
        {"items": [{"label": "Home", "targetPageSlug": "home", "platforms": ["native"]}],
         "toolbar": [
            {"label": "Notifications", "visibility": "roles", "requiredRoles": ["manager"],
             "block": {"type": "notificationCentre", "props": {"heading": "Notifications"}}},
            {"label": "Account", "block": {"type": "userAccount", "props": {"display": "avatar"}}},
            {"label": "Web only", "platforms": ["web"], "block": {"type": "userAccount", "props": {}}},
            {"label": "No block"}
         ]}
        """)
        let config = try XCTUnwrap(CmsTabBarConfig.find(shell: shell))
        XCTAssertEqual(config.toolbar.count, 4)

        let manager = CmsPortalMembership(isMember: true, role: "manager", canDesign: false, email: nil)
        let forManager = config.visibleToolbar(membership: manager, canDesign: false)
        XCTAssertEqual(forManager.map(\.type), ["notificationCentre", "userAccount"])
        XCTAssertEqual(forManager.first?.props.string("heading"), "Notifications")
        XCTAssertEqual(Set(forManager.map(\.id)).count, 2, "each toolbar block has its own identity")

        let forStaff = config.visibleToolbar(membership: member, canDesign: false)
        XCTAssertEqual(forStaff.map(\.type), ["userAccount"], "the bell is for managers only")
    }

    func testNoTabBarWithoutShellOrBlock() throws {
        XCTAssertNil(CmsTabBarConfig.find(shell: nil))
        let plain = try page("shell", blocks: #"{"layout": "list", "items": [{"id": "n", "type": "topNav", "props": {}}]}"#)
        XCTAssertNil(CmsTabBarConfig.find(shell: plain))
    }

    // MARK: Who sees which tab

    func testVisibleTabsFollowNavAndPageVisibility() throws {
        let shell = try shell(tabBarProps: """
        {"items": [
            {"label": "Home", "icon": "home", "targetPageSlug": "home"},
            {"label": "Members", "targetPageSlug": "members-page", "visibility": "members"},
            {"label": "Managers", "targetPageSlug": "managers", "visibility": "roles", "requiredRoles": ["manager"]},
            {"label": "Hidden page", "targetPageSlug": "secret"},
            {"label": "No page", "url": "https://example.com"},
            {"label": "Again", "targetPageSlug": "home"},
            {"label": "Group", "heading": true},
            {"label": "Slot", "slotId": "account", "targetPageSlug": "home"},
            {"label": "Reports", "targetPageSlug": "reports", "divider": true},
            {"label": "Acts", "targetPageSlug": "jobs", "actionType": "mutation", "children": [{"label": "c", "targetPageSlug": "x"}]}
        ]}
        """)
        let config = try XCTUnwrap(CmsTabBarConfig.find(shell: shell))
        let openable: Set<String> = ["home", "members-page", "managers", "jobs", "reports"]

        let visitor = config.visibleTabs(openableSlugs: openable, membership: nil, canDesign: false)
        XCTAssertEqual(visitor.map(\.pageSlug), ["home", "reports", "jobs"],
                       "members-only and role tabs hide; a page the visitor can't open hides; no page, a duplicate, a heading and a slot item never become tabs; fields a tab doesn't use (divider, children, actionType) are ignored")

        let staff = config.visibleTabs(openableSlugs: openable, membership: member, canDesign: false)
        XCTAssertEqual(staff.map(\.pageSlug), ["home", "members-page", "reports", "jobs"])

        let manager = CmsPortalMembership(isMember: true, role: "manager", canDesign: false, email: nil)
        XCTAssertEqual(config.visibleTabs(openableSlugs: openable, membership: manager, canDesign: false).map(\.pageSlug),
                       ["home", "members-page", "managers", "reports", "jobs"])

        let designer = config.visibleTabs(openableSlugs: openable, membership: nil, canDesign: true)
        XCTAssertEqual(designer.map(\.pageSlug), ["home", "members-page", "managers", "reports", "jobs"], "designers see every tab")
    }

    func testAWebOnlyTabIsSkippedKeepingOrderAndTheRememberedTab() throws {
        let config = try XCTUnwrap(CmsTabBarConfig.find(shell: try shell(tabBarProps: """
        {"items": [
            {"label": "Shifts", "targetPageSlug": "shifts"},
            {"label": "Account", "targetPageSlug": "account", "platforms": ["web"]},
            {"label": "Jobs", "targetPageSlug": "jobs", "platforms": ["web", "native"]},
            {"label": "Pay", "targetPageSlug": "pay", "platforms": ["native"]}
        ]}
        """)))
        let tabs = config.visibleTabs(openableSlugs: ["shifts", "account", "jobs", "pay"], membership: nil, canDesign: false)
        XCTAssertEqual(tabs.map(\.pageSlug), ["shifts", "jobs", "pay"], "the web-only Account tab is skipped, the rest in order")
        XCTAssertEqual(config.items[1].platforms, ["web"])
        XCTAssertNil(config.items[0].platforms, "unset shows on both")
        // The remembered tab is by page, so Jobs after the skipped item is still Jobs.
        let ids = tabs.map(\.id)
        let state = CmsAppNavigationState(siteTabs: tabs.map { (id: $0.id, rootSlug: $0.pageSlug) },
                                          tabIDs: ids + ["host:account"], selected: CmsAppTabID.site("jobs"))
        XCTAssertEqual(state.selected, "page:jobs")
        let stale = CmsAppNavigationState(siteTabs: tabs.map { (id: $0.id, rootSlug: $0.pageSlug) },
                                          tabIDs: ids + ["host:account"], selected: CmsAppTabID.site("account"))
        XCTAssertEqual(stale.selected, "page:shifts", "a remembered web-only tab falls back to the first")
    }

    func testTabIdentityIconAndTitle() throws {
        let shell = try shell(tabBarProps: """
        {"items": [{"label": "Shifts", "icon": "calendar", "targetPageSlug": "shifts"},
                   {"label": "", "icon": "no-such-icon", "targetPageSlug": "jobs"}]}
        """)
        let tabs = try XCTUnwrap(CmsTabBarConfig.find(shell: shell))
            .visibleTabs(openableSlugs: ["shifts", "jobs"], membership: nil, canDesign: false)
        XCTAssertEqual(tabs[0].id, "page:shifts")
        XCTAssertEqual(tabs[0].accessibilityIdentifier, "tabbar.shifts")
        XCTAssertEqual(tabs[0].systemImage, "calendar")
        XCTAssertEqual(tabs[1].title, "jobs", "an empty label falls back to the page slug")
        XCTAssertEqual(tabs[1].systemImage, "doc.text", "an unknown icon key gets the page symbol")
    }

    // MARK: Routing

    private func state(selected: String? = nil) -> CmsAppNavigationState {
        CmsAppNavigationState(
            siteTabs: [(id: "page:shifts", rootSlug: "shifts"), (id: "page:jobs", rootSlug: "jobs")],
            tabIDs: ["page:shifts", "page:jobs", "host:account"],
            selected: selected
        )
    }

    private let openable: Set<String> = ["shifts", "jobs", "shift-detail", "job-detail"]

    func testSelectionRestoresOnlyAKnownTab() {
        XCTAssertEqual(state().selected, "page:shifts", "first tab by default")
        XCTAssertEqual(state(selected: "page:jobs").selected, "page:jobs")
        XCTAssertEqual(state(selected: "host:account").selected, "host:account")
        XCTAssertEqual(state(selected: "page:gone").selected, "page:shifts", "a stored tab that no longer exists falls back")
    }

    func testOtherPagesPushOntoTheSelectedTab() {
        var nav = state()
        XCTAssertEqual(nav.open(pageSlug: "shift-detail", openableSlugs: openable), .pushed(tab: "page:shifts"))
        XCTAssertEqual(nav.paths["page:shifts"], [CmsAppRoute(pageSlug: "shift-detail")])
        XCTAssertEqual(nav.topSlug(of: "page:shifts"), "shift-detail")
        XCTAssertEqual(nav.open(pageSlug: "shift-detail", openableSlugs: openable), .unchanged, "the page on top isn't pushed twice")
        XCTAssertEqual(nav.open(pageSlug: "job-detail", openableSlugs: openable), .pushed(tab: "page:shifts"))
        XCTAssertEqual(nav.paths["page:shifts"]?.count, 2)
    }

    func testATabsFirstPageSelectsThatTabAndPopsIt() {
        var nav = state()
        nav.selected = "page:jobs"
        nav.open(pageSlug: "job-detail", openableSlugs: openable)
        nav.selected = "page:shifts"
        nav.open(pageSlug: "shift-detail", openableSlugs: openable)

        XCTAssertEqual(nav.open(pageSlug: "jobs", openableSlugs: openable), .selectedTab("page:jobs"))
        XCTAssertEqual(nav.selected, "page:jobs")
        XCTAssertEqual(nav.paths["page:jobs"], [], "the tab shows the page the link named")
        XCTAssertEqual(nav.paths["page:shifts"]?.count, 1, "the tab left keeps its place")

        XCTAssertEqual(nav.open(pageSlug: "jobs", openableSlugs: openable), .unchanged)
    }

    func testUnknownPagesAreIgnored() {
        var nav = state()
        XCTAssertEqual(nav.open(pageSlug: "nope", openableSlugs: openable), .ignored)
        XCTAssertEqual(nav, state())
    }

    func testFromAHostTabPagesOpenInTheFirstSiteTab() {
        var nav = state(selected: "host:account")
        XCTAssertEqual(nav.open(pageSlug: "shift-detail", openableSlugs: openable), .pushed(tab: "page:shifts"))
        XCTAssertEqual(nav.selected, "page:shifts")
    }

    // MARK: Re-tap

    func testReselectPopsThenScrollsToTop() {
        XCTAssertEqual(CmsAppReselect.action(stackDepth: 2), .popToRoot)
        XCTAssertEqual(CmsAppReselect.action(stackDepth: 1), .popToRoot)
        XCTAssertEqual(CmsAppReselect.action(stackDepth: 0), .scrollToTop)
    }

    // MARK: While the site isn't loaded

    func testHostTabsStayWhileTheSiteIsNotLoaded() {
        XCTAssertEqual(CmsAppLayout.whileNotLoaded(hostTabCount: 1), .statusBesideHostTabs,
                       "a host's Account tab stays reachable when the site refuses or fails to load")
        XCTAssertEqual(CmsAppLayout.whileNotLoaded(hostTabCount: 0), .statusOnly)
    }

    func testTabMemoryIsPerSite() {
        let defaults = UserDefaults(suiteName: "CmsTabBarTests.memory")!
        defaults.removePersistentDomain(forName: "CmsTabBarTests.memory")
        let a = CmsAppTabMemory(cmsId: "cms_a", defaults: defaults)
        let b = CmsAppTabMemory(cmsId: "cms_b", defaults: defaults)
        XCTAssertEqual(a.stored, "")
        a.stored = CmsAppTabID.host("account")
        XCTAssertEqual(a.stored, "host:account")
        XCTAssertEqual(b.stored, "", "each site remembers its own tab")
        XCTAssertEqual(a.key, "io.ripul.cms.app.tab.cms_a")
    }

    // MARK: CmsPortalMenu

    func testPortalMenuTabs() throws {
        let shell = try shell(tabBarProps: """
        {"items": [{"label": "Shifts", "icon": "calendar", "targetPageSlug": "shifts"},
                   {"label": "Private", "targetPageSlug": "private"}]}
        """)
        let pages = [try page("shifts"), try page("private", requiresAuth: true), shell]
        let bySlug = Dictionary(uniqueKeysWithValues: pages.map { ($0.slug, $0) })

        XCTAssertEqual(CmsPortalMenuResolver.tabItems(shell: shell, pageBySlug: bySlug, membership: nil).map(\.pageSlug), ["shifts"])
        let tabs = CmsPortalMenuResolver.tabItems(shell: shell, pageBySlug: bySlug, membership: member)
        XCTAssertEqual(tabs.map(\.pageSlug), ["shifts", "private"])
        XCTAssertEqual(tabs[0].systemImage, "calendar")
        XCTAssertTrue(tabs.allSatisfy { $0.children.isEmpty && $0.url == nil })

        let plain = try page("shell")
        XCTAssertEqual(CmsPortalMenuResolver.tabItems(shell: plain, pageBySlug: bySlug, membership: member), [])
    }

    // MARK: In a page

    @MainActor
    func testTabBarIsRegisteredAsNothingInAPage() {
        XCTAssertTrue(CmsBlockRegistry.supports("tabBar"))
    }
}
