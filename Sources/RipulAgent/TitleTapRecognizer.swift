#if os(iOS) && !targetEnvironment(macCatalyst)
import SwiftUI
import UIKit

/// The title's single and double taps as one UIKit tap recognizer, which the
/// window's own tap recognizers wait for. Used by `TitleTapGestures`.
///
/// A window holding a scroll view that scrolls to the top keeps its top 64
/// points as UIKit's tap-to-scroll-to-top region: the status bar's tap, moved
/// into the window. UIKit adds it as the scroll view joins the window
/// (`-[UIWindow _addWindowTopTapRegion]`, measured on iOS 27.0 and 27.1, 31
/// October 2026). Its recognizer takes every touch in that band that is not on
/// a UIControl and never shares one with another gesture, so a SwiftUI tap
/// gesture there never fires. An ordinary iPhone's bar starts below the band.
/// The iPhone Duo's does not: its cover has no top inset (the camera is at the
/// side), and on the open display the row joins the camera's band. So the
/// chat's title panel stayed open and ignored every tap on Peter's Duo.
///
/// No SwiftUI gesture can make another wait for it, and a UIKit recognizer
/// can: every recognizer that an interaction on the window owns waits for this
/// one. A tap anywhere else in the band still scrolls to the top.
///
/// One recognizer, not a double tap the single must wait for: UIKit's pair
/// would be two SwiftUI gestures on one view, ordered by SwiftUI rather than
/// by each other. The double is told apart here instead: a second tap close
/// to the first, within the interval, is a double and the single never fires.
@available(iOS 18.0, *)
struct TitleTapRecognizer: UIGestureRecognizerRepresentable {
    let onTap: (() -> Void)?
    let onDoubleTap: (() -> Void)?

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UITapGestureRecognizer {
        let tap = UITapGestureRecognizer()
        tap.name = "TitleTapRecognizer"
        tap.delegate = context.coordinator
        return tap
    }

    func updateUIGestureRecognizer(_ recognizer: UITapGestureRecognizer, context: Context) {
        context.coordinator.onTap = onTap
        context.coordinator.onDoubleTap = onDoubleTap
    }

    func handleUIGestureRecognizerAction(_ recognizer: UITapGestureRecognizer, context: Context) {
        guard recognizer.state == .ended else { return }
        context.coordinator.tapped(at: recognizer.location(in: nil))
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onTap: (() -> Void)?
        var onDoubleTap: (() -> Void)?
        /// The first tap, until a second has had time to make it a double.
        private var pending: (location: CGPoint, single: DispatchWorkItem)?
        /// How long the single tap waits for a second: the double-tap interval
        /// UIKit's own recognizers use.
        static let doubleTapInterval: TimeInterval = 0.35
        /// How far apart the two taps of a double may land.
        static let doubleTapReach: CGFloat = 40

        func tapped(at location: CGPoint) {
            if let first = pending,
               hypot(first.location.x - location.x, first.location.y - location.y) <= Self.doubleTapReach {
                first.single.cancel()
                pending = nil
                onDoubleTap?()
                return
            }
            pending?.single.cancel()
            pending = nil
            // Nothing to wait for: the single tap is the only one.
            guard onDoubleTap != nil else {
                onTap?()
                return
            }
            let single = DispatchWorkItem { [weak self] in
                self?.pending = nil
                self?.onTap?()
            }
            pending = (location, single)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.doubleTapInterval, execute: single)
        }

        /// The window's interaction-owned recognizers (the scroll-to-top
        /// region's among them) wait for the title's tap to fail.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            other.view is UIWindow && other.delegate is UIInteraction
        }
    }
}
#endif
