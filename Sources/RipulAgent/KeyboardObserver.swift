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
        // Once the keyboard has finished moving, the window has finished any turn:
        // a frame that could not be read against it as it was announced is read now.
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardDidChange),
            name: UIResponder.keyboardDidShowNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardDidChange),
            name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
    }

    /// How much of a keyboard frame (screen coordinates, as notifications carry it)
    /// covers the app's window. Nil when the frame is laid out for the other way up:
    /// a turn of the phone announces the keyboard for the coming orientation while
    /// the window still has the old one, so the frame cannot be read against it
    /// yet. A keyboard that ends below the window (none showing, or a hardware
    /// keyboard's) covers nothing.
    ///
    /// The whole frame's height used to be taken as the keyboard's, so the
    /// announcement that came with each turn of the open Duo lifted the chat by a
    /// keyboard's height before the turn began, and dropped it again after (Peter,
    /// 6 and 7 November 2026: "the composer jumps up into the chat before the
    /// rotation starts").
    @MainActor
    static func coveredHeight(of frame: CGRect) -> CGFloat? {
        guard let window = RipulChrome.appWindow() else { return frame.height }
        let inWindow = window.convert(frame, from: window.screen.coordinateSpace)
        let bounds = window.bounds
        if abs(inWindow.width - bounds.width) > 1, abs(inWindow.width - bounds.height) <= 1 { return nil }
        let covered = inWindow.intersection(bounds)
        return covered.isNull ? 0 : max(0, covered.height)
    }

    @MainActor
    private static func describe(_ frame: CGRect) -> String {
        let window = RipulChrome.appWindow()?.bounds.size ?? .zero
        return "end=\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height)) "
            + "window=\(Int(window.width))x\(Int(window.height))"
    }

    /// Publish the keyboard covering `covered` points of the window.
    private func publish(covered: CGFloat, animation: Animation?) {
        // Asked a turn after the announcement, once the field that asked for
        // the keyboard holds focus.
        let forWebContent = covered > 0 && Self.webViewHasFocus()
        // Subtract bottom safe area since the overlay is already positioned above it
        let adjusted = max(0, covered - bottomSafeArea)
        // willShow repeats with an identical frame on focus hops, the predictive
        // bar and first-responder changes; don't publish those, unless the hop
        // was between a page and a native field.
        guard height != adjusted || rawHeight != covered || isForWebContent != forWebContent else { return }
        withAnimation(animation) {
            height = adjusted
            rawHeight = covered
            isForWebContent = forWebContent
        }
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
        guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let animation = keyboardAnimation(from: notification)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let covered = Self.coveredHeight(of: frame) else {
                    // For the coming orientation: read when the keyboard has moved.
                    ChatSlideProbe.mark("keyboard willShow, other way up: \(Self.describe(frame))")
                    return
                }
                ChatSlideProbe.mark("keyboard willShow covers \(Int(covered)): \(Self.describe(frame))")
                self.publish(covered: covered, animation: animation)
            }
        }
    }

    /// The keyboard has finished moving (shown, or a new frame after a turn).
    @objc private func keyboardDidChange(_ notification: Notification) {
        guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let covered = Self.coveredHeight(of: frame), covered != self.rawHeight else { return }
                ChatSlideProbe.mark("keyboard settled covers \(Int(covered)): \(Self.describe(frame))")
                self.publish(covered: covered, animation: covered > 0 ? .easeOut(duration: 0.2) : Self.hideAnimation)
            }
        }
    }

    /// How everything raised above the keyboard comes back down with it:
    /// fast initial travel, then a long gentle settle at the end.
    public static let hideAnimation = Animation.timingCurve(0.05, 0.7, 0.1, 1.0, duration: 0.45)

    @objc private func keyboardWillHide(_ notification: Notification) {
        DispatchQueue.main.async {
            ChatSlideProbe.mark("keyboard willHide (was \(Int(self.rawHeight)))")
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
