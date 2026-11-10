import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - The site's own text styles (theme.typography.styles)
//
// Twin of the web's `resolveTypography` and `siteTextStyle`
// (src/cms/tokens/typographyTokens.ts). A site names its text styles once
// (h1–h6, subtitle1, subtitle2, body1, body2, caption, overline), each a CSS
// family stack, size (px, rem, vw, calc(), clamp()), weight, italic, line
// height, tracking, case, alignment and colour. A text block with no typography
// of its own follows its element's style (a paragraph is body1); one naming a
// `variant` takes that style, its own settings over it. Natively the size is
// evaluated at the window's width, as the browser does at the phone's, and
// scales with Dynamic Type from there; the family is the first in its stack
// this device has (the app bundles the site's web fonts, e.g. Source Sans 3).

/// One of a site's text styles, as the theme stores it. Every field optional.
public struct CmsSiteTextStyleConfig: Codable, Equatable {
    public var fontFamily: String?
    /// CSS: `17px`, `1.2rem`, `clamp(19px, calc(17.77px + 0.315vw), 21.8px)`.
    public var fontSize: String?
    public var fontWeight: Double?
    public var fontStyle: String?
    /// Unitless (a multiple of the size) or CSS (`24px`).
    public var lineHeight: String?
    public var letterSpacing: String?
    public var textTransform: String?
    public var textAlign: String?
    public var color: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ k: CodingKeys) -> String? {
            if let s = try? c.decode(String.self, forKey: k) { return s }
            if let n = try? c.decode(Double.self, forKey: k) { return String(n) }
            return nil
        }
        fontFamily = text(.fontFamily)
        fontSize = text(.fontSize)
        fontWeight = (try? c.decode(Double.self, forKey: .fontWeight)) ?? text(.fontWeight).flatMap(Double.init)
        fontStyle = text(.fontStyle)
        lineHeight = text(.lineHeight)
        letterSpacing = text(.letterSpacing)
        textTransform = text(.textTransform)
        textAlign = text(.textAlign)
        color = text(.color)
    }

    init(fontFamily: String? = nil, fontSize: String? = nil, fontWeight: Double? = nil, fontStyle: String? = nil,
         lineHeight: String? = nil, letterSpacing: String? = nil, textTransform: String? = nil,
         textAlign: String? = nil, color: String? = nil) {
        self.fontFamily = fontFamily; self.fontSize = fontSize; self.fontWeight = fontWeight; self.fontStyle = fontStyle
        self.lineHeight = lineHeight; self.letterSpacing = letterSpacing; self.textTransform = textTransform
        self.textAlign = textAlign; self.color = color
    }
}

/// A CSS length evaluated in points: `px`, `rem`/`em` (of `base`), `vw`/`vh`,
/// sums in `calc()`, and `clamp()`, `min()`, `max()`. Nil when it doesn't read.
enum CmsCssLength {
    static func points(_ css: String?, viewport: CGFloat, base: CGFloat = 16, percentOf: CGFloat? = nil) -> CGFloat? {
        guard let css else { return nil }
        var p = Parser(chars: Array(css.lowercased()), viewport: viewport, base: base, percentOf: percentOf)
        guard let v = p.sum(), p.atEnd else { return nil }
        return v
    }

    private struct Parser {
        let chars: [Character]
        let viewport: CGFloat
        let base: CGFloat
        /// What `%` is of (a container's width); nil, `%` doesn't read.
        let percentOf: CGFloat?
        var i = 0

        var atEnd: Bool { mutating get { skip(); return i >= chars.count } }
        mutating func skip() { while i < chars.count, chars[i] == " " { i += 1 } }
        mutating func eat(_ s: String) -> Bool {
            skip()
            let a = Array(s)
            guard i + a.count <= chars.count, Array(chars[i..<(i + a.count)]) == a else { return false }
            i += a.count
            return true
        }

        mutating func sum() -> CGFloat? {
            guard var v = term() else { return nil }
            while true {
                if eat("+") { guard let t = term() else { return nil }; v += t }
                else if eat("-") { guard let t = term() else { return nil }; v -= t }
                else { return v }
            }
        }

        mutating func term() -> CGFloat? {
            guard var v = atom() else { return nil }
            while true {
                if eat("*") { guard let t = atom() else { return nil }; v *= t }
                else if eat("/") { guard let t = atom(), t != 0 else { return nil }; v /= t }
                else { return v }
            }
        }

        mutating func args() -> [CGFloat]? {
            var out: [CGFloat] = []
            repeat { guard let v = sum() else { return nil }; out.append(v) } while eat(",")
            return eat(")") ? out : nil
        }

        mutating func atom() -> CGFloat? {
            skip()
            if eat("calc(") || eat("(") { let v = sum(); return eat(")") ? v : nil }
            if eat("clamp(") { guard let a = args(), a.count == 3 else { return nil }; return min(max(a[1], a[0]), a[2]) }
            if eat("min(") { return args()?.min() }
            if eat("max(") { return args()?.max() }
            let start = i
            if i < chars.count, chars[i] == "-" { i += 1 }
            while i < chars.count, chars[i].isNumber || chars[i] == "." { i += 1 }
            guard let n = Double(String(chars[start..<i])) else { return nil }
            let value = CGFloat(n)
            if eat("px") { return value }
            if eat("rem") || eat("em") { return value * base }
            if eat("vw") { return value * viewport / 100 }
            if eat("vh") { return value * viewport * 2 / 100 }
            if eat("pt") { return value * 4 / 3 }
            if eat("%") { return percentOf.map { value * $0 / 100 } }
            return value
        }
    }
}

/// A text block's look, resolved: what the web's resolveTypography gives it.
struct CmsSiteText: Equatable {
    var family: String?
    var size: CGFloat?
    var weight: Double?
    var italic = false
    /// A multiple of the size.
    var lineHeight: CGFloat?
    /// Points.
    var tracking: CGFloat?
    var transform: String?
    var align: String?
    var color: String?

    /// It sets how the text is drawn (family, size, weight, line, tracking,
    /// case, italics), not only where it sits or its colour.
    var setsLettering: Bool {
        family != nil || size != nil || weight != nil || lineHeight != nil || tracking != nil || transform != nil || italic
    }

    static let styleNames: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6", "subtitle1", "subtitle2", "body1", "body2", "caption", "overline", "button"]

    /// The web's siteTextStyle then resolveTypography: a block with no
    /// typography follows its element's site style (a paragraph is body1), when
    /// the site defines it; nil when nothing applies (the block draws as before).
    static func resolve(typography: [String: CmsJSON]?, element: String, styles: [String: CmsSiteTextStyleConfig]?,
                        viewport: CGFloat) -> CmsSiteText? {
        var t = typography ?? [:]
        if t.isEmpty {
            let name = element.range(of: #"^h[1-6]$"#, options: .regularExpression) != nil ? element : "body1"
            guard styles?[name] != nil else { return nil }
            t = ["variant": .string(name)]
        }
        var out = CmsSiteText()
        var sizeCSS: String?, lineCSS: String?, trackCSS: String?
        if let variant = t.string("variant"), styleNames.contains(variant), let s = styles?[variant] {
            out.family = s.fontFamily
            sizeCSS = s.fontSize
            out.weight = s.fontWeight
            out.italic = s.fontStyle == "italic"
            lineCSS = s.lineHeight
            trackCSS = s.letterSpacing
            out.transform = s.textTransform
            out.align = s.textAlign
            out.color = s.color
        }
        if let v = t.string("family") { out.family = v }
        if let v = t["size"].flatMap(cssText) { sizeCSS = v }
        if let v = t["weight"]?.doubleValue ?? t.string("weight").flatMap(Double.init) { out.weight = v }
        if let v = t["lineHeight"].flatMap(cssText) { lineCSS = v }
        if let v = t["letterSpacing"].flatMap(cssText) { trackCSS = v }
        if let v = t.string("textAlign") { out.align = v }
        if let v = t.string("textTransform") { out.transform = v }
        if let v = t.string("color") { out.color = v }
        out.size = CmsCssLength.points(sizeCSS, viewport: viewport)
        if let lineCSS {
            if let n = Double(lineCSS.trimmingCharacters(in: .whitespaces)) { out.lineHeight = CGFloat(n) }
            else if let pts = CmsCssLength.points(lineCSS, viewport: viewport), let size = out.size, size > 0 { out.lineHeight = pts / size }
        }
        if let trackCSS, trackCSS != "normal" {
            out.tracking = CmsCssLength.points(trackCSS, viewport: viewport, base: out.size ?? 16)
        }
        return out
    }

    private static func cssText(_ v: CmsJSON) -> String? {
        if let s = v.stringValue { return s }
        if let n = v.doubleValue { return "\(n)px" }
        return nil
    }

    /// The family a CSS stack resolves to, as a browser walks it (and as Android's
    /// `CmsPortalTheme.stackFamily`): each name in order, unquoted; a generic family
    /// (`sans-serif`, `serif`, …) ends the walk with the system font (nil); a name
    /// this device has (case and surrounding spaces ignored) is used as the device
    /// names it; a name it lacks is skipped. Nil when none is had.
    static func installedFamily(stack: String?) -> String? {
        guard let stack else { return nil }
        for raw in stack.split(separator: ",") {
            let name = raw.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                .trimmingCharacters(in: .whitespaces)
            if name.isEmpty { continue }
            if genericFamilies.contains(name.lowercased()) { return nil }
            if let found = deviceFamily(name) { return found }
        }
        return nil
    }

    static let genericFamilies: Set<String> = ["sans-serif", "serif", "monospace", "system-ui", "-apple-system", "inherit", "cursive", "fantasy"]

    /// The device's own spelling of a family it has, matched without regard to case.
    static func deviceFamily(_ name: String) -> String? {
        if let exact = CmsPortalTheme.installedFamily(name) { return exact }
        #if os(iOS)
        let names = UIFont.familyNames
        #elseif os(macOS)
        let names = NSFontManager.shared.availableFontFamilies
        #else
        let names: [String] = []
        #endif
        let wanted = name.lowercased()
        return names.first { $0.lowercased() == wanted }
    }

    /// The window's width, the `vw` a phone's browser measures sizes against.
    @MainActor
    static var viewportWidth: CGFloat {
        #if os(iOS)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene?.windows.first?.bounds.width ?? scene?.screen.bounds.width ?? 390
        #else
        return 390
        #endif
    }

    /// Straight quotes and apostrophes as curly ones (the web's typographicQuotes).
    static func typographicQuotes(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: #"(^|[\s(\[{“—–-])'"#, with: "$1‘", options: .regularExpression)
        s = s.replacingOccurrences(of: "'", with: "’")
        s = s.replacingOccurrences(of: #"(^|[\s(\[{‘—–-])""#, with: "$1“", options: .regularExpression)
        s = s.replacingOccurrences(of: "\"", with: "”")
        return s
    }
}

/// Text drawn in a resolved site style: the family (first installed), size
/// scaled by Dynamic Type relative to `relativeTo`, weight, italic, line height,
/// tracking, case and colour.
struct CmsSiteTextModifier: ViewModifier {
    let style: CmsSiteText
    let fallbackSize: CGFloat
    let relativeTo: Font.TextStyle
    let colour: Color
    @ScaledMetric private var size: CGFloat

    init(style: CmsSiteText, fallbackSize: CGFloat, relativeTo: Font.TextStyle, colour: Color) {
        self.style = style
        self.fallbackSize = fallbackSize
        self.relativeTo = relativeTo
        self.colour = colour
        _size = ScaledMetric(wrappedValue: style.size ?? fallbackSize, relativeTo: relativeTo)
    }

    func body(content: Content) -> some View {
        let weight = style.weight.map(CmsTypography.weight(css:)) ?? .regular
        let family = CmsSiteText.installedFamily(stack: style.family)
        var font = family.map { Font.custom($0, fixedSize: size) } ?? .system(size: size)
        font = font.weight(weight)
        if style.italic { font = font.italic() }
        if family == nil, style.family == nil, style.size == nil {
            // Neither family nor size from the site: the text style itself, as
            // before site text styles, whose lines are taller than a bare size's
            // (17 pt body is 22 pt a line, not 20).
            font = Font.system(relativeTo).weight(weight)
            if style.italic { font = font.italic() }
        }
        let extra = style.lineHeight.map { max(0, ($0 - 1.2) * size) } ?? 0
        return content
            .font(font)
            .lineSpacing(extra)
            .tracking(style.tracking ?? 0)
            .textCase(style.transform == "uppercase" ? .uppercase : style.transform == "lowercase" ? .lowercase : nil)
            .foregroundStyle(colour)
            .multilineTextAlignment(style.align == "center" ? .center : style.align == "right" || style.align == "end" ? .trailing : .leading)
    }
}

/// A piece of a native block's text in one of the site's text styles (the MUI
/// variant the web's block uses: body1, body2, caption, …): its family, size and
/// weight, scaled by Dynamic Type. A site with no such style gets its body
/// family at `fallback` points.
struct CmsSiteFont: ViewModifier {
    let variant: String
    let fallback: CGFloat
    let relativeTo: Font.TextStyle
    /// CSS weight over the style's own (`600` for a semibold label).
    var weight: Double? = nil
    @EnvironmentObject private var runtime: CmsRuntime

    func body(content: Content) -> some View {
        let style = runtime.themeConfig?.typography?.styles?[variant]
        let size = CmsCssLength.points(style?.fontSize, viewport: CmsSiteText.viewportWidth) ?? fallback
        let family = CmsSiteText.installedFamily(stack: style?.fontFamily) ?? runtime.theme.fontFamily
        let w = CmsTypography.weight(css: weight ?? style?.fontWeight ?? 400)
        return content.modifier(Scaled(family: family, size: size, weight: w, italic: style?.fontStyle == "italic", relativeTo: relativeTo))
    }

    private struct Scaled: ViewModifier {
        let family: String?
        let weight: Font.Weight
        let italic: Bool
        @ScaledMetric private var size: CGFloat

        init(family: String?, size: CGFloat, weight: Font.Weight, italic: Bool, relativeTo: Font.TextStyle) {
            self.family = family
            self.weight = weight
            self.italic = italic
            _size = ScaledMetric(wrappedValue: size, relativeTo: relativeTo)
        }

        func body(content: Content) -> some View {
            var font = family.map { Font.custom($0, fixedSize: size) } ?? .system(size: size)
            font = font.weight(weight)
            if italic { font = font.italic() }
            return content.font(font)
        }
    }
}

extension View {
    /// Text in the site's `variant` style (CmsSiteFont).
    func cmsSiteFont(_ variant: String, _ fallback: CGFloat, relativeTo: Font.TextStyle = .body, weight: Double? = nil) -> some View {
        modifier(CmsSiteFont(variant: variant, fallback: fallback, relativeTo: relativeTo, weight: weight))
    }
}
