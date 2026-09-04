#if canImport(UIKit)
import SwiftUI

/// The gesture that summons the screen overview, and walks the card strip.
///
/// ## One recogniser, not two
/// A separate vertical and horizontal recogniser would race: each sees the
/// other's diagonal and both can claim the same drag, so you get a half-open
/// overview *and* a tab change. This one stays undecided until the drag has
/// declared an axis, then commits to that axis for the rest of the gesture.
///
/// ## Two mount points, opposite directions
/// The title bar pulls DOWN, the chat composer pulls UP — both toward the middle
/// of the screen, which is where the grid appears. Direction is a parameter
/// rather than a second implementation, so the thresholds, the axis arbitration
/// and the commit rules cannot drift apart between them.
@available(iOS 15.0, *)
public struct ScreenSwitcherPullModifier: ViewModifier {
    public enum Direction {
        /// Pull down to open — mounted on chrome at the TOP of the screen.
        case down
        /// Pull up to open — mounted on chrome at the BOTTOM.
        case up

        /// Travel toward the open state, as a positive number. The store always
        /// measures opening as positive regardless of which way the finger went.
        func travel(_ dy: CGFloat) -> CGFloat { self == .down ? dy : -dy }
    }

    let enabled: Bool
    let direction: Direction
    let allowsHorizontal: Bool
    /// Attach ahead of the host's own recognisers rather than alongside them.
    /// Only needed where the content owns the same axis — a segmented control's
    /// thumb, for instance. Everywhere else stays simultaneous so no other
    /// screen's behaviour moves.
    var highPriority: Bool = false

    private enum Axis { case undecided, vertical, horizontal }

    @Environment(\.screenSwitcher) private var switcher
    @State private var axis: Axis = .undecided

    /// Where the finger was when the axis resolved.
    ///
    /// Everything downstream is measured FROM here rather than from touch-down.
    /// The distance spent deciding which way the drag was going is not motion
    /// anyone asked for, and applying it the instant the axis locks moves the
    /// screen by the whole threshold in a single frame — felt as the gesture
    /// hesitating and then snapping to the thumb.
    ///
    /// The cost is that the screen trails the finger by that threshold for the
    /// rest of the drag, and it is worth paying: what matters here is that the
    /// opening is smooth, not that a card edge stays welded to a thumb. The
    /// distance is a few points and the eye is on the motion, not the offset.
    @State private var origin: CGSize = .zero

    /// True only while a touch is down, so the axis lock can be cleared at the
    /// START of a gesture. `onEnded` does not run when a gesture is CANCELLED,
    /// and a latched axis with a stale origin makes every later drag misbehave.
    @GestureState private var tracking = false

    /// True from the instant a finger lands, which is when the overview is
    /// built. Distinct from `tracking`, which waits for the drag to be
    /// recognised — by then the useful head start is gone.
    @GestureState private var touching = false

    /// Travel before the axis is chosen. Separate from the recogniser's own
    /// minimum, which is now small enough that the drag is live almost at once —
    /// this is only how much direction has to be shown before committing.
    private let decisionDistance: CGFloat = 8

    /// The window, grabbed BEFORE the gesture commits to anything.
    ///
    /// `captureKeyWindow` renders the whole screen — a WKWebView and all — on
    /// the main thread. Taken at the moment the axis locks, which is what used
    /// to happen, that stall lands on the exact frame the card should start
    /// moving: the app freezes, the finger keeps going, and the first frame that
    /// finally draws shows the card already shrunk to wherever the thumb got to.
    /// That is the snap, and no amount of correcting the arithmetic touches it.
    ///
    /// Taken here instead, during the few points of dead zone before the axis is
    /// decided, it costs the same but nothing is moving yet, so there is nothing
    /// for it to interrupt.
    @State private var prepared: UIImage?

    public init(
        enabled: Bool = true,
        direction: Direction = .down,
        allowsHorizontal: Bool = true,
        highPriority: Bool = false
    ) {
        self.enabled = enabled
        self.direction = direction
        self.allowsHorizontal = allowsHorizontal
        self.highPriority = highPriority
    }

    /// The strip is window-wide, so travel is measured against the window and
    /// not against whatever control the finger happens to be on.
    private var screenWidth: CGFloat { max(UIScreen.main.bounds.width, 1) }
    private var screenHeight: CGFloat { max(UIScreen.main.bounds.height, 1) }

    public func body(content: Content) -> some View {
        guard enabled, let switcher else { return AnyView(content) }
        // 3, not 8: this is only where SwiftUI starts reporting the drag. The
        // axis has its own threshold below, so waiting here bought nothing but
        // delay before anything could happen at all.
        let drag = DragGesture(minimumDistance: 3)
            .updating($tracking) { _, state, _ in
                if !state {
                    axis = .undecided
                    origin = .zero
                    prepared = nil
                }
                state = true
            }
            .onChanged { value in
                if axis == .undecided {
                    let dx = value.translation.width
                    let dy = value.translation.height
                    // Before the threshold, not after: this is the only moment
                    // in the gesture when a stall is free.
                    if prepared == nil { prepared = ScreenSnapshotter.captureKeyWindow() }
                    guard max(abs(dx), abs(dy)) >= decisionDistance else { return }

                    if direction.travel(dy) > 0, abs(dy) > abs(dx) {
                        axis = .vertical
                        origin = value.translation
                        // Before the first progress is computed, so the ramp's
                        // length is settled for the whole gesture and cannot
                        // change under it.
                        switcher.calibrate(windowHeight: screenHeight)
                        switcher.beginInteractive(snapshot: prepared)
                    } else if allowsHorizontal, abs(dx) > abs(dy) {
                        axis = .horizontal
                        origin = value.translation
                        switcher.cancelPrepareToOpen()
                        switcher.beginSlide(snapshot: prepared)
                    } else {
                        return
                    }
                }

                // Measured from where the axis locked, so the screen starts at
                // rest and grows with the finger instead of arriving at it.
                let dx = value.translation.width - origin.width
                let dy = value.translation.height - origin.height

                switch axis {
                case .vertical:
                    switcher.updateInteractive(translation: direction.travel(dy))
                case .horizontal:
                    switcher.updateSlide(translation: dx, width: screenWidth)
                case .undecided:
                    break
                }
            }
            .onEnded { value in
                let decided = axis
                let start = origin
                axis = .undecided
                origin = .zero

                // Origin-relative like the live updates. Velocity is a
                // difference of the two, so the shift cancels there and the
                // flick keeps its full strength.
                let dy = value.translation.height - start.height
                let py = value.predictedEndTranslation.height - start.height

                switch decided {
                case .vertical:
                    let toward = direction.travel(dy)
                    let predicted = direction.travel(py)
                    switcher.endInteractive(translation: toward, velocity: predicted - toward)
                case .horizontal:
                    switcher.endSlide(
                        predicted: value.predictedEndTranslation.width - start.width,
                        width: screenWidth
                    )
                case .undecided:
                    break
                }
            }

        // Separate, and zero-distance, so it fires the moment a finger lands
        // rather than once the drag has been recognised. Simultaneous, so it
        // consumes nothing — a tap on whatever this is mounted over still
        // behaves as a tap.
        let warm = DragGesture(minimumDistance: 0)
            .updating($touching) { _, state, _ in
                if !state { switcher.prepareToOpen() }
                state = true
            }
            .onEnded { _ in
                if axis == .undecided { switcher.cancelPrepareToOpen() }
            }

        return highPriority
            ? AnyView(content.highPriorityGesture(drag).simultaneousGesture(warm))
            : AnyView(content.simultaneousGesture(drag).simultaneousGesture(warm))
    }
}

@available(iOS 15.0, *)
public extension View {
    /// Mount the overview gesture on a piece of chrome.
    func screenSwitcherPull(
        _ direction: ScreenSwitcherPullModifier.Direction,
        enabled: Bool = true,
        allowsHorizontal: Bool = true,
        highPriority: Bool = false
    ) -> some View {
        modifier(ScreenSwitcherPullModifier(
            enabled: enabled,
            direction: direction,
            allowsHorizontal: allowsHorizontal,
            highPriority: highPriority
        ))
    }
}
#endif
