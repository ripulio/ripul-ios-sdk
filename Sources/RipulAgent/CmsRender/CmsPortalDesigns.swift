import Foundation

/// Twin of `portalDesigns.ts`: alternative looks of one live site. A design
/// names a shell, a landing page and pages it swaps in; a swapped page shows
/// its replacement under the original's slug, so links and nav highlights
/// keep working. The first design is the default; the visitor's choice is
/// kept per site (the web keeps it in localStorage under the same key).
public struct CmsPortalDesign: Codable, Equatable {
    public var id: String
    public var label: String?
    public var shellPageId: String?
    public var landingPageId: String?
    public var pages: [String: String]?

    public init(id: String, label: String? = nil, shellPageId: String? = nil,
                landingPageId: String? = nil, pages: [String: String]? = nil) {
        self.id = id
        self.label = label
        self.shellPageId = shellPageId
        self.landingPageId = landingPageId
        self.pages = pages
    }
}

/// The slice of `portalConfig` the renderer reads.
public struct CmsPortalConfig: Codable, Equatable {
    public var designs: [CmsPortalDesign]?

    private enum CodingKeys: String, CodingKey { case designs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        designs = try? c.decodeIfPresent([CmsPortalDesign].self, forKey: .designs)
    }
}

enum CmsPortalDesigns {
    static func storageKey(_ cmsId: String) -> String { "ripul.portalDesign:\(cmsId)" }

    /// The visitor's design: their last choice when it still exists, else the first.
    static func chosen(cmsId: String, designs: [CmsPortalDesign], defaults: UserDefaults = .standard) -> CmsPortalDesign? {
        guard !designs.isEmpty else { return nil }
        if let stored = defaults.string(forKey: storageKey(cmsId)),
           let match = designs.first(where: { $0.id == stored }) {
            return match
        }
        return designs[0]
    }

    struct Applied {
        var pages: [CmsPage]
        var shellPageId: String?
        var landingPageId: String?
    }

    /// `applyDesign`: swapped-in pages take the original's place and slug and
    /// leave their own; the design's shell replaces the site's shell wherever
    /// a page uses it, by default or by naming it.
    static func apply(pages: [CmsPage], shellPageId: String?, landingPageId: String?, design: CmsPortalDesign?) -> Applied {
        guard let design else { return Applied(pages: pages, shellPageId: shellPageId, landingPageId: landingPageId) }
        let swaps = design.pages ?? [:]
        let byId = Dictionary(pages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let swappedIn = Set(swaps.values.filter { byId[$0] != nil })
        let designShell = design.shellPageId.flatMap { byId[$0] != nil ? $0 : nil }
        func reshell(_ page: CmsPage) -> CmsPage {
            guard let designShell, let siteShell = shellPageId, page.shellPageId == siteShell else { return page }
            var copy = page
            copy.shellPageId = designShell
            return copy
        }
        var out: [CmsPage] = []
        for page in pages {
            if let targetId = swaps[page.id], var target = byId[targetId] {
                target.slug = page.slug
                out.append(reshell(target))
            } else if !swappedIn.contains(page.id) {
                out.append(reshell(page))
            }
        }
        func mapId(_ id: String?) -> String? {
            guard let id else { return nil }
            if let swapped = swaps[id], byId[swapped] != nil { return swapped }
            return id
        }
        let landing = design.landingPageId.flatMap { byId[$0] != nil ? $0 : nil } ?? landingPageId
        return Applied(pages: out, shellPageId: designShell ?? shellPageId, landingPageId: mapId(landing))
    }
}
