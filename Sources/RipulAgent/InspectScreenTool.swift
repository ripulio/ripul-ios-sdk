import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Shared markers for runtime app-dev inspection tools.
public enum RipulInspection {
    /// The host app sets this as the `accessibilityIdentifier` on its dev-assistant
    /// overlay `UIWindow`. Inspection tools skip any window carrying it, so the
    /// agent always sees the HOST app's screen — never the assistant floating over it.
    public static let excludedOverlayWindowIdentifier = "ripul.devAssistant.overlay"
}

/// Built-in `NativeTool` that captures the running app's native (UIKit/SwiftUI)
/// view tree so an agent can "see" the host screen and bind elements back to source.
///
/// Reuses the View Explorer's capture helpers (`InspectedView`) for text / view-
/// controller / IBOutlet / accessibility-id resolution, but runs **headless** — no
/// overlay, no human tap — and **excludes the dev-assistant overlay window**
/// (`RipulInspection.excludedOverlayWindowIdentifier`).
///
/// Surfaced to a remote agent over the relay as `device_inspect_screen`.
public struct InspectScreenTool: NativeTool {
    public let name = "inspect_screen"
    public let description = "Inspect the running app's on-screen native (UIKit/SwiftUI) view tree. "
        + "Returns elements with class name, role (button/field/cell/list/… — the vocabulary the actuation "
        + "tools' role predicate matches), window-space frame, accessibility id / uiKitIdentifier stamp, "
        + "visible text, owning view controller, and IBOutlet/property name — for locating a control in source. "
        + "Every element also gets a short-lived \"handle\" (e.g. \"e7\") — pass it to tap_element / type_text / "
        + "scroll_element to hit exactly that element. Handles go stale on the next inspect or actuation. "
        + "Set includeScreenshot for a downscaled JPEG. Excludes the Ripul dev-assistant overlay itself, so it "
        + "reports the host app's screen, never the assistant."
    public let inputSchema: [String: Any] = ToolSchema.object(
        .bool("includeScreenshot", "Also return a base64 JPEG of the screen (downscaled)"),
        .string("filter", "Only include elements whose class, text, id, IBOutlet or view controller contains this substring (case-insensitive)"),
        .number("maxElements", "Cap the number of elements returned (default 250, max 1000)")
    )

    let bridge: AgentBridge

    /// SDK-internal: constructible only from within this module (the console
    /// composition path) — see `RipulDeveloperOnlyTool`.
    init(bridge: AgentBridge) {
        self.bridge = bridge
    }

    @MainActor
    public func execute(args: [String: Any]) async throws -> Any {
        #if canImport(UIKit)
        let includeScreenshot = args["includeScreenshot"] as? Bool ?? false
        let filter = (args["filter"] as? String).flatMap { $0.isEmpty ? nil : $0.lowercased() }
        let maxElements = min(max(args["maxElements"] as? Int ?? 250, 1), 1000)

        guard let window = Self.hostKeyWindow() else {
            return ["success": false, "error": "No host window found"]
        }
        let root: UIView = window.rootViewController?.view ?? window

        var elements: [[String: Any]] = []
        var visited = 0
        // A fresh snapshot: handles issued by previous inspects go stale, then
        // each returned element is registered so actuation tools can target it
        // exactly (see ScreenSnapshotStore).
        ScreenSnapshotStore.shared.beginSnapshot()
        Self.walk(root) { view, depth in
            visited += 1
            guard elements.count < maxElements else { return }
            var el = Self.element(for: view, depth: depth, window: window)
            if let filter {
                let hay = ["class", "text", "id", "ibOutlet", "vc", "role"]
                    .compactMap { el[$0] as? String }
                    .joined(separator: " ")
                    .lowercased()
                guard hay.contains(filter) else { return }
            }
            el["handle"] = ScreenSnapshotStore.shared.register(
                view: view, id: el["id"] as? String, text: el["text"] as? String)
            elements.append(el)
        }

        var result: [String: Any] = [
            "success": true,
            "screen": Self.rect(window.bounds),
            "visited": visited,
            "returned": elements.count,
            "truncated": visited > elements.count,
            "elements": elements,
        ]
        if includeScreenshot, let jpeg = Self.screenshot(window) {
            result["screenshotJpegBase64"] = jpeg.base64EncodedString()
        }
        return result
        #else
        return ["success": false, "error": "inspect_screen requires UIKit"]
        #endif
    }

    // MARK: - Capture (UIKit)

    #if canImport(UIKit)
    /// The host app's visible window, excluding the dev-assistant overlay.
    @MainActor
    private static func hostKeyWindow() -> UIWindow? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .filter { !isExcluded($0) && !$0.isHidden }
        return windows.first { $0.isKeyWindow }
            ?? windows.filter { $0.windowLevel == .normal }.last
            ?? windows.last
    }

    @MainActor
    private static func isExcluded(_ window: UIWindow) -> Bool {
        window.accessibilityIdentifier == RipulInspection.excludedOverlayWindowIdentifier
    }

    /// Depth-first walk of the visible tree, skipping hidden / effectively-invisible
    /// views and (defensively) any excluded overlay window.
    @MainActor
    private static func walk(_ view: UIView, depth: Int = 0, _ visit: (UIView, Int) -> Void) {
        if view.isHidden || view.alpha < 0.01 { return }
        if let window = view as? UIWindow, isExcluded(window) { return }
        visit(view, depth)
        for sub in view.subviews {
            walk(sub, depth: depth + 1, visit)
        }
    }

    @MainActor
    private static func element(for view: UIView, depth: Int, window: UIWindow) -> [String: Any] {
        var d: [String: Any] = [
            "class": String(describing: type(of: view)),
            "depth": depth,
            "frame": rect(view.convert(view.bounds, to: window)),
        ]

        // Identifier: UIKit accessibilityIdentifier (WAC's `<screen>.<element>`),
        // then a uiKitIdentifier stamp, then a SwiftUI accessibility-tree id.
        var id = view.accessibilityIdentifier
        if id?.isEmpty ?? true { id = UIKitIdentifierRegistry.shared.identifier(for: view) }
        if id?.isEmpty ?? true { id = InspectedView.accessibilityIdInTree(view) }
        if let id, !id.isEmpty { d["id"] = id }

        if let text = InspectedView.textContent(of: view), !text.isEmpty { d["text"] = text }
        if let role = ScreenElementFinder.role(of: view) { d["role"] = role }
        if view.subviews.count > 0 { d["children"] = view.subviews.count }

        // Source-binding hints are reflection-heavy, so only resolve them for
        // elements that carry meaning (an id, text, or an interactive control).
        let interesting = d["id"] != nil || d["text"] != nil || view is UIControl
        if interesting {
            if let vc = InspectedView.viewControllerChain(of: view).first { d["vc"] = vc }
            if let outlet = InspectedView.propertyReference(of: view) { d["ibOutlet"] = outlet }
            if view is UIControl { d["control"] = true }
        }
        return d
    }

    private static func rect(_ r: CGRect) -> [String: Double] {
        ["x": Double(r.minX), "y": Double(r.minY), "w": Double(r.width), "h": Double(r.height)]
    }

    /// Downscaled JPEG of the window (not the overlay) so the payload stays small.
    @MainActor
    private static func screenshot(_ window: UIWindow, maxDimension: CGFloat = 900) -> Data? {
        let bounds = window.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let factor = min(1, maxDimension / max(bounds.width, bounds.height))
        let size = CGSize(width: bounds.width * factor, height: bounds.height * factor)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { _ in
            window.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: false)
        }
        return image.jpegData(compressionQuality: 0.6)
    }
    #endif
}
