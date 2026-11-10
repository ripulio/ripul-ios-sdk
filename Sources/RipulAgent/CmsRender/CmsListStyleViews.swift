import SwiftUI

// MARK: - Drawing a list in a list style (docs/cms-list-styles.md)

extension CmsRuntime {
    /// The list style a block draws with: its own `listStyle`, else the
    /// theme's `defaultListStyle`, else `system`; colours from the site's
    /// palette in the current appearance.
    func listStyle(for block: CmsBlock) -> CmsResolvedListStyle {
        CmsResolvedListStyle(config: themeConfig, block: block.props.string("listStyle"), theme: theme)
    }
}

/// A leading picture: an SF Symbol, or an image address.
public enum CmsListPicture: Equatable {
    case symbol(String)
    case url(URL)
}

/// Rows laid out in a list style. `system` is one rounded group with
/// separators, `plain` edge-to-edge rows with separators, `cards` a card per
/// row with the style's gap and shadow. Each row draws its own content (pad it
/// with `cmsListRowPadding`).
struct CmsStyledRows<Item, Row: View>: View {
    let style: CmsResolvedListStyle
    let items: [Item]
    /// Where separators start, from the row's leading edge.
    var separatorInset: CGFloat? = nil
    /// A row's swipe actions (CmsSwipe): with any, the rows are a real `List`
    /// (the shared `GlassSwipeList`), so they take the system's swipe actions.
    var swipe: ((Item) -> GlassSwipeSet)? = nil
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        if let swipe, items.contains(where: { !swipe($0).isEmpty }) {
            swipingRows(swipe)
        } else {
            stackedRows
        }
    }

    /// The same three layouts as list rows: a card per row, `gap` apart, or
    /// one group (system) or edge-to-edge rows (plain), separated. Each row
    /// is opaque, so it covers the swipe buttons until it slides.
    @ViewBuilder
    private func swipingRows(_ swipe: @escaping (Item) -> GlassSwipeSet) -> some View {
        switch style.layout {
        case .cards:
            GlassSwipeList(items.indices, id: \.self, spacing: style.gap, swipe: { swipe(items[$0]) }) { index in
                row(items[index])
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cmsListCard(style)
            }
        case .system, .plain:
            let list = GlassSwipeList(items.indices, id: \.self, spacing: 0, separators: style.separators,
                                      separatorColor: style.separatorColor,
                                      separatorInset: separatorInset ?? style.paddingHorizontal,
                                      swipe: { swipe(items[$0]) }) { index in
                row(items[index])
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(style.fill)
            }
            if style.layout == .system { list.cmsListCard(style) } else { list.background(style.fill) }
        }
    }

    @ViewBuilder
    private var stackedRows: some View {
        switch style.layout {
        case .cards:
            VStack(spacing: style.gap) {
                ForEach(items.indices, id: \.self) { index in
                    row(items[index])
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cmsListCard(style)
                }
            }
        case .system:
            rows
                .cmsListCard(style)
        case .plain:
            rows
                .background(style.fill)
        }
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { index in
                row(items[index])
                    .frame(maxWidth: .infinity, alignment: .leading)
                if style.separators && index < items.count - 1 {
                    Rectangle()
                        .fill(style.separatorColor)
                        .frame(height: 1 / CmsListMetrics.displayScale)
                        .padding(.leading, separatorInset ?? style.paddingHorizontal)
                }
            }
        }
    }
}

enum CmsListMetrics {
    /// One physical pixel, the hairline iOS draws its separators with.
    static var displayScale: CGFloat {
        #if os(iOS)
        UITraitCollection.current.displayScale > 0 ? UITraitCollection.current.displayScale : 2
        #else
        2
        #endif
    }
}

extension View {
    /// The style's card behind one card or one group: fill, corners, border
    /// and shadow.
    func cmsListCard(_ style: CmsResolvedListStyle) -> some View {
        let shape = RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
        return self
            .background(shape.fill(style.fill))
            .clipShape(shape)
            .overlay {
                if style.borderWidth > 0 { shape.strokeBorder(style.borderColor, lineWidth: style.borderWidth) }
            }
            .shadow(color: style.hasShadow ? style.shadowColor : .clear,
                    radius: style.shadowRadius, y: style.shadowOffsetY)
    }

    /// The style's row padding and minimum height.
    func cmsListRowPadding(_ style: CmsResolvedListStyle) -> some View {
        self
            .padding(.horizontal, style.paddingHorizontal)
            .padding(.vertical, style.paddingVertical)
            .frame(minHeight: style.minHeight)
            .contentShape(Rectangle())
    }
}

/// One row's content in a list style: picture (in the style's badge), title,
/// subtitle, trailing text, an accessory (a pill) and the chevron.
struct CmsListRowContent<Accessory: View>: View {
    let style: CmsResolvedListStyle
    let title: String
    var titleColor: Color? = nil
    var subtitle: String? = nil
    var picture: CmsListPicture? = nil
    /// An image chain's candidates: when set, the first that loads takes the
    /// picture slot and `picture` is the fallback (a 404, a failed load).
    var pictureCandidates: [CmsCalendarDecorations.ImageCandidate] = []
    var trailing: String? = nil
    /// Whether the row goes somewhere; the chevron shows when the style has one.
    var navigates: Bool = false
    @ViewBuilder var accessory: () -> Accessory
    @Environment(\.cmsListRowInList) private var inList

    var body: some View {
        HStack(spacing: 12) {
            if !pictureCandidates.isEmpty {
                CmsChainListPicture(style: style, candidates: pictureCandidates, fallback: picture)
            } else if let picture {
                CmsListPictureView(style: style, picture: picture)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(style.titleFont)
                    .foregroundStyle(titleColor ?? style.titleColor)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(style.subtitleFont)
                        .foregroundStyle(style.subtitleColor)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            accessory()
            if let trailing, !trailing.isEmpty {
                Text(trailing)
                    .font(style.trailingFont)
                    .foregroundStyle(style.trailingColor)
                    .lineLimit(1)
            }
            if navigates && style.chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(style.subtitleColor.opacity(0.6))
            }
        }
        .modifier(CmsListRowContentPadding(style: style, inList: inList))
    }
}

/// A row pads itself, except inside a SwiftUI `List`, whose row insets do it.
private struct CmsListRowContentPadding: ViewModifier {
    let style: CmsResolvedListStyle
    let inList: Bool
    func body(content: Content) -> some View {
        if inList { content } else { content.cmsListRowPadding(style) }
    }
}

private struct CmsListRowInListKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True inside `CmsListRow`: the List row carries the padding.
    var cmsListRowInList: Bool {
        get { self[CmsListRowInListKey.self] }
        set { self[CmsListRowInListKey.self] = newValue }
    }
}

extension CmsListRowContent where Accessory == EmptyView {
    init(style: CmsResolvedListStyle, title: String, titleColor: Color? = nil, subtitle: String? = nil,
         picture: CmsListPicture? = nil, trailing: String? = nil, navigates: Bool = false) {
        self.init(style: style, title: title, titleColor: titleColor, subtitle: subtitle, picture: picture,
                  trailing: trailing, navigates: navigates, accessory: { EmptyView() })
    }
}

/// The leading picture: the symbol in the primary colour, on the style's
/// badge (circle or rounded square, filled with the badge tint) when it has one.
struct CmsListPictureView: View {
    let style: CmsResolvedListStyle
    let picture: CmsListPicture
    /// A picture already loaded (an image chain's), drawn as an address's is.
    var loaded: CmsPlatformImage? = nil

    var body: some View {
        let size = style.pictureSize
        let image = Group {
            if let loaded {
                Image(cmsPlatformImage: loaded).resizable().scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            } else {
            switch picture {
            case .symbol(let name):
                Image(systemName: name)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .foregroundStyle(style.color(.primary) ?? .accentColor)
            case .url(let url):
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() }
                    else { style.badgeTint }
                }
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            }
            }
        }
        switch style.badge {
        case .none:
            image
        case .circle:
            image.frame(width: style.badgeSize, height: style.badgeSize)
                .background(Circle().fill(style.badgeTint))
        case .roundedSquare:
            image.frame(width: style.badgeSize, height: style.badgeSize)
                .background(RoundedRectangle(cornerRadius: style.badgeSize * 0.25, style: .continuous)
                    .fill(style.badgeTint))
        }
    }
}

/// A row's picture from an image chain, in the style's picture slot with its
/// badge: the first candidate that loads, through the page's image cache. While
/// it loads it holds the slot, invisibly; when none loads it falls back to the
/// row's own picture (its icon), and with none it takes no space.
struct CmsChainListPicture: View {
    let style: CmsResolvedListStyle
    let candidates: [CmsCalendarDecorations.ImageCandidate]
    let fallback: CmsListPicture?
    @EnvironmentObject private var runtime: CmsRuntime
    @State private var load = CmsPictureLoad.loading

    var body: some View {
        Group {
            switch load {
            case .loaded(let image):
                CmsListPictureView(style: style, picture: fallback ?? .symbol("photo"), loaded: image)
            case .loading:
                let slot = style.badge == .none ? style.pictureSize : style.badgeSize
                Color.clear.frame(width: slot, height: slot)
            case .none:
                if let fallback { CmsListPictureView(style: style, picture: fallback) }
            }
        }
        .task(id: candidates) {
            let image = await CmsMarkerImageCache.forPage(runtime)
                .resolve(candidates, size: CmsCalendarDecorations.imageRequestSize(Double(style.pictureSize)))
            load = CmsPictureLoad(image)
        }
    }
}

/// A section heading over a styled list: iOS's grouped header.
struct CmsListSectionHeader: View {
    let style: CmsResolvedListStyle
    let title: String

    var body: some View {
        Text(title)
            .font(style.font(size: 13))
            .textCase(.uppercase)
            .foregroundStyle(style.subtitleColor)
            .padding(.horizontal, style.paddingHorizontal)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }
}
