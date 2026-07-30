import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - MacroElementResolving — the seam that makes replay testable
//
// `ScreenElementFinder.find`/`resolveAnchor` are `@MainActor` and walk a live
// `UIView` tree — inherently unreachable from `swift test` on macOS, where
// `#if canImport(UIKit)` compiles this whole file's UIKit-backed conformance
// out, AND `UIView`/`UIScrollView` don't exist as TYPES at all (not just "no
// live tree to walk"). So the resolver protocol can't mention them directly —
// doing so would make the protocol itself, and any fake conforming to it,
// unusable outside UIKit platforms. Instead: BOTH resolution AND actuation are
// behind the protocol via an associated `ResolvedElement` type, opaque to
// `MacroReplayEngine`. The live conformance (`LiveScreenResolver`) sets
// `ResolvedElement = UIView`; a test fake can set it to any placeholder type
// at all (an enum case, a plain struct) with no UIKit dependency whatsoever.
// This is what lets `MacroReplayEngine` itself be pure Foundation code,
// unconditionally compiled, and its control flow (sequencing, parameter
// substitution, stop-on-first-failure) pinned by `swift test` with a fake.

// MARK: - MacroResolution — why a lookup failed, not just that it did

/// The result of one selector resolution. `.notFound` and `.ambiguous` are
/// deliberately distinct: "nothing matches" and "five things match" need
/// completely different fixes (a wait / a `within` anchor or `nth`), and
/// collapsing them into the same `nil` made the first real replay bug
/// unreadable.
public enum MacroResolution<Element> {
    case resolved(Element)
    case notFound
    case ambiguous(count: Int)

    /// Convenience for the `.wait` step's found/not-found check.
    public var element: Element? {
        if case .resolved(let e) = self { return e }
        return nil
    }
}

@MainActor
public protocol MacroElementResolving {
    associatedtype ResolvedElement

    /// Resolve a selector to the element a tap/type step should act on.
    /// One-shot (no polling) — `MacroReplayEngine` owns the bounded-poll loop.
    /// Returns a `MacroResolution` (not an Optional) specifically so the
    /// replay error can distinguish "matched nothing" from "matched N,
    /// ambiguous" — identical failures were the first user-visible bug this
    /// system hit (a tab-bar tap matched all 5 tab buttons and read as
    /// "could not resolve", identical to a genuinely missing element).
    func resolveTap(_ selector: MacroSelector) -> MacroResolution<ResolvedElement>
    /// Resolve a selector to the scroll container a scroll step should act on.
    func resolveScrollView(_ selector: MacroSelector) -> MacroResolution<ResolvedElement>

    /// Actuate a resolved element — mirrors `ScreenActuationEngine`'s three
    /// operations exactly; the live conformance just forwards to it.
    func performTap(_ element: ResolvedElement, matchId: String?, matchText: String?) -> (success: Bool, error: String?)
    /// Via-aware tap outcome — declared as a REQUIREMENT (not just an
    /// extension convenience) specifically so it dispatches through the
    /// witness table at generic call sites. A method defined only in a
    /// protocol extension statically dispatches to the default at
    /// `R: MacroElementResolving` call sites — conformances never see it
    /// called. (Caught by MacroReplayEngineTests: the fake's `via` never
    /// surfaced until this became a requirement.)
    func performTapDetailed(_ element: ResolvedElement, matchId: String?, matchText: String?) -> (success: Bool, via: String?, error: String?)
    func performType(_ element: ResolvedElement, text: String, append: Bool) -> (success: Bool, error: String?)
    func performScroll(_ element: ResolvedElement, direction: String, amount: Double) -> Bool

    /// A compact one-line identity for a resolved element — class, role,
    /// id, text, window-space frame — recorded into each step's result so a
    /// replay log says WHAT the selector actually matched, not just that it
    /// matched. A requirement (not extension-only) for the same dispatch
    /// reason as `performTapDetailed`.
    func describe(_ element: ResolvedElement) -> String?
}

@MainActor
public extension MacroElementResolving {
    /// Via-aware tap outcome — reports WHICH actuation path fired
    /// (`uicontrol` / `accessibilityElement` / `tapGesture` / …), so a replay
    /// sheet can show "pressed, but only via the weakest path" instead of a
    /// bare success. Default maps the original `performTap` (via unknown);
    /// the live conformance overrides with the real value.
    func performTapDetailed(_ element: ResolvedElement, matchId: String?, matchText: String?) -> (success: Bool, via: String?, error: String?) {
        let (success, error) = performTap(element, matchId: matchId, matchText: matchText)
        return (success, nil, error)
    }
}

#if canImport(UIKit)
/// The real resolver: walks the live host screen via `ScreenElementFinder` and
/// acts via `ScreenActuationEngine` — exactly what the live `tap_element`/
/// `type_text`/`scroll_element` tools do, so a macro replays through the
/// identical implementation a single live call would use.
@MainActor
public struct LiveScreenResolver: MacroElementResolving {
    public init() {}

    public func resolveTap(_ selector: MacroSelector) -> MacroResolution<UIView> {
        Self.resolveView(for: selector)
    }

    public func resolveScrollView(_ selector: MacroSelector) -> MacroResolution<UIView> {
        switch Self.resolveView(for: selector) {
        case .resolved(let view):
            if let scrollView = (view as? UIScrollView) ?? ScrollElementTool.enclosingScrollView(of: view) {
                return .resolved(scrollView)
            }
            return .notFound
        case .notFound: return .notFound
        case .ambiguous(let count): return .ambiguous(count: count)
        }
    }

    public func performTap(_ element: UIView, matchId: String?, matchText: String?) -> (success: Bool, error: String?) {
        let outcome = ScreenActuationEngine.performTap(on: element, matchId: matchId, matchText: matchText)
        return (outcome.success, outcome.error)
    }

    public func performTapDetailed(_ element: UIView, matchId: String?, matchText: String?) -> (success: Bool, via: String?, error: String?) {
        let outcome = ScreenActuationEngine.performTap(on: element, matchId: matchId, matchText: matchText)
        return (outcome.success, outcome.via, outcome.error)
    }

    public func performType(_ element: UIView, text: String, append: Bool) -> (success: Bool, error: String?) {
        ScreenActuationEngine.performType(on: element, text: text, append: append)
    }

    public func performScroll(_ element: UIView, direction: String, amount: Double) -> Bool {
        guard let scrollView = element as? UIScrollView else { return false }
        _ = ScreenActuationEngine.performScroll(on: scrollView, direction: direction, amount: amount)
        return true
    }

    public func describe(_ element: UIView) -> String? {
        var parts: [String] = [String(describing: type(of: element))]
        if let role = ScreenElementFinder.role(of: element) { parts.append("(\(role))") }
        if let id = ScreenElementFinder.identifier(of: element) { parts.append("[\(id)]") }
        if let text = InspectedView.textContent(of: element), !text.isEmpty { parts.append("\"\(text)\"") }
        if let window = element.window {
            let f = element.convert(element.bounds, to: window)
            parts.append(String(format: "@(%.0f,%.0f %.0f×%.0f)", f.minX, f.minY, f.width, f.height))
        }
        return parts.joined(separator: " ")
    }

    /// Resolves `selector.within` (one level — see `MacroAnchorSelector`) to
    /// an anchor view first, then searches `selector`'s own predicates scoped
    /// to that anchor. Ambiguous results (no `nth` and more than one disjoint
    /// match, at either the anchor or the main query) are reported as
    /// `.ambiguous` — replay has no interactive way to disambiguate, so it
    /// must fail rather than guess, and the COUNT is what the error message
    /// needs to say so.
    private static func resolveView(for selector: MacroSelector) -> MacroResolution<UIView> {
        var anchor: UIView?
        if let anchorSelector = selector.within {
            guard anchorSelector.hasAnyPredicate else { return .notFound }
            let anchorQuery = ScreenElementFinder.Query(id: anchorSelector.id, text: anchorSelector.text,
                                                        role: anchorSelector.role, className: anchorSelector.className,
                                                        nth: anchorSelector.nth)
            let anchorMatches = ScreenElementFinder.find(anchorQuery)
            if anchorMatches.isEmpty { return .notFound }
            let anchorNth = anchorSelector.nth ?? (anchorMatches.count == 1 ? 0 : -1)
            guard anchorNth >= 0, anchorNth < anchorMatches.count else { return .ambiguous(count: anchorMatches.count) }
            anchor = anchorMatches[anchorNth].view
        }
        guard selector.hasAnyPredicate else {
            return anchor.map { .resolved($0) } ?? .notFound
        }

        let query = ScreenElementFinder.Query(id: selector.id, text: selector.text,
                                              role: selector.role, className: selector.className,
                                              nth: selector.nth)
        let matches = ScreenElementFinder.find(query, within: anchor)
        if matches.isEmpty { return .notFound }
        let nth = selector.nth ?? (matches.count == 1 ? 0 : -1)
        guard nth >= 0, nth < matches.count else { return .ambiguous(count: matches.count) }
        return .resolved(matches[nth].view)
    }
}
#endif
