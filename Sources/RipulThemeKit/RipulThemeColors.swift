import SwiftUI
#if canImport(UIKit)
import UIKit
package typealias RipulPlatformColor = UIColor
#elseif canImport(AppKit)
import AppKit
package typealias RipulPlatformColor = NSColor
#endif

// MARK: - Colours a view can use
//
// What a call site writes (docs/theming.md):
//     .foregroundStyle(.ripul(.textSecondary))     any ShapeStyle position
//     Color.ripul(.surface)                         where a Color is required
//     UIColor.ripul(.separator)                     UIKit
//
// With no theme, each gives the system value it replaces, itself: `.ripul(.textSecondary)`
// is the system's hierarchical secondary style, `Color.ripul(.danger)` is `Color.red`,
// `UIColor.ripul(.text)` is `UIColor.label`. That is what makes a migrated call site draw
// the same pixels as before.

/// A base colour role as a SwiftUI style. Prefer it to `Color.ripul` wherever a style is
/// accepted: with no theme, the text roles and the accent stay the system's own
/// hierarchical and tint styles, which a plain `Color` cannot reproduce inside a list row
/// or on a material.
public struct RipulColorStyle: ShapeStyle {
    public let role: RipulColorRole
    /// The role's colour when the accessor was called. Held in the style, not looked up
    /// when it is drawn: SwiftUI resolves a style again only when the style's own value
    /// changes, and a role's name does not change with the theme (measured: a style that
    /// looked the colour up in `resolve` kept the old colour after a theme change).
    let value: RipulColorValue

    init(role: RipulColorRole) {
        self.role = role
        self.value = RipulTheme.color(role)
    }

    public func resolve(in environment: EnvironmentValues) -> AnyShapeStyle {
        switch value.systemName {
        case "label": return AnyShapeStyle(.primary)
        case "secondaryLabel": return AnyShapeStyle(.secondary)
        case "tertiaryLabel": return AnyShapeStyle(.tertiary)
        case "quaternaryLabel": return AnyShapeStyle(.quaternary)
        case "tint": return AnyShapeStyle(.tint)
        default: return AnyShapeStyle(RipulTheme.swiftUIColor(value))
        }
    }
}

/// A system colour by name, for a call site that no role fits. It draws what the
/// system colour draws and is never themed; the check counts these apart, and the
/// brand step decides what each becomes.
public enum RipulSystemColor: String, CaseIterable, Sendable {
    case label, secondaryLabel, tertiaryLabel, quaternaryLabel, placeholderText, separator, opaqueSeparator, link
    case systemBackground, secondarySystemBackground, tertiarySystemBackground
    case systemGroupedBackground, secondarySystemGroupedBackground, tertiarySystemGroupedBackground
    case systemFill, secondarySystemFill, tertiarySystemFill, quaternarySystemFill
    case systemRed, systemOrange, systemYellow, systemGreen, systemMint, systemTeal, systemCyan, systemBlue
    case systemIndigo, systemPurple, systemPink, systemBrown
    case systemGray, systemGray2, systemGray3, systemGray4, systemGray5, systemGray6
    /// Pure white and black: scrims, shadows, and marks on a photograph. Not `onAccent`.
    case white, black
}

extension ShapeStyle where Self == Color {
    /// A system colour that no role fits: `.fill(.ripul(system: .tertiarySystemFill))`.
    public static func ripul(system name: RipulSystemColor) -> Color { RipulTheme.swiftUIColor(system: name) }
}

extension ShapeStyle where Self == RipulColorStyle {
    /// A base colour role: `.foregroundStyle(.ripul(.textSecondary))`.
    public static func ripul(_ role: RipulColorRole) -> RipulColorStyle { RipulColorStyle(role: role) }

    /// For a colour that meant "the app's colour" but was written as another (a system
    /// blue): the theme's accent once a theme names one, and until then the role it was,
    /// so the default document draws what it drew. The system's tint is not its blue in
    /// dark mode or under Increased Contrast (measured), so `.ripul(.accent)` would not.
    public static func ripul(accentOr role: RipulColorRole) -> RipulColorStyle {
        RipulColorStyle(role: RipulTheme.isDefault(.accent) ? role : .accent)
    }
}

extension Color {
    /// A base colour role as a `Color`. Use the style form (`.ripul(.text)` in a
    /// `foregroundStyle`, `fill`, `background`, `tint`) where one is accepted.
    public static func ripul(_ role: RipulColorRole) -> Color { RipulTheme.swiftUIColor(RipulTheme.color(role)) }

    /// The theme's accent once a theme names one, and until then `role`: see the style form.
    public static func ripul(accentOr role: RipulColorRole) -> Color {
        .ripul(RipulTheme.isDefault(.accent) ? role : .accent)
    }
}

extension RipulTheme {
    /// The accent as an override for `.tint(_:)` and a window's tint: nil while the accent
    /// is the system's, so applying it changes nothing.
    public static var accentOverride: Color? { isDefault(.accent) ? nil : Color.ripul(.accent) }

    /// SwiftUI's own colour where it has one (`Color.red`, `Color.white`), the wrapped
    /// platform colour otherwise: what the call site wrote before.
    static func swiftUIColor(system name: RipulSystemColor) -> Color {
        switch name {
        case .white: return .white
        case .black: return .black
        case .label, .secondaryLabel: return Color(systemPlatformColor(name.rawValue))
        default: return swiftUISystemColor(name.rawValue) ?? Color(systemPlatformColor(name.rawValue))
        }
    }

    static func swiftUIColor(_ value: RipulColorValue) -> Color {
        if let name = value.systemName, let known = swiftUISystemColor(name) { return known }
        // What the host wrote before: `Color("BrandNavy")`.
        if let asset = value.assetName { return Color(asset) }
        return colours.swiftUI(value) { Color(platformColor(value)) }
    }

    /// SwiftUI's own colour for a system name, where it has one. These, not a wrapped
    /// platform colour, are what call sites use today (`Color.secondary`, `Color.red`).
    private static func swiftUISystemColor(_ name: String) -> Color? {
        switch name {
        case "tint": return .accentColor
        case "label": return .primary
        case "secondaryLabel": return .secondary
        case "systemRed": return .red
        case "systemOrange": return .orange
        case "systemYellow": return .yellow
        case "systemGreen": return .green
        case "systemMint": return .mint
        case "systemTeal": return .teal
        case "systemCyan": return .cyan
        case "systemBlue": return .blue
        case "systemIndigo": return .indigo
        case "systemPurple": return .purple
        case "systemPink": return .pink
        case "systemBrown": return .brown
        case "systemGray": return .gray
        default: return nil
        }
    }

    /// The platform colour for a resolved value. A system colour is returned as the
    /// system's own object; a light and dark pair as one dynamic colour.
    package static func platformColor(_ value: RipulColorValue) -> RipulPlatformColor {
        guard let dark = value.dark, dark != value.light else { return platformColor(value.light) }
        let light = value.light
        return colours.platform(value) {
            #if canImport(UIKit)
            UIColor { $0.userInterfaceStyle == .dark ? platformColor(dark).resolvedColor(with: $0) : platformColor(light).resolvedColor(with: $0) }
            #else
            NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? platformColor(dark) : platformColor(light) }
            #endif
        }
    }

    /// One colour object per value, made once.
    ///
    /// A light and dark pair is a dynamic colour, and two made from the same pair do not
    /// compare equal (each is a new closure). SwiftUI compares a view's
    /// foreground style with the one it last drew, so a new object from every body reads as a
    /// change of colour, and inside an animation SwiftUI animates it, drawing the text from an
    /// interpolated picture that moves on a path of its own. On 23 October 2026 the sidebar's
    /// labels slid a row away from their icons while a machine opened, and the main thread
    /// redrew their glyphs every frame. The same value always draws the same colour, and a
    /// theme names a few, so they are kept for the life of the process.
    private static let colours = ColourCache()

    private final class ColourCache: @unchecked Sendable {
        private let lock = NSLock()
        private var platformColours: [RipulColorValue: RipulPlatformColor] = [:]
        private var swiftUIColours: [RipulColorValue: Color] = [:]

        func platform(_ value: RipulColorValue, make: () -> RipulPlatformColor) -> RipulPlatformColor {
            lock.lock(); defer { lock.unlock() }
            if let made = platformColours[value] { return made }
            let made = make()
            platformColours[value] = made
            return made
        }

        /// Made outside the lock: making one asks `platform` for its platform colour.
        func swiftUI(_ value: RipulColorValue, make: () -> Color) -> Color {
            lock.lock()
            if let made = swiftUIColours[value] { lock.unlock(); return made }
            lock.unlock()
            let made = make()
            lock.lock(); defer { lock.unlock() }
            if let other = swiftUIColours[value] { return other }
            swiftUIColours[value] = made
            return made
        }
    }

    package static func platformColor(_ literal: RipulColorLiteral) -> RipulPlatformColor {
        switch literal {
        case .rgba(let r, let g, let b, let a):
            return RipulPlatformColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a))
        case .system(let name):
            return systemPlatformColor(name)
        case .asset(let name):
            // A name the catalogue does not hold is drawn as nothing, as SwiftUI draws it.
            return RipulPlatformColor(named: name) ?? .clear
        }
    }

    static func systemPlatformColor(_ name: String) -> RipulPlatformColor {
        #if canImport(UIKit)
        switch name {
        case "white": return .white
        case "black": return .black
        case "tint": return .tintColor
        case "label": return .label
        case "secondaryLabel": return .secondaryLabel
        case "tertiaryLabel": return .tertiaryLabel
        case "quaternaryLabel": return .quaternaryLabel
        case "placeholderText": return .placeholderText
        case "separator": return .separator
        case "opaqueSeparator": return .opaqueSeparator
        case "link": return .link
        case "systemBackground": return .systemBackground
        case "secondarySystemBackground": return .secondarySystemBackground
        case "tertiarySystemBackground": return .tertiarySystemBackground
        case "systemGroupedBackground": return .systemGroupedBackground
        case "secondarySystemGroupedBackground": return .secondarySystemGroupedBackground
        case "tertiarySystemGroupedBackground": return .tertiarySystemGroupedBackground
        case "systemFill": return .systemFill
        case "secondarySystemFill": return .secondarySystemFill
        case "tertiarySystemFill": return .tertiarySystemFill
        case "quaternarySystemFill": return .quaternarySystemFill
        case "systemRed": return .systemRed
        case "systemOrange": return .systemOrange
        case "systemYellow": return .systemYellow
        case "systemGreen": return .systemGreen
        case "systemMint": return .systemMint
        case "systemTeal": return .systemTeal
        case "systemCyan": return .systemCyan
        case "systemBlue": return .systemBlue
        case "systemIndigo": return .systemIndigo
        case "systemPurple": return .systemPurple
        case "systemPink": return .systemPink
        case "systemBrown": return .systemBrown
        case "systemGray": return .systemGray
        case "systemGray2": return .systemGray2
        case "systemGray3": return .systemGray3
        case "systemGray4": return .systemGray4
        case "systemGray5": return .systemGray5
        case "systemGray6": return .systemGray6
        default: return .label
        }
        #else
        // AppKit has no grouped backgrounds or numbered greys; these are its nearest
        // equivalents. The Mac host's own screens are not themed (they only compile).
        switch name {
        case "white": return .white
        case "black": return .black
        case "tint": return .controlAccentColor
        case "label": return .labelColor
        case "secondaryLabel": return .secondaryLabelColor
        case "tertiaryLabel": return .tertiaryLabelColor
        case "quaternaryLabel": return .quaternaryLabelColor
        case "placeholderText": return .placeholderTextColor
        case "separator", "opaqueSeparator": return .separatorColor
        case "link": return .linkColor
        case "systemBackground", "systemGroupedBackground": return .windowBackgroundColor
        case "secondarySystemBackground", "secondarySystemGroupedBackground": return .controlBackgroundColor
        case "tertiarySystemBackground", "tertiarySystemGroupedBackground": return .underPageBackgroundColor
        case "systemFill", "secondarySystemFill": return .quaternaryLabelColor
        case "tertiarySystemFill", "quaternarySystemFill": return .quaternaryLabelColor
        case "systemRed": return .systemRed
        case "systemOrange": return .systemOrange
        case "systemYellow": return .systemYellow
        case "systemGreen": return .systemGreen
        case "systemMint": return .systemMint
        case "systemTeal": return .systemTeal
        case "systemCyan": return .systemCyan
        case "systemBlue": return .systemBlue
        case "systemIndigo": return .systemIndigo
        case "systemPurple": return .systemPurple
        case "systemPink": return .systemPink
        case "systemBrown": return .systemBrown
        default: return .systemGray
        }
        #endif
    }
}

#if canImport(UIKit)
extension UIColor {
    /// A base colour role for UIKit. With no theme this is the system colour itself
    /// (`UIColor.ripul(.text) === UIColor.label`). `.accent` is `UIColor.tintColor`, which
    /// follows the tint of the view it is drawn in.
    public static func ripul(_ role: RipulColorRole) -> UIColor { RipulTheme.platformColor(RipulTheme.color(role)) }

    /// The theme's accent once a theme names one, and until then `role`: see the style form.
    public static func ripul(accentOr role: RipulColorRole) -> UIColor {
        .ripul(RipulTheme.isDefault(.accent) ? role : .accent)
    }

    /// A system colour that no role fits; the system's own object.
    public static func ripul(system name: RipulSystemColor) -> UIColor { RipulTheme.systemPlatformColor(name.rawValue) }
}
#elseif canImport(AppKit)
extension NSColor {
    /// A base colour role for AppKit.
    public static func ripul(_ role: RipulColorRole) -> NSColor { RipulTheme.platformColor(RipulTheme.color(role)) }
}
#endif
