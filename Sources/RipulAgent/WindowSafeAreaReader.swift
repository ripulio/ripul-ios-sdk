#if os(iOS)
import SwiftUI
import UIKit

/// Reports the hosting **window's** top safe-area inset into SwiftUI state.
///
/// Mount as a `.background` anywhere in the hierarchy; position is irrelevant
/// because it reads `window.safeAreaInsets`, not its own. That window-level
/// value is the point: floating top bars that pin themselves to the physical
/// top can't trust the inset the hierarchy hands them (ancestors consume or
/// zero it — the original under-the-notch lozenge bug), and they must not ask
/// `UIApplication`/`UIWindow` during `body` either: `UIWindow.safeAreaInsets`
/// computes status-bar visibility, which queries a SwiftUI preference, which
/// synchronously re-enters the in-flight body evaluation — in Debug builds one
/// nested pass overflows the main-thread stack (deterministic launch crash,
/// ___chkstk_darwin SIGSEGV).
///
/// This reader threads that needle: UIKit callbacks (`didMoveToWindow`,
/// `safeAreaInsetsDidChange`, `layoutSubviews` for rotation) schedule a plain
/// main-queue async read + report, so the window is never touched inside a
/// SwiftUI update transaction and the state write never lands mid-update.
struct WindowSafeAreaTopReader: UIViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.onChange = onChange
        return view
    }

    func updateUIView(_ uiView: ReaderView, context: Context) {
        uiView.onChange = onChange
    }

    final class ReaderView: UIView {
        var onChange: ((CGFloat) -> Void)?
        private var lastReported: CGFloat?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            scheduleReport()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            scheduleReport()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            scheduleReport()
        }

        private func scheduleReport() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                let top = window.safeAreaInsets.top
                guard top != self.lastReported else { return }
                self.lastReported = top
                self.onChange?(top)
            }
        }
    }
}

/// Public face of `WindowSafeAreaTopReader` for hosts that build their own
/// floating bars (the first-party Agents|Plans root bar). Mount as a
/// `.background` and pad by the reported value — a `GeometryReader`'s
/// `safeAreaInsets` at those levels reads zero because ancestors consume the
/// region (the trap documented on the reader above).
public struct WindowSafeAreaTop: View {
    let onChange: (CGFloat) -> Void

    public init(onChange: @escaping (CGFloat) -> Void) {
        self.onChange = onChange
    }

    public var body: some View {
        WindowSafeAreaTopReader(onChange: onChange)
    }
}
#endif
