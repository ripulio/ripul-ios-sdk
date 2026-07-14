import SwiftUI

/// Native rendering of the `sidebar` page layout on compact width — the twin
/// of SidebarRenderer's mobile collapse (below md the web moves side columns
/// into slide-in drawers behind an in-flow burger bar). Natively the main
/// slot renders full width under the same burger bar (left burger leading,
/// right burger trailing — the web's space-between bar), and the side
/// columns SLIDE IN as page-level drawers (CmsDrawerOverlay, owned by
/// CmsPageView) — matching the app's own slide-out sidebar. Side columns
/// can be long-lived functional surfaces, not quick selections, so the
/// lateral drawer's spatial continuity beats a bottom sheet here.
///
/// The web's app-nav merge (page's left drawer hosts the sidebarNav guest
/// with a Menu/Page toggle) applies once a native sidebarNav twin exists —
/// it needs native page routing first; the left drawer is its future home.
struct CmsSidebarLayoutView: View {
    let variant: String
    let slots: [String: CmsPageBlocks]
    let frame: CmsContainerFrame?
    @EnvironmentObject var runtime: CmsRuntime

    private var hasLeft: Bool {
        (variant == "left" || variant == "both") && slots["left"] != nil
    }
    private var hasRight: Bool {
        (variant == "right" || variant == "both") && slots["right"] != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: frame?.gapPoints ?? 16) {
            // The icon row is a page-settings OPT-IN (nativeSidebarIcon,
            // default off) — it costs a horizontal strip; edge swipe is
            // the default affordance for reaching the side panels.
            if (hasLeft || hasRight) && runtime.pageSidebarIcon {
                burgerBar
            }
            if let main = slots["main"] {
                CmsBlockContainerView(container: main)
            }
        }
        // Edge swipe lives at the PAGE level (CmsPageView edge strips) —
        // a content-level gesture here loses the touch competition to
        // nested UIKit scroll views. Register this layout's slots; on
        // disappear release only registrations still pointing at us (a
        // successor page's panels may already have re-registered).
        .onAppear {
            if hasLeft { runtime.edgeSwipeLeftSlot = slots["left"] }
            if hasRight { runtime.edgeSwipeRightSlot = slots["right"] }
        }
        .onDisappear {
            if hasLeft, runtime.edgeSwipeLeftSlot == slots["left"] {
                runtime.edgeSwipeLeftSlot = nil
            }
            if hasRight, runtime.edgeSwipeRightSlot == slots["right"] {
                runtime.edgeSwipeRightSlot = nil
            }
        }
    }

    /// In-flow burger bar — the web's reserve-mode strip.
    private var burgerBar: some View {
        HStack {
            if hasLeft {
                Button {
                    guard let slot = slots["left"] else { return }
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        runtime.openDrawer = .init(edge: .leading, slot: slot)
                    }
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.body.weight(.medium))
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            if hasRight {
                Button {
                    guard let slot = slots["right"] else { return }
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        runtime.openDrawer = .init(edge: .trailing, slot: slot)
                    }
                } label: {
                    Image(systemName: "sidebar.trailing")
                        .font(.body.weight(.medium))
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

}
