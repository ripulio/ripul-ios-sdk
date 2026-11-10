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
    /// This layout's registration of its slots (see `edgeSwipeLeftOwner`).
    @State private var owner = UUID()

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
        // The side regions, mounted offstage while their drawers are shut,
        // so what they publish (a choice list's default) is there when the
        // page loads, not only once a drawer opens. Their state is shared
        // with the drawer's copy through the runtime.
        .background(alignment: .topLeading) {
            ZStack {
                if hasLeft, let left = slots["left"] { CmsBlockContainerView(container: left) }
                if hasRight, let right = slots["right"] { CmsBlockContainerView(container: right) }
            }
            .frame(width: CmsDrawerOverlay.panelWidth - 32)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 0, height: 0, alignment: .topLeading)
            .clipped()
            .hidden()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        // Edge swipe lives at the PAGE level (CmsPageView edge strips) —
        // a content-level gesture here loses the touch competition to
        // nested UIKit scroll views. Register this layout's slots; on
        // disappear release only registrations still pointing at us (a
        // successor page's panels may already have re-registered).
        #if os(iOS)
        // The edge drag over content: content scrolling under the screen's
        // edge (a full-width sheet, a bleeding block) takes a drag before the
        // page's edge strip can, so a pan on the window opens the drawer too.
        .background(CmsSidebarEdgePan(runtime: runtime, left: hasLeft, right: hasRight).frame(width: 1, height: 1))
        #endif
        .onAppear {
            if hasLeft {
                runtime.edgeSwipeLeftSlot = slots["left"]
                runtime.edgeSwipeLeftOwner = owner
                runtime.edgeSwipeLeftWidth = frame?.sidebarWidth(left: true).map { CGFloat($0) }
            }
            if hasRight {
                runtime.edgeSwipeRightSlot = slots["right"]
                runtime.edgeSwipeRightOwner = owner
                runtime.edgeSwipeRightWidth = frame?.sidebarWidth(left: false).map { CGFloat($0) }
            }
        }
        .onDisappear {
            if hasLeft, runtime.edgeSwipeLeftOwner == owner {
                runtime.edgeSwipeLeftSlot = nil
                runtime.edgeSwipeLeftOwner = nil
            }
            if hasRight, runtime.edgeSwipeRightOwner == owner {
                runtime.edgeSwipeRightSlot = nil
                runtime.edgeSwipeRightOwner = nil
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

#if os(iOS)
/// A pan on the window that begins only when a drag starts within 22
/// points of a screen edge with a side region and moves inward; scroll
/// views' pans wait for it (it fails at once anywhere else). It slides the
/// drawer in under the finger, as the page's edge strip does.
private struct CmsSidebarEdgePan: UIViewRepresentable {
    let runtime: CmsRuntime
    let left: Bool
    let right: Bool

    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.isUserInteractionEnabled = false
        probe.isAccessibilityElement = false
        return probe
    }

    func updateUIView(_ probe: Probe, context: Context) {
        probe.runtime = runtime
        probe.left = left
        probe.right = right
    }

    static func dismantleUIView(_ probe: Probe, coordinator: ()) { probe.detach() }

    final class Probe: UIView {
        weak var runtime: CmsRuntime?
        var left = false
        var right = false
        private var pan: UIPanGestureRecognizer?
        /// The system's screen-edge pans, as WAC's sidebar uses: a finger on
        /// the very edge (which the plain pan below can miss) opens it too.
        private var edgePans: [UIScreenEdgePanGestureRecognizer] = []
        private lazy var rules = Rules(probe: self)
        fileprivate var edge: CmsRuntime.DrawerRequest.Edge?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window else { detach(); return }
            guard pan == nil else { return }
            let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
            recognizer.delegate = rules
            window.addGestureRecognizer(recognizer)
            pan = recognizer
            for side in [UIRectEdge.left, .right] {
                let edgePan = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handle(_:)))
                edgePan.edges = side
                edgePan.delegate = rules
                window.addGestureRecognizer(edgePan)
                edgePans.append(edgePan)
            }
        }

        func detach() {
            if let pan { pan.view?.removeGestureRecognizer(pan) }
            for edgePan in edgePans { edgePan.view?.removeGestureRecognizer(edgePan) }
            pan = nil
            edgePans = []
        }

        /// Whether a drag may open a drawer (asked by `Rules`, the pan's
        /// delegate: a UIView answering `gestureRecognizerShouldBegin` itself
        /// would also be asked about other gestures).
        fileprivate func shouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let runtime, let view = recognizer.view, !isHidden, window != nil,
                  runtime.pageSidebarEdgeSwipe, runtime.openDrawer == nil,
                  let pan = recognizer as? UIPanGestureRecognizer else { return false }
            if let edgePan = recognizer as? UIScreenEdgePanGestureRecognizer, edgePans.contains(edgePan) {
                if edgePan.edges == .left, left, runtime.edgeSwipeLeftSlot != nil { edge = .leading; return true }
                if edgePan.edges == .right, right, runtime.edgeSwipeRightSlot != nil { edge = .trailing; return true }
                return false
            }
            guard recognizer === self.pan else { return false }
            let start = pan.location(in: view).x - pan.translation(in: view).x
            let v = pan.velocity(in: view)
            guard abs(v.x) > abs(v.y) else { return false }
            if left, v.x > 0, CmsEdgeDrag.startsAtEdge(start, width: view.bounds.width, leading: true),
               runtime.edgeSwipeLeftSlot != nil {
                edge = .leading
                return true
            }
            if right, v.x < 0, CmsEdgeDrag.startsAtEdge(start, width: view.bounds.width, leading: false),
               runtime.edgeSwipeRightSlot != nil {
                edge = .trailing
                return true
            }
            return false
        }


        /// Moves the drawer with the finger through `CmsDrawerTrack` (UIKit
        /// only, no SwiftUI state per touch), then lets it spring.
        @objc private func handle(_ pan: UIPanGestureRecognizer) {
            guard let runtime, let edge else { return }
            let dx = pan.translation(in: pan.view).x
            let pulled = max(0, edge == .leading ? dx : -dx)
            switch pan.state {
            case .began:
                guard let slot = edge == .leading ? runtime.edgeSwipeLeftSlot : runtime.edgeSwipeRightSlot else { return }
                runtime.beginInteractiveDrawer(edge: edge, slot: slot)
                runtime.dragDrawer(pulled: pulled, edge: edge)
            case .changed:
                runtime.dragDrawer(pulled: pulled, edge: edge)
            case .ended, .cancelled, .failed:
                let vx = pan.velocity(in: pan.view).x
                runtime.releaseDrawer(velocity: pan.state == .ended ? (edge == .leading ? vx : -vx) : 0, edge: edge)
                self.edge = nil
            default:
                break
            }
        }
    }

    final class Rules: NSObject, UIGestureRecognizerDelegate {
        weak var probe: Probe?
        init(probe: Probe) { self.probe = probe }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            probe?.shouldBegin(recognizer) ?? false
        }

        /// A scroll view's pan waits for the edge drag to fail.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            other.view is UIScrollView
        }
    }
}
#endif
