import Foundation
#if canImport(UIKit)
import UIKit

// MARK: - Selector synthesis (live view → durable MacroSelector)

public extension MacroSelector {
    /// Synthesize a durable selector for a live view, using the SAME identity
    /// ladder the actuation tools already compute — an id alone when present
    /// (tightest, most stable), else role + visible text, else role + class.
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
        self.init(text: (text?.isEmpty == false) ? text : nil,
                  role: ScreenElementFinder.role(of: view),
                  className: String(describing: type(of: view)))
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
        let label = describeTarget(view)

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
    /// text when available, else the id, else the class name.
    static func describeTarget(_ view: UIView) -> String {
        let role = ScreenElementFinder.role(of: view)
        if let text = InspectedView.textContent(of: view), !text.isEmpty {
            return role.map { "'\(text)' (\($0))" } ?? "'\(text)'"
        }
        if let id = ScreenElementFinder.identifier(of: view), !id.isEmpty {
            return "'\(id)'"
        }
        return String(describing: type(of: view))
    }
}
#endif
