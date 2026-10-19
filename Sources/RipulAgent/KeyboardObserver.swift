#if os(iOS)
import UIKit
import SwiftUI
import Combine
import WebKit

/// Observes keyboard show/hide and publishes the height above the safe area.
public final class KeyboardObserver: ObservableObject {
    /// Keyboard height adjusted for bottom safe area (use for overlay padding).
    @Published public var height: CGFloat = 0
    /// Raw keyboard frame height from screen bottom (use for view frame calculations in views that ignore safe areas).
    @Published public var rawHeight: CGFloat = 0
    /// The keyboard is up for a field in a web page: what has it is inside a
    /// `WKWebView`. Changes with the height, in the same animation, so a screen
    /// that treats a page's keyboard differently moves with the keyboard.
    @Published public var isForWebContent = false

    public init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillShow),
            name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillHide),
            name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    private var bottomSafeArea: CGFloat {
        UIApplication.shared
            .connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?
            .windows.first?
            .safeAreaInsets.bottom ?? 0
    }

    /// Build a SwiftUI animation that matches the system keyboard curve and duration.
    private func keyboardAnimation(from notification: Notification) -> Animation {
        let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval ?? 0.25
        // iOS keyboard uses curve 7 (private). A critically-damped spring is the closest match.
        return .interpolatingSpring(mass: 3, stiffness: 1000, damping: 500, initialVelocity: 0)
            .speed(1.0 / max(0.01, duration / 0.25))
    }

    @objc private func keyboardWillShow(_ notification: Notification) {
        if let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
            // Subtract bottom safe area since the overlay is already positioned above it
            let adjusted = max(0, frame.height - bottomSafeArea)
            let animation = keyboardAnimation(from: notification)
            DispatchQueue.main.async {
                // Asked a turn after the announcement, once the field that
                // asked for the keyboard holds focus.
                let forWebContent = Self.webViewHasFocus()
                // willShow repeats with an identical frame on focus hops, the
                // predictive bar and first-responder changes; don't publish
                // those, unless the hop was between a page and a native field.
                guard self.height != adjusted || self.rawHeight != frame.height
                        || self.isForWebContent != forWebContent else { return }
                withAnimation(animation) {
                    self.height = adjusted
                    self.rawHeight = frame.height
                    self.isForWebContent = forWebContent
                }
            }
        }
    }

    /// How everything raised above the keyboard comes back down with it:
    /// fast initial travel, then a long gentle settle at the end.
    public static let hideAnimation = Animation.timingCurve(0.05, 0.7, 0.1, 1.0, duration: 0.45)

    @objc private func keyboardWillHide(_ notification: Notification) {
        DispatchQueue.main.async {
            guard self.height != 0 || self.rawHeight != 0 || self.isForWebContent else { return }
            withAnimation(Self.hideAnimation) {
                self.height = 0
                self.rawHeight = 0
                self.isForWebContent = false
            }
        }
    }

    /// Whether a field in a web page has focus: WebKit's content view, inside
    /// a `WKWebView`, is the first responder. Looked for in every window's
    /// views rather than through the responder chain, which starts from the
    /// key window: which window is key does not decide it.
    private static func webViewHasFocus() -> Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .contains(where: containsFocusedWebView)
    }

    private static func containsFocusedWebView(_ view: UIView) -> Bool {
        if view is WKWebView { return containsFirstResponder(view) }
        return view.subviews.contains(where: containsFocusedWebView)
    }

    private static func containsFirstResponder(_ view: UIView) -> Bool {
        view.isFirstResponder || view.subviews.contains(where: containsFirstResponder)
    }
}
#endif // os(iOS)
