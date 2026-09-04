#if canImport(UIKit)
import UIKit
import QuartzCore

/// Catches main-thread stalls and reports how long the app was actually dead.
///
/// ## Why the heartbeat runs on the main thread
/// The question "is the main thread blocked?" cannot be answered from another
/// thread — a watchdog on a background queue only proves the *process* is alive,
/// which it always is. This timer is scheduled ON the main runloop, so the gap
/// between two fires is measured from inside the very thread that stalls. If the
/// thread is blocked, the fire simply doesn't happen, and the next one carries
/// the whole duration.
///
/// It also answers the *converse*, which is the harder half: if the heartbeat
/// keeps arriving on time and the screen is still frozen, the main thread was
/// never the problem and the fault is in rendering or event delivery. Evidence
/// that rules a cause OUT is worth as much as evidence that rules one in — this
/// exists because two plausible explanations for a freeze had already been
/// chased without either being confirmed.
///
/// Note what it does NOT prove: a fire means the main thread *ran*, not that a
/// frame was *drawn*. Distinguishing "ran but drew nothing" needs a frame-level
/// probe, and is only worth adding if the heartbeat comes back clean.
///
/// ## Why the foreground baseline is reset
/// The timer doesn't fire while the app is backgrounded, so the first fire after
/// a resume would otherwise report the whole time away as a stall.
/// `didBecomeActive` rebases the clock. That is also the moment of interest, so
/// the profile below records the transition itself: how long
/// `willEnterForeground` took to reach `didBecomeActive`, and how long from
/// there to the first tick the main thread actually serviced. Both are
/// main-thread time, and neither is visible in any existing log.
@MainActor
public final class MainThreadStallMonitor {
    public static let shared = MainThreadStallMonitor()

    /// Anything longer than this is a stall worth a line. A dropped frame or
    /// two is normal; a quarter second is something a person notices.
    private static let stallThresholdMs: Double = 250

    /// How often the heartbeat is scheduled. Anything the main thread does for
    /// longer than this shows up as lateness on the next fire.
    private static let tickInterval: TimeInterval = 0.1

    private var timer: Timer?
    private var lastTickAt: CFTimeInterval = 0
    private var willEnterForegroundAt: CFTimeInterval = 0
    private var didBecomeActiveAt: CFTimeInterval = 0
    private var awaitingFirstTick = false
    private var observers: [NSObjectProtocol] = []

    private init() {}

    /// Unqualified `NSLog`, which inside this module resolves to the tee in
    /// `NativeLogTee.swift` and appends to the console buffer synchronously.
    ///
    /// Deliberately NOT a closure supplied by `AgentBridge`. The previous
    /// version routed through one, and produced nothing on device twice running
    /// — a wiring failure indistinguishable, in the logs, from having nothing
    /// to report. This is the same path the `Capability request` lines take, and
    /// those arrive reliably, so it is known-good rather than assumed-good.
    private func emit(_ line: String) {
        NSLog("%@", line)
    }

    public func start() {
        guard timer == nil else { return }
        // A block-based Timer rather than a CADisplayLink with an @objc
        // selector: the first version of this shipped as a display link and
        // produced not one line on device, which cost a whole build-and-install
        // round trip to discover. There is nothing here to mis-resolve at
        // runtime — no selector, no ObjC bridging — and for measuring lateness
        // a heartbeat is every bit as good as a frame callback.
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // .common so it keeps firing during scroll tracking — a stall that only
        // happens with a finger down would otherwise be invisible, and that is
        // exactly when it would be felt most.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        lastTickAt = CACurrentMediaTime()
        // Proof of life. Without it, "no [STALL] lines" is ambiguous between
        // "nothing stalled" and "the instrument never ran" — and this monitor
        // has already been silent once for the second reason while being read
        // as the first.
        emit("[FGPROF] stall monitor armed (threshold \(Int(Self.stallThresholdMs))ms)")

        let nc = NotificationCenter.default
        // Recorded synchronously in the notification handler, NOT via a
        // `Task { @MainActor }` hop like the existing [LIFECYCLE] lines. That
        // distinction is the whole point: a hop is scheduled behind whatever is
        // already on the main actor, so its timestamp reports when the queue
        // drained rather than when the event happened — which is precisely the
        // interval being measured.
        observers.append(nc.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.willEnterForegroundAt = CACurrentMediaTime() }
        })
        observers.append(nc.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.markDidBecomeActive() }
        })
    }

    private func markDidBecomeActive() {
        let now = CACurrentMediaTime()
        didBecomeActiveAt = now
        // Rebase: the time spent backgrounded is not a stall.
        lastTickAt = now
        awaitingFirstTick = true
        guard willEnterForegroundAt > 0 else { return }
        let willToActive = (now - willEnterForegroundAt) * 1000
        emit(String(
            format: "[FGPROF] willEnterForeground -> didBecomeActive %.0fms",
            willToActive
        ))
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let previous = lastTickAt
        lastTickAt = now
        guard previous > 0 else { return }

        if awaitingFirstTick {
            awaitingFirstTick = false
            let toFirstTick = (now - didBecomeActiveAt) * 1000
            let sinceWillEnter = willEnterForegroundAt > 0
                ? (now - willEnterForegroundAt) * 1000
                : toFirstTick
            // The headline number: from the OS saying "you are coming back" to
            // this process servicing its own runloop again. If the freeze is
            // main-thread work, the whole of it lands here.
            emit(String(
                format: "[FGPROF] didBecomeActive -> first tick %.0fms (willEnterForeground -> first tick %.0fms)",
                toFirstTick, sinceWillEnter
            ))
            return
        }

        let gapMs = (now - previous) * 1000
        guard gapMs > Self.stallThresholdMs else { return }
        emit(String(format: "[STALL] main thread blocked %.0fms", gapMs))
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }
}
#endif
