import Foundation
import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Touch paths (pure)
//
// Ungated so `swift test` on macOS can pin the gesture geometry; the UIKit
// half below compiles out there.

enum TouchPath {
    /// Evenly spaced points from `start` to `end`, excluding `start` and
    /// including `end` — the finger's moves after touching down at `start`.
    static func moves(from start: CGPoint, to end: CGPoint, steps: Int) -> [CGPoint] {
        let count = max(1, steps)
        return (1...count).map { step in
            let t = CGFloat(step) / CGFloat(count)
            return CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
        }
    }

    /// Moves for a drag lasting `duration`, at about 60 per second.
    static func steps(for duration: TimeInterval) -> Int {
        max(2, Int((duration * 60).rounded()))
    }
}

#if canImport(UIKit)

/// Real finger touches, synthesized inside the app: the way in-process UI test
/// frameworks (KIF, Lyft's Hammer) drive UIKit. The event goes through UIKit's
/// own touch pipeline — hit testing, gesture recognizers, SwiftUI, UITabBar —
/// exactly as a finger's does, so it presses things `tap_element`'s semantic
/// ladder (control actions, accessibility activation) can't reach, and it can
/// swipe, drag and long-press.
///
/// DEV-ONLY private API: IOKit's IOHIDEvent constructors, BackBoardServices'
/// digitizer-info setter (which names the window the touch belongs to) and
/// `-[UIApplication _enqueueHIDEvent:]`, all resolved at runtime (dlsym and
/// selectors), never linked. Compiled into DEBUG builds only, so no App Store
/// binary carries the names; `unavailableReason` says why it's off elsewhere,
/// or when a future iOS drops a symbol, and callers fall back.
///
/// A host whose test builds are not Debug builds (its Debug configuration
/// points at another backend, say) compiles those builds with
/// `RIPUL_DEVELOPER_BUILD` to get the same. That is for builds installed
/// straight onto a developer's own devices, never for one that goes to
/// TestFlight or the App Store.
@MainActor
enum TouchSynthesizer {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// nil when touches can be synthesized.
    static var unavailableReason: String? {
        #if DEBUG || RIPUL_DEVELOPER_BUILD
        return HID.shared == nil ? "this iOS version lacks the touch-event functions" : nil
        #else
        return "real touches are compiled into debug and developer builds only"
        #endif
    }

    static var isAvailable: Bool { unavailableReason == nil }

    /// A tap (or `count` taps) at `point`, in `window`'s coordinates.
    static func tap(at point: CGPoint, in window: UIWindow, count: Int = 1) async throws {
        for index in 0..<max(1, count) {
            if index > 0 { try await pause(0.08) }
            try send(.down, at: point, in: window)
            try await pause(0.06)
            try send(.up, at: point, in: window)
        }
    }

    static func longPress(at point: CGPoint, in window: UIWindow, duration: TimeInterval) async throws {
        try send(.down, at: point, in: window)
        try await pause(duration)
        try send(.up, at: point, in: window)
    }

    /// Touch down at `start`, move to `end` over `duration`, lift. Short
    /// durations fling a scroll view; long ones drag.
    static func drag(from start: CGPoint, to end: CGPoint, in window: UIWindow, duration: TimeInterval) async throws {
        let moves = TouchPath.moves(from: start, to: end, steps: TouchPath.steps(for: duration))
        let interval = duration / Double(moves.count)
        try send(.down, at: start, in: window)
        for point in moves {
            try await pause(interval)
            try send(.moved, at: point, in: window)
        }
        try send(.up, at: end, in: window)
    }

    private static func pause(_ seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    /// `held`: a finger that is down and hasn't moved, while another does something.
    enum Phase { case down, moved, held, up, cancelled }

    /// One finger of a hand: which (0…4), where in the window, and what it is doing.
    struct Finger {
        let slot: Int
        let point: CGPoint
        let phase: Phase
        /// It came down at the edge of the screen. A touchscreen says so
        /// itself, and UIKit's screen-edge recognizers (Back, a drawer) act
        /// only on touches it has said it of; where the finger is isn't enough.
        var fromEdge = false
    }

    /// How near the edge of the window a finger comes down to count as from the edge.
    static let edgeReach: CGFloat = 12

    static func isAtEdge(_ point: CGPoint, of window: UIWindow) -> Bool {
        let bounds = window.bounds
        return point.x <= bounds.minX + edgeReach || point.x >= bounds.maxX - edgeReach
            || point.y <= bounds.minY + edgeReach || point.y >= bounds.maxY - edgeReach
    }

    /// Whether the one finger of tap, drag and `pointer` came down at the edge.
    private static var fingerIsFromEdge = false

    /// The most fingers a hand has.
    static let mostFingers = 5

    /// One moment of a hand driven from outside (Live View's live touches,
    /// `pinch`): every finger that is down, each with what it is doing now.
    static func hand(_ fingers: [Finger], in window: UIWindow, time: UInt64? = nil) throws {
        #if DEBUG || RIPUL_DEVELOPER_BUILD
        guard let hid = HID.shared else { throw Failure(description: unavailableReason ?? "unavailable") }
        guard !fingers.isEmpty else { return }
        try hid.send(fingers.map { finger in
            (index: UInt32(2 + min(max(finger.slot, 0), mostFingers - 1)),
             screenPoint: window.convert(finger.point, to: window.screen.coordinateSpace), phase: finger.phase,
             fromEdge: finger.fromEdge)
        }, window: window, time: time)
        #else
        throw Failure(description: unavailableReason ?? "unavailable")
        #endif
    }

    /// Two fingers about `center`, `from` points apart moving to `to` apart,
    /// along `angle` (radians from the horizontal): apart to zoom in, together
    /// to zoom out.
    static func pinch(center: CGPoint, from: CGFloat, to: CGFloat, angle: CGFloat, in window: UIWindow,
                      duration: TimeInterval) async throws {
        let bounds = window.bounds.insetBy(dx: 1, dy: 1)
        func fingers(_ apart: CGFloat, _ phase: Phase) -> [Finger] {
            let dx = cos(angle) * apart / 2, dy = sin(angle) * apart / 2
            func inside(_ point: CGPoint) -> CGPoint {
                CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
            }
            return [Finger(slot: 0, point: inside(CGPoint(x: center.x - dx, y: center.y - dy)), phase: phase),
                    Finger(slot: 1, point: inside(CGPoint(x: center.x + dx, y: center.y + dy)), phase: phase)]
        }
        let steps = TouchPath.steps(for: duration)
        try hand(fingers(from, .down), in: window)
        for step in 1...steps {
            try await pause(duration / Double(steps))
            try hand(fingers(from + (to - from) * CGFloat(step) / CGFloat(steps), .moved), in: window)
        }
        try await pause(0.03)
        try hand(fingers(to, .up), in: window)
    }

    /// One phase of a finger driven from outside, as it happens there (Live
    /// View's live touches): the caller sends down, its moves, then up — or
    /// cancelled, which ends the touch without it counting as a tap. `time`
    /// is the event's moment on this device's clock (mach ticks); now if nil.
    static func pointer(_ phase: Phase, at point: CGPoint, in window: UIWindow, time: UInt64? = nil) throws {
        try send(phase, at: point, in: window, time: time)
    }

    /// This device's clock ticks in a millisecond.
    static let ticksPerMillisecond: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return 1_000_000 * Double(info.denom) / Double(max(info.numer, 1))
    }()

    private static func send(_ phase: Phase, at point: CGPoint, in window: UIWindow, time: UInt64? = nil) throws {
        #if DEBUG || RIPUL_DEVELOPER_BUILD
        guard let hid = HID.shared else { throw Failure(description: unavailableReason ?? "unavailable") }
        if phase == .down { fingerIsFromEdge = isAtEdge(point, of: window) }
        try hid.send([(index: 2, screenPoint: window.convert(point, to: window.screen.coordinateSpace), phase: phase,
                       fromEdge: fingerIsFromEdge)], window: window, time: time)
        #else
        throw Failure(description: unavailableReason ?? "unavailable")
        #endif
    }
}

#if DEBUG || RIPUL_DEVELOPER_BUILD
/// The private functions, resolved once. nil if any is missing.
@MainActor
private final class HID {
    static let shared: HID? = HID()

    // IOHIDEventCreateDigitizerEvent(allocator, timeStamp, transducerType, index, identity,
    //   eventMask, buttonMask, x, y, z, tipPressure, barrelPressure, range, touch, options)
    private typealias CreateDigitizer = @convention(c) (
        OpaquePointer?, UInt64, UInt32, UInt32, UInt32, UInt32, UInt32,
        Double, Double, Double, Double, Double, UInt8, UInt8, UInt32) -> OpaquePointer?
    // IOHIDEventCreateDigitizerFingerEventWithQuality(allocator, timeStamp, index, identity,
    //   eventMask, x, y, z, tipPressure, twist, minorRadius, majorRadius, quality, density,
    //   irregularity, range, touch, options)
    private typealias CreateFinger = @convention(c) (
        OpaquePointer?, UInt64, UInt32, UInt32, UInt32,
        Double, Double, Double, Double, Double, Double, Double, Double, Double, Double,
        UInt8, UInt8, UInt32) -> OpaquePointer?
    private typealias AppendEvent = @convention(c) (OpaquePointer, OpaquePointer, UInt32) -> Void
    private typealias SetInteger = @convention(c) (OpaquePointer, UInt32, Int) -> Void
    private typealias SetSender = @convention(c) (OpaquePointer, UInt64) -> Void
    // BKSHIDEventSetDigitizerInfo(event, contextID, systemGestureIsPossible,
    //   isSystemGestureStateChangeEvent, displayUUID, initialTouchTimestamp, maxForce)
    private typealias SetDigitizerInfo = @convention(c) (
        OpaquePointer, UInt32, UInt8, UInt8, OpaquePointer?, Double, Float) -> Void
    private typealias Enqueue = @convention(c) (AnyObject, Selector, OpaquePointer) -> Void
    private typealias ContextID = @convention(c) (AnyObject, Selector) -> UInt32

    // IOHIDEventTypes.h
    private let transducerHand: UInt32 = 3
    private let eventRange: UInt32 = 1 << 0
    private let eventTouch: UInt32 = 1 << 1
    private let eventPosition: UInt32 = 1 << 2
    private let eventCancel: UInt32 = 1 << 7
    private let eventFromEdgeTip: UInt32 = 1 << 11
    private let fieldBuiltIn: UInt32 = 4                              // IOHIDEventFieldBase(NULL) + 4
    private let fieldIsDisplayIntegrated: UInt32 = (11 << 16) | 25   // IOHIDEventFieldBase(Digitizer) + 25
    private let senderID: UInt64 = 0x0000_0001_0000_027F

    private let createDigitizer: CreateDigitizer
    private let createFinger: CreateFinger
    private let append: AppendEvent
    private let setInteger: SetInteger
    private let setSender: SetSender
    private let setDigitizerInfo: SetDigitizerInfo
    private let enqueueSelector = NSSelectorFromString("_enqueueHIDEvent:")
    private let contextSelector = NSSelectorFromString("_contextId")

    private init?() {
        _ = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_LAZY)
        func load<T>(_ name: String, as: T.Type) -> T? {
            guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }  // RTLD_DEFAULT
            return unsafeBitCast(symbol, to: T.self)
        }
        guard let createDigitizer = load("IOHIDEventCreateDigitizerEvent", as: CreateDigitizer.self),
              let createFinger = load("IOHIDEventCreateDigitizerFingerEventWithQuality", as: CreateFinger.self),
              let append = load("IOHIDEventAppendEvent", as: AppendEvent.self),
              let setInteger = load("IOHIDEventSetIntegerValue", as: SetInteger.self),
              let setSender = load("IOHIDEventSetSenderID", as: SetSender.self),
              let setDigitizerInfo = load("BKSHIDEventSetDigitizerInfo", as: SetDigitizerInfo.self),
              UIApplication.shared.responds(to: enqueueSelector),
              UIWindow.instancesRespond(to: contextSelector)
        else { return nil }
        self.createDigitizer = createDigitizer
        self.createFinger = createFinger
        self.append = append
        self.setInteger = setInteger
        self.setSender = setSender
        self.setDigitizerInfo = setDigitizerInfo
    }

    /// One hand event carrying one finger, addressed to `window`'s context and
    /// queued on UIKit's event queue like a digitizer event from backboardd.
    private func phaseMask(_ phase: TouchSynthesizer.Phase) -> UInt32 {
        switch phase {
        case .moved: eventPosition
        case .held: 0
        case .cancelled: eventRange | eventTouch | eventCancel
        case .down, .up: eventRange | eventTouch
        }
    }

    /// One hand event carrying every finger given, as a digitizer reports a
    /// hand: those that changed with what changed, the rest as still down.
    func send(_ fingers: [(index: UInt32, screenPoint: CGPoint, phase: TouchSynthesizer.Phase, fromEdge: Bool)],
              window: UIWindow, time: UInt64? = nil) throws {
        let time = time ?? mach_absolute_time()
        let anyDown: UInt8 = fingers.contains { $0.phase != .up && $0.phase != .cancelled } ? 1 : 0
        func mask(of finger: (index: UInt32, screenPoint: CGPoint, phase: TouchSynthesizer.Phase, fromEdge: Bool)) -> UInt32 {
            phaseMask(finger.phase) | (finger.fromEdge ? eventFromEdgeTip : 0)
        }
        let handMask = fingers.reduce(UInt32(0)) { $0 | mask(of: $1) }
        guard let hand = createDigitizer(nil, time, transducerHand, 0, 0, handMask, 0,
                                         0, 0, 0, 0, 0, anyDown, anyDown, 0) else {
            throw TouchSynthesizer.Failure(description: "could not create the touch event")
        }
        defer { release(hand) }
        setInteger(hand, fieldIsDisplayIntegrated, 1)
        setInteger(hand, fieldBuiltIn, 1)
        setSender(hand, senderID)
        for finger in fingers {
            let touching: UInt8 = finger.phase == .up || finger.phase == .cancelled ? 0 : 1
            guard let event = createFinger(nil, time, finger.index, finger.index, mask(of: finger),
                                           Double(finger.screenPoint.x), Double(finger.screenPoint.y),
                                           0, 0, 0, 5, 5, 1, 1, 1, touching, touching, 0) else {
                throw TouchSynthesizer.Failure(description: "could not create the finger event")
            }
            setInteger(event, fieldIsDisplayIntegrated, 1)
            append(hand, event, 0)
            release(event)   // the hand event holds it now
        }
        let contextID = unsafeBitCast(window.method(for: contextSelector), to: ContextID.self)(window, contextSelector)
        setDigitizerInfo(hand, contextID, 0, 0, nil, 0, 0)
        let application = UIApplication.shared
        unsafeBitCast(application.method(for: enqueueSelector), to: Enqueue.self)(application, enqueueSelector, hand)
    }

    private func release(_ event: OpaquePointer) {
        Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(event)).release()
    }
}
#endif

#endif
