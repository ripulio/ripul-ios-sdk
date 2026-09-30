import SwiftUI

public extension View {
    /// A tap anywhere outside a text field ends editing and lowers the
    /// keyboard. The tap still reaches whatever was under it — a row, a
    /// button, empty space — so nothing else changes.
    ///
    /// On iPhone the keyboard covers half the screen. Leaving a field must
    /// never depend on moving focus to another field or finding Return:
    /// tapping away is how people expect to put the keyboard down. Apply this
    /// to any screen or sheet with a text field. `scrollDismissesKeyboard`
    /// only covers scrolling, and `onTapGesture` on a list misses its rows.
    func dismissesKeyboardOnTapAway() -> some View {
        #if os(iOS)
        background(TapAwayInstaller())
        #else
        self
        #endif
    }
}

#if os(iOS)
/// Installs one tap recognizer on the hosting window while the view is on
/// screen. Window-level so taps on rows, headers and empty space all count;
/// it never cancels or delays the touch it observes.
private struct TapAwayInstaller: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> InstallerView {
        let view = InstallerView()
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }
    func updateUIView(_ uiView: InstallerView, context: Context) {}
    static func dismantleUIView(_ uiView: InstallerView, coordinator: Coordinator) { coordinator.attach(to: nil) }

    final class InstallerView: UIView {
        weak var coordinator: Coordinator?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator?.attach(to: window)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var window: UIWindow?
        private lazy var recognizer: UITapGestureRecognizer = {
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
            tap.cancelsTouchesInView = false
            tap.delaysTouchesEnded = false
            tap.delegate = self
            return tap
        }()

        func attach(to window: UIWindow?) {
            guard window !== self.window else { return }
            self.window?.removeGestureRecognizer(recognizer)
            self.window = window
            window?.addGestureRecognizer(recognizer)
        }

        @objc private func tapped() { window?.endEditing(true) }

        /// Taps in a field (including a search field) are for editing it.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view {
                if current is UITextField || current is UITextView { return false }
                view = current.superview
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}
#endif
