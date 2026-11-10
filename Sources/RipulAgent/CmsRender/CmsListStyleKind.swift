#if os(iOS)
import Foundation

/// The `cmsList` style kind on the SDK's theme engine (docs/cms-list-styles.md).
///
/// Its built-in styles are `system`, `plain` and `cards`; a site's `listStyles`
/// are its other named styles; its default tier is `system`. Knobs are the
/// list style's settings flattened to dotted keys (`card.cornerRadius`,
/// `title.color`), and `layout` for `basedOn`.
///
/// A CMS site's styles stay out of the engine's live document: that document
/// belongs to the host app (it persists it and may publish it), and one app can
/// show several sites. So the renderer resolves with `RipulStyleKind.resolve`,
/// passing the site's styles as the named styles. A host that wants the kind in
/// its own theme editor adds `RipulStyleKind.cmsList()` to its spec.
public enum CmsListStyleKind {
    public static let name = "cmsList"
    /// The one element the kind resolves for: a list.
    public static let element = "cms.list"

    /// The knob keys, in editor order, with their editors.
    public static let knobs: [RipulStyleKnob] = {
        let roles = CmsPaletteRole.allCases.map { (raw: $0.rawValue, label: $0.rawValue) }
        return [
            RipulStyleKnob("layout", "Layout", .options(CmsListLayout.allCases.map { ($0.rawValue, $0.rawValue.capitalized) })),
            RipulStyleKnob("card.cornerRadius", "Card corner radius", .number(range: 0...40, fallback: 10)),
            RipulStyleKnob("card.fill", "Card fill", .options(roles)),
            RipulStyleKnob("card.border.color", "Border colour", .options(roles)),
            RipulStyleKnob("card.border.width", "Border width", .number(range: 0...4, fallback: 0, format: "%.1f")),
            RipulStyleKnob("card.shadow.color", "Shadow colour", .options(roles)),
            RipulStyleKnob("card.shadow.radius", "Shadow radius", .number(range: 0...30, fallback: 0)),
            RipulStyleKnob("card.shadow.offsetY", "Shadow offset", .number(range: -10...20, fallback: 0)),
            RipulStyleKnob("card.shadow.opacity", "Shadow opacity", .number(range: 0...1, fallback: 0, format: "%.2f")),
            RipulStyleKnob("card.gap", "Gap between cards", .number(range: 0...40, fallback: 0)),
            RipulStyleKnob("card.pageBackground", "Page background", .options(roles)),
            RipulStyleKnob("row.minHeight", "Row height", .number(range: 28...120, fallback: 44)),
            RipulStyleKnob("row.paddingVertical", "Row padding (vertical)", .number(range: 0...40, fallback: 11)),
            RipulStyleKnob("row.paddingHorizontal", "Row padding (sides)", .number(range: 0...48, fallback: 16)),
            RipulStyleKnob("row.separators", "Separators", .bool),
            RipulStyleKnob("row.chevron", "Chevron", .bool),
            RipulStyleKnob("picture.size", "Picture size", .number(range: 12...64, fallback: 28)),
            RipulStyleKnob("picture.badge", "Picture badge", .options([("none", "None"), ("circle", "Circle"), ("roundedSquare", "Rounded square")])),
            RipulStyleKnob("picture.badgeSize", "Badge size", .number(range: 16...80, fallback: 36)),
            RipulStyleKnob("picture.badgeTint", "Badge tint", .options(roles)),
            RipulStyleKnob("title.size", "Title size", .number(range: 10...34, fallback: 17)),
            RipulStyleKnob("title.weight", "Title weight", .number(range: 100...900, fallback: 400)),
            RipulStyleKnob("title.color", "Title colour", .options(roles)),
            RipulStyleKnob("subtitle.size", "Subtitle size", .number(range: 10...28, fallback: 15)),
            RipulStyleKnob("subtitle.color", "Subtitle colour", .options(roles)),
            RipulStyleKnob("trailing.size", "Trailing size", .number(range: 10...28, fallback: 17)),
            RipulStyleKnob("trailing.weight", "Trailing weight", .number(range: 100...900, fallback: 400)),
            RipulStyleKnob("trailing.color", "Trailing colour", .options(roles)),
            RipulStyleKnob("trailing.align", "Trailing position", .options([("center", "Centred"), ("top", "Top"), ("spread", "Value top, chip bottom")])),
            RipulStyleKnob("leading.width", "Leading width", .number(range: 24...96, fallback: 44)),
            RipulStyleKnob("leading.align", "Leading position", .options([("center", "Centred"), ("top", "Top")])),
            RipulStyleKnob("leading.date.top.size", "Weekday size", .number(range: 8...24, fallback: 12)),
            RipulStyleKnob("leading.date.top.weight", "Weekday weight", .number(range: 100...900, fallback: 600)),
            RipulStyleKnob("leading.date.top.color", "Weekday colour", .options(roles)),
            RipulStyleKnob("leading.date.top.uppercase", "Weekday in capitals", .bool),
            RipulStyleKnob("leading.date.top.letterSpacing", "Weekday letter spacing", .number(range: 0...4, fallback: 0.5, format: "%.1f")),
            RipulStyleKnob("leading.date.bottom.size", "Day size", .number(range: 12...40, fallback: 22)),
            RipulStyleKnob("leading.date.bottom.weight", "Day weight", .number(range: 100...900, fallback: 600)),
            RipulStyleKnob("leading.date.bottom.color", "Day colour", .options(roles)),
            RipulStyleKnob("lines.size", "Line size", .number(range: 10...24, fallback: 15)),
            RipulStyleKnob("lines.weight", "Line weight", .number(range: 100...900, fallback: 400)),
            RipulStyleKnob("lines.color", "Line colour", .options(roles)),
            RipulStyleKnob("lines.gap", "Gap between lines", .number(range: 0...12, fallback: 2)),
            RipulStyleKnob("inlineImage.size", "Line picture size", .number(range: 10...40, fallback: 18)),
            RipulStyleKnob("inlineImage.cornerRadius", "Line picture corners", .number(range: 0...20, fallback: 4)),
            RipulStyleKnob("chip.variant", "Chip", .options([("filled", "Filled"), ("outlined", "Outlined"), ("tinted", "Tinted")])),
            RipulStyleKnob("chip.cornerRadius", "Chip corners", .number(range: 0...999, fallback: 999)),
            RipulStyleKnob("chip.borderWidth", "Chip border", .number(range: 0...4, fallback: 1, format: "%.1f")),
            RipulStyleKnob("chip.size", "Chip text size", .number(range: 8...20, fallback: 12)),
            RipulStyleKnob("chip.weight", "Chip text weight", .number(range: 100...900, fallback: 600)),
            RipulStyleKnob("chip.paddingHorizontal", "Chip padding (sides)", .number(range: 0...20, fallback: 8)),
            RipulStyleKnob("chip.paddingVertical", "Chip padding (vertical)", .number(range: 0...12, fallback: 3)),
            RipulStyleKnob("chip.iconSize", "Chip icon size", .number(range: 6...24, fallback: 11)),
            RipulStyleKnob("chip.color", "Chip colour", .options(roles)),
        ]
    }()

    /// A style as knobs. Unset settings are absent.
    public static func knobs(_ style: CmsListStyle) -> [String: RipulKnob] {
        guard let data = try? JSONEncoder().encode(style),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var out: [String: RipulKnob] = [:]
        func walk(_ value: Any, _ path: String) {
            if let dict = value as? [String: Any] {
                for (key, child) in dict { walk(child, path.isEmpty ? key : "\(path).\(key)") }
            } else if let number = value as? NSNumber {
                // JSONSerialization hands Bools back as NSNumber; tell them apart.
                if CFGetTypeID(number) == CFBooleanGetTypeID() { out[path] = .bool(number.boolValue) }
                else { out[path] = .number(number.doubleValue) }
            } else if let string = value as? String {
                out[path] = .string(string)
            }
        }
        walk(object, "")
        if let layout = out.removeValue(forKey: "basedOn") { out["layout"] = layout }
        return out
    }

    /// Knobs back into a style. Unknown keys and wrong types are dropped.
    public static func style(_ knobs: [String: RipulKnob]) -> CmsListStyle {
        var root: [String: Any] = [:]
        func set(_ value: Any, at path: [String], in dict: inout [String: Any]) {
            guard let head = path.first else { return }
            if path.count == 1 { dict[head] = value; return }
            var child = dict[head] as? [String: Any] ?? [:]
            set(value, at: Array(path.dropFirst()), in: &child)
            dict[head] = child
        }
        for (key, knob) in knobs {
            let path = (key == "layout" ? "basedOn" : key).split(separator: ".").map(String.init)
            set(knob.jsonValue, at: path, in: &root)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: root),
              let style = try? JSONDecoder().decode(CmsListStyle.self, from: data) else { return CmsListStyle() }
        return style
    }

    /// The kind itself: the built-ins as its library, `system` as its default.
    public static func kind() -> RipulStyleKind {
        RipulStyleKind(
            name: name, label: "List styles", path: ["CMS"],
            defaultStyleLabel: "Default (system)",
            scopes: [RipulThemeScope(id: element, label: "Lists")],
            knobs: knobs,
            builtIns: CmsListStyle.builtIns.mapValues(knobs),
            defaultTier: { _, _ in knobs(.system) }
        )
    }

    /// The site's own styles as the kind's named styles: each one filled from
    /// its built-in, built-in names left out.
    public static func namedStyles(_ config: CmsPortalThemeConfig?) -> [String: [String: RipulKnob]] {
        var out: [String: [String: RipulKnob]] = [:]
        for (name, style) in config?.listStyles ?? [:] where CmsListStyle.builtIns[name] == nil {
            let base = CmsListStyle.builtIns[(style.basedOn ?? .system).rawValue] ?? .system
            out[name] = knobs(style.layered(over: base))
        }
        return out
    }

    /// Resolution through the engine's cascade: the block's style, else the
    /// theme's default, else `system`. Equal to `CmsPortalThemeConfig.listStyle`
    /// (a test holds them equal).
    public static func resolve(config: CmsPortalThemeConfig?, block: String?) -> CmsListStyle {
        let name = config.listStyle(block: block).name
        return style(kind().resolve(element: element, style: name, namedStyles: namedStyles(config)))
    }
}

extension RipulStyleKind {
    /// The CMS list style kind, for a host that adds it to its own theme spec.
    public static func cmsList() -> RipulStyleKind { CmsListStyleKind.kind() }
}
#endif
