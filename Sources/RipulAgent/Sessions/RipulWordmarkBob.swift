import CoreGraphics

/// How the dot of the Ripul logo moves when the logo first appears: it sways
/// left and right, a little less each time, and comes to rest where it began.
/// A small sign of life on a screen where nothing else is happening yet.
///
/// Free of SwiftUI and of the package's resources, so the motion can be drawn
/// frame by frame by a script without building an app.
enum RipulWordmarkBob {
    /// The dot's centre in the logo image, as a share of its width and height.
    static let dotCentre = CGPoint(x: 0.1301, y: 0.6091)
    /// From the first movement to rest, in seconds.
    static let duration: Double = 2.4
    /// How long the logo stands still before the dot moves, so the eye is there first.
    static let delay: Double = 0.45
    /// Left, right, left, each smaller than the last.
    static let sways: CGFloat = 2.5

    /// The dot at `progress` (0 as it starts, 1 at rest): how far it has slid
    /// sideways, as a share of the logo's height, and how far it has tipped, in
    /// radians. Both are zero at either end, so the logo is exact before and after.
    static func pose(at progress: CGFloat) -> (shift: CGFloat, tilt: CGFloat) {
        let p = min(max(progress, 0), 1)
        let fade = (1 - p) * (1 - p)
        let sway = -sin(2 * .pi * sways * p) * fade
        return (shift: 0.08 * sway, tilt: 0.28 * sway)
    }
}
