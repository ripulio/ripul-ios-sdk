import Foundation

#if canImport(UIKit)
import UIKit

/// Lists the Core Animation animations the app has running, and can freeze them.
///
/// An animation handed to Core Animation costs the app's own process nothing
/// after it is added: the render server draws every frame of it. So the app's
/// counters (`[PERFMIN]`: processor time, main-thread wake time) cannot see a
/// loop that runs for a whole agent turn, and the phone warms with nothing to
/// show for it. Measured on a simulator, 8 October 2026: with a turn running the
/// app used 1-3% of a core and the simulator's render server 41%; with no turn,
/// the render server used none.
///
/// `list` names each animation and the view that owns its layer. `pause` freezes
/// the matching loops where they are and `resume` lets them run again, so the
/// cost of one can be measured within a single turn: read the render server,
/// pause, read it again.
///
/// It sees animations on this process's layers. A SwiftUI `repeatForever` or
/// `TimelineView` is interpolated on the main thread and shows in `[PERFMIN]`
/// instead; a web page's animations live in the web content process and are
/// read with `document.getAnimations()`.
public struct LayerAnimationsTool: NativeTool {
    public let name = "layer_animations"
    public let description = "List the Core Animation animations running in the app (the ones the render server "
        + "draws every frame, which the app's own processor counters cannot see), with the layer, its place on "
        + "screen and the view that owns it. action \"pause\" freezes the looping ones where they are and "
        + "\"resume\" lets them run again, to measure what one costs: read the render server's load, pause, read "
        + "it again. match narrows any action to animations whose key, key path, owner or id contains the text. "
        + "action \"changing\" watches for a few seconds what the app's main thread itself changes on screen, wake "
        + "by wake (a SwiftUI animation re-renders on the main thread every frame, and no loop above shows it): how "
        + "often the main thread woke and for how long, and the views whose layers changed most often."
    public let inputSchema: [String: Any] = ToolSchema.object(
        .string("action", "list (default), pause, resume or changing"),
        .string("match", "Only animations whose key, key path, layer class, owning view or id contains this (case-insensitive)"),
        .bool("includeFinite", "Also list animations that end by themselves, and the system's own that only keep one layer in step with another (default: only loops)"),
        .number("seconds", "changing: how long to watch, 1-10 seconds (default 3)"),
        .integer("limit", "changing: how many views to report (default 15)")
    )

    /// SDK-internal — see `RipulDeveloperOnlyTool`.
    init() {}

    /// Layers this tool froze, so `resume` restores exactly those.
    @MainActor private static let frozen = NSHashTable<CALayer>.weakObjects()

    @MainActor
    public func execute(args: [String: Any]) async throws -> Any {
        let action = (args["action"] as? String ?? "list").lowercased()
        guard ["list", "pause", "resume", "changing"].contains(action) else {
            return ["success": false, "error": "action is list, pause, resume or changing"]
        }
        let match = (args["match"] as? String).flatMap { $0.isEmpty ? nil : $0.lowercased() }
        let includeFinite = args["includeFinite"] as? Bool ?? false

        if action == "changing" {
            let seconds = min(10, max(1, (args["seconds"] as? NSNumber)?.doubleValue ?? 3))
            let limit = min(40, max(1, (args["limit"] as? NSNumber)?.intValue ?? 15))
            return await LayerChangeWatcher.watch(seconds: seconds, limit: limit, match: match)
        }

        if action == "resume" {
            let layers = Self.frozen.allObjects
            for layer in layers { Self.unfreeze(layer) }
            Self.frozen.removeAllObjects()
            return ["success": true, "resumed": layers.count]
        }

        var found: [[String: Any]] = []
        var loops = 0
        var changed = 0
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        for window in windows {
            Self.walk(window.layer, shown: !window.isHidden) { layer, shown in
                for key in layer.animationKeys() ?? [] {
                    guard let animation = layer.animation(forKey: key) else { continue }
                    let looping = Self.loops(animation)
                    guard looping || includeFinite else { continue }
                    let owner = Self.owner(of: layer)
                    let keyPath = (animation as? CAPropertyAnimation)?.keyPath
                    let id = owner.flatMap { Self.nearestIdentifier($0) }
                    let ownerName = owner.map { String(describing: type(of: $0)) }
                    if let match {
                        let text = [key, keyPath, String(describing: type(of: layer)), ownerName, id]
                            .compactMap { $0 }.joined(separator: " ").lowercased()
                        guard text.contains(match) else { continue }
                    }
                    if looping { loops += 1 }
                    if action == "pause", looping, layer.speed != 0 {
                        Self.freeze(layer)
                        Self.frozen.add(layer)
                        changed += 1
                    }
                    guard found.count < 200 else { continue }
                    let frame = layer.convert(layer.bounds, to: window.layer)
                    var entry: [String: Any] = [
                        "key": key,
                        "type": String(describing: type(of: animation)),
                        // A number a JSON reply can carry. An endless duration is not one, and
                        // WebKit's layers give the largest finite number instead of infinity.
                        "duration": Self.endless(animation.duration) ? -1 : (animation.duration * 100).rounded() / 100,
                        "repeats": looping ? "forever" : Self.follows(animation) ? "follows another layer"
                            : String(Int(max(1, min(animation.repeatCount, 1_000_000)))),
                        "layer": String(describing: type(of: layer)),
                        "frame": ["x": Int(frame.minX), "y": Int(frame.minY), "w": Int(frame.width), "h": Int(frame.height)],
                        // Shown: no hidden or clear ancestor, and inside the window.
                        "shown": shown && frame.intersects(window.bounds),
                        "frozen": layer.speed == 0,
                        "window": String(describing: type(of: window)),
                    ]
                    if let keyPath { entry["keyPath"] = keyPath }
                    if animation.autoreverses { entry["autoreverses"] = true }
                    // The rate it asks the render server for (`RenderServerAnimations`
                    // sets one on each loop); absent means every frame the display draws
                    // (the default range is all zeros).
                    let rate = animation.preferredFrameRateRange
                    if rate.maximum > 0 {
                        entry["framesPerSecond"] = (rate.preferred ?? rate.maximum).rounded()
                    }
                    if let ownerName { entry["owner"] = ownerName }
                    if let id { entry["id"] = id }
                    found.append(entry)
                }
            }
        }
        var result: [String: Any] = ["success": true, "loops": loops, "animations": found]
        if action == "pause" { result["paused"] = changed }
        return result
    }

    /// The system's match animations (Liquid Glass uses them) never end, but they
    /// are not a clock: they copy another layer's position or value, and draw
    /// nothing while that layer is still.
    private static func follows(_ animation: CAAnimation) -> Bool {
        String(describing: type(of: animation)).contains("Match")
    }

    private static func endless(_ duration: CFTimeInterval) -> Bool { !duration.isFinite || duration > 1_000_000 }

    /// Runs until something removes it, drawing a new frame every refresh.
    private static func loops(_ animation: CAAnimation) -> Bool {
        if follows(animation) { return false }
        if animation.repeatCount == .infinity || animation.repeatCount > 10_000 { return true }
        if animation.repeatDuration > 3_600 || endless(animation.duration) { return true }
        if let group = animation as? CAAnimationGroup { return (group.animations ?? []).contains(where: loops) }
        return false
    }

    @MainActor
    private static func walk(_ layer: CALayer, shown: Bool, _ visit: (CALayer, Bool) -> Void) {
        let shownHere = shown && !layer.isHidden && layer.opacity > 0.01
        visit(layer, shownHere)
        for child in layer.sublayers ?? [] { walk(child, shown: shownHere, visit) }
    }

    /// The view whose layer this is, or the nearest one above it.
    @MainActor
    static func owner(of layer: CALayer) -> UIView? {
        var current: CALayer? = layer
        while let node = current {
            if let view = node.delegate as? UIView { return view }
            current = node.superlayer
        }
        return nil
    }

    /// The identifier the view carries, or the nearest one above it.
    @MainActor
    static func nearestIdentifier(_ view: UIView) -> String? {
        var current: UIView? = view
        var steps = 0
        while let node = current, steps < 40 {
            if let id = ScreenElementFinder.identifier(of: node) { return id }
            current = node.superview
            steps += 1
        }
        return nil
    }

    // Apple's documented way to stop a layer's clock and start it again where it stopped.
    @MainActor
    private static func freeze(_ layer: CALayer) {
        let stoppedAt = layer.convertTime(CACurrentMediaTime(), from: nil)
        layer.speed = 0
        layer.timeOffset = stoppedAt
    }

    @MainActor
    private static func unfreeze(_ layer: CALayer) {
        let stoppedAt = layer.timeOffset
        layer.speed = 1
        layer.timeOffset = 0
        layer.beginTime = 0
        layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - stoppedAt
    }
}
#endif
