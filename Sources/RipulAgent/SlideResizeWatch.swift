import Foundation
#if DEBUG && canImport(UIKit)
import UIKit
import QuartzCore

/// What changes size, and which bodies run, while a page slides (Peter,
/// 5 November 2026: a sliding page "pointlessly re-draws a screen at new
/// widths just before it's about to be ejected", the chat's composer for one).
/// A page that slides should keep its layout and only move: SwiftUI moves the
/// frames of the UIKit views it carries, so a size that changes mid-slide is a
/// relayout, and a body that runs mid-slide is a redraw nobody asked for.
///
/// Off unless launched with `-ripul.debug.slideResize YES`. Then every slide
/// that tells a `SlideDisplacement` where it is (Home's way back, the chat's
/// columns, the drawer, slide-in panels) is watched from its first moving
/// frame until it has been still for a moment: the key window's views and
/// their own layers are measured every frame, against a reading taken at rest
/// beforehand, and each slide's report is logged (`[SLIDERESIZE]`) and added
/// to `Documents/slide-resize.json`. It walks the whole window every frame, so
/// it is a measuring tool, not something to leave on.
@MainActor
public final class SlideResizeWatch {
    public nonisolated static let enabled = UserDefaults.standard.bool(forKey: "ripul.debug.slideResize")
    static let shared = SlideResizeWatch()

    /// A view or layer, keyed by identity, with what it was measured as.
    private struct Seen {
        var label: String
        var minW: CGFloat, maxW: CGFloat, minH: CGFloat, maxH: CGFloat
        var frames: Int
        var rest: CGSize?
        mutating func add(_ size: CGSize) {
            minW = min(minW, size.width); maxW = max(maxW, size.width)
            minH = min(minH, size.height); maxH = max(maxH, size.height)
            frames += 1
        }
    }

    private var link: CADisplayLink?
    private var active = false
    private var startedAt: CFTimeInterval = 0
    private var lastMoveAt: CFTimeInterval = 0
    private var lastIdleReadingAt: CFTimeInterval = 0
    private var restReading: [ObjectIdentifier: (String, CGSize)] = [:]
    private var seen: [ObjectIdentifier: Seen] = [:]
    private var bodies: [String: Int] = [:]
    private var movingFrames = 0
    private var furthest: CGFloat = 0
    private var slides = 0

    private init() {}

    /// Every frame a slide draws, with how far it has the views it carries
    /// from where they rest (`SlideEffect.effectValue`). Inert when off.
    nonisolated static func moved(_ x: CGFloat) {
        guard enabled else { return }
        MainActor.assumeIsolated { shared.move(x) }
    }

    /// A value a view measured, logged with the slide's place when it changes:
    /// what a body that ran mid-slide was told.
    nonisolated static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let text = message()
        MainActor.assumeIsolated {
            let x = shared.active ? String(format: " (sliding, %.0fpt)", shared.furthest) : ""
            NSLog("%@", "[SLIDERESIZE] \(text)\(x)")
        }
    }

    /// A body evaluated, or a setter published, during a slide (`ChatSlideProbe.mark`).
    static func note(_ label: String) {
        guard enabled, shared.active else { return }
        // While it moves, or in the moment after it stopped (the landing's own work).
        let moving = CACurrentMediaTime() - shared.lastMoveAt < 0.05
        shared.bodies[moving ? label : "\(label) (after it stopped)", default: 0] += 1
    }

    private func move(_ x: CGFloat) {
        let now = CACurrentMediaTime()
        lastMoveAt = now
        furthest = max(furthest, abs(x))
        startLink()
        guard !active else { return }
        active = true
        startedAt = now
        movingFrames = 0
        furthest = abs(x)
        bodies = [:]
        seen = [:]
        // The reading taken at rest just before: what each thing was.
        if restReading.isEmpty { restReading = read() }
        for (id, (label, size)) in restReading {
            seen[id] = Seen(label: label, minW: size.width, maxW: size.width, minH: size.height, maxH: size.height,
                            frames: 0, rest: size)
        }
    }

    private func startLink() {
        guard link == nil else { return }
        let link = CADisplayLink(target: Target(self), selector: #selector(Target.frame(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// Started at launch, so the first slide has a reading at rest to compare with.
    public static func start() {
        guard enabled else { return }
        shared.startLink()
    }

    fileprivate func frame(_ link: CADisplayLink) {
        let now = link.timestamp
        guard active else {
            // At rest: keep a reading from no more than half a second ago.
            if now - lastIdleReadingAt > 0.5 {
                lastIdleReadingAt = now
                restReading = read()
            }
            return
        }
        movingFrames += 1
        merge(read())
        // Still for a moment: the slide is over. Read once more at rest.
        if now - lastMoveAt > 0.4 {
            merge(read(), atRest: true)
            finish(duration: now - startedAt)
            active = false
            restReading = read()
            lastIdleReadingAt = now
        }
    }

    private func merge(_ reading: [ObjectIdentifier: (String, CGSize)], atRest: Bool = false) {
        for (id, (label, size)) in reading {
            if var entry = seen[id] {
                entry.add(size)
                seen[id] = entry
            } else {
                // Made during the slide: measured from now on.
                seen[id] = Seen(label: label, minW: size.width, maxW: size.width, minH: size.height, maxH: size.height,
                                frames: 1, rest: nil)
            }
        }
    }

    /// Every view in the key window and the layers each draws itself (not
    /// another view's), by identity, with the nearest accessibility
    /// identifier above it as its name.
    private func read() -> [ObjectIdentifier: (String, CGSize)] {
        var out: [ObjectIdentifier: (String, CGSize)] = [:]
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .filter { !$0.isHidden && $0.isKeyWindow }
        for window in windows { walk(window, named: "", parents: "", depth: 0, into: &out) }
        return out
    }

    private func walk(_ view: UIView, named: String, parents: String, depth: Int,
                      into out: inout [ObjectIdentifier: (String, CGSize)]) {
        guard depth < 160, !view.isHidden, view.alpha > 0.01 else { return }
        let id = view.accessibilityIdentifier.flatMap { $0.isEmpty ? nil : $0 }
        let name = id ?? named
        let kind = String(describing: type(of: view))
        // Two views up, to tell one plain container from another.
        let described = "\(kind)\(parents)\(name.isEmpty ? "" : " in \(name)")"
        out[ObjectIdentifier(view)] = (described, view.bounds.size)
        if let sublayers = view.layer.sublayers {
            for layer in sublayers where !(layer.delegate is UIView) {
                walk(layer, in: "\(kind)\(parents)", named: name, depth: 0, into: &out)
            }
        }
        let below = " < \(kind)" + (parents.components(separatedBy: " < ").dropFirst().first.map { " < \($0)" } ?? "")
        for subview in view.subviews { walk(subview, named: name, parents: below, depth: depth + 1, into: &out) }
    }

    private func walk(_ layer: CALayer, in owner: String, named: String, depth: Int,
                      into out: inout [ObjectIdentifier: (String, CGSize)]) {
        guard depth < 40, !layer.isHidden else { return }
        let kind = String(describing: type(of: layer))
        out[ObjectIdentifier(layer)] = ("\(kind) of \(owner)\(named.isEmpty ? "" : " in \(named)")", layer.bounds.size)
        for sublayer in layer.sublayers ?? [] where !(sublayer.delegate is UIView) {
            walk(sublayer, in: owner, named: named, depth: depth + 1, into: &out)
        }
    }

    private func finish(duration: CFTimeInterval) {
        slides += 1
        // Changed: two sizes apart by more than half a point, among things that
        // were there at rest before the slide or seen in more than one frame.
        let changed = seen.values
            .filter { ($0.rest != nil || $0.frames > 1) && ($0.maxW - $0.minW > 0.5 || $0.maxH - $0.minH > 0.5) }
        // One line per kind of thing: many layers of one view change together.
        var grouped: [String: (count: Int, minW: CGFloat, maxW: CGFloat, minH: CGFloat, maxH: CGFloat)] = [:]
        for entry in changed {
            var group = grouped[entry.label] ?? (0, entry.minW, entry.maxW, entry.minH, entry.maxH)
            group.count += 1
            group.minW = min(group.minW, entry.minW); group.maxW = max(group.maxW, entry.maxW)
            group.minH = min(group.minH, entry.minH); group.maxH = max(group.maxH, entry.maxH)
            grouped[entry.label] = group
        }
        let rows = grouped.sorted { ($0.value.maxW - $0.value.minW) > ($1.value.maxW - $1.value.minW) }
        let bodyRows = bodies.sorted { $0.value > $1.value }
        NSLog("%@", String(format: "[SLIDERESIZE] slide %d: %.2fs, %d frames, furthest %.0fpt, %d things changed size, %d bodies ran",
                           slides, duration, movingFrames, furthest, changed.count, bodies.values.reduce(0, +)))
        for (label, g) in rows.prefix(30) {
            NSLog("%@", String(format: "[SLIDERESIZE]   %@ ×%d w %.0f…%.0f h %.0f…%.0f",
                               label, g.count, g.minW, g.maxW, g.minH, g.maxH))
        }
        for (label, count) in bodyRows.prefix(20) {
            NSLog("%@", "[SLIDERESIZE]   body \(label) ×\(count)")
        }
        let report: [String: Any] = [
            "slide": slides,
            "at": Date().timeIntervalSince1970,
            "seconds": duration,
            "frames": movingFrames,
            "furthest": furthest,
            "changed": rows.map { label, g in
                ["what": label, "count": g.count, "minW": g.minW, "maxW": g.maxW, "minH": g.minH, "maxH": g.maxH] as [String: Any]
            },
            "bodies": bodyRows.map { ["what": $0.key, "count": $0.value] as [String: Any] },
        ]
        append(report)
    }

    private func append(_ report: [String: Any]) {
        guard let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = folder.appendingPathComponent("slide-resize.json")
        var all = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
        all.append(report)
        if let data = try? JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// CADisplayLink retains its target; this breaks the cycle.
    private final class Target: NSObject {
        weak var watch: SlideResizeWatch?
        init(_ watch: SlideResizeWatch) { self.watch = watch }
        @objc func frame(_ link: CADisplayLink) {
            MainActor.assumeIsolated { watch?.frame(link) }
        }
    }
}
#else
/// Release builds, and AppKit: nothing is measured.
public enum SlideResizeWatch {
    public static let enabled = false
    static func moved(_ x: CGFloat) {}
    static func note(_ label: String) {}
    static func log(_ message: @autoclosure () -> String) {}
    public static func start() {}
}
#endif
