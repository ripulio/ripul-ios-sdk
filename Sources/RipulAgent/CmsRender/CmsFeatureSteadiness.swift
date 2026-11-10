import CoreGraphics
import QuartzCore

/// The tab bar feature disc's rule for jumps (CmsTabBarFeatureSlotTracker.steady):
/// a place more than `threshold` from the one shown is followed only once it
/// has held, within 2 pt, for `hold` seconds. On each tab change UIKit hands
/// back a mid-update place for about 33 ms (x 201 → 180 and y 822 → 31, then
/// back, on iOS 27.0, 31 October 2026), which made the disc flick left on
/// Peter's phone. Smooth movement (the bar minimizing, the accessory) passes
/// at once; a real jump (rotation, a new size) `hold` later.
struct CmsFeatureSteadiness {
    static let threshold: CGFloat = 12
    static let hold: CFTimeInterval = 0.08

    private var pending: CGPoint?
    private var since: CFTimeInterval = 0

    /// `accept`: show `place`. `waiting`: a jump is held; read again shortly.
    mutating func next(_ place: CGPoint, shown: CGPoint?, now: CFTimeInterval) -> (accept: Bool, waiting: Bool) {
        guard let shown, hypot(place.x - shown.x, place.y - shown.y) > Self.threshold else {
            pending = nil
            return (true, false)
        }
        if let p = pending, hypot(place.x - p.x, place.y - p.y) <= 2 {
            guard now - since >= Self.hold else { return (false, true) }
            pending = nil
            return (true, false)
        }
        pending = place
        since = now
        return (false, true)
    }
}
