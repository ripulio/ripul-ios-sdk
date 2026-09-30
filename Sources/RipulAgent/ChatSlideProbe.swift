#if canImport(UIKit)
import UIKit
import QuartzCore
import Combine
import Darwin

/// Frame-level probe for the chat <-> session-list slide.
///
/// `MainThreadStallMonitor` only reports gaps over 250ms; a slide stutter is one
/// or two dropped frames (10-60ms) and never shows there. This runs a display
/// link only while a slide is in flight — finger down through the settle
/// spring — and logs every frame that arrived late, with its time since release
/// and whatever `mark`s landed nearby. One `[SLIDEPROBE]` summary per slide, and
/// one `[SLIDEHITCH]` line per late frame.
///
/// `mark` is cheap and inert when no slide is running, so it can sit in body
/// evaluations and model setters that are suspected of landing mid-slide.
@MainActor
public final class ChatSlideProbe {
    public static let shared = ChatSlideProbe()

    private var link: CADisplayLink?
    private var startedAt: CFTimeInterval = 0
    private var releasedAt: CFTimeInterval = 0
    private var lastFrameAt: CFTimeInterval = 0
    private var stopWork: DispatchWorkItem?
    private var frames = 0
    private var hitches = 0
    private var worstGapMs: Double = 0
    private var marks: [(at: CFTimeInterval, label: String)] = []

    private init() {}

    /// Finger down (idempotent across `.changed` frames).
    public func begin() {
        stopWork?.cancel()
        stopWork = nil
        guard link == nil else { return }
        MainThreadSampler.arm()
        startedAt = CACurrentMediaTime()
        releasedAt = 0
        lastFrameAt = 0
        frames = 0
        hitches = 0
        worstGapMs = 0
        marks = []
        let link = CADisplayLink(target: Target(self), selector: #selector(Target.frame(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// Finger up; keep measuring through the settle animation.
    public func release(settle: TimeInterval = 0.7, label: String) {
        guard link != nil else { return }
        releasedAt = CACurrentMediaTime()
        mark("release \(label)")
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.finish() } }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settle, execute: work)
    }

    private var watched: [ObjectIdentifier: AnyCancellable] = [:]

    /// Mark every `objectWillChange` of `object` that fires mid-slide, naming
    /// the setter that caused it. Views re-render because an object they
    /// observe published; this names which property it was, so a stall can be
    /// traced to its source instead of guessed at. Idempotent per object.
    public func watch<O: ObservableObject>(_ object: O, as name: String) {
        let id = ObjectIdentifier(object)
        guard watched[id] == nil else { return }
        watched[id] = object.objectWillChange.sink { _ in
            // objectWillChange fires synchronously from the property's willSet,
            // so the caller is on this stack. Only paid while a slide runs.
            guard Thread.isMainThread else { return }
            MainThreadSampler.count("\(name).pub")
            MainActor.assumeIsolated {
                guard ChatSlideProbe.shared.link != nil else { return }
                ChatSlideProbe.shared.mark("\(name)<-\(Self.callerSummary())")
            }
        }
    }

    private typealias Demangle = @convention(c) (
        UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32
    ) -> UnsafeMutablePointer<CChar>?
    #if DEBUG || RIPUL_DEVELOPER_BUILD
    private static let demangle: Demangle? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle")
        .map { unsafeBitCast($0, to: Demangle.self) }
    #else
    /// Looked up by name, so not in store builds: names stay mangled there.
    private static let demangle: Demangle? = nil
    #endif

    /// The first few app frames above Combine: the setter and whoever called it.
    private static func callerSummary() -> String {
        var frames: [String] = []
        for line in Thread.callStackSymbols.dropFirst(2) {
            // "<n> <image> 0x<addr> <symbol> + <offset>"
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 4 else { continue }
            let image = String(parts[1])
            guard image.hasPrefix("Ripul") || image.hasPrefix("Alice") else { continue }
            var symbol = parts[3...].prefix { $0 != "+" }.joined(separator: " ")
            if let demangle, let out = symbol.withCString({ demangle($0, strlen($0), nil, nil, 0) }) {
                symbol = String(cString: out)
                free(out)
            }
            // Skip the sink itself and the Swift runtime glue around it
            // (MainActor.assumeIsolated's reabstraction thunks).
            let glue = ["ChatSlideProbe", "objectWillChange", "thunk", "partial apply", "assumeIsolated"]
            if glue.contains(where: symbol.contains) { continue }
            symbol = symbol.replacingOccurrences(of: "RipulAgent.", with: "")
                .replacingOccurrences(of: "Ripul.", with: "")
            frames.append(String(symbol.prefix(90)))
            if frames.count == 3 { break }
        }
        return frames.isEmpty ? "?" : frames.joined(separator: " < ")
    }

    public static func mark(_ label: @autoclosure () -> String) {
        guard shared.link != nil else { return }
        shared.mark(label())
    }

    private var deferred: [String: () -> Void] = [:]

    /// Run `work` now, or — while a chat/list slide is in flight (finger down
    /// through the settle) — once it has settled. Later requests under the same
    /// key replace earlier ones, so a burst collapses to one run. For state no
    /// one needs mid-swipe (the session list rebuilt by live agent activity),
    /// whose publish would otherwise re-render the whole shell during the drag.
    /// A fallback flush caps the wait if a gesture ends without a release.
    public static func afterSlide(_ key: String, _ work: @escaping () -> Void) {
        guard shared.link != nil else { work(); return }
        let first = shared.deferred.isEmpty
        shared.deferred[key] = work
        shared.mark("deferred \(key)")
        if first {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                MainActor.assumeIsolated { shared.flushDeferred() }
            }
        }
    }

    private func flushDeferred() {
        let pending = deferred
        deferred = [:]
        for work in pending.values { work() }
    }

    /// Mark a body evaluation and, in debug builds, WHY it ran: SwiftUI's own
    /// `_printChanges()` report ("ContentView: _selectedTab changed."). That
    /// names re-render sources `watch` cannot see — view @State, @Observable
    /// models, environment values. It prints to stdout, so stdout is briefly
    /// redirected into a pipe around the call. Only while a slide is measured.
    public static func markBody(_ name: String, _ printChanges: () -> Void) {
        MainThreadSampler.count("\(name).body")
        guard shared.link != nil else { return }
        #if DEBUG
        var fds: [Int32] = [0, 0]
        fflush(stdout)
        let saved = dup(STDOUT_FILENO)
        guard saved >= 0, pipe(&fds) == 0 else { shared.mark("\(name).body"); return }
        dup2(fds[1], STDOUT_FILENO)
        printChanges()
        fflush(stdout)
        dup2(saved, STDOUT_FILENO)
        close(saved)
        close(fds[1])
        let data = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true).readDataToEndOfFile()
        let report = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " / ")
        shared.mark(report.isEmpty ? "\(name).body" : "\(name).body{\(report.prefix(240))}")
        #else
        shared.mark("\(name).body")
        #endif
    }

    private func mark(_ label: String) {
        marks.append((CACurrentMediaTime(), label))
    }

    private func relative(_ t: CFTimeInterval) -> String {
        let base = releasedAt > 0 ? releasedAt : startedAt
        let tag = releasedAt > 0 ? "rel" : "start"
        return String(format: "%@%+.0fms", tag, (t - base) * 1000)
    }

    fileprivate func frame(_ link: CADisplayLink) {
        let now = link.timestamp
        defer { lastFrameAt = now }
        guard lastFrameAt > 0 else { return }
        frames += 1
        let expected = max(link.duration, 1.0 / 120.0)
        let gap = now - lastFrameAt
        guard gap > expected * 1.6 else { return }
        hitches += 1
        let gapMs = gap * 1000
        worstGapMs = max(worstGapMs, gapMs)
        // Marks inside (or just before) the late frame are the suspects.
        let nearby = marks.filter { $0.at >= lastFrameAt - expected && $0.at <= now }
            .map(\.label)
        NSLog("%@", String(format: "[SLIDEHITCH] %@ gap=%.1fms (%.1f frames) phase=%@ marks=[%@]",
            relative(lastFrameAt), gapMs, gap / expected,
            releasedAt > 0 && lastFrameAt >= releasedAt ? "settle" : "drag",
            nearby.joined(separator: ", ")))
    }

    private func finish() {
        link?.invalidate()
        link = nil
        stopWork = nil
        MainThreadSampler.disarm()
        defer { flushDeferred() }
        let timeline = marks.map { "\(relative($0.at)) \($0.label)" }.joined(separator: " | ")
        NSLog("%@", String(format: "[SLIDEPROBE] frames=%d hitches=%d worst=%.1fms timeline: %@",
            frames, hitches, worstGapMs, timeline))
    }

    /// CADisplayLink retains its target; this breaks the cycle.
    private final class Target: NSObject {
        weak var probe: ChatSlideProbe?
        init(_ probe: ChatSlideProbe) { self.probe = probe }
        @objc func frame(_ link: CADisplayLink) {
            MainActor.assumeIsolated { probe?.frame(link) }
        }
    }
}
#else
/// No slide to measure on AppKit; `mark` stays callable from shared code.
@MainActor
public enum ChatSlideProbe {
    public static func mark(_ label: @autoclosure () -> String) {}
    public static func markBody(_ name: String, _ printChanges: () -> Void) {}
    public static func afterSlide(_ key: String, _ work: @escaping () -> Void) { work() }
}
#endif
