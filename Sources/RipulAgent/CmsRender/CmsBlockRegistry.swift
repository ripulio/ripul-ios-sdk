import SwiftUI

/// Native block registry — the Swift twin of the web's BlockRegistry.
/// Maps a block `type` discriminator to a SwiftUI renderer. VISUAL types
/// without a native twin render `CmsUnsupportedBlockView` (an honest native
/// placeholder, never a web view) so a page keeps rendering as new block
/// types ship on the web before their native twins exist. HEADLESS types
/// (no visual output on the web — they feed data/config channels) render
/// NOTHING when untwinned: absence of UI is the correct mirror. Their DATA
/// role simply doesn't run yet — e.g. a `condition` block's outputs stay
/// unresolved — which the runtime inspector surfaces.
@MainActor
public enum CmsBlockRegistry {
    public typealias Renderer = (CmsBlock, Axis) -> AnyView

    private static var renderers: [String: Renderer] = defaultRenderers()

    /// Web block types marked `headless: true` (or rendering null at
    /// runtime) that have no native twin yet. `parameterSetter` is headless
    /// too but has a twin, so it isn't listed.
    private static let headlessTypes: Set<String> = [
        "condition",
        "navContribution",
        "columnDefs",
    ]

    public static func register(_ type: String, renderer: @escaping Renderer) {
        renderers[type] = renderer
    }

    public static func supports(_ type: String) -> Bool {
        renderers[type] != nil
    }

    public static var supportedTypes: [String] {
        renderers.keys.sorted()
    }

    @ViewBuilder
    static func render(_ block: CmsBlock, axis: Axis) -> some View {
        if let renderer = renderers[block.type] {
            renderer(block, axis)
        } else if headlessTypes.contains(block.type) {
            EmptyView()
        } else {
            CmsUnsupportedBlockView(block: block)
        }
    }

    private static func defaultRenderers() -> [String: Renderer] {
        var map: [String: Renderer] = [:]
        map["text"] = { block, _ in AnyView(CmsTextBlockView(block: block)) }
        map["markdown"] = { block, _ in AnyView(CmsMarkdownBlockView(block: block)) }
        map["image"] = { block, _ in AnyView(CmsImageBlockView(block: block)) }
        map["divider"] = { block, _ in AnyView(CmsDividerBlockView(block: block)) }
        map["section"] = { block, _ in AnyView(CmsSectionBlockView(block: block)) }
        map["container"] = { block, _ in AnyView(CmsContainerBlockView(block: block)) }
        map["recordCards"] = { block, _ in AnyView(CmsRecordCardsBlockView(block: block)) }
        map["simpleCalendar"] = { block, _ in AnyView(CmsSimpleCalendarBlockView(block: block)) }
        map["selectionMenu"] = { block, _ in AnyView(CmsSelectionMenuBlockView(block: block)) }
        map["kpiStrip"] = { block, _ in AnyView(CmsKpiStripBlockView(block: block)) }
        map["agGrid"] = { block, _ in AnyView(CmsAgGridBlockView(block: block)) }
        map["parameterSetter"] = { block, _ in AnyView(CmsParameterSetterBlockView(block: block)) }
        map["gridViewSwitcher"] = { block, _ in AnyView(CmsGridViewSwitcherBlockView(block: block)) }
        map["agentChat"] = { block, _ in AnyView(CmsAgentChatBlockView(block: block)) }
        map["sidebarNav"] = { block, _ in AnyView(CmsSidebarNavBlockView(block: block)) }
        map["topNav"] = { block, _ in AnyView(CmsTopNavBlockView(block: block)) }
        map["pageOutlet"] = { block, _ in AnyView(CmsPageOutletBlockView(block: block)) }
        map["detailHeader"] = { block, _ in AnyView(CmsDetailHeaderBlockView(block: block)) }
        map["fieldGrid"] = { block, _ in AnyView(CmsFieldGridBlockView(block: block)) }
        map["modal"] = { block, _ in AnyView(CmsModalBlockView(block: block)) }
        map["recordNavigator"] = { block, _ in AnyView(CmsRecordNavigatorBlockView(block: block)) }
        map["trailMap"] = { block, _ in AnyView(CmsTrailMapBlockView(block: block)) }
        return map
    }
}

/// Renders one block: registry lookup wrapped in the block's frame semantics.
/// Hidden / off-device blocks stay MOUNTED but invisible — same rule as the
/// web, where they keep feeding block outputs (a hidden AG Grid publishing
/// aggregates to a KPI strip) and selections.
///
/// DESIGN MODE (`runtime.isDesignMode`): the runtime IS the canvas — no
/// forked designer surface. Every block gets selection chrome (dashed
/// outline, solid accent when picked) and a HIGH-priority tap that selects
/// it. High priority beats the block's internal controls (a tap selects
/// instead of toggling — the web's edit-mode reading) while innermost
/// resolution still picks the DEEPEST nested block. Hidden/off-device
/// blocks render visibly but dimmed with a marker chip, mirroring the web
/// ("fully visible and editable in edit mode").
struct CmsBlockView: View {
    let block: CmsBlock
    let axis: Axis
    @EnvironmentObject var runtime: CmsRuntime

    private var isSuppressed: Bool { block.hidden == true || excludedOnMobile }
    private var isSelected: Bool { runtime.selectedBlockId == block.id }

    var body: some View {
        if isSuppressed && !runtime.isDesignMode {
            CmsBlockRegistry.render(block, axis: axis)
                .frame(height: 0)
                .clipped()
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        } else {
            let content = CmsBlockRegistry.render(block, axis: axis)
                .modifier(CmsBlockFrameModifier(frame: block.frame, axis: axis, resolve: { runtime.color($0) }))
                // View Explorer: every block reports `Cms.<type>.<slug>` so the
                // inspector can name it (the native twin of `data-ui`).
                .cmsInspectorID("Cms.\(block.type).\(block.slug ?? block.id)")
            if runtime.isDesignMode {
                let designContent = content
                    .opacity(isSuppressed ? 0.45 : 1)
                    .overlay { designChrome }
                    .contentShape(Rectangle())
                if isContainer {
                    // Containers pass taps through to nested blocks first; empty
                    // space still selects the container via contentShape.
                    designContent
                        .gesture(
                            TapGesture().onEnded {
                                runtime.selectedBlockId = isSelected ? nil : block.id
                            }
                        )
                } else {
                    // Leaf blocks beat their own inner controls in design mode
                    // (a tap selects instead of toggling).
                    designContent
                        .highPriorityGesture(
                            TapGesture().onEnded {
                                runtime.selectedBlockId = isSelected ? nil : block.id
                            }
                        )
                }
            } else {
                content
            }
        }
    }

    @ViewBuilder private var designChrome: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.accentColor : Color.secondary.opacity(0.4),
                    style: StrokeStyle(lineWidth: isSelected ? 2 : 1, dash: isSelected ? [] : [5, 4])
                )
            if isSelected {
                Text(block.type)
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor))
                    .padding(3)
            } else if isSuppressed {
                Image(systemName: suppressionIcon)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(4)
                    .background(Circle().fill(Color.secondary.opacity(0.12)))
                    .padding(3)
            }
        }
        .overlay(alignment: .center) {
            if isSuppressed {
                HStack(spacing: 4) {
                    Image(systemName: suppressionIcon)
                    Text(suppressionLabel)
                }
                .font(.caption.weight(.semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.red.opacity(0.85)))
                .shadow(radius: 2)
                .padding(8)
            }
        }
        .allowsHitTesting(false)
    }

    private var suppressionIcon: String {
        if block.hidden == true { return "eye.slash" }
        if excludedOnMobile { return "desktopcomputer" }
        return "eye.slash"
    }
    private var suppressionLabel: String {
        if block.hidden == true { return "Hidden" }
        if excludedOnMobile { return "Desktop only" }
        return "Hidden"
    }

    private var excludedOnMobile: Bool {
        guard let visibleOn = block.visibleOn, !visibleOn.isEmpty else { return false }
        return !visibleOn.contains("mobile")
    }

    /// Block types whose native renderer embeds other blocks. For these we
    /// want taps to reach the deepest nested child first; empty space still
    /// selects the container itself.
    private var isContainer: Bool {
        ["section", "container", "template", "sidebar", "pageOutlet", "modal", "recordNavigator", "trailMap"]
            .contains(block.type)
    }
}

/// Renders a CmsPageBlocks container recursively. `list` gets full column/row
/// semantics; template and sidebar slots stack vertically on the phone
/// (matching the web's own mobile collapse); canvas and carousel items stack —
/// a documented PoC simplification.
struct CmsBlockContainerView: View {
    let container: CmsPageBlocks
    @EnvironmentObject var runtime: CmsRuntime

    var body: some View {
        let frame = container.containerFrame
        Group {
            switch container {
            case .list(let items, _), .canvas(let items, _, _, _), .carousel(let items, _):
                stack(items: items, frame: frame)
            case .sidebar(let variant, let slots, let sidebarFrame):
                CmsSidebarLayoutView(variant: variant, slots: slots, frame: sidebarFrame)
            case .template(_, let slots, _):
                VStack(alignment: .leading, spacing: frame?.gapPoints ?? 16) {
                    ForEach(orderedSlotKeys(slots), id: \.self) { key in
                        if let slot = slots[key] {
                            CmsBlockContainerView(container: slot)
                        }
                    }
                }
            }
        }
        .modifier(CmsContainerFrameModifier(frame: frame, resolve: { runtime.color($0) }))
    }

    @ViewBuilder
    private func stack(items: [CmsBlock], frame: CmsContainerFrame?) -> some View {
        let gap = frame?.gapPoints ?? 16
        if frame?.stackAxis == .horizontal {
            HStack(alignment: frame?.verticalAlignment ?? .top, spacing: gap) {
                ForEach(items) { CmsBlockView(block: $0, axis: .horizontal) }
            }
        } else {
            VStack(alignment: frame?.horizontalAlignment ?? .leading, spacing: gap) {
                ForEach(items) { CmsBlockView(block: $0, axis: .vertical) }
            }
        }
    }

    /// 'main' first, then remaining slots in name order — keeps the primary
    /// content above sidebars when a sidebar layout collapses to a phone column.
    private func orderedSlotKeys(_ slots: [String: CmsPageBlocks]) -> [String] {
        var keys = slots.keys.sorted()
        if let mainIndex = keys.firstIndex(of: "main") {
            keys.remove(at: mainIndex)
            keys.insert("main", at: 0)
        }
        return keys
    }
}

/// Honest native placeholder for a block type with no native twin yet.
struct CmsUnsupportedBlockView: View {
    let block: CmsBlock

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.dashed")
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(block.name ?? block.type)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.secondary)
                Text("No native renderer for '\(block.type)' yet")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .foregroundColor(Color.secondary.opacity(0.4))
        )
    }
}
