#if os(iOS)
import SwiftUI
import UIKit

/// The window's first responder, by the public route: an action sent to no
/// target goes to it.
@MainActor
enum NativeChatFirstResponder {
    private static weak var found: UIResponder?

    static func current() -> UIResponder? {
        found = nil
        UIApplication.shared.sendAction(#selector(UIResponder.ripulNativeChatCaptureFirstResponder(_:)), to: nil, from: nil, for: nil)
        return found
    }

    /// Text is selected in place: until the selection is dismissed, a drag is
    /// not a swipe. SwiftUI makes its selection view first responder and gives
    /// the range through UITextInput; it stays first responder after the
    /// selection goes, so the range is what tells (measured 27 Oct 2026). An
    /// editable field (the composer) is not a selection in the chat.
    static func showsTextSelection() -> Bool {
        guard let responder = current(), let input = responder as? UITextInput,
              !(responder is UITextField), !((responder as? UITextView)?.isEditable ?? false),
              let range = input.selectedTextRange else { return false }
        return !range.isEmpty
    }

    fileprivate static func capture(_ responder: UIResponder) { found = responder }
}

extension UIResponder {
    @objc fileprivate func ripulNativeChatCaptureFirstResponder(_ sender: Any?) {
        NativeChatFirstResponder.capture(self)
    }
}

@available(iOS 18.0, *)
struct NativeReplySwipeGesture: UIGestureRecognizerRepresentable {
    let onChanged: (CGFloat) -> Void
    /// Only a completed gesture may send a reply; cancellation still resets it.
    let onEnded: (_ shouldTrigger: Bool) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.name = "NativeChat.replySwipe"
        // One finger. Two fingers sideways move between screens
        // (ScreenSwitcherTwoFingerSwipe), and this pan recognises beside
        // everything, so with two it would slide the message as well.
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        handleAction(recognizer)
    }

    func handleAction(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed:
            onChanged(recognizer.translation(in: recognizer.view).x)
        case .ended:
            onEnded(true)
        case .cancelled, .failed:
            onEnded(false)
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var touchedView: UIView?

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            // A swipe that starts on the strip along the left edge is the
            // chat's swipe back, never a reply (Peter, 1 November 2026).
            if ReservedEdgeSwipeView.reserves(touch) { return false }
            touchedView = touch.view
            // Decide at touch-down, before the bubble moves or arms a reply.
            // A table/code scroller owns its drag even at either scroll limit;
            // never hand an edge bounce over to swipe-to-reply.
            var ancestor = touch.view
            while let view = ancestor {
                if let scroll = view as? UIScrollView,
                   scroll.isScrollEnabled, scroll.panGestureRecognizer.isEnabled {
                    let inset = scroll.adjustedContentInset
                    let horizontalExtent = scroll.contentSize.width + inset.left + inset.right
                    if scroll.alwaysBounceHorizontal || horizontalExtent > scroll.bounds.width + 1 {
                        return false
                    }
                }
                if view === gestureRecognizer.view { break }
                ancestor = view.superview
            }
            return true
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            if isSelectingText(besides: pan) || NativeChatFirstResponder.showsTextSelection() { return false }
            #if !targetEnvironment(macCatalyst)
            // Two fingers sideways move between screens. With one on each of
            // two messages, each message's pan sees a single finger.
            if TwoFingerSwipeRecognizer.isReadingPair(in: pan.view?.window) { return false }
            #endif
            let moved = pan.translation(in: pan.view)
            return moved.x > 0 && abs(moved.x) > abs(moved.y) * 1.6
        }

        /// A drag that is selecting text in place is the selection's (Peter, 27 Oct
        /// 2026: extending a selection slid the bubble to reply). Selecting starts
        /// with a long press and a handle is dragged, so by the time this pan would
        /// begin, a long press or another drag already holds the touch. A scroll
        /// view's own pan is not one: the chat scrolls under every swipe.
        private func isSelectingText(besides pan: UIGestureRecognizer) -> Bool {
            var view = touchedView
            while let current = view {
                for other in current.gestureRecognizers ?? [] where other !== pan {
                    guard other.state == .began || other.state == .changed,
                          other is UILongPressGestureRecognizer || other is UIPanGestureRecognizer else { continue }
                    if let scroll = current as? UIScrollView, other === scroll.panGestureRecognizer { continue }
                    return true
                }
                view = current.superview
            }
            return false
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
#endif
