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
///    host app. Runtime ivar reads return nil instead of throwing. NEVER
///    fires recognizers attached to scroll containers (UITableView/
///    UICollectionView/UIScrollView): those compute the target row from the
///    recognizer's STALE location — firing one selects whatever row sits at
///    that point (typically the top of the list) and reads as success, so
///    path 5 never runs.
/// 5. Container selection — walk to the nearest UITableViewCell /
///    UICollectionViewCell and drive the owning container's delegate
///    `didSelect` call (public API). Covers the case where NO touch
///    semantics live on the element at all: the table/collection owns the
///    tap. Broadest fallback, so it runs last.
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

    /// The window actuation drives: the HOST's, never SDK chrome.
    static func hostWindow() -> UIWindow? {
        RipulChrome.appWindow()
    }

    /// The identity ladder: UIKit accessibilityIdentifier (WAC's
    /// `<screen>.<element>`), then a uiKitIdentifier stamp, then a SwiftUI
    /// accessibility-tree id.
    static func identifier(of view: UIView) -> String? {
        var vid = ownAccessibilityIdentifier(of: view)
        if vid?.isEmpty ?? true { vid = UIKitIdentifierRegistry.shared.identifier(for: view) }
        if vid?.isEmpty ?? true { vid = InspectedView.accessibilityIdInTree(view) }
        return (vid?.isEmpty == false) ? vid : nil
    }

    /// `accessibilityIdentifier`, but only when the view actually OWNS it.
    ///
    /// SwiftUI applies `.accessibilityIdentifier` (and therefore
    /// `.uiKitIdentifier`) to a whole subtree: every descendant UIView ends up
    /// carrying the island's identifier as its own property. WAC's notes field
    /// reported `addShift.notes.root` — the PANEL's id — in place of the
    /// `addShift.notes.field` its own code had set, intermittently, depending
    /// on when SwiftUI last re-rendered. Acted on as identity, that sent the
    /// actuation ladder climbing to the panel and collapsing it.
    ///
    /// An id shared with an ancestor was inherited FROM that ancestor and names
    /// it, not this view. The outermost view carrying a given id owns it;
    /// everything below has borrowed it. Bounded climb — an id is only
    /// interesting relative to nearby structure.
    static func ownAccessibilityIdentifier(of view: UIView) -> String? {
        guard let id = view.accessibilityIdentifier, !id.isEmpty else { return nil }
        var ancestor = view.superview
        var hops = 0
        while let cur = ancestor, hops < 12 {
            if cur.accessibilityIdentifier == id { return nil }   // inherited
            ancestor = cur.superview
            hops += 1
        }
        return id
    }

    /// Whether `view`'s identifier came from an ancestor rather than itself —
    /// surfaced in the explorer readout so a borrowed id is visible as such
    /// rather than read as the element's own name.
    static func hasInheritedIdentifier(_ view: UIView) -> Bool {
        (view.accessibilityIdentifier?.isEmpty == false) && ownAccessibilityIdentifier(of: view) == nil
    }

    /// The first non-empty `UILabel.text` in `view`'s subtree — the label a
    /// composite control contains (a tab-bar button's title, an icon-button's
    /// caption). Bounded depth, skips hidden/faded branches. Used by
    /// `contentText` for controls only, never for plain containers — a
    /// UITableViewCell whose row contains "Delete" must NOT itself match the
    /// text, or collapse-to-outermost would hand the tap to the row instead
    /// of the button inside it.
    static func descendantLabelText(of view: UIView, maxDepth: Int = 4) -> String? {
        guard maxDepth > 0 else { return nil }
        for sub in view.subviews where !sub.isHidden && sub.alpha > 0.01 {
            if let label = sub as? UILabel, let text = label.text, !text.isEmpty {
                return text
            }
            if let found = descendantLabelText(of: sub, maxDepth: maxDepth - 1) {
                return found
            }
        }
        return nil
    }

    /// Text a view "contains" for matching purposes — XPath's `contains(.)`
    /// predicate: the view's own text content, and for a UIControl (which is
    /// an interactive container, never a passive row) the label text inside
    /// it. Non-controls keep own-text-only semantics, deliberately — see
    /// `descendantLabelText`.
    static func contentText(of view: UIView) -> String? {
        if let own = InspectedView.textContent(of: view), !own.isEmpty { return own }
        if view is UIControl { return descendantLabelText(of: view) }
        // A SwiftUI island has no text a UIKit walk can see: `Text` does not
        // render into a UILabel, so every view inside a hosting view is
        // textless and a text query could never match one. SwiftUI publishes
        // that text in the ACCESSIBILITY tree instead, so for a hosting view
        // the queryable text is its accessibility labels. Matching the island
        // is enough to actuate correctly — `performTap` narrows to the right
        // element inside it by the same label (path 2).
        if isHostingView(view) { return accessibilityLabelText(of: view) }
        return nil
    }

    /// A SwiftUI hosting view — the boundary of one SwiftUI island in a UIKit
    /// hierarchy. Matched by class name because the type is private to SwiftUI.
    static func isHostingView(_ view: UIView) -> Bool {
        String(describing: type(of: view)).contains("HostingView")
    }

    /// Every accessibility label published under `view`, joined. Used as the
    /// text fact for a SwiftUI island (see `contentText`).
    static func accessibilityLabelText(of view: UIView, limit: Int = 60) -> String? {
        var labels: [String] = []
        func visit(_ obj: NSObject, depth: Int) {
            if depth > 40 || labels.count >= limit { return }
            if obj.isAccessibilityElement,
               let l = obj.accessibilityLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
               !l.isEmpty {
                labels.append(l)
            }
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
            if let v = obj as? UIView {
                for sub in v.subviews where !sub.isHidden && sub.alpha > 0.01 { visit(sub, depth: depth + 1) }
            }
        }
        visit(view, depth: 0)
        return labels.isEmpty ? nil : labels.joined(separator: " ")
    }

    /// Find elements by accessibility id (exact, then case-insensitive) or
    /// visible text (case-insensitive substring). Returns in walk (z) order.
    /// Kept for simple id/text lookups (wait_for_element polls); the actuation
    /// tools use the predicate-based `find(_:within:)` below.
    static func find(id: String?, text: String?) -> [Match] {
        guard let window = hostWindow() else { return [] }
        // The window — presented content is a sibling of the root controller's
        // view, not a descendant. See `find(_:within:)`.
        let root: UIView = window
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
        // The WINDOW, not `rootViewController.view`: UIKit puts a modally
        // presented view controller's view in a presentation container that is
        // a SIBLING of the root controller's view, so a walk rooted at the root
        // controller cannot see presented content at all. That is why a
        // recorded tap on a presented menu could never be resolved on replay
        // while the View Explorer could still pick it — the explorer hit-tests
        // the window.
        let root: UIView = anchor ?? window
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
    /// rules themselves are tested once and used everywhere. The text fact
    /// comes from `contentText` — own text, plus descendant label text for
    /// UIControl containers (the `contains(.)` semantics).
    private static func viewMatches(_ view: UIView, _ q: Query) -> Bool {
        let facts = ElementFacts(id: identifier(of: view), text: contentText(of: view),
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
        /// Identity of the accessibility element actually activated, when the
        /// tap went through one. An anonymous SwiftUI leaf (`_UIInheritedView`,
        /// no id, no UILabel text) is unnameable from the view tree, and the
        /// macro recorder was writing `class=_UIInheritedView` selectors that
        /// nothing could resolve on replay. This is the name it should record.
        var activatedIdentifier: String? = nil
        var activatedLabel: String? = nil
        /// One token per ladder path in order — what each tried and what it
        /// did (e.g. "control:no a11y:no gesture:containerSkipped row:HomeCell[0:0]").
        /// Turns "it didn't click through" from a shrug into a diagnosis:
        /// the path that claimed success is named, and every skip is visible.
        let trace: String
    }

    struct ScrollOutcome {
        let offset: CGPoint
        let contentSize: CGSize
    }

    /// The tap ladder (see the file header). `matchId`/`matchText` feed path 2's
    /// leaf matching within the view's own accessibility subtree.
    ///
    /// `windowPoint` — where the user actually pointed, in the view's window
    /// coordinates — is what makes path 2c possible: SwiftUI leaves are often
    /// anonymous scaffolding (`_UIInheritedView` with no id, no text, no
    /// control), and then the POINT is the only thing that identifies which
    /// element was meant. Defaults to the view's own centre, which is what
    /// "tap this element" means for a caller that resolved it by predicate.
    static func performTap(on view: UIView, matchId: String?, matchText: String?,
                           at windowPoint: CGPoint? = nil) -> TapOutcome {
        // Stamp the SDK version FIRST. Three separate rounds have been spent
        // deducing which build produced a trace from which tokens happened to
        // be present in it — a fix shipped, a stale binary tested, and the
        // result read as "the fix didn't work". A trace has to say what
        // produced it.
        var trace: [String] = ["sdk=\(ripulSDKVersion)"]
        // Worth naming: a detached target means every coordinate derived FROM
        // it is meaningless, and it explains failures that otherwise look like
        // empty space.
        // A UIWindow's own `window` is nil, so the naive check called every
        // window detached — a misleading token in exactly the diagnostics that
        // are supposed to be trustworthy.
        if view.window == nil, !(view is UIWindow) { trace.append("detached") }
        if let control = view as? UIControl {
            // Only claim this path if something is actually WIRED to the event.
            // SwiftUI ships its own UIControl shells — `HostingUIButton` — that
            // handle the press internally rather than through target/action, so
            // `sendActions` is a silent no-op on them. Firing regardless made
            // the ladder stop at path 1 and report `via uicontrol` for a button
            // that did nothing, which is worse than failing: it hides the
            // accessibility activation below that would have worked, and it
            // tells the caller the tap landed.
            let wired = control.allTargets.contains { target in
                control.actions(forTarget: target, forControlEvent: .touchUpInside)?.isEmpty == false
            }
            if wired {
                control.sendActions(for: .touchUpInside)
                ScreenSnapshotStore.shared.invalidate()
                trace.append("control:fired")
                return TapOutcome(success: true, via: "uicontrol", error: nil,
                                  trace: trace.joined(separator: " "))
            }
            trace.append("control:noTargets(\(type(of: control)))")
        } else {
            trace.append("control:no")
        }
        if let el = TapElementTool.activateAccessibilityElement(in: view, id: matchId, text: matchText) {
            ScreenSnapshotStore.shared.invalidate()
            trace.append("a11y:activated")
            return TapOutcome(success: true, via: "accessibilityElement", error: nil,
                              activatedIdentifier: InspectedView.objectAccessibilityIdentifier(el),
                              activatedLabel: el.accessibilityLabel,
                              trace: trace.joined(separator: " "))
        }
        trace.append("a11y:no")

        // 2a. The target IS a text input. Then tapping it means focusing it —
        //     unambiguously, with no search and no identity involved — and that
        //     must be settled before any path that climbs to an ancestor.
        //
        //     Proven on device: SwiftUI propagates a `.uiKitIdentifier` from an
        //     enclosing island DOWN onto a child's accessibilityIdentifier, so
        //     WAC's notes field reports the PANEL's id (`addShift.notes.root`)
        //     instead of its own. The strict climb below then matched that id
        //     honestly and activated the panel's own element — collapsing the
        //     panel instead of entering the field. Identity that has been
        //     inherited from an ancestor points AT the ancestor; a text input
        //     needs no identity at all.
        if let field = view as? UIView & UITextInput, field.canBecomeFirstResponder,
           field.becomeFirstResponder() {
            ScreenSnapshotStore.shared.invalidate()
            trace.append("focusSelf:activated(\(type(of: view)))")
            return TapOutcome(success: true, via: "focus", error: nil,
                              activatedIdentifier: view.accessibilityIdentifier,
                              activatedLabel: view.accessibilityLabel,
                              trace: trace.joined(separator: " "))
        }

        // 2b. SwiftUI hosting boundary. A leaf inside a SwiftUI island — a
        //     `.uiKitIdentifier` stamp, a text/image platform view — has no
        //     accessibility element of its OWN: SwiftUI publishes the control's
        //     element on the enclosing hosting view. Without this the whole rest
        //     of the ladder is UIKit-shaped and finds nothing (SwiftUI buttons
        //     are not UIControls and their recognizers are not
        //     UITapGestureRecognizers), so pointing the View Explorer at a glass
        //     field reported "not tappable" for a control that works under a
        //     real finger.
        //
        //     Bounded two ways so it can never reach into unrelated UI: it stops
        //     at the same container boundaries as the gesture path, and it is
        //     STRICT — an actual id/text match, never the "only one element in
        //     here" fallback that the direct call above allows.
        let hasIdentity = (matchId?.isEmpty == false) || (matchText?.isEmpty == false)
        if hasIdentity {
            // An ancestor's element may only stand in for the target if it
            // occupies roughly the same SPACE. An id can be inherited from an
            // enclosing SwiftUI island, so matching on it alone led straight to
            // the island's own element — a 360×93 panel activated on behalf of
            // a 284×44 field. Space cannot be inherited: if the element found
            // is far bigger than what was aimed at, it is a different control.
            let targetArea = max(1, view.bounds.width * view.bounds.height)
            func representsTarget(_ el: NSObject) -> Bool {
                let f = el.accessibilityFrame
                guard f.width > 0, f.height > 0 else { return true }  // no frame to judge by
                return (f.width * f.height) <= targetArea * 3
            }
            var a: UIView? = view.superview
            while let cur = a, !(cur is UIScrollView), !(cur is UIWindow) {
                if let el = TapElementTool.activateAccessibilityElement(in: cur, id: matchId,
                                                                       text: matchText, strict: true,
                                                                       accept: representsTarget) {
                    ScreenSnapshotStore.shared.invalidate()
                    trace.append("a11yAncestor:activated(\(type(of: cur)))")
                    return TapOutcome(success: true, via: "accessibilityElement(ancestor)", error: nil,
                                      activatedIdentifier: InspectedView.objectAccessibilityIdentifier(el),
                                      activatedLabel: el.accessibilityLabel,
                                      trace: trace.joined(separator: " "))
                }
                a = cur.superview
            }
            trace.append("a11yAncestor:no")
        } else {
            trace.append("a11yAncestor:noIdentity")
        }

        // 2c. Point-targeted accessibility activation. A SwiftUI leaf is often
        //     anonymous scaffolding — `_UIInheritedView`, no id, no text, not a
        //     control — so there is nothing to match on and every path below is
        //     UIKit-shaped. But accessibility elements carry SCREEN-space
        //     frames, so the thing the user pointed AT is answerable even when
        //     the view tree names nothing: take the tightest element containing
        //     the point and activate it. Tried tightest-first because a row and
        //     the label inside it both contain the point and only one of them
        //     may be activatable.
        let screenPoint = Self.screenPoint(for: view, windowPoint: windowPoint)
        let hostRoot: UIView = Self.hostingAncestor(of: view) ?? view
        let byPoint = Self.accessibilityElements(in: hostRoot, containing: screenPoint)
        for el in byPoint.prefix(4) where el.accessibilityActivate() {
            ScreenSnapshotStore.shared.invalidate()
            let name = el.accessibilityLabel ?? String(describing: type(of: el))
            let others = byPoint.prefix(6).dropFirst()
                .map { $0.accessibilityLabel ?? String(describing: type(of: $0)) }
                .joined(separator: "|")
            trace.append("a11yPoint:activated(\(name)) over{\(others)}")
            return TapOutcome(success: true, via: "accessibilityElement(point)", error: nil,
                              activatedIdentifier: InspectedView.objectAccessibilityIdentifier(el),
                              activatedLabel: el.accessibilityLabel,
                              trace: trace.joined(separator: " "))
        }
        // 2c-band. Same row, beside the point. An accessibility frame hugs its
        //     CONTENT, but a row is full width: a leading-aligned button in a
        //     440pt list row publishes a 93pt frame at x=40, so pointing at the
        //     middle of the row lands 87pt to its right and contains-the-point
        //     finds nothing. That is not an exotic layout, it is the commonest
        //     one on the platform, and it was scoring three archetypes as
        //     unreachable when the element was sitting right there.
        //
        //     The band is what makes this safe rather than a guess: require the
        //     element to CONTAIN the point vertically, which in a list is
        //     precisely the set of elements in the row the user pointed at, then
        //     take the horizontally nearest. Never reaches into another row, and
        //     an element genuinely elsewhere on screen is excluded by the y-test
        //     rather than by a distance heuristic.
        //     Reaching here already means the contains-the-point loop above
        //     activated nothing — do NOT re-test it, `accessibilityActivate()`
        //     performs the action rather than reporting whether it could.
        do {
            let band = Self.accessibilityElements(in: hostRoot, containing: nil)
                .filter { el in
                    let f = el.accessibilityFrame
                    guard f.width > 0, f.height > 0 else { return false }
                    guard f.minY - 4 <= screenPoint.y, screenPoint.y <= f.maxY + 4 else { return false }
                    return abs(f.midX - screenPoint.x) <= max(hostRoot.bounds.width, 320) * 0.75
                }
                .sorted { abs($0.accessibilityFrame.midX - screenPoint.x) < abs($1.accessibilityFrame.midX - screenPoint.x) }
            for el in band.prefix(3) where el.accessibilityActivate() {
                ScreenSnapshotStore.shared.invalidate()
                let name = el.accessibilityLabel ?? String(describing: type(of: el))
                let dx = Int(abs(el.accessibilityFrame.midX - screenPoint.x))
                trace.append("a11yBand:activated(\(name) dx=\(dx))")
                return TapOutcome(success: true, via: "accessibilityElement(row)", error: nil,
                                  activatedIdentifier: InspectedView.objectAccessibilityIdentifier(el),
                                  activatedLabel: el.accessibilityLabel,
                                  trace: trace.joined(separator: " "))
            }
            if !band.isEmpty {
                let names = band.prefix(4)
                    .map { $0.accessibilityLabel ?? String(describing: type(of: $0)) }
                    .joined(separator: "|")
                trace.append("a11yBand:noneActivated(\(band.count)){\(names)}")
            }
        }

        // Name the losers too. "It tapped the wrong thing" is only debuggable
        // if you can see what else was under the point and in what order.
        let candidateNames = byPoint.prefix(6)
            .map { $0.accessibilityLabel ?? String(describing: type(of: $0)) }
            .joined(separator: "|")
        if byPoint.isEmpty {
            // "noElement" alone is not a diagnosis — it cannot distinguish "the
            // point is wrong" from "the frames are wrong" from "there is
            // nothing here", and each of those has a different fix. Report the
            // numbers: where we looked, what the target occupies, and what was
            // available with its frame. Deduced twice from the bare token and
            // got it wrong twice; the arithmetic is cheaper than a round trip.
            let all = Self.accessibilityElements(in: hostRoot, containing: nil)
            let viewScreen = UIAccessibility.convertToScreenCoordinates(view.bounds, in: view)
            let seen = all.prefix(4).map { el -> String in
                let f = el.accessibilityFrame
                let name = el.accessibilityLabel ?? String(describing: type(of: el))
                return "\(name)@\(Self.short(f))"
            }.joined(separator: "|")
            trace.append("a11yPoint:noElement(pt=\(Self.short(CGRect(origin: screenPoint, size: .zero)))"
                + " target=\(type(of: view))@\(Self.short(viewScreen)) host=\(type(of: hostRoot))"
                + " seen=\(all.count){\(seen)})")
        } else {
            trace.append("a11yPoint:noneActivated(\(byPoint.count)){\(candidateNames)}")
        }

        // 2c-bis. Tapping a text input MEANS focusing it. Nothing above can do
        //     that: a text view is not a control, `accessibilityActivate()` on
        //     one returns false, and it has no tap recognizer of its own — so a
        //     notes field or search box was "not tappable by any path" despite
        //     being the most obviously tappable thing on screen. The semantic a
        //     real finger produces is first-responder, so produce that.
        if let field = Self.textInput(in: hostRoot, containing: screenPoint), field.becomeFirstResponder() {
            ScreenSnapshotStore.shared.invalidate()
            trace.append("focus:activated(\(type(of: field)))")
            return TapOutcome(success: true, via: "focus", error: nil,
                              activatedIdentifier: field.accessibilityIdentifier,
                              activatedLabel: field.accessibilityLabel,
                              trace: trace.joined(separator: " "))
        }
        trace.append("focus:no")

        // 2d. The island publishes exactly ONE element. Then there is nothing to
        //     disambiguate and no point to need: that element IS the control.
        //     This is the same "only one element in here" rule path 2 applies to
        //     the target's own subtree, applied at the SwiftUI boundary — which
        //     is where a stamped leaf's element actually lives. It is why
        //     `tap_element id=addShift.jobField` worked (it resolved the ISLAND,
        //     so path 2 saw the lone element) while recording the same control
        //     failed: recording targets the STAMP, whose own subtree is empty,
        //     and the strict climb above refuses a lone unnamed element.
        //     Deliberately last: a menu with rows has many elements, so this
        //     cannot fire there and steal from the point path.
        //
        //     LOCALITY IS REQUIRED. "The only element in the island" was safe
        //     only by accident: in a List every row is its own hosting island,
        //     so the lone element was always the row pointed at. On a screen
        //     that is ONE island — the common SwiftUI shape — the island
        //     publishes one element and this rule pressed it from anywhere.
        //     Eight archetypes at y=439 through y=639 all fired the same button
        //     at y=651. A rule with no reference to the point cannot be part of
        //     a point-resolution ladder; being last does not make it safe, only
        //     late. So the lone element must still be level with where the user
        //     actually pointed.
        let islandY = windowPoint.map { Self.screenPoint(for: view, windowPoint: $0).y }
        if hostRoot !== view,
           let el = TapElementTool.activateAccessibilityElement(
               in: hostRoot, id: matchId, text: matchText,
               accept: { candidate in
                   guard let islandY else { return true }
                   let f = candidate.accessibilityFrame
                   guard f.height > 0 else { return true }
                   return f.minY - 8 <= islandY && islandY <= f.maxY + 8
               }) {
            ScreenSnapshotStore.shared.invalidate()
            trace.append("a11yIsland:activated(\(el.accessibilityLabel ?? "unnamed"))")
            return TapOutcome(success: true, via: "accessibilityElement(island)", error: nil,
                              activatedIdentifier: InspectedView.objectAccessibilityIdentifier(el),
                              activatedLabel: el.accessibilityLabel,
                              trace: trace.joined(separator: " "))
        }
        trace.append("a11yIsland:no")

        var v: UIView? = view
        while let cur = v {
            if cur.responds(to: #selector(UIResponder.accessibilityActivate)), cur.accessibilityActivate() {
                ScreenSnapshotStore.shared.invalidate()
                trace.append("chain:activated")
                return TapOutcome(success: true, via: "accessibilityActivate", error: nil, trace: trace.joined(separator: " "))
            }
            v = cur.superview
        }
        trace.append("chain:no")

        // 3-bis. The VIEW band — a real control beside the point.
        //
        // The a11y band (2c-band) only sees accessibility elements, and two very
        // ordinary archetypes are invisible to it: a UIButton inside a SwiftUI
        // List row published NO accessibility element at all (`seen=0`), and a
        // UISwitch published one whose `accessibilityActivate()` declined. Both
        // are perfectly real UIControls sitting in the view tree with actions
        // wired — the ladder simply had no rung that reached a control BESIDE
        // the point rather than under it, so both fell through to selecting the
        // list row and reported success for a control that never moved.
        //
        // Same band rule as 2c-band, applied to views: vertically contain the
        // point (which in a list means the row pointed at), then nearest
        // horizontally. And actuate each control the way the PLATFORM does —
        // a switch toggles and sends .valueChanged, a button sends
        // .touchUpInside — because that is what the app's handler is waiting
        // for. Only where something is genuinely wired: an unwired control
        // reporting success is the false-success bug this ladder already
        // learned once (0.7.47, HostingUIButton).
        if let windowPoint {
            var candidates: [(UIView, CGFloat)] = []
            var stack: [UIView] = [view]
            while let cur = stack.popLast() {
                stack.append(contentsOf: cur.subviews)
                guard !cur.isHidden, cur.alpha > 0.01, cur.isUserInteractionEnabled else { continue }
                guard Self.isBandActuatable(cur) else { continue }
                let f = cur.convert(cur.bounds, to: nil)
                guard f.width > 0, f.height > 0 else { continue }
                guard f.minY - 4 <= windowPoint.y, windowPoint.y <= f.maxY + 4 else { continue }
                // BESIDE the point, not merely somewhere in the same row. The
                // first cut allowed 0.75x the container width - 300pt on a
                // 400pt row - and pressed a UISwitch 148pt away while aiming at
                // a UIButton, in the same cell. A leading-aligned control sits
                // within a few tens of points of where you pointed; anything
                // further is a different control, and actuating it is worse
                // than refusing. Allow the gap between the point and the
                // candidate's NEAREST EDGE, which is zero for anything the
                // point is level with and grows only as you leave it.
                let gap = max(0, max(f.minX - windowPoint.x, windowPoint.x - f.maxX))
                candidates.append((cur, gap))
            }
            candidates.sort { $0.1 < $1.1 }
            // AMBIGUITY is the danger, not distance. A distance cap gets this
            // wrong both ways: 300pt pressed a UISwitch 148pt away in the wrong
            // row, and 96pt then refused a leading-aligned switch 119pt from the
            // centre of its OWN row — the very case the band exists for. Neither
            // number is discoverable, because "how far is too far" depends
            // entirely on the layout.
            //
            // What actually distinguishes them: when the point is level with one
            // control, that control is what was meant however wide the row is.
            // When it is level with several, no distance argument can say which,
            // and pressing the nearest is a guess that has already been wrong.
            // So: reach anything the point is level with, and refuse when the
            // band is ambiguous unless one candidate is clearly nearest.
            let nearest = candidates.first?.1 ?? 0
            let contested = candidates.dropFirst().contains { $0.1 < nearest + 44 }
            if contested, nearest > 8 {
                let names = candidates.prefix(3)
                    .map { "\(type(of: $0.0))@\(Int($0.1))" }.joined(separator: "|")
                trace.append("viewBand:ambiguous(\(candidates.count)){\(names)}")
                candidates = []
            }
            for (candidate, dx) in candidates.prefix(3) {
                guard Self.actuateControl(candidate) else { continue }
                ScreenSnapshotStore.shared.invalidate()
                trace.append("viewBand:fired(\(type(of: candidate)) dx=\(Int(dx)))")
                return TapOutcome(success: true, via: "control(row)", error: nil,
                                  activatedIdentifier: ScreenElementFinder.identifier(of: candidate),
                                  activatedLabel: candidate.accessibilityLabel
                                      ?? InspectedView.textContent(of: candidate),
                                  trace: trace.joined(separator: " "))
            }
            let declined = candidates.prefix(3)
                .map { "\(type(of: $0.0))@\(Int($0.1))" }
                .joined(separator: "|")
            trace.append(candidates.isEmpty ? "viewBand:none"
                : "viewBand:noneFired(\(candidates.count)){\(declined)}")
        }

        var g: UIView? = view
        var gestureStoppedAtBoundary = false
        var isTargetItself = true
        while let cur = g {
            // The boundary rule exists to stop the CLIMB reaching a table's
            // selection machinery or a window-level keyboard-dismiss gesture. It
            // must not fire on the element itself: a UITextView IS a UIScrollView,
            // so targeting one broke out before ever looking at its own
            // recognizers — including the tap recognizer UIKit installs to place
            // the caret, which is precisely the gesture a real tap uses.
            let scrollBoundaryApplies = !isTargetItself
            isTargetItself = false
            // STOP at container boundaries — not merely "don't fire on them":
            // scrolling up PAST a UITableView/UICollectionView reaches
            // recognizers that are never element semantics — the table's own
            // selection machinery (stale-location row selection) and, above
            // it, global gestures like a keyboard-dismiss recognizer on the
            // root/window view, which fires `resignFirstResponder` and claims
            // a hollow success (exactly the observed
            // "gesture:fired(afterContainerSkip)" no-op that kept path 5 from
            // ever running). Recognizers on the element or its ancestors
            // BELOW the boundary still fire normally.
            if (scrollBoundaryApplies && cur is UIScrollView) || cur is UIWindow {
                gestureStoppedAtBoundary = true
                break
            }
            for gr in cur.gestureRecognizers ?? [] where gr.isEnabled {
                guard let tap = gr as? UITapGestureRecognizer else { continue }
                if TapElementTool.fireTapTargets(of: tap) {
                    ScreenSnapshotStore.shared.invalidate()
                    trace.append("gesture:fired")
                    return TapOutcome(success: true, via: "tapGesture", error: nil, trace: trace.joined(separator: " "))
                }
            }
            g = cur.superview
        }
        trace.append(gestureStoppedAtBoundary ? "gesture:stoppedAtBoundary" : "gesture:no")

        // 5. Container selection — a plain view inside a UITableViewCell /
        //    UICollectionViewCell whose tap means "select this row". There is
        //    no per-cell gesture recognizer to fire: selection lives in the
        //    container's delegate call, which is the semantic a real tap
        //    drives. Public API only; the broadest fallback, so it runs last
        //    (a button inside the cell or an explicit gesture on a subview
        //    must win first). The via string names the row selected, so a
        //    wrong-target selection is visible in the fire pill / logs.
        if let detail = Self.selectContainerRow(of: view) {
            ScreenSnapshotStore.shared.invalidate()
            trace.append("row:\(detail)")
            return TapOutcome(success: true, via: detail, error: nil, trace: trace.joined(separator: " "))
        }
        trace.append("row:noCell")
        // The trace IS the diagnosis — "not tappable by any path" on its own
        // sends whoever reads it back to the device to find out which path and
        // why. Carry it in the message so one report is enough.
        let joined = trace.joined(separator: " ")
        return TapOutcome(success: false, via: nil,
                          error: "Element found but not tappable by any path (not a control, no activatable accessibility element, no tap gesture, not inside a selectable cell). Trace: \(joined)",
                          trace: joined)
    }

    /// Where the tap lands, in SCREEN coordinates — the space accessibility
    /// frames live in. `windowPoint` is in the view's window; with none, the
    /// view's own centre stands in.
    /// Eligible for the view band: a control the platform can actuate, or a view
    /// carrying its own tap recognizer. Scroll views are excluded for the same
    /// reason the gesture climb stops at them — their recognizers are scroll and
    /// selection machinery, not this element's semantics.
    static func isBandActuatable(_ v: UIView) -> Bool {
        if v is UIScrollView { return false }
        if v is UIControl { return true }
        return v.gestureRecognizers?.contains { $0.isEnabled && $0 is UITapGestureRecognizer } == true
    }

    /// Actuate a control the way the PLATFORM does, and report honestly whether
    /// anything was wired to receive it. `sendActions` on a control with no
    /// targets is a silent no-op — reporting that as success is the bug this
    /// ladder already learned once with SwiftUI's HostingUIButton.
    static func actuateControl(_ v: UIView) -> Bool {
        // `allControlEvents` is the right wiring test, and the only one that
        // sees a BLOCK handler. The first cut asked
        // `actions(forTarget:forControlEvent:)`, which reports target/action
        // pairs only — so a control wired with `addAction(UIAction { … })`, the
        // modern idiom and most current UIKit code, looked unwired and was
        // refused. A guard against false success turned into a false refusal.
        // This still excludes SwiftUI's HostingUIButton, which registers no
        // control events at all because it handles the press internally, so the
        // protection that guard existed for is intact.
        if let sw = v as? UISwitch {
            guard sw.allControlEvents.contains(.valueChanged) else { return false }
            sw.setOn(!sw.isOn, animated: true)
            sw.sendActions(for: .valueChanged)
            return true
        }
        if let control = v as? UIControl {
            for event in [UIControl.Event.touchUpInside, .primaryActionTriggered, .valueChanged]
            where control.allControlEvents.contains(event) {
                control.sendActions(for: event)
                return true
            }
            return false
        }
        for gr in v.gestureRecognizers ?? [] where gr.isEnabled {
            guard let tap = gr as? UITapGestureRecognizer else { continue }
            if TapElementTool.fireTapTargets(of: tap) { return true }
        }
        return false
    }

    private static func screenPoint(for view: UIView, windowPoint: CGPoint?) -> CGPoint {
        // A window point converts through a WINDOW, never through the target
        // view. The view can be DETACHED by the time it is actuated — macro
        // recording captures the element on a double-tap and acts on it after
        // the action chooser, and SwiftUI recycles its scaffolding views on any
        // re-render in between. Both `convert(_:from: nil)` and
        // `convertToScreenCoordinates(_:in:)` silently no-op on a window-less
        // view, so the result stayed in the view's LOCAL space and was compared
        // against SCREEN-space accessibility frames: nothing ever matched, and
        // the failure looked like "there is nothing under the point".
        if let wp = windowPoint, let anchor = view.window ?? ScreenElementFinder.hostWindow() {
            return UIAccessibility.convertToScreenCoordinates(CGRect(origin: wp, size: .zero), in: anchor).origin
        }
        // No point given: the view's own centre, which needs the view itself.
        let centre = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        return UIAccessibility.convertToScreenCoordinates(CGRect(origin: centre, size: .zero), in: view).origin
    }

    /// The SwiftUI hosting view enclosing `view` — the boundary of one SwiftUI
    /// island. Everything under it is SwiftUI's own scaffolding, and the
    /// accessibility elements for the whole island hang off the hosting view,
    /// not off the leaves. Matched by class name because the type is private to
    /// SwiftUI. Bounded so a deep UIKit hierarchy can't walk to the window.
    private static func hostingAncestor(of view: UIView) -> UIView? {
        var cur: UIView? = view
        var hops = 0
        while let v = cur, hops < 12 {
            if String(describing: type(of: v)).contains("HostingView") { return v }
            cur = v.superview
            hops += 1
        }
        return nil
    }

    /// The tightest focusable text input under `screenPoint` within `root`.
    /// Views, not accessibility elements: a text view IS the thing that takes
    /// focus, and SwiftUI's `TextField`/`TextEditor` are backed by exactly
    /// these UIKit types.
    private static func textInput(in root: UIView, containing screenPoint: CGPoint) -> UIView? {
        var best: UIView?
        var bestArea = CGFloat.greatestFiniteMagnitude
        func walk(_ v: UIView, depth: Int) {
            if depth > 60 { return }
            for sub in v.subviews where !sub.isHidden && sub.alpha > 0.01 {
                let f = UIAccessibility.convertToScreenCoordinates(sub.bounds, in: sub)
                if f.contains(screenPoint), sub is UITextInput, sub.canBecomeFirstResponder {
                    let area = f.width * f.height
                    if area < bestArea { bestArea = area; best = sub }
                }
                walk(sub, depth: depth + 1)
            }
        }
        if root is UITextInput, root.canBecomeFirstResponder,
           UIAccessibility.convertToScreenCoordinates(root.bounds, in: root).contains(screenPoint) {
            best = root
            bestArea = root.bounds.width * root.bounds.height
        }
        walk(root, depth: 0)
        return best
    }

    /// Compact "x,y,w,h" for traces — full precision is noise in a one-line
    /// diagnostic that has to survive being pasted out of a UI.
    private static func short(_ r: CGRect) -> String {
        r.size == .zero ? "\(Int(r.origin.x)),\(Int(r.origin.y))"
                        : "\(Int(r.origin.x)),\(Int(r.origin.y)),\(Int(r.width)),\(Int(r.height))"
    }

    /// Every accessibility element under `root` whose screen frame contains
    /// `screenPoint`, tightest first. Tightest-first matters: a row and the
    /// label inside it both contain the point, and which one answers
    /// `accessibilityActivate()` is up to whoever built the tree.
    ///
    /// `nil` point means "everything under here", which is what the failure
    /// diagnostic reports so a miss can be told apart from an empty tree.
    private static func accessibilityElements(in root: NSObject, containing screenPoint: CGPoint?) -> [NSObject] {
        var hits: [(el: NSObject, area: CGFloat)] = []
        var seen = Set<ObjectIdentifier>()
        var visited = 0
        func visit(_ obj: NSObject, depth: Int) {
            if depth > 60 || visited > 400 { return }
            guard seen.insert(ObjectIdentifier(obj)).inserted else { return }
            visited += 1

            if obj.isAccessibilityElement {
                let f = obj.accessibilityFrame
                if screenPoint.map({ f.contains($0) }) ?? true { hits.append((obj, f.width * f.height)) }
            }

            var children: [NSObject] = []
            if let els = obj.accessibilityElements as? [NSObject] {
                children = els
            } else {
                let n = obj.accessibilityElementCount()
                if n > 0 && n != NSNotFound {
                    for i in 0..<n { if let e = obj.accessibilityElement(at: i) as? NSObject { children.append(e) } }
                }
            }
            for c in children { visit(c, depth: depth + 1) }

            // Subviews TOO, not "only if no published elements". A container's
            // `accessibilityElements` array is VoiceOver's reading order, not an
            // inventory of what is interactive — a hosting view that publishes
            // [Add attachment, Notes] can still contain a text editor, and
            // returning early on the published array made everything else
            // invisible to the point search. That reported `seen=2` and read as
            // "the app exposes nothing here" when the walk simply never looked.
            // Deduped by identity, since a published element is usually a view
            // in the subtree as well.
            if let v = obj as? UIView {
                for sub in v.subviews where !sub.isHidden && sub.alpha > 0.01 { visit(sub, depth: depth + 1) }
            }
        }
        visit(root, depth: 0)
        return hits.sorted { $0.area < $1.area }.map(\.el)
    }

    /// Walk up to the nearest table/collection cell, then to its owning
    /// container, and perform the selection the delegate would get from a
    /// real tap — `selectRow`/`selectItem` for visual fidelity, then the
    /// `didSelect` call itself (the semantic). Respects `allowsSelection`
    /// and `responds(to:)` so a non-selectable list is correctly not a tap.
    /// Returns a via string naming WHAT was selected (cell class +
    /// section:row), so a wrong-target selection is immediately visible.
    private static func selectContainerRow(of view: UIView) -> String? {
        var cell: UIView?
        var v: UIView? = view
        while let cur = v {
            if cur is UITableViewCell || cur is UICollectionViewCell { cell = cur; break }
            v = cur.superview
        }
        guard let cell else { return nil }

        var owner = cell.superview
        while let cur = owner {
            if let table = cur as? UITableView,
               let tableCell = cell as? UITableViewCell,
               table.allowsSelection,
               let indexPath = table.indexPath(for: tableCell),
               let delegate = table.delegate,
               delegate.responds(to: #selector(UITableViewDelegate.tableView(_:didSelectRowAt:))) {
                table.selectRow(at: indexPath, animated: true, scrollPosition: .none)
                delegate.tableView?(table, didSelectRowAt: indexPath)
                return "rowSelection \(String(describing: type(of: tableCell)))[\(indexPath.section):\(indexPath.row)]"
            }
            if let collection = cur as? UICollectionView,
               let collectionCell = cell as? UICollectionViewCell,
               collection.allowsSelection,
               let indexPath = collection.indexPath(for: collectionCell),
               let delegate = collection.delegate,
               delegate.responds(to: #selector(UICollectionViewDelegate.collectionView(_:didSelectItemAt:))) {
                collection.selectItem(at: indexPath, animated: true, scrollPosition: [])
                delegate.collectionView?(collection, didSelectItemAt: indexPath)
                return "itemSelection \(String(describing: type(of: collectionCell)))[\(indexPath.section):\(indexPath.item)]"
            }
            owner = cur.superview
        }
        return nil
    }

    /// Set a text field/view's content, firing the same change notification
    /// real typing would. `nil` return means no text-input view was found at
    /// or below `view`.
    /// Set the VALUE of a value-bearing control, rather than pretending to
    /// operate it.
    ///
    /// A date picker's wheels cannot be meaningfully driven through public API,
    /// and mechanically simulating a spin would be an elaborate way to produce
    /// what one property assignment produces exactly. `UIDatePicker.date` plus
    /// `.valueChanged` IS what a real spin delivers to the app — the same
    /// handler, the same value — so a macro should record the VALUE, which is
    /// also the thing worth re-reading later ("set the clock-in to 09:00"),
    /// where a gesture recording would be unreadable and brittle.
    ///
    /// Dates are simply the first instance: every UIKit control that carries a
    /// value has this shape, and none of them were reachable before.
    static func performSetValue(on view: UIView, value: String) -> TapOutcome {
        var trace: [String] = ["sdk=\(ripulSDKVersion)"]
        // At-or-below, then the enclosing SwiftUI island — the same reach the
        // tap and type paths needed, for the same reason: the target is often
        // scaffolding and the control is a sibling within the island.
        let scope: [UIView] = [view] + (Self.hostingAncestor(of: view).map { [$0] } ?? [])
        for root in scope {
            guard let control = Self.valueControl(in: root) else { continue }
            trace.append("found:\(type(of: control))")
            if let outcome = Self.apply(value, to: control, trace: &trace) { return outcome }
        }
        trace.append("setValue:noControl")
        return TapOutcome(success: false, via: nil,
                          error: "No value-bearing control at or below this element (date picker, switch, "
                               + "slider, stepper, segmented control, picker or text field). Trace: "
                               + trace.joined(separator: " "),
                          trace: trace.joined(separator: " "))
    }

    /// Whether a value-bearing control exists at, below, or in the same
    /// SwiftUI island as `view` — so the recording chooser can offer "Set
    /// value" only where it means something, rather than listing an action
    /// that will refuse.
    static func hasValueControl(at view: UIView) -> Bool {
        if valueControl(in: view) != nil { return true }
        if let island = hostingAncestor(of: view) { return valueControl(in: island) != nil }
        return false
    }

    /// The first control in `root`'s subtree that carries a value.
    private static func valueControl(in root: UIView) -> UIView? {
        if Self.isValueBearing(root) { return root }
        for sub in root.subviews where !sub.isHidden && sub.alpha > 0.01 {
            if let found = valueControl(in: sub) { return found }
        }
        return nil
    }

    private static func isValueBearing(_ v: UIView) -> Bool {
        v is UIDatePicker || v is UISwitch || v is UISlider || v is UIStepper
            || v is UISegmentedControl || v is UIPickerView || v is UITextField || v is UITextView
    }

    /// Apply `value` to a control, then fire `.valueChanged` — the notification
    /// a real interaction produces, and the thing the app's handler listens to.
    /// Setting the property alone would change the display and tell nobody.
    private static func apply(_ value: String, to control: UIView, trace: inout [String]) -> TapOutcome? {
        func done(_ via: String, _ shown: String) -> TapOutcome {
            (control as? UIControl)?.sendActions(for: .valueChanged)
            ScreenSnapshotStore.shared.invalidate()
            trace.append("setValue:\(via)")
            return TapOutcome(success: true, via: "setValue(\(via))", error: nil,
                              activatedIdentifier: control.accessibilityIdentifier,
                              activatedLabel: shown, trace: trace.joined(separator: " "))
        }

        switch control {
        case let picker as UIDatePicker:
            guard let date = Self.parseDate(value, mode: picker.datePickerMode) else {
                trace.append("setValue:unparsableDate")
                return TapOutcome(success: false, via: nil,
                                  error: "Could not read \"\(value)\" as a date/time. Accepts ISO8601 "
                                       + "(2026-08-02T09:00), \"yyyy-MM-dd HH:mm\", \"yyyy-MM-dd\" or \"HH:mm\".",
                                  trace: trace.joined(separator: " "))
            }
            picker.setDate(date, animated: true)
            return done("date", ISO8601DateFormatter().string(from: date))

        case let s as UISwitch:
            let on = ["1", "true", "on", "yes"].contains(value.lowercased())
            s.setOn(on, animated: true)
            return done("switch", on ? "on" : "off")

        case let slider as UISlider:
            guard let n = Float(value) else { return nil }
            slider.setValue(n, animated: true)
            return done("slider", value)

        case let stepper as UIStepper:
            guard let n = Double(value) else { return nil }
            stepper.value = n
            return done("stepper", value)

        case let seg as UISegmentedControl:
            if let i = Int(value), i >= 0, i < seg.numberOfSegments {
                seg.selectedSegmentIndex = i
                return done("segment", "index \(i)")
            }
            for i in 0..<seg.numberOfSegments where seg.titleForSegment(at: i)?
                .caseInsensitiveCompare(value) == .orderedSame {
                seg.selectedSegmentIndex = i
                return done("segment", seg.titleForSegment(at: i) ?? value)
            }
            trace.append("setValue:noSuchSegment")
            return nil

        case let picker as UIPickerView:
            // Row index only: titles live in the delegate and reading them back
            // is not reliably available.
            guard let row = Int(value), picker.numberOfComponents > 0,
                  row >= 0, row < picker.numberOfRows(inComponent: 0) else {
                trace.append("setValue:badRow")
                return nil
            }
            picker.selectRow(row, inComponent: 0, animated: true)
            picker.delegate?.pickerView?(picker, didSelectRow: row, inComponent: 0)
            ScreenSnapshotStore.shared.invalidate()
            trace.append("setValue:pickerRow")
            return TapOutcome(success: true, via: "setValue(pickerRow)", error: nil,
                              activatedIdentifier: picker.accessibilityIdentifier,
                              activatedLabel: "row \(row)", trace: trace.joined(separator: " "))

        case is UITextField, is UITextView:
            let (ok, err) = Self.performType(on: control, text: value, append: false)
            trace.append(ok ? "setValue:text" : "setValue:textFailed")
            return TapOutcome(success: ok, via: ok ? "setValue(text)" : nil, error: err,
                              activatedIdentifier: control.accessibilityIdentifier,
                              activatedLabel: value, trace: trace.joined(separator: " "))

        default:
            return nil
        }
    }

    /// Lenient on format, because a macro author writes what they mean rather
    /// than what a formatter wants.
    private static func parseDate(_ raw: String, mode: UIDatePicker.Mode) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: raw) { return d }
        iso.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        if let d = iso.date(from: raw) { return d }
        let patterns = ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd", "HH:mm", "HH:mm:ss"]
        for p in patterns {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = p
            guard let parsed = f.date(from: raw) else { continue }
            // A bare time means "today at that time" — a time picker set to
            // 1970 would be technically correct and useless.
            if p.hasPrefix("HH") {
                let cal = Calendar.current
                let t = cal.dateComponents([.hour, .minute, .second], from: parsed)
                return cal.date(bySettingHour: t.hour ?? 0, minute: t.minute ?? 0,
                                second: t.second ?? 0, of: Date())
            }
            return parsed
        }
        return nil
    }

    static func performType(on view: UIView, text: String, append: Bool) -> (success: Bool, error: String?) {
        // At-or-below first, then the enclosing SwiftUI island. A target inside
        // an island is routinely scaffolding with nothing beneath it — a stamp,
        // an `_UIInheritedView` — while the real field is a sibling branch
        // within the same hosting view. The tap ladder already reaches it that
        // way (the focus path); typing refused instead, which made "type into
        // this field" fail on a field the explorer had selected correctly.
        let input = TypeTextTool.textInput(in: view)
            ?? Self.hostingAncestor(of: view).flatMap { TypeTextTool.textInput(in: $0) }
        guard let input else {
            return (false, "Element found but no text input at or below it, nor anywhere in its SwiftUI island. Match the field itself (role=\"field\", or its accessibility id).")
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
        // `activated` + `trace` are the answer to "it tapped, but the app did
        // the wrong thing": the matched VIEW is often a whole SwiftUI island,
        // and which element inside it was pressed is the part that decides
        // what happens. Reporting only `via` made a wrong-target activation
        // indistinguishable from a correct one.
        if outcome.success {
            var result: [String: Any] = ["success": true, "via": outcome.via as Any, "matched": matchCount,
                                         "element": ScreenElementFinder.describe(target),
                                         "trace": outcome.trace]
            if let a = outcome.activatedLabel { result["activated"] = a }
            if let a = outcome.activatedIdentifier { result["activatedId"] = a }
            return result
        }
        return ["success": false, "matched": matchCount, "element": ScreenElementFinder.describe(target),
                "trace": outcome.trace, "error": outcome.error as Any]
    }

    /// Walk the accessibility tree under `view` (elements array / container
    /// protocol / subviews — same traversal as the inspector) and activate the
    /// element matching the requested id or text. Only presses something it can
    /// NAME: the matched element, or the single element the view exposes —
    /// never "the first of many".
    /// `strict`: require a real id/text match. The default allows a lone
    /// accessibility element in the subtree to stand in for the match, which is
    /// right when the caller already resolved THIS view as the element — and
    /// wrong when climbing ancestors, where the one element found may belong to
    /// something else entirely.
    ///
    /// Returns the element it activated (nil when nothing did), not just a
    /// Bool: for an anonymous SwiftUI leaf the activated element is the only
    /// thing carrying a NAME, and the macro recorder needs that name to write
    /// down a selector that can be resolved again later.
    @discardableResult
    /// `accept`: an extra veto on a matched element — used by the ancestor
    /// climb to refuse an element that is far larger than what was aimed at.
    static func activateAccessibilityElement(in view: UIView, id: String?, text: String?,
                                             strict: Bool = false,
                                             accept: ((NSObject) -> Bool)? = nil) -> NSObject? {
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
        let candidates = matched.isEmpty && !strict && all.count == 1 ? all : matched
        guard let el = candidates.first(where: { accept?($0) ?? true }) else { return nil }
        return el.accessibilityActivate() ? el : nil
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
