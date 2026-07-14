import SwiftUI

/// Page-level slide-in drawer — the native twin of the web's sidebar Drawer.
/// Owned by CmsPageView so the scrim and panel cover the whole rendered page
/// (matching the app's own slide-out sidebar) instead of scrolling with a
/// block. Slides from the requesting edge with the app's sidebar spring;
/// dismiss by scrim tap or dragging toward the edge.
struct CmsDrawerOverlay: View {
    @ObservedObject var runtime: CmsRuntime
    @State private var dragOffset: CGFloat = 0

    static let panelWidth: CGFloat = 320
    private var panelWidth: CGFloat { Self.panelWidth }
    private let spring = Animation.spring(response: 0.32, dampingFraction: 0.86)

    /// 1 = fully open, 0 = hidden at the edge (interactive open in flight).
    private var openProgress: CGFloat {
        1 - min(abs(runtime.drawerOpenOffset) / panelWidth, 1)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: alignment) {
                if let request = runtime.openDrawer {
                    // Scrim dims with the open progress so an interactive open
                    // fades it in under the finger.
                    Color.black.opacity(0.2 * openProgress)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { close() }
                        .transition(.opacity)

                    panel(request, width: panelWidth(for: request, in: geo.size))
                        // An edge swipe places the panel itself (the finger is
                        // the animation) — no insertion slide on top of it.
                        .transition(runtime.drawerInteractiveOpen
                                    ? AnyTransition.identity
                                    : .move(edge: request.edge == .leading ? .leading : .trailing))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: alignmentPoint)
        }
        .animation(spring, value: runtime.openDrawer != nil)
    }

    /// Authored width capped so the scrim stays reachable on any device.
    private func panelWidth(for request: CmsRuntime.DrawerRequest, in size: CGSize) -> CGFloat {
        min(request.width ?? Self.panelWidth, max(240, size.width - 48))
    }

    private var alignmentPoint: Alignment {
        runtime.openDrawer?.edge == .trailing ? .trailing : .leading
    }

    private var alignment: Alignment {
        runtime.openDrawer?.edge == .trailing ? .trailing : .leading
    }

    @ViewBuilder
    private func panel(_ request: CmsRuntime.DrawerRequest, width: CGFloat) -> some View {
        // A slot containing a fill-sized block owns the drawer height (an
        // agent chat column) — no outer scroll, so the height proposal
        // reaches it. Otherwise the slot scrolls like a normal column.
        // (A ScrollView proposes unbounded height, collapsing fill children.)
        VStack(spacing: 0) {
            if let title = request.title {
                HStack {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        close()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.footnote.weight(.semibold))
                            .padding(8)
                            .background(Circle().fill(Color.secondary.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                Divider()
            }
            if Self.isSelfScrolling(request.slot) {
                // A native sidebar List owns its own scrolling and insets —
                // no outer ScrollView (that would nest scrollers) and no
                // padding (the List provides sidebar insets).
                CmsBlockContainerView(container: request.slot)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else if Self.containsFill(request.slot) {
                VStack(spacing: 0) {
                    CmsBlockContainerView(container: request.slot)
                        .padding(16)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView {
                    CmsBlockContainerView(container: request.slot)
                        .padding(16)
                }
            }
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        // Native slide-in sidebar: Liquid Glass surface (iOS 26+) with an
        // interior-rounded edge, instead of an opaque paper fill.
        .modifier(GlassSidebarPanelModifier(roundTrailing: request.edge == .leading))
        .environmentObject(runtime)
        .offset(x: dragOffset + runtime.drawerOpenOffset)
        .gesture(
            DragGesture()
                .onChanged { value in
                    // Follow the finger only toward the drawer's edge.
                    let translation = value.translation.width
                    dragOffset = request.edge == .leading
                        ? min(0, translation)
                        : max(0, translation)
                }
                .onEnded { value in
                    let toward = request.edge == .leading
                        ? -value.translation.width
                        : value.translation.width
                    if toward > 60 { close() } else {
                        withAnimation(spring) { dragOffset = 0 }
                    }
                }
        )
        .shadow(color: .black.opacity(0.2), radius: 12, x: request.edge == .leading ? 4 : -4, y: 0)
    }

    /// A slot that is a single self-scrolling block (a native sidebar `List`)
    /// hosts itself — the drawer must not wrap it in a ScrollView.
    static func isSelfScrolling(_ container: CmsPageBlocks) -> Bool {
        if case .list(let items, _) = container, items.count == 1 {
            return items[0].type == "sidebarNav"
        }
        return false
    }

    /// Does any block in the slot declare Size = fill?
    static func containsFill(_ container: CmsPageBlocks) -> Bool {
        func blockFills(_ block: CmsBlock) -> Bool {
            if block.frame?.size == "fill" { return true }
            if block.props["height"]?.stringValue == "fill" { return true }
            if let children = block.children { return containsFill(children) }
            return false
        }
        switch container {
        case .list(let items, _), .canvas(let items, _, _, _), .carousel(let items, _):
            return items.contains(where: blockFills)
        case .template(_, let slots, _), .sidebar(_, let slots, _):
            return slots.values.contains(where: containsFill)
        }
    }

    private func close() {
        // `closeDrawer()` owns the slide-out animation now; just settle any
        // in-flight drag alongside it.
        withAnimation(spring) { dragOffset = 0 }
        runtime.closeDrawer()
    }
}
