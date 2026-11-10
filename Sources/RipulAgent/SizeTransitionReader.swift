#if os(iOS)
import SwiftUI
import UIKit

/// The size the window is about to become, told before the system lays
/// anything out at that size.
///
/// A turn of the phone is an animated change of the window's size. UIKit calls
/// `viewWillTransition(to:with:)` first, then resizes the window and lays it
/// out inside the turn's animation. Apple's guidance for the iPhone Duo is to
/// do size-dependent work there. A decision a view stores from
/// `onGeometryChange` arrives one layout too late: SwiftUI lays the whole
/// screen out at the new size with the old decision, the measurement changes
/// the state, and it lays it out again before the first frame can be shown.
/// On the open Duo each of those layouts cost 150 to 350 ms, and iOS shows the
/// old frame stretched while they run (6 November 2026,
/// docs/plans/one-step-rotation.md).
///
/// A view that already measures itself keeps measuring. This only lets it set
/// the value it is about to measure, so the measurement finds it equal and
/// changes nothing. When a prediction is wrong the measurement corrects it, as
/// it always did.
///
/// The closure gets the window's size now and the size it is becoming. A
/// controller in a container receives its container's size, which for the
/// app's full-window containers is the window's.
///
/// `init(onTransition:)` is the same, and its closure can return another to
/// be called when that transition has completed: after its animation, or on
/// the next turn of the main queue where there is none to wait for. Each one
/// returned is called once.
public struct SizeTransitionReader: UIViewControllerRepresentable {
    let onTransition: (_ current: CGSize, _ new: CGSize) -> (() -> Void)?

    public init(onWillTransition: @escaping (_ current: CGSize, _ new: CGSize) -> Void) {
        onTransition = { current, new in
            onWillTransition(current, new)
            return nil
        }
    }

    public init(onTransition: @escaping (_ current: CGSize, _ new: CGSize) -> (() -> Void)?) {
        self.onTransition = onTransition
    }

    public func makeUIViewController(context: Context) -> Controller {
        Controller(onTransition: onTransition)
    }

    public func updateUIViewController(_ controller: Controller, context: Context) {
        controller.onTransition = onTransition
    }

    public final class Controller: UIViewController {
        var onTransition: (CGSize, CGSize) -> (() -> Void)?

        init(onTransition: @escaping (CGSize, CGSize) -> (() -> Void)?) {
            self.onTransition = onTransition
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        public override func loadView() {
            let view = UIView()
            view.isUserInteractionEnabled = false
            view.isHidden = true
            self.view = view
        }

        public override func viewWillTransition(to size: CGSize,
                                                with coordinator: any UIViewControllerTransitionCoordinator) {
            super.viewWillTransition(to: size, with: coordinator)
            // Off screen (a tab not shown), there is nothing of ours to lay out.
            guard let window = viewIfLoaded?.window else { return }
            let current = window.bounds.size
            guard size != current, size.width > 0, size.height > 0 else { return }
            guard let ended = onTransition(current, size) else { return }
            // Held by the coordinator, so the transition that began is told it
            // ended even should this controller go first.
            if !coordinator.animate(alongsideTransition: nil, completion: { _ in ended() }) {
                DispatchQueue.main.async { ended() }
            }
        }
    }
}
#endif
