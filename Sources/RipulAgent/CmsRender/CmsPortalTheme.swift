import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Swift twin of the portal theme: `PortalThemeConfig` (stored on the CMS
/// definition, cmsDefinitionsService.ts) + `buildPortalTheme` / `deriveBrand`
/// (portalTheme.ts) + the `color.*` / `radius.*` token tables
/// (colorTokens.ts, radiusTokens.ts), with MUI's light/dark palette defaults
/// filling unset fields — so a page authored against theme tokens renders in
/// the portal's brand natively.
///
/// Decoding is LENIENT: the theme rides inside the definition / visitor
/// config, so one mistyped field (a weight stored as "800") must degrade to
/// "unset", never fail the whole page load.
public struct CmsPortalThemeConfig: Codable, Equatable {
    public struct Palette: Codable, Equatable {
        public var primary: String?
        public var secondary: String?
        public var background: String?
        public var paper: String?
        public var text: String?
        public var mutedText: String?
        public var divider: String?
        /// Deeper partner to `primary` — gradient start stop. Derived when unset.
        public var accent: String?
        /// Faint brand wash (`color.tint`). Derived when unset.
        public var tint: String?
        /// Recessed surface (`color.surfaceMuted`). Derived when unset.
        public var surfaceMuted: String?
        public var success: String?
        public var warning: String?
        public var error: String?

        public init(
            primary: String? = nil, secondary: String? = nil, background: String? = nil,
            paper: String? = nil, text: String? = nil, mutedText: String? = nil,
            divider: String? = nil, accent: String? = nil, tint: String? = nil,
            surfaceMuted: String? = nil, success: String? = nil, warning: String? = nil,
            error: String? = nil
        ) {
            self.primary = primary; self.secondary = secondary; self.background = background
            self.paper = paper; self.text = text; self.mutedText = mutedText
            self.divider = divider; self.accent = accent; self.tint = tint
            self.surfaceMuted = surfaceMuted; self.success = success; self.warning = warning
            self.error = error
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            primary = c.lossyString(.primary)
            secondary = c.lossyString(.secondary)
            background = c.lossyString(.background)
            paper = c.lossyString(.paper)
            text = c.lossyString(.text)
            mutedText = c.lossyString(.mutedText)
            divider = c.lossyString(.divider)
            accent = c.lossyString(.accent)
            tint = c.lossyString(.tint)
            surfaceMuted = c.lossyString(.surfaceMuted)
            success = c.lossyString(.success)
            warning = c.lossyString(.warning)
            error = c.lossyString(.error)
        }

        /// `{ ...self, ...over }` — the web's darkPalette layering. Unset keys
        /// in `over` keep this palette's value.
        func layered(with over: Palette?) -> Palette {
            guard let over else { return self }
            return Palette(
                primary: over.primary ?? primary, secondary: over.secondary ?? secondary,
                background: over.background ?? background, paper: over.paper ?? paper,
                text: over.text ?? text, mutedText: over.mutedText ?? mutedText,
                divider: over.divider ?? divider, accent: over.accent ?? accent,
                tint: over.tint ?? tint, surfaceMuted: over.surfaceMuted ?? surfaceMuted,
                success: over.success ?? success, warning: over.warning ?? warning,
                error: over.error ?? error
            )
        }
    }

    /// The site's brand gradient (`gradient` in PortalThemeConfig): what
    /// `color.gradient` paints. Unset stops: accent → primary.
    public struct Gradient: Codable, Equatable {
        /// Two or more CSS colours, first to last along the sweep, evenly spaced.
        public var stops: [String]?
        /// The sweep's direction in CSS degrees. Unset: `buttons.gradientAngle`, else 135.
        public var angle: Double?
        /// The stops when the site renders dark. Unset: `stops`.
        public var darkStops: [String]?

        public init(stops: [String]? = nil, angle: Double? = nil, darkStops: [String]? = nil) {
            self.stops = stops; self.angle = angle; self.darkStops = darkStops
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            stops = c.lossyStrings(.stops)
            angle = c.lossyDouble(.angle)
            darkStops = c.lossyStrings(.darkStops)
        }
    }

    public struct Typography: Codable, Equatable {
        public var fontFamily: String?
        public var baseFontSize: Double?
        public var scale: Double?
        /// Headings only; falls back to `fontFamily`.
        public var headingFontFamily: String?
        /// h1–h6 weight, e.g. 800.
        public var headingWeight: Double?
        /// h1–h6 tracking in em, e.g. -0.02.
        public var headingLetterSpacing: Double?
        /// The site's own text styles by name (h1–h6, subtitle1, body1, …): CmsSiteText.
        public var styles: [String: CmsSiteTextStyleConfig]?
        /// Curly quotes in text blocks.
        public var smartQuotes: Bool?
        /// The gap after a paragraph in text and markdown blocks (CSS: `0.87em`, `14px`).
        public var paragraphSpacing: String?

        public init(
            fontFamily: String? = nil, baseFontSize: Double? = nil, scale: Double? = nil,
            headingFontFamily: String? = nil, headingWeight: Double? = nil,
            headingLetterSpacing: Double? = nil
        ) {
            self.fontFamily = fontFamily; self.baseFontSize = baseFontSize; self.scale = scale
            self.headingFontFamily = headingFontFamily; self.headingWeight = headingWeight
            self.headingLetterSpacing = headingLetterSpacing
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            fontFamily = c.lossyString(.fontFamily)
            baseFontSize = c.lossyDouble(.baseFontSize)
            scale = c.lossyDouble(.scale)
            headingFontFamily = c.lossyString(.headingFontFamily)
            headingWeight = c.lossyDouble(.headingWeight)
            headingLetterSpacing = c.lossyDouble(.headingLetterSpacing)
            styles = try? c.decode([String: CmsSiteTextStyleConfig].self, forKey: .styles)
            smartQuotes = try? c.decode(Bool.self, forKey: .smartQuotes)
            paragraphSpacing = c.lossyString(.paragraphSpacing)
        }
    }

    public struct Shape: Codable, Equatable {
        /// Base radius — `radius.sm|md|lg` multiply it. MUI default 4.
        public var borderRadius: Double?
        /// `radius.card`; falls back to borderRadius × 2.
        public var cardRadius: Double?
        /// `radius.input`; falls back to borderRadius.
        public var inputRadius: Double?
        /// `radius.button`; 999 = pill. Falls back to borderRadius.
        public var buttonRadius: Double?

        public init(borderRadius: Double? = nil, cardRadius: Double? = nil,
                    inputRadius: Double? = nil, buttonRadius: Double? = nil) {
            self.borderRadius = borderRadius; self.cardRadius = cardRadius
            self.inputRadius = inputRadius; self.buttonRadius = buttonRadius
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            borderRadius = c.lossyDouble(.borderRadius)
            cardRadius = c.lossyDouble(.cardRadius)
            inputRadius = c.lossyDouble(.inputRadius)
            buttonRadius = c.lossyDouble(.buttonRadius)
        }
    }

    public struct Buttons: Codable, Equatable {
        /// `solid` | `gradient` (contained primary buttons take the brand gradient).
        public var style: String?
        /// Gradient direction in CSS degrees (default 135).
        public var gradientAngle: Double?
        public var fontWeight: Double?
        /// `none` | `uppercase`.
        public var textTransform: String?

        public init(style: String? = nil, gradientAngle: Double? = nil,
                    fontWeight: Double? = nil, textTransform: String? = nil) {
            self.style = style; self.gradientAngle = gradientAngle
            self.fontWeight = fontWeight; self.textTransform = textTransform
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            style = c.lossyString(.style)
            gradientAngle = c.lossyDouble(.gradientAngle)
            fontWeight = c.lossyDouble(.fontWeight)
            textTransform = c.lossyString(.textTransform)
        }
    }

    public var mode: String?
    public var palette: Palette?
    /// Layered over `palette` when the portal renders dark.
    public var darkPalette: Palette?
    public var gradient: Gradient?
    public var typography: Typography?
    public var spacing: Double?
    public var shape: Shape?
    public var buttons: Buttons?
    /// The site's own list styles, by name (CmsListStyle.swift). A key that
    /// names a built-in (`system`, `plain`, `cards`) is ignored.
    public var listStyles: [String: CmsListStyle]?
    /// `system` | `plain` | `cards` | a key of `listStyles`; unset = `system`.
    public var defaultListStyle: String?
    /// The site's own card styles, by name, as JSON (CmsCardStyle.swift).
    public var cardStyles: [String: CmsJSON]?
    /// `plain` | `elevated` | `outlined` | a key of `cardStyles`; unset = `elevated`.
    public var defaultCardStyle: String?
    /// The site's masthead styles, by name, as JSON (CmsMasthead.swift).
    public var mastheads: [String: CmsJSON]?
    /// `standard` | a key of `mastheads`; unset = `standard`.
    public var defaultMasthead: String?
    /// How record forms open: `{ default: sheet|page, viewerChoice }`, as JSON.
    public var formPresentation: CmsJSON?
    /// The site's input settings, as JSON: `choiceStyle` is read (the style choice inputs take when they name none).
    public var inputs: CmsJSON?

    public init(mode: String? = nil, palette: Palette? = nil, darkPalette: Palette? = nil,
                gradient: Gradient? = nil, typography: Typography? = nil, spacing: Double? = nil,
                shape: Shape? = nil, buttons: Buttons? = nil,
                listStyles: [String: CmsListStyle]? = nil, defaultListStyle: String? = nil) {
        self.mode = mode; self.palette = palette; self.darkPalette = darkPalette
        self.gradient = gradient; self.typography = typography; self.spacing = spacing
        self.shape = shape; self.buttons = buttons
        self.listStyles = listStyles; self.defaultListStyle = defaultListStyle
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = c.lossyString(.mode)
        palette = try? c.decodeIfPresent(Palette.self, forKey: .palette)
        darkPalette = try? c.decodeIfPresent(Palette.self, forKey: .darkPalette)
        gradient = try? c.decodeIfPresent(Gradient.self, forKey: .gradient)
        typography = try? c.decodeIfPresent(Typography.self, forKey: .typography)
        spacing = c.lossyDouble(.spacing)
        shape = try? c.decodeIfPresent(Shape.self, forKey: .shape)
        buttons = try? c.decodeIfPresent(Buttons.self, forKey: .buttons)
        listStyles = c.lossyListStyles(.listStyles)
        defaultListStyle = c.lossyString(.defaultListStyle)
        cardStyles = try? c.decodeIfPresent([String: CmsJSON].self, forKey: .cardStyles)
        defaultCardStyle = c.lossyString(.defaultCardStyle)
        mastheads = try? c.decodeIfPresent([String: CmsJSON].self, forKey: .mastheads)
        defaultMasthead = c.lossyString(.defaultMasthead)
        formPresentation = try? c.decodeIfPresent(CmsJSON.self, forKey: .formPresentation)
        inputs = try? c.decodeIfPresent(CmsJSON.self, forKey: .inputs)
    }
}

private extension KeyedDecodingContainer {
    /// String, or nil for absent / null / wrong-typed / empty (the web's
    /// truthiness checks treat "" as unset).
    func lossyString(_ key: Key) -> String? {
        guard let s = try? decodeIfPresent(String.self, forKey: key), !s.isEmpty else { return nil }
        return s
    }

    /// The strings of a list, skipping anything that is not one; nil when the
    /// key is absent or not a list.
    func lossyStrings(_ key: Key) -> [String]? {
        guard var list = try? nestedUnkeyedContainer(forKey: key) else { return nil }
        var out: [String] = []
        while !list.isAtEnd {
            if let s = try? list.decode(String.self) { out.append(s) }
            else { _ = try? list.decode(CmsSkippedValue.self) }
        }
        return out
    }

    /// Each style that decodes; an entry that is not an object is skipped.
    func lossyListStyles(_ key: Key) -> [String: CmsListStyle]? {
        guard let raw = try? decodeIfPresent([String: CmsJSON].self, forKey: key) else { return nil }
        var out: [String: CmsListStyle] = [:]
        for (name, value) in raw {
            guard value.objectValue != nil, let data = try? JSONEncoder().encode(value),
                  let style = try? JSONDecoder().decode(CmsListStyle.self, from: data) else { continue }
            out[name] = style
        }
        return out
    }

    /// Number, accepting a numeric string; nil otherwise.
    func lossyDouble(_ key: Key) -> Double? {
        if let n = try? decodeIfPresent(Double.self, forKey: key) { return n }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return Double(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
}

/// Decodes and discards one value of any type, so a list can step past an
/// entry of the wrong type.
private struct CmsSkippedValue: Decodable {
    init(from decoder: Decoder) throws {}
}

// MARK: - RGBA maths (twins of MUI's colorManipulator)

/// sRGB components 0…1. The maths the web runs on CSS strings (darken,
/// alpha, getContrastText) runs here on parsed components.
struct CmsRGBA: Equatable {
    var r: Double, g: Double, b: Double, a: Double

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    /// Hex `#rgb|#rrggbb|#rrggbbaa` or `rgb()/rgba()`.
    init?(css: String?) {
        guard let c = CmsCss.rgba(css) else { return nil }
        self = c
    }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }

    /// MUI `darken`: each channel × (1 − coefficient); alpha kept.
    func darkened(_ coefficient: Double) -> CmsRGBA {
        let k = 1 - min(max(coefficient, 0), 1)
        return CmsRGBA(r: r * k, g: g * k, b: b * k, a: a)
    }

    /// MUI `alpha`: REPLACES the alpha channel.
    func withAlpha(_ value: Double) -> CmsRGBA {
        CmsRGBA(r: r, g: g, b: b, a: min(max(value, 0), 1))
    }

    /// WCAG relative luminance (MUI `getLuminance`).
    var luminance: Double {
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// MUI `getContrastText` (contrastThreshold 3): white when it reaches
    /// 3:1 against this fill, else rgba(0,0,0,0.87).
    var contrastText: CmsRGBA {
        let ratio = (1.0 + 0.05) / (luminance + 0.05)
        return ratio >= 3 ? CmsRGBA(r: 1, g: 1, b: 1) : CmsRGBA(r: 0, g: 0, b: 0, a: 0.87)
    }
}

// MARK: - Resolved theme

public struct CmsPortalTheme {
    let isDark: Bool
    let primary: Color
    let primaryContrast: Color
    let secondary: Color
    let secondaryContrast: Color
    let background: Color
    let paper: Color
    let textPrimary: Color
    let textSecondary: Color
    let divider: Color
    let success: Color
    let warning: Color
    let error: Color
    let info: Color
    /// `color.*.soft`: a status colour at 14%, the wash behind a status pill.
    let primarySoft: Color
    let successSoft: Color
    let warningSoft: Color
    let errorSoft: Color

    // Brand tokens (CmsBrandTokens in portalTheme.ts).
    let accent: Color
    let tint: Color
    let surfaceMuted: Color
    /// Component values behind primary / accent / tint / surfaceMuted (for
    /// exact parity checks against the web's derivation).
    let primaryRGBA: CmsRGBA
    let accentRGBA: CmsRGBA
    let tintRGBA: CmsRGBA
    let surfaceMutedRGBA: CmsRGBA
    /// Every palette role's colour, for list styles (which name roles).
    let roleRGBA: [CmsPaletteRole: CmsRGBA]
    /// Brand gradient: the theme's stops (its dark ones when dark), or
    /// accent → primary, at `gradientAngle` CSS degrees.
    let gradient: LinearGradient
    let gradientStops: [CmsRGBA]
    let gradientAngle: Double
    /// Base radius (`shape.borderRadius`, MUI default 4).
    let baseRadius: CGFloat
    let cardRadius: CGFloat
    let inputRadius: CGFloat
    let buttonRadius: CGFloat
    /// The site set its own button corners (shape.buttonRadius, or the borderRadius
    /// they fall back to). Unset, native buttons keep the system's shape: the web's
    /// 4 px is MUI's default, not the site's design.
    let setsButtonRadius: Bool
    /// The site set its own card corners (shape.cardRadius, or borderRadius).
    let setsCardRadius: Bool
    /// The site set its own field corners (shape.inputRadius, or borderRadius).
    let setsInputRadius: Bool
    /// `solid` | `gradient`.
    let buttonStyle: String
    let buttonFontWeight: Font.Weight?
    let buttonUppercase: Bool

    /// True when the site's palette (its dark one when dark) names a page
    /// background. Only then does a native page paint `background`; a site
    /// that sets none keeps iOS's own system background.
    let setsPageBackground: Bool
    /// The site's body font family (`typography.fontFamily`'s first family),
    /// when it is installed on this device; nil = the system font.
    let fontFamily: String?

    // Heading typography (h1–h6).
    let headingFontFamily: String?
    let headingWeight: Font.Weight?
    /// Tracking in em — multiply by the font size for points.
    let headingLetterSpacing: Double?

    public init(config: CmsPortalThemeConfig?, effectiveDark: Bool = false) {
        let dark: Bool
        switch config?.mode {
        case "dark": dark = true
        case "light": dark = false
        default: dark = effectiveDark
        }
        isDark = dark
        let base = config?.palette ?? CmsPortalThemeConfig.Palette()
        let palette = dark ? base.layered(with: config?.darkPalette) : base

        func rgba(_ raw: String?, _ fallback: String) -> CmsRGBA {
            CmsRGBA(css: raw) ?? CmsRGBA(css: fallback)!
        }
        // MUI createTheme defaults per mode (light / dark).
        let primaryRGBA = rgba(palette.primary, dark ? "#90caf9" : "#1976d2")
        let secondaryRGBA = rgba(palette.secondary, dark ? "#ce93d8" : "#9c27b0")
        let textRGBA = rgba(palette.text, dark ? "#ffffff" : "rgba(0,0,0,0.87)")
        primary = primaryRGBA.color
        primaryContrast = primaryRGBA.contrastText.color
        secondary = secondaryRGBA.color
        secondaryContrast = secondaryRGBA.contrastText.color
        background = rgba(palette.background, dark ? "#121212" : "#ffffff").color
        paper = rgba(palette.paper, dark ? "#121212" : "#ffffff").color
        textPrimary = textRGBA.color
        textSecondary = rgba(palette.mutedText, dark ? "rgba(255,255,255,0.7)" : "rgba(0,0,0,0.6)").color
        divider = rgba(palette.divider, dark ? "rgba(255,255,255,0.12)" : "rgba(0,0,0,0.12)").color
        let successRGBA = rgba(palette.success, dark ? "#66bb6a" : "#2e7d32")
        let warningRGBA = rgba(palette.warning, dark ? "#ffa726" : "#ed6c02")
        let errorRGBA = rgba(palette.error, dark ? "#f44336" : "#d32f2f")
        success = successRGBA.color
        warning = warningRGBA.color
        error = errorRGBA.color
        primarySoft = primaryRGBA.withAlpha(0.14).color
        successSoft = successRGBA.withAlpha(0.14).color
        warningSoft = warningRGBA.withAlpha(0.14).color
        errorSoft = errorRGBA.withAlpha(0.14).color
        info = (dark ? CmsRGBA(css: "#29b6f6") : CmsRGBA(css: "#0288d1"))!.color

        // deriveBrand — mirror exactly.
        let accentRGBA = CmsRGBA(css: palette.accent) ?? primaryRGBA.darkened(0.35)
        let tintRGBA = CmsRGBA(css: palette.tint) ?? primaryRGBA.withAlpha(dark ? 0.18 : 0.08)
        let surfaceMutedRGBA = CmsRGBA(css: palette.surfaceMuted) ?? textRGBA.withAlpha(dark ? 0.06 : 0.035)
        self.primaryRGBA = primaryRGBA
        self.accentRGBA = accentRGBA
        self.tintRGBA = tintRGBA
        self.surfaceMutedRGBA = surfaceMutedRGBA
        accent = accentRGBA.color
        tint = tintRGBA.color
        surfaceMuted = surfaceMutedRGBA.color
        roleRGBA = [
            .primary: primaryRGBA, .secondary: secondaryRGBA, .accent: accentRGBA, .tint: tintRGBA,
            .background: rgba(palette.background, dark ? "#121212" : "#ffffff"),
            .paper: rgba(palette.paper, dark ? "#121212" : "#ffffff"),
            .surfaceMuted: surfaceMutedRGBA,
            .divider: rgba(palette.divider, dark ? "rgba(255,255,255,0.12)" : "rgba(0,0,0,0.12)"),
            .text: textRGBA,
            .mutedText: rgba(palette.mutedText, dark ? "rgba(255,255,255,0.7)" : "rgba(0,0,0,0.6)"),
            .success: successRGBA, .warning: warningRGBA, .error: errorRGBA,
        ]
        // brandGradient (portalTheme.ts): own stops, dark ones when dark, else
        // accent → primary; fewer than two readable stops is no gradient of its own.
        func readable(_ stops: [String]?) -> [CmsRGBA]? {
            let parsed = (stops ?? []).compactMap { CmsRGBA(css: $0) }
            return parsed.count >= 2 ? parsed : nil
        }
        let ownGradient = config?.gradient
        let stops = (dark ? readable(ownGradient?.darkStops) : nil)
            ?? readable(ownGradient?.stops)
            ?? [accentRGBA, primaryRGBA]
        gradientStops = stops
        let angle = ownGradient?.angle ?? config?.buttons?.gradientAngle ?? 135
        gradientAngle = angle
        let points = Self.gradientPoints(angle: angle)
        gradient = LinearGradient(colors: stops.map(\.color),
                                  startPoint: points.start, endPoint: points.end)

        let shape = config?.shape
        let radius = shape?.borderRadius ?? 4
        baseRadius = CGFloat(radius)
        cardRadius = CGFloat(shape?.cardRadius ?? radius * 2)
        inputRadius = CGFloat(shape?.inputRadius ?? radius)
        buttonRadius = CGFloat(shape?.buttonRadius ?? radius)
        setsButtonRadius = shape?.buttonRadius != nil || shape?.borderRadius != nil
        setsInputRadius = shape?.inputRadius != nil || shape?.borderRadius != nil
        setsCardRadius = shape?.cardRadius != nil || shape?.borderRadius != nil
        buttonStyle = config?.buttons?.style ?? "solid"
        buttonFontWeight = config?.buttons?.fontWeight.map(CmsTypography.weight(css:))
        buttonUppercase = config?.buttons?.textTransform == "uppercase"

        setsPageBackground = palette.background != nil
        let typography = config?.typography
        // The first family in each stack this device has: a site's stack names its
        // web font first (freight-sans-pro), then the one an app bundles (Source Sans 3).
        fontFamily = CmsSiteText.installedFamily(stack: typography?.fontFamily)
        // Headings resolving to nothing fall back to the body family, as the web's inherit.
        headingFontFamily = CmsSiteText.installedFamily(stack: typography?.headingFontFamily) ?? fontFamily
        headingWeight = typography?.headingWeight.map(CmsTypography.weight(css:))
        headingLetterSpacing = typography?.headingLetterSpacing
    }

    /// `family` when this device has it, else nil (the system font draws).
    static func installedFamily(_ family: String?) -> String? {
        guard let family else { return nil }
        #if os(iOS)
        return UIFont.familyNames.contains(family) ? family : nil
        #elseif os(macOS)
        return NSFontManager.shared.availableFontFamilies.contains(family) ? family : nil
        #else
        return nil
        #endif
    }

    /// A font at `size` and `weight` in the site's family, or the system font.
    public func font(size: CGFloat, weight: Font.Weight) -> Font {
        guard let fontFamily else { return .system(size: size, weight: weight) }
        return Font.custom(fontFamily, size: size).weight(weight)
    }

    /// CSS `linear-gradient(<angle>deg, …)` direction as SwiftUI unit points:
    /// 0deg runs bottom→top, 90deg left→right, 135deg top-left→bottom-right.
    /// The direction vector is scaled so its dominant axis spans the box
    /// edge-to-edge (exact for multiples of 45° on a square, which is what
    /// the web's corner-to-corner gradient line reduces to).
    static func gradientPoints(angle: Double) -> (start: UnitPoint, end: UnitPoint) {
        let rad = angle * .pi / 180
        var dx = sin(rad)
        var dy = -cos(rad) // SwiftUI y grows downward
        let scale = max(abs(dx), abs(dy))
        if scale > 0 { dx /= scale; dy /= scale }
        return (UnitPoint(x: 0.5 - dx / 2, y: 0.5 - dy / 2), UnitPoint(x: 0.5 + dx / 2, y: 0.5 + dy / 2))
    }

    /// First family of a CSS font stack, unquoted; generic families (which
    /// mean "the system font" natively) return nil.
    static func firstFamily(_ stack: String?) -> String? {
        guard let first = stack?.split(separator: ",").first else { return nil }
        let name = first.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        let generic: Set<String> = ["sans-serif", "serif", "monospace", "system-ui", "-apple-system", "inherit", "cursive", "fantasy"]
        return name.isEmpty || generic.contains(name.lowercased()) ? nil : name
    }

    /// Token table — mirror of COLOR_PATHS in colorTokens.ts. Non-token
    /// values fall through to the CSS parser; unknowns return nil.
    /// `color.gradient` is a FILL, not a colour — it resolves nil here (the
    /// web's CSS would reject it as a text colour too); use `fill(_:)`.
    /// MUI palette paths and the colour token each is.
    static let muiPaletteAliases: [String: String] = [
        "text.primary": "color.text.primary", "text.secondary": "color.text.secondary",
        "text.disabled": "color.text.disabled",
        "primary.main": "color.primary", "primary.contrastText": "color.primary.contrast",
        "secondary.main": "color.secondary", "secondary.contrastText": "color.secondary.contrast",
        "error.main": "color.error", "warning.main": "color.warning", "info.main": "color.info",
        "success.main": "color.success",
        "background.default": "color.background", "background.paper": "color.paper",
        "divider": "color.divider", "common.white": "color.common.white", "common.black": "color.common.black",
    ]

    /// Text's colour: the value resolved, else the site's text colour (the web's
    /// inherited `text.primary`), never the system's own black.
    public func textColor(_ value: String?) -> Color { resolve(value) ?? textPrimary }

    public func resolve(_ value: String?) -> Color? {
        guard let value, !value.isEmpty else { return nil }
        // MUI's own palette paths (`text.primary`, `primary.main`): the web hands
        // any value that isn't a token to MUI, which reads these from the palette.
        if let token = Self.muiPaletteAliases[value] { return resolve(token) }
        switch value {
        case "color.primary": return primary
        case "color.primary.contrast": return primaryContrast
        case "color.secondary": return secondary
        case "color.secondary.contrast": return secondaryContrast
        case "color.error": return error
        case "color.warning": return warning
        case "color.info": return info
        case "color.success": return success
        case "color.text.primary": return textPrimary
        case "color.text.secondary": return textSecondary
        case "color.text.disabled": return isDark ? Color(white: 1, opacity: 0.5) : Color(white: 0, opacity: 0.38)
        case "color.background": return background
        case "color.paper": return paper
        case "color.divider": return divider
        case "color.common.white": return .white
        case "color.common.black": return .black
        case "color.accent": return accent
        case "color.tint": return tint
        case "color.surfaceMuted": return surfaceMuted
        case "color.primary.soft": return primarySoft
        case "color.success.soft": return successSoft
        case "color.warning.soft": return warningSoft
        case "color.error.soft": return errorSoft
        case "color.gradient": return nil
        default: return CmsCss.color(value)
        }
    }

    /// A palette role's colour: `text` is the text colour, `mutedText` the
    /// secondary text colour, the rest their `color.*` token.
    public func color(role: CmsPaletteRole) -> Color { rgba(role: role).color }

    func rgba(role: CmsPaletteRole) -> CmsRGBA { roleRGBA[role] ?? CmsRGBA(r: 0, g: 0, b: 0) }

    /// Background fill: `color.gradient` → the brand LinearGradient; any
    /// other value resolves as a colour. nil = no paint.
    public func fill(_ value: String?) -> AnyShapeStyle? {
        if value == "color.gradient" { return AnyShapeStyle(gradient) }
        return resolve(value).map { AnyShapeStyle($0) }
    }

    /// Radius token table — mirror of radiusTokens.ts. Role tokens
    /// (`radius.card|input|button`) read the theme's role radii; scale
    /// tokens multiply the base; pills (≥ 999) become 9999 (SwiftUI clamps
    /// a RoundedRectangle's radius to a capsule). Non-tokens parse as CSS
    /// lengths; unknowns return nil.
    public func radius(_ value: String?) -> CGFloat? {
        guard let value, !value.isEmpty else { return nil }
        func pill(_ r: CGFloat) -> CGFloat { r >= 999 ? 9999 : r }
        switch value {
        case "radius.card": return pill(cardRadius)
        case "radius.input": return pill(inputRadius)
        case "radius.button": return pill(buttonRadius)
        case "radius.none": return 0
        case "radius.sm": return baseRadius * 0.5
        case "radius.md": return baseRadius
        case "radius.lg": return baseRadius * 2
        case "radius.full": return 9999
        default: return CmsCss.points(value)
        }
    }
}

// MARK: - The site's own mode

extension CmsPortalThemeConfig {
    /// The colour scheme the site forces (`mode: "light"` or `"dark"`), or nil
    /// when it follows the device (`system`, unset or anything else).
    public var forcedColorScheme: ColorScheme? {
        switch mode {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}

/// Applies a site's forced `mode` to everything under it, so the system's
/// own chrome (large titles, bars, list rows that read `\.colorScheme`) and
/// the CMS content agree. `ownsWindow` also sets it as the presentation's
/// preference, which reaches the status bar and the tab bar: only a view that
/// is the whole app (`CmsAppView`) does that, since the preference spreads to
/// the window around it. A site that follows the device changes nothing.
extension CmsPortalTheme {
    /// A native button's shape in the site's corners (shape.buttonRadius; 999 or
    /// more is a pill, 0 square), or the system's when the site sets none.
    /// A native panel's corners: the site's card radius when it sets one, else
    /// the panel's own (`fallback`), so a site that sets none looks as before.
    func cardCorner(_ fallback: CGFloat) -> CGFloat { setsCardRadius ? cardRadius : fallback }

    var buttonShape: ButtonBorderShape {
        !setsButtonRadius ? .automatic : buttonRadius >= 999 ? .capsule : .roundedRectangle(radius: buttonRadius)
    }
}

#if os(iOS)
/// A text field in the site's field corners (shape.inputRadius) with the
/// system's own field fill, as `.roundedBorder` draws it; the system's
/// rounded border when the site sets none.
struct CmsSiteFieldStyle: ViewModifier {
    let theme: CmsPortalTheme

    func body(content: Content) -> some View {
        if theme.setsInputRadius {
            let shape = RoundedRectangle(cornerRadius: theme.inputRadius, style: .continuous)
            content
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(shape.fill(Color.ripul(system: .systemBackground)))
                .overlay(shape.strokeBorder(Color.ripul(system: .separator)))
        } else {
            content.textFieldStyle(.roundedBorder)
        }
    }
}
#endif

struct CmsSiteColorScheme: ViewModifier {
    @ObservedObject var runtime: CmsRuntime
    var ownsWindow: Bool

    func body(content: Content) -> some View {
        let forced = runtime.themeConfig?.forcedColorScheme
        if let forced {
            if ownsWindow {
                content.environment(\.colorScheme, forced).preferredColorScheme(forced)
            } else {
                // The navigation bar belongs to the host's stack, outside this
                // view, and `toolbarColorScheme` from inside doesn't reach a
                // large title at rest (checked on iOS 26.4): a host embedding
                // a page applies `forcedColorScheme` around its own stack.
                content.environment(\.colorScheme, forced)
            }
        } else {
            content
        }
    }
}

// MARK: - Page background

/// Paints the site palette's `background` behind a native page, under the
/// large title and the bars as a grouped background is, when the palette
/// names one. A site that names none keeps the system background.
struct CmsPageBackground: ViewModifier {
    @ObservedObject var runtime: CmsRuntime
    /// The page's own frame background, which wins over the palette's.
    var pageFill: String? = nil

    func body(content: Content) -> some View {
        if let fill = runtime.fill(pageFill) {
            content.background(Rectangle().fill(fill).ignoresSafeArea())
        } else if runtime.theme.setsPageBackground {
            content.background(runtime.theme.background.ignoresSafeArea())
        } else {
            content
        }
    }
}
