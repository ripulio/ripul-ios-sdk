#if canImport(UIKit)
import UIKit

// MARK: - Typing

/// Typing from a Live View viewer, into whatever has the keyboard here. This
/// device's keyboard is the system's: it is in no picture of the app and no
/// touch made in the app reaches it, so the viewer types on its own keyboard
/// and the characters arrive here.
@MainActor
enum LiveStreamTyping {
    /// Whatever has the keyboard.
    static func focused() -> UIResponder? {
        LiveStreamFocus.found = nil
        UIApplication.shared.sendAction(#selector(UIResponder.liveStreamSayFocused), to: nil, from: nil, for: nil)
        return LiveStreamFocus.found
    }

    /// `keyboard`'s payload: whether it is up, and the kind the field asks for.
    static func keyboard(visible: Bool) -> Data {
        var say: [String: Any] = ["visible": visible]
        if visible, let traits = focused() as? UITextInputTraits {
            if let type = traits.keyboardType { say["type"] = type.rawValue }
            if let key = traits.returnKeyType { say["returnKey"] = key.rawValue }
            if let secure = traits.isSecureTextEntry { say["secure"] = secure }
        }
        return (try? JSONSerialization.data(withJSONObject: say)) ?? Data("{}".utf8)
    }

    /// `key`'s payload: {insert?, delete?, return?, dismiss?}.
    static func apply(_ key: [String: Any]) {
        if key["dismiss"] as? Bool == true {
            ScreenElementFinder.hostWindow()?.endEditing(true)
            return
        }
        guard let responder = focused(), let input = responder as? UIKeyInput else { return }
        if let count = (key["delete"] as? NSNumber)?.intValue {
            for _ in 0..<min(max(count, 0), 500) where input.hasText { input.deleteBackward() }
        }
        if let text = key["insert"] as? String, !text.isEmpty, text.count <= 4_000 {
            input.insertText(text)
        }
        if key["return"] as? Bool == true { pressReturn(on: responder, input) }
        ScreenSnapshotStore.shared.invalidate()
    }

    /// Return as the keyboard's own key does it: a text field asks its
    /// delegate and ends editing on exit (SwiftUI's onSubmit hangs off that);
    /// anything else gets a new line.
    private static func pressReturn(on responder: UIResponder, _ input: UIKeyInput) {
        if let field = responder as? UITextField {
            if field.delegate?.textFieldShouldReturn?(field) ?? true {
                field.sendActions(for: .editingDidEndOnExit)
            }
        } else {
            input.insertText("\n")
        }
    }
}

private enum LiveStreamFocus {
    @MainActor static weak var found: UIResponder?
}

extension UIResponder {
    /// Sent to nil, this lands on the first responder.
    @objc fileprivate func liveStreamSayFocused() {
        MainActor.assumeIsolated { LiveStreamFocus.found = self }
    }
}

// MARK: - To the top

/// What a tap on the status bar does: the screen's scroll view goes to its
/// top. The status bar is the system's, so a touch made in the app can't
/// tap it; the viewer asks for this instead.
@MainActor
enum LiveStreamScrollToTop {
    static func perform(in window: UIWindow) {
        var candidates: [UIScrollView] = []
        func collect(_ view: UIView, depth: Int) {
            guard depth < 80, !view.isHidden, view.alpha > 0.01 else { return }
            if let scroll = view as? UIScrollView, scroll.scrollsToTop, scroll.isScrollEnabled,
               scroll.contentSize.height > scroll.bounds.height,
               window.bounds.intersects(scroll.convert(scroll.bounds, to: window)) {
                candidates.append(scroll)
            }
            for sub in view.subviews { collect(sub, depth: depth + 1) }
        }
        collect(window, depth: 0)
        // The system acts only when one scroll view claims it; when several
        // do, take the one that fills the most of the screen.
        guard let scroll = candidates.max(by: { area($0, in: window) < area($1, in: window) }) else { return }
        if scroll.delegate?.scrollViewShouldScrollToTop?(scroll) == false { return }
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: -scroll.adjustedContentInset.top), animated: true)
        ScreenSnapshotStore.shared.invalidate()
    }

    private static func area(_ scroll: UIScrollView, in window: UIWindow) -> CGFloat {
        let shown = scroll.convert(scroll.bounds, to: window).intersection(window.bounds)
        return shown.isNull ? 0 : shown.width * shown.height
    }
}
#endif
