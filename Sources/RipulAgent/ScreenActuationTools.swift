import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Built-in `NativeTool`s that let the dev-console agent ACT on the host app's
/// screen, closing the loop `inspect_screen` opened: tap buttons, type into
/// fields, scroll containers — addressed by the same accessibility id /
/// uiKitIdentifier / visible text the inspector returns.
///
/// Registration: `RipulAgentConsole`'s built-ins, so any host embedding the
/// console gets them. They exclude the dev-assistant overlay window exactly
/// like `InspectScreenTool` (the agent drives the HOST app, never itself).
///
/// Addressing model (for hosts with poor markup): XPath's addressing model
/// with JSON syntax, no string DSL. Every predicate ANDs together; `within`
/// anchors the search to a container's subtree ("the button inside the row
/// whose text contains 'Alice'"); nested duplicates (a button AND the label
/// inside it) collapse to the container; disjoint multi-matches fail with a
/// candidate list instead of silently tapping the first. `nth` is the
/// last-resort positional predicate.
///
/// Actuation order for taps (all public API first):
/// 1. `UIControl.sendActions(for: .touchUpInside)` — UIKit buttons/controls.
/// 2. `accessibilityActivate()` on the matching accessibility ELEMENT inside
///    the matched view — SwiftUI Buttons/rows expose their press on the
///    element (an `AccessibilityNode`), never on any UIView, so this is the
///    sanctioned route that presses them.
/// 3. `accessibilityActivate()` up the superview chain — the same hook for
///    UIKit views that implement it directly.
/// 4. Fire an attached `UITapGestureRecognizer`'s targets, read via the ObjC
///    runtime (`class_getInstanceVariable` + ivar loads). DEV-ONLY private
///    introspection — but NEVER via KVC: `UIGestureRecognizerTarget` is not
///    KVC-compliant for its SEL-typed `_action` ivar, and `value(forKey:)`
///    throws `NSUnknownKeyException` straight through Swift, killing the
///    host app. Runtime ivar reads return nil instead of throwing.
// MARK: - Element lookup (shared walker)
//
// `ScreenElementFinder`'s pure predicate-matching core (this declaration) is
// deliberately UNGATED — no UIKit dependency, so it compiles and is testable
// under plain `swift test` on macOS, where `canImport(UIKit)` is false and
// the `#if canImport(UIKit)` extension below (everything that actually walks
// a live `UIView` tree) compiles out entirely. See `ScreenElementFinderTests`
// (`RipulAgentTests`) for the pure-logic pins this split exists to enable.

/// Internal (not private) so `WaitForElementTool` can poll the same walker.
enum ScreenElementFinder {
    /// A predicate set: every non-nil predicate must match (AND). `nth` is not
    /// a predicate — it's a post-filter ordinal applied after collapse.
    struct Query {
        var id: String?
        var text: String?
        var role: String?
        var className: String?
        var nth: Int?

        var hasAnyPredicate: Bool {
            [id, text, role, className].contains { $0?.isEmpty == false }
        }
    }

    /// A candidate's queryable facts, decoupled from `UIView`.
    struct ElementFacts: Equatable {
        let id: String?
        let text: String?
        let role: String?
        let className: String?
    }

    /// The AND-predicate match itself — pure, no UIView. `viewMatches` (the
    /// UIKit-gated extension below) is the only caller that extracts facts
    /// from a live view; every other predicate rule lives here so it's tested
    /// once and used everywhere.
    static func matches(_ facts: ElementFacts, _ q: Query) -> Bool {
        if let id = q.id, !id.isEmpty {
            guard let fid = facts.id, fid == id || fid.caseInsensitiveCompare(id) == .orderedSame else { return false }
        }
        if let text = q.text, !text.isEmpty {
            guard let ftext = facts.text, ftext.range(of: text, options: .caseInsensitive) != nil else { return false }
        }
        if let role = q.role, !role.isEmpty {
            guard let frole = facts.role, frole.caseInsensitiveCompare(role) == .orderedSame else { return false }
        }
        if let cls = q.className, !cls.isEmpty {
            guard let fcls = facts.className, fcls.range(of: cls, options: .caseInsensitive) != nil else { return false }
        }
        return true
    }

    /// The pure algorithmic core of `collapseToOutermost`: drop any item whose
    /// ANCESTOR is also present in the set, keeping the outermost of each
    /// lineage. `isAncestor(a, b)` means "a is an ancestor of b" — the filter
    /// drops `item` when some `other` in the set is `item`'s ancestor. Generic
    /// (no `UIView`) so the algorithm itself is unit-testable under plain
    /// `swift test`.
    static func collapseToOutermost<T>(_ items: [T], isSame: (T, T) -> Bool, isAncestor: (T, T) -> Bool) -> [T] {
        items.filter { item in
            !items.contains { other in !isSame(other, item) && isAncestor(other, item) }
        }
    }
}

#if canImport(UIKit)

/// Everything that actually walks a live `UIView` tree — gated because
/// `UIApplication`/`UIView`/`UIWindow` don't exist outside `canImport(UIKit)`.
/// The pure predicate/collapse core these methods build on lives in the
/// ungated declaration above.
@MainActor
extension ScreenElementFinder {
    struct Match {
        let view: UIView
        let window: UIWindow
        let id: String?
        let text: String?
    }

    static func hostWindow() -> UIWindow? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .filter { $0.accessibilityIdentifier != RipulInspection.excludedOverlayWindowIdentifier && !$0.isHidden }
        return windows.first { $0.isKeyWindow }
            ?? windows.filter { $0.windowLevel == .normal }.last
            ?? windows.last
    }

    /// The identity ladder: UIKit accessibilityIdentifier (WAC's
    /// `<screen>.<element>`), then a uiKitIdentifier stamp, then a SwiftUI
    /// accessibility-tree id.
    static func identifier(of view: UIView) -> String? {
        var vid = view.accessibilityIdentifier
        if vid?.isEmpty ?? true { vid = UIKitIdentifierRegistry.shared.identifier(for: view) }
        if vid?.isEmpty ?? true { vid = InspectedView.accessibilityIdInTree(view) }
        return (vid?.isEmpty == false) ? vid : nil
    }

    /// Find elements by accessibility id (exact, then case-insensitive) or
    /// visible text (case-insensitive substring). Returns in walk (z) order.
    /// Kept for simple id/text lookups (wait_for_element polls); the actuation
    /// tools use the predicate-based `find(_:within:)` below.
    static func find(id: String?, text: String?) -> [Match] {
        guard let window = hostWindow() else { return [] }
        let root: UIView = window.rootViewController?.view ?? window
        var matches: [Match] = []
        walk(root) { view in
            let vid = identifier(of: view)
            let vtext = InspectedView.textContent(of: view)
            if let id, !id.isEmpty, let vid {
                if vid == id || vid.caseInsensitiveCompare(id) == .orderedSame {
                    matches.append(Match(view: view, window: window, id: vid, text: vtext))
                }
            } else if let text, !text.isEmpty, let vtext, !vtext.isEmpty,
                      vtext.range(of: text, options: .caseInsensitive) != nil {
                matches.append(Match(view: view, window: window, id: vid, text: vtext))
            }
        }
        return matches
    }

    private static func walk(_ view: UIView, _ visit: (UIView) -> Void) {
        if view.isHidden || view.alpha < 0.01 { return }
        if let window = view as? UIWindow,
           window.accessibilityIdentifier == RipulInspection.excludedOverlayWindowIdentifier { return }
        visit(view)
        for sub in view.subviews { walk(sub, visit) }
    }

    /// Resolve a snapshot handle from the last `inspect_screen`. `mode` picks
    /// the staleness rule: actuation refuses handles older than the last
    /// mutation; observation only needs the view alive and on screen.
    enum HandleMode { case actuation, observation }

    static func resolveHandle(_ handle: String, mode: HandleMode) -> Match? {
        let entry = mode == .actuation
            ? ScreenSnapshotStore.shared.resolveForActuation(handle)
            : ScreenSnapshotStore.shared.resolveForObservation(handle)
        guard let entry, let window = entry.view.window ?? hostWindow() else { return nil }
        return Match(view: entry.view, window: window, id: entry.id, text: entry.text)
    }

    /// Standard error for a handle that didn't resolve under actuation rules —
    /// distinguishes "never heard of it" from "the screen moved on".
    static func staleHandleError(_ handle: String) -> [String: Any] {
        if ScreenSnapshotStore.shared.contains(handle) {
            return ["success": false,
                    "error": "Handle '\(handle)' is stale — the screen changed since this snapshot. Run inspect_screen for fresh handles, or wait_for_element to observe this exact element."]
        }
        return ["success": false,
                "error": "Unknown handle '\(handle)'. Handles come from the most recent inspect_screen result (older ones go stale)."]
    }

    // MARK: Predicate queries (XPath addressing model, JSON syntax)

    /// The role vocabulary the tools match `role:` against. Best-effort:
    /// UIKit class first, then accessibility traits (where SwiftUI's element
    /// traits surface when they propagate to a host view), then a bare
    /// isAccessibilityElement fallback.
    static let roleVocabulary = ["button", "field", "switch", "slider", "segmented", "stepper",
                                 "pageControl", "image", "label", "cell", "list", "scrollView",
                                 "navigationBar", "tabBar", "link", "header", "control", "element"]

    static func role(of view: UIView) -> String? {
        switch view {
        case is UITextField, is UITextView: return "field"
        case is UISwitch: return "switch"
        case is UISlider: return "slider"
        case is UISegmentedControl: return "segmented"
        case is UIStepper: return "stepper"
        case is UIPageControl: return "pageControl"
        case is UIButton: return "button"
        case is UITableViewCell, is UICollectionViewCell: return "cell"
        case is UITableView, is UICollectionView: return "list"
        case is UIScrollView: return "scrollView"
        case is UIImageView: return "image"
        case is UILabel: return "label"
        case is UINavigationBar: return "navigationBar"
        case is UITabBar: return "tabBar"
        case is UIControl: return "control"
        default: break
        }
        let traits = view.accessibilityTraits
        if traits.contains(.button) { return "button" }
        if traits.contains(.link) { return "link" }
        if traits.contains(.searchField) { return "field" }
        if traits.contains(.image) { return "image" }
        if traits.contains(.header) { return "header" }
        if traits.contains(.staticText) { return "label" }
        if view.isAccessibilityElement { return "element" }
        return nil
    }

    /// Predicate search. When `anchor` is given only its subtree is searched
    /// (the anchor itself is excluded — "within X" means an element INSIDE X).
    /// Nested lineages collapse to their OUTERMOST member before returning:
    /// a button and the label inside it are ONE logical target, and the
    /// actuation ladder needs the container (path 1 fires on the UIControl,
    /// not the label inside it). Disjoint survivors are genuine ambiguity.
    static func find(_ query: Query, within anchor: UIView? = nil) -> [Match] {
        guard query.hasAnyPredicate else { return [] }
        guard let window = anchor?.window ?? hostWindow() else { return [] }
        let root: UIView = anchor ?? window.rootViewController?.view ?? window
        var matches: [Match] = []
        walk(root) { view in
            if let anchor, view === anchor { return }
            if viewMatches(view, query) {
                matches.append(Match(view: view, window: window,
                                     id: identifier(of: view), text: InspectedView.textContent(of: view)))
            }
        }
        return collapseToOutermost(matches)
    }

    /// UIView → `ElementFacts`, then delegates to the ungated `matches(_:_:)`
    /// (declared above, outside the `canImport(UIKit)` gate) so the predicate
    /// rules themselves are tested once and used everywhere.
    private static func viewMatches(_ view: UIView, _ q: Query) -> Bool {
        let facts = ElementFacts(id: identifier(of: view), text: InspectedView.textContent(of: view),
                                 role: role(of: view), className: String(describing: type(of: view)))
        return matches(facts, q)
    }

    /// Drop any match that has an ANCESTOR also among the matches — e.g. a
    /// button and the label inside it are one logical target, and the
    /// actuation ladder needs the container (path 1 fires on the UIControl,
    /// not the label inside it), so the button (outermost) survives and the
    /// label (its descendant) is dropped. See `find(_:within:)`.
    static func collapseToOutermost(_ matches: [Match]) -> [Match] {
        collapseToOutermost(matches, isSame: { $0.view === $1.view },
                            isAncestor: { ancestor, descendant in descendant.view.isDescendant(of: ancestor.view) })
    }

    /// The multi-match response: instead of silently acting on the first of N
    /// disjoint matches, hand the agent the candidate list (class/role/id/
    /// text/frame) so it can refine with within/role or pick nth next call.
    static func ambiguityError(_ matches: [Match], context: String) -> [String: Any] {
        [
            "success": false,
            "matched": matches.count,
            "error": "\(matches.count) disjoint elements match \(context) — ambiguous. Refine with within/role/id, or pass nth (0-based).",
            "candidates": matches.prefix(10).map { describe($0) },
        ]
    }

    /// Resolve a `within` argument to its anchor view. A nil `within` is a nil
    /// anchor (search the whole screen). The anchor must be UNIQUE after
    /// collapse — an ambiguous anchor makes the whole scoped search
    /// untrustworthy, so it errors with candidates like any ambiguity.
    static func resolveAnchor(_ within: [String: Any]?, mode: HandleMode) -> (anchor: UIView?, error: [String: Any]?) {
        guard let within else { return (nil, nil) }
        var anchorMatches: [Match] = []
        if let ah = within["handle"] as? String, !ah.isEmpty {
            guard let m = resolveHandle(ah, mode: mode) else {
                return (nil, staleHandleError(ah))
            }
            anchorMatches = [m]
        } else {
            let aq = Query(id: within["id"] as? String, text: within["text"] as? String,
                           role: within["role"] as? String, className: within["class"] as? String,
                           nth: within["nth"] as? Int)
            guard aq.hasAnyPredicate else {
                return (nil, ["success": false,
                              "error": "'within' needs at least one predicate (handle/id/text/role/class)."])
            }
            anchorMatches = find(aq)
        }
        if anchorMatches.isEmpty {
            return (nil, ["success": false,
                          "error": "The 'within' anchor matched nothing visible. inspect_screen shows the live tree; off-screen list rows only exist after scrolling."])
        }
        let nth = (within["nth"] as? Int) ?? (anchorMatches.count == 1 ? 0 : -1)
        if nth < 0 {
            return (nil, ambiguityError(anchorMatches, context: "the 'within' anchor"))
        }
        guard nth < anchorMatches.count else {
            return (nil, ["success": false, "matched": anchorMatches.count,
                          "error": "within.nth \(nth) out of range (0..<\(anchorMatches.count))."])
        }
        return (anchorMatches[nth].view, nil)
    }

    enum TargetResolution {
        case target(Match, matchCount: Int)
        case failure([String: Any])
    }

    /// Shared targeting for the actuation tools. Precedence: handle >
    /// (within anchor + AND predicates + nth). `textPredicateKey` lets
    /// type_text match on its `field` arg (its `text` is the text to type).
    static func resolveTarget(args: [String: Any], textPredicateKey: String = "text") -> TargetResolution {
        if let handle = args["handle"] as? String, !handle.isEmpty {
            guard let m = resolveHandle(handle, mode: .actuation) else {
                return .failure(staleHandleError(handle))
            }
            return .target(m, matchCount: 1)
        }

        let (anchor, anchorError) = resolveAnchor(args["within"] as? [String: Any], mode: .actuation)
        if let anchorError { return .failure(anchorError) }

        let q = Query(id: args["id"] as? String, text: args[textPredicateKey] as? String,
                      role: args["role"] as? String, className: args["class"] as? String,
                      nth: args["nth"] as? Int)
        guard q.hasAnyPredicate else {
            return .failure(["success": false,
                             "error": "Provide handle, or id/text/role/class (optionally scoped with within). Run inspect_screen to find elements."])
        }
        let found = find(q, within: anchor)
        if found.isEmpty {
            return .failure(["success": false,
                             "error": "No element found for that query\(anchor != nil ? " inside the anchor" : ""). inspect_screen shows the live tree; off-screen list rows only exist after scrolling."])
        }
        let nth = q.nth ?? (found.count == 1 ? 0 : -1)
        if nth < 0 {
            return .failure(ambiguityError(found, context: "that query"))
        }
        guard nth < found.count else {
            return .failure(["success": false, "matched": found.count,
                             "error": "nth \(nth) out of range (0..<\(found.count))."])
        }
        return .target(found[nth], matchCount: found.count)
    }

    static func describe(_ m: Match) -> [String: Any] {
        var d: [String: Any] = ["class": String(describing: type(of: m.view))]
        if let r = role(of: m.view) { d["role"] = r }
        if let id = m.id { d["id"] = id }
        if let text = m.text { d["text"] = text }
        let f = m.view.convert(m.view.bounds, to: m.window)
        d["frame"] = ["x": Double(f.minX), "y": Double(f.minY), "w": Double(f.width), "h": Double(f.height)]
        return d
    }
}

// MARK: - Actuation core (shared by the live tools AND macro replay, phase 1)

/// The single implementation of "how do we actually press/type/scroll a
/// resolved view" — extracted out of the three live tools so macro replay
/// (`docs/plans/automation-macros/`) calls the exact same code path instead of
/// a second copy that could drift. Nothing here changes behavior; it's a pure
/// extract-method refactor of what `TapElementTool`/`TypeTextTool`/
/// `ScrollElementTool` already did inline.
@MainActor
enum ScreenActuationEngine {
    struct TapOutcome {
        let success: Bool
        let via: String?
        let error: String?
    }

    struct ScrollOutcome {
        let offset: CGPoint
        let contentSize: CGSize
    }

    /// The 4-path tap ladder (see the file header). `matchId`/`matchText` feed
    /// path 2's leaf matching within the view's own accessibility subtree.
    static func performTap(on view: UIView, matchId: String?, matchText: String?) -> TapOutcome {
        if let control = view as? UIControl {
            control.sendActions(for: .touchUpInside)
            ScreenSnapshotStore.shared.invalidate()
            return TapOutcome(success: true, via: "uicontrol", error: nil)
        }
        if TapElementTool.activateAccessibilityElement(in: view, id: matchId, text: matchText) {
            ScreenSnapshotStore.shared.invalidate()
            return TapOutcome(success: true, via: "accessibilityElement", error: nil)
        }
        var v: UIView? = view
        while let cur = v {
            if cur.responds(to: #selector(UIResponder.accessibilityActivate)), cur.accessibilityActivate() {
                ScreenSnapshotStore.shared.invalidate()
                return TapOutcome(success: true, via: "accessibilityActivate", error: nil)
            }
            v = cur.superview
        }
        var g: UIView? = view
        while let cur = g {
            for gr in cur.gestureRecognizers ?? [] where gr.isEnabled {
                guard let tap = gr as? UITapGestureRecognizer else { continue }
                if TapElementTool.fireTapTargets(of: tap) {
                    ScreenSnapshotStore.shared.invalidate()
                    return TapOutcome(success: true, via: "tapGesture", error: nil)
                }
            }
            g = cur.superview
        }
        return TapOutcome(success: false, via: nil,
                          error: "Element found but not tappable by any path (not a control, no activatable accessibility element, no tap gesture).")
    }

    /// Set a text field/view's content, firing the same change notification
    /// real typing would. `nil` return means no text-input view was found at
    /// or below `view`.
    static func performType(on view: UIView, text: String, append: Bool) -> (success: Bool, error: String?) {
        guard let input = TypeTextTool.textInput(in: view) else {
            return (false, "Element found but no text input at or below it. Match the field itself (role=\"field\", or its accessibility id).")
        }
        _ = input.view.becomeFirstResponder()
        let newText = append ? (input.currentText + text) : text
        input.setText(newText)
        ScreenSnapshotStore.shared.invalidate()
        return (true, nil)
    }

    /// Scroll by a fraction of the visible size in one direction, clamped to
    /// content bounds — identical math to the shipped `scroll_element`.
    static func performScroll(on scrollView: UIScrollView, direction: String, amount: Double) -> ScrollOutcome {
        let fraction: CGFloat
        switch direction {
        case "up": fraction = -1
        case "left": fraction = -1
        default: fraction = 1
        }
        let horizontal = direction == "left" || direction == "right"
        var offset = scrollView.contentOffset
        if horizontal {
            let step = scrollView.bounds.width * amount * fraction
            offset.x = max(-scrollView.adjustedContentInset.left,
                           min(scrollView.contentSize.width - scrollView.bounds.width + scrollView.adjustedContentInset.right, offset.x + step))
        } else {
            let step = scrollView.bounds.height * amount * fraction
            offset.y = max(-scrollView.adjustedContentInset.top,
                           min(scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom, offset.y + step))
        }
        scrollView.setContentOffset(offset, animated: true)
        ScreenSnapshotStore.shared.invalidate()
        return ScrollOutcome(offset: offset, contentSize: scrollView.contentSize)
    }
}

// MARK: - tap_element

public struct TapElementTool: NativeTool {
    public let name = "tap_element"
    public let description = "Tap an on-screen element (button, row, tab) in the host app. Addressing is a "
        + "predicate query — every given predicate ANDs together, XPath-style: handle (preferred, exact) > "
        + "id/text/role/class, optionally scoped by 'within'. Example: within={text:\"Alice\"}, role=\"button\" "
        + "taps the button inside Alice's row. Ambiguous queries (several disjoint matches) FAIL with a "
        + "candidate list — refine with within/role/id, or pass nth. Nested duplicates (button + its label) "
        + "collapse to the container. Handles go stale on any screen change; follow with wait_for_element."
    public let inputSchema: [String: Any] = ToolSchema.object(
        .string("handle", "Handle from the last inspect_screen (e.g. \"e7\") — taps exactly that element (preferred)"),
        .selector("within", "Anchor container: search only inside its subtree, e.g. {text:\"Alice\"} for the row containing Alice"),
        .string("id", "Accessibility id / uiKitIdentifier of the element (exact)"),
        .string("text", "Visible text to match (case-insensitive substring)"),
        .stringEnum("role", "Element role (see inspect_screen's role field)", values: ScreenElementFinder.roleVocabulary),
        .string("class", "Class-name substring (e.g. \"Button\", \"BarButton\")"),
        .integer("nth", "0-based ordinal when several disjoint elements match (last resort)")
    )

    /// SDK-internal — see `RipulDeveloperOnlyTool`.
    init() {}

    @MainActor
    public func execute(args: [String: Any]) async throws -> Any {
        let target: ScreenElementFinder.Match
        let matchCount: Int
        switch ScreenElementFinder.resolveTarget(args: args) {
        case .failure(let error): return error
        case .target(let m, let count): target = m; matchCount = count
        }
        let outcome = ScreenActuationEngine.performTap(on: target.view,
                                                        matchId: args["id"] as? String,
                                                        matchText: args["text"] as? String)
        if outcome.success {
            return ["success": true, "via": outcome.via as Any, "matched": matchCount, "element": ScreenElementFinder.describe(target)]
        }
        return ["success": false, "matched": matchCount, "element": ScreenElementFinder.describe(target),
                "error": outcome.error as Any]
    }

    /// Walk the accessibility tree under `view` (elements array / container
    /// protocol / subviews — same traversal as the inspector) and activate the
    /// element matching the requested id or text. Only presses something it can
    /// NAME: the matched element, or the single element the view exposes —
    /// never "the first of many".
    static func activateAccessibilityElement(in view: UIView, id: String?, text: String?) -> Bool {
        var matched: [NSObject] = []
        var all: [NSObject] = []
        func leafMatches(_ el: NSObject) -> Bool {
            if let id, !id.isEmpty,
               let eid = InspectedView.objectAccessibilityIdentifier(el),
               eid.caseInsensitiveCompare(id) == .orderedSame { return true }
            if let text, !text.isEmpty {
                let hay = [el.accessibilityLabel, el.accessibilityValue].compactMap { $0 }.joined(separator: " ")
                if hay.range(of: text, options: .caseInsensitive) != nil { return true }
            }
            return false
        }
        func visit(_ obj: NSObject, depth: Int) {
            if depth > 60 || all.count > 300 { return }
            var children: [NSObject] = []
            if let els = obj.accessibilityElements as? [NSObject] {
                children = els
            } else {
                let n = obj.accessibilityElementCount()
                if n > 0 && n != NSNotFound {
                    for i in 0..<n { if let e = obj.accessibilityElement(at: i) as? NSObject { children.append(e) } }
                }
            }
            if !children.isEmpty {
                for c in children { visit(c, depth: depth + 1) }
                return
            }
            if obj.isAccessibilityElement {
                all.append(obj)
                if leafMatches(obj) { matched.append(obj) }
                return
            }
            if let v = obj as? UIView {
                for sub in v.subviews where !sub.isHidden && sub.alpha > 0.01 { visit(sub, depth: depth + 1) }
            }
        }
        visit(view, depth: 0)
        guard let el = matched.first ?? (all.count == 1 ? all.first : nil) else { return false }
        return el.accessibilityActivate()
    }

    /// Invoke a tap gesture recognizer's registered target/action pairs with the
    /// recognizer as the argument — indistinguishable from a real finger tap to
    /// the receiving code. Returns false if the private introspection fails.
    ///
    /// Reads `_targets` / `_target` / `_action` via the ObjC runtime, NOT KVC:
    /// `UIGestureRecognizerTarget` raises `NSUnknownKeyException` for
    /// `value(forKey: "action")` (KVC cannot box a SEL ivar), and an ObjC
    /// exception through Swift terminates the app. Runtime lookups return nil
    /// on any mismatch instead of throwing. Verified on the iOS 26 SDK.
    static func fireTapTargets(of gesture: UITapGestureRecognizer) -> Bool {
        guard let targetsIvar = class_getInstanceVariable(UIGestureRecognizer.self, "_targets"),
              let records = object_getIvar(gesture, targetsIvar) as? [NSObject], !records.isEmpty else { return false }
        var fired = false
        for record in records {
            guard let targetIvar = class_getInstanceVariable(type(of: record), "_target"),
                  let target = object_getIvar(record, targetIvar) as? NSObject,
                  let actionIvar = class_getInstanceVariable(type(of: record), "_action") else { continue }
            // SEL ivar: raw pointer-sized load at the ivar's offset — object_getIvar
            // would treat the SEL as an object and over-release garbage.
            let base = UnsafeRawPointer(Unmanaged.passUnretained(record).toOpaque())
            guard let rawSel = base.load(fromByteOffset: ivar_getOffset(actionIvar), as: Optional<UnsafeRawPointer>.self) else { continue }
            let action = unsafeBitCast(rawSel, to: Selector.self)
            _ = target.perform(action, with: gesture)
            fired = true
        }
        return fired
    }
}

// MARK: - type_text

public struct TypeTextTool: NativeTool {
    public let name = "type_text"
    public let description = "Enter text into a text field in the host app (UITextField/UITextView, incl. the "
        + "UIKit field behind a SwiftUI TextField). Addressing mirrors tap_element: handle (preferred) > "
        + "id/field/role/class ANDed together, optionally scoped by 'within' — role=\"field\" matches text "
        + "inputs directly. Replaces the content by default; set append to add to it. Fires editingChanged "
        + "so bindings and validation react exactly as to real typing."
    public let inputSchema: [String: Any] = ToolSchema.object(
        .string("handle", "Handle from the last inspect_screen — types into exactly that element's field (preferred)"),
        .selector("within", "Anchor container: search only inside its subtree, e.g. {text:\"Sign in\"} for the form"),
        .string("id", "Accessibility id of the text field"),
        .string("field", "Placeholder or current text of the field to match (substring)"),
        .stringEnum("role", "Element role — \"field\" matches text inputs", values: ScreenElementFinder.roleVocabulary),
        .string("class", "Class-name substring (e.g. \"TextField\")"),
        .integer("nth", "0-based ordinal when several disjoint elements match (last resort)"),
        .string("text", "The text to enter (required)", required: true),
        .bool("append", "Append to the existing content instead of replacing it (default false)")
    )

    /// SDK-internal — see `RipulDeveloperOnlyTool`.
    init() {}

    @MainActor
    public func execute(args: [String: Any]) async throws -> Any {
        guard let text = args["text"] as? String else {
            return ["success": false, "error": "text is required"]
        }
        let append = args["append"] as? Bool ?? false

        // Match on `field` (placeholder/current content) — `text` is the payload.
        let target: ScreenElementFinder.Match
        switch ScreenElementFinder.resolveTarget(args: args, textPredicateKey: "field") {
        case .failure(let error): return error
        case .target(let m, _): target = m
        }

        let outcome = ScreenActuationEngine.performType(on: target.view, text: text, append: append)
        if outcome.success {
            return ["success": true, "appended": append, "element": ScreenElementFinder.describe(target)]
        }
        return ["success": false, "element": ScreenElementFinder.describe(target), "error": outcome.error as Any]
    }

    /// The text-input view at or below (or immediately above) the matched element.
    static func textInput(in view: UIView) -> TextInputBox? {
        if let box = TextInputBox(view) { return box }
        for sub in view.subviews {
            if let box = textInput(in: sub) { return box }
        }
        // SwiftUI fields: the match may be a wrapper whose sibling/child chain
        // holds the real input — also check up to 2 levels of descendants.
        for sub in view.subviews {
            for sub2 in sub.subviews {
                if let box = TextInputBox(sub2) { return box }
            }
        }
        return nil
    }

    /// Uniform text set/read over UITextField / UITextView.
    struct TextInputBox {
        let view: UIView
        let currentText: String
        let setText: (String) -> Void

        init?(_ view: UIView) {
            if let field = view as? UITextField {
                self.view = field
                currentText = field.text ?? ""
                setText = { new in
                    field.text = new
                    field.sendActions(for: .editingChanged)
                }
                return
            }
            if let tv = view as? UITextView {
                self.view = tv
                currentText = tv.text ?? ""
                setText = { new in
                    tv.text = new
                    NotificationCenter.default.post(name: UITextView.textDidChangeNotification, object: tv)
                }
                return
            }
            return nil
        }
    }
}

// MARK: - scroll_element

public struct ScrollElementTool: NativeTool {
    public let name = "scroll_element"
    public let description = "Scroll a container in the host app (list, scroll view) by a fraction of its "
        + "visible height. Address it like tap_element (handle > id/text/role/class ANDed, optional 'within') "
        + "— role=\"list\" matches tables/collections directly; matching any element scrolls its enclosing "
        + "scroll view. With no addressing at all, the first scroll view on screen is used. Use inspect_screen "
        + "to see what's visible, scroll, then inspect again."
    public let inputSchema: [String: Any] = ToolSchema.object(
        .string("handle", "Handle from the last inspect_screen — scrolls that element's enclosing scroll view (preferred)"),
        .selector("within", "Anchor container: search only inside its subtree"),
        .string("id", "Accessibility id of the scroll container or an element inside it"),
        .string("text", "Visible text of an element inside the container (substring)"),
        .stringEnum("role", "Element role — \"list\" matches tables/collections, \"scrollView\" any scroll container", values: ScreenElementFinder.roleVocabulary),
        .string("class", "Class-name substring (e.g. \"TableView\")"),
        .integer("nth", "0-based ordinal when several disjoint elements match (last resort)"),
        .string("direction", "up | down | left | right (default down; 'up' scrolls toward the top)"),
        .number("amount", "Fraction of the visible size to scroll by, 0.1–2.0 (default 0.8)")
    )

    /// SDK-internal — see `RipulDeveloperOnlyTool`.
    init() {}

    @MainActor
    public func execute(args: [String: Any]) async throws -> Any {
        let direction = (args["direction"] as? String ?? "down").lowercased()
        let amount = min(max(args["amount"] as? Double ?? 0.8, 0.1), 2.0)

        // Resolve the scroll view: enclosing for a matched element, else (no
        // addressing at all) the first visible one on screen.
        var scrollView: UIScrollView?
        let hasAddressing = ["handle", "within", "id", "text", "role", "class"].contains { args[$0] != nil }
        if hasAddressing {
            switch ScreenElementFinder.resolveTarget(args: args) {
            case .failure(let error): return error
            case .target(let m, _):
                scrollView = m.view as? UIScrollView ?? Self.enclosingScrollView(of: m.view)
                if scrollView == nil {
                    return ["success": false, "element": ScreenElementFinder.describe(m),
                            "error": "Element resolved, but it isn't inside a scroll view."]
                }
            }
        } else if let window = ScreenElementFinder.hostWindow() {
            scrollView = Self.firstScrollView(in: window.rootViewController?.view ?? window)
        }
        guard let sv = scrollView else {
            return ["success": false, "error": "No scroll view found. Pass the id of an element inside the list."]
        }

        let outcome = ScreenActuationEngine.performScroll(on: sv, direction: direction, amount: amount)
        return ["success": true,
                "scrolledTo": ["x": Double(outcome.offset.x), "y": Double(outcome.offset.y)],
                "contentSize": ["w": Double(outcome.contentSize.width), "h": Double(outcome.contentSize.height)]]
    }

    static func enclosingScrollView(of view: UIView) -> UIScrollView? {
        var v = view.superview
        while let cur = v {
            if let sv = cur as? UIScrollView { return sv }
            v = cur.superview
        }
        return nil
    }

    private static func firstScrollView(in view: UIView) -> UIScrollView? {
        if let sv = view as? UIScrollView, !sv.isHidden && sv.alpha > 0.01 { return sv }
        for sub in view.subviews {
            if let found = firstScrollView(in: sub) { return found }
        }
        return nil
    }
}
#endif
