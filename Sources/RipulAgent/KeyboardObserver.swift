#if os(iOS)
import UIKit
import SwiftUI
import Combine

/// Observes keyboard show/hide and publishes the height above the safe area.
public final class KeyboardObserver: ObservableObject {
    /// Keyboard height adjusted for bottom safe area (use for overlay padding).
    @Published public var height: CGFloat = 0
    /// Raw keyboard frame height from screen bottom (use for view frame calculations in views that ignore safe areas).
    @Published public var rawHeight: CGFloat = 0

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
                withAnimation(animation) {
                    self.height = adjusted
                    self.rawHeight = frame.height
                }
            }
        }
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        // Fast initial travel then long gentle settle at the end
        let animation = Animation.timingCurve(0.05, 0.7, 0.1, 1.0, duration: 0.45)
        DispatchQueue.main.async {
            withAnimation(animation) {
                self.height = 0
                self.rawHeight = 0
            }
        }
    }
}
#endif // os(iOS)
