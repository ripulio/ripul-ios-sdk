import SwiftUI

// MARK: - A button that opens a glass menu (docs/plans/cms-home-records-levers.md, addendum 3)
//
// `menu` on the action button block: the button opens a column of rows that
// grow out of it, each a Liquid Glass element on iOS 26 (a material panel
// before it). A row runs an action in the button's own fields, or is a
// placeholder that says it is coming soon. `primary` keeps the button's own
// action as the bottom row. Nothing here knows WAC: WAC's Records + is one
// configuration of it.

/// The action button's `menu`, decoded leniently: a row without a label is
/// left out, an unknown fill is unset.
struct CmsButtonMenu: Equatable {
    struct Item: Equatable, Identifiable {
        var id: Int
        var label: String
        var subtitle: String?
        var symbol: String?
        var image: String?
        var fill: CmsPaletteRole?
        var placeholder: Bool
        /// The row's own action, in the button's fields (`actionType`,
        /// `mutationSlug`, `targetPageSlug`, `url` …); nil for a placeholder.
        var action: [String: CmsJSON]?

        /// "<label> is coming soon", for a placeholder.
        var comingSoon: String { "\(label) is coming soon" }

        /// The name VoiceOver reads: the label and the subtitle.
        var accessibilityName: String {
            [label, subtitle].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        }
    }

    struct Primary: Equatable {
        var label: String?
        var subtitle: String?
        /// The main row's fill, a palette role; unset is `primary`.
        var fill: CmsPaletteRole?
    }

    /// `panel` (the default): one glass panel of solid rows, WAC's shipped
    /// menu. `rows`: each row its own glass, morphing out of the button.
    var style: String
    /// The symbols' colour, a palette role; unset is `primary`.
    var tint: CmsPaletteRole?
    /// `square` (the default): a 32 tile, corners 9, the tint at 12%.
    /// `circle`: a 40 circle.
    var tile: String
    var items: [Item]
    var primary: Primary?

    init?(_ json: CmsJSON?) {
        guard case .object(let menu)? = json else { return nil }
        var items: [Item] = []
        if case .array(let raw)? = menu["items"] {
            for entry in raw {
                guard case .object(let row) = entry,
                      let label = row.string("label")?.trimmingCharacters(in: .whitespaces), !label.isEmpty else { continue }
                let media = row.object("media")
                let placeholder = row.bool("placeholder") ?? false
                items.append(Item(
                    id: items.count,
                    label: label,
                    subtitle: row.string("subtitle").flatMap { $0.isEmpty ? nil : $0 },
                    symbol: media?.string("symbol").flatMap { $0.isEmpty ? nil : $0 },
                    image: media?.string("image").flatMap { $0.isEmpty ? nil : $0 },
                    fill: row.string("fill").flatMap(CmsPaletteRole.init(rawValue:)),
                    placeholder: placeholder,
                    action: placeholder ? nil : Self.action(row)))
            }
        }
        self.items = items
        style = menu.string("style") == "rows" ? "rows" : "panel"
        tint = menu.string("tint").flatMap(CmsPaletteRole.init(rawValue:))
        tile = menu.string("tile") == "circle" ? "circle" : "square"
        if case .object(let p)? = menu["primary"] {
            primary = Primary(label: p.string("label").flatMap { $0.isEmpty ? nil : $0 },
                              subtitle: p.string("subtitle").flatMap { $0.isEmpty ? nil : $0 },
                              fill: p.string("fill").flatMap(CmsPaletteRole.init(rawValue:)))
        } else {
            primary = nil
        }
        guard !items.isEmpty || primary != nil else { return nil }
    }

    /// A row's action in the button's own field names. `pageSlug` is read
    /// as the button's `targetPageSlug` (the addendum's shorthand).
    static func action(_ row: [String: CmsJSON]) -> [String: CmsJSON] {
        var out = row
        for key in ["label", "subtitle", "media", "fill", "placeholder"] { out[key] = nil }
        if out["targetPageSlug"] == nil, let page = row["pageSlug"] { out["targetPageSlug"] = page }
        return out
    }

    /// A row's symbol: a nav icon key (what the web reads too, so use keys
    /// for a site on both), else an SF Symbol name (iPhone only).
    static func symbolName(_ name: String?) -> String? {
        guard let name, !name.isEmpty else { return nil }
        return CmsNavIcon.symbol(for: name) ?? name
    }

    // MARK: The panel's measures (WAC's AddRecordMenuPopover)

    static let panelRowWidth: CGFloat = 250
    static let panelPadding: CGFloat = 14
    static let panelCorner: CGFloat = 24
    static let panelRowHeight: CGFloat = 50
    static let panelRowGap: CGFloat = 10
    static let panelPrimaryHeight: CGFloat = 62
    static let panelPrimaryGap: CGFloat = 16
    static var panelWidth: CGFloat { panelRowWidth + panelPadding * 2 }

    /// The rows' height inside the panel: rows 10 apart, then the main row
    /// 16 below them.
    var panelContentHeight: CGFloat {
        let rows = CGFloat(items.count) * Self.panelRowHeight + CGFloat(max(0, items.count - 1)) * Self.panelRowGap
        guard primary != nil else { return rows }
        return rows + (items.isEmpty ? 0 : Self.panelPrimaryGap) + Self.panelPrimaryHeight
    }

    var panelHeight: CGFloat { panelContentHeight + Self.panelPadding * 2 }

    /// A floating button's open panel: its trailing edge on the button's,
    /// its foot 14 above it, kept 16 from the screen's sides and below the
    /// top inset.
    func panelFrame(button: CGRect, screen: CGSize, topInset: CGFloat) -> CGRect {
        let w = Self.panelWidth, h = panelHeight
        let x = min(max(16, button.maxX - w), screen.width - 16 - w)
        let y = max(topInset + 8, button.minY - 14 - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Where the panel starts and ends its morph: a circle tucked inside the
    /// button.
    static func collapsedFrame(button: CGRect) -> CGRect {
        let inset = max(8, button.width * 0.22)
        return button.insetBy(dx: inset, dy: inset)
    }

    /// Where an inline button's menu goes: below the button when it fits
    /// between the button and the bottom of the space, else above it.
    static func opensBelow(anchor: CGRect, menuHeight: CGFloat, space: CGRect, gap: CGFloat = 8) -> Bool {
        anchor.maxY + gap + menuHeight <= space.maxY || anchor.minY - gap - menuHeight < space.minY
    }
}

/// The open menu, drawn over the whole screen in a clear full-screen cover:
/// a lightly dimmed backdrop, then the rows growing out of the button at
/// `anchor` (window points).
struct CmsButtonMenuOverlay: View {
    let menu: CmsButtonMenu
    let anchor: CGRect
    let floating: Bool
    /// The button's own icon, for the source a floating menu grows out of.
    let icon: String
    let primaryLabel: String
    let run: (CmsButtonMenu.Item?) -> Void
    let close: () -> Void
    @EnvironmentObject private var runtime: CmsRuntime
    @State private var expanded = false
    @Namespace private var glass

    private let rowWidth: CGFloat = 280
    private let rowHeight: CGFloat = 56

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // theme-exempt: a scrim, black in light and dark alike (WAC's 16%, 12% for rows).
                Color.black.opacity(expanded ? (panelStyle ? 0.16 : 0.12) : 0)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { dismiss(then: nil) }
                    .accessibilityHidden(true)
                if panelStyle {
                    panel(space: geo.size)
                    if floating { closeButton }
                } else if floating {
                    floatingColumn
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(.trailing, max(0, geo.size.width - anchor.maxX))
                        .padding(.bottom, max(0, geo.size.height - anchor.maxY))
                } else {
                    inlinePanel(space: CGRect(origin: .zero, size: geo.size))
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityAction(.escape) { dismiss(then: nil) }
        .onAppear {
            // The panel lands with WAC's slight bounce (damping 0.74); rows morph bouncier.
            withAnimation(panelStyle ? .spring(duration: 0.5, bounce: 0.26) : .bouncy(duration: 0.5, extraBounce: 0.16)) {
                expanded = true
            }
        }
    }

    private var panelStyle: Bool { menu.style == "panel" }

    /// Every symbol's colour: `menu.tint`, else `primary`.
    private var tint: CmsRGBA { runtime.theme.rgba(role: menu.tint ?? .primary) }

    private var topInset: CGFloat {
        #if os(iOS)
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.safeAreaInsets.top ?? 0
        #else
        0
        #endif
    }

    // MARK: Panel: one glass panel of solid rows (the default, WAC's shipped menu)

    /// The panel morphs between a circle tucked in the button and its open
    /// frame (an inline menu grows from the button itself), its corners
    /// following; the rows inside keep their size, scaled and faded in.
    private func panel(space: CGSize) -> some View {
        let height = menu.panelHeight
        let target: CGRect
        let start: CGRect
        if floating {
            target = menu.panelFrame(button: anchor, screen: space, topInset: topInset)
            start = CmsButtonMenu.collapsedFrame(button: anchor)
        } else {
            let below = CmsButtonMenu.opensBelow(anchor: anchor, menuHeight: height,
                                                 space: CGRect(origin: .zero, size: space))
            let x = min(max(16, anchor.minX), space.width - 16 - CmsButtonMenu.panelWidth)
            target = CGRect(x: x, y: below ? anchor.maxY + 8 : anchor.minY - 8 - height,
                            width: CmsButtonMenu.panelWidth, height: height)
            start = anchor
        }
        let frame = expanded ? target : start
        let radius = expanded ? CmsButtonMenu.panelCorner : min(start.width, start.height) / 2
        return panelRows
            .frame(width: CmsButtonMenu.panelRowWidth, height: menu.panelContentHeight)
            .scaleEffect(x: expanded ? 1 : max(0.08, start.width / target.width),
                         y: expanded ? 1 : max(0.08, start.height / target.height))
            .opacity(expanded ? 1 : 0)
            .animation(expanded ? .easeOut(duration: 0.3).delay(0.03) : .smooth(duration: 0.2), value: expanded)
            .frame(width: frame.width, height: frame.height)
            .modifier(CmsMorphGlass(radius: radius))
            .position(x: frame.midX, y: frame.midY)
    }

    private var panelRows: some View {
        VStack(spacing: CmsButtonMenu.panelRowGap) {
            ForEach(menu.items) { panelRow($0) }
            if let primary = menu.primary {
                primaryRow(primary)
                    .padding(.top, menu.items.isEmpty ? 0 : CmsButtonMenu.panelPrimaryGap - CmsButtonMenu.panelRowGap)
            }
        }
    }

    /// A solid `paper` card: the title (and subtitle) leading, the icon's
    /// tile trailing.
    private func panelRow(_ item: CmsButtonMenu.Item) -> some View {
        let card = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return Button { dismiss(then: item) } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.label)
                        .font(runtime.theme.font(size: 16, weight: .semibold))
                        .foregroundStyle(runtime.theme.textPrimary)
                    if let subtitle = item.subtitle {
                        Text(subtitle)
                            .font(runtime.theme.font(size: 13, weight: .regular))
                            .foregroundStyle(runtime.theme.textSecondary)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                iconTile(item)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: CmsButtonMenu.panelRowHeight, maxHeight: CmsButtonMenu.panelRowHeight)
            .background(card.fill(runtime.theme.color(role: .paper))
                .shadow(color: runtime.theme.rgba(role: .text).withAlpha(0.14).color, radius: 8, y: 3))
            .contentShape(card)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.accessibilityName)
    }

    /// The main action: a capsule in `primary.fill` (unset `primary`), the
    /// words and the button's icon in `paper`.
    private func primaryRow(_ primary: CmsButtonMenu.Primary) -> some View {
        let paper = runtime.theme.rgba(role: .paper)
        let label = primary.label ?? primaryLabel
        return Button { dismiss(then: nil, primary: true) } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(runtime.theme.font(size: 17, weight: .bold))
                    if let subtitle = primary.subtitle {
                        Text(subtitle)
                            .font(runtime.theme.font(size: 13, weight: .regular))
                    }
                }
                .lineLimit(1)
                .foregroundStyle(paper.color)
                Spacer(minLength: 8)
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(paper.color)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(paper.withAlpha(0.22).color))
            }
            .padding(.leading, 20)
            .padding(.trailing, 15)
            .frame(maxWidth: .infinity, minHeight: CmsButtonMenu.panelPrimaryHeight, maxHeight: CmsButtonMenu.panelPrimaryHeight)
            .background(Capsule().fill(runtime.theme.color(role: primary.fill ?? .primary)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel([label, primary.subtitle].compactMap { $0 }.joined(separator: ", "))
    }

    /// A floating button while its menu is open: drawn where it is, in its
    /// own colours, its + turned to a close mark (another icon swaps to ×).
    /// A tap on it closes the menu.
    private var closeButton: some View {
        let plus = icon == "plus"
        return Button { dismiss(then: nil) } label: {
            Image(systemName: plus ? "plus" : (expanded ? "xmark" : icon))
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(runtime.theme.color(role: .paper))
                .rotationEffect(.degrees(plus && expanded ? 45 : 0))
                .frame(width: anchor.width, height: anchor.height)
                .background(Circle().fill(runtime.theme.accent))
                .shadow(color: runtime.theme.rgba(role: .text).withAlpha(0.2).color, radius: 8, y: 3)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .position(x: anchor.midX, y: anchor.midY)
        .accessibilityLabel("Close menu")
    }

    /// A row's icon. `square`: a 32 tile, corners 9, the row's `fill` or the
    /// tint at 12%, its symbol 18 in the tint. `circle`: the 40 circle.
    /// An image draws as it is, at the icon's size.
    @ViewBuilder
    private func iconTile(_ item: CmsButtonMenu.Item) -> some View {
        if menu.tile == "circle" {
            mediaCircle(item)
        } else {
            let fill = item.fill.map { runtime.theme.rgba(role: $0) } ?? tint.withAlpha(0.12)
            let ink = item.fill == nil ? tint.color : fill.contrastText.color
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(fill.color)
                .frame(width: 32, height: 32)
                .overlay { iconContent(item, ink: ink, size: 18) }
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func iconContent(_ item: CmsButtonMenu.Item, ink: Color, size: CGFloat) -> some View {
        if let address = item.image, let url = URL(string: address) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Color.clear
            }
            .frame(width: size, height: size)
        } else if let symbol = CmsButtonMenu.symbolName(item.symbol) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.9, weight: .semibold))
                .foregroundStyle(ink)
        }
    }

    /// Closes with the system's smooth curve, then runs the row's action
    /// (nil: only close).
    private func dismiss(then item: CmsButtonMenu.Item?, primary: Bool = false) {
        withAnimation(.smooth(duration: 0.28)) { expanded = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            close()
            if item != nil || primary { run(item) }
        }
    }

    // MARK: Floating: a column rising from the button
    //
    // Regular glass, not clear: a menu's words must read over anything the
    // page has under it (a brand-coloured header, a photo).

    @ViewBuilder
    private var floatingColumn: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            GlassEffectContainer(spacing: 22) {
                VStack(alignment: .trailing, spacing: 6) {
                    if expanded {
                        ForEach(menu.items) { item in
                            rowButton(item)
                                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .glassEffectID("row\(item.id)", in: glass)
                        }
                    }
                    sourceRow
                }
            }
        } else {
            VStack(alignment: .trailing, spacing: 6) {
                if expanded {
                    VStack(spacing: 0) {
                        ForEach(menu.items) { item in
                            rowButton(item)
                            if item.id != menu.items.last?.id { Divider().padding(.leading, 16) }
                        }
                    }
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .transition(.scale(scale: 0.2, anchor: .bottomTrailing).combined(with: .opacity))
                }
                sourceRow
            }
        }
    }

    /// The button itself, where it was: with `primary`, it grows into the
    /// bottom row (its label beside it) and runs the button's action;
    /// without, its icon turns to a close mark and it closes the menu.
    @ViewBuilder
    private var sourceRow: some View {
        let source = sourceCircle
        if let primary = menu.primary {
            Button { dismiss(then: nil, primary: true) } label: {
                HStack(spacing: 12) {
                    if expanded {
                        texts(primary.label ?? primaryLabel, primary.subtitle)
                            .transition(.opacity)
                    }
                    source
                }
                .padding(.leading, expanded ? 16 : 0)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(CmsMenuSourceGlass(expanded: expanded, namespace: glass))
            .accessibilityLabel([primary.label ?? primaryLabel, primary.subtitle].compactMap { $0 }.joined(separator: ", "))
        } else {
            Button { dismiss(then: nil) } label: { source }
                .buttonStyle(.plain)
                .modifier(CmsMenuSourceGlass(expanded: false, namespace: glass))
                .accessibilityLabel("Close menu")
        }
    }

    private var sourceCircle: some View {
        Image(systemName: menu.primary == nil && expanded ? "xmark" : icon)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(runtime.theme.color(role: .paper))
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 56, height: 56)
            .background(Circle().fill(runtime.theme.accent))
    }

    // MARK: Inline: a popover below the button, or above it

    private func inlinePanel(space: CGRect) -> some View {
        let height = CGFloat(menu.items.count + (menu.primary == nil ? 0 : 1)) * rowHeight
        let below = CmsButtonMenu.opensBelow(anchor: anchor, menuHeight: height, space: space)
        let x = min(max(anchor.minX, 16), max(16, space.width - rowWidth - 16))
        let y = below ? anchor.maxY + 8 : anchor.minY - 8 - height
        return Group {
            if expanded {
                inlineRows
                    .frame(width: rowWidth)
                    .modifier(CmsMenuPanelGlass())
                    .transition(.scale(scale: 0.6, anchor: below ? .topLeading : .bottomLeading).combined(with: .opacity))
            }
        }
        .offset(x: x, y: max(space.minY + 8, y))
    }

    private var inlineRows: some View {
        VStack(spacing: 0) {
            ForEach(menu.items) { item in
                rowButton(item)
                if item.id != menu.items.last?.id || menu.primary != nil { Divider().padding(.leading, 16) }
            }
            if let primary = menu.primary {
                Button { dismiss(then: nil, primary: true) } label: {
                    HStack(spacing: 12) {
                        texts(primary.label ?? primaryLabel, primary.subtitle)
                        Spacer(minLength: 12)
                        Image(systemName: icon)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(runtime.theme.color(role: .paper))
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(runtime.theme.accent))
                    }
                    .padding(.horizontal, 16)
                    .frame(height: rowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel([primary.label ?? primaryLabel, primary.subtitle].compactMap { $0 }.joined(separator: ", "))
            }
        }
    }

    // MARK: A row

    private func rowButton(_ item: CmsButtonMenu.Item) -> some View {
        Button { dismiss(then: item) } label: {
            HStack(spacing: 12) {
                texts(item.label, item.subtitle)
                Spacer(minLength: 12)
                mediaCircle(item)
            }
            .padding(.horizontal, 16)
            .frame(width: rowWidth, height: rowHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.accessibilityName)
    }

    private func texts(_ label: String, _ subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(runtime.theme.font(size: 17, weight: .semibold))
                .foregroundStyle(runtime.theme.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .font(runtime.theme.font(size: 13, weight: .regular))
                    .foregroundStyle(runtime.theme.textSecondary)
            }
        }
        .lineLimit(1)
    }

    /// The row's picture in a 40-point circle (agreed with the web): `fill`
    /// (a palette role), else a faint tint of the text colour; a symbol in
    /// the fill's contrast colour (the primary colour when unset), an image
    /// as it is at about 62% of the circle.
    private func mediaCircle(_ item: CmsButtonMenu.Item) -> some View {
        let fill = item.fill.map { runtime.theme.rgba(role: $0) } ?? runtime.theme.rgba(role: .text).withAlpha(0.08)
        let ink = item.fill == nil ? tint.color : fill.contrastText.color
        return Circle()
            .fill(fill.color)
            .frame(width: 40, height: 40)
            .overlay { iconContent(item, ink: ink, size: 22) }
            .accessibilityHidden(true)
    }
}

/// The button's own glass in a floating menu: a circle while closed, the
/// bottom row's capsule while open with `primary`.
private struct CmsMenuSourceGlass: ViewModifier {
    let expanded: Bool
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content
                .glassEffect(.regular, in: Capsule())
                .glassEffectID("source", in: namespace)
        } else {
            content
                .background(expanded ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.clear), in: Capsule())
        }
    }
}

/// The panel's glass, its shape following the morph: Liquid Glass on
/// iOS 26, a material before it.
private struct CmsMorphGlass: ViewModifier {
    let radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if #available(iOS 26.0, macOS 26.0, *) {
            content.clipShape(shape).glassEffect(.regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape).clipShape(shape)
        }
    }
}

/// An inline menu's panel: Liquid Glass on iOS 26, a material before it.
private struct CmsMenuPanelGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}
