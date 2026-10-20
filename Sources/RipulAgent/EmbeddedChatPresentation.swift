import Foundation
import CoreGraphics

public enum EmbeddedChatPresentation: String, Sendable {
    case fullscreen
    case floating
}

/// Input is the container's available rectangle, after safe-area and keyboard
/// avoidance. Never guesses a phone's screen size or assumes symmetric insets.
public enum EmbeddedChatLayout {
    public static func frame(in available: CGRect, presentation: EmbeddedChatPresentation) -> CGRect {
        guard available.width > 0, available.height > 0 else { return .zero }
        guard presentation == .floating else { return available }
        let margin = min(12, min(available.width, available.height) / 4)
        let width = min(420, max(0, available.width - margin * 2))
        let height = min(640, max(0, available.height - margin * 2), available.height * 0.78)
        return CGRect(x: available.maxX - margin - width, y: available.maxY - margin - height, width: width, height: height)
    }
}
