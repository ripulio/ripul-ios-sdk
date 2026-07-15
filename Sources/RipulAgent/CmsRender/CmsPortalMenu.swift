import Foundation

/// Host-sidebar merge protocol: the CMS *contributes* menu items, the host app
/// (e.g. WAC) *merges* them into its own native sidebar/menu and owns their
/// placement and presentation. The SDK never draws the host's chrome — it hands
/// over a resolved, role-filtered model and a way to open each target page.
///
/// This is the embedder↔CMS contract for navigation:
///   1. Host calls `CmsPortalMenu.resolve(...)` with the user's portal credentials.
///   2. SDK validates membership and returns the portal's nav items the user's
///      role may actually reach (mirrors the web's page visibility exactly).
///   3. Host renders each item as a native row; tapping presents
///      `CmsPageView(cmsId:pageSlug:...)` at that item's page.
///
/// Gating falls out for free: a non-member (or blocked / uninvited user on an
/// invite-only portal) resolves to `isMember == false` with no items, so the
/// host simply shows nothing.

/// One contributed menu item, already resolved for native rendering.
public struct CmsPortalMenuItem: Identifiable, Equatable {
    /// Stable within a resolve (target slug, else label) — safe as a SwiftUI id.
    public let id: String
    public let label: String
    /// SF Symbol name resolved from the CMS icon key, or nil for no icon.
    public let systemImage: String?
    /// Portal page to open when tapped. nil when the item is a pure submenu
    /// parent or an external link.
    public let pageSlug: String?
    /// External URL, when the item links out rather than to a portal page.
    public let url: URL?
    /// Nested items (submenus). Empty for leaves.
    public let children: [CmsPortalMenuItem]
}

/// The resolved contribution: membership plus the items to merge.
public struct CmsPortalMenu: Equatable {
    /// True when the caller is a portal member. The host shows the section
    /// only when this is true.
    public let isMember: Bool
    /// The member's role (drives which items were kept), or nil if not a member.
    public let role: String?
    /// True when the member may enter delegated design mode.
    public let canDesign: Bool
    /// Top-level items, role-filtered. Empty when not a member.
    public let items: [CmsPortalMenuItem]

    /// The "nothing to show" contribution — not a member / could not resolve.
    public static let none = CmsPortalMenu(isMember: false, role: nil, canDesign: false, items: [])
}

@available(iOS 15.0, macOS 13.0, *)
public enum CmsPortalMenuResolver {
    /// Resolve the portal's menu contribution for the current user.
    ///
    /// Reuses the single site-key validate response the renderer already
    /// fetches (pages + shell nav travel inside it) plus one `/v1/site-key/me`
    /// call — no bespoke endpoint. Returns `.none` on any failure or for a
    /// non-member, so the host has one simple contract: show the section iff
    /// `isMember` and `items` is non-empty.
    ///
    /// - Parameters:
    ///   - cmsId: the CMS definition id (informational; the menu is read from
    ///     the site key's embedded config).
    ///   - siteKey: the portal's publishable key.
    ///   - clientConfig: the SAME config used for `CmsPageView` — its
    ///     `portalCredentialProvider` supplies the app credentials that prove
    ///     membership.
    ///   - baseURL: portal host for validation (defaults to the Ripul portal host).
    public static func resolve(
        cmsId: String,
        siteKey: String,
        clientConfig: CmsClientConfig,
        baseURL: URL = URL(string: RipulDomain.demoURL)!
    ) async -> CmsPortalMenu {
        // 1. Membership — the gate. No credentials / not invited / blocked → nothing.
        let client = CmsClient(config: clientConfig)
        guard let membership = try? await client.fetchPortalMembership(siteKey: siteKey),
              membership.isMember else {
            return .none
        }

        // 2. The embedded config carries the pages and the shell's nav blocks.
        let result = await SiteKeyValidator.validate(siteKey: siteKey, baseURL: baseURL)
        guard let json = result.configJSON, let data = json.data(using: .utf8),
              let config = try? JSONDecoder().decode(PortalConfigSlice.self, from: data),
              let cms = config.cms else {
            // Authenticated but couldn't read the menu — still a member, just
            // no contributed items (host can fall back to a single portal link).
            return CmsPortalMenu(isMember: true, role: membership.role,
                                 canDesign: membership.canDesign ?? false, items: [])
        }

        let pages = cms.pages ?? []
        let pageBySlug = Dictionary(pages.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })

        // Authoritative source: the shell page's sidebarNav (fall back to topNav).
        let shell = cms.shellPageId.flatMap { id in pages.first { $0.id == id } }
        let navItems = navSource(in: shell?.blocks) ?? pages.lazy.compactMap { navSource(in: $0.blocks) }.first ?? []

        let items = filter(navItems, pageBySlug: pageBySlug, membership: membership)
        return CmsPortalMenu(isMember: true, role: membership.role,
                             canDesign: membership.canDesign ?? false, items: items)
    }

    // MARK: - Config slice

    /// Minimal decode of the validate config — just the pages + shell id.
    /// `CmsPage` already decodes its blocks, so the nav tree comes with it.
    private struct PortalConfigSlice: Decodable {
        struct Cms: Decodable {
            var pages: [CmsPage]?
            var shellPageId: String?
        }
        var cms: Cms?
    }

    // MARK: - Nav extraction

    /// The nav items authored on a page: prefer a `sidebarNav` block, else a
    /// `topNav` block, searched through the block tree.
    private static func navSource(in blocks: CmsPageBlocks?) -> [CmsNavItem]? {
        var found: [CmsBlock] = []
        collectNavBlocks(blocks, into: &found)
        let block = found.first { $0.type == "sidebarNav" } ?? found.first { $0.type == "topNav" }
        guard let block else { return nil }
        return CmsNavItem.decodeList(block.props["items"])
    }

    private static func collectNavBlocks(_ blocks: CmsPageBlocks?, into out: inout [CmsBlock]) {
        guard let blocks else { return }
        switch blocks {
        case .list(let items, _), .canvas(let items, _, _, _), .carousel(let items, _):
            for b in items {
                if b.type == "sidebarNav" || b.type == "topNav" { out.append(b) }
                collectNavBlocks(b.children, into: &out)
            }
        case .template(_, let slots, _), .sidebar(_, let slots, _):
            for slot in slots.values { collectNavBlocks(slot, into: &out) }
        }
    }

    // MARK: - Role filtering (mirrors CmsPageVisibility)

    /// Keep an item when the user can reach its target page, it links out, or
    /// it still has visible children — dropping unreachable/no-target items
    /// (e.g. a "Login" entry) exactly as the web nav hides them.
    private static func filter(
        _ items: [CmsNavItem],
        pageBySlug: [String: CmsPage],
        membership: CmsPortalMembership
    ) -> [CmsPortalMenuItem] {
        items.compactMap { item -> CmsPortalMenuItem? in
            let kids = filter(item.children, pageBySlug: pageBySlug, membership: membership)
            var reachableSlug: String?
            if let slug = item.targetPageSlug, let page = pageBySlug[slug],
               CmsPageVisibility.canView(page, membership: membership) {
                reachableSlug = slug
            }
            let external = item.url.flatMap { URL(string: $0) }
            guard reachableSlug != nil || external != nil || !kids.isEmpty else { return nil }
            return CmsPortalMenuItem(
                id: reachableSlug ?? item.url ?? item.label,
                label: item.label,
                systemImage: CmsNavIcon.symbol(for: item.icon),
                pageSlug: reachableSlug,
                url: external,
                children: kids
            )
        }
    }
}
