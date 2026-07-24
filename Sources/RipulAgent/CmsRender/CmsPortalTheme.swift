import SwiftUI

/// Swift twin of the portal theme: `PortalThemeConfig` (stored on the CMS
/// definition) + the `color.*` token table from `colorTokens.ts`, with MUI's
/// light/dark palette defaults filling unset fields — so a page authored
/// against theme tokens renders in the portal's brand colours natively.
public struct CmsPortalThemeConfig: Codable, Equatable {
    public struct Palette: Codable, Equatable {
        public var primary: String?
        public var secondary: String?
        public var background: String?
        public var paper: String?
        public var text: String?
        public var mutedText: String?
        public var divider: String?
    }
    public var mode: String?
    public var palette: Palette?
}

public struct CmsPortalTheme {
    let isDark: Bool
    let primary: Color
    let secondary: Color
    let background: Color
    let paper: Color
    let textPrimary: Color
    let textSecondary: Color
    let divider: Color

    public init(config: CmsPortalThemeConfig?, effectiveDark: Bool = false) {
        let mode = config?.mode
        let dark: Bool
        switch mode {
        case "dark":
            dark = true
        case "light":
            dark = false
        default:
            dark = effectiveDark
        }
        isDark = dark
        let palette = config?.palette
        func color(_ raw: String?, _ fallback: Color) -> Color {
            CmsCss.color(raw) ?? fallback
        }
        // MUI defaults per mode.
        primary = color(palette?.primary, Color(red: 0.098, green: 0.463, blue: 0.824)) // #1976d2
        secondary = color(palette?.secondary, Color(red: 0.612, green: 0.153, blue: 0.690)) // #9c27b0
        background = color(palette?.background, dark ? Color(red: 0.071, green: 0.071, blue: 0.071) : .white)
        paper = color(palette?.paper, dark ? Color(red: 0.071, green: 0.071, blue: 0.071) : .white)
        textPrimary = color(palette?.text, dark ? .white : Color(white: 0, opacity: 0.87))
        textSecondary = color(palette?.mutedText, dark ? Color(white: 1, opacity: 0.7) : Color(white: 0, opacity: 0.6))
        divider = color(palette?.divider, dark ? Color(white: 1, opacity: 0.12) : Color(white: 0, opacity: 0.12))
    }

    /// Token table — mirror of COLOR_PATHS in colorTokens.ts. Non-token
    /// values fall through to the CSS parser; unknowns return nil.
    public func resolve(_ value: String?) -> Color? {
        guard let value, !value.isEmpty else { return nil }
        switch value {
        case "color.primary": return primary
        case "color.primary.contrast": return isDark ? .black : .white
        case "color.secondary": return secondary
        case "color.secondary.contrast": return .white
        case "color.error": return Color(red: 0.827, green: 0.184, blue: 0.184)
        case "color.warning": return Color(red: 0.929, green: 0.490, blue: 0.192)
        case "color.info": return Color(red: 0.008, green: 0.541, blue: 0.925)
        case "color.success": return Color(red: 0.180, green: 0.490, blue: 0.196)
        case "color.text.primary": return textPrimary
        case "color.text.secondary": return textSecondary
        case "color.text.disabled": return isDark ? Color(white: 1, opacity: 0.5) : Color(white: 0, opacity: 0.38)
        case "color.background": return background
        case "color.paper": return paper
        case "color.divider": return divider
        case "color.common.white": return .white
        case "color.common.black": return .black
        default: return CmsCss.color(value)
        }
    }
}
