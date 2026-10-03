import Foundation
import CoreGraphics

/// Keep the embedded slot's displayed height in step with the native controls.
/// Reporting the final height immediately makes the surrounding chat jump
/// while SwiftUI is still animating.
struct NativeInteractionHeightTransition {
  static let duration: TimeInterval = 0.5
  private var target: CGSize?
  private var startHeight: CGFloat = 0
  private var startedAt: TimeInterval = 0

  mutating func update(target next: CGSize, at time: TimeInterval, animated: Bool) {
    guard let previous = target, previous.width == next.width, animated else {
      target = next
      startHeight = next.height
      startedAt = time
      return
    }
    // Remeasuring an unchanged destination must not restart the transition.
    guard abs(previous.height - next.height) > 0.5 else { return }
    startHeight = size(at: time).height
    target = next
    startedAt = time
  }

  func size(at time: TimeInterval) -> CGSize {
    guard let target else { return .zero }
    let progress = min(1, max(0, (time - startedAt) / Self.duration))
    // Matches SwiftUI's timingCurve(1/3, 0, 2/3, 1): x is linear, y is smoothstep.
    let eased = progress * progress * (3 - 2 * progress)
    return CGSize(width: target.width, height: startHeight + (target.height - startHeight) * eased)
  }

  func isAnimating(at time: TimeInterval) -> Bool {
    guard let target else { return false }
    return startHeight != target.height && time < startedAt + Self.duration
  }
}
