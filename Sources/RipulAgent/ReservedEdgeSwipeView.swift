#if os(iOS)
import SwiftUI
import UIKit

/// The chat's swipe back from the left edge, owning a strip along the edge
/// without taking the touches that start there from what is under them.
///
/// A swipe right that starts within `width` of the edge is the edge's. The
/// messages' swipe to reply declines it (`reserves`), and it slides the chat
/// back even when it did not start on the screen's own edge: a swipe meant for
/// the edge started on a message and slid it to reply (Peter, 1 November
/// 2026). As the app drawer's edge swipe does (`SidebarEdgeSwipeView`), the
/// strip is a marker that takes no touches and its pans watch from the window,
/// so a tap or a scroll that starts on the strip still reaches the message
/// under it. A screen-edge pan takes a touch from the very edge. A plain pan
/// stands in where that one does not: a touch further in, and every touch on
/// the unfolded iPhone Duo, which recognises no screen-edge pan. It begins
/// only on a move to the right, and does not wait for the edge pan to fail:
/// the two are exclusive anyway, and on Peter's open Duo, upright, a stand-in
/// that waited never began (1 November 2026). `[EDGESWIPE]` lines say which
/// one took a swipe, or why the stand-in let it go.
///
/// The details panel's swipe in from the right edge is one too (`edge:
/// .trailing`, offsets and speeds measured leftward). Where the system's tab
/// rail stands beside the strip (the closed Duo upright, rail at the right),
/// a swipe from the screen's edge starts on the rail, so a touch on the rail
/// beside the strip counts as the strip's; a tap there still reaches the rail.
struct ReservedEdgeSwipeView: UIViewRepresentable {
    /// How far in from the edge the chat's swipe back's strip reaches.
    static let width: CGFloat = 50

    var edge: HorizontalEdge = .leading
    var onBegan: () -> Void
    var onChanged: (CGFloat) -> Void
    var onEnded: (_ offset: CGFloat, _ velocity: CGFloat) -> Void
    var onCancelled: () -> Void
    var maxOffset: CGFloat

    private static let markers = NSHashTable<MarkerView>.weakObjects()

    /// Whether `touch` starts on a left-edge strip an edge swipe has reserved
    /// (the swipe to reply, a rightward swipe, gives way to it).
    static func reserves(_ touch: UITouch) -> Bool {
        guard let window = touch.window else { return false }
        let point = touch.location(in: window)
        return markers.allObjects.contains {
            $0.edge == .leading && $0.window === window && $0.convert($0.bounds, to: window).contains(point)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MarkerView {
        let view = MarkerView()
        view.edge = edge
        context.coordinator.marker = view
        view.onWindowChanged = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        return view
    }

    func updateUIView(_ view: MarkerView, context: Context) {
        context.coordinator.configuration = self
    }

    static func dismantleUIView(_ view: MarkerView, coordinator: Coordinator) {
        view.onWindowChanged = nil
        coordinator.attach(to: nil)
    }

    final class MarkerView: UIView {
        var onWindowChanged: ((UIWindow?) -> Void)?
        var edge: HorizontalEdge = .leading
        private var testingExposure = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { ReservedEdgeSwipeView.markers.remove(self) } else { ReservedEdgeSwipeView.markers.add(self) }
            onWindowChanged?(window)
        }

        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            testingExposure && super.point(inside: point, with: event)
        }

        /// Whether a touch at `point` lands on this strip, nothing covering
        /// it, without taking the actual touch from its content.
        func isExposed(at point: CGPoint, in window: UIWindow) -> Bool {
            testingExposure = true
            defer { testingExposure = false }
            return window.hitTest(point, with: nil) === self
        }

        /// Whether a touch at `point` lands in the system's tab rail's strip,
        /// out beyond this strip on its side and level with it. Mostly that
        /// strip is the selected screen showing past its safe area, not the
        /// rail's buttons (on the Duo simulator a touch 2pt from the edge hit
        /// the tab's hosting view), so where it lands within the tab bar
        /// controller does not matter; landing outside it means something is
        /// presented over the rail.
        func isOnRail(at point: CGPoint, in window: UIWindow) -> Bool {
            #if targetEnvironment(macCatalyst)
            // No system tab rail on a Mac (`SystemTabRail` is not built there).
            return false
            #else
            let frame = convert(bounds, to: window)
            let beyond = edge == .trailing ? point.x >= frame.minX : point.x <= frame.maxX
            guard beyond, point.y >= frame.minY, point.y <= frame.maxY,
                  let rail = SystemTabRail.rail(in: window), rail.frame.contains(point),
                  let hit = window.hitTest(point, with: nil) else { return false }
            return hit.isDescendant(of: rail.controller.view)
            #endif
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var configuration: ReservedEdgeSwipeView
        weak var marker: MarkerView?
        /// Whether the current touch started on the exposed strip. Set at
        /// every touch-down, so it never outlives its own touch.
        private var trackingEdgeTouch = false

        /// +1 when out from the edge is rightward (the left edge), -1 leftward.
        private var outward: CGFloat { configuration.edge == .leading ? 1 : -1 }
        private var side: String { configuration.edge == .leading ? "left" : "right" }

        private lazy var edgePan: UIScreenEdgePanGestureRecognizer = {
            let recognizer = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            recognizer.edges = configuration.edge == .leading ? .left : .right
            recognizer.maximumNumberOfTouches = 1
            recognizer.delegate = self
            return recognizer
        }()

        private lazy var stripPan: UIPanGestureRecognizer = {
            let recognizer = StandInPan(target: self, action: #selector(handlePan(_:)))
            recognizer.outward = outward
            recognizer.maximumNumberOfTouches = 1
            recognizer.delegate = self
            return recognizer
        }()

        /// The stand-in, saying what holds it back. A pan that is 30pt out
        /// from the edge and has not begun is waiting on, or was failed by,
        /// another recogniser: on Peter's open Duo upright the stand-in saw
        /// the touch on the strip and then neither began nor let it go
        /// (1 November 2026). One line per touch, on the strip only.
        private final class StandInPan: UIPanGestureRecognizer {
            var outward: CGFloat = 1
            private var reported = false

            override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
                super.touchesMoved(touches, with: event)
                guard state == .possible, !reported, let view, translation(in: view).x * outward > 30 else { return }
                reported = true
                RipulLog.log("[EDGESWIPE] stand-in held at \(Int(translation(in: view).x * outward))pt; around it: "
                             + Self.recognizers(around: touches.first?.view, besides: self))
            }

            override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
                RipulLog.log("[EDGESWIPE] touch cancelled while \(state == .possible ? "waiting" : "tracking")")
                super.touchesCancelled(touches, with: event)
            }

            override func reset() {
                super.reset()
                reported = false
            }

            /// Every recogniser from the touched view up that has not failed:
            /// what could be holding this one back.
            static func recognizers(around view: UIView?, besides own: UIGestureRecognizer) -> String {
                var found: [String] = []
                var current = view
                while let view = current {
                    for recognizer in view.gestureRecognizers ?? [] where recognizer !== own && recognizer.state != .failed {
                        found.append("\(type(of: recognizer))[\(recognizer.state.rawValue)] on \(type(of: view))")
                    }
                    current = view.superview
                }
                return found.isEmpty ? "none" : found.joined(separator: ", ")
            }
        }

        init(_ configuration: ReservedEdgeSwipeView) { self.configuration = configuration }

        func attach(to window: UIWindow?) {
            guard edgePan.view !== window else { return }
            edgePan.view?.removeGestureRecognizer(edgePan)
            stripPan.view?.removeGestureRecognizer(stripPan)
            window?.addGestureRecognizer(edgePan)
            window?.addGestureRecognizer(stripPan)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let marker, let window = marker.window, gestureRecognizer.view === window else { return false }
            let point = touch.location(in: window)
            let exposed = marker.isExposed(at: point, in: window)
            let onRail = !exposed && marker.isOnRail(at: point, in: window)
            trackingEdgeTouch = exposed || onRail
            alongside = []
            if trackingEdgeTouch, gestureRecognizer === stripPan {
                RipulLog.log(String(format: "[EDGESWIPE] %@ touch at x=%.0f on the %@", side, point.x, onRail ? "rail" : "strip"))
            }
            return trackingEdgeTouch
        }

        /// A scroll view under the strip waits for the edge swipe to fail, as
        /// UIKit's own Back swipe makes it: a vertical scroll from the strip
        /// starts a few points later. Only for touches that started there.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            Self.isScrolling(otherGestureRecognizer) && trackingEdgeTouch
        }

        /// Nothing else on the strip may fail the swipe back by beginning
        /// first (a drag of the chat's own, a hold): the two run together,
        /// and the swipe back cancels the touches under it once it begins.
        /// The two pans here stay exclusive, and a scroll view waits instead.
        private var alongside: Set<ObjectIdentifier> = []
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            guard trackingEdgeTouch, otherGestureRecognizer !== edgePan, otherGestureRecognizer !== stripPan,
                  !Self.isScrolling(otherGestureRecognizer) else { return false }
            if alongside.insert(ObjectIdentifier(otherGestureRecognizer)).inserted {
                RipulLog.log("[EDGESWIPE] alongside \(type(of: otherGestureRecognizer)) on "
                             + "\(otherGestureRecognizer.view.map { "\(type(of: $0))" } ?? "nothing")")
            }
            return true
        }

        private static func isScrolling(_ recognizer: UIGestureRecognizer) -> Bool {
            recognizer.view is UIScrollView && recognizer is UIPanGestureRecognizer
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === stripPan else { return true }
            // Text selected on the strip moves its handles, as the swipe to
            // reply leaves it; the screen's own edge still swipes back.
            if NativeChatFirstResponder.showsTextSelection() {
                RipulLog.log("[EDGESWIPE] stand-in let go: text is selected")
                return false
            }
            // Out from the edge, as the edge pan's own direction is.
            let velocity = stripPan.velocity(in: stripPan.view)
            guard velocity.x * outward > 0, abs(velocity.x) > abs(velocity.y) else {
                RipulLog.log(String(format: "[EDGESWIPE] stand-in let go: moving %.0f, %.0f", velocity.x, velocity.y))
                return false
            }
            return true
        }

        @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            let offset = min(configuration.maxOffset, max(0, recognizer.translation(in: recognizer.view).x * outward))
            switch recognizer.state {
            case .began:
                RipulLog.log("[EDGESWIPE] \(side) began by the \(recognizer === edgePan ? "edge pan" : "stand-in")")
                configuration.onBegan()
            case .changed:
                configuration.onChanged(offset)
            case .ended:
                RipulLog.log(String(format: "[EDGESWIPE] ended at %.0f", offset))
                configuration.onEnded(offset, recognizer.velocity(in: recognizer.view).x * outward)
            case .cancelled, .failed:
                RipulLog.log("[EDGESWIPE] cancelled")
                configuration.onCancelled()
            default:
                break
            }
        }
    }
}
#endif
