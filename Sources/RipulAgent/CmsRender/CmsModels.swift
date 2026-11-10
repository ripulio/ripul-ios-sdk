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
    /// Edge to edge: the page's side margins go; as the first block of a
    /// title-hidden page it also runs under the status bar.
    public var bleed: Bool?
    /// Points: the block's surface grows by this much at its bottom, and what
    /// follows starts that much higher, drawn over it.
    public var overlap: Double?
    /// `behind`, on a page's first block: fixed while the page scrolls up over it.
    /// `bottom`, in a sidebar region: kept at the region's foot while the rest scrolls.
    public var pin: String?
    /// The pinned block: `sheet` makes what scrolls over it one sheet of the
    /// page's background; unset (`clear`) leaves it clear.
    public var pinCover: String?
    /// The pinned block: points at the top of its content never covered.
    public var pinKeep: Double?
    /// The pinned block: what follows goes under it at the cover line (its
    /// surface's bottom less `overlap`), cut `rounded` or `straight`; nil rides over it.
    public var pinUnder: String?

    private enum CodingKeys: String, CodingKey {
        case size, fixedValue, width, minHeight, maxHeight, padding, margin, align
        case background, borderColor, borderStyle, borderWidth, borderRadius, shadow, bleed, overlap, pin, pinCover, pinKeep, pinUnder
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        size = c.cssValue(.size)
        fixedValue = c.cssValue(.fixedValue, number: .size)
        width = c.cssValue(.width, number: .size)
        minHeight = c.cssValue(.minHeight, number: .size)
        maxHeight = c.cssValue(.maxHeight, number: .size)
        padding = c.cssValue(.padding, number: .spacing)
        margin = c.cssValue(.margin, number: .spacing)
        align = c.cssValue(.align)
        background = c.cssValue(.background)
        borderColor = c.cssValue(.borderColor)
        borderStyle = c.cssValue(.borderStyle)
        borderWidth = c.cssValue(.borderWidth, number: .pixels)
        borderRadius = c.cssValue(.borderRadius, number: .pixels)
        shadow = c.cssValue(.shadow)
        bleed = try? c.decodeIfPresent(Bool.self, forKey: .bleed)
        overlap = (try? c.decodeIfPresent(Double.self, forKey: .overlap)).flatMap { $0.flatMap { $0 > 0 ? $0 : nil } }
        pin = (try? c.decodeIfPresent(String.self, forKey: .pin)).flatMap { ["behind", "bottom"].contains($0) ? $0 : nil }
        pinCover = (try? c.decodeIfPresent(String.self, forKey: .pinCover)).flatMap { $0 == "sheet" ? "sheet" : nil }
        // 0 is kept: it cuts what scrolls at the content's top (below the status bar).
        pinKeep = (try? c.decodeIfPresent(Double.self, forKey: .pinKeep)).flatMap { $0.flatMap { $0 >= 0 ? $0 : nil } }
        pinUnder = (try? c.decodeIfPresent(String.self, forKey: .pinUnder)).flatMap { $0.flatMap { $0 == "rounded" || $0 == "straight" ? $0 : nil } }
    }
}

/// How a bare JSON number in a frame field reads on the web, where frames
/// reach MUI's `sx`: spacing keys multiply the theme spacing (8), sizing keys
/// are pixels above 1 and fractions at or below it, the rest are pixels.
enum CmsCssNumber { case spacing, size, pixels, none }

extension KeyedDecodingContainer {
    /// A frame field as a CSS string. Accepts the string the designer
    /// writes, or a number written by an agent or older tool, read the way
    /// MUI reads it. Anything else is unset rather than a failed page.
    func cssValue(_ key: Key, number: CmsCssNumber = .none) -> String? {
        if let s = try? decodeIfPresent(String.self, forKey: key) { return s }
        guard let n = try? decodeIfPresent(Double.self, forKey: key) else { return nil }
        func px(_ v: Double) -> String {
            v.rounded() == v ? "\(Int(v))px" : "\(v)px"
        }
        switch number {
        case .spacing: return px(n * 8)
        case .size: return n > 0 && n <= 1 ? "\(n * 100)%" : px(n)
        case .pixels: return px(n)
        case .none: return nil
        }
    }

    func lenientBool(_ key: Key) -> Bool? {
        try? decodeIfPresent(Bool.self, forKey: key)
    }
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
    /// A sidebar layout's side widths in points (`sidebarWidth`, and
    /// `leftSidebarWidth`/`rightSidebarWidth` beside it), read from the
    /// layout itself, not its frame. The phone's drawer takes them, capped
    /// to the screen.
    public var sidebarWidth: Double?
    public var leftSidebarWidth: Double?
    public var rightSidebarWidth: Double?

    private enum CodingKeys: String, CodingKey {
        case width, minWidth, maxWidth, minHeight, maxHeight, padding, gap, background
        case direction, alignItems, justifyContent, wrap, overflow
        case borderColor, borderStyle, borderWidth, borderRadius, shadow, fullBleed
    }

    public init() {}

    /// The drawer's width for a side: its own width, else the layout's.
    public func sidebarWidth(left: Bool) -> Double? {
        (left ? leftSidebarWidth : rightSidebarWidth) ?? sidebarWidth
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        width = c.cssValue(.width, number: .size)
        minWidth = c.cssValue(.minWidth, number: .size)
        maxWidth = c.cssValue(.maxWidth, number: .size)
        minHeight = c.cssValue(.minHeight, number: .size)
        maxHeight = c.cssValue(.maxHeight, number: .size)
        padding = c.cssValue(.padding, number: .spacing)
        gap = c.cssValue(.gap, number: .spacing)
        background = c.cssValue(.background)
        direction = c.cssValue(.direction)
        alignItems = c.cssValue(.alignItems)
        justifyContent = c.cssValue(.justifyContent)
        wrap = c.cssValue(.wrap)
        overflow = c.cssValue(.overflow)
        borderColor = c.cssValue(.borderColor)
        borderStyle = c.cssValue(.borderStyle)
        borderWidth = c.cssValue(.borderWidth, number: .pixels)
        borderRadius = c.cssValue(.borderRadius, number: .pixels)
        shadow = c.cssValue(.shadow)
        fullBleed = c.lenientBool(.fullBleed)
    }
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

    /// Placed content cells use the same nested containers as page slots.
    /// Include them in traversal so their independent queries and inspector
    /// edits work even when the grid itself has no record source.
    var gridContentSlots: [String: CmsPageBlocks] {
        guard let slots = props.object("gridLayout")?.object("slots") else { return [:] }
        return slots.compactMapValues { json in
            guard let data = try? JSONEncoder().encode(json) else { return nil }
            return try? JSONDecoder().decode(CmsPageBlocks.self, from: data)
        }
    }
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
        case sidebarWidth, leftSidebarWidth, rightSidebarWidth
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
            // The side widths sit on the layout, beside its slots.
            func width(_ key: CodingKeys) -> Double? {
                (try? c.decodeIfPresent(Double.self, forKey: key)).flatMap { $0.flatMap { $0 > 0 ? $0 : nil } }
            }
            var withWidths = frame
            let widths = (width(.sidebarWidth), width(.leftSidebarWidth), width(.rightSidebarWidth))
            if widths.0 != nil || widths.1 != nil || widths.2 != nil {
                if withWidths == nil { withWidths = CmsContainerFrame() }
                withWidths?.sidebarWidth = widths.0
                withWidths?.leftSidebarWidth = widths.1
                withWidths?.rightSidebarWidth = widths.2
            }
            self = .sidebar(
                variant: try c.decode(String.self, forKey: .variant),
                slots: try c.decode([String: CmsPageBlocks].self, forKey: .slots),
                frame: withWidths
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
            try c.encodeIfPresent(frame?.sidebarWidth, forKey: .sidebarWidth)
            try c.encodeIfPresent(frame?.leftSidebarWidth, forKey: .leftSidebarWidth)
            try c.encodeIfPresent(frame?.rightSidebarWidth, forKey: .rightSidebarWidth)
        }
    }

    public var containerFrame: CmsContainerFrame? {
        switch self {
        case .list(_, let f), .canvas(_, _, _, let f), .carousel(_, let f),
             .template(_, _, let f), .sidebar(_, _, let f):
            return f
        }
    }

    /// All blocks in this container, recursively (includes block children).
    public func allBlocks() -> [CmsBlock] {
        var result: [CmsBlock] = []
        func collect(_ container: CmsPageBlocks) {
            switch container {
            case .list(let items, _), .canvas(let items, _, _, _), .carousel(let items, _):
                for block in items {
                    result.append(block)
                    if let children = block.children { collect(children) }
                    for slot in block.gridContentSlots.values { collect(slot) }
                }
            case .template(_, let slots, _), .sidebar(_, let slots, _):
                for slot in slots.values { collect(slot) }
            }
        }
        collect(self)
        return result
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
    /// The page carries its own chrome (sign-in, onboarding): no shell.
    public var hideShell: Bool?
    /// `shown` (default) | `hidden`: no navigation title, and on iPhone the
    /// bar stays hidden at the top of the scroll; a pushed page keeps its back button.
    public var titleDisplay: String?
    /// The site's masthead at the top (CmsMasthead.swift): true, a style's name,
    /// or { style, title, subtitle, actions }. Drawn as a masthead block put first.
    public var masthead: CmsJSON?
    /// A shell of the page's own instead of the site's.
    public var shellPageId: String?
    /// `none`: no ☰ bar for the page's side regions (it opens them from its
    /// own button); the edge swipe stays.
    public var mobileBurgers: String?
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
    /// Saved views (a base query plus sources), beside the queries.
    public var views: [CmsViewDef]?
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
    public var portalConfig: CmsPortalConfig?
    public var mutations: [CmsMutationDef]?
    public var functions: [CmsFunctionDef]?
}

/// Site-owned deterministic JavaScript calculation function (`CmsFunction` in
/// `packages/shared-types/src/cmsFunctions.ts`), executed in an isolated
/// QuickJS sandbox when a form expression calls `fn.<slug>(...)`.
public struct CmsFunctionInputDef: Codable, Equatable {
    public var name: String
    /// `'number' | 'string' | 'boolean' | 'json'`
    public var type: String
    public var description: String?

    public init(name: String, type: String, description: String? = nil) {
        self.name = name
        self.type = type
        self.description = description
    }
}

public struct CmsFunctionTestDef: Codable, Equatable {
    public var name: String
    public var input: [String: CmsJSON]
    public var expect: CmsJSON

    public init(name: String, input: [String: CmsJSON], expect: CmsJSON) {
        self.name = name
        self.input = input
        self.expect = expect
    }
}

public struct CmsFunctionDef: Codable, Equatable {
    public var id: String
    public var slug: String
    public var name: String
    public var description: String?
    public var inputs: [CmsFunctionInputDef]
    /// `'number' | 'string' | 'boolean'`
    public var resultType: String
    public var code: String
    public var tests: [CmsFunctionTestDef]?

    public init(
        id: String,
        slug: String,
        name: String,
        description: String? = nil,
        inputs: [CmsFunctionInputDef],
        resultType: String,
        code: String,
        tests: [CmsFunctionTestDef]? = nil
    ) {
        self.id = id
        self.slug = slug
        self.name = name
        self.description = description
        self.inputs = inputs
        self.resultType = resultType
        self.code = code
        self.tests = tests
    }
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

/// Slice of CmsMutation an action needs: how its params resolve, what to
/// ask first, what to say after, and which queries to refresh.
public struct CmsMutationDef: Codable, Equatable {
    public var slug: String
    public var name: String?
    public var paramSources: [String: CmsQueryParamSource]?
    public var confirmMessage: String?
    public var successMessage: String?
    public var invalidateQueries: [String]?
    /// The action contract: the inputs an action button asks for in a form
    /// before it runs (`CmsActionForm`).
    public var action: CmsActionConfigDef?

    private enum CodingKeys: String, CodingKey {
        case slug, name, paramSources, confirmMessage, successMessage, invalidateQueries, action
    }

    /// Lenient past the slug: a mutation is a side table to rendering, so an
    /// odd field drops that field, never the site.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slug = try c.decode(String.self, forKey: .slug)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        paramSources = try? c.decodeIfPresent([String: CmsQueryParamSource].self, forKey: .paramSources)
        confirmMessage = try? c.decodeIfPresent(String.self, forKey: .confirmMessage)
        successMessage = try? c.decodeIfPresent(String.self, forKey: .successMessage)
        invalidateQueries = try? c.decodeIfPresent([String].self, forKey: .invalidateQueries)
        action = try? c.decodeIfPresent(CmsActionConfigDef.self, forKey: .action)
    }

    public init(slug: String, name: String? = nil, paramSources: [String: CmsQueryParamSource]? = nil,
                confirmMessage: String? = nil, successMessage: String? = nil,
                invalidateQueries: [String]? = nil, action: CmsActionConfigDef? = nil) {
        self.slug = slug; self.name = name; self.paramSources = paramSources
        self.confirmMessage = confirmMessage; self.successMessage = successMessage
        self.invalidateQueries = invalidateQueries; self.action = action
    }

    /// Whether its form is the record form (`CmsRecordFormSheet`) rather than
    /// the plain input list: it has a layout (`action.form`), or an input the
    /// plain list can't serve (hidden, computed, or a choice that fills others).
    /// The web's one dialog serves all of them.
    public var opensRecordForm: Bool {
        action?.form != nil || (action?.inputs ?? []).contains {
            $0.hidden == true || $0.fromComputed != nil || $0.optionsQuery?.fills != nil
        }
    }
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
