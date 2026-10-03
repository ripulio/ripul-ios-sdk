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
/// The web's `appearance: app` preset is web presentation too and is ignored;
/// its CONTENT carries over: group headings render as section labels, badges
/// as capsules, and the workspace card (`headerTitle`…) as the first row.
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
                workspaceCard
                ForEach(rows) { row in
                    if row.item.divider {
                        Divider().padding(.horizontal, 16).padding(.vertical, 4)
                    }
                    if row.item.heading {
                        headingRow(row)
                    } else if !row.item.divider || row.item.isActionable || !row.item.children.isEmpty {
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
            if item.heading {
                // A heading is a label, never an accordion: its own children
                // always show, at the heading's depth.
                rows.append(FlatRow(id: "h|" + key(item, depth), item: item, depth: depth, expanded: true))
                flatten(item.children, depth: depth, into: &rows)
                continue
            }
            let isOpen = expanded.contains(key(item, depth))
            rows.append(FlatRow(id: key(item, depth), item: item, depth: depth, expanded: isOpen))
            if isOpen { flatten(item.children, depth: depth + 1, into: &rows) }
        }
    }

    /// A group heading: the small uppercase label over its group.
    private func headingRow(_ row: FlatRow) -> some View {
        Text(row.item.label.uppercased())
            .font(.system(size: 11, weight: .bold))
            .tracking(1.2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.leading, CGFloat(row.depth) * 16)
            .padding(.top, 12)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
            .cmsInspectorID("Cms.sidebarNav.heading")
    }

    // ── Workspace card (headerTitle / headerSubtitle / headerInitials) ──────

    private var headerTitle: String? {
        guard let title = runtime.resolveString(block: block, propKey: "headerTitle"),
              !title.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return title
    }

    /// Two-letter mark: authored initials, else the title's (any token still
    /// unresolved is ignored, as on the web).
    private func initials(for title: String) -> String {
        if let authored = block.props.string("headerInitials")?.trimmingCharacters(in: .whitespaces),
           !authored.isEmpty {
            return String(authored.prefix(3))
        }
        let words = title.replacing(#/@[A-Za-z_]\w*\.[A-Za-z_]\w*/#, with: " ")
            .split(whereSeparator: \.isWhitespace)
        if words.count == 1 { return String(words[0].prefix(2)).uppercased() }
        return words.prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    /// Records the card switches between (web: `headerQuerySlug`).
    private var headerSource: String? {
        block.props.string("headerQuerySlug").flatMap { $0.isEmpty ? nil : $0 }
    }

    private var headerSourceRows: [[String: CmsJSON]] {
        guard let source = headerSource, case .ok(let result) = runtime.state(for: source) else { return [] }
        return result.rows
    }

    /// The card's text for one record of the source: its `@source.column`
    /// tokens read that row, other tokens the current selections.
    private func headerText(_ propKey: String, row: [String: CmsJSON]) -> String {
        guard let source = headerSource, let raw = block.props.string(propKey) else { return "" }
        if let binding = block.bindings?[propKey], binding.querySlug == source {
            return row[binding.column]?.displayString ?? ""
        }
        return runtime.resolveTemplate(raw.replacingOccurrences(of: "@\(source).", with: "@"), rowContext: row)
    }

    /// Land on the first record when nothing is selected yet — the shell's
    /// pick, which the page inherits (web: useRecordCursor autoSelectFirst).
    private func anchorHeaderSource() {
        guard let source = headerSource else { return }
        runtime.ensureLoaded(source)
        if runtime.selectedRow(source) == nil, let first = headerSourceRows.first {
            runtime.setSelectedRows(source, rows: [first])
        }
    }

    private static let unresolvedToken = #/@[A-Za-z_]\w*\.[A-Za-z_]\w*/#

    /// The workspace card: a brand-gradient mark beside the workspace name
    /// and subtitle. With several records to pick from it is a menu of them
    /// (plus the card's page); otherwise it opens `headerTargetPageSlug`.
    @ViewBuilder
    private var workspaceCard: some View {
        if let title = headerTitle {
            let subtitle = runtime.resolveString(block: block, propKey: "headerSubtitle")
                .flatMap { $0.isEmpty ? nil : $0 }
            let target = block.props.string("headerTargetPageSlug").flatMap { $0.isEmpty ? nil : $0 }
            // Tokens whose row isn't selected yet show as a placeholder, never raw.
            let pending = title.contains(Self.unresolvedToken) || (subtitle?.contains(Self.unresolvedToken) ?? false)
            let rows = headerSourceRows
            let switchable = rows.count > 1
            let card = HStack(spacing: 10) {
                Text(initials(for: title))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(runtime.theme.primaryContrast)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(runtime.theme.gradient))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if switchable {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                } else if target != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .redacted(reason: pending ? .placeholder : [])
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(runtime.theme.surfaceMuted)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(runtime.theme.divider, lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
            .padding(.bottom, 6)

            Group {
                if switchable, let source = headerSource {
                    let current = runtime.selectedRow(source)
                    Menu {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            Button {
                                runtime.setSelectedRows(source, rows: [row])
                            } label: {
                                let label = headerText("headerTitle", row: row)
                                if current == row {
                                    Label(label, systemImage: "checkmark")
                                } else {
                                    Text(label)
                                }
                            }
                        }
                        if let target {
                            Divider()
                            Button("Settings") { runtime.navigate(toPage: target, viewRef: nil) }
                        }
                    } label: { card }
                    .buttonStyle(.plain)
                    .cmsInspectorID("Cms.sidebarNav.workspaceMenu")
                } else if let target {
                    Button { runtime.navigate(toPage: target, viewRef: nil) } label: { card }
                        .buttonStyle(.plain)
                        .cmsInspectorID("Cms.sidebarNav.workspaceCard")
                } else {
                    card.cmsInspectorID("Cms.sidebarNav.workspaceCard")
                }
            }
            .task(id: rows.count) { anchorHeaderSource() }
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
                if let badge = item.badgeText(runtime: runtime) {
                    CmsNavBadge(text: badge, tone: item.badgeTone)
                }
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
                if item.heading {
                    // Headings never collapse; their children sit at its depth.
                    walk(item.children, depth: depth)
                    continue
                }
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
/// concern with no native twin yet. `showPageTitle` shows the routed page's
/// title; group headings become a separator in the bar and a `Section` in
/// menus; `iconOnly` entries are bare SF Symbols with a corner count badge.
/// The web `appearance: app` preset (bar chrome) is web presentation and is
/// not reproduced.
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
        runtime.radius(block.props.string("activeRadius")) ?? (variant == "pill" ? 999 : 10)
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

    /// The routed page's title (web: the portal shell's `activePage`). Nil
    /// when no shell is active or the shell itself is the page.
    @ViewBuilder
    private var pageTitle: some View {
        if block.props.bool("showPageTitle") == true, let title = runtime.outletPage?.title, !title.isEmpty {
            let typo = block.props.object("pageTitleTypography")
            Text(title)
                .font(.system(size: CmsTypography.size(typo) ?? 17,
                              weight: CmsTypography.weight(typo) ?? .bold))
                .foregroundColor(runtime.color(typo?.string("color")) ?? .primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityAddTraits(.isHeader)
                .cmsInspectorID("Cms.topNav.pageTitle")
        }
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
                pageTitle
                Spacer(minLength: 0)
            } else {
                barZones
            }
        }
        .padding(.horizontal, CmsCss.points(block.props.string("paddingX")) ?? 12)
        .frame(minHeight: CmsCss.points(block.props.string("height")) ?? 44)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(runtime.fill(block.props.string("background")) ?? AnyShapeStyle(Color.clear))
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
            pageTitle
            ForEach(start) { barItem($0) }
            Spacer(minLength: 8)
            if logoAlign == "center" { logoMark }
            ForEach(center) { barItem($0) }
            Spacer(minLength: 8)
            ForEach(end) { barItem($0) }
            if logoAlign == "end" { logoMark }
        }
    }

    private func barItem(_ item: CmsNavItem) -> AnyView {
        // A bar has no room for a group label: a heading is a separator with
        // its own children inline after it.
        if item.heading {
            return AnyView(Group {
                Divider().frame(height: 20)
                ForEach(item.children) { barItem($0) }
            })
        }
        return AnyView(barEntry(item))
    }

    @ViewBuilder
    private func barEntry(_ item: CmsNavItem) -> some View {
        if item.divider {
            Divider().frame(height: 20)
        }
        if item.iconOnly, let symbol = CmsNavIcon.symbol(for: item.icon) {
            iconOnlyEntry(item, symbol: symbol)
        } else if !item.children.isEmpty {
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

    /// An icon-only bar entry: the SF Symbol with a count badge on its
    /// corner; the label is the accessibility label. Parents open their Menu.
    @ViewBuilder
    private func iconOnlyEntry(_ item: CmsNavItem, symbol: String) -> some View {
        let active = item.targetPageSlug != nil && item.targetPageSlug == runtime.currentPageSlug
        let glyph = Image(systemName: symbol)
            .font(.system(size: 17, weight: .medium))
            .foregroundColor(active ? activeTextColor : labelColor)
            .frame(width: 32, height: 32)
            .overlay(alignment: .topTrailing) {
                if let badge = item.badgeText(runtime: runtime) {
                    CmsNavBadge(text: badge, tone: item.badgeTone, bubble: true)
                        .offset(x: 6, y: -4)
                }
            }
            .contentShape(Rectangle())
            .accessibilityLabel(item.label)
            .cmsInspectorID("Cms.topNav.iconItem")
        if !item.children.isEmpty {
            Menu { menuEntries(item.children) } label: { glyph }
        } else {
            Button { item.perform(runtime: runtime, openURL: openURL) } label: { glyph }
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
            if let badge = item.badgeText(runtime: runtime) {
                CmsNavBadge(text: badge, tone: item.badgeTone)
            }
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
            ForEach(CmsNavItem.foldHeadings(items)) { item in
                if item.heading {
                    Section(item.label) {
                        menuEntries(item.children)
                    }
                } else if !item.children.isEmpty {
                    Menu(item.label) {
                        menuEntries(item.children)
                    }
                } else {
                    Button {
                        item.perform(runtime: runtime, openURL: openURL)
                    } label: {
                        // Menus render plain text — the badge rides along as a
                        // suffix rather than a styled pill.
                        let title = item.badgeText(runtime: runtime).map { "\(item.label)  ·  \($0)" } ?? item.label
                        if let symbol = CmsNavIcon.symbol(for: item.icon) {
                            Label(title, systemImage: symbol)
                        } else {
                            Text(title)
                        }
                    }
                    .disabled(!item.isActionable)
                }
            }
        )
    }
}
