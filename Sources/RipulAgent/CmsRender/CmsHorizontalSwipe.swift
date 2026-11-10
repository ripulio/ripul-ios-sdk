import SwiftUI
#if os(iOS)
import UIKit
#endif

/// A horizontal pager's drag inside a vertical scroll, split the way iOS
/// splits it: a drag that starts mostly horizontal is the pager's (and the
/// scroll view's pan waits for it), one that starts mostly vertical never
/// begins, so the page scrolls. Taps on what is inside are unchanged.
///
/// On iOS a SwiftUI `DragGesture` inside a `ScrollView`, even a simultaneous
/// one, kept a vertical drag that started on it from scrolling the page, so
/// the drag is a `UIPanGestureRecognizer` on the enclosing scroll view (or
/// the hosting view), limited to this view's bounds.
struct CmsHorizontalSwipe: ViewModifier {
    let changed: (CGSize) -> Void
    let ended: (CGSize) -> Void
    @Environment(\.cmsPinnedCover) private var cover

    func body(content: Content) -> some View {
        #if os(iOS)
        content.background(CmsHorizontalPanProbe(changed: changed, ended: ended, cover: cover))
        #else
        content.simultaneousGesture(
            DragGesture(minimumDistance: 10)
                .onChanged { changed($0.translation) }
                .onEnded { ended($0.translation) }
        )
        #endif
    }

    /// Whether a drag starting at `y` (scroll content points, the page
    /// scrolled by `scrolled`) is on the uncovered part of a pinned block.
    static func uncovered(_ y: CGFloat, cover: CmsPinnedCover?, scrolled: CGFloat) -> Bool {
        guard let cover else { return true }
        let kept = cover.keepTop.map { $0 + scrolled } ?? -.infinity
        return y < max(cover.coverTop, kept)
    }

    /// Whether a drag starting with this velocity is the pager's.
    static func isHorizontal(_ velocity: CGPoint) -> Bool {
        abs(velocity.x) > abs(velocity.y)
    }
}

#if os(iOS)
private struct CmsHorizontalPanProbe: UIViewRepresentable {
    let changed: (CGSize) -> Void
    let ended: (CGSize) -> Void
    let cover: CmsPinnedCover?

    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.isUserInteractionEnabled = false
        probe.isAccessibilityElement = false
        probe.changed = changed
        probe.ended = ended
        probe.cover = cover
        return probe
    }

    func updateUIView(_ probe: Probe, context: Context) {
        probe.changed = changed
        probe.ended = ended
        probe.cover = cover
    }

    static func dismantleUIView(_ probe: Probe, coordinator: ()) { probe.detach() }

    final class Probe: UIView {
        var changed: ((CGSize) -> Void)?
        var ended: ((CGSize) -> Void)?
        var cover: CmsPinnedCover?
        private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
        /// The pan's delegate, a separate object: a UIView subclass that
        /// answered `gestureRecognizerShouldBegin` itself would also be asked
        /// about other gestures (UIKit asks a view under the touch), and its
        /// "no" stopped the page's edge swipe from starting over a calendar.
        private lazy var rules = Rules(probe: self)
        fileprivate weak var host: UIView?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { detach(); return }
            // The nearest scroll view takes the touches over this view; with
            // none, the topmost view below the window does.
            var view = superview
            var top = superview
            while let current = view, !(current is UIScrollView) {
                if current.superview is UIWindow || current.superview == nil { top = current }
                view = current.superview
            }
            guard let target = view ?? top, target !== host else { return }
            detach()
            pan.delegate = rules
            pan.cancelsTouchesInView = true
            target.addGestureRecognizer(pan)
            host = target
        }

        func detach() {
            host?.removeGestureRecognizer(pan)
            host = nil
        }

        @objc private func handle(_ pan: UIPanGestureRecognizer) {
            let t = pan.translation(in: self)
            let size = CGSize(width: t.x, height: t.y)
            switch pan.state {
            case .changed: changed?(size)
            case .ended, .cancelled, .failed: ended?(size)
            default: break
            }
        }

        /// Only a drag that starts on this view, mostly sideways, and (in a
        /// pinned block) where the page doesn't cover it.
        fileprivate func shouldBegin(_ pan: UIPanGestureRecognizer) -> Bool {
            guard window != nil, !isHidden else { return false }
            guard bounds.contains(pan.location(in: self)) else { return false }
            if let scroll = host as? UIScrollView,
               !CmsHorizontalSwipe.uncovered(pan.location(in: scroll).y, cover: cover,
                                             scrolled: scroll.contentOffset.y + scroll.adjustedContentInset.top) {
                return false
            }
            return CmsHorizontalSwipe.isHorizontal(pan.velocity(in: self))
        }
    }

    final class Rules: NSObject, UIGestureRecognizerDelegate {
        weak var probe: Probe?
        init(probe: Probe) { self.probe = probe }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let probe, let pan = recognizer as? UIPanGestureRecognizer else { return false }
            return probe.shouldBegin(pan)
        }

        // The scroll view's pan waits for this one, so a sideways drag never
        // nudges the page; a vertical one fails this at once and scrolls.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            guard let scroll = probe?.host as? UIScrollView else { return false }
            return other === scroll.panGestureRecognizer
        }
    }
}
#endif
