import Foundation
import CoreGraphics

// MARK: - Which tokens an element is drawn with
//
// SwiftUI draws into layers, so the view a person selects in the View Explorer holds no
// colour and no font to read back. The source does: an identified element is a view
// expression ending in `.uiKitIdentifier("…")`, and the accessors in that expression are
// what it is drawn with. `tools/ripul-theme usage-map` reads them at build
// time and writes a map from identifier to tokens, which the app bundles as
// `ripul-theme-usage.json`. This file reads that map and says what each token resolves to
// in the live theme. It has no UIKit, so it is tested on macOS.
//
// No call site declares anything: the identifier and the accessor were already there.

/// The build-time map from an element's identifier to the theme accessors in its source.
public struct RipulThemeUsageMap: Sendable {
    /// The name of the bundled file, without its extension.
    public static let resourceName = "ripul-theme-usage"

    /// One accessor found in an element's source.
    public struct Token: Equatable, Sendable {
        public enum Kind: String, Sendable {
            /// `.ripul(.text)`, `Color.ripul(.surface)`, `.ripul(accentOr: .info)`
            case colour
            /// `.ripul(system: .systemGray5)`: a system colour, never themed
            case system
            /// `.ripul(.body)` as a font, and `ripulTextStyle(.eyebrow)`
            case type
            /// `.ripul(size: 14)`: a fixed size in a theme family
            case size
            /// `.ripulIcon(…)`: a symbol's size, never themed
            case icon
            /// `.tint`, `Color.accentColor`: the accent, through the window's tint
            case tint
            /// `ripulProminentButtonStyle()`, `Section(themed:)` and the rest of `RipulThemeControls`
            case control
            /// `.ripul(role)`: a role only known when the code runs
            case dynamic
            /// A font or colour written on the element that is not a token: a model's colour,
            /// a material, a value passed in
            case other
        }
        public var kind: Kind
        /// The colour or type role, the system colour's name, or the control's name.
        public var name: String?
        public var size: String?
        public var weight: String?
        public var family: String?
        /// "Foreground", "Fill", "Font": what the accessor was given to.
        public var property: String?
        /// A view, a property or a local the accessor was reached through.
        public var via: String?
        /// Written on a view that encloses the element, not on the element itself.
        public var inherited = false
        /// One of several the code chooses between when it runs.
        public var conditional = false
        public var accentOr = false
        /// The `Button`, `Menu` or `Link` whose label the accessor is in. The system colours
        /// such a label itself: its hierarchical styles follow the control's tint.
        public var control: String?
        /// The `.buttonStyle( )` chained to that control, as written: `.plain`.
        public var controlStyle: String?
        /// True when the control is in a toolbar, whose buttons the system draws in the
        /// label colour until a theme names an accent.
        public var inToolbar = false
        /// True when the control is an item of a menu, a context menu, swipe actions, an
        /// alert or a dialog, which the system draws in its own colours.
        public var inMenu = false
        /// True for `Color.ripul( )` and `UIColor.ripul( )`: a fixed colour, which a control
        /// does not recolour.
        public var isColorForm = false
        public var file: String
        public var line: Int
        public var source: String?
    }

    /// One place an identifier is written.
    public struct Site: Equatable, Sendable {
        public var file: String
        public var line: Int
        public var tokens: [Token]
        /// Identified parts inside this element, each with tokens of its own.
        public var parts: [String]
        /// True when the expression holds text, a label or a control with a title.
        public var hasText: Bool
        public var truncated: Bool
    }

    private let exact: [String: [Site]]
    /// Identifiers with an interpolation, kept as patterns: `row.*`. Longest literal first.
    private let patterns: [(key: String, regex: NSRegularExpression, sites: [Site])]

    public var count: Int { exact.count + patterns.count }

    public init?(data: Data) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let elements = root["elements"] as? [String: Any] else { return nil }
        var exact: [String: [Site]] = [:]
        var patterns: [(key: String, regex: NSRegularExpression, sites: [Site])] = []
        for (key, raw) in elements {
            let sites = (raw as? [[String: Any]] ?? []).compactMap(Self.site)
            guard !sites.isEmpty else { continue }
            if key.contains("*") {
                // A pattern that is nearly all gap (`*.*`) would match any identifier: it
                // names nothing, so it is left out.
                guard key.filter({ $0.isLetter || $0.isNumber }).count >= 4 else { continue }
                let body = key.split(separator: "*", omittingEmptySubsequences: false)
                    .map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: ".+")
                if let regex = try? NSRegularExpression(pattern: "^" + body + "$") { patterns.append((key, regex, sites)) }
            } else {
                exact[key] = sites
            }
        }
        self.exact = exact
        self.patterns = patterns.sorted {
            let a = $0.key.filter { $0 != "*" }.count, b = $1.key.filter { $0 != "*" }.count
            return a != b ? a > b : $0.key < $1.key
        }
    }

    /// The places `identifier` is written, and the key that matched (a pattern for an
    /// identifier built at run time). nil when the map does not know it.
    public func sites(for identifier: String) -> (key: String, sites: [Site])? {
        if let sites = exact[identifier] { return (identifier, sites) }
        let range = NSRange(identifier.startIndex..., in: identifier)
        for pattern in patterns where pattern.key != "*" && pattern.regex.firstMatch(in: identifier, range: range) != nil {
            return (pattern.key, pattern.sites)
        }
        return nil
    }

    private static func site(_ raw: [String: Any]) -> Site? {
        guard let file = raw["file"] as? String, let line = raw["line"] as? Int else { return nil }
        // A token's file is its site's unless the token names another.
        return Site(file: file, line: line, tokens: (raw["tokens"] as? [[String: Any]] ?? []).compactMap { token($0, file: file) },
                    parts: raw["parts"] as? [String] ?? [], hasText: raw["text"] as? Bool ?? false,
                    truncated: raw["truncated"] as? Bool ?? false)
    }

    private static func token(_ raw: [String: Any], file: String) -> Token? {
        guard let kind = (raw["k"] as? String).flatMap(Token.Kind.init(rawValue:)) else { return nil }
        return Token(kind: kind, name: raw["role"] as? String ?? raw["name"] as? String ?? raw["style"] as? String,
                     size: raw["size"] as? String, weight: raw["weight"] as? String, family: raw["family"] as? String,
                     property: raw["property"] as? String, via: raw["via"] as? String,
                     inherited: raw["inherited"] as? Bool ?? false, conditional: raw["cond"] as? Bool ?? false,
                     accentOr: raw["accentOr"] as? Bool ?? false, control: raw["ctl"] as? String,
                     controlStyle: raw["ctlStyle"] as? String, inToolbar: raw["ctlIn"] as? String == "toolbar",
                     inMenu: raw["ctlIn"] as? String == "menu",
                     isColorForm: raw["form"] != nil, file: raw["file"] as? String ?? file,
                     line: raw["line"] as? Int ?? 0, source: raw["src"] as? String)
    }
}

/// One line of the explorer's Appearance section: a token, and what it is now.
public struct RipulThemeUsageLine: Equatable, Sendable {
    /// What the token styles: "Foreground", "Font (in titleFont, one of several)".
    public var property: String
    /// The token's name: `ripul.text`, `body`, `symbol size`.
    public var token: String
    /// What it resolves to now, in words: `system:label`, `Archivo 17 pt semibold`.
    public var value: String
    /// Where that value comes from: "default", "theme document", "never themed".
    public var origin: String
    /// The colour to show beside it, for a colour token.
    public var colour: RipulColorValue?
    /// True when the colour is the window's tint, which only a view can resolve.
    public var isWindowTint = false

    /// The line as the explorer's text readout prints it.
    public var text: String { "\(property): \(token) = \(value), \(origin)" }
}

extension RipulTheme {
    /// What a resolved colour is, in a document's own words.
    public static func describe(_ value: RipulColorValue) -> String {
        func one(_ literal: RipulColorLiteral) -> String {
            switch literal {
            case .system(let name): return "system:" + name
            case .asset(let name): return "the asset colour " + name
            case .rgba(let r, let g, let b, let a):
                let byte = { (v: Double) in Int((max(0, min(1, v)) * 255).rounded()) }
                let hex = String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
                return a < 0.999 ? hex + String(format: "%02X", byte(a)) : hex
            }
        }
        guard let dark = value.dark, dark != value.light else { return one(value.light) }
        return "\(one(value.light)) light, \(one(dark)) dark"
    }

    /// True when the document in use says something about this type role or its family.
    package static func typeOrigin(role: RipulTextRole?, family: RipulFontFamily) -> String {
        let typography = table.typography
        let familyThemed = typography.families[family.rawValue].map { $0 != family.defaultFace } ?? false
        let roleThemed = role.flatMap { typography.roles[$0.rawValue] }.map { !$0.isEmpty } ?? false
        switch (roleThemed, familyThemed) {
        case (true, true): return "role and family from the theme document"
        case (true, false): return "role from the theme document"
        case (false, true): return "family from the theme document"
        case (false, false): return "default"
        }
    }

    static func faceName(_ face: String) -> String {
        switch face {
        case "system": return "system font"
        case "system-serif": return "system serif"
        case "system-rounded": return "system rounded"
        case "system-monospaced": return "system monospaced"
        default: return face
        }
    }

    /// The lines for one token of the usage map, resolved against the live theme.
    public static func describe(_ token: RipulThemeUsageMap.Token) -> [RipulThemeUsageLine] {
        var notes: [String] = []
        if let via = token.via { notes.append("in \(via)") }
        if token.inherited { notes.append("from an enclosing view") }
        if token.conditional { notes.append("one of several") }
        func property(_ fallback: String) -> String {
            let base = token.property ?? fallback
            return notes.isEmpty ? base : "\(base) (\(notes.joined(separator: ", ")))"
        }
        func colourLine(_ role: RipulColorRole, as name: String, note: String? = nil) -> RipulThemeUsageLine {
            let value = color(role)
            let origin = isDefault(role) ? "default" : "theme document"
            return RipulThemeUsageLine(property: property(name), token: role.tokenName, value: describe(value),
                                       origin: note.map { "\(origin), \($0)" } ?? origin, colour: value)
        }
        func weight(_ resolved: String?) -> String {
            guard let w = token.weight ?? resolved else { return "" }
            return w == "?" ? " in a weight chosen at run time" : " \(w)"
        }

        switch token.kind {
        case .colour:
            guard let name = token.name else { return [] }
            // A role of the host's own is known once the app has read it. Named in the
            // source and not read yet, its default is not known here.
            guard let role = RipulColorRole(rawValue: name) else {
                return [RipulThemeUsageLine(property: property("Colour"), token: name, value: "a colour role of the app's own",
                                            origin: "not read by the app yet", colour: nil)]
            }
            if let drawn = drawnByControl(role, token: token, property: property("Colour")) { return [drawn] }
            guard token.accentOr else { return [colourLine(role, as: "Colour")] }
            // The accent once a theme names one, and until then the role it was.
            return isDefault(.accent)
                ? [colourLine(role, as: "Colour", note: "becomes ripul.accent when a theme names an accent")]
                : [colourLine(.accent, as: "Colour", note: "\(role.tokenName) until a theme names an accent")]
        case .system:
            guard let name = token.name, let literal = RipulColorLiteral("system:" + name) ?? fixed(name) else { return [] }
            return [RipulThemeUsageLine(property: property("Colour"), token: "system:" + name, value: "a system colour",
                                        origin: "never themed", colour: RipulColorValue(light: literal))]
        case .tint:
            let value = color(.accent)
            return [RipulThemeUsageLine(property: property("Colour"), token: RipulColorRole.accent.tokenName,
                                        value: describe(value),
                                        origin: (isDefault(.accent) ? "default" : "theme document") + ", through the window's tint",
                                        colour: value, isWindowTint: isDefault(.accent))]
        case .type:
            guard let role = token.name.flatMap(RipulTextRole.init(rawValue:)) else { return [] }
            let family = token.family.flatMap(RipulFontFamily.init(rawValue:))
            let resolved = text(role, family: family)
            let size = resolved.size ?? platformPointSize(resolved.relativeTo)
            let resolvedWeight = resolved.weight ?? resolved.relativeTo.intrinsicWeight
            let named = family.map { "\(role.rawValue) in the \($0.rawValue) family" } ?? role.rawValue
            return [RipulThemeUsageLine(
                property: property("Font"), token: named,
                value: "\(faceName(resolved.face)) \(number(size)) pt\(weight(resolvedWeight))",
                origin: typeOrigin(role: role, family: family ?? resolved.familyOrDefault(role)))]
        case .size:
            let family = token.family.flatMap(RipulFontFamily.init(rawValue:)) ?? .text
            let size = token.size.flatMap(Double.init).map { number(CGFloat($0)) + " pt" } ?? "a size chosen at run time"
            return [RipulThemeUsageLine(property: property("Font"), token: "fixed size in the \(family.rawValue) family",
                                        value: "\(faceName(face(family))) \(size)\(weight(nil))",
                                        origin: typeOrigin(role: nil, family: family))]
        case .icon:
            let size = token.size.map { Double($0).map { number(CGFloat($0)) + " pt" } ?? "a size chosen at run time" }
                ?? token.name.map { "the \($0) text style's size" } ?? "the symbol's own size"
            return [RipulThemeUsageLine(property: property("Symbol size"), token: "symbol size",
                                        value: "\(size)\(weight(nil))", origin: "never themed")]
        case .control:
            return controlLines(token.name ?? "", token: token, property: property)
        case .other:
            return [RipulThemeUsageLine(property: property("Colour"), token: "not a theme token",
                                        value: token.source ?? "a value in code", origin: "set in code or from data")]
        case .dynamic:
            return [RipulThemeUsageLine(property: property("Token"), token: "a role chosen at run time",
                                        value: token.source ?? "the code picks it", origin: "not known until it runs")]
        }
    }

    /// Inside a `Button`, `Menu` or `Link` the system's hierarchical styles (primary,
    /// secondary…) are steps of the control's own foreground, which is its tint. A text
    /// role's default IS such a style, so there the source's role is not what is drawn
    /// (seen on the top bar's buttons: the source writes the text role, the screen shows the
    /// accent). nil when the token is drawn as written.
    private static func drawnByControl(_ role: RipulColorRole, token: RipulThemeUsageMap.Token,
                                       property: String) -> RipulThemeUsageLine? {
        let levels = ["label": "primary", "secondaryLabel": "secondary", "tertiaryLabel": "tertiary", "quaternaryLabel": "quaternary"]
        guard let control = token.control, !token.isColorForm, !token.accentOr,
              let level = color(role).systemName.flatMap({ levels[$0] }) else { return nil }
        let written = "the source writes \(role.tokenName), whose default is the system's \(level) style"
        if token.inMenu {
            return RipulThemeUsageLine(
                property: property, token: role.tokenName, value: "the system's own colour for a menu item",
                origin: "set by the system: \(written), and a menu, swipe action, alert or dialog draws its items its own way. No swatch is shown")
        }
        if let style = token.controlStyle {
            guard !style.contains("plain") else { return nil }   // a plain button draws its label as written
            // Bordered, prominent and custom styles give the label a colour of their own.
            return RipulThemeUsageLine(
                property: property, token: role.tokenName, value: "a step of the \(control)'s own label colour",
                origin: "set by the system: \(written), and inside a \(control) with the button style \(style) that follows the label the style draws. No swatch is shown, because it is not known here")
        }
        let accent = color(.accent)
        let from = isDefault(.accent) ? "default" : "theme document"
        if token.inToolbar, isDefault(.accent) {
            return RipulThemeUsageLine(
                property: property, token: role.tokenName, value: describe(color(role)),
                origin: "default; in a toolbar the system draws this in the label colour, and in ripul.accent once a theme names an accent",
                colour: color(role))
        }
        let step = level == "primary" ? "" : "a fainter step of "
        return RipulThemeUsageLine(
            property: property, token: "ripul.accent, as the system draws it",
            value: step + describe(accent),
            origin: "\(from), through the \(control)'s tint: \(written), and inside a \(control) that style follows the tint. "
                + "To recolour it change ripul.accent; a theme that names \(role.tokenName) is drawn as written. "
                + "A button style set around it can change this",
            colour: accent, isWindowTint: isDefault(.accent))
    }

    private static func fixed(_ name: String) -> RipulColorLiteral? {
        switch name {
        case "white": return .rgba(red: 1, green: 1, blue: 1, alpha: 1)
        case "black": return .rgba(red: 0, green: 0, blue: 0, alpha: 1)
        default: return nil
        }
    }

    private static func controlLines(_ name: String, token: RipulThemeUsageMap.Token,
                                     property: (String) -> String) -> [RipulThemeUsageLine] {
        func familyLine(_ what: String, _ role: RipulTextRole, weight: String?) -> RipulThemeUsageLine {
            guard hasThemedTextFamily else {
                return RipulThemeUsageLine(property: property(what), token: role.rawValue,
                                           value: "the system's own style for it", origin: "default until a theme names a text family")
            }
            let resolved = text(role)
            let w = weight ?? resolved.weight ?? resolved.relativeTo.intrinsicWeight
            let size = resolved.size ?? platformPointSize(resolved.relativeTo)
            return RipulThemeUsageLine(property: property(what), token: role.rawValue,
                                       value: "\(faceName(resolved.face)) \(number(size)) pt\(w.map { " " + $0 } ?? "")",
                                       origin: typeOrigin(role: role, family: .text))
        }
        switch name {
        case "prominentButton", "glassProminentButton":
            let accent = color(.accent), on = color(.onAccent)
            return [
                RipulThemeUsageLine(property: property("Button fill"), token: RipulColorRole.accent.tokenName,
                                    value: describe(accent),
                                    origin: (isDefault(.accent) ? "default" : "theme document") + ", through the window's tint",
                                    colour: accent, isWindowTint: isDefault(.accent)),
                RipulThemeUsageLine(property: property("Button label"), token: RipulColorRole.onAccent.tokenName,
                                    value: isDefault(.onAccent) ? "the system's white label" : describe(on),
                                    origin: isDefault(.onAccent) ? "default" : "theme document", colour: on),
            ]
        case "buttonTint":
            // No foreground is written on the control, so its label is the tint.
            let accent = color(.accent)
            let control = token.control ?? "Button"
            if token.inToolbar, isDefault(.accent) {
                return [RipulThemeUsageLine(property: property("\(control) label"), token: "none written",
                                            value: "the system's label colour",
                                            origin: "default; in a toolbar it becomes ripul.accent once a theme names an accent")]
            }
            // Where the control sits decides it, and that is often another function's
            // business: say what the system may do, and show no swatch.
            return [RipulThemeUsageLine(
                property: property("\(control) label"), token: "none written", value: "the system colours it",
                origin: "usually ripul.accent (\(describe(accent)), \(isDefault(.accent) ? "default" : "theme document")) "
                    + "through the \(control)'s tint; its own colours in a menu or a toolbar, or under a button style set around it")]
        case "toggle":
            let accent = color(.accent)
            return isDefault(.accent)
                ? [RipulThemeUsageLine(property: property("Toggle's on colour"), token: "none written", value: "the system's green",
                                       origin: "default; it becomes ripul.accent once a theme names an accent")]
                : [RipulThemeUsageLine(property: property("Toggle's on colour"), token: RipulColorRole.accent.tokenName,
                                       value: describe(accent), origin: "theme document, through the window's tint", colour: accent)]
        case "sectionHeader": return [familyLine("Section header font", .headline, weight: nil)]
        case "sectionFooter": return [familyLine("Section footer font", .footnote, weight: nil)]
        case "emptyTitle": return [familyLine("Empty state title font", .title3, weight: "bold")]
        case "emptyDescription": return [familyLine("Empty state description font", .body, weight: nil)]
        default: return []
        }
    }

    package static func number(_ value: CGFloat) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", Double(value))
    }
}

private extension RipulTheme.ResolvedTextRole {
    /// The family the role was resolved in, when the call site named none.
    func familyOrDefault(_ role: RipulTextRole) -> RipulFontFamily {
        let spec = RipulTheme.typography.roles[role.rawValue]
        return spec?.family.flatMap(RipulFontFamily.init(rawValue:)) ?? role.defaultFamily
    }
}

/// What the explorer can say about one identified element: its lines, and where they came from.
public struct RipulThemeUsageAnswer: Equatable, Sendable {
    public var identifier: String
    /// `UnifiedSessionRow.swift:492`, one for each place the identifier is written.
    public var places: [String]
    public var lines: [RipulThemeUsageLine]
    /// Identified parts inside the element that have tokens of their own.
    public var parts: [String]
    /// True when the element holds text and no font is written on it or around it.
    public var textWithNoFont: Bool
    public var truncated: Bool
}

extension RipulThemeUsageMap {
    /// The answer for an identifier, or nil when the map does not know it. An identifier
    /// written in several places gives every place's tokens, each once.
    public func answer(for identifier: String) -> RipulThemeUsageAnswer? {
        guard let found = sites(for: identifier) else { return nil }
        var lines: [RipulThemeUsageLine] = []
        var hasFont = false
        for token in found.sites.flatMap(\.tokens) {
            if [.type, .size, .icon].contains(token.kind) || (token.kind == .other && token.property == "Font") { hasFont = true }
            for line in RipulTheme.describe(token) where !lines.contains(line) { lines.append(line) }
        }
        let several = found.sites.count > 1
        if several {
            // The same identifier in several places: which one is on screen is not known.
            lines = lines.map { var l = $0; if !l.property.contains("one of several") { l.property += " (in one of \(found.sites.count) places)" }; return l }
        }
        var parts: [String] = []
        for part in found.sites.flatMap(\.parts) where !parts.contains(part) { parts.append(part) }
        return RipulThemeUsageAnswer(
            identifier: identifier,
            places: found.sites.map { "\(($0.file as NSString).lastPathComponent):\($0.line)" },
            lines: lines, parts: parts,
            textWithNoFont: !hasFont && found.sites.contains { $0.hasText },
            truncated: found.sites.contains { $0.truncated })
    }
}
