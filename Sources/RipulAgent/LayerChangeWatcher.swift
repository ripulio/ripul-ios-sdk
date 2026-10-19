import Foundation

#if canImport(UIKit)
import UIKit

/// What the main thread changes on screen, wake by wake: the `changing` action of
/// `layer_animations`.
///
/// A Core Animation loop is drawn by the render server and never wakes the app. A
/// SwiftUI animation is different: a `repeatForever`, a `TimelineView` or an
/// animated value that never settles keeps SwiftUI's own display link running, and
/// on every frame the main thread wakes, renders the view graph and writes the new
/// values into the layers. On a phone drawing 120 frames a second that is the main
/// thread busy for as long as the animation lasts, and the once-a-minute profile can
/// only name SwiftUI's `ViewGraphRootValueUpdater.render`, with nothing of ours on
/// the stack (Peter's phone, 14 October 2026: 15-25% of a core for minutes on end).
///
/// For a few seconds this looks at every main-thread wake without adding one of its
/// own: a run loop observer that runs last, after Core Animation has committed,
/// compares every layer's own values with what they were at the previous wake. It
/// reports how often the main thread woke and how long each wake was busy, and the
/// views whose layers changed most often, with the identifier nearest to each.
///
/// It sees what the main thread writes: position, size, opacity, transform, hidden,
/// background colour, corner radius, sublayer count and which contents object a
/// layer holds. It does not see a layer redrawn into the same contents object, nor
/// a Core Animation animation (those never change the model values; `list` names
/// them).
@MainActor
final class LayerChangeWatcher {
    private struct State: Equatable {
        var position: CGPoint
        var bounds: CGRect
        var opacity: Float
        var transform: CATransform3D
        var hidden: Bool
        var contents: ObjectIdentifier?
        var color: CGColor?
        var radius: CGFloat
        var sublayers: Int

        init(_ layer: CALayer) {
            position = layer.position
            bounds = layer.bounds
            opacity = layer.opacity
            transform = layer.transform
            hidden = layer.isHidden
            contents = layer.contents.map { ObjectIdentifier($0 as AnyObject) }
            color = layer.backgroundColor
            radius = layer.cornerRadius
            sublayers = layer.sublayers?.count ?? 0
        }

        static func == (lhs: State, rhs: State) -> Bool { lhs.differences(from: rhs).isEmpty }

        func differences(from other: State) -> [String] {
            var kinds: [String] = []
            if position != other.position { kinds.append("position") }
            if bounds.size != other.bounds.size { kinds.append("size") }
            if bounds.origin != other.bounds.origin { kinds.append("scroll") }
            if opacity != other.opacity { kinds.append("opacity") }
            if !CATransform3DEqualToTransform(transform, other.transform) { kinds.append("transform") }
            if hidden != other.hidden { kinds.append("hidden") }
            if contents != other.contents { kinds.append("contents") }
            if color != other.color { kinds.append("colour") }
            if radius != other.radius { kinds.append("radius") }
            if sublayers != other.sublayers { kinds.append("sublayers") }
            return kinds
        }
    }

    private final class Tally {
        weak var layer: CALayer?
        var changes = 0
        var kinds = Set<String>()
        var shown = false
        init(_ layer: CALayer) { self.layer = layer }
    }

    private let seconds: TimeInterval
    private let limit: Int
    private let match: String?
    private var completion: (([String: Any]) -> Void)?
    private var observer: CFRunLoopObserver?
    private var previous: [ObjectIdentifier: State] = [:]
    private var tallies: [ObjectIdentifier: Tally] = [:]
    private var startedAt: CFTimeInterval = 0
    private var wakes = 0
    private var walks = 0
    private var wakesWithChanges = 0
    private var wokeAt: CFTimeInterval = 0
    private var awake: CFTimeInterval = 0
    private var walking: CFTimeInterval = 0
    private var layerCount = 0

    private init(seconds: TimeInterval, limit: Int, match: String?) {
        self.seconds = seconds; self.limit = limit; self.match = match
    }

    /// Watch for `seconds` and return the report.
    static func watch(seconds: TimeInterval, limit: Int, match: String?) async -> [String: Any] {
        await withCheckedContinuation { continuation in
            let watcher = LayerChangeWatcher(seconds: seconds, limit: limit, match: match)
            watcher.completion = { continuation.resume(returning: $0) }
            watcher.start()
        }
    }

    private func start() {
        startedAt = CACurrentMediaTime()
        previous = walk(tally: false)
        // Last of everything in a wake: after SwiftUI has rendered and Core
        // Animation has committed what it rendered.
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, activities, true, CFIndex.max) { [weak self] _, activity in
            MainActor.assumeIsolated { self?.observed(activity) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
        // The timer holds the watcher until it reports.
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated { self.finish() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func observed(_ activity: CFRunLoopActivity) {
        if activity == .afterWaiting {
            wakes += 1
            wokeAt = CACurrentMediaTime()
            return
        }
        let begin = CACurrentMediaTime()
        if wokeAt > 0 { awake += begin - wokeAt }
        wokeAt = 0
        previous = walk(tally: true)
        walks += 1
        walking += CACurrentMediaTime() - begin
    }

    /// Every layer of every window, compared with the previous walk when tallying.
    private func walk(tally: Bool) -> [ObjectIdentifier: State] {
        var next: [ObjectIdentifier: State] = [:]
        next.reserveCapacity(max(previous.count, 256))
        var changed = false
        func visit(_ layer: CALayer, shown: Bool) {
            let shownHere = shown && !layer.isHidden && layer.opacity > 0.01
            let id = ObjectIdentifier(layer)
            let state = State(layer)
            if tally, let before = previous[id] {
                let kinds = state.differences(from: before)
                if !kinds.isEmpty {
                    changed = true
                    let entry = tallies[id] ?? { let made = Tally(layer); tallies[id] = made; return made }()
                    entry.changes += 1
                    entry.kinds.formUnion(kinds)
                    entry.shown = shownHere
                }
            }
            next[id] = state
            for child in layer.sublayers ?? [] { visit(child, shown: shownHere) }
        }
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        for window in windows { visit(window.layer, shown: !window.isHidden) }
        if changed { wakesWithChanges += 1 }
        layerCount = next.count
        return next
    }

    private func finish() {
        guard let observer else { return }
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = nil
        let elapsed = max(0.001, CACurrentMediaTime() - startedAt)

        // Layers of one view change together: report views, each with its busiest layers.
        struct Group { var owner: UIView?; var id: String?; var tallies: [Tally] = [] }
        var groups: [String: Group] = [:]
        for tally in tallies.values where tally.changes >= 2 {
            guard let layer = tally.layer else { continue }
            let owner = LayerAnimationsTool.owner(of: layer)
            let id = owner.flatMap { LayerAnimationsTool.nearestIdentifier($0) }
            let key = "\(owner.map { "\(ObjectIdentifier($0))" } ?? "-")|\(id ?? "-")"
            groups[key, default: Group(owner: owner, id: id)].tallies.append(tally)
        }
        var views: [[String: Any]] = []
        for group in groups.values {
            let busiest = group.tallies.sorted { $0.changes > $1.changes }
            let ownerName = group.owner.map { Self.typeName($0) }
            if let match {
                let text = ([ownerName, group.id] + busiest.compactMap { $0.layer.map { String(describing: type(of: $0)) } })
                    .compactMap { $0 }.joined(separator: " ").lowercased()
                guard text.contains(match) else { continue }
            }
            var entry: [String: Any] = [
                "changes": busiest[0].changes,
                "perSecond": (Double(busiest[0].changes) / elapsed * 10).rounded() / 10,
                "layers": busiest.count,
                "kinds": Array(Set(busiest.flatMap(\.kinds))).sorted(),
                "shown": busiest.contains { $0.shown },
            ]
            if let ownerName { entry["owner"] = ownerName }
            if let id = group.id { entry["id"] = id }
            if let owner = group.owner { entry["ancestors"] = Self.ancestors(of: owner) }
            entry["samples"] = busiest.prefix(3).compactMap { tally -> [String: Any]? in
                guard let layer = tally.layer else { return nil }
                var root = layer
                while let up = root.superlayer { root = up }
                let frame = layer.convert(layer.bounds, to: root)
                return [
                    "layer": String(describing: type(of: layer)),
                    "changes": tally.changes,
                    "kinds": tally.kinds.sorted(),
                    "frame": ["x": Int(frame.minX), "y": Int(frame.minY), "w": Int(frame.width), "h": Int(frame.height)],
                ]
            }
            views.append(entry)
        }
        views.sort { ($0["changes"] as? Int ?? 0) > ($1["changes"] as? Int ?? 0) }

        let report: [String: Any] = [
            "success": true,
            "seconds": (elapsed * 10).rounded() / 10,
            "wakesPerSecond": (Double(wakes) / elapsed * 10).rounded() / 10,
            "awakePercent": (awake / elapsed * 1000).rounded() / 10,
            "awakeMsPerWake": wakes > 0 ? (awake / Double(wakes) * 10000).rounded() / 10 : 0,
            "wakesWithChangesPerSecond": (Double(wakesWithChanges) / elapsed * 10).rounded() / 10,
            "layers": layerCount,
            // What looking cost: added to each wake, and not counted in awakePercent.
            "probeMsPerWake": walks > 0 ? (walking / Double(walks) * 10000).rounded() / 10 : 0,
            "views": Array(views.prefix(limit)),
        ]
        completion?(report)
        completion = nil
    }

    /// The view's class, with SwiftUI's long generic names cut down to what identifies them.
    private static func typeName(_ view: UIView) -> String {
        let name = String(describing: type(of: view))
        return name.count > 220 ? String(name.prefix(220)) + "…" : name
    }

    /// The nearest few views above, by class, for a view that has no identifier of its own.
    private static func ancestors(of view: UIView) -> [String] {
        var names: [String] = []
        var current = view.superview
        while let node = current, names.count < 5 {
            let name = String(describing: type(of: node))
            let short = name.count > 90 ? String(name.prefix(90)) + "…" : name
            if names.last != short { names.append(short) }
            current = node.superview
        }
        return names
    }
}
#endif
