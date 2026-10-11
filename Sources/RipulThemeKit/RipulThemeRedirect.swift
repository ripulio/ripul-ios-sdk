import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - A theme for source nobody edited
//
// A host that switches on the package's `RipulThemeRedirect` build-tool plug-in gets one
// generated Swift file compiled into its own module. That file declares SwiftUI's names
// again (`Font.body`, `Font.system(size:)`, `Color.red`, `foregroundStyle`, `WindowGroup`),
// and inside the host's module its declarations are chosen over SwiftUI's, so the host's
// existing `.font(.body)` arrives here with no line of it changed. Each generated
// declaration is one call into this file. Everything that decides anything is here, in the
// SDK, where `Font.body` still means SwiftUI's.
//
// The rule that holds the whole design up: with no theme, every function below returns the
// value the call site would have had without the plug-in, itself.
//
// Nothing here runs for a host that does not switch the plug-in on.
// The template is `tools/redirect/RipulThemeRedirect.swift.txt`.

public enum RipulThemeRedirect {

    // MARK: fonts

    /// `Font.body` and the other ten text styles.
    public static func font(_ style: Font.TextStyle) -> Font {
        guard let role = role(for: style) else { return RipulTheme.systemFont(style) }
        return remember(Font.ripul(role), was: RipulTheme.systemFont(style))
    }

    /// `Font.system(size:weight:design:)`. A serif is the display family once a theme
    /// names one, fixed-width is the code family, and rounded is left alone.
    public static func systemFont(size: CGFloat, weight: Font.Weight?, design: Font.Design?) -> Font {
        let original = Font.system(size: size, weight: weight, design: design)
        // With the family the system's, the call site's own value and not an equal one.
        guard let family = family(for: design), RipulTheme.face(family) != family.defaultFace else { return original }
        return remember(Font.ripul(size: size, weight: weight, family: family), was: original)
    }

    /// `Font.system(_:design:weight:)`.
    public static func systemFont(_ style: Font.TextStyle, design: Font.Design?, weight: Font.Weight?) -> Font {
        let original = Font.system(style, design: design, weight: weight)
        guard let role = role(for: style), let family = family(for: design) else { return original }
        let resolved = RipulTheme.text(role, family: family)
        // With nothing themed for this role, the call site's own value and not an equal one.
        if resolved.face == family.defaultFace, resolved.size == nil, resolved.weight == nil { return original }
        return remember(Font.ripul(role, weight: weight, family: family == .text ? nil : family), was: original)
    }

    /// `font.weight(_:)`, `font.bold()` and `font.italic()`: the font itself, and a note of
    /// what it would have been, so that a symbol can still be given its system size.
    public static func weight(_ font: Font, _ weight: Font.Weight) -> Font {
        derive(font, font.weight(weight)) { $0.weight(weight) }
    }
    public static func bold(_ font: Font) -> Font { derive(font, font.bold()) { $0.bold() } }
    public static func italic(_ font: Font) -> Font { derive(font, font.italic()) { $0.italic() } }

    /// `.font(_:)` on an `Image`: a symbol's size, never the theme's. It is given the font
    /// the call site would have had without the redirect.
    public static func iconFont(_ image: Image, _ font: Font) -> some View {
        lock.lock()
        let original = originals[font] ?? font
        lock.unlock()
        return image.font(original)
    }

    private static func role(for style: Font.TextStyle) -> RipulTextRole? {
        switch style {
        case .largeTitle: return .largeTitle
        case .title: return .title
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .body: return .body
        case .callout: return .callout
        case .subheadline: return .subheadline
        case .footnote: return .footnote
        case .caption: return .caption
        case .caption2: return .caption2
        default: return nil
        }
    }

    /// The family a system design stands for. nil: leave the call alone.
    private static func family(for design: Font.Design?) -> RipulFontFamily? {
        switch design {
        case nil, .some(.default): return .text
        case .some(.monospaced): return .code
        // A host's serif headings become the theme's display family, and stay the
        // system's serif until a theme names one.
        case .some(.serif): return RipulTheme.face(.display) == RipulFontFamily.display.defaultFace ? nil : .display
        default: return nil
        }
    }

    // What each themed font would have been. Only fonts that differ are kept, so with no
    // theme the table is empty. It is bounded by the distinct fonts a host's source names.
    private static let lock = NSLock()
    private static var originals: [Font: Font] = [:]

    private static func remember(_ themed: Font, was original: Font) -> Font {
        guard themed != original else { return themed }
        lock.lock(); originals[themed] = original; lock.unlock()
        return themed
    }

    private static func derive(_ from: Font, _ to: Font, _ same: (Font) -> Font) -> Font {
        lock.lock()
        if let original = originals[from] { originals[to] = same(original) }
        lock.unlock()
        return to
    }

    // MARK: colours

    /// `Color.red` and the other named colours that are a role.
    public static func color(_ role: RipulColorRole) -> Color { Color.ripul(role) }

    /// `Color("BrandNavy")`: a colour of the app's own asset catalogue is a role of the
    /// asset's name, whose default is the asset. A theme document that names the role
    /// (`"roles": { "BrandNavy": … }`) changes it; until one does, the asset itself.
    public static func color(named name: String, bundle: Bundle?) -> Color {
        guard bundle == nil || bundle == .main else { return Color(name, bundle: bundle) }
        let role = RipulColorRole(asset: name)
        return RipulTheme.isDefault(role) ? Color(name, bundle: bundle) : Color.ripul(role)
    }

    #if canImport(UIKit)
    /// `Color(.systemGroupedBackground)`, `Color(uiColor: .label)`: the role the system
    /// colour is the default of, and the colour itself for any other.
    public static func color(_ uiColor: UIColor) -> Color {
        guard let role = role(for: uiColor), !RipulTheme.isDefault(role) else { return Color(uiColor: uiColor) }
        return Color.ripul(role)
    }

    private static func role(for color: UIColor) -> RipulColorRole? {
        switch color {
        case .systemBackground: return .canvas
        case .secondarySystemGroupedBackground: return .surface
        case .systemGroupedBackground: return .surfaceSunken
        case .label: return .text
        case .secondaryLabel: return .textSecondary
        case .tertiaryLabel: return .textTertiary
        case .quaternaryLabel: return .textQuaternary
        case .separator: return .separator
        default: return nil
        }
    }
    #endif

    /// `.foregroundStyle(.secondary)` and the other hierarchy styles, on any view.
    @ViewBuilder
    public static func foregroundStyle<Content: View, S: ShapeStyle>(_ content: Content, _ style: S) -> some View {
        if let role = textRole(for: style) {
            content.foregroundStyle(RipulColorStyle(role: role))
        } else {
            content.foregroundStyle(style)
        }
    }

    /// The same on a `Text`, which stays a `Text`.
    public static func foregroundStyle<S: ShapeStyle>(_ text: Text, _ style: S) -> Text {
        if let role = textRole(for: style) { return text.foregroundStyle(RipulColorStyle(role: role)) }
        return text.foregroundStyle(style)
    }

    /// The text role a hierarchy style is the default of, once a theme names that role.
    /// Until then nil, and the call site's own style is applied untouched.
    private static func textRole<S: ShapeStyle>(for style: S) -> RipulColorRole? {
        guard let level = style as? HierarchicalShapeStyle,
              let role = hierarchy[String(reflecting: level)] else { return nil }
        return RipulTheme.isDefault(role) ? nil : role
    }

    /// The four levels by what they print as: the type is not `Equatable`.
    private static let hierarchy: [String: RipulColorRole] = [
        String(reflecting: HierarchicalShapeStyle.primary): .text,
        String(reflecting: HierarchicalShapeStyle.secondary): .textSecondary,
        String(reflecting: HierarchicalShapeStyle.tertiary): .textTertiary,
        String(reflecting: HierarchicalShapeStyle.quaternary): .textQuaternary,
    ]

    // MARK: text with no colour of its own

    /// `Text("…")` in the host's source. On a line where the build found a text with no
    /// colour of its own (`tools/theme_text.py`), the text is given the theme's `text`
    /// colour as it is made. Anywhere else, and with no theme, it is the text itself.
    public static func text(_ key: LocalizedStringKey, isBare: () -> Bool) -> Text {
        themed(Text(key), isBare)
    }

    /// `Text(name)`, a text made from a string.
    public static func text(verbatim content: String, isBare: () -> Bool) -> Text {
        themed(Text(content), isBare)
    }

    private static func themed(_ text: Text, _ isBare: () -> Bool) -> Text {
        guard !RipulTheme.isDefault(.text), isBare() else { return text }
        return text.foregroundStyle(RipulColorStyle(role: .text))
    }

    // MARK: the root

    /// The View Explorer's map of the host's own tokens, as the generated file carries it
    /// in a Debug build. A map bundled as `ripul-theme-usage.json` is used before this one.
    public static func useUsageMap(_ json: String) {
        lock.lock(); usageMapJSON = json; lock.unlock()
    }

    package static var usageMap: RipulThemeUsageMap? {
        lock.lock(); let json = usageMapJSON; lock.unlock()
        return json.isEmpty ? nil : RipulThemeUsageMap(data: Data(json.utf8))
    }

    private static var usageMapJSON = ""

    /// What a generated `WindowGroup` puts round the host's content: the theme root, with
    /// the host's theme installed before the first view. The theme is the one Info.plist
    /// names (`RipulTheme`), or, with none named, the only theme document in the bundle.
    public struct Root<Content: View>: View {
        private let content: () -> Content

        public init(_ content: @escaping () -> Content) {
            RipulTheme.installForRedirect()
            self.content = content
        }

        public var body: some View { content().ripulThemeRoot() }
    }
}
