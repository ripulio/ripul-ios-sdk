import Foundation

/// Swift mirrors of the CMS page-definition wire format defined in
/// `chrome-extension/src/api/services/cmsDefinitionsService.ts` (which itself
/// mirrors `packages/api/src/cmsDefinitions/types.ts`). Keep in sync — the
/// native renderer interprets the SAME JSON the web renderer does; there is
/// no native-specific page format.

public struct CmsBlockFrame: Codable, Equatable {
    public var size: String?          // 'hug' | 'fill' | 'fixed'
    public var fixedValue: String?
    public var width: String?
    public var minHeight: String?
    public var maxHeight: String?
    public var padding: String?
    public var margin: String?
    public var align: String?         // 'start' | 'center' | 'end'
    public var background: String?
    public var borderColor: String?
    public var borderStyle: String?
    public var borderWidth: String?
    public var borderRadius: String?
    public var shadow: String?
}

public struct CmsContainerFrame: Codable, Equatable {
    public var width: String?
    public var minWidth: String?
    public var maxWidth: String?
    public var minHeight: String?
    public var maxHeight: String?
    public var padding: String?
    public var gap: String?
    public var background: String?
    public var direction: String?     // 'column' | 'row'
    public var alignItems: String?
    public var justifyContent: String?
    public var wrap: String?
    public var overflow: String?
    public var borderColor: String?
    public var borderStyle: String?
    public var borderWidth: String?
    public var borderRadius: String?
    public var shadow: String?
    public var fullBleed: Bool?
}

public struct CmsBindingEntry: Codable, Equatable {
    public var querySlug: String
    public var column: String
    public var format: String?
}

public struct CmsCanvasPosition: Codable, Equatable {
    public var col: Int
    public var row: Int
    public var colSpan: Int
    public var rowSpan: Int
    public var z: Int?
}

public struct CmsBlock: Codable, Identifiable, Equatable {
    public var id: String
    public var slug: String?
    public var name: String?
    public var hidden: Bool?
    public var visibleOn: [String]?   // 'mobile' | 'desktop'
    public var type: String
    public var props: [String: CmsJSON]
    public var frame: CmsBlockFrame?
    public var position: CmsCanvasPosition?
    public var children: CmsPageBlocks?
    public var bindings: [String: CmsBindingEntry]?
}

/// Recursive block container, discriminated by `layout`.
/// The PoC renders `list` with full semantics; `template`/`sidebar` render
/// their slots stacked and `canvas`/`carousel` render items stacked — honest
/// simplifications, not web fallbacks.
public indirect enum CmsPageBlocks: Codable, Equatable {
    case list(items: [CmsBlock], frame: CmsContainerFrame?)
    case template(templateId: String, slots: [String: CmsPageBlocks], frame: CmsContainerFrame?)
    case canvas(items: [CmsBlock], columns: Int?, rowHeight: Int?, frame: CmsContainerFrame?)
    case carousel(items: [CmsBlock], frame: CmsContainerFrame?)
    case sidebar(variant: String, slots: [String: CmsPageBlocks], frame: CmsContainerFrame?)

    private enum CodingKeys: String, CodingKey {
        case layout, items, frame, templateId, slots, columns, rowHeight, variant
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let layout = try c.decode(String.self, forKey: .layout)
        let frame = try c.decodeIfPresent(CmsContainerFrame.self, forKey: .frame)
        switch layout {
        case "list":
            self = .list(items: try c.decode([CmsBlock].self, forKey: .items), frame: frame)
        case "template":
            self = .template(
                templateId: try c.decode(String.self, forKey: .templateId),
                slots: try c.decode([String: CmsPageBlocks].self, forKey: .slots),
                frame: frame
            )
        case "canvas":
            self = .canvas(
                items: try c.decode([CmsBlock].self, forKey: .items),
                columns: try c.decodeIfPresent(Int.self, forKey: .columns),
                rowHeight: try c.decodeIfPresent(Int.self, forKey: .rowHeight),
                frame: frame
            )
        case "carousel":
            self = .carousel(items: try c.decode([CmsBlock].self, forKey: .items), frame: frame)
        case "sidebar":
            self = .sidebar(
                variant: try c.decode(String.self, forKey: .variant),
                slots: try c.decode([String: CmsPageBlocks].self, forKey: .slots),
                frame: frame
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .layout, in: c,
                debugDescription: "Unknown CmsPageBlocks layout '\(layout)'"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .list(let items, let frame):
            try c.encode("list", forKey: .layout)
            try c.encode(items, forKey: .items)
            try c.encodeIfPresent(frame, forKey: .frame)
        case .template(let templateId, let slots, let frame):
            try c.encode("template", forKey: .layout)
            try c.encode(templateId, forKey: .templateId)
            try c.encode(slots, forKey: .slots)
            try c.encodeIfPresent(frame, forKey: .frame)
        case .canvas(let items, let columns, let rowHeight, let frame):
            try c.encode("canvas", forKey: .layout)
            try c.encode(items, forKey: .items)
            try c.encodeIfPresent(columns, forKey: .columns)
            try c.encodeIfPresent(rowHeight, forKey: .rowHeight)
            try c.encodeIfPresent(frame, forKey: .frame)
        case .carousel(let items, let frame):
            try c.encode("carousel", forKey: .layout)
            try c.encode(items, forKey: .items)
            try c.encodeIfPresent(frame, forKey: .frame)
        case .sidebar(let variant, let slots, let frame):
            try c.encode("sidebar", forKey: .layout)
            try c.encode(variant, forKey: .variant)
            try c.encode(slots, forKey: .slots)
            try c.encodeIfPresent(frame, forKey: .frame)
        }
    }

    public var containerFrame: CmsContainerFrame? {
        switch self {
        case .list(_, let f), .canvas(_, _, _, let f), .carousel(_, let f),
             .template(_, _, let f), .sidebar(_, _, let f):
            return f
        }
    }
}

public struct CmsPage: Codable, Identifiable, Equatable {
    public var id: String
    public var slug: String
    public var title: String
    public var bodyType: String       // 'markdown' | 'html' | 'blocks'
    public var body: String?
    public var blocks: CmsPageBlocks?
    public var requiresAuth: Bool?
    /// Roles allowed to view this page (mirrors the web's pageVisibility):
    /// "public" ⇒ everyone; empty/nil falls back to `requiresAuth`.
    public var requiredRoles: [String]?
    /// Native sidebar affordances (authored in page settings): show the
    /// slide-out icon row (default false — it costs a horizontal strip)
    /// and open drawers by edge swipe (default true).
    public var nativeSidebarIcon: Bool?
    public var nativeSidebarEdgeSwipe: Bool?
}

/// Role-based page visibility — exact mirror of the web's
/// `src/cms/pageVisibility.ts` (`canViewPage`): owner/admin bypass;
/// `requiredRoles` wins when configured ("public" ⇒ everyone); otherwise the
/// legacy fallback (`requiresAuth === false` ⇒ public, else members only).
public enum CmsPageVisibility {
    static let publicRole = "public"
    static let bypassRoles: Set<String> = ["owner", "admin"]

    public static func canView(_ page: CmsPage, membership: CmsPortalMembership?) -> Bool {
        if let role = membership?.role, bypassRoles.contains(role) { return true }
        if let required = page.requiredRoles, !required.isEmpty {
            if required.contains(publicRole) { return true }
            guard let role = membership?.role else { return false }
            return required.contains(role)
        }
        if page.requiresAuth == false { return true }
        return membership?.isMember == true
    }
}

/// Minimal slice of a CmsDefinition — the renderer needs pages plus query
/// metadata (paramSources) for cascading-parameter resolution.
public struct CmsRenderDefinition: Codable {
    public var id: String
    public var name: String?
    public var pages: [CmsPage]?
    public var queries: [CmsQueryDef]?
    public var theme: CmsPortalThemeConfig?
    /// Page designated as the portal SHELL: it renders as persistent chrome
    /// (nav blocks) and routed pages render inside its `pageOutlet`.
    public var shellPageId: String?
    /// Default entry page for the portal.
    public var landingPageId: String?
    /// Schema-wide shared column views (keyed by slug) — blocks reference one
    /// via `columnViewRef` to share a curated/ordered/labelled field set.
    public var columnViews: [CmsColumnView]?
    /// Schema-wide shared card views (keyed by slug) — the grid's `cards`
    /// projection references one via `cardViewRef` to design the cards
    /// distinctly from its columns (own field set + card chrome).
    public var cardViews: [CmsCardView]?
}

/// Shared column view (`columnViewRef` target): a named, query-scoped set of
/// column config entries (same shape as a block's inline `fields`/`columns`),
/// so multiple blocks share one field definition. Columns stay RAW JSON so
/// each block decodes the keys it cares about (key/valueFrom/label/visible/
/// format/checkbox/image/…).
public struct CmsColumnView: Codable, Equatable {
    public var slug: String
    public var name: String?
    public var querySlug: String?
    public var columns: [CmsJSON]?
}

/// Shared card view (`cardViewRef` target): the card-presentation sibling of
/// `CmsColumnView`. Same RAW-JSON `columns` overlay PLUS `card` chrome
/// (recordCards-compatible props — title/imageColumn/imageShape/imageHeight/
/// cardVariant/showImageInCard) that the grid's cards projection spreads onto
/// the card it renders.
public struct CmsCardView: Codable, Equatable {
    public var slug: String
    public var name: String?
    public var querySlug: String?
    public var columns: [CmsJSON]?
    public var card: CmsJSON?
}

/// Slice of CmsQuery the runtime needs: slug, the SQL text (only to filter
/// paramSources to params actually referenced), and the source map.
public struct CmsQueryDef: Codable, Equatable {
    public var slug: String
    public var sql: String?
    public var paramSources: [String: CmsQueryParamSource]?
}

/// Mirror of QueryParamSource — three variants folded into one shape exactly
/// as on the wire: shared `parameter`, `datePredicate` range-fold, or plain
/// selection (sourceQuerySlug + column).
public struct CmsQueryParamSource: Codable, Equatable {
    public var sourceQuerySlug: String?
    public var column: String?
    public var mode: String?           // 'single' | 'multi'
    public var debounceMs: Double?
    public var autoRefresh: Bool?
    public var optional: Bool?
    public var datePredicate: CmsDatePredicateSource?
    public var parameter: CmsParameterBindingSource?
}

public struct CmsDatePredicateSource: Codable, Equatable {
    public var `operator`: String      // eq | gt | gte | lt | lte | any
    public var toParam: String
    public var operatorSource: CmsOperatorSource?
}

public struct CmsOperatorSource: Codable, Equatable {
    public var sourceQuerySlug: String
    public var column: String
}

public struct CmsParameterBindingSource: Codable, Equatable {
    public var id: String
    public var kind: String
    public var projection: String
    public var toParam: String?
}

/// Slice of a SiteKey the renderer needs to resolve RLS context.
public struct CmsSiteKeySummary: Codable, Equatable {
    public var id: String
    public var name: String?
    public var publishableKey: String?
    public var cmsDefinitionId: String?
}

public struct CmsQueryResultColumn: Codable, Equatable {
    public var name: String
    public var type: String?
}

public struct CmsQueryResult {
    public var rows: [[String: CmsJSON]]
    public var schema: [CmsQueryResultColumn]
}
