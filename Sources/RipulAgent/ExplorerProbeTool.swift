import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Drive the View Explorer's reticule from a tool.
///
/// Everything else the agent has — `inspect_screen`, `tap_element` — addresses
/// elements by PREDICATE (id, text, class). The explorer addresses them by
/// POINT, through a completely different resolution path: hit-test, geometric
/// walks, the stamp registry, the accessibility tree, then a choice between
/// closest-element and closest-actionable. That path is the one that actually
/// fails, and until now it could only be exercised by a human dragging a
/// crosshair and reading the result off a phone screen.
///
/// The reticule is a relative, accelerated cursor with no absolute addressing,
/// which is precisely why it was undriveable. `probe` gives it an absolute
/// entry point and returns the readout VERBATIM — the same string the Copy
/// button yields — so a tool-driven check and a human bug report are the same
/// artefact rather than two descriptions that have to be reconciled.
///
/// Surfaced to a remote agent as `device_explorer_probe`.
public struct ExplorerProbeTool: NativeTool {
    public let name = "explorer_probe"
    public let description = "Read the user's current View Explorer highlight, or highlight an app element at a screen coordinate. "
        + "Omit both x and y to read the current selection without moving the reticule, reselecting, pressing, "
        + "or opening the explorer. Reports isOpen and hasSelection, plus the selected element's text, label, "
        + "identifier, frame and source readout when available. Supply both x and y to move the reticule and report what it "
        + "resolves — the selected element, the element a tap would actually drive (they differ more often "
        + "than you'd think), whether they diverge, and the readout verbatim. Optionally fire, which presses "
        + "through the identical path a human tap takes and returns via/activated/trace. Coordinates are "
        + "window-space, the same frames inspect_screen reports. With coordinates, automatically opens View Explorer if it is "
        + "closed; no manual launch is needed. Omit fire or set it to false to highlight without pressing. Fire requires coordinates. "
        + "This is the ONLY way to test point-based resolution; tap_element addresses by "
        + "predicate and exercises a different path entirely."
    public let inputSchema: [String: Any] = ToolSchema.object(
        .number("x", "Window-space x. Supply with y to move the highlight; omit both to read the current selection."),
        .number("y", "Window-space y. Supply with x to move the highlight; omit both to read the current selection."),
        .bool("fire", "Also press what resolves (default false). Requires both x and y; never fires in read mode.")
    )

    public init() {}

    public func execute(args: [String: Any]) async throws -> Any {
        #if canImport(UIKit)
        let fire = args["fire"] as? Bool ?? false
        if args["x"] == nil && args["y"] == nil {
            guard !fire else {
                return ["success": false, "error": "fire requires both x and y; reading the current selection never presses it"]
            }
            return await MainActor.run { () -> Any in
                guard let live = ViewInspectorController.live,
                      let window = live.window, !window.isHidden, window.alpha > 0.01,
                      !live.isHidden else {
                    return ["success": true, "isOpen": false, "hasSelection": false]
                }
                return live.selectionSnapshot()
            }
        }
        guard let x = (args["x"] as? NSNumber)?.doubleValue,
              let y = (args["y"] as? NSNumber)?.doubleValue,
              x.isFinite, y.isFinite else {
            return ["success": false, "error": "Supply both x and y as finite window-space coordinates, or omit both to read the current selection"]
        }

        // Open the explorer if it isn't up. Asking a human to open it first
        // reintroduces exactly the manual step this tool exists to remove —
        // and "point the reticule" implies having one.
        let opened = await MainActor.run { () -> Bool in
            if let live = ViewInspectorController.live, live.window != nil { return false }
            if #available(iOS 16.0, *) { return RipulViewExplorer.present() }
            return false
        }
        if opened {
            // The controller is created when the SwiftUI overlay mounts, a
            // runloop or two later.
            try? await Task.sleep(nanoseconds: 400_000_000)
        }

        return await MainActor.run { () -> Any in
            guard let live = ViewInspectorController.live, live.window != nil else {
                return ["success": false,
                        "error": "The View Explorer could not be opened (needs iOS 16+ and a foreground scene)."]
            }
            var result = live.probe(atWindowPoint: CGPoint(x: x, y: y), fire: fire)
            if opened { result["openedExplorer"] = true }
            return result
        }
        #else
        return ["success": false, "error": "explorer_probe requires UIKit"]
        #endif
    }
}
