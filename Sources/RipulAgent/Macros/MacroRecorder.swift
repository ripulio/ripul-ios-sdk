import Foundation
#if canImport(UIKit)
import UIKit

// MARK: - Selector synthesis (live view → durable MacroSelector)

public extension MacroSelector {
    /// Synthesize a durable selector for a live view, using the SAME identity
    /// ladder the actuation tools already compute, plus two fallbacks learned
    /// from the first real replay failure (a UITabBar tap matched all five
    /// tab buttons — same class, same role, nothing else):
    ///
    /// 1. id alone when present (tightest, most stable), else
    /// 2. role + visible text (textContent), else
    /// 3. role + `accessibilityLabel` — where tab-bar items, icon-only SF
    ///    Symbol buttons, and SwiftUI combined elements keep their name
    ///    (`textContent` only reads UILabel/text-field/view/Button-title),
    /// else
    /// 4. role + class + `nth` — computed against the LIVE tree right now:
    ///    when the selector would still match several disjoint elements, the
    ///    tapped element's own index among them is recorded, so "the third
    ///    tab button" replays as exactly that instead of failing ambiguous.
    ///
    /// This is what makes a recorded step replay correctly later: it's built
    /// from the same `ScreenElementFinder` facts `tap_element`'s own matching
    /// reads, not a one-off snapshot of the view.
    ///
    /// `public`: lets a UI-test-only hook (`RipulAppApp`'s
    /// `-RipulUITestRecordCaptureStep`) prove this exact synthesis round-trips
    /// (view → selector → `LiveScreenResolver` resolves it back to a working
    /// target) using only already-public phase-1 surface — no need to expose
    /// `MacroRecorder` itself just for testability.
    @MainActor
    init(describing view: UIView) {
        if let id = ScreenElementFinder.identifier(of: view), !id.isEmpty {
            self.init(id: id)
            return
        }

        let text = InspectedView.textContent(of: view)
        let label = view.accessibilityLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let role = ScreenElementFinder.role(of: view)
        let className = String(describing: type(of: view))
        // Text ladder: own text, then accessibilityLabel, then the label a
        // composite control CONTAINS (descendant UILabel — where a tab-bar
        // button or icon-button keeps its name). `contentText` covers the
        // first and third rungs; the middle one isn't part of it because
        // matching reads own-or-descendant, not the a11y label.
        let textPredicate: String? = (text?.isEmpty == false) ? text
            : (label?.isEmpty == false) ? label
            : ScreenElementFinder.contentText(of: view)

        var selector = MacroSelector(text: textPredicate, role: role, className: className)

        // Disambiguation: if this selector matches several disjoint elements
        // in the live tree (siblings sharing class+role, e.g. every tab
        // button in a tab bar), record the tapped element's own index — the
        // XPath positional predicate — so replay picks it deterministically
        // instead of failing ambiguous.
        let query = ScreenElementFinder.Query(id: nil, text: selector.text,
                                              role: selector.role, className: selector.className, nth: nil)
        let matches = ScreenElementFinder.find(query)
        if matches.count > 1, let index = matches.firstIndex(where: { $0.view === view }) {
            selector.nth = index
        }
        self = selector
    }
}

// MARK: - Recording — live-execute + append (the dogfooding step)

/// One action a developer can pick for the element under a double-tap while
/// recording. Declaration order is the order buttons appear in the chooser.
enum MacroRecordingAction: String, CaseIterable {
    case tap = "Tap"
    case type = "Type text"
    case scroll = "Scroll"
    case waitForGone = "Wait for this to disappear"
}

/// Live-executes a chosen action against the tapped view (the developer sees
/// their own app respond — if it doesn't work now, recording it wouldn't make
/// it work later either) through the SAME `ScreenActuationEngine` the live
/// `tap_element`/`type_text`/`scroll_element` tools and macro replay both use,
/// then returns the `MacroStep` to append. `nil` return means the action
/// couldn't be performed (e.g. Scroll on something with no enclosing scroll
/// view) — the caller shows an error instead of appending a step that would
/// never replay.
@MainActor
enum MacroRecorder {
    static func record(_ action: MacroRecordingAction, on view: UIView, typedText: String = "") -> (step: MacroStep, error: String?)? {
        let selector = MacroSelector(describing: view)
        let label = describeTarget(view, ordinal: ordinalSuffix(for: view, selector: selector))

        switch action {
        case .tap:
            let outcome = ScreenActuationEngine.performTap(on: view, matchId: selector.id, matchText: selector.text)
            let step = MacroStep(kind: .tap, selector: selector, recordedLabel: "Tap \(label)")
            return (step, outcome.success ? nil : outcome.error)

        case .type:
            let outcome = ScreenActuationEngine.performType(on: view, text: typedText, append: false)
            let step = MacroStep(kind: .type, selector: selector, text: typedText, append: false,
                                 recordedLabel: "Type into \(label)")
            return (step, outcome.success ? nil : outcome.error)

        case .scroll:
            guard let scrollView = (view as? UIScrollView) ?? ScrollElementTool.enclosingScrollView(of: view) else {
                return nil
            }
            _ = ScreenActuationEngine.performScroll(on: scrollView, direction: "down", amount: 0.8)
            let step = MacroStep(kind: .scroll, selector: selector, direction: "down", amount: 0.8,
                                 recordedLabel: "Scroll \(label)")
            return (step, nil)

        case .waitForGone:
            // Not live-executed — recording a wait is declarative (the element
            // is visible right now, by construction, since it was just tapped).
            let step = MacroStep(kind: .wait, selector: selector, state: "gone", timeout: 5,
                                 recordedLabel: "Wait for \(label) to disappear")
            return (step, nil)
        }
    }

    /// A short human label for the step list / dialog title — role-qualified
    /// text when available (visible text first, then `accessibilityLabel`,
    /// which is where tab-bar items and icon-only buttons keep their name),
    /// else the id, else the class name. `ordinal` ("2 of 5") joins the role
    /// in the parenthetical when the selector needed an `nth` to pick this
    /// element out of identical siblings — otherwise a bare class-name label
    /// like "_UITabButton" says nothing about WHICH tab button it is.
    static func describeTarget(_ view: UIView, ordinal: String? = nil) -> String {
        let role = ScreenElementFinder.role(of: view)
        let qualifier = [role, ordinal].compactMap { $0 }.joined(separator: ", ")
        if let text = InspectedView.textContent(of: view), !text.isEmpty {
            return qualifier.isEmpty ? "'\(text)'" : "'\(text)' (\(qualifier))"
        }
        if let label = view.accessibilityLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            return qualifier.isEmpty ? "'\(label)'" : "'\(label)' (\(qualifier))"
        }
        // The label a composite control contains (tab-bar title, icon-button
        // caption) — third rung of the text ladder.
        if let contained = ScreenElementFinder.contentText(of: view), !contained.isEmpty {
            return qualifier.isEmpty ? "'\(contained)'" : "'\(contained)' (\(qualifier))"
        }
        if let id = ScreenElementFinder.identifier(of: view), !id.isEmpty {
            return "'\(id)'"
        }
        let className = String(describing: type(of: view))
        return qualifier.isEmpty ? className : "\(className) (\(qualifier))"
    }

    /// "N of M" when the selector needed an `nth` to pick this element out of
    /// M disjoint siblings — nil when it matched exactly one (or none).
    private static func ordinalSuffix(for view: UIView, selector: MacroSelector) -> String? {
        guard let nth = selector.nth else { return nil }
        let query = ScreenElementFinder.Query(id: nil, text: selector.text, role: selector.role,
                                              className: selector.className, nth: nil)
        let total = ScreenElementFinder.find(query).count
        guard total > 1 else { return nil }
        return "\(nth + 1) of \(total)"
    }
}
#endif
