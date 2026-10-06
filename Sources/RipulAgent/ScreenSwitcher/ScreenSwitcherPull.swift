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
///
/// ## The chrome's own drag
/// A drag toward the edge the chrome sits on opens nothing. A host that wants
/// it — the Browser pushes its address bar down into the compact pill — passes
/// `onChromeDrag`, and the same recogniser hands it the drag once the axis
/// locks that way. With `chromeTakesPull` it takes the pull toward the middle
/// too, for chrome with a step of its own before the overview: the Browser's
/// minimised bar comes back first, and the next pull opens the overview. A
/// second recogniser for either would race this one.
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

    /// A vertical drag the host takes for its chrome, in points toward the
    /// edge the chrome sits on, from where the axis locked: negative the other
    /// way. A frame that stalls is not caught up afterwards (see `chromeLast`),
    /// so the chrome can trail the finger but never jumps to it.
    public enum ChromeDrag {
        /// The axis locked, toward the edge (a push) or away from it (a pull).
        case began(towardEdge: Bool)
        case moved(CGFloat)
        /// `predicted` is where the system projects the finger would come to rest.
        case ended(CGFloat, predicted: CGFloat)
        /// The system took the touch, or the gesture was switched off under it.
        case cancelled
    }

    let enabled: Bool
    let direction: Direction
    let allowsHorizontal: Bool
    /// Attach ahead of the host's own recognisers rather than alongside them.
    /// Only needed where the content owns the same axis — a segmented control's
    /// thumb, for instance. Everywhere else stays simultaneous so no other
    /// screen's behaviour moves.
    var highPriority: Bool = false
    /// The drag toward the edge. Nil leaves it to whatever is underneath.
    var onChromeDrag: ((ChromeDrag) -> Void)? = nil
    /// The pull toward the middle goes to `onChromeDrag` too, not the overview.
    var chromeTakesPull: Bool = false

    private enum Axis { case undecided, vertical, horizontal, chrome }

    /// Every vertical drag is the host's: no overview to warm, no snapshot.
    private var hostTakesPull: Bool { chromeTakesPull && onChromeDrag != nil }

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
    @State private var warmed = false

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

    /// The chrome drag's last event, by the event's own clock, and its travel
    /// before anything was absorbed. When events are further apart than a
    /// stall, whatever the finger did across the gap is absorbed into the
    /// offset instead of drawn in one frame — the snap the origin exists to
    /// prevent, arriving by another route. A hitch anywhere (the first frame
    /// of a heavy layout, a capture) would otherwise land as a jump to the thumb.
    @State private var chromeLast: (time: Date, travel: CGFloat)?
    @State private var chromeAbsorbed: CGFloat = 0
    /// Two frames at 60Hz. A moving finger reports far more often than this.
    private let stallGap: TimeInterval = 0.034

    public init(
        enabled: Bool = true,
        direction: Direction = .down,
        allowsHorizontal: Bool = true,
        highPriority: Bool = false,
        onChromeDrag: ((ChromeDrag) -> Void)? = nil,
        chromeTakesPull: Bool = false
    ) {
        self.enabled = enabled
        self.direction = direction
        self.allowsHorizontal = allowsHorizontal
        self.highPriority = highPriority
        self.onChromeDrag = onChromeDrag
        self.chromeTakesPull = chromeTakesPull
    }

    /// The strip is window-wide, so travel is measured against the window and
    /// not against whatever control the finger happens to be on.
    private var screenWidth: CGFloat { max(switcher?.owningWindow?.bounds.width ?? 1, 1) }
    private var screenHeight: CGFloat { max(switcher?.owningWindow?.bounds.height ?? 1, 1) }

    public func body(content: Content) -> some View {
        // Keep the same content tree when editing disables this gesture.
        // Returning plain content here replaced the composer's UITextView
        // immediately after it became first responder, dropping the keyboard.
        // The chrome drag needs no switcher, so a host without one still has it.
        let gesturesEnabled = enabled && (switcher != nil || onChromeDrag != nil)
        let mask: GestureMask = gesturesEnabled ? .all : .subviews
        // 3, not 8: this is only where SwiftUI starts reporting the drag. The
        // axis has its own threshold below, so waiting here bought nothing but
        // delay before anything could happen at all.
        //
        // Global when the chrome follows its drag: that moves the view this is
        // attached to, and a translation measured in its own space would
        // include the response to the last event. Everywhere else the view
        // stands still under the snapshot, and stays exactly as it was.
        let drag = DragGesture(minimumDistance: 3, coordinateSpace: onChromeDrag == nil ? .local : .global)
            .updating($tracking) { _, state, _ in
                guard gesturesEnabled else { return }
                if !state {
                    axis = .undecided
                    origin = .zero
                    prepared = nil
                }
                state = true
            }
            .onChanged { value in
                guard gesturesEnabled else { return }
                if axis == .undecided {
                    let dx = value.translation.width
                    let dy = value.translation.height
                    // Before the threshold, not after: this is the only moment
                    // in the gesture when a stall is free.
                    //
                    // Not for a drag already heading the chrome's way, which
                    // needs no picture. A quick swipe's first report is often
                    // past the threshold, so the capture and the lock land on
                    // the same event and the stall is the chrome's first frame.
                    let chromeBound = onChromeDrag != nil && abs(dy) >= abs(dx)
                        && (hostTakesPull || direction.travel(dy) < 0)
                    if prepared == nil, let switcher, !chromeBound {
                        prepared = ScreenSnapshotter.capture(window: switcher.owningWindow)
                    }
                    guard max(abs(dx), abs(dy)) >= decisionDistance else { return }

                    let vertical = abs(dy) > abs(dx)
                    let toward = direction.travel(dy) > 0
                    if let switcher, vertical, toward, !hostTakesPull {
                        axis = .vertical
                        origin = value.translation
                        // Before the first progress is computed, so the ramp's
                        // length is settled for the whole gesture and cannot
                        // change under it.
                        switcher.calibrate(windowHeight: screenHeight)
                        switcher.beginInteractive(snapshot: prepared)
                    } else if let switcher, allowsHorizontal, abs(dx) > abs(dy) {
                        axis = .horizontal
                        origin = value.translation
                        cancelWarmup()
                        switcher.beginSlide(snapshot: prepared)
                    } else if let onChromeDrag, vertical, !toward || hostTakesPull {
                        axis = .chrome
                        origin = value.translation
                        chromeLast = (value.time, 0)
                        chromeAbsorbed = 0
                        // The warm overview stays until the finger lifts:
                        // unmounting it here would be a stall on this frame.
                        onChromeDrag(.began(towardEdge: !toward))
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
                    switcher?.updateInteractive(translation: direction.travel(dy))
                case .horizontal:
                    switcher?.updateSlide(translation: dx, width: screenWidth)
                case .chrome:
                    let travel = -direction.travel(dy)
                    if let last = chromeLast, value.time.timeIntervalSince(last.time) > stallGap {
                        chromeAbsorbed += travel - last.travel
                    }
                    chromeLast = (value.time, travel)
                    onChromeDrag?(.moved(travel - chromeAbsorbed))
                case .undecided:
                    break
                }
            }
            .onEnded { value in
                let decided = axis
                let start = origin
                axis = .undecided
                origin = .zero
                cancelWarmup()
                guard gesturesEnabled else { return }

                // Origin-relative like the live updates. Velocity is a
                // difference of the two, so the shift cancels there and the
                // flick keeps its full strength.
                let dy = value.translation.height - start.height
                let py = value.predictedEndTranslation.height - start.height

                switch decided {
                case .vertical:
                    let toward = direction.travel(dy)
                    let predicted = direction.travel(py)
                    switcher?.endInteractive(translation: toward, velocity: predicted - toward)
                case .horizontal:
                    switcher?.endSlide(
                        predicted: value.predictedEndTranslation.width - start.width,
                        width: screenWidth
                    )
                case .chrome:
                    // Shifted alike, so the flick's velocity survives.
                    onChromeDrag?(.ended(-direction.travel(dy) - chromeAbsorbed,
                                         predicted: -direction.travel(py) - chromeAbsorbed))
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
                // Nothing to warm when no pull can open the overview.
                guard gesturesEnabled, let switcher, !hostTakesPull else { return }
                if !state {
                    warmed = true
                    switcher.prepareToOpen()
                }
                state = true
            }
            .onEnded { _ in
                if axis == .undecided { cancelWarmup() }
            }

        let wrapped = highPriority
            ? AnyView(content.highPriorityGesture(drag, including: mask).simultaneousGesture(warm, including: mask))
            : AnyView(content.simultaneousGesture(drag, including: mask).simultaneousGesture(warm, including: mask))
        return wrapped
            .onChange(of: gesturesEnabled) { active in
                guard !active else { return }
                // Focus can cancel a touch without delivering onEnded.
                cancelWarmup()
                if axis == .chrome { onChromeDrag?(.cancelled) }
                axis = .undecided
                origin = .zero
                prepared = nil
            }
            .onChange(of: touching) { active in
                if !active, axis == .undecided { cancelWarmup() }
            }
            .onChange(of: tracking) { active in
                // `tracking` reverts on cancellation AND on completion, and its
                // order against `onEnded` is not defined. Give `onEnded` the
                // rest of this run-loop turn: if the axis is still latched
                // after it, nothing ended this drag — the system took the touch
                // (a backgrounding, a call, Control Centre) — and the store
                // would otherwise sit mid-ramp or mid-slide until the next one.
                guard !active, axis != .undecided else { return }
                DispatchQueue.main.async { settleInterruptedDrag() }
            }
    }

    private func settleInterruptedDrag() {
        switch axis {
        case .vertical: switcher?.cancelInteractive()
        case .horizontal: switcher?.cancelSlide()
        case .chrome: onChromeDrag?(.cancelled)
        case .undecided: return
        }
        axis = .undecided
        origin = .zero
        prepared = nil
        cancelWarmup()
    }

    private func cancelWarmup() {
        guard warmed else { return }
        warmed = false
        switcher?.cancelPrepareToOpen()
    }
}

@available(iOS 15.0, *)
public extension View {
    /// Mount the overview gesture on a piece of chrome.
    func screenSwitcherPull(
        _ direction: ScreenSwitcherPullModifier.Direction,
        enabled: Bool = true,
        allowsHorizontal: Bool = true,
        highPriority: Bool = false,
        onChromeDrag: ((ScreenSwitcherPullModifier.ChromeDrag) -> Void)? = nil,
        chromeTakesPull: Bool = false
    ) -> some View {
        modifier(ScreenSwitcherPullModifier(
            enabled: enabled,
            direction: direction,
            allowsHorizontal: allowsHorizontal,
            highPriority: highPriority,
            onChromeDrag: onChromeDrag,
            chromeTakesPull: chromeTakesPull
        ))
    }
}
#endif
