import UIKit
import Combine

/// Observes keyboard show/hide and publishes the height above the safe area.
public final class KeyboardObserver: ObservableObject {
    @Published public var height: CGFloat = 0

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

    @objc private func keyboardWillShow(_ notification: Notification) {
        if let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
            // Subtract bottom safe area since the overlay is already positioned above it
            let adjusted = max(0, frame.height - bottomSafeArea)
            DispatchQueue.main.async { self.height = adjusted }
        }
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        DispatchQueue.main.async { self.height = 0 }
    }
}
