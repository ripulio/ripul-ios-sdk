import SwiftUI

/// Page-level slide-in drawer — the native twin of the web's sidebar Drawer.
/// Owned by CmsPageView so the scrim and panel cover the whole rendered page
/// (matching the app's own slide-out sidebar) instead of scrolling with a
/// block. On iOS UIKit places it (`CmsDrawerTrack`): it follows a finger,
/// springs open or closed, and closes by a scrim tap or a drag toward the edge.
struct CmsDrawerOverlay: View {
    @ObservedObject var runtime: CmsRuntime
    /// Handed to the panel's own hosting controller on iOS, so it reads the
    /// page's theme, colour scheme and the rest as before.
    @Environment(\.self) private var environment

    static let panelWidth: CGFloat = 320
    private var panelWidth: CGFloat { Self.panelWidth }

    var body: some View {
        GeometryReader { geo in
            if let request = runtime.openDrawer {
                let width = panelWidth(for: request, in: geo.size)
                #if os(iOS)
                // UIKit places the panel and the scrim (`CmsDrawerTrack`): a
                // finger moves a transform, never SwiftUI state.
                CmsDrawerTrackView(runtime: runtime, edge: request.edge, width: width,
                                   // The page's environment first, then the runtime
                                   // inside it (the copy would otherwise replace it).
                                   panel: AnyView(panel(request, width: width)
                                    .environmentObject(runtime)
                                    .environment(\.self, environment)))
                #else
                ZStack(alignment: request.edge == .trailing ? .trailing : .leading) {
                    Color.black.opacity(0.2)
                        .contentShape(Rectangle())
                        .onTapGesture { runtime.closeDrawer() }
                    panel(request, width: width)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                #endif
            }
        }
        .ignoresSafeArea()
    }

    /// Authored width capped so the scrim stays reachable on any device.
    private func panelWidth(for request: CmsRuntime.DrawerRequest, in size: CGSize) -> CGFloat {
        // The request's width, else the side region's (its sidebar layout's
        // `sidebarWidth`, WAC's 321), else the default; capped to the screen.
        let region = request.edge == .leading ? runtime.edgeSwipeLeftWidth : runtime.edgeSwipeRightWidth
        return min(request.width ?? region ?? Self.panelWidth, max(240, size.width - 48))
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
            let (body, footer) = Self.splitPinnedBottom(request.slot)
            Group {
                if Self.isSelfScrolling(body) {
                    // A native sidebar List owns its own scrolling and insets —
                    // no outer ScrollView (that would nest scrollers) and no
                    // padding (the List provides sidebar insets).
                    CmsBlockContainerView(container: body)
                        .frame(maxHeight: .infinity, alignment: .top)
                } else if Self.containsFill(body) {
                    VStack(spacing: 0) {
                        CmsBlockContainerView(container: body)
                            .padding(16)
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                } else {
                    ScrollView {
                        CmsBlockContainerView(container: body)
                            .padding(16)
                    }
                }
            }
            // `pin: 'bottom'`: kept at the drawer's foot, as a bottom inset, so
            // the region's last rows scroll clear of it rather than under it.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let footer {
                    VStack(spacing: 0) {
                        Divider()
                        CmsBlockContainerView(container: footer)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }
                }
            }
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        // Native slide-in sidebar: Liquid Glass surface (iOS 26+) with an
        // interior-rounded edge, instead of an opaque paper fill.
        .modifier(GlassSidebarPanelModifier(roundTrailing: request.edge == .leading))
        .shadow(color: .black.opacity(0.2), radius: 12, x: request.edge == .leading ? 4 : -4, y: 0)
    }

    /// A side region's blocks split into what scrolls and what is pinned to
    /// its foot (`frame.pin: 'bottom'`, in order); nil footer when none is.
    static func splitPinnedBottom(_ container: CmsPageBlocks) -> (CmsPageBlocks, CmsPageBlocks?) {
        guard case .list(let items, let frame) = container else { return (container, nil) }
        let pinned = items.filter { $0.frame?.pin == "bottom" }
        guard !pinned.isEmpty else { return (container, nil) }
        return (.list(items: items.filter { $0.frame?.pin != "bottom" }, frame: frame), .list(items: pinned, frame: frame))
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

    private func close() { runtime.closeDrawer() }
}
