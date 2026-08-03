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
            await MainActor.run { RipulConformanceLog.shared.clear() }

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
            // Read the app's own record of what ran. This is the only evidence
            // that distinguishes pressing the control from pressing NEAR it.
            var effects = await MainActor.run { RipulConformanceLog.shared.fired }
            // First-responder state is PLATFORM ground truth and a better oracle
            // than any binding. SwiftUI's @FocusState tracks SwiftUI's own focus
            // system, so focusing the backing UIKit field directly - which is
            // exactly what the engine does, and what makes typing work - can
            // leave the binding untouched. That scored a genuine focus as a
            // miss. Ask the responder chain instead: if the archetype's own view
            // (or something inside it) is first responder, it was focused.
            let focused = await MainActor.run { () -> Bool in
                guard let token = archetype.effectToken, token.hasSuffix("textfield") || token.hasSuffix("textview"),
                      let match = ScreenElementFinder.find(id: archetype.id, text: nil).first else { return false }
                // Scan the ISLAND, not the stamped view's subtree.
                // `.uiKitIdentifier` stamps a background SIBLING, so the field
                // that actually took focus is not underneath the stamp - the
                // oracle reported 'never focused' for a field the trace shows
                // becoming first responder. An oracle that looks in the wrong
                // place fails exactly like the bug it is meant to detect.
                var root = match.view
                for _ in 0..<6 { root = root.superview ?? root }
                var stack: [UIView] = [root]
                while let cur = stack.popLast() {
                    if cur.isFirstResponder, cur is UITextInput { return true }
                    stack.append(contentsOf: cur.subviews)
                }
                return false
            }
            if focused, let token = archetype.effectToken, !effects.contains(token) { effects.append(token) }
            rows.append(Self.score(archetype, probe: probe, fired: fire, effects: effects))
            // Let any focus/keyboard/navigation settle before the next probe.
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        // ---- Anchor phase ----------------------------------------------
        // Proves the one sanctioned exception to "no coordinates past
        // resolve": an element-relative anchor recorded against the split
        // container must (a) have been needed at all (`pointMattered`), (b)
        // stay absent for a tap identity alone can replay, and (c) still
        // press the SAME half after the container moves and resizes —
        // resolved against the live frame, while the stale screen point
        // provably no longer covers that half.
        if fire {
            rows.append(contentsOf: await Self.anchorPhase())
            await MainActor.run { RipulConformanceState.shared.splitShifted = false }
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
    /// The anchor proof. All geometry is read from LIVE frames on the main
    /// actor — nothing here assumes padding values or screen sizes.
    private static func anchorPhase() async -> [[String: Any]] {
        var rows: [[String: Any]] = []
        let splitId = RipulConformance.prefix + "uikit.split"
        let buttonId = RipulConformance.prefix + "uikit.button"

        // The split row is the last row of the sheet — scroll it into view if
        // the sheet is too short, or every row below reports not-on-screen.
        await MainActor.run {
            guard let m = ScreenElementFinder.find(id: splitId, text: nil).first else { return }
            let f = m.view.convert(m.view.bounds, to: nil)
            if f.maxY > m.window.bounds.height - 40,
               let sv = ScrollElementTool.enclosingScrollView(of: m.view) {
                _ = ScreenActuationEngine.performScroll(on: sv, direction: "down", amount: 0.6)
            }
        }
        try? await Task.sleep(nanoseconds: 500_000_000)

        // (a) Locality: the reticule pointed at the right half must fire the
        // right half — through the full pick → resolve → actuate path.
        await MainActor.run { RipulConformanceLog.shared.clear() }
        let probeTrace = await MainActor.run { () -> String in
            guard let m = ScreenElementFinder.find(id: splitId, text: nil).first,
                  let live = ViewInspectorController.live else { return "split control or explorer missing" }
            let f = m.view.convert(m.view.bounds, to: nil)
            let probe = live.probe(atWindowPoint: CGPoint(x: f.minX + f.width * 0.8, y: f.midY), fire: true)
            return ((probe["fired"] as? [String: Any])?["trace"] as? String) ?? "no fire result"
        }
        let localityEffects = await MainActor.run { RipulConformanceLog.shared.fired }
        rows.append(["archetype": "Anchor: point picks the half it is over", "id": splitId,
                     "result": localityEffects.contains("split.right") && !localityEffects.contains("split.left")
                         ? "pass" : "fail",
                     "detail": "fired [\(localityEffects.joined(separator: ","))] — \(probeTrace)"])
        try? await Task.sleep(nanoseconds: 250_000_000)

        // (b) The exception stays exceptional: `pointMattered` must be TRUE
        // for the anonymous split (two point-eligible controls, nothing
        // nameable) and FALSE for an off-centre tap on a named UIButton —
        // that is the rule that keeps anchors off ordinary semantic steps.
        let shapes = await MainActor.run { () -> (split: Bool?, button: Bool?) in
            var split: Bool?, button: Bool?
            if let m = ScreenElementFinder.find(id: splitId, text: nil).first {
                let f = m.view.convert(m.view.bounds, to: nil)
                split = ScreenActuationEngine.resolveTap(on: m.view, matchId: splitId, matchText: nil,
                                                         at: CGPoint(x: f.minX + f.width * 0.8, y: f.midY)).pointMattered
            }
            if let m = ScreenElementFinder.find(id: buttonId, text: nil).first {
                let f = m.view.convert(m.view.bounds, to: nil)
                button = ScreenActuationEngine.resolveTap(on: m.view, matchId: buttonId, matchText: nil,
                                                          at: CGPoint(x: f.minX + f.width * 0.85, y: f.midY)).pointMattered
            }
            return (split, button)
        }
        rows.append(["archetype": "Anchor: recorded only when the point disambiguated", "id": splitId,
                     "result": shapes.split == true && shapes.button == false ? "pass" : "fail",
                     "detail": "pointMattered — split: \(shapes.split.map(String.init) ?? "unresolved"), "
                         + "uikit.button off-centre: \(shapes.button.map(String.init) ?? "unresolved") (want true / false)"])

        // (c) Element-grounded replay: synthesize the recorded form (durable
        // selector + element-relative anchor), MOVE AND RESIZE the container,
        // then replay through the production path — selector → live view →
        // anchor → live frame → point → resolve → actuate.
        struct Recorded { let selector: MacroSelector; let anchor: MacroAnchor?; let frame: CGRect; let point: CGPoint }
        let recorded = await MainActor.run { () -> Recorded? in
            guard let m = ScreenElementFinder.find(id: splitId, text: nil).first else { return nil }
            let f = m.view.convert(m.view.bounds, to: nil)
            let p = CGPoint(x: f.minX + f.width * 0.8, y: f.midY)
            let rtl = m.view.effectiveUserInterfaceLayoutDirection == .rightToLeft
            return Recorded(selector: MacroSelector(describing: m.view),
                            anchor: MacroAnchor.fraction(x: p.x, y: p.y, frameX: f.minX, frameY: f.minY,
                                                         width: f.width, height: f.height, rightToLeft: rtl),
                            frame: f, point: p)
        }
        guard let recorded, let anchor = recorded.anchor else {
            rows.append(["archetype": "Anchor: replay after the element moves", "id": splitId,
                         "result": "fail", "detail": "could not record selector + anchor"])
            return rows
        }

        await MainActor.run { RipulConformanceState.shared.splitShifted = true }
        try? await Task.sleep(nanoseconds: 600_000_000)
        await MainActor.run { RipulConformanceLog.shared.clear() }

        let replay = await MainActor.run { () -> (ok: Bool, via: String?, newFrame: CGRect?, error: String?) in
            let resolver = LiveScreenResolver()
            guard case .resolved(let view) = resolver.resolveTap(recorded.selector) else {
                return (false, nil, nil, "selector \(recorded.selector.compactSummary) did not resolve after the move")
            }
            let newFrame = view.convert(view.bounds, to: nil)
            let out = resolver.performTapDetailed(view, matchId: recorded.selector.id,
                                                  matchText: recorded.selector.text, anchor: anchor)
            return (out.success, out.via, newFrame, out.error)
        }
        let replayEffects = await MainActor.run { RipulConformanceLog.shared.fired }

        var frameMoved = false
        var derivedIn = false
        var staleIn = true
        var stalePointProof = "no post-move frame"
        if let nf = replay.newFrame {
            frameMoved = abs(nf.minX - recorded.frame.minX) > 40 || abs(nf.width - recorded.frame.width) > 40
            // The geometric statement of why screen coordinates are banned:
            // the anchored point follows the element into its new right half;
            // the stale screen point no longer covers it.
            let rightHalf = CGRect(x: nf.midX, y: nf.minY, width: nf.width / 2, height: nf.height)
            let derived = anchor.point(frameX: nf.minX, frameY: nf.minY,
                                       width: nf.width, height: nf.height, rightToLeft: false)
            derivedIn = rightHalf.contains(CGPoint(x: derived.x, y: derived.y))
            staleIn = rightHalf.contains(recorded.point)
            stalePointProof = "anchored point (\(Int(derived.x)),\(Int(derived.y))) in new right half: \(derivedIn); "
                + "stale screen point (\(Int(recorded.point.x)),\(Int(recorded.point.y))) in new right half: \(staleIn)"
        }

        let replayPassed = replay.ok && frameMoved
            && replayEffects.contains("split.right") && !replayEffects.contains("split.left")
        rows.append(["archetype": "Anchor: replay after the element moves", "id": splitId,
                     "result": replayPassed ? "pass" : "fail",
                     "detail": "frame \(short(recorded.frame)) → \(replay.newFrame.map(short) ?? "?"), "
                         + "moved: \(frameMoved), fired [\(replayEffects.joined(separator: ","))] via \(replay.via ?? "none")"
                         + (replay.error.map { " — \($0)" } ?? "")])
        rows.append(["archetype": "Anchor: stale screen point would miss", "id": splitId,
                     "result": derivedIn && !staleIn ? "pass" : "fail",
                     "detail": stalePointProof])
        return rows
    }

    private static func short(_ r: CGRect) -> String {
        "(\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height)))"
    }

    private static func score(_ a: RipulArchetype, probe: [String: Any], fired: Bool,
                              effects: [String]) -> [String: Any] {
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
        // The ENGINE's claim. Necessary, never sufficient.
        let claimed = (f?["success"] as? Bool) == true
        // The APP's record. `itemSelection` selects a SwiftUI List row, which
        // does nothing without a selection binding, yet reported success for a
        // UIButton, a UISwitch and an onTapGesture view - three controls that
        // were never touched, scored as passes. An archetype with a handler
        // passes only when that handler ran.
        let observed = a.effectToken.map(effects.contains) ?? false
        let pressed = a.effectToken == nil ? claimed : observed
        if !effects.isEmpty { row["observed"] = effects.joined(separator: ",") }

        // An archetype declared inert passes by being inert. Theme tools select
        // labels and backgrounds constantly, and "nothing here responds to a
        // tap" is the correct answer for them, not a miss. It has to survive the
        // PRESS too: predicting nothing and then pressing something is the
        // false-success failure mode, not a pass.
        guard a.expectActionable else {
            if !effects.isEmpty {
                row["result"] = "unexpected-actionable"
                row["detail"] = "declared inert, but pressing it ran \(effects.joined(separator: ","))"
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
            row["detail"] = claimed
                ? "the engine reported success via \(f?["via"] ?? "?") but the control's handler never ran"
                    + " - it pressed something else"
                : (actionable == nil
                    ? "no actionable element resolved and the press was refused"
                    : "resolved but the press was refused")
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
