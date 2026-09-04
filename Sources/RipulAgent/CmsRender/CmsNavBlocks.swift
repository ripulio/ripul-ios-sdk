import SwiftUI

// MARK: - sidebarNav

/// Native twin of `sidebarNav` (SidebarNavBlock.tsx), built as a native iOS
/// sidebar in the WAC `RecordMenu` idiom: a clean row stack over the drawer's
/// Liquid Glass, no separators, and the SELECTED row highlighted by a Liquid
/// Glass lozenge (a capsule behind the row) — not a flat tint or a `List`
/// chrome that fights the glass.
///
/// We mirror the block's SEMANTICS (the shared NavItem tree, active = current
/// page, nested items as an accordion auto-expanded when a descendant is
/// active, actions) but NOT its web presentation: the pill/underline/text
/// variants, icon position, and label typography are web knobs a native
/// sidebar owns instead — only `activeColor` survives, as the selection tint.
/// `mode: drawer` renders this inside the page-level glass drawer. Mutation/
/// export actions have no native machinery yet — those rows render disabled.
struct CmsSidebarNavBlockView: View {
    let block: CmsBlock
    @EnvironmentObject var runtime: CmsRuntime
    @Environment(\.openURL) private var openURL
    @State private var expanded: Set<String> = []
    @State private var seededExpansion = false

    private var items: [CmsNavItem] { CmsNavItem.decodeList(block.props["items"]) }
    /// The author's accent for the active row (selection tint + label). A
    /// native sidebar owns the rest of the presentation, so we deliberately
    /// do NOT reproduce the web variant / typography / background knobs.
    private var activeColor: Color {
        runtime.color(block.props.string("activeColor")) ?? runtime.theme.primary
    }
    /// Native-only override (web "Native App" inspector group): the tint for
    /// the selection lozenge + active row. Blank → falls back to `activeColor`.
    private var activeTint: Color {
        runtime.color(block.props.string("nativeItemTint")) ?? activeColor
    }
    /// Native-only menu row height (web "Native App" group), default 48pt.
    private var itemHeight: CGFloat {
        max(CGFloat(block.props.double("nativeItemHeight") ?? 48), 32)
    }

    var body: some View {
        if (block.props.string("mode") ?? "inline") == "drawer" {
            burgerButton
                // A drawer-mode nav IS the page's side panel — register it
                // for edge swipe (same channel as sidebar-layout columns),
                // so the screen edge tracks it open and the left-edge
                // delegation arbitration applies. The burger stays as the
                // authored visible affordance.
                .onAppear {
                    if drawerEdge == .trailing {
                        runtime.edgeSwipeRightSlot = inlineSlot
                    } else {
                        runtime.edgeSwipeLeftSlot = inlineSlot
                    }
                }
                .onDisappear {
                    if drawerEdge == .trailing, runtime.edgeSwipeRightSlot == inlineSlot {
                        runtime.edgeSwipeRightSlot = nil
                    } else if drawerEdge == .leading, runtime.edgeSwipeLeftSlot == inlineSlot {
                        runtime.edgeSwipeLeftSlot = nil
                    }
                }
        } else {
            navList
        }
    }

    /// This nav rendered inline, as a drawer/edge-swipe slot.
    private var inlineSlot: CmsPageBlocks {
        var props = block.props
        props["mode"] = .string("inline")
        let inline = CmsBlock(
            id: block.id, slug: block.slug, name: block.name,
            hidden: nil, visibleOn: nil, type: "sidebarNav",
            props: props, frame: nil, position: nil, children: nil, bindings: nil
        )
        return .list(items: [inline], frame: nil)
    }

    private var drawerEdge: CmsRuntime.DrawerRequest.Edge {
        (block.props.string("burgerPosition") ?? "top-left") == "top-right" ? .trailing : .leading
    }

    /// Drawer mode: a burger that opens the page-level drawer containing
    /// this nav rendered inline — the web's fixed-burger reading.
    private var burgerButton: some View {
        Button {
            runtime.openDrawer = CmsRuntime.DrawerRequest(edge: drawerEdge, slot: inlineSlot)
        } label: {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 17, weight: .medium))
                .padding(10)
        }
        .buttonStyle(.plain)
    }

    private var navList: some View {
        var rows: [FlatRow] = []
        flatten(items, depth: 0, into: &rows)
        return ScrollView {
            VStack(spacing: 4) {
                ForEach(rows) { row in
                    if row.item.divider {
                        Divider().padding(.horizontal, 16).padding(.vertical, 4)
                    } else {
                        navRow(row)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
        }
        .onAppear { seedExpansion() }
    }

    private struct FlatRow: Identifiable {
        let id: String
        let item: CmsNavItem
        let depth: Int
        let expanded: Bool
    }

    private func key(_ item: CmsNavItem, _ depth: Int) -> String { "\(depth)|\(item.label)" }

    private func isActive(_ item: CmsNavItem) -> Bool {
        item.targetPageSlug != nil && item.targetPageSlug == runtime.currentPageSlug
    }

    private func flatten(_ items: [CmsNavItem], depth: Int, into rows: inout [FlatRow]) {
        for item in items {
            let isOpen = expanded.contains(key(item, depth))
            rows.append(FlatRow(id: key(item, depth), item: item, depth: depth, expanded: isOpen))
            if isOpen { flatten(item.children, depth: depth + 1, into: &rows) }
        }
    }

    /// One WAC-idiom sidebar row: SF Symbol + label, clear background, and a
    /// Liquid Glass lozenge behind it when it's the active page. Parents toggle
    /// their accordion; leaves navigate / run their action.
    private func navRow(_ row: FlatRow) -> some View {
        let item = row.item
        let active = isActive(item)
        let enabled = item.isActionable || !item.children.isEmpty
        return Button {
            if !item.children.isEmpty {
                withAnimation(.snappy) {
                    if row.expanded { expanded.remove(row.id) } else { expanded.insert(row.id) }
                }
            } else {
                item.perform(runtime: runtime, openURL: openURL)
            }
        } label: {
            HStack(spacing: 12) {
                if let symbol = CmsNavIcon.symbol(for: item.icon) {
                    Image(systemName: symbol)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(active ? activeTint : Color.primary.opacity(0.85))
                        .frame(width: 26)
                }
                Text(item.label)
                    .font(.system(size: 16, weight: active ? .semibold : .medium))
                    .foregroundStyle(!enabled ? Color.secondary : active ? activeTint : Color.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if !item.children.isEmpty {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(row.expanded ? 90 : 0))
                }
            }
            .padding(.horizontal, 14)
            .padding(.leading, CGFloat(row.depth) * 16)
            .frame(height: itemHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { selectionLozenge(active: active) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .cmsInspectorID("Cms.sidebarNav.item")
    }

    /// The active row's Liquid Glass lozenge (WAC RecordMenu selection).
    @ViewBuilder
    private func selectionLozenge(active: Bool) -> some View {
        if active {
            Color.clear.modifier(GlassLozengeModifier(tint: activeTint))
        }
    }

    /// Branches holding the active page start expanded, once per mount.
    private func seedExpansion() {
        guard !seededExpansion else { return }
        seededExpansion = true
        func containsActive(_ item: CmsNavItem) -> Bool {
            if let slug = item.targetPageSlug, slug == runtime.currentPageSlug { return true }
            return item.children.contains(where: containsActive)
        }
        func walk(_ items: [CmsNavItem], depth: Int) {
            for item in items where !item.children.isEmpty {
                if item.children.contains(where: containsActive) {
                    expanded.insert(key(item, depth))
                }
                walk(item.children, depth: depth + 1)
            }
        }
        walk(items, depth: 0)
    }
}

// MARK: - topNav

/// Native twin of `topNav` (TopNavBlock.tsx). The bar renders zone groups
/// (item.align over the block alignment default); items with children are
/// native `Menu`s (nested any depth — hover triggers degrade to tap).
/// `collapseOnMobile` respects the author: in a compact width class the
/// whole tree collapses into one burger Menu. Sticky is a page-scroll
/// concern with no native twin yet.
struct CmsTopNavBlockView: View {
    let block: CmsBlock
    @EnvironmentObject var runtime: CmsRuntime
    @Environment(\.openURL) private var openURL
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    private var items: [CmsNavItem] { CmsNavItem.decodeList(block.props["items"]) }
    private var variant: String { block.props.string("itemVariant") ?? "text" }
    private var activeColor: Color {
        runtime.color(block.props.string("activeColor")) ?? runtime.theme.primary
    }

    // ── Selection appearance (navShared.tsx `buildSelectionStyle`) ──────────
    // `lozenge`/`pill`/`outline`/`solid` draw a chip; the fill defaults to the
    // accent at low alpha so a nav on a coloured bar reads without the author
    // choosing one. `text`/`underline` draw no chip.

    private var chipVariant: Bool { ["lozenge", "pill", "outline", "solid"].contains(variant) }

    private var activeFill: Color? {
        if let explicit = runtime.color(block.props.string("activeBackground")) { return explicit }
        switch variant {
        case "lozenge", "pill": return activeColor.opacity(0.18)
        case "solid": return activeColor
        default: return nil
        }
    }

    private var activeTextColor: Color {
        variant == "solid" ? CmsCss.contrastText(on: activeFill ?? activeColor) : activeColor
    }

    private var chipRadius: CGFloat {
        CmsCss.points(block.props.string("activeRadius")) ?? (variant == "pill" ? 999 : 10)
    }

    private var chipPadX: CGFloat { CmsCss.points(block.props.string("activePaddingX")) ?? 12 }
    private var chipPadY: CGFloat { CmsCss.points(block.props.string("activePaddingY")) ?? 6 }
    private var activeBold: Bool { block.props.bool("activeBold") ?? true }

    // ── Logo ───────────────────────────────────────────────────────────────

    private var logoURL: URL? {
        guard let src = block.props.string("logo"), !src.isEmpty else { return nil }
        return URL(string: src)
    }
    private var logoAlign: String { block.props.string("logoAlign") ?? "start" }
    private var logoHeight: CGFloat { CmsCss.points(block.props.string("logoHeight")) ?? 28 }
    private var logoPadX: CGFloat { CmsCss.points(block.props.string("logoPaddingX")) ?? 8 }
    private var logoPadY: CGFloat { CmsCss.points(block.props.string("logoPaddingY")) ?? 0 }

    /// The brand mark, sized by height so the width follows the artwork's own
    /// ratio. Tappable only when the author gave it a destination — the same
    /// nav machinery every other entry uses.
    @ViewBuilder
    private var logoMark: some View {
        if let url = logoURL {
            let target = CmsNavItem(
                label: block.props.string("logoAlt") ?? "",
                icon: nil,
                targetPageSlug: block.props.string("logoTargetPageSlug").flatMap { $0.isEmpty ? nil : $0 },
                targetViewRef: nil,
                url: block.props.string("logoUrl").flatMap { $0.isEmpty ? nil : $0 },
                actionType: "link",
                targetGridId: nil,
                targetViewId: nil,
                children: [],
                align: nil,
                divider: false
            )
            let mark = AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFit()
                default: Color.clear
                }
            }
            .frame(height: logoHeight)
            .padding(.horizontal, logoPadX)
            .padding(.vertical, logoPadY)
            .accessibilityLabel(block.props.string("logoAlt") ?? "")

            if target.isActionable {
                Button { target.perform(runtime: runtime, openURL: openURL) } label: { mark }
                    .buttonStyle(.plain)
            } else {
                mark
            }
        }
    }
    private var labelFont: Font {
        let typo = block.props.object("labelTypography")
        return .system(size: CmsTypography.size(typo) ?? 14,
                       weight: CmsTypography.weight(typo) ?? .regular)
    }
    private var labelColor: Color {
        runtime.color(block.props.object("labelTypography")?.string("color")) ?? .primary
    }

    private var collapsed: Bool {
        guard block.props.bool("collapseOnMobile") ?? true else { return false }
        #if os(iOS)
        return sizeClass == .compact
        #else
        return false
        #endif
    }

    var body: some View {
        HStack(spacing: CmsCss.points(block.props.string("itemGap")) ?? 8) {
            if collapsed {
                Menu {
                    menuEntries(items)
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(labelColor)
                        .padding(8)
                }
                logoMark
                Spacer(minLength: 0)
            } else {
                barZones
            }
        }
        .padding(.horizontal, CmsCss.points(block.props.string("paddingX")) ?? 12)
        .frame(minHeight: CmsCss.points(block.props.string("height")) ?? 44)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(runtime.color(block.props.string("background")) ?? Color.clear)
        .overlay(alignment: .bottom) {
            if block.props.bool("borderBottom") ?? false {
                Rectangle()
                    .fill(runtime.color(block.props.string("borderColor")) ?? runtime.theme.divider)
                    .frame(height: 1)
            }
        }
    }

    // Zone groups: item.align overrides the block's default alignment zone.
    private var barZones: some View {
        let defaultZone: String = {
            switch block.props.string("alignment") ?? "left" {
            case "center": return "center"
            case "right": return "end"
            default: return "start"
            }
        }()
        let zone = { (item: CmsNavItem) -> String in item.align ?? defaultZone }
        let start = items.filter { zone($0) == "start" }
        let center = items.filter { zone($0) == "center" }
        let end = items.filter { zone($0) == "end" }
        return HStack(spacing: CmsCss.points(block.props.string("itemGap")) ?? 8) {
            if logoAlign == "start" { logoMark }
            ForEach(start) { barItem($0) }
            Spacer(minLength: 8)
            if logoAlign == "center" { logoMark }
            ForEach(center) { barItem($0) }
            Spacer(minLength: 8)
            ForEach(end) { barItem($0) }
            if logoAlign == "end" { logoMark }
        }
    }

    @ViewBuilder
    private func barItem(_ item: CmsNavItem) -> some View {
        if item.divider {
            Divider().frame(height: 20)
        }
        if !item.children.isEmpty {
            Menu {
                menuEntries(item.children)
            } label: {
                barLabel(item, chevron: true)
            }
        } else {
            Button {
                item.perform(runtime: runtime, openURL: openURL)
            } label: {
                barLabel(item, chevron: false)
            }
            .buttonStyle(.plain)
            .disabled(!item.isActionable)
        }
    }

    private func barLabel(_ item: CmsNavItem, chevron: Bool) -> some View {
        let active = item.targetPageSlug != nil && item.targetPageSlug == runtime.currentPageSlug
        return HStack(spacing: 5) {
            if let symbol = CmsNavIcon.symbol(for: item.icon) {
                Image(systemName: symbol).font(.system(size: 13))
            }
            Text(item.label)
                .font(labelFont.weight(active && activeBold ? .semibold : .regular))
                .lineLimit(1)
            if chevron {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
        }
        .foregroundColor(!item.isActionable && item.children.isEmpty
                         ? .secondary.opacity(0.5)
                         : active ? activeTextColor : labelColor)
        .padding(.horizontal, chipVariant ? chipPadX : 4)
        .padding(.vertical, chipVariant ? chipPadY : 6)
        .background {
            if chipVariant && active {
                RoundedRectangle(cornerRadius: chipRadius, style: .continuous)
                    .fill(activeFill ?? .clear)
                    .overlay {
                        if variant == "outline" {
                            RoundedRectangle(cornerRadius: chipRadius, style: .continuous)
                                .strokeBorder(activeColor, lineWidth: 1)
                        }
                    }
            }
        }
        .overlay(alignment: .bottom) {
            if variant == "underline" && active {
                Rectangle().fill(activeColor).frame(height: 2)
            }
        }
        .contentShape(Rectangle())
        .cmsInspectorID("Cms.topNav.item")
    }

    /// Recursive Menu entries — nested children become nested Menus.
    private func menuEntries(_ items: [CmsNavItem]) -> AnyView {
        AnyView(
            ForEach(items) { item in
                if !item.children.isEmpty {
                    Menu(item.label) {
                        menuEntries(item.children)
                    }
                } else {
                    Button {
                        item.perform(runtime: runtime, openURL: openURL)
                    } label: {
                        if let symbol = CmsNavIcon.symbol(for: item.icon) {
                            Label(item.label, systemImage: symbol)
                        } else {
                            Text(item.label)
                        }
                    }
                    .disabled(!item.isActionable)
                }
            }
        )
    }
}
