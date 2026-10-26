import Foundation
import CoreGraphics

#if canImport(UIKit)
import UIKit
import QuartzCore
#endif

// MARK: - Pure trajectory & anomaly analysis (ungated for `swift test`)

/// Pure analysis of frame-by-frame presentation-layer trajectories for
/// `layer_animations` action `trace`.
///
/// Ungated so `swift test` on macOS can exercise spike, reversal, mid-flight
/// freeze, and keyframe compaction without UIKit.
enum LayerMotionAnalysis {
    struct Sample: Equatable {
        let ms: Int
        let x: Double
        let y: Double
        let w: Double
        let h: Double
        let opacity: Double
        let scaleX: Double
        let scaleY: Double
        let tx: Double
        let ty: Double
        let scrollX: Double
        let scrollY: Double
        let radius: Double

        init(
            ms: Int,
            x: Double, y: Double, w: Double, h: Double,
            opacity: Double = 1.0,
            scaleX: Double = 1.0, scaleY: Double = 1.0,
            tx: Double = 0, ty: Double = 0,
            scrollX: Double = 0, scrollY: Double = 0,
            radius: Double = 0
        ) {
            self.ms = ms
            self.x = x
            self.y = y
            self.w = w
            self.h = h
            self.opacity = opacity
            self.scaleX = scaleX
            self.scaleY = scaleY
            self.tx = tx
            self.ty = ty
            self.scrollX = scrollX
            self.scrollY = scrollY
            self.radius = radius
        }

        func roughlyEquals(_ other: Sample) -> Bool {
            changedKinds(from: other).isEmpty
        }

        func changedKinds(from other: Sample) -> [String] {
            var kinds: [String] = []
            if abs(x - other.x) >= 0.5 || abs(y - other.y) >= 0.5 { kinds.append("position") }
            if abs(w - other.w) >= 0.5 || abs(h - other.h) >= 0.5 { kinds.append("size") }
            if abs(opacity - other.opacity) >= 0.015 { kinds.append("opacity") }
            if abs(scaleX - other.scaleX) >= 0.01 || abs(scaleY - other.scaleY) >= 0.01 { kinds.append("scale") }
            if abs(tx - other.tx) >= 0.5 || abs(ty - other.ty) >= 0.5 { kinds.append("transform") }
            if abs(scrollX - other.scrollX) >= 0.5 || abs(scrollY - other.scrollY) >= 0.5 { kinds.append("scroll") }
            if abs(radius - other.radius) >= 0.5 { kinds.append("radius") }
            return kinds
        }

        /// Total scalar distance from `other` across geometry and opacity (scaled to points).
        func distance(from other: Sample) -> Double {
            let dx = abs(x - other.x) + abs(tx - other.tx)
            let dy = abs(y - other.y) + abs(ty - other.ty) + abs(scrollY - other.scrollY)
            let dw = abs(w - other.w)
            let dh = abs(h - other.h)
            let dop = abs(opacity - other.opacity) * 100.0
            let dsc = (abs(scaleX - other.scaleX) + abs(scaleY - other.scaleY)) * 100.0
            return dx + dy + dw + dh + dop + dsc
        }

        func dictionary() -> [String: Any] {
            var dict: [String: Any] = [
                "ms": ms,
                "x": Int(x.rounded()),
                "y": Int(y.rounded()),
                "w": Int(w.rounded()),
                "h": Int(h.rounded()),
            ]
            if opacity < 0.99 { dict["opacity"] = (opacity * 100).rounded() / 100 }
            if abs(scaleX - 1) >= 0.01 || abs(scaleY - 1) >= 0.01 {
                dict["scale"] = [(scaleX * 100).rounded() / 100, (scaleY * 100).rounded() / 100]
            }
            if abs(scrollX) >= 1 || abs(scrollY) >= 1 {
                dict["scroll"] = [Int(scrollX.rounded()), Int(scrollY.rounded())]
            }
            if radius >= 1 { dict["radius"] = Int(radius.rounded()) }
            return dict
        }
    }

    struct Anomaly: Equatable {
        let kind: String
        let atMs: Int
        let durationMs: Int?
        let property: String?
        let detail: String

        func dictionary() -> [String: Any] {
            var out: [String: Any] = [
                "kind": kind,
                "atMs": atMs,
                "detail": detail,
            ]
            if let durationMs { out["durationMs"] = durationMs }
            if let property { out["property"] = property }
            return out
        }
    }

    struct Summary {
        let changes: Int
        let kinds: [String]
        let firstMovedMs: Int
        let settledAtMs: Int
        let activeDurationMs: Int
        let startSample: Sample
        let endSample: Sample
        let anomalies: [Anomaly]
        let keyframes: [Sample]
    }

    /// Analyze a chronological sequence of presentation samples for one view/layer.
    /// Returns `nil` if the view never moved across the entire trace.
    static func summarize(samples: [Sample], maxKeyframes: Int = 18) -> Summary? {
        guard samples.count >= 2 else { return nil }
        var changedIndices: [Int] = []
        var allKinds = Set<String>()
        for i in 1..<samples.count {
            let kinds = samples[i].changedKinds(from: samples[i - 1])
            if !kinds.isEmpty {
                changedIndices.append(i)
                allKinds.formUnion(kinds)
            }
        }
        guard let firstChanged = changedIndices.first, let lastChanged = changedIndices.last else {
            return nil
        }

        let firstMovedMs = samples[firstChanged].ms
        let settledAtMs = samples[lastChanged].ms
        let activeDurationMs = max(0, settledAtMs - firstMovedMs)

        var anomalies: [Anomaly] = []
        var anomalySampleIndices = Set<Int>()

        // 1. Single-frame / two-frame spike (flash): sample jumps away from its
        //    predecessor and immediately snaps back within 1-2 frames (<= 45ms).
        var i = 1
        while i < samples.count - 1 {
            let before = samples[i - 1]
            let current = samples[i]
            let jump = current.distance(from: before)
            if jump >= 12.0 {
                // Check if sample i+1 (1-frame spike) or i+2 (2-frame spike) returns to `before`.
                if current.ms - before.ms <= 45 {
                    let after1 = samples[i + 1]
                    if after1.ms - current.ms <= 45 && after1.distance(from: before) <= max(2.0, jump * 0.15) {
                        let kinds = current.changedKinds(from: before).joined(separator: ",")
                        anomalies.append(Anomaly(
                            kind: "single_frame_spike",
                            atMs: current.ms,
                            durationMs: max(1, after1.ms - current.ms),
                            property: kinds.isEmpty ? nil : kinds,
                            detail: "1-frame spike at +\(current.ms)ms (\(kinds)) before snapping back at +\(after1.ms)ms"
                        ))
                        anomalySampleIndices.insert(i)
                        anomalySampleIndices.insert(i + 1)
                        i += 2
                        continue
                    } else if i + 2 < samples.count {
                        let after2 = samples[i + 2]
                        if after2.ms - before.ms <= 60 && after2.distance(from: before) <= max(2.0, jump * 0.15) {
                            let kinds = current.changedKinds(from: before).joined(separator: ",")
                            anomalies.append(Anomaly(
                                kind: "single_frame_spike",
                                atMs: current.ms,
                                durationMs: max(1, after2.ms - current.ms),
                                property: kinds.isEmpty ? nil : kinds,
                                detail: "2-frame spike at +\(current.ms)ms (\(kinds)) before snapping back at +\(after2.ms)ms"
                            ))
                            anomalySampleIndices.insert(i)
                            anomalySampleIndices.insert(i + 2)
                            i += 3
                            continue
                        }
                    }
                }
            }
            i += 1
        }

        // 2. Mid-flight freeze: between `firstChanged` and `lastChanged`, the view
        //    stops changing for >= 80ms while at least 15% of its total travel
        //    still remains before `lastChanged`.
        let totalTravel = max(1.0, samples[lastChanged].distance(from: samples[max(0, firstChanged - 1)]))
        for pairIndex in 0..<(changedIndices.count - 1) {
            let stallStartIdx = changedIndices[pairIndex]
            let resumeIdx = changedIndices[pairIndex + 1]
            let stallStartMs = samples[stallStartIdx].ms
            let freezeDurationMs = samples[resumeIdx].ms - stallStartMs
            guard freezeDurationMs >= 80 else { continue }
            let remainingTravel = samples[lastChanged].distance(from: samples[stallStartIdx])
            let completedTravel = samples[stallStartIdx].distance(from: samples[max(0, firstChanged - 1)])
            if completedTravel >= max(4.0, totalTravel * 0.10) && remainingTravel >= max(4.0, totalTravel * 0.15) {
                anomalies.append(Anomaly(
                    kind: "mid_flight_freeze",
                    atMs: stallStartMs,
                    durationMs: freezeDurationMs,
                    property: nil,
                    detail: "Froze mid-flight for \(freezeDurationMs)ms (+\(stallStartMs)ms to +\(samples[resumeIdx].ms)ms) before settling"
                ))
                anomalySampleIndices.insert(stallStartIdx)
                anomalySampleIndices.insert(max(stallStartIdx, resumeIdx - 1))
                anomalySampleIndices.insert(resumeIdx)
            }
        }

        // 3. Direction reversal / nod (excluding 1-frame spikes):
        //    Check primary axes (`x`, `y`, `w`, `h`, `scrollY`).
        let axes: [(name: String, extract: (Sample) -> Double)] = [
            ("x", \.x), ("y", \.y), ("w", \.w), ("h", \.h), ("scrollY", \.scrollY)
        ]
        let nonSpikeIndices = (0..<samples.count).filter { !anomalySampleIndices.contains($0) }
        if nonSpikeIndices.count >= 3 {
            for axis in axes {
                let startVal = axis.extract(samples[nonSpikeIndices[0]])
                var minVal = startVal, maxVal = startVal
                var minIdx = nonSpikeIndices[0], maxIdx = nonSpikeIndices[0]
                for idx in nonSpikeIndices {
                    let v = axis.extract(samples[idx])
                    if v < minVal { minVal = v; minIdx = idx }
                    if v > maxVal { maxVal = v; maxIdx = idx }
                }
                let endVal = axis.extract(samples[nonSpikeIndices.last!])
                let upExcursion = maxVal - startVal
                let downExcursion = startVal - minVal
                // Did it move >= 6pt one way and then pull back >= 5pt toward/past start?
                if upExcursion >= 6.0 && (maxVal - endVal) >= 5.0 && maxIdx > nonSpikeIndices.first! && maxIdx < nonSpikeIndices.last! {
                    let peakMs = samples[maxIdx].ms
                    anomalies.append(Anomaly(
                        kind: "reversal",
                        atMs: peakMs,
                        durationMs: nil,
                        property: axis.name,
                        detail: "\(axis.name) moved +\(Int(upExcursion.rounded()))pt (peak at +\(peakMs)ms) then reversed -\(Int((maxVal - endVal).rounded()))pt"
                    ))
                    anomalySampleIndices.insert(maxIdx)
                } else if downExcursion >= 6.0 && (endVal - minVal) >= 5.0 && minIdx > nonSpikeIndices.first! && minIdx < nonSpikeIndices.last! {
                    let peakMs = samples[minIdx].ms
                    anomalies.append(Anomaly(
                        kind: "reversal",
                        atMs: peakMs,
                        durationMs: nil,
                        property: axis.name,
                        detail: "\(axis.name) moved -\(Int(downExcursion.rounded()))pt (peak at +\(peakMs)ms) then reversed +\(Int((endVal - minVal).rounded()))pt"
                    ))
                    anomalySampleIndices.insert(minIdx)
                }
            }
        }

        // Build compact keyframes preserving start, pre-move, first move, anomalies, and settled end.
        var mustKeep = Set<Int>([0, max(0, firstChanged - 1), firstChanged, lastChanged])
        mustKeep.formUnion(anomalySampleIndices)
        var selected = mustKeep.sorted()
        let remainingBudget = max(0, maxKeyframes - selected.count)
        if remainingBudget > 0 && changedIndices.count > 2 {
            let candidates = changedIndices.filter { !mustKeep.contains($0) }
            if candidates.count <= remainingBudget {
                selected.append(contentsOf: candidates)
            } else {
                for step in 0..<remainingBudget {
                    let pos = Int((Double(step) * Double(candidates.count - 1) / Double(max(1, remainingBudget - 1))).rounded())
                    selected.append(candidates[pos])
                }
            }
            selected = Array(Set(selected)).sorted()
        }
        let keyframes = selected.map { samples[$0] }

        return Summary(
            changes: changedIndices.count,
            kinds: allKinds.sorted(),
            firstMovedMs: firstMovedMs,
            settledAtMs: settledAtMs,
            activeDurationMs: activeDurationMs,
            startSample: samples.first!,
            endSample: samples[lastChanged],
            anomalies: anomalies,
            keyframes: keyframes
        )
    }
}

#if canImport(UIKit)

// MARK: - Live 120Hz presentation-layer tracer (`layer_animations` action `trace`)

/// Records 120Hz `layer.presentation()` trajectories, main-thread wake hitches,
/// SwiftUI `_printChanges()` body evaluations, and optional inline finger
/// gestures in one atomic call.
@MainActor
final class LayerMotionTracer {
    private final class TrackedView {
        weak var view: UIView?
        let ownerName: String
        let id: String?
        let ancestors: [String]
        let matchesFilter: Bool
        var samples: [LayerMotionAnalysis.Sample] = []

        init(view: UIView, ownerName: String, id: String?, ancestors: [String], matchesFilter: Bool) {
            self.view = view
            self.ownerName = ownerName
            self.id = id
            self.ancestors = ancestors
            self.matchesFilter = matchesFilter
        }
    }

    private struct Hitch {
        let atMs: Int
        let gapMs: Double
        let wakeMs: Double
        let phase: String
        let marks: [String]

        func dictionary() -> [String: Any] {
            var out: [String: Any] = [
                "atMs": atMs,
                "gapMs": (gapMs * 10).rounded() / 10,
                "wakeMs": (wakeMs * 10).rounded() / 10,
                "phase": phase,
            ]
            if !marks.isEmpty { out["marks"] = marks }
            return out
        }
    }

    private let seconds: TimeInterval
    private let limit: Int
    private let matchTerms: [String]
    private let touchArgs: [String: Any]?

    private var link: CADisplayLink?
    private var observer: CFRunLoopObserver?
    private var startedAt: CFTimeInterval = 0
    private var lastFrameAt: CFTimeInterval = 0
    private var wokeAt: CFTimeInterval = 0
    private var currentWakeDuration: CFTimeInterval = 0
    private var totalAwake: CFTimeInterval = 0
    private var wakes = 0
    private var frames = 0
    private var touchStartedMs: Int?
    private var touchEndedMs: Int?
    private var touchResult: [String: Any]?
    private var touchInFlight = false

    private var tracked: [ObjectIdentifier: TrackedView] = [:]
    private var marks: [(at: CFTimeInterval, label: String)] = []
    private var hitches: [Hitch] = []
    private var completion: (([String: Any]) -> Void)?

    private init(seconds: TimeInterval, limit: Int, match: String?, touchArgs: [String: Any]?) {
        self.seconds = seconds
        self.limit = limit
        if let match, !match.isEmpty {
            self.matchTerms = match
                .split { $0 == "," || $0 == "|" }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        } else {
            self.matchTerms = []
        }
        self.touchArgs = touchArgs
    }

    static func trace(
        seconds: TimeInterval,
        limit: Int,
        match: String?,
        touch: [String: Any]?
    ) async -> [String: Any] {
        let tracer = LayerMotionTracer(seconds: seconds, limit: limit, match: match, touchArgs: touch)
        let result: [String: Any] = await withCheckedContinuation { continuation in
            tracer.completion = { continuation.resume(returning: $0) }
            tracer.start()
        }
        // Timers and the display-link target deliberately hold weak references.
        // The suspended caller must own the trace until its timer finishes.
        withExtendedLifetime(tracer) {}
        return result
    }

    private func start() {
        startedAt = CACurrentMediaTime()
        lastFrameAt = startedAt

        // Hook `ChatSlideProbe` so SwiftUI `_printChanges()` bodies and watched
        // `ObservableObject` setters feed into our mark stream during the trace.
        ChatSlideProbe.shared.externalMarkSink = { [weak self] time, label in
            self?.marks.append((time, label))
        }

        // Measure main-thread runloop wakes so even a first-frame stall (before
        // the second CADisplayLink callback) is caught and timed accurately.
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        let obs = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, activities, true, CFIndex.max) { [weak self] _, activity in
            MainActor.assumeIsolated { self?.observedRunLoop(activity) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), obs, .commonModes)
        self.observer = obs

        // Capture baseline frame at +0ms before any gesture begins.
        sampleAll(at: startedAt)

        let displayLink = CADisplayLink(target: Target(self), selector: #selector(Target.tick(_:)))
        displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        displayLink.add(to: .main, forMode: .common)
        self.link = displayLink

        if let touchArgs {
            touchInFlight = true
            Task { @MainActor [weak self] in
                // Yield one turn so CADisplayLink is live on the runloop.
                await Task.yield()
                guard let self, self.link != nil else { return }
                let startMs = Int(((CACurrentMediaTime() - self.startedAt) * 1000).rounded())
                self.touchStartedMs = startMs
                self.marks.append((CACurrentMediaTime(), "touch.start"))
                let out = (try? await TouchTool().execute(args: touchArgs)) as? [String: Any]
                let endMs = Int(((CACurrentMediaTime() - self.startedAt) * 1000).rounded())
                self.touchEndedMs = endMs
                self.touchResult = out
                self.touchInFlight = false
                self.marks.append((CACurrentMediaTime(), "touch.end"))
            }
        }

        scheduleFinish(after: seconds)
    }

    private func scheduleFinish(after delay: TimeInterval) {
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // If an inline touch is still running, let it finish + 250ms settle
                // (up to a hard 10s ceiling).
                let elapsed = CACurrentMediaTime() - self.startedAt
                if self.touchInFlight && elapsed < 10.0 {
                    self.scheduleFinish(after: 0.25)
                    return
                }
                self.finish()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func observedRunLoop(_ activity: CFRunLoopActivity) {
        let now = CACurrentMediaTime()
        if activity == .afterWaiting {
            wakes += 1
            wokeAt = now
        } else if wokeAt > 0 {
            let duration = now - wokeAt
            totalAwake += duration
            currentWakeDuration = max(currentWakeDuration, duration)
            wokeAt = 0
        }
    }

    fileprivate func onDisplayLink(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let gap = now - lastFrameAt
        let expected = max(link.duration, 1.0 / 120.0)
        let wakeMs = currentWakeDuration * 1000.0
        currentWakeDuration = 0

        frames += 1
        // Record a hitch if either the display link missed its deadline by >1.6x
        // (and >= 20ms) or a main-thread wake inside the frame took >= 20ms.
        if (gap > expected * 1.6 && gap >= 0.020) || wakeMs >= 20.0 {
            let atMs = Int(((lastFrameAt - startedAt) * 1000).rounded())
            let nearby = marks
                .filter { $0.at >= lastFrameAt - expected && $0.at <= now + 0.002 }
                .map(\.label)
            let phase: String
            if let touchStartedMs {
                if let touchEndedMs, atMs >= touchEndedMs {
                    phase = "settle"
                } else if atMs >= touchStartedMs {
                    phase = "gesture"
                } else {
                    phase = "pre_gesture"
                }
            } else {
                phase = "active"
            }
            hitches.append(Hitch(
                atMs: max(0, atMs),
                gapMs: gap * 1000.0,
                wakeMs: wakeMs,
                phase: phase,
                marks: Array(nearby.prefix(8))
            ))
        }
        lastFrameAt = now
        sampleAll(at: now)
    }

    private func sampleAll(at time: CFTimeInterval) {
        let ms = max(0, Int(((time - startedAt) * 1000).rounded()))
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .filter { !$0.isHidden && $0.alpha > 0.01 }

        for window in windows {
            let rootLayer = window.layer.presentation() ?? window.layer
            walk(view: window, rootLayer: rootLayer, ms: ms, parentOpacity: 1.0)
        }
    }

    private func walk(view: UIView, rootLayer: CALayer, ms: Int, parentOpacity: Float) {
        guard !view.isHidden else { return }
        let layer = view.layer
        let pres = layer.presentation() ?? layer
        let effectiveOpacity = parentOpacity * pres.opacity
        guard effectiveOpacity > 0.005 else { return }

        let key = ObjectIdentifier(view)
        let entry: TrackedView
        if let existing = tracked[key] {
            entry = existing
        } else {
            let ownerName = Self.shortTypeName(view)
            let id = LayerAnimationsTool.nearestIdentifier(view)
            let ownId = ScreenElementFinder.identifier(of: view)
            let label = view.accessibilityLabel
            let matches: Bool
            if matchTerms.isEmpty {
                matches = true
            } else {
                let haystack = [id, ownId, ownerName, String(describing: type(of: layer)), label]
                    .compactMap { $0 }
                    .joined(separator: " ")
                    .lowercased()
                matches = matchTerms.contains { haystack.contains($0) }
            }
            let created = TrackedView(
                view: view,
                ownerName: ownerName,
                id: ownId ?? id,
                ancestors: Self.ancestors(of: view),
                matchesFilter: matches
            )
            tracked[key] = created
            entry = created
        }

        if entry.matchesFilter {
            let rect = pres.convert(pres.bounds, to: rootLayer)
            let t = pres.transform
            let scaleX = sqrt(t.m11 * t.m11 + t.m12 * t.m12 + t.m13 * t.m13)
            let scaleY = sqrt(t.m21 * t.m21 + t.m22 * t.m22 + t.m23 * t.m23)
            let scrollOrigin = (view as? UIScrollView)?.contentOffset ?? pres.bounds.origin
            let sample = LayerMotionAnalysis.Sample(
                ms: ms,
                x: rect.minX,
                y: rect.minY,
                w: rect.width,
                h: rect.height,
                opacity: Double(effectiveOpacity),
                scaleX: Double(scaleX),
                scaleY: Double(scaleY),
                tx: Double(t.m41),
                ty: Double(t.m42),
                scrollX: Double(scrollOrigin.x),
                scrollY: Double(scrollOrigin.y),
                radius: Double(pres.cornerRadius)
            )
            entry.samples.append(sample)
        }

        for subview in view.subviews {
            walk(view: subview, rootLayer: rootLayer, ms: ms, parentOpacity: effectiveOpacity)
        }
    }

    private func finish() {
        link?.invalidate()
        link = nil
        if let observer {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            self.observer = nil
        }
        ChatSlideProbe.shared.externalMarkSink = nil

        let elapsed = max(0.001, CACurrentMediaTime() - startedAt)
        struct AnalyzedView {
            let tracked: TrackedView
            let summary: LayerMotionAnalysis.Summary
        }

        var analyzed: [AnalyzedView] = []
        for item in tracked.values where item.matchesFilter {
            if let summary = LayerMotionAnalysis.summarize(samples: item.samples) {
                analyzed.append(AnalyzedView(tracked: item, summary: summary))
            }
        }

        // Deduplicate wrapper views that share the same identifier and moved
        // with the exact same start/end frames and change count.
        analyzed.sort { a, b in
            if a.summary.anomalies.count != b.summary.anomalies.count {
                return a.summary.anomalies.count > b.summary.anomalies.count
            }
            if a.summary.changes != b.summary.changes {
                return a.summary.changes > b.summary.changes
            }
            return (a.tracked.id != nil ? 1 : 0) > (b.tracked.id != nil ? 1 : 0)
        }

        var seenSignatures = Set<String>()
        var deduped: [AnalyzedView] = []
        for item in analyzed {
            let s = item.summary.startSample
            let e = item.summary.endSample
            let sig = "\(item.tracked.id ?? item.tracked.ownerName)|\(Int(s.x)):\(Int(s.y)):\(Int(s.w)):\(Int(s.h))->\(Int(e.x)):\(Int(e.y)):\(Int(e.w)):\(Int(e.h))"
            if seenSignatures.contains(sig) { continue }
            seenSignatures.insert(sig)
            deduped.append(item)
            if deduped.count >= limit { break }
        }

        let globalStartMs = deduped.map(\.summary.firstMovedMs).min()
        let globalEndMs = deduped.map(\.summary.settledAtMs).max()

        let viewReports: [[String: Any]] = deduped.map { item in
            var dict: [String: Any] = [
                "owner": item.tracked.ownerName,
                "changes": item.summary.changes,
                "kinds": item.summary.kinds,
                "firstMovedMs": item.summary.firstMovedMs,
                "settledAtMs": item.summary.settledAtMs,
                "activeDurationMs": item.summary.activeDurationMs,
                "startFrame": item.summary.startSample.dictionary(),
                "endFrame": item.summary.endSample.dictionary(),
                "keyframes": item.summary.keyframes.map { $0.dictionary() },
            ]
            if let id = item.tracked.id { dict["id"] = id }
            if !item.tracked.ancestors.isEmpty { dict["ancestors"] = item.tracked.ancestors }
            if !item.summary.anomalies.isEmpty {
                dict["anomalies"] = item.summary.anomalies.map { $0.dictionary() }
            }
            return dict
        }

        var report: [String: Any] = [
            "success": true,
            "action": "trace",
            "seconds": (elapsed * 100).rounded() / 100,
            "frames": frames,
            "fps": (Double(frames) / elapsed * 10).rounded() / 10,
            "wakesPerSecond": (Double(wakes) / elapsed * 10).rounded() / 10,
            "awakePercent": (totalAwake / elapsed * 1000).rounded() / 10,
            "movingViewsCount": analyzed.count,
            "hitches": hitches.map { $0.dictionary() },
            "views": viewReports,
        ]
        if let globalStartMs, let globalEndMs {
            report["motionWindow"] = [
                "startMs": globalStartMs,
                "endMs": globalEndMs,
                "durationMs": max(0, globalEndMs - globalStartMs),
            ]
        }
        if let touchArgs {
            var touchSummary: [String: Any] = [
                "action": touchArgs["action"] as? String ?? "tap",
                "startedAtMs": touchStartedMs ?? 0,
                "endedAtMs": touchEndedMs ?? 0,
            ]
            if let touchResult {
                touchSummary["success"] = touchResult["success"] as? Bool ?? false
                if let under = touchResult["under"] { touchSummary["under"] = under }
                if let error = touchResult["error"] { touchSummary["error"] = error }
            }
            report["touch"] = touchSummary
        }

        completion?(report)
        completion = nil
    }

    private static func shortTypeName(_ view: UIView) -> String {
        let name = String(describing: type(of: view))
        return name.count > 180 ? String(name.prefix(180)) + "…" : name
    }

    private static func ancestors(of view: UIView) -> [String] {
        var names: [String] = []
        var current = view.superview
        while let node = current, names.count < 4 {
            let name = String(describing: type(of: node))
            let short = name.count > 80 ? String(name.prefix(80)) + "…" : name
            if names.last != short { names.append(short) }
            current = node.superview
        }
        return names
    }

    private final class Target: NSObject {
        weak var tracer: LayerMotionTracer?
        init(_ tracer: LayerMotionTracer) { self.tracer = tracer }
        @objc func tick(_ link: CADisplayLink) {
            MainActor.assumeIsolated { tracer?.onDisplayLink(link) }
        }
    }
}

#endif
