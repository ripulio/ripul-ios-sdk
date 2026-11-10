import Foundation
import CoreGraphics
#if canImport(UIKit)
import SwiftUI
import UIKit
import WebKit
#endif

// MARK: - Reading two fingers (pure)
//
// Ungated so `swift test` on macOS can pin the rules; the UIKit half below
// compiles out there.

/// What two fingers moving together ask the screens for, read the way the
/// overview's pull reads one finger: nothing until the pair has shown a
/// direction, then one answer for the rest of the touch.
enum TwoFingerSwipeReading: Equatable {
    case undecided
    /// Up: the overview opens, as it does from the composer.
    case up
    /// Left or right: the previous or next screen, as the title bar slides.
    case sideways
    /// Not this swipe. Left to whatever else wants the fingers.
    case declined(Declined)

    enum Declined: String, Equatable {
        /// The gap between the fingers changed more than they travelled.
        case pinch
        /// Nothing opens downward, so a two-finger scroll that way keeps it.
        case down
    }

    /// Travel of the point between the fingers before a direction is chosen:
    /// the pull's own decision distance, so one finger and two commit alike.
    static let decisionDistance: CGFloat = 8

    /// A change in the gap between the fingers this large, while the pair has
    /// travelled less than it, is a pinch.
    static let pinchSlop: CGFloat = 12

    /// `from`: the two fingers when the second landed. `to`: the same two now.
    static func read(from: (CGPoint, CGPoint), to: (CGPoint, CGPoint)) -> TwoFingerSwipeReading {
        let start = midpoint(from.0, from.1)
        let now = midpoint(to.0, to.1)
        let dx = now.x - start.x
        let dy = now.y - start.y
        let travel = hypot(dx, dy)
        let spread = abs(gap(to.0, to.1) - gap(from.0, from.1))
        if spread >= pinchSlop, spread > travel { return .declined(.pinch) }
        guard travel >= decisionDistance else { return .undecided }
        if abs(dy) > abs(dx) { return dy < 0 ? .up : .declined(.down) }
        return .sideways
    }

    static func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    static func gap(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(b.x - a.x, b.y - a.y)
    }

    /// How much further a release at `velocity` (points a second) carries,
    /// as `DragGesture`'s `predictedEndTranslation` has it. The store's flick
    /// thresholds were tuned on the pull's predictions, so two fingers have to
    /// project the way one does or the same flick lands on a different stop.
    static func projection(velocity: CGFloat) -> CGFloat {
        velocity * projectionFactor
    }

    /// Seconds of travel at the release's speed; measured against SwiftUI by
    /// `TwoFingerSwitcherSwipeTests.testAFlickProjectsAsFarAsOneFingersDoes`.
    static let projectionFactor: CGFloat = 0.25
}

#if canImport(UIKit)

/// A view whose own touches use two fingers: a trackpad, the fingers sent to
/// a remote screen, a camera that pans and zooms. The screens' two-finger
/// swipe leaves any touch that lands on one alone.
public protocol OwnsTwoFingerTouches: UIView {}

#if os(iOS) && !targetEnvironment(macCatalyst)

/// Two fingers that land together and move together, read with
/// `TwoFingerSwipeReading`. It begins once the pair has chosen up or
/// sideways, and fails on a pinch, a swipe down, a third finger, or a first
/// finger that was already going somewhere when the second came down.
final class TwoFingerSwipeRecognizer: UIGestureRecognizer {
    /// How soon after the first finger the second must land to make a pair.
    static let pairWindow: TimeInterval = 0.25
    /// How far the first finger may have moved by then. Under the pull's
    /// decision distance, so a first finger on the composer or the title bar
    /// can't already have started the one-finger pull.
    static let pairSlop: CGFloat = 6

    private(set) var pair: [UITouch] = []
    private var firstDown: (point: CGPoint, time: TimeInterval)?
    /// Where the two were when the second landed, in the window.
    private(set) var landed: (CGPoint, CGPoint)?
    private(set) var reading: TwoFingerSwipeReading = .undecided
    /// The point between the fingers over the last moments, for the release.
    private var samples: [(time: TimeInterval, point: CGPoint)] = []

    /// The second finger landed and the pair is being read: the moment to
    /// mount the overview and take the picture, before anything moves.
    var onPaired: (() -> Void)?
    /// After every touch sequence, whatever it came to.
    var onReset: (() -> Void)?

    /// Two fingers are down in `window` and its swipe is reading them. One of
    /// them can land on the composer or a title bar, whose pull would read it
    /// too and drive the store a second time, or on a message whose swipe to
    /// reply sees only its own finger; both stand aside while this is true.
    static func isReadingPair(in window: UIWindow?) -> Bool {
        window?.gestureRecognizers?.contains { ($0 as? TwoFingerSwipeRecognizer)?.landed != nil } ?? false
    }

    /// The point between the two fingers, in the window.
    var midpoint: CGPoint {
        guard pair.count == 2 else { return pair.first?.location(in: nil) ?? .zero }
        return TwoFingerSwipeReading.midpoint(pair[0].location(in: nil), pair[1].location(in: nil))
    }

    /// The point between the fingers, in points a second, over the last 80ms.
    var velocity: CGPoint {
        guard let last = samples.last,
              let first = samples.first(where: { last.time - $0.time <= 0.08 }) else { return .zero }
        let elapsed = last.time - first.time
        guard elapsed > 0.001 else { return .zero }
        return CGPoint(x: (last.point.x - first.point.x) / elapsed, y: (last.point.y - first.point.y) / elapsed)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard state == .possible else {
            // Once the swipe is under way a third finger changes nothing.
            for touch in touches { ignore(touch, for: event) }
            return
        }
        for touch in touches.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard pair.count < 2 else {
                state = .failed
                return
            }
            pair.append(touch)
        }
        guard let first = pair.first else { return }
        if firstDown == nil { firstDown = (first.location(in: nil), first.timestamp) }
        guard pair.count == 2, landed == nil, let firstDown else { return }
        let second = pair[1]
        let firstNow = first.location(in: nil)
        guard second.timestamp - firstDown.time <= Self.pairWindow,
              TwoFingerSwipeReading.gap(firstNow, firstDown.point) <= Self.pairSlop else {
            state = .failed
            return
        }
        landed = (firstNow, second.location(in: nil))
        record(at: second.timestamp)
        onPaired?()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let landed else {
            // One finger so far: once it has gone somewhere, it is that
            // finger's gesture.
            if state == .possible, let first = pair.first, let firstDown,
               TwoFingerSwipeReading.gap(first.location(in: nil), firstDown.point) > Self.pairSlop {
                state = .failed
            }
            return
        }
        record(at: event.timestamp)
        switch state {
        case .possible:
            reading = TwoFingerSwipeReading.read(
                from: landed, to: (pair[0].location(in: nil), pair[1].location(in: nil)))
            switch reading {
            case .undecided: break
            case .declined: state = .failed
            case .up, .sideways: state = .began
            }
        case .began, .changed:
            state = .changed
        default:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        guard touches.contains(where: { touch in pair.contains { $0 === touch } }) else { return }
        switch state {
        // Lifted before the pair said anything: a tap, or nothing.
        case .possible: state = .failed
        // Either finger lifting ends it, at the speed it had.
        case .began, .changed: state = .ended
        default: break
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        state = state == .possible ? .failed : .cancelled
    }

    override func reset() {
        super.reset()
        pair = []
        firstDown = nil
        landed = nil
        reading = .undecided
        samples = []
        onReset?()
    }

    private func record(at time: TimeInterval) {
        samples.append((time, midpoint))
        if let last = samples.last { samples.removeAll { last.time - $0.time > 0.2 } }
    }
}

/// The overview and the slide between screens, from two fingers anywhere on
/// the screen: up opens the overview as the composer's pull does, left and
/// right move along the screens as the title bar does. Mounted once at the
/// app's root, beside the overlay; it drives the same store calls as
/// `ScreenSwitcherPullModifier`, so the ramp, the stops and the flick rules
/// are the pull's.
///
/// ## A passive marker and a window recogniser
/// As the drawer's edge swipe does, the marker takes no touches; the
/// recogniser watches from the window, so every screen has it without
/// wrapping any of them, and the touch stays on whatever it landed on.
///
/// ## Scrolling
/// A two-finger drag used to scroll whatever was under it. While a pair is
/// down, scroll views wait to hear whether it is a swipe; up or sideways, it
/// begins and the scroll never starts. Down, it fails, and the scroll goes on.
///
/// ## Buttons and rows under the fingers
/// When it begins it takes the fingers from everything else holding them
/// (`takeFingers`), or a row pressed by a sideways swipe would open as the
/// fingers lift. The pull and the swipe to reply also stand aside while a
/// pair is down (`TwoFingerSwipeRecognizer.isReadingPair`).
///
/// ## What keeps its two fingers
/// A touch is left alone, with a `[TWOFINGER]` line saying why, on a view
/// that adopts `OwnsTwoFingerTouches`; on a web page; under a recogniser of
/// its own that wants two fingers (a pinch, a rotation, a two-finger pan or
/// tap: the Browser's camera, a zooming image, a floating panel's resize); in
/// a list that is selecting; inside anything presented over the screens (a
/// sheet, an alert); and while the keyboard is up, as the composer's pull is.
public struct ScreenSwitcherTwoFingerSwipe: UIViewRepresentable {
    let store: ScreenSwitcherStore
    /// Read at touch time, like the drawer's.
    var isEnabled: () -> Bool

    public init(store: ScreenSwitcherStore, isEnabled: @escaping () -> Bool = { true }) {
        self.store = store
        self.isEnabled = isEnabled
    }

    public func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    public func makeUIView(context: Context) -> MarkerView {
        let view = MarkerView()
        view.onWindowChanged = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        return view
    }

    public func updateUIView(_ view: MarkerView, context: Context) {
        context.coordinator.store = store
        context.coordinator.isEnabled = isEnabled
    }

    public static func dismantleUIView(_ view: MarkerView, coordinator: Coordinator) {
        view.onWindowChanged = nil
        coordinator.attach(to: nil)
    }

    public final class MarkerView: UIView {
        var onWindowChanged: ((UIWindow?) -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override public func didMoveToWindow() {
            super.didMoveToWindow()
            onWindowChanged?(window)
        }
    }

    @MainActor
    public final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var store: ScreenSwitcherStore
        var isEnabled: () -> Bool = { true }

        private enum Axis { case none, vertical, horizontal }
        private var axis: Axis = .none
        /// Where the point between the fingers was when the swipe began.
        /// Everything is measured from here, as the pull measures from where
        /// its axis locked, so the screen starts at rest rather than jumping
        /// by the distance spent deciding.
        private var origin: CGPoint = .zero
        /// The picture taken when the pair landed, while nothing was moving.
        private var prepared: UIImage?
        private var warmed = false
        private var keyboardShown = false
        /// One `[TWOFINGER]` line per touch sequence when a touch is left alone.
        private var notedStandDown = false

        private lazy var recognizer: TwoFingerSwipeRecognizer = {
            let recognizer = TwoFingerSwipeRecognizer(target: self, action: #selector(handle(_:)))
            recognizer.name = "ScreenSwitcher.twoFingerSwipe"
            recognizer.delegate = self
            // A tap's end goes to its view at once rather than after this has
            // failed; it can't begin after the fingers lift anyway.
            recognizer.delaysTouchesEnded = false
            recognizer.onPaired = { [weak self] in self?.paired() }
            recognizer.onReset = { [weak self] in self?.finished() }
            return recognizer
        }()

        init(store: ScreenSwitcherStore) {
            self.store = store
            super.init()
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(keyboardWillShow(_:)),
                               name: UIResponder.keyboardWillShowNotification, object: nil)
            center.addObserver(self, selector: #selector(keyboardWillHide(_:)),
                               name: UIResponder.keyboardWillHideNotification, object: nil)
        }

        func attach(to window: UIWindow?) {
            guard recognizer.view !== window else { return }
            recognizer.view?.removeGestureRecognizer(recognizer)
            window?.addGestureRecognizer(recognizer)
        }

        @objc private func keyboardWillShow(_ note: Notification) {
            let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
            keyboardShown = frame.height > 0
        }

        @objc private func keyboardWillHide(_ note: Notification) { keyboardShown = false }

        /// Nothing else has the store: no overview, slide, pull or landing.
        private var storeIsAtRest: Bool {
            !store.isActive && !store.isSliding && !store.isDragging && !store.isDocking
                && !store.isBubbling && !store.isFlatDismissing
        }

        // MARK: Delegate

        public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            if gestureRecognizer.state == .possible, recognizer.pair.isEmpty { notedStandDown = false }
            guard touch.type == .direct, isEnabled(), storeIsAtRest, !keyboardShown,
                  let window = gestureRecognizer.view as? UIWindow, touch.window === window else { return false }
            if let reason = Self.standDownReason(for: touch.view, besides: gestureRecognizer) {
                if !notedStandDown {
                    notedStandDown = true
                    RipulLog.log("[TWOFINGER] left alone: \(reason)")
                }
                return false
            }
            return true
        }

        public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            // The one-finger pull may have taken the store since touch-down.
            isEnabled() && storeIsAtRest && !keyboardShown
        }

        public func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // Never beside a scroll view's pan: beginning first is what keeps
            // the screen from scrolling under the swipe.
            if otherGestureRecognizer is UIPanGestureRecognizer, otherGestureRecognizer.view is UIScrollView {
                return false
            }
            // Beside whatever was already under way when the pair was read: a
            // SwiftUI button's press begins as the finger lands, and would
            // otherwise shut the swipe out (the floating panel's pinch found
            // this). Anything still waiting is stopped by the swipe beginning.
            return otherGestureRecognizer.state == .began || otherGestureRecognizer.state == .changed
        }

        public func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // While a pair is down, scroll views wait to hear whether it is a
            // swipe. One finger never makes them wait.
            recognizer.landed != nil && otherGestureRecognizer is UIPanGestureRecognizer
                && otherGestureRecognizer.view is UIScrollView
        }

        /// Why a touch on `view` is not the swipe's, or nil when it is.
        static func standDownReason(for view: UIView?, besides recognizer: UIGestureRecognizer) -> String? {
            var responder: UIResponder? = view
            while let current = responder {
                if let controller = current as? UIViewController, controller.presentingViewController != nil {
                    return "presented over the screens"
                }
                if let view = current as? UIView {
                    if view is OwnsTwoFingerTouches { return "\(type(of: view)) takes two fingers" }
                    if view is WKWebView { return "a web page" }
                    if let list = view as? UICollectionView, list.isEditing { return "a list selecting" }
                    if let list = view as? UITableView, list.isEditing { return "a list selecting" }
                    for other in view.gestureRecognizers ?? [] where other !== recognizer && other.isEnabled
                        && takesTwoFingers(other) {
                        return "\(type(of: other)) on \(type(of: view))"
                    }
                }
                responder = current.next
            }
            return nil
        }

        static func takesTwoFingers(_ recognizer: UIGestureRecognizer) -> Bool {
            if recognizer is UIPinchGestureRecognizer || recognizer is UIRotationGestureRecognizer { return true }
            if let pan = recognizer as? UIPanGestureRecognizer, pan.minimumNumberOfTouches >= 2 { return true }
            if let tap = recognizer as? UITapGestureRecognizer, tap.numberOfTouchesRequired >= 2 { return true }
            return false
        }

        // MARK: The swipe

        private func paired() {
            guard storeIsAtRest else { return }
            warmed = true
            store.prepareToOpen()
            let started = CACurrentMediaTime()
            prepared = ScreenSnapshotter.capture(window: store.owningWindow ?? recognizer.view as? UIWindow)
            RipulLog.log(String(format: "[TWOFINGER] paired; picture in %.0fms", (CACurrentMediaTime() - started) * 1000))
        }

        /// The swipe has the fingers now, so whatever else holds them lets go,
        /// as content does when a scroll view takes a touch. Two had begun
        /// before the swipe did (measured 4 November 2026): a SwiftUI button's
        /// press (`UIKitResponderGestureRecognizer`), which fires as the finger
        /// lifts even when UIKit cancels its touches, and a message's swipe to
        /// reply on each row, which sees only its own finger. A scroll view's
        /// pan was already stopped by the swipe beginning; the window's own
        /// recognisers are left as they are. Returns what let go.
        private func takeFingers(from recognizer: TwoFingerSwipeRecognizer) -> [String] {
            var seen = Set<ObjectIdentifier>()
            var taken: [String] = []
            for touch in recognizer.pair {
                for other in touch.gestureRecognizers ?? [] where other !== recognizer && other.isEnabled {
                    guard seen.insert(ObjectIdentifier(other)).inserted,
                          !(other.view is UIScrollView), !(other.view is UIWindow),
                          other.state == .possible || other.state == .began || other.state == .changed else { continue }
                    // Disabling a recogniser cancels whatever it is tracking.
                    other.isEnabled = false
                    other.isEnabled = true
                    taken.append(other.name ?? String(describing: type(of: other)))
                }
            }
            return taken
        }

        private func finished() {
            // An overview that opened was revealed by beginInteractive, which
            // ends the warm-up itself.
            if axis == .none { cancelWarmup() } else { warmed = false }
            axis = .none
            prepared = nil
        }

        private func cancelWarmup() {
            guard warmed else { return }
            warmed = false
            store.cancelPrepareToOpen()
        }

        @objc private func handle(_ recognizer: TwoFingerSwipeRecognizer) {
            guard let window = recognizer.view else { return }
            let point = recognizer.midpoint
            let dx = point.x - origin.x
            let dy = point.y - origin.y
            switch recognizer.state {
            case .began:
                origin = point
                store.fingerLocation = point
                switch recognizer.reading {
                case .up:
                    axis = .vertical
                    // Before the first progress, as the pull does, so the
                    // ramp's length is settled for the whole swipe.
                    store.calibrate(windowHeight: max(window.bounds.height, 1))
                    store.beginInteractive(snapshot: prepared)
                case .sideways:
                    axis = .horizontal
                    cancelWarmup()
                    store.beginSlide(snapshot: prepared)
                default:
                    axis = .none
                }
                prepared = nil
                let taken = takeFingers(from: recognizer)
                RipulLog.log("[TWOFINGER] began \(axis == .vertical ? "up" : "sideways")"
                             + (taken.isEmpty ? "" : "; took the fingers from \(taken.joined(separator: ", "))"))
            case .changed:
                store.fingerLocation = point
                switch axis {
                case .vertical:
                    store.updateInteractive(translation: -dy)
                    // Sideways too: in a window wide enough to dock, the card
                    // goes where the fingers take it.
                    store.updateCarry(translation: dx)
                case .horizontal:
                    store.updateSlide(translation: dx, width: window.bounds.width)
                case .none:
                    break
                }
            case .ended:
                let velocity = recognizer.velocity
                switch axis {
                case .vertical:
                    store.endInteractive(translation: -dy, velocity: TwoFingerSwipeReading.projection(velocity: -velocity.y))
                case .horizontal:
                    store.endSlide(predicted: dx + TwoFingerSwipeReading.projection(velocity: velocity.x),
                                   width: window.bounds.width)
                case .none:
                    break
                }
                RipulLog.log(String(format: "[TWOFINGER] ended dx=%.0f dy=%.0f v=(%.0f, %.0f)",
                                    dx, dy, velocity.x, velocity.y))
            case .cancelled:
                switch axis {
                case .vertical: store.cancelInteractive()
                case .horizontal: store.cancelSlide()
                case .none: break
                }
                RipulLog.log("[TWOFINGER] cancelled")
            default:
                break
            }
        }
    }
}
#endif
#endif
