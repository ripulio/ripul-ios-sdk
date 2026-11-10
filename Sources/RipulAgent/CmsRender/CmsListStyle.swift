import SwiftUI

// MARK: - List styles in a site's theme (docs/cms-list-styles.md)

/// A key of the site's palette. A list style names colours by role, never by
/// value, so the dark palette and any palette change restyle every list.
public enum CmsPaletteRole: String, CaseIterable, Codable, Equatable {
    case primary, secondary, accent, tint
    case background, paper, surfaceMuted, divider
    case text, mutedText
    case success, warning, error
}

/// How a list is laid out. The three built-in styles are one of each.
public enum CmsListLayout: String, CaseIterable, Codable, Equatable {
    /// iOS's own inset grouped list: one rounded group of rows.
    case system
    /// Edge-to-edge rows with separators.
    case plain
    /// Each row its own card on the page background.
    case cards
}

/// One list style, as the site's theme stores it (`listStyles[name]`). Every
/// setting is optional: an unset one takes the built-in style's value. The
/// shape is the plan's "agreed shape", shared with the web's `ListStyle`.
///
/// Decoding is lenient, like the rest of the theme: a mistyped setting is
/// unset, and a colour that is not a palette role is unset.
public struct CmsListStyle: Codable, Equatable {
    public struct Border: Codable, Equatable {
        public var color: CmsPaletteRole?
        public var width: Double?
        public init(color: CmsPaletteRole? = nil, width: Double? = nil) { self.color = color; self.width = width }
    }

    public struct Shadow: Codable, Equatable {
        public var color: CmsPaletteRole?
        public var radius: Double?
        public var offsetY: Double?
        public var opacity: Double?
        public init(color: CmsPaletteRole? = nil, radius: Double? = nil, offsetY: Double? = nil, opacity: Double? = nil) {
            self.color = color; self.radius = radius; self.offsetY = offsetY; self.opacity = opacity
        }
    }

    public struct Card: Codable, Equatable {
        public var cornerRadius: Double?
        public var fill: CmsPaletteRole?
        public var border: Border?
        public var shadow: Shadow?
        /// Space between cards (and between rows of a `cards` list).
        public var gap: Double?
        /// What shows behind the cards.
        public var pageBackground: CmsPaletteRole?
        public init(cornerRadius: Double? = nil, fill: CmsPaletteRole? = nil, border: Border? = nil,
                    shadow: Shadow? = nil, gap: Double? = nil, pageBackground: CmsPaletteRole? = nil) {
            self.cornerRadius = cornerRadius; self.fill = fill; self.border = border
            self.shadow = shadow; self.gap = gap; self.pageBackground = pageBackground
        }
    }

    public struct Row: Codable, Equatable {
        public var minHeight: Double?
        public var paddingVertical: Double?
        public var paddingHorizontal: Double?
        public var separators: Bool?
        public var chevron: Bool?
        public init(minHeight: Double? = nil, paddingVertical: Double? = nil, paddingHorizontal: Double? = nil,
                    separators: Bool? = nil, chevron: Bool? = nil) {
            self.minHeight = minHeight; self.paddingVertical = paddingVertical
            self.paddingHorizontal = paddingHorizontal; self.separators = separators; self.chevron = chevron
        }
    }

    public enum Badge: String, Codable, Equatable { case none, circle, roundedSquare }

    public struct Picture: Codable, Equatable {
        public var size: Double?
        public var badge: Badge?
        public var badgeSize: Double?
        public var badgeTint: CmsPaletteRole?
        public init(size: Double? = nil, badge: Badge? = nil, badgeSize: Double? = nil, badgeTint: CmsPaletteRole? = nil) {
            self.size = size; self.badge = badge; self.badgeSize = badgeSize; self.badgeTint = badgeTint
        }
    }

    /// Title, subtitle and trailing text. The subtitle has no weight; only
    /// the trailing value has `align`.
    public struct Text: Codable, Equatable {
        public var size: Double?
        public var weight: Double?
        public var color: CmsPaletteRole?
        /// Trailing only: `center`, `top`, or `spread` (the value at the top,
        /// the chip at the bottom).
        public var align: String?
        public init(size: Double? = nil, weight: Double? = nil, color: CmsPaletteRole? = nil, align: String? = nil) {
            self.size = size; self.weight = weight; self.color = color; self.align = align
        }
    }

    /// The date block's weekday line.
    public struct DateTop: Codable, Equatable {
        public var size: Double?
        public var weight: Double?
        public var color: CmsPaletteRole?
        public var uppercase: Bool?
        public var letterSpacing: Double?
        public init(size: Double? = nil, weight: Double? = nil, color: CmsPaletteRole? = nil,
                    uppercase: Bool? = nil, letterSpacing: Double? = nil) {
            self.size = size; self.weight = weight; self.color = color
            self.uppercase = uppercase; self.letterSpacing = letterSpacing
        }
    }

    public struct DateBlock: Codable, Equatable {
        public var top: DateTop?
        public var bottom: Text?
        public init(top: DateTop? = nil, bottom: Text? = nil) { self.top = top; self.bottom = bottom }
    }

    /// A row layout's leading part (a date block or a picture).
    public struct Leading: Codable, Equatable {
        public var width: Double?
        /// `top` | `center`.
        public var align: String?
        public var date: DateBlock?
        public init(width: Double? = nil, align: String? = nil, date: DateBlock? = nil) {
            self.width = width; self.align = align; self.date = date
        }
    }

    /// The lines under a row layout's title.
    public struct Lines: Codable, Equatable {
        public var size: Double?
        public var weight: Double?
        public var color: CmsPaletteRole?
        public var gap: Double?
        public init(size: Double? = nil, weight: Double? = nil, color: CmsPaletteRole? = nil, gap: Double? = nil) {
            self.size = size; self.weight = weight; self.color = color; self.gap = gap
        }
    }

    /// The picture that starts a line.
    public struct InlineImage: Codable, Equatable {
        public var size: Double?
        public var cornerRadius: Double?
        public init(size: Double? = nil, cornerRadius: Double? = nil) { self.size = size; self.cornerRadius = cornerRadius }
    }

    /// A column's chip in a row.
    public struct Chip: Codable, Equatable {
        /// `filled` | `outlined` | `tinted`: used when the column's lozenge names none.
        public var variant: String?
        public var cornerRadius: Double?
        public var borderWidth: Double?
        public var size: Double?
        public var weight: Double?
        public var paddingHorizontal: Double?
        public var paddingVertical: Double?
        public var iconSize: Double?
        /// The colour when no style rule or lozenge sets one.
        public var color: CmsPaletteRole?
        public init(variant: String? = nil, cornerRadius: Double? = nil, borderWidth: Double? = nil,
                    size: Double? = nil, weight: Double? = nil, paddingHorizontal: Double? = nil,
                    paddingVertical: Double? = nil, iconSize: Double? = nil, color: CmsPaletteRole? = nil) {
            self.variant = variant; self.cornerRadius = cornerRadius; self.borderWidth = borderWidth
            self.size = size; self.weight = weight; self.paddingHorizontal = paddingHorizontal
            self.paddingVertical = paddingVertical; self.iconSize = iconSize; self.color = color
        }
    }

    public var basedOn: CmsListLayout?
    public var card: Card?
    public var row: Row?
    public var picture: Picture?
    public var title: Text?
    public var subtitle: Text?
    public var trailing: Text?
    public var leading: Leading?
    public var lines: Lines?
    public var inlineImage: InlineImage?
    public var chip: Chip?

    public init(basedOn: CmsListLayout? = nil, card: Card? = nil, row: Row? = nil, picture: Picture? = nil,
                title: Text? = nil, subtitle: Text? = nil, trailing: Text? = nil,
                leading: Leading? = nil, lines: Lines? = nil, inlineImage: InlineImage? = nil, chip: Chip? = nil) {
        self.basedOn = basedOn; self.card = card; self.row = row; self.picture = picture
        self.title = title; self.subtitle = subtitle; self.trailing = trailing
        self.leading = leading; self.lines = lines; self.inlineImage = inlineImage; self.chip = chip
    }

    /// True when the style sets nothing at all.
    public var isEmpty: Bool { self == CmsListStyle() }

    /// `{ ...base, ...self }`, setting by setting.
    public func layered(over base: CmsListStyle) -> CmsListStyle {
        func pick<T>(_ a: T?, _ b: T?) -> T? { a ?? b }
        let c = card, bc = base.card
        let border: Border? = (c?.border == nil && bc?.border == nil) ? nil : Border(
            color: pick(c?.border?.color, bc?.border?.color), width: pick(c?.border?.width, bc?.border?.width))
        let shadow: Shadow? = (c?.shadow == nil && bc?.shadow == nil) ? nil : Shadow(
            color: pick(c?.shadow?.color, bc?.shadow?.color), radius: pick(c?.shadow?.radius, bc?.shadow?.radius),
            offsetY: pick(c?.shadow?.offsetY, bc?.shadow?.offsetY), opacity: pick(c?.shadow?.opacity, bc?.shadow?.opacity))
        let mergedCard: Card? = (c == nil && bc == nil) ? nil : Card(
            cornerRadius: pick(c?.cornerRadius, bc?.cornerRadius), fill: pick(c?.fill, bc?.fill),
            border: border, shadow: shadow, gap: pick(c?.gap, bc?.gap),
            pageBackground: pick(c?.pageBackground, bc?.pageBackground))
        let r = row, br = base.row
        let mergedRow: Row? = (r == nil && br == nil) ? nil : Row(
            minHeight: pick(r?.minHeight, br?.minHeight), paddingVertical: pick(r?.paddingVertical, br?.paddingVertical),
            paddingHorizontal: pick(r?.paddingHorizontal, br?.paddingHorizontal),
            separators: pick(r?.separators, br?.separators), chevron: pick(r?.chevron, br?.chevron))
        let p = picture, bp = base.picture
        let mergedPicture: Picture? = (p == nil && bp == nil) ? nil : Picture(
            size: pick(p?.size, bp?.size), badge: pick(p?.badge, bp?.badge),
            badgeSize: pick(p?.badgeSize, bp?.badgeSize), badgeTint: pick(p?.badgeTint, bp?.badgeTint))
        func text(_ a: Text?, _ b: Text?) -> Text? {
            (a == nil && b == nil) ? nil : Text(size: pick(a?.size, b?.size), weight: pick(a?.weight, b?.weight),
                                                color: pick(a?.color, b?.color), align: pick(a?.align, b?.align))
        }
        var out = CmsListStyle(basedOn: pick(basedOn, base.basedOn), card: mergedCard, row: mergedRow,
                               picture: mergedPicture, title: text(title, base.title),
                               subtitle: text(subtitle, base.subtitle), trailing: text(trailing, base.trailing))
        let l = leading, bl = base.leading
        if l != nil || bl != nil {
            let d = l?.date, bd = bl?.date
            let top: DateTop? = (d?.top == nil && bd?.top == nil) ? nil : DateTop(
                size: pick(d?.top?.size, bd?.top?.size), weight: pick(d?.top?.weight, bd?.top?.weight),
                color: pick(d?.top?.color, bd?.top?.color), uppercase: pick(d?.top?.uppercase, bd?.top?.uppercase),
                letterSpacing: pick(d?.top?.letterSpacing, bd?.top?.letterSpacing))
            let date: DateBlock? = (d == nil && bd == nil) ? nil : DateBlock(top: top, bottom: text(d?.bottom, bd?.bottom))
            out.leading = Leading(width: pick(l?.width, bl?.width), align: pick(l?.align, bl?.align), date: date)
        }
        if lines != nil || base.lines != nil {
            out.lines = Lines(size: pick(lines?.size, base.lines?.size), weight: pick(lines?.weight, base.lines?.weight),
                              color: pick(lines?.color, base.lines?.color), gap: pick(lines?.gap, base.lines?.gap))
        }
        if inlineImage != nil || base.inlineImage != nil {
            out.inlineImage = InlineImage(size: pick(inlineImage?.size, base.inlineImage?.size),
                                          cornerRadius: pick(inlineImage?.cornerRadius, base.inlineImage?.cornerRadius))
        }
        let ch = chip, bch = base.chip
        if ch != nil || bch != nil {
            out.chip = Chip(variant: pick(ch?.variant, bch?.variant), cornerRadius: pick(ch?.cornerRadius, bch?.cornerRadius),
                            borderWidth: pick(ch?.borderWidth, bch?.borderWidth), size: pick(ch?.size, bch?.size),
                            weight: pick(ch?.weight, bch?.weight),
                            paddingHorizontal: pick(ch?.paddingHorizontal, bch?.paddingHorizontal),
                            paddingVertical: pick(ch?.paddingVertical, bch?.paddingVertical),
                            iconSize: pick(ch?.iconSize, bch?.iconSize), color: pick(ch?.color, bch?.color))
        }
        return out
    }
}

// MARK: Lenient decoding

private extension KeyedDecodingContainer {
    func number(_ key: Key) -> Double? {
        if let n = try? decodeIfPresent(Double.self, forKey: key) { return n }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return Double(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
    func role(_ key: Key) -> CmsPaletteRole? {
        (try? decodeIfPresent(String.self, forKey: key)).flatMap { $0.flatMap(CmsPaletteRole.init(rawValue:)) }
    }
    func flag(_ key: Key) -> Bool? { try? decodeIfPresent(Bool.self, forKey: key) }
    func choice(_ key: Key, _ allowed: [String]) -> String? {
        (try? decodeIfPresent(String.self, forKey: key)).flatMap { $0.flatMap { allowed.contains($0) ? $0 : nil } }
    }
    func part<T: Decodable>(_ type: T.Type, _ key: Key) -> T? { (try? decodeIfPresent(type, forKey: key)) ?? nil }
}

extension CmsListStyle.Border {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        color = c.role(.color); width = c.number(.width)
    }
}

extension CmsListStyle.Shadow {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        color = c.role(.color); radius = c.number(.radius); offsetY = c.number(.offsetY); opacity = c.number(.opacity)
    }
}

extension CmsListStyle.Card {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cornerRadius = c.number(.cornerRadius); fill = c.role(.fill)
        border = c.part(CmsListStyle.Border.self, .border); shadow = c.part(CmsListStyle.Shadow.self, .shadow)
        gap = c.number(.gap); pageBackground = c.role(.pageBackground)
    }
}

extension CmsListStyle.Row {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        minHeight = c.number(.minHeight); paddingVertical = c.number(.paddingVertical)
        paddingHorizontal = c.number(.paddingHorizontal); separators = c.flag(.separators); chevron = c.flag(.chevron)
    }
}

extension CmsListStyle.Picture {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        size = c.number(.size)
        badge = (try? c.decodeIfPresent(String.self, forKey: .badge)).flatMap { $0.flatMap(CmsListStyle.Badge.init(rawValue:)) }
        badgeSize = c.number(.badgeSize); badgeTint = c.role(.badgeTint)
    }
}

extension CmsListStyle.Text {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        size = c.number(.size); weight = c.number(.weight); color = c.role(.color)
        align = c.choice(.align, ["center", "top", "spread"])
    }
}

extension CmsListStyle.DateTop {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        size = c.number(.size); weight = c.number(.weight); color = c.role(.color)
        uppercase = c.flag(.uppercase); letterSpacing = c.number(.letterSpacing)
    }
}

extension CmsListStyle.DateBlock {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        top = c.part(CmsListStyle.DateTop.self, .top); bottom = c.part(CmsListStyle.Text.self, .bottom)
    }
}

extension CmsListStyle.Leading {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        width = c.number(.width); align = c.choice(.align, ["top", "center"])
        date = c.part(CmsListStyle.DateBlock.self, .date)
    }
}

extension CmsListStyle.Lines {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        size = c.number(.size); weight = c.number(.weight); color = c.role(.color); gap = c.number(.gap)
    }
}

extension CmsListStyle.InlineImage {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        size = c.number(.size); cornerRadius = c.number(.cornerRadius)
    }
}

extension CmsListStyle.Chip {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        variant = c.choice(.variant, ["filled", "outlined", "tinted"])
        cornerRadius = c.number(.cornerRadius); borderWidth = c.number(.borderWidth)
        size = c.number(.size); weight = c.number(.weight)
        paddingHorizontal = c.number(.paddingHorizontal); paddingVertical = c.number(.paddingVertical)
        iconSize = c.number(.iconSize); color = c.role(.color)
    }
}

extension CmsListStyle {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        basedOn = (try? c.decodeIfPresent(String.self, forKey: .basedOn)).flatMap { $0.flatMap(CmsListLayout.init(rawValue:)) }
        card = c.part(Card.self, .card); row = c.part(Row.self, .row); picture = c.part(Picture.self, .picture)
        title = c.part(Text.self, .title); subtitle = c.part(Text.self, .subtitle); trailing = c.part(Text.self, .trailing)
        leading = c.part(Leading.self, .leading); lines = c.part(Lines.self, .lines)
        inlineImage = c.part(InlineImage.self, .inlineImage); chip = c.part(Chip.self, .chip)
    }
}

// MARK: - The built-in styles

extension CmsListStyle {
    /// The three built-in styles, every setting filled. Twin of the web's
    /// table (`packages/shared-types/src/cmsListStyles.builtin.json` in chrome-extension); a test decodes
    /// that file and compares, so the two sides cannot drift.
    public static let builtIns: [String: CmsListStyle] = [
        CmsListLayout.system.rawValue: system,
        CmsListLayout.plain.rawValue: plain,
        CmsListLayout.cards.rawValue: cards,
    ]

    public static let builtInNames: [String] = CmsListLayout.allCases.map(\.rawValue)

    /// iOS's inset grouped list: the card is the one rounded group the rows
    /// sit in.
    public static let system = CmsListStyle(
        basedOn: .system,
        card: Card(cornerRadius: 10, fill: .paper, border: Border(color: .divider, width: 0),
                   shadow: Shadow(color: .text, radius: 0, offsetY: 0, opacity: 0),
                   gap: 0, pageBackground: .background),
        row: Row(minHeight: 44, paddingVertical: 11, paddingHorizontal: 16, separators: true, chevron: true),
        picture: Picture(size: 28, badge: CmsListStyle.Badge.none, badgeSize: 36, badgeTint: .tint),
        title: Text(size: 17, weight: 400, color: .text),
        subtitle: Text(size: 15, color: .mutedText),
        trailing: Text(size: 17, weight: 400, color: .mutedText, align: "center"),
        leading: Leading(width: 44, align: "center", date: DateBlock(
            top: DateTop(size: 12, weight: 600, color: .mutedText, uppercase: true, letterSpacing: 0.5),
            bottom: Text(size: 22, weight: 600, color: .text))),
        lines: Lines(size: 15, weight: 400, color: .mutedText, gap: 2),
        inlineImage: InlineImage(size: 16, cornerRadius: 4),
        chip: Chip(variant: "tinted", cornerRadius: 999, borderWidth: 1, size: 12, weight: 600,
                   paddingHorizontal: 8, paddingVertical: 2, iconSize: 14, color: .primary)
    )

    /// Edge-to-edge rows with separators: the card is the rows' own background.
    public static let plain = CmsListStyle(
        basedOn: .plain,
        card: Card(cornerRadius: 0, fill: .paper, border: Border(color: .divider, width: 0),
                   shadow: Shadow(color: .text, radius: 0, offsetY: 0, opacity: 0),
                   gap: 0, pageBackground: .paper),
        row: system.row,
        picture: system.picture,
        title: system.title,
        subtitle: system.subtitle,
        trailing: system.trailing,
        leading: system.leading,
        lines: system.lines,
        inlineImage: system.inlineImage,
        chip: system.chip
    )

    /// Each row its own rounded card, with a soft shadow.
    public static let cards = CmsListStyle(
        basedOn: .cards,
        card: Card(cornerRadius: 12, fill: .paper, border: Border(color: .divider, width: 0),
                   shadow: Shadow(color: .text, radius: 8, offsetY: 2, opacity: 0.08),
                   gap: 12, pageBackground: .background),
        row: Row(minHeight: 64, paddingVertical: 14, paddingHorizontal: 16, separators: false, chevron: true),
        picture: Picture(size: 24, badge: .roundedSquare, badgeSize: 40, badgeTint: .tint),
        title: Text(size: 17, weight: 600, color: .text),
        subtitle: Text(size: 14, color: .mutedText),
        trailing: Text(size: 15, weight: 600, color: .text, align: "spread"),
        leading: Leading(width: 48, align: "center", date: DateBlock(
            top: DateTop(size: 12, weight: 600, color: .mutedText, uppercase: true, letterSpacing: 0.5),
            bottom: Text(size: 24, weight: 700, color: .text))),
        lines: Lines(size: 14, weight: 400, color: .mutedText, gap: 2),
        inlineImage: InlineImage(size: 18, cornerRadius: 4),
        chip: Chip(variant: "outlined", cornerRadius: 999, borderWidth: 1, size: 12, weight: 600,
                   paddingHorizontal: 8, paddingVertical: 3, iconSize: 14, color: .primary)
    )
}

// MARK: - Which style a list uses

extension CmsPortalThemeConfig {
    /// The name a list's style resolves to: the block's own `listStyle`, else
    /// the theme's `defaultListStyle`, else `system`. A name that is not a
    /// built-in or one of the site's styles is skipped (check_site reports it
    /// as `list-style-unknown`).
    public func listStyleName(block: String?) -> String {
        for candidate in [block, defaultListStyle] {
            guard let name = candidate?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { continue }
            if CmsListStyle.builtIns[name] != nil || siteListStyle(name) != nil { return name }
        }
        return CmsListLayout.system.rawValue
    }

    /// One of the site's own styles. A key that names a built-in is ignored:
    /// a site can't redefine `system`, `plain` or `cards`.
    func siteListStyle(_ name: String) -> CmsListStyle? {
        guard CmsListStyle.builtIns[name] == nil else { return nil }
        return listStyles?[name]
    }

    /// The style a list draws with, every setting filled. `explicit` keeps
    /// what the site itself set, so a block can tell "the site chose this"
    /// from "the built-in's value".
    public func listStyle(block: String?) -> (name: String, style: CmsListStyle, explicit: CmsListStyle) {
        let name = listStyleName(block: block)
        if let builtIn = CmsListStyle.builtIns[name] { return (name, builtIn, CmsListStyle()) }
        let own = siteListStyle(name) ?? CmsListStyle()
        let base = CmsListStyle.builtIns[(own.basedOn ?? .system).rawValue] ?? .system
        var explicit = own
        explicit.basedOn = nil
        return (name, own.layered(over: base), explicit)
    }
}

extension Optional where Wrapped == CmsPortalThemeConfig {
    /// A site with no theme resolves every list to `system`.
    func listStyle(block: String?) -> (name: String, style: CmsListStyle, explicit: CmsListStyle) {
        (self ?? CmsPortalThemeConfig()).listStyle(block: block)
    }
}

// MARK: - The resolved style, with colours

/// A list style ready to draw: every number filled and every colour read
/// from the site's palette (the dark one when dark).
public struct CmsResolvedListStyle {
    public let name: String
    public let layout: CmsListLayout
    /// The full style (built-in values filled in).
    public let style: CmsListStyle
    /// Only what the site itself set on a style of its own.
    public let explicit: CmsListStyle
    let theme: CmsPortalTheme

    /// The built-in `system` with nothing set: blocks that predate list
    /// styles keep their own look exactly in this case.
    public var isBareSystem: Bool { name == CmsListLayout.system.rawValue }

    public init(config: CmsPortalThemeConfig?, block: String?, dark: Bool) {
        let theme = CmsPortalTheme(config: config, effectiveDark: dark)
        self.init(config: config, block: block, theme: theme)
    }

    /// A style built elsewhere (a card style's lines and chip), drawn as is.
    init(style: CmsListStyle, theme: CmsPortalTheme, name: String = "card") {
        self.name = name
        self.style = style
        explicit = style
        layout = style.basedOn ?? .cards
        self.theme = theme
    }

    init(config: CmsPortalThemeConfig?, block: String?, theme: CmsPortalTheme) {
        let resolved = config.listStyle(block: block)
        name = resolved.name
        style = resolved.style
        explicit = resolved.explicit
        layout = resolved.style.basedOn ?? .system
        self.theme = theme
    }

    public func color(_ role: CmsPaletteRole?) -> Color? { role.map(theme.color(role:)) }
    func rgba(_ role: CmsPaletteRole) -> CmsRGBA { theme.rgba(role: role) }

    // Card
    public var cornerRadius: CGFloat { CGFloat(style.card?.cornerRadius ?? 0) }
    public var fill: Color { color(style.card?.fill) ?? theme.paper }
    public var borderColor: Color { color(style.card?.border?.color) ?? theme.divider }
    public var borderWidth: CGFloat { CGFloat(style.card?.border?.width ?? 0) }
    public var shadowColor: Color {
        let s = style.card?.shadow
        return rgba(s?.color ?? .text).withAlpha(s?.opacity ?? 0).color
    }
    public var shadowRadius: CGFloat { CGFloat(style.card?.shadow?.radius ?? 0) }
    public var shadowOffsetY: CGFloat { CGFloat(style.card?.shadow?.offsetY ?? 0) }
    public var hasShadow: Bool { (style.card?.shadow?.opacity ?? 0) > 0 && shadowRadius + abs(shadowOffsetY) > 0 }
    public var gap: CGFloat { CGFloat(style.card?.gap ?? 0) }
    public var pageBackground: Color { color(style.card?.pageBackground) ?? theme.background }
    // Row
    public var minHeight: CGFloat { CGFloat(style.row?.minHeight ?? 44) }
    public var paddingVertical: CGFloat { CGFloat(style.row?.paddingVertical ?? 11) }
    public var paddingHorizontal: CGFloat { CGFloat(style.row?.paddingHorizontal ?? 16) }
    public var separators: Bool { style.row?.separators ?? true }
    public var chevron: Bool { style.row?.chevron ?? true }
    // Picture
    public var pictureSize: CGFloat { CGFloat(style.picture?.size ?? 28) }
    public var badge: CmsListStyle.Badge { style.picture?.badge ?? .none }
    public var badgeSize: CGFloat { CGFloat(style.picture?.badgeSize ?? 36) }
    public var badgeTint: Color { color(style.picture?.badgeTint) ?? theme.primary }
    // Text
    public var titleFont: Font { font(style.title, fallback: 17) }
    public var titleColor: Color { color(style.title?.color) ?? theme.textPrimary }
    public var subtitleFont: Font { font(style.subtitle, fallback: 15) }
    public var subtitleColor: Color { color(style.subtitle?.color) ?? theme.textSecondary }
    public var trailingFont: Font { font(style.trailing, fallback: 17) }
    public var trailingColor: Color { color(style.trailing?.color) ?? theme.textSecondary }
    public var separatorColor: Color { theme.divider }

    /// The site's font family (`typography.fontFamily`) when installed, else nil.
    public var fontFamily: String? { theme.fontFamily }

    /// A font in the site's family at `size` and `weight`, or the system font.
    public func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        theme.font(size: size, weight: weight)
    }

    func font(_ text: CmsListStyle.Text?, fallback: Double) -> Font {
        theme.font(size: CGFloat(text?.size ?? fallback), weight: CmsTypography.weight(css: text?.weight ?? 400))
    }
}
