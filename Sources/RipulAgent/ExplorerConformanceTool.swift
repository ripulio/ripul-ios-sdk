import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Run the whole archetype sweep: for every control on the conformance screen,
/// point the reticule at it, report what resolves, press it, and compare
/// against what that archetype is declared to support.
///
/// This is the answer to "will we ever get coverage" being a NUMBER rather than
/// a hope. Until now the only way to discover an unreachable archetype was for
/// someone to point at one on a phone and describe what went wrong; each gap
/// found that way cost a round trip, a release and an install. A sweep finds
/// them all at once, on demand, and — because it drives the reticule rather
/// than addressing elements by id — it exercises the point-resolution path that
/// is the one that actually breaks.
///
/// A failing row is not necessarily an SDK bug: `expectActionable: false` rows
/// are expected to be inert, and an app that publishes nothing to accessibility
/// is an app-side fact. The report distinguishes them.
///
/// Surfaced to a remote agent as `device_explorer_conformance`.
public struct ExplorerConformanceTool: NativeTool {
    public let name = "explorer_conformance"
    public let description = "Sweep the Ripul conformance screen: point the View Explorer's reticule at every "
        + "control archetype (UIKit button/field/textview/switch, SwiftUI button/field/toggle/tap-gesture/"
        + "inert label/nested island), report what each resolves to and what pressing it does, and score it "
        + "against the declared expectation. Returns a pass/fail table and a coverage count. Opens the "
        + "conformance screen and the explorer if they aren't up. Use this to find unreachable archetypes "
        + "before a user does, and to check a resolution change hasn't regressed the ones that worked."
    public let inputSchema: [String: Any] = ToolSchema.object(
        .bool("fire", "Press each archetype as well as resolving it (default true)")
    )

    public init() {}

    public func execute(args: [String: Any]) async throws -> Any {
        #if canImport(UIKit)
        let fire = args["fire"] as? Bool ?? true
        guard #available(iOS 16.0, *) else {
            return ["success": false, "error": "explorer_conformance requires iOS 16+"]
        }

        // Bring up the harness and the explorer, then let the sheet settle.
        let presented = await MainActor.run { RipulConformance.present() }
        if presented { try? await Task.sleep(nanoseconds: 700_000_000) }
        let openedExplorer = await MainActor.run { () -> Bool in
            if let live = ViewInspectorController.live, live.window != nil { return false }
            return RipulViewExplorer.present()
        }
        if openedExplorer { try? await Task.sleep(nanoseconds: 400_000_000) }

        var rows: [[String: Any]] = []
        for archetype in RipulConformance.archetypes {
            // Locate it by id to get its frame, then drive the RETICULE to the
            // centre of that frame — the point path, not the predicate path.
            // Put the screen back to a known state first. Pressing a text field
            // raises the keyboard, which scrolls the List — so every archetype
            // after the first text field was aimed with a frame that had since
            // moved, and scored as unreachable when it was merely somewhere
            // else. A sweep whose earlier rows perturb its later ones measures
            // its own ordering, not the SDK.
            await MainActor.run {
                RipulChrome.appWindow()?.endEditing(true)
            }
            try? await Task.sleep(nanoseconds: 450_000_000)

            // Locate and probe in ONE hop onto the main actor. Split across two,
            // the layout is free to settle, scroll or animate in between, and
            // the reticule is aimed at where the element used to be.
            let probe = await MainActor.run { () -> [String: Any]? in
                guard let match = ScreenElementFinder.find(id: archetype.id, text: nil).first else { return nil }
                let frame = match.view.convert(match.view.bounds, to: nil)
                guard frame.width > 0, frame.height > 0 else { return nil }
                guard let live = ViewInspectorController.live else { return [:] }
                return live.probe(atWindowPoint: CGPoint(x: frame.midX, y: frame.midY), fire: fire)
            }
            guard let probe else {
                rows.append(["archetype": archetype.title, "id": archetype.id,
                             "result": "not-on-screen",
                             "detail": "no view carries this id — the harness sheet may not be presented in the APP window, "
                                 + "or the row is scrolled out of view"])
                continue
            }
            rows.append(Self.score(archetype, probe: probe, fired: fire))
            // Let any focus/keyboard/navigation settle before the next probe.
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        let passed = rows.filter { ($0["result"] as? String)?.hasPrefix("pass") == true }.count
        return [
            "success": true,
            "coverage": "\(passed)/\(rows.count)",
            "passed": passed,
            "total": rows.count,
            "rows": rows,
        ]
        #else
        return ["success": false, "error": "explorer_conformance requires UIKit"]
        #endif
    }

    #if canImport(UIKit)
    private static func score(_ a: RipulArchetype, probe: [String: Any], fired: Bool) -> [String: Any] {
        var row: [String: Any] = ["archetype": a.title, "id": a.id]
        let actionable = probe["actionable"] as? [String: Any]
        row["element"] = (probe["element"] as? [String: Any])?["class"] ?? "—"
        row["actionable"] = actionable?["class"] ?? "none"

        // Score the PRESS, never the prediction. `actionable` is what the
        // explorer expects to be pressable, computed from the view tree; the
        // engine's ladder also reaches accessibility elements, which are not
        // views and are routinely the only representation a SwiftUI control
        // has. Gating the fire on a non-nil `actionable` meant a whole release
        // whose entire purpose was a new engine path scored without that path
        // ever running once, and read as a regression.
        //
        // The prediction is still worth reporting — a persistent disagreement
        // between `actionable: none` and a successful press is a real defect in
        // the readout — but it is evidence, not the verdict.
        let f = probe["fired"] as? [String: Any]
        if let f {
            row["via"] = f["via"] ?? "none"
            row["trace"] = f["trace"] ?? ""
        }
        let pressed = (f?["success"] as? Bool) == true

        // An archetype declared inert passes by being inert. Theme tools select
        // labels and backgrounds constantly, and "nothing here responds to a
        // tap" is the correct answer for them, not a miss. It has to survive the
        // PRESS too: predicting nothing and then pressing something is the
        // false-success failure mode, not a pass.
        guard a.expectActionable else {
            if pressed {
                row["result"] = "unexpected-actionable"
                row["detail"] = "declared inert, but the press succeeded via \(f?["via"] ?? "?")"
            } else if actionable != nil {
                row["result"] = "unexpected-actionable"
                row["detail"] = "declared inert, but the readout claims something here is pressable"
            } else {
                row["result"] = "pass"
            }
            return row
        }
        guard fired, f != nil else {
            row["result"] = actionable != nil ? "pass" : "fail"   // resolution only; not asked to press
            return row
        }
        guard pressed else {
            row["result"] = "fail"
            row["detail"] = actionable == nil
                ? "no actionable element resolved and the press was refused"
                : "resolved but the press was refused"
            return row
        }
        if actionable == nil {
            row["result"] = "pass-readout-pessimistic"
            row["detail"] = "pressed via \(f?["via"] ?? "?") but the readout said nothing here responds "
                + "to a tap — the engine reached it, the explorer did not predict it"
            return row
        }
        if let expected = a.expectVia, (f?["via"] as? String) != expected {
            row["result"] = "pass-different-path"
            row["detail"] = "pressed via \(f?["via"] ?? "?"), expected \(expected) — works, but not the route assumed"
            return row
        }
        row["result"] = "pass"
        return row
    }
    #endif
}
