#if canImport(UIKit)
import UIKit

/// When a finger last touched the app's window, for main-thread work that
/// should wait until nobody is touching it. The switcher's picture of a screen
/// draws the whole window on the main thread, 70-220 ms on Peter's Duo
/// (5 November 2026): taken while a finger is down or a list is still moving
/// from a fling, that is a frozen scroll (docs/main-thread.md).
@MainActor
public enum TouchActivity {
    public private(set) static var lastTouchAt: CFTimeInterval = 0
    public private(set) static var touchesDown = 0

    /// No finger on the window, and none for `quietFor` seconds: long enough
    /// for a fling's list to come to rest.
    public static func isQuiet(for quietFor: CFTimeInterval = 1.5) -> Bool {
        touchesDown == 0 && CACurrentMediaTime() - lastTouchAt > quietFor
    }

    /// Watches `window`'s touches, once per window. Takes none of them.
    public static func watch(_ window: UIWindow?) {
        guard let window, !(window.gestureRecognizers ?? []).contains(where: { $0 is Watcher }) else { return }
        window.addGestureRecognizer(Watcher())
    }

    private final class Watcher: UIGestureRecognizer {
        private var down = 0

        init() {
            super.init(target: nil, action: nil)
            name = "TouchActivity.watcher"
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            down += touches.count
            note()
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { note() }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches) }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches) }

        override func reset() {
            down = 0
            note()
        }

        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }

        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

        private func lift(_ touches: Set<UITouch>) {
            down = max(0, down - touches.count)
            note()
            // Never recognises: done with this sequence once the last finger is up.
            if down == 0 { state = .failed }
        }

        private func note() {
            TouchActivity.touchesDown = down
            TouchActivity.lastTouchAt = CACurrentMediaTime()
        }
    }
}
#endif
