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
    public let description = "Point the View Explorer's reticule at a screen coordinate and report what it "
        + "resolves — the selected element, the element a tap would actually drive (they differ more often "
        + "than you'd think), whether they diverge, and the readout verbatim. Optionally fire, which presses "
        + "through the identical path a human tap takes and returns via/activated/trace. Coordinates are "
        + "window-space, the same frames inspect_screen reports. Requires the View Explorer to be open on "
        + "the device. This is the ONLY way to test point-based resolution; tap_element addresses by "
        + "predicate and exercises a different path entirely."
    public let inputSchema: [String: Any] = ToolSchema.object(
        .number("x", "Window-space x, as reported by inspect_screen frames"),
        .number("y", "Window-space y"),
        .bool("fire", "Also press what resolves, through the same path a human tap takes (default false)")
    )

    public init() {}

    public func execute(args: [String: Any]) async throws -> Any {
        #if canImport(UIKit)
        guard let x = (args["x"] as? NSNumber)?.doubleValue,
              let y = (args["y"] as? NSNumber)?.doubleValue else {
            return ["success": false, "error": "x and y are required (window-space coordinates)"]
        }
        let fire = args["fire"] as? Bool ?? false
        return await MainActor.run { () -> Any in
            guard let live = ViewInspectorController.live, live.window != nil else {
                return ["success": false,
                        "error": "The View Explorer isn't open on the device. Open it, then probe."]
            }
            return live.probe(atWindowPoint: CGPoint(x: x, y: y), fire: fire)
        }
        #else
        return ["success": false, "error": "explorer_probe requires UIKit"]
        #endif
    }
}
