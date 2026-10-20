import Foundation
import CoreGraphics

@main
struct Checks {
    static func main() {
        // Rectangles already account for the notch, asymmetric landscape sides,
        // tab bar and keyboard. Floating controls must remain inside all of them.
        let available: [CGRect] = [
            CGRect(x: 0, y: 62, width: 430, height: 836),
            CGRect(x: 62, y: 0, width: 840, height: 396),
            CGRect(x: 0, y: 62, width: 430, height: 430),
            CGRect(x: 40, y: 20, width: 320, height: 200),
            CGRect(x: 0, y: 0, width: 120, height: 60),
            CGRect(x: 80, y: 60, width: 1000, height: 1000),
        ]
        for rect in available {
            precondition(EmbeddedChatLayout.frame(in: rect, presentation: .fullscreen) == rect)
            let floating = EmbeddedChatLayout.frame(in: rect, presentation: .floating)
            precondition(rect.contains(floating))
            precondition(floating.width <= 420 && floating.height <= 640)
            precondition(floating.width > 0 && floating.height > 0)
            precondition(floating.maxX < rect.maxX && floating.maxY < rect.maxY)
        }
        precondition(EmbeddedChatLayout.frame(in: .zero, presentation: .floating) == .zero)
        precondition(EmbeddedChatPresentation(rawValue: "unknown") == nil)
        print("PASS: full-screen/floating geometry, compact and keyboard-sized bounds, asymmetric insets, unset/invalid modes")
    }
}
