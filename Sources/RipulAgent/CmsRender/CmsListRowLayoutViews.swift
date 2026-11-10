import SwiftUI

// MARK: - Drawing a `listRow` (docs/cms-list-styles.md)

/// A font in the site's family at a list style's size and weight, scaled
/// with Dynamic Type relative to `textStyle`: at the default text size it is
/// exactly the style's size.
struct CmsScaledFont: ViewModifier {
    let theme: CmsPortalTheme
    let weight: Font.Weight
    @ScaledMetric private var size: CGFloat

    init(theme: CmsPortalTheme, size: CGFloat, weight: Font.Weight, relativeTo textStyle: Font.TextStyle) {
        self.theme = theme
        self.weight = weight
        _size = ScaledMetric(wrappedValue: size, relativeTo: textStyle)
    }

    func body(content: Content) -> some View {
        content.font(theme.font(size: size, weight: weight))
    }
}

extension CmsResolvedListStyle {
    func scaledFont(_ size: Double?, fallback: Double, weight: Double?, relativeTo textStyle: Font.TextStyle) -> CmsScaledFont {
        CmsScaledFont(theme: theme, size: CGFloat(size ?? fallback),
                      weight: CmsTypography.weight(css: weight ?? 400), relativeTo: textStyle)
    }

    // The row layout's parts, from the style (built-ins fill every one).
    var leadingWidth: CGFloat { CGFloat(style.leading?.width ?? 44) }
    var leadingAlignsTop: Bool { style.leading?.align == "top" }
    var linesGap: CGFloat { CGFloat(style.lines?.gap ?? 2) }
    var inlineImageSize: CGFloat { CGFloat(style.inlineImage?.size ?? 16) }
    var inlineImageRadius: CGFloat { CGFloat(style.inlineImage?.cornerRadius ?? 4) }
    /// `center`, `top` or `spread`.
    var trailingAlign: String { style.trailing?.align ?? "center" }
}

/// One row drawn from a grid's `listRow`: leading date block or picture,
/// title, lines, trailing value and chip, then the chevron when it drills.
/// VoiceOver reads it as one element, in that order.
struct CmsLayoutRowContent<Accessory: View>: View {
    let style: CmsResolvedListStyle
    let layout: CmsListRowLayout
    let row: [String: CmsJSON]
    let column: (String) -> CmsColumnPresentation
    var titleColor: Color? = nil
    var navigates: Bool = false
    /// A row's initial and its disc's colour, drawn in the leading slot when its
    /// leading picture is missing (a Calendar Strip day's details); nil, a
    /// missing picture takes no space.
    var leadingInitial: (([String: CmsJSON]) -> (letter: String, color: Color)?)? = nil
    @ViewBuilder var accessory: () -> Accessory
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The leading width grows with the text, as the date in it does.
    @ScaledMetric(relativeTo: .title2) private var leadingScale: CGFloat = 1

    var body: some View {
        let title = CmsListRowLayout.fill(layout.title.text, row: row, column: column)
        let lines = layout.lines.compactMap { line -> (CmsListRowLayout.Line, String?)? in
            let words = CmsListRowLayout.fill(line.text, row: row, column: column)
            let picture = line.image.map { column($0).pictureCandidates(row) } ?? []
            return words == nil && picture.isEmpty ? nil : (line, words)
        }
        let trailing = layout.trailing.flatMap { CmsListRowLayout.fill($0.text, row: row, column: column) }
        let chip = layout.chip.flatMap { column($0).chip(row) }

        if dynamicTypeSize.isAccessibilitySize {
            // At the largest text sizes the parts stack, as iOS's own rows do,
            // so nothing is cut short: the date on one line, then the title
            // and lines, then the value and chip.
            VStack(alignment: .leading, spacing: style.linesGap + 4) {
                if case .date(let name)? = layout.leading,
                   let parts = CmsListRowLayout.dateParts(column(name).value(row), naiveIsLocal: column(name).naiveIsLocal) {
                    CmsDateBlock(style: style, parts: parts, inline: true)
                }
                if let title {
                    Text(title)
                        .modifier(style.scaledFont(style.style.title?.size, fallback: 17,
                                                   weight: style.style.title?.weight, relativeTo: .body))
                        .foregroundStyle(titleColor ?? style.titleColor)
                }
                ForEach(lines.indices, id: \.self) { i in
                    lineView(lines[i].0, words: lines[i].1)
                }
                HStack(spacing: 8) {
                    if let trailing {
                        Text(trailing)
                            .modifier(style.scaledFont(style.style.trailing?.size, fallback: 17,
                                                       weight: style.style.trailing?.weight, relativeTo: .body))
                            .foregroundStyle(style.trailingColor)
                    }
                    if let chip { CmsChipView(style: style, chip: chip) }
                    Spacer(minLength: 0)
                    accessory()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cmsListRowPadding(style)
            .accessibilityElement(children: .combine)
        } else {
            standard(title: title, lines: lines, trailing: trailing, chip: chip)
        }
    }

    private func standard(title: String?, lines: [(CmsListRowLayout.Line, String?)], trailing: String?,
                          chip: CmsColumnPresentation.Chip?) -> some View {
        HStack(alignment: style.leadingAlignsTop ? .top : .center, spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: style.linesGap) {
                if let title {
                    Text(title)
                        .modifier(style.scaledFont(style.style.title?.size, fallback: 17,
                                                   weight: style.style.title?.weight, relativeTo: .body))
                        .foregroundStyle(titleColor ?? style.titleColor)
                }
                ForEach(lines.indices, id: \.self) { i in
                    lineView(lines[i].0, words: lines[i].1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // The value and chip keep their words, as the web's column never
            // shrinks: the title and lines give way (they wrap, then end in "…").
            trailingColumn(trailing, chip: chip)
                .fixedSize(horizontal: true, vertical: false)
            accessory()
            if navigates && style.chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(style.subtitleColor.opacity(0.6))
                    .accessibilityHidden(true)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .cmsListRowPadding(style)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var leading: some View {
        switch layout.leading {
        case .date(let name)?:
            CmsDateBlock(style: style, parts: CmsListRowLayout.dateParts(column(name).value(row), naiveIsLocal: column(name).naiveIsLocal))
                .frame(width: style.leadingWidth * leadingScale)
        case .image(let name)?:
            CmsColumnPicture(candidates: column(name).pictureCandidates(row),
                             size: style.pictureSize, cornerRadius: style.pictureSize * 0.22,
                             fallback: leadingInitial?(row).map { initialDisc($0.letter, color: $0.color) })
                .frame(width: style.leadingWidth * leadingScale)
        case nil:
            EmptyView()
        }
    }

    /// An initial in the picture's place, as a marker's `initial` fallback: the
    /// letter on the colour, black or white by its luminance.
    private func initialDisc(_ letter: String, color: Color) -> AnyView {
        let size = style.pictureSize
        return AnyView(
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(color)
                .frame(width: size, height: size)
                .overlay {
                    Text(letter)
                        .font(.system(size: max(7, (size * 0.55).rounded()), weight: .semibold))
                        .foregroundColor(CmsDayLook.autoText(on: color))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
                .accessibilityHidden(true)
                .cmsInspectorID("Cms.listRow.initial")
        )
    }

    private func lineView(_ line: CmsListRowLayout.Line, words: String?) -> some View {
        HStack(spacing: 6) {
            // A row with no picture draws none (no empty square), as on the web.
            if let image = line.image, !column(image).pictureCandidates(row).isEmpty {
                CmsColumnPicture(candidates: column(image).pictureCandidates(row),
                                 size: style.inlineImageSize, cornerRadius: style.inlineImageRadius)
                    .accessibilityHidden(true)
            }
            if let words {
                Text(words)
                    .modifier(style.scaledFont(style.style.lines?.size, fallback: 15,
                                               weight: style.style.lines?.weight, relativeTo: .subheadline))
                    .foregroundStyle(style.color(style.style.lines?.color) ?? style.subtitleColor)
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private func trailingColumn(_ value: String?, chip: CmsColumnPresentation.Chip?) -> some View {
        if value != nil || chip != nil {
            let valueText = value.map { words in
                Text(words)
                    .modifier(style.scaledFont(style.style.trailing?.size, fallback: 17,
                                               weight: style.style.trailing?.weight, relativeTo: .body))
                    .foregroundStyle(style.trailingColor)
                    .lineLimit(1)
            }
            let chipView = chip.map { CmsChipView(style: style, chip: $0) }
            switch style.trailingAlign {
            case "spread":
                VStack(alignment: .trailing, spacing: 6) {
                    valueText
                    Spacer(minLength: 0)
                    chipView
                }
                .frame(maxHeight: .infinity)
            case "top":
                VStack(alignment: .trailing, spacing: 6) {
                    valueText
                    chipView
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity)
            default:
                VStack(alignment: .trailing, spacing: 6) {
                    valueText
                    chipView
                }
            }
        }
    }
}

/// The date block: the weekday small over the day of the month large.
struct CmsDateBlock: View {
    let style: CmsResolvedListStyle
    let parts: (weekday: String, day: String)?
    /// Side by side ("SUN 25"), for the stacked row at the largest text sizes.
    var inline = false

    var body: some View {
        let top = style.style.leading?.date?.top
        let bottom = style.style.leading?.date?.bottom
        let layout = inline ? AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 6))
                            : AnyLayout(VStackLayout(spacing: 0))
        layout {
            if let parts {
                Text(top?.uppercase == true ? parts.weekday.uppercased() : parts.weekday)
                    .modifier(style.scaledFont(top?.size, fallback: 12, weight: top?.weight, relativeTo: .caption))
                    .tracking(CGFloat(top?.letterSpacing ?? 0))
                    .foregroundStyle(style.color(top?.color) ?? style.subtitleColor)
                Text(parts.day)
                    .modifier(style.scaledFont(bottom?.size, fallback: 22, weight: bottom?.weight, relativeTo: .title2))
                    .foregroundStyle(style.color(bottom?.color) ?? style.titleColor)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}

/// A column's chip: filled, outlined or tinted, with an optional icon.
/// Colour, first that is set: the matching rule's, the lozenge's, the
/// style's `chip.color`, the palette's primary.
struct CmsChipView: View {
    let style: CmsResolvedListStyle
    let chip: CmsColumnPresentation.Chip

    var body: some View {
        let s = style.style.chip
        let colours = CmsChipView.colours(chip, style: style)
        let radius = CGFloat(s?.cornerRadius ?? 999)
        let shape = RoundedRectangle(cornerRadius: min(radius, 999), style: .continuous)
        HStack(spacing: 4) {
            if let symbol = CmsNavIcon.symbol(for: chip.icon) {
                Image(systemName: symbol)
                    .font(.system(size: CGFloat(s?.iconSize ?? 14), weight: .semibold))
                    .accessibilityHidden(true)
            }
            Text(chip.text)
                .modifier(style.scaledFont(s?.size, fallback: 12, weight: s?.weight, relativeTo: .caption))
                .lineLimit(1)
        }
        .foregroundStyle(colours.text)
        .padding(.horizontal, CGFloat(s?.paddingHorizontal ?? 8))
        .padding(.vertical, CGFloat(s?.paddingVertical ?? 2))
        .background(shape.fill(colours.fill))
        .overlay {
            if let border = colours.border {
                shape.strokeBorder(border, lineWidth: CGFloat(s?.borderWidth ?? 1))
            }
        }
        .cmsInspectorID("Cms.listRow.chip")
    }

    /// The variant: the column's lozenge, else the style's, else filled.
    static func variant(_ chip: CmsColumnPresentation.Chip, style: CmsResolvedListStyle) -> String {
        chip.variant ?? style.style.chip?.variant ?? "filled"
    }

    /// Fill, text and border colours for a chip.
    static func colours(_ chip: CmsColumnPresentation.Chip, style: CmsResolvedListStyle)
        -> (fill: Color, text: Color, border: Color?) {
        let theme = style.theme
        let base = style.color(style.style.chip?.color) ?? theme.primary
        let fg = theme.resolve(chip.fg)
        let bg = theme.resolve(chip.bg)
        switch variant(chip, style: style) {
        case "outlined":
            let c = fg ?? bg ?? base
            return (.clear, c, c)
        case "tinted":
            let c = fg ?? bg ?? base
            return (c.opacity(0.12), c, nil)
        default:
            let fill = bg ?? fg ?? base
            return (fill, (bg != nil ? fg : nil) ?? .white, nil)
        }
    }
}

/// A column's picture: the first of its candidates that loads, through the
/// page's image cache (the calendar's), else an empty rounded square.
struct CmsColumnPicture: View {
    let candidates: [CmsCalendarDecorations.ImageCandidate]
    let size: CGFloat
    let cornerRadius: CGFloat
    /// Drawn instead when there is no picture, so the place is kept; nil, none is.
    var fallback: AnyView? = nil
    /// A glyph: the picture's shape in this colour, fitted whole (an app's own icon).
    var template: Color? = nil
    /// Fitted whole rather than filling the square (an icon with its own colours).
    var fit = false
    @EnvironmentObject private var runtime: CmsRuntime
    @State private var load = CmsPictureLoad.loading

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Group {
            switch load {
            case .loaded(let image):
                if let template {
                    Image(cmsPlatformImage: image).renderingMode(.template).resizable().scaledToFit()
                        .foregroundStyle(template)
                        .frame(width: size, height: size)
                } else if fit {
                    Image(cmsPlatformImage: image).resizable().scaledToFit()
                        .frame(width: size, height: size)
                } else {
                    Image(cmsPlatformImage: image).resizable().scaledToFill()
                        .frame(width: size, height: size)
                        .clipShape(shape)
                }
            case .loading:
                // Holds the place, invisibly: nothing flashes before a picture.
                Color.clear.frame(width: size, height: size)
            case .none:
                // A 404, a failed load or no candidate: the fallback, else no picture and no space.
                if let fallback { fallback } else { EmptyView() }
            }
        }
        .task(id: candidates) {
            guard !candidates.isEmpty else { load = .none; return }
            let image = await CmsMarkerImageCache.forPage(runtime)
                .resolve(candidates, size: CmsCalendarDecorations.imageRequestSize(Double(size)))
            load = CmsPictureLoad(image)
        }
    }
}

/// Where a column's picture is: loading, loaded, or none to draw.
enum CmsPictureLoad {
    case loading
    case loaded(CmsPlatformImage)
    case none

    init(_ image: CmsPlatformImage?) {
        self = image.map(CmsPictureLoad.loaded) ?? .none
    }

    var takesSpace: Bool {
        if case .none = self { return false }
        return true
    }
}

/// A picture field's image from its column's image chain (`image.chain`),
/// filling its frame: the first candidate that loads, else a placeholder.
struct CmsChainImage: View {
    let candidates: [CmsCalendarDecorations.ImageCandidate]
    var fit: String = "cover"
    var requestSize: Int = 240
    @EnvironmentObject private var runtime: CmsRuntime
    @State private var image: CmsPlatformImage?

    var body: some View {
        Group {
            if let image {
                if fit == "contain" {
                    Image(cmsPlatformImage: image).resizable().scaledToFit()
                } else {
                    Image(cmsPlatformImage: image).resizable().scaledToFill()
                }
            } else {
                runtime.theme.surfaceMuted
            }
        }
        .task(id: candidates) {
            guard !candidates.isEmpty else { image = nil; return }
            image = await CmsMarkerImageCache.forPage(runtime).resolve(candidates, size: requestSize)
        }
    }
}
