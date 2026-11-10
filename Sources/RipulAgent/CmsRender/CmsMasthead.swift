import Foundation

/// A site's masthead and how its record forms open: the web's
/// `packages/shared-types/src/cmsMasthead.ts`, held to the same table
/// (`cmsMasthead.cases.json`, `CmsMastheadTests`). docs/cms-masthead.md.
///
/// - `theme.mastheads` / `defaultMasthead`: named masthead styles.
/// - a page's `masthead`: a `masthead` block put first, bleeding, pinned behind,
///   what follows cutting in by the style's `overlap`; the page's title moves into it.
/// - `theme.formPresentation` and a form's `presentation`: `sheet` or `page`.
/// - the viewer's choice, kept on the device (`UserDefaults`).
public enum CmsMasthead {
    public static let builtin = "standard"
    public static let pageBlockId = "page_masthead"

    /// One style with every value filled.
    public struct Style: Equatable {
        public var name = CmsMasthead.builtin
        /// A palette role, or nil for the brand gradient.
        public var fill: CmsPaletteRole? = .primary
        public var text: CmsPaletteRole = .paper
        public var subtitleOpacity: Double = 0.75
        public var centred = false
        public var titleSize: Double = 28
        public var titleWeight: Double = 700
        public var subtitleSize: Double = 15
        public var height: Double = 96
        public var padding: Double = 20
        public var overlap: Double = 24
        /// `over` (what follows rides over the band) or `under` (it goes under at the cut-in line).
        public var scroll = "over"
        /// With `under`: `rounded` (a card's corners kept at the line) or `straight`.
        public var cut = "rounded"

        public var isGradient: Bool { fill == nil }
    }

    /// How what follows scrolls: a page's or form's own setting, else the style's.
    static func scrolling(_ style: Style, scroll: String?, cut: String?) -> (under: Bool, rounded: Bool) {
        let s = scroll == "under" || scroll == "over" ? scroll! : style.scroll
        let c = cut == "rounded" || cut == "straight" ? cut! : style.cut
        return (s == "under", c == "rounded")
    }

    static func hasStyle(_ theme: CmsPortalThemeConfig?, _ name: String) -> Bool {
        name == builtin || theme?.mastheads?[name]?.objectValue != nil
    }

    /// The style a name means: the named one (unknown or unset = `defaultMasthead`,
    /// else the built-in), over the built-in's values; a wrong value is ignored.
    public static func style(_ theme: CmsPortalThemeConfig?, named name: String?) -> Style {
        func pick(_ n: String?) -> String? { n.flatMap { !$0.isEmpty && hasStyle(theme, $0) ? $0 : nil } }
        let chosen = pick(name) ?? pick(theme?.defaultMasthead) ?? builtin
        var s = Style()
        s.name = chosen
        guard chosen != builtin, let o = theme?.mastheads?[chosen]?.objectValue else { return s }
        func num(_ key: String, _ lo: Double, _ hi: Double) -> Double? {
            guard let v = o.double(key), v.isFinite, v >= lo, v <= hi else { return nil }
            return v
        }
        if o.string("fill") == "gradient" { s.fill = nil } else if let r = o.string("fill").flatMap(CmsPaletteRole.init(rawValue:)) { s.fill = r }
        if let r = o.string("text").flatMap(CmsPaletteRole.init(rawValue:)) { s.text = r }
        if let v = num("subtitleOpacity", 0, 1) { s.subtitleOpacity = v }
        if let a = o.string("align"), a == "center" || a == "leading" { s.centred = a == "center" }
        if let v = num("titleSize", 8, 200) { s.titleSize = v }
        if let v = num("titleWeight", 100, 900) { s.titleWeight = v }
        if let v = num("subtitleSize", 6, 100) { s.subtitleSize = v }
        if let v = num("height", 0, 600) { s.height = v }
        if let v = num("padding", 0, 100) { s.padding = v }
        if let v = num("overlap", 0, 300) { s.overlap = v }
        if let v = o.string("scroll"), v == "over" || v == "under" { s.scroll = v }
        if let v = o.string("cut"), v == "rounded" || v == "straight" { s.cut = v }
        return s
    }

    /// A page's masthead setting as the block's props, or nil for none.
    public static func pageProps(_ masthead: CmsJSON?, title: String?) -> [String: CmsJSON]? {
        switch masthead {
        case .bool(true)?:
            return ["title": .string(title ?? "")]
        case .string(let name)? where !name.trimmingCharacters(in: .whitespaces).isEmpty:
            return ["style": .string(name.trimmingCharacters(in: .whitespaces)), "title": .string(title ?? "")]
        case .object(let o)?:
            var props: [String: CmsJSON] = ["title": .string(o.string("title") ?? title ?? "")]
            if let s = o.string("style"), !s.isEmpty { props["style"] = .string(s) }
            if let s = o.string("subtitle"), !s.isEmpty { props["subtitle"] = .string(s) }
            if case .array(let a)? = o["actions"], !a.isEmpty { props["actions"] = .array(a) }
            if let v = o.string("scroll"), v == "over" || v == "under" { props["scroll"] = .string(v) }
            if let v = o.string("cut"), v == "rounded" || v == "straight" { props["cut"] = .string(v) }
            return props
        default:
            return nil
        }
    }

    /// The page's blocks with its masthead put first, where `CmsLevers.firstBlock`
    /// looks: a list's items, or a template's or sidebar's `main` slot (else its first).
    static func withMasthead(_ blocks: CmsPageBlocks?, masthead: CmsJSON?, title: String?, theme: CmsPortalThemeConfig?) -> CmsPageBlocks? {
        guard let blocks, let props = pageProps(masthead, title: title) else { return blocks }
        let style = style(theme, named: props["style"]?.stringValue)
        // over: what scrolls rides over the band, cut at its content's top (pinKeep 0), below
        // the status bar. under: it goes under the band at the cut-in line (pinUnder), as WAC does.
        let how = scrolling(style, scroll: props["scroll"]?.stringValue, cut: props["cut"]?.stringValue)
        var frame: [String: CmsJSON] = ["bleed": .bool(true), "pin": .string("behind")]
        if how.under { frame["pinUnder"] = .string(how.rounded ? "rounded" : "straight") } else { frame["pinKeep"] = .number(0) }
        if style.overlap > 0 { frame["overlap"] = .number(style.overlap) }
        let raw: CmsJSON = .object(["id": .string(pageBlockId), "type": .string("masthead"), "props": .object(props), "frame": .object(frame)])
        guard let data = try? JSONEncoder().encode(raw), let block = try? JSONDecoder().decode(CmsBlock.self, from: data) else { return blocks }
        func place(_ c: CmsPageBlocks) -> CmsPageBlocks? {
            switch c {
            case .list(let items, let frame):
                return items.contains { $0.id == pageBlockId } ? c : .list(items: [block] + items, frame: frame)
            case .canvas(let items, let columns, let rowHeight, let frame):
                return items.contains { $0.id == pageBlockId } ? c : .canvas(items: [block] + items, columns: columns, rowHeight: rowHeight, frame: frame)
            case .carousel(let items, let frame):
                return items.contains { $0.id == pageBlockId } ? c : .carousel(items: [block] + items, frame: frame)
            case .template(let id, var slots, let frame):
                guard let key = slots["main"] != nil ? "main" : slots.keys.sorted().first, let inner = slots[key].flatMap(place) else { return nil }
                slots[key] = inner
                return .template(templateId: id, slots: slots, frame: frame)
            case .sidebar(let variant, var slots, let frame):
                guard let key = slots["main"] != nil ? "main" : slots.keys.sorted().first, let inner = slots[key].flatMap(place) else { return nil }
                slots[key] = inner
                return .sidebar(variant: variant, slots: slots, frame: frame)
            }
        }
        return place(blocks) ?? blocks
    }

    /// The page as it is viewed: its masthead put first and its title hidden (the band shows it).
    public static func applied(_ page: CmsPage, theme: CmsPortalThemeConfig?) -> CmsPage {
        guard pageProps(page.masthead, title: page.title) != nil, page.bodyType == "blocks" else { return page }
        var out = page
        out.blocks = withMasthead(page.blocks, masthead: page.masthead, title: page.title, theme: theme)
        out.titleDisplay = "hidden"
        return out
    }

    // MARK: How a record form opens

    public enum Presentation: String, Equatable { case sheet, page }
    /// The viewer's choice; `site` follows each form's and the theme's setting.
    public enum ViewerChoice: String, CaseIterable, Equatable {
        case site, sheet, page
        public var label: String {
            switch self {
            case .site: return "As the site sets"
            case .sheet: return "Sheets"
            case .page: return "Pages"
            }
        }
        public init(stored: String?) { self = ViewerChoice(rawValue: stored ?? "") ?? .site }
    }

    static func viewerChoiceAllowed(_ theme: CmsPortalThemeConfig?) -> Bool {
        theme?.formPresentation?.objectValue?.bool("viewerChoice") == true
    }

    /// The viewer's choice when the theme allows one and it isn't `site`; else
    /// the form's own; else the theme's default; else a sheet.
    public static func presentation(form: String?, theme: CmsPortalThemeConfig?, viewer: String?) -> Presentation {
        if viewerChoiceAllowed(theme), let v = viewer.flatMap(Presentation.init(rawValue:)) { return v }
        if let f = form.flatMap(Presentation.init(rawValue:)) { return f }
        if let d = theme?.formPresentation?.objectValue?.string("default").flatMap(Presentation.init(rawValue:)) { return d }
        return .sheet
    }

    /// Where the viewer's choice is kept (the web's localStorage key).
    public static func storageKey(cmsId: String) -> String { "ripul.cms.\(cmsId).formPresentation" }

    static func storedChoice(cmsId: String) -> String? {
        UserDefaults.standard.string(forKey: storageKey(cmsId: cmsId))
    }

    static func setChoice(_ choice: ViewerChoice, cmsId: String) {
        if choice == .site {
            UserDefaults.standard.removeObject(forKey: storageKey(cmsId: cmsId))
        } else {
            UserDefaults.standard.set(choice.rawValue, forKey: storageKey(cmsId: cmsId))
        }
    }

    /// How a form opens for this viewer now.
    @MainActor static func presentation(of form: CmsFormDef?, runtime: CmsRuntime) -> Presentation {
        guard let form else { return .sheet }
        return presentation(form: form.presentation, theme: runtime.themeConfig, viewer: storedChoice(cmsId: runtime.cmsId))
    }

    static func flipLabel(_ current: Presentation) -> String { current == .page ? "Open as sheet" : "Open as page" }
}
