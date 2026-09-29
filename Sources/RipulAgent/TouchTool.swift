import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - touch

/// Real finger input at a point: tap, double tap, long press, swipe, pinch. The
/// counterpart of `tap_element` for what its addressing can't express — an
/// exact spot, a gesture — and for controls only a real touch presses. See
/// `TouchSynthesizer` (debug builds only).
public struct TouchTool: NativeTool {
    public let name = "touch"
    public let description = "Real finger input in the host app at a point in window coordinates (points — the "
        + "space inspect_screen's frames use): tap, double_tap, long_press, swipe from x,y to toX,toY, or pinch "
        + "about x,y with two fingers going from `from` to `to` points apart (apart to zoom in). It "
        + "goes through UIKit's own touch handling, so gesture recognizers, SwiftUI, tab bars and scroll "
        + "views react as to a finger. Use it for gestures (swipe to scroll, drag, long press), for an exact "
        + "spot, or where tap_element reports an element isn't tappable. A short swipe duration flings, a "
        + "long one drags. The result names what was under the finger; confirm the effect with "
        + "wait_for_element or inspect_screen. Debug builds of the app only."
    public let inputSchema: [String: Any] = ToolSchema.object(
        .stringEnum("action", "What the finger does",
                    values: ["tap", "double_tap", "long_press", "swipe", "pinch"], required: true),
        .number("x", "Where the finger lands: x in window points", required: true),
        .number("y", "Where the finger lands: y in window points", required: true),
        .number("toX", "swipe: where the finger lifts, x"),
        .number("toY", "swipe: where the finger lifts, y"),
        .number("duration", "Seconds: long_press hold (default 0.8), swipe or pinch travel (default 0.25)"),
        .number("from", "pinch: how far apart the two fingers start, in points (default 80)"),
        .number("to", "pinch: how far apart they end, in points (default 240)"),
        .number("angle", "pinch: the line the fingers are on, in degrees from the horizontal (default 45)"),
        .string("purpose", "\"liveview\" when a Live View viewer sends it; leave out otherwise"),
        .string("viewer", "The Live View viewer's name")
    )

    /// SDK-internal — see `RipulDeveloperOnlyTool`.
    init() {}

    @MainActor
    public func execute(args: [String: Any]) async throws -> Any {
        #if canImport(UIKit)
        if let refusal = LiveStreamHost.shared.relayRefusal(args) {
            return ["success": false, "error": refusal]
        }
        if let reason = TouchSynthesizer.unavailableReason {
            return ["success": false, "error": "Real touches are unavailable: \(reason). Use tap_element instead."]
        }
        guard let window = ScreenElementFinder.hostWindow() else {
            return ["success": false, "error": "No app window on screen"]
        }
        func number(_ key: String) -> CGFloat? {
            (args[key] as? NSNumber).map { CGFloat(truncating: $0) }
        }
        guard let x = number("x"), let y = number("y") else {
            return ["success": false, "error": "x and y are required"]
        }
        let point = CGPoint(x: x, y: y)
        let action = args["action"] as? String ?? "tap"
        let bounds = window.bounds
        guard bounds.contains(point) else {
            return ["success": false, "error": "(\(x), \(y)) is outside the window (\(Int(bounds.width))x\(Int(bounds.height)))"]
        }
        let under = Self.describeHit(window.hitTest(point, with: nil))
        var result: [String: Any] = ["action": action, "point": ["x": x, "y": y], "under": under]
        do {
            switch action {
            case "tap": try await TouchSynthesizer.tap(at: point, in: window)
            case "double_tap": try await TouchSynthesizer.tap(at: point, in: window, count: 2)
            case "long_press":
                try await TouchSynthesizer.longPress(at: point, in: window, duration: Double(number("duration") ?? 0.8))
            case "swipe":
                guard let toX = number("toX"), let toY = number("toY") else {
                    return ["success": false, "error": "swipe needs toX and toY"]
                }
                let end = CGPoint(x: min(max(toX, 0), bounds.maxX - 1), y: min(max(toY, 0), bounds.maxY - 1))
                try await TouchSynthesizer.drag(from: point, to: end, in: window,
                                                duration: Double(number("duration") ?? 0.25))
                result["to"] = ["x": end.x, "y": end.y]
            case "pinch":
                let from = number("from") ?? 80, to = number("to") ?? 240
                try await TouchSynthesizer.pinch(center: point, from: from, to: to,
                                                 angle: (number("angle") ?? 45) * .pi / 180, in: window,
                                                 duration: Double(number("duration") ?? 0.25))
                result["from"] = from
                result["to"] = to
            default:
                return ["success": false, "error": "Unknown action '\(action)'"]
            }
        } catch {
            return ["success": false, "error": "The touch could not be delivered: \(error)"]
        }
        ScreenSnapshotStore.shared.invalidate()
        result["success"] = true
        return result
        #else
        return ["success": false, "error": "touch needs UIKit"]
        #endif
    }

    #if canImport(UIKit)
    /// What a finger at the point would hit: class and identifier, for the agent to check it aimed right.
    @MainActor
    static func describeHit(_ view: UIView?) -> [String: Any] {
        guard let view else { return ["class": "nothing"] }
        var hit: [String: Any] = ["class": String(describing: type(of: view))]
        if let id = ScreenElementFinder.identifier(of: view) { hit["id"] = id }
        if let label = view.accessibilityLabel, !label.isEmpty { hit["label"] = label }
        return hit
    }
    #endif
}
