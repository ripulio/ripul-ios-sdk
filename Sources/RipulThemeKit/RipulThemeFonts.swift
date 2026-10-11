import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Fonts a view can use
//
// What a call site writes (docs/theming.md):
//     .font(.ripul(.body))                          was .font(.body)
//     .font(.ripul(.caption, weight: .semibold))    was .font(.caption.weight(.semibold))
//     .font(.ripul(.caption, family: .code))        was .font(.caption.monospaced())
//     .font(.ripul(size: 14, weight: .medium))      was .font(.system(size: 14, weight: .medium))
//     .font(.ripulIcon(size: 18))                   was .font(.system(size: 18)) on an Image
//
// With no theme each returns the value on the right, itself.

extension Font {
    /// A type role. With no theme, the system text style of the same name.
    /// - Parameters:
    ///   - weight: a weight for this use, as `.weight(_:)` on the system style.
    ///   - family: `.code` for fixed-width text in this role's size.
    public static func ripul(_ role: RipulTextRole, weight: Font.Weight? = nil, family: RipulFontFamily? = nil) -> Font {
        let resolved = RipulTheme.text(role, family: family)
        // A custom face has no weight of its own for a style, so the one the system's style
        // carries (headline is semibold) is given to it. The system face keeps its own.
        let roleWeight = weight ?? resolved.weight.flatMap(RipulTheme.fontWeight)
            ?? (resolved.isSystemFace ? nil : resolved.relativeTo.intrinsicWeight.flatMap(RipulTheme.fontWeight))
        let style = resolved.relativeTo.textStyle
        var font: Font
        if resolved.isSystemFace, resolved.size == nil {
            let design = RipulTheme.design(resolved.face)
            font = design == nil ? RipulTheme.systemFont(style) : .system(style, design: design)
        } else if resolved.isSystemFace {
            font = .system(size: RipulTheme.scaled(resolved.size!, for: resolved.relativeTo), design: RipulTheme.design(resolved.face))
        } else if let size = resolved.size {
            font = .custom(resolved.face, size: size, relativeTo: style)
        } else {
            font = .custom(resolved.face, size: RipulTheme.platformPointSize(resolved.relativeTo), relativeTo: style)
        }
        if let roleWeight { font = font.weight(roleWeight) }
        return font
    }

    /// A fixed size in the theme's family, for the places a text style does not fit.
    /// With no theme, `Font.system(size:weight:)` (and `design: .monospaced` for `.code`).
    public static func ripul(size: CGFloat, weight: Font.Weight? = nil, family: RipulFontFamily = .text) -> Font {
        let face = RipulTheme.face(family)
        guard face.hasPrefix("system") else {
            let font = Font.custom(face, fixedSize: size)
            return weight.map { font.weight($0) } ?? font
        }
        return .system(size: size, weight: weight, design: RipulTheme.design(face))
    }

    /// The size of an SF Symbol. Never themed: a font on an `Image` is an icon size, not type.
    public static func ripulIcon(size: CGFloat, weight: Font.Weight? = nil) -> Font {
        .system(size: size, weight: weight)
    }

    /// A symbol sized with a text style, so it scales with Dynamic Type. Never themed.
    public static func ripulIcon(_ style: Font.TextStyle, weight: Font.Weight? = nil) -> Font {
        let font = RipulTheme.systemFont(style)
        return weight.map { font.weight($0) } ?? font
    }
}

extension View {
    /// A type role with everything the theme says about it: the font, and its tracking
    /// and capitals when the theme sets them. With no theme this is `.font(.ripul(role))`.
    public func ripulTextStyle(_ role: RipulTextRole, weight: Font.Weight? = nil) -> some View {
        modifier(RipulTextStyleModifier(role: role, weight: weight))
    }
}

private struct RipulTextStyleModifier: ViewModifier {
    let role: RipulTextRole
    let weight: Font.Weight?

    @ViewBuilder
    func body(content: Content) -> some View {
        let resolved = RipulTheme.text(role)
        let styled = content.font(.ripul(role, weight: weight))
        if resolved.tracking != 0 || resolved.uppercase {
            styled.tracking(resolved.tracking).textCase(resolved.uppercase ? .uppercase : nil)
        } else {
            styled
        }
    }
}

extension RipulTextRole {
    /// The system text style this role scales with by default.
    public var textStyle: Font.TextStyle {
        switch defaultRelativeTo {
        case .largeTitle: return .largeTitle
        case .title: return .title
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .callout: return .callout
        case .subheadline: return .subheadline
        case .footnote: return .footnote
        case .caption: return .caption
        case .caption2: return .caption2
        default: return .body
        }
    }
}

extension RipulTheme {
    /// The default font for `ripulThemeRoot()`: nil while `body` is the system's, so
    /// applying it changes nothing.
    public static var defaultFontOverride: Font? {
        let body = text(.body)
        return body.face == "system" && body.size == nil && body.weight == nil ? nil : Font.ripul(.body)
    }

    /// SwiftUI's own value for a system text style: `Font.body`, not `Font.system(.body)`,
    /// because the first is what call sites write and the two are not equal as values.
    static func systemFont(_ style: Font.TextStyle) -> Font {
        switch style {
        case .largeTitle: return .largeTitle
        case .title: return .title
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .callout: return .callout
        case .footnote: return .footnote
        case .caption: return .caption
        case .caption2: return .caption2
        default: return .body
        }
    }

    static func design(_ face: String) -> Font.Design? {
        switch face {
        case "system-serif": return .serif
        case "system-rounded": return .rounded
        case "system-monospaced": return .monospaced
        default: return nil
        }
    }

    static func fontWeight(_ name: String) -> Font.Weight? {
        switch name {
        case "ultraLight": return .ultraLight
        case "thin": return .thin
        case "light": return .light
        case "regular": return .regular
        case "medium": return .medium
        case "semibold": return .semibold
        case "bold": return .bold
        case "heavy": return .heavy
        case "black": return .black
        default: return nil
        }
    }

    /// The system's size for a text style at the default text size on this platform: 17 for
    /// body on an iPhone, 13 on Mac Catalyst. A custom family with no size of its own is
    /// drawn at this, so it sits where the system's text sat.
    static func platformPointSize(_ role: RipulTextRole) -> CGFloat {
        #if canImport(UIKit)
        return UIFont.preferredFont(forTextStyle: role.uiTextStyle,
                                    compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)).pointSize
        #else
        return role.systemPointSize
        #endif
    }

    /// A themed size at the current Dynamic Type size (iOS). Elsewhere, the size itself.
    static func scaled(_ size: CGFloat, for role: RipulTextRole) -> CGFloat {
        #if canImport(UIKit) && !targetEnvironment(macCatalyst)
        return UIFontMetrics(forTextStyle: role.uiTextStyle).scaledValue(for: size)
        #else
        return size
        #endif
    }
}

#if canImport(UIKit)
extension RipulTextRole {
    public var uiTextStyle: UIFont.TextStyle {
        switch defaultRelativeTo {
        case .largeTitle: return .largeTitle
        case .title: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .callout: return .callout
        case .subheadline: return .subheadline
        case .footnote: return .footnote
        case .caption: return .caption1
        case .caption2: return .caption2
        default: return .body
        }
    }
}

extension UIFont {
    /// A type role for UIKit. With no theme, `UIFont.preferredFont(forTextStyle:)`; with a
    /// weight, the system font at that style's current size in that weight.
    public static func ripul(_ role: RipulTextRole, weight: UIFont.Weight? = nil, family: RipulFontFamily? = nil) -> UIFont {
        let resolved = RipulTheme.text(role, family: family)
        let style = resolved.relativeTo.uiTextStyle
        let roleWeight = weight ?? resolved.weight.flatMap(RipulTheme.uiFontWeight)
            ?? (resolved.isSystemFace ? nil : resolved.relativeTo.intrinsicWeight.flatMap(RipulTheme.uiFontWeight))
        if resolved.face == "system", resolved.size == nil, roleWeight == nil { return .preferredFont(forTextStyle: style) }
        let size = resolved.size.map { UIFontMetrics(forTextStyle: style).scaledValue(for: $0) }
            ?? UIFont.preferredFont(forTextStyle: style).pointSize
        return RipulTheme.uiFont(face: resolved.face, size: size, weight: roleWeight)
    }

    /// A fixed size in the theme's family. With no theme, `UIFont.systemFont(ofSize:weight:)`
    /// (`monospacedSystemFont` for `.code`).
    public static func ripul(size: CGFloat, weight: UIFont.Weight = .regular, family: RipulFontFamily = .text) -> UIFont {
        RipulTheme.uiFont(face: RipulTheme.face(family), size: size, weight: weight)
    }
}

extension RipulTheme {
    static func uiFont(face: String, size: CGFloat, weight: UIFont.Weight?) -> UIFont {
        let weight = weight ?? .regular
        switch face {
        case "system": return .systemFont(ofSize: size, weight: weight)
        case "system-monospaced": return .monospacedSystemFont(ofSize: size, weight: weight)
        case "system-serif", "system-rounded":
            let base = UIFont.systemFont(ofSize: size, weight: weight)
            let design: UIFontDescriptor.SystemDesign = face == "system-serif" ? .serif : .rounded
            return base.fontDescriptor.withDesign(design).map { UIFont(descriptor: $0, size: size) } ?? base
        default:
            let descriptor = UIFontDescriptor(fontAttributes: [.family: face, .traits: [UIFontDescriptor.TraitKey.weight: weight]])
            return UIFont(descriptor: descriptor, size: size)
        }
    }

    static func uiFontWeight(_ name: String) -> UIFont.Weight? {
        switch name {
        case "ultraLight": return .ultraLight
        case "thin": return .thin
        case "light": return .light
        case "regular": return .regular
        case "medium": return .medium
        case "semibold": return .semibold
        case "bold": return .bold
        case "heavy": return .heavy
        case "black": return .black
        default: return nil
        }
    }
}
#endif
