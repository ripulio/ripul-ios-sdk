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
        + "reports the host app's screen, never the assistant. Only what can be seen is returned: views scrolled "
        + "or clipped out of sight, and interactive views covered by something else (a closed sidebar under the "
        + "main screen), are left out and counted in `hidden`; includeHidden returns them too, marked."
    public let inputSchema: [String: Any] = ToolSchema.object(
        .bool("includeScreenshot", "Also return a base64 JPEG of the screen (downscaled)"),
        .bool("includeHidden", "Also return views that can't be seen (covered, clipped or off screen), each marked with `hidden`"),
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
        let includeHidden = args["includeHidden"] as? Bool ?? false
        let filter = (args["filter"] as? String).flatMap { $0.isEmpty ? nil : $0.lowercased() }
        let maxElements = min(max(args["maxElements"] as? Int ?? 250, 1), 1000)

        guard let window = Self.hostKeyWindow() else {
            return ["success": false, "error": "No host window found"]
        }
        // The window, not `rootViewController.view`: a modally presented view
        // controller's view sits in a presentation container that is a SIBLING
        // of the root controller's view, so rooting the walk at the root
        // controller reported the screen UNDERNEATH any presented menu, sheet
        // or dialog — and never the thing the user was actually looking at.
        let root: UIView = window

        var visited = 0
        var hidden = 0
        // A fresh snapshot: handles issued by previous inspects go stale, then
        // each returned element is registered so actuation tools can target it
        // exactly (see ScreenSnapshotStore).
        ScreenSnapshotStore.shared.beginSnapshot()
        // Ids of covered controls by frame: a control drawn twice (the iOS 26
        // tab bar's two layers) carries its id on the layer underneath.
        var coveredControlIds: [(frame: CGRect, id: String)] = []
        // Everything reportable first; ids are completed, then the filter and
        // the cap apply, so a filter can find an id borrowed below.
        var collected: [(view: UIView, el: [String: Any])] = []
        Self.walk(root, clip: window.bounds) { view, depth, visibleFrame in
            visited += 1
            let hiddenReason = ScreenVisibility.hiddenReason(view, visibleFrame: visibleFrame, in: window)
            if hiddenReason != nil { hidden += 1 }
            if hiddenReason == "covered", view is UIControl, let id = ScreenElementFinder.identifier(of: view) {
                coveredControlIds.append((view.convert(view.bounds, to: window), id))
            }
            if hiddenReason != nil && !includeHidden { return hiddenReason }
            guard collected.count < 3000 else { return hiddenReason }
            var el = Self.element(for: view, depth: depth, window: window)
            if let hiddenReason { el["hidden"] = hiddenReason }
            if includeHidden, let hit = ScreenVisibility.hitReadout(view, visibleFrame: visibleFrame, in: window) {
                el["hitAtCentre"] = hit
            }
            collected.append((view, el))
            return hiddenReason
        }

        // The visible copy of a two-layer control takes the id of the covered
        // copy in the same place, so a caller can still find the Agent tab by
        // `Workspace.tab.agent` (tap_element resolves that id as before).
        for i in collected.indices where collected[i].el["id"] == nil && collected[i].el["control"] as? Bool == true {
            guard let f = collected[i].el["frame"] as? [String: Double] else { continue }
            let frame = CGRect(x: f["x"] ?? 0, y: f["y"] ?? 0, width: f["w"] ?? 0, height: f["h"] ?? 0)
            if let match = coveredControlIds.first(where: {
                abs($0.frame.minX - frame.minX) <= 2 && abs($0.frame.minY - frame.minY) <= 2
                    && abs($0.frame.width - frame.width) <= 2 && abs($0.frame.height - frame.height) <= 2
            }) {
                collected[i].el["id"] = match.id
                collected[i].el["idFrom"] = "covered layer"
            }
        }

        // SwiftUI draws its text outside UIKit, so an id stamp over "Macbook
        // pro" had no text. The accessibility tree publishes it: an element in
        // the same place names the stamp.
        let published = ScreenVisibility.accessibilityLabels(in: window)
        for i in collected.indices where collected[i].el["text"] == nil && collected[i].el["id"] != nil {
            guard let f = collected[i].el["frame"] as? [String: Double] else { continue }
            let frame = CGRect(x: f["x"] ?? 0, y: f["y"] ?? 0, width: f["w"] ?? 0, height: f["h"] ?? 0)
            let area = frame.width * frame.height
            guard area > 0 else { continue }
            let best = published.map { item -> (label: String, score: CGFloat) in
                let o = item.frame.intersection(frame)
                let inter = o.isNull ? 0 : o.width * o.height
                let union = area + item.frame.width * item.frame.height - inter
                return (item.label, union > 0 ? inter / union : 0)
            }.max { $0.score < $1.score }
            if let best, best.score >= 0.5 {
                collected[i].el["text"] = best.label.count > 160 ? String(best.label.prefix(159)) + "…" : best.label
                collected[i].el["textFrom"] = "accessibility"
            }
        }

        let matching = collected.filter { item in
            guard let filter else { return true }
            let hay = ["class", "text", "id", "ibOutlet", "vc", "role"]
                .compactMap { item.el[$0] as? String }
                .joined(separator: " ")
                .lowercased()
            return hay.contains(filter)
        }
        // Over the cap, keep what a caller can use (an id, text or a control)
        // ahead of anonymous wrappers, in tree order: a cap of 60 used to keep
        // the list's wrappers and drop the top bar and tab bar.
        var kept = matching
        if kept.count > maxElements {
            // Controls first, then the first view carrying each id (SwiftUI
            // repeats an id down a stack of wrappers), then text, then the rest.
            var seenIds = Set<String>()
            let tier: [Int] = matching.map { item in
                let el = item.el
                if el["control"] as? Bool == true { return 0 }
                if let id = el["id"] as? String, seenIds.insert(id).inserted { return 1 }
                return el["text"] != nil ? 2 : 3
            }
            let order = matching.indices.sorted { tier[$0] != tier[$1] ? tier[$0] < tier[$1] : $0 < $1 }
            kept = order.prefix(maxElements).sorted().map { matching[$0] }
        }
        let elements: [[String: Any]] = kept.map { item in
            var el = item.el
            el["handle"] = ScreenSnapshotStore.shared.register(
                view: item.view, id: el["id"] as? String, text: el["text"] as? String)
            return el
        }

        var result: [String: Any] = [
            "success": true,
            "screen": Self.rect(window.bounds),
            "visited": visited,
            "returned": elements.count,
            "hidden": hidden,
            "truncated": matching.count > elements.count,
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
    /// The host app's visible window — never SDK chrome.
    @MainActor
    private static func hostKeyWindow() -> UIWindow? {
        RipulChrome.appWindow()
    }

    @MainActor
    private static func isExcluded(_ window: UIWindow) -> Bool {
        RipulChrome.isRipulWindow(window)
    }

    /// Depth-first walk of the visible tree, skipping hidden / effectively-invisible
    /// views and (defensively) any excluded overlay window. Carries the part of
    /// each view that its clipping ancestors leave visible, in window space.
    @MainActor
    private static func walk(_ view: UIView, depth: Int = 0, clip: CGRect,
                             _ visit: (UIView, Int, CGRect) -> String?) {
        if view.isHidden || view.alpha < 0.01 { return }
        if let window = view as? UIWindow, isExcluded(window) { return }
        let frame = view.window.map { view.convert(view.bounds, to: $0) } ?? view.frame
        let visibleFrame = frame.intersection(clip)
        _ = visit(view, depth, visibleFrame)
        // Subviews may draw outside a view that doesn't clip; one that clips
        // hides them beyond its own bounds.
        let childClip = view.clipsToBounds ? visibleFrame : clip
        for sub in view.subviews {
            walk(sub, depth: depth + 1, clip: childClip, visit)
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

        if let text = InspectedView.textContent(of: view), !text.isEmpty {
            d["text"] = text
        } else if view is UITableViewCell || view is UICollectionViewCell,
                  let text = ScreenElementFinder.accessibilityLabelText(of: view, limit: 6) {
            // A SwiftUI row draws its text outside UIKit's labels; its
            // accessibility labels are the only text a walk can read, and
            // without them every session row came back nameless.
            d["text"] = text.count > 160 ? String(text.prefix(159)) + "…" : text
        }
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

#if canImport(UIKit)
/// What an agent can actually see on screen. Shared by inspect_screen (what it
/// reports) and the actuation tools (which of several matches is the real one).
enum ScreenVisibility {
    /// Why a view can't be seen, or nil when it can.
    ///
    /// Hidden and transparent views are skipped by the walk. What is left: a
    /// view scrolled or clipped out of sight, and a view something else covers.
    /// The closed sidebar was the case that mattered: it sits at its normal
    /// place UNDER the main screen, neither hidden nor transparent, and inspect
    /// reported about 60 of its rows as on screen, crowding out the real content
    /// and aiming taps at things nobody could see.
    ///
    /// Covered is judged the way a finger is: hit-test the centre, then four
    /// inner points. At each point the answer is one of:
    /// - this view or something inside it: seen;
    /// - another branch, drawn above this one: covered;
    /// - a container above this view in the tree (the touch stopped there):
    ///   proves nothing. SwiftUI draws most content in the host and keeps
    ///   platform views (gesture helpers, stamps) beneath it, so the Machines
    ///   card's pan helper looked covered by the card it serves.
    /// Each view is judged on its own points. Coverage is not inherited: the
    /// Machines card sits in a transparent full-screen wrapper whose sample
    /// points land on the list above it, and inheriting that hid the card.
    /// Seen at any point: visible. Covered at the points that could tell:
    /// covered. Nothing could tell: visible.
    @MainActor
    static func hiddenReason(_ view: UIView, visibleFrame: CGRect, in window: UIWindow) -> String? {
        if view is UIWindow { return nil }
        guard !visibleFrame.isNull, visibleFrame.width >= 1, visibleFrame.height >= 1 else { return "offscreen" }
        // An identifier stamp is an invisible marker beside the control it
        // names, and the control is drawn above it: the Agents/Plans switch
        // over `GlassTopBar.titleLozenge`, the menu button over
        // `GlassTopBar.trailingMenu`. A stamp covered by a control (or a
        // SwiftUI button host) is covered by what it names, which means it is
        // seen. A screen drawn over it (the list over the closed sidebar's
        // stamps) is not a control.
        let registry = UIKitIdentifierRegistry.shared
        let isStamp = (registry.identifier(for: view) != nil
            || String(describing: type(of: view)).contains("IdentifierStamper")
            || view.subviews.contains { registry.identifier(for: $0) != nil })
        func namesItsControl(_ hit: UIView) -> Bool {
            guard isStamp else { return false }
            let control = sequence(first: hit, next: { $0.superview }).prefix(3).contains {
                $0 is UIControl || String(describing: type(of: $0)).contains("Button")
            }
            let stampArea = max(visibleFrame.width * visibleFrame.height, 1)
            let h = hit.convert(hit.bounds, to: window)
            guard control, h.width * h.height <= stampArea * 3 else { return false }
            // Its OWN control: where the two branches part, the control's side
            // is a bar-sized container, not a screen. The Agents/Plans switch
            // over the closed sidebar's header is a control of the main
            // screen, drawn over the sidebar as part of that screen.
            guard let side = branch(of: hit, apartFrom: view) else { return false }
            let b = side.convert(side.bounds, to: window)
            return b.width * b.height <= stampArea * 4
        }
        var covered = 0
        func verdict(_ p: CGPoint) -> Bool? {
            guard let hit = window.hitTest(p, with: nil) else { return nil }
            if hit === view || hit.isDescendant(of: view) { return true }
            if view.isDescendant(of: hit) { return nil }
            guard isDrawn(hit, above: view) else { return nil }
            return namesItsControl(hit) ? true : false
        }
        let f = visibleFrame
        let points = [CGPoint(x: f.midX, y: f.midY)] + [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)]
            .map { CGPoint(x: f.minX + f.width * $0.0, y: f.minY + f.height * $0.1) }
        for p in points {
            switch verdict(p) {
            case true?: return nil
            case false?: covered += 1
            case nil: break
            }
        }
        return covered > 0 ? "covered" : nil
    }

    /// What the finger test hit at a view's centre, for includeHidden's readout.
    @MainActor
    static func hitReadout(_ view: UIView, visibleFrame: CGRect, in window: UIWindow) -> String? {
        guard !visibleFrame.isNull, visibleFrame.width >= 1, visibleFrame.height >= 1,
              let hit = window.hitTest(CGPoint(x: visibleFrame.midX, y: visibleFrame.midY), with: nil) else { return nil }
        let relation = hit === view ? "self" : hit.isDescendant(of: view) ? "inside"
            : view.isDescendant(of: hit) ? "container" : isDrawn(hit, above: view) ? "above" : "below"
        let name = String(describing: type(of: hit))
        return "\(relation):\(name.count > 60 ? String(name.prefix(60)) + "…" : name)"
    }

    /// The child of `a` and `b`'s nearest common ancestor that contains `a`:
    /// the part of the tree `a` belongs to where the two part. Nil when one
    /// contains the other.
    @MainActor
    static func branch(of a: UIView, apartFrom b: UIView) -> UIView? {
        var aChain: [UIView] = []
        var cur: UIView? = a
        while let v = cur { aChain.append(v); cur = v.superview }
        var bCur: UIView? = b.superview
        while let ancestor = bCur {
            if let i = aChain.firstIndex(where: { $0 === ancestor }) { return i > 0 ? aChain[i - 1] : nil }
            bCur = ancestor.superview
        }
        return nil
    }

    /// Whether `a` is drawn above `b`: at their nearest common ancestor, a's
    /// branch comes later among the subviews. False when one contains the other.
    @MainActor
    static func isDrawn(_ a: UIView, above b: UIView) -> Bool {
        var aChain: [UIView] = []
        var cur: UIView? = a
        while let v = cur { aChain.append(v); cur = v.superview }
        var bChild: UIView = b
        var bCur: UIView? = b.superview
        while let ancestor = bCur {
            if let i = aChain.firstIndex(where: { $0 === ancestor }) {
                guard i > 0 else { return false } // a contains b
                let aChild = aChain[i - 1]
                guard let ai = ancestor.subviews.firstIndex(where: { $0 === aChild }),
                      let bi = ancestor.subviews.firstIndex(where: { $0 === bChild }) else { return false }
                return ai > bi
            }
            bChild = ancestor
            bCur = ancestor.superview
        }
        return false
    }

    @MainActor
    static func isInteractiveBranch(_ view: UIView, in window: UIWindow) -> Bool {
        var cur: UIView? = view
        while let v = cur, v !== window {
            if !v.isUserInteractionEnabled { return false }
            cur = v.superview
        }
        return true
    }


    /// Every labelled accessibility element on screen, in window space, for
    /// naming stamps whose text SwiftUI draws itself. Bounded walk.
    @MainActor
    static func accessibilityLabels(in window: UIWindow, budget: Int = 2500) -> [(frame: CGRect, label: String)] {
        var out: [(frame: CGRect, label: String)] = []
        var left = budget
        var seen = Set<ObjectIdentifier>()
        func visit(_ obj: NSObject, depth: Int) {
            guard depth < 60, left > 0, seen.insert(ObjectIdentifier(obj)).inserted else { return }
            left -= 1
            if obj.isAccessibilityElement,
               let label = obj.accessibilityLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
                let f = ScreenElementFinder.windowRect(fromScreen: obj.accessibilityFrame, in: window)
                if f.width > 0, f.height > 0 { out.append((f, label)) }
            }
            if let els = obj.accessibilityElements as? [NSObject] {
                for e in els { visit(e, depth: depth + 1) }
            }
            if let v = obj as? UIView {
                for sub in v.subviews where !sub.isHidden && sub.alpha > 0.01 {
                    if let w = sub as? UIWindow, RipulChrome.isRipulWindow(w) { continue }
                    visit(sub, depth: depth + 1)
                }
            }
        }
        visit(window, depth: 0)
        return out
    }

    /// A view's frame in window space, cut down by every clipping ancestor.
    @MainActor
    static func visibleFrame(of view: UIView, in window: UIWindow) -> CGRect {
        var frame = view.convert(view.bounds, to: window)
        var cur = view.superview
        while let v = cur, v !== window {
            if v.clipsToBounds { frame = frame.intersection(v.convert(v.bounds, to: window)) }
            cur = v.superview
        }
        return frame.intersection(window.bounds)
    }

    @MainActor
    static func isVisible(_ view: UIView, in window: UIWindow) -> Bool {
        hiddenReason(view, visibleFrame: visibleFrame(of: view, in: window), in: window) == nil
    }
}
#endif
