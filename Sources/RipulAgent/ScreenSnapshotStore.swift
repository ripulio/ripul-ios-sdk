import Foundation
#if canImport(UIKit)
import UIKit

/// Short-lived element handles ("e7", "e12", …) that `inspect_screen` issues
/// and the actuation tools (`tap_element`, `type_text`, `scroll_element`,
/// `wait_for_element`) accept, so the agent can hit EXACTLY the element it
/// just read about instead of re-matching visible text and hoping the first
/// match is the right one.
///
/// Staleness is two-mode, on purpose:
///
/// - `resolveForActuation` — the handle's view must be alive and on screen, and
///   EITHER nothing has been actuated since the snapshot OR the view is still
///   where it was and still carries the same id and text. That second clause is
///   the safety check that matters: cells get reused and lists reorder, so a
///   handle whose view moved or now says something else refuses to actuate and
///   the agent must re-inspect — but a Done button that stayed put across a
///   toggle tap is still the Done button.
///
/// - `resolveForObservation` — any generation, as long as the view is alive
///   and still attached to a window. Used by `wait_for_element(state:"gone")`:
///   the tap that SHOULD dismiss the element must still be able to answer "is
///   this exact view still on screen?" — a fact about the view, not the snapshot.
///
/// History: the actuation rule used to compare a count of inspects with a count
/// of actuations (`snapshotGeneration == actuationGeneration`) — two independent
/// counters that are equal only by coincidence. Once a session had made a
/// different number of taps than inspects, EVERY handle reported stale,
/// including those from an inspect a moment earlier.
///
/// Entries are weak refs capped by the inspector's own element cap, and are
/// replaced wholesale by the next `inspect_screen`, so the store never grows
/// unboundedly and never retains views.
@MainActor
final class ScreenSnapshotStore {
    static let shared = ScreenSnapshotStore()

    struct Entry {
        weak var view: UIView?
        let id: String?
        let text: String?
        /// Where the view was when the handle was issued, in window coordinates.
        let frame: CGRect
        /// `fingerprint(of:)` at issue — compared like-for-like after actuations.
        let fingerprint: String
    }

    private var entries: [String: Entry] = [:]
    private var nextOrdinal = 0
    /// Bumped by `invalidate` (any actuation).
    private var actuationGeneration = 0
    /// `actuationGeneration` as it stood when the current snapshot was taken.
    private var actuationsAtSnapshot = 0

    /// A fresh inspect starts a new snapshot: all previously issued handles are
    /// dropped (the agent has fresh ones that describe reality).
    func beginSnapshot() {
        entries = [:]
        nextOrdinal = 0
        actuationsAtSnapshot = actuationGeneration
    }

    /// Any successful actuation. Handles stay resolvable for observation; for
    /// actuation they must now prove they still describe the same element.
    func invalidate() {
        actuationGeneration += 1
    }

    /// Record one element of the current snapshot; returns its handle.
    @discardableResult
    func register(view: UIView, id: String?, text: String?) -> String {
        nextOrdinal += 1
        let handle = "e\(nextOrdinal)"
        entries[handle] = Entry(view: view, id: id, text: text,
                                frame: view.convert(view.bounds, to: nil), fingerprint: Self.fingerprint(of: view))
        return handle
    }

    /// Whether the handle was ever issued by the current snapshot — lets the
    /// actuation tools distinguish "unknown handle" from "stale handle" in
    /// their error messages.
    func contains(_ handle: String) -> Bool { entries[handle] != nil }

    /// Actuation mode: the view is alive and on screen, and either nothing has been
    /// actuated since the snapshot, or it hasn't moved and still names and says the same.
    func resolveForActuation(_ handle: String) -> (view: UIView, id: String?, text: String?)? {
        guard let entry = entries[handle], let view = entry.view, view.window != nil else { return nil }
        if actuationGeneration == actuationsAtSnapshot { return (view, entry.id, entry.text) }
        let now = view.convert(view.bounds, to: nil)
        let unmoved = abs(now.minX - entry.frame.minX) < 2 && abs(now.minY - entry.frame.minY) < 2
            && abs(now.width - entry.frame.width) < 2 && abs(now.height - entry.frame.height) < 2
        guard unmoved, Self.fingerprint(of: view) == entry.fingerprint else { return nil }
        return (view, entry.id, entry.text)
    }

    /// What the view names and says, by one fixed rule so issue-time and use-time
    /// readings compare like with like (a reused cell keeps its frame, not its content).
    private static func fingerprint(of view: UIView) -> String {
        let id = view.accessibilityIdentifier.flatMap { $0.isEmpty ? nil : $0 }
            ?? UIKitIdentifierRegistry.shared.identifier(for: view) ?? ""
        return id + "\u{1F}" + (InspectedView.textContent(of: view) ?? "")
    }

    /// Observation mode: nil only once the view is deallocated or off-window.
    func resolveForObservation(_ handle: String) -> (view: UIView, id: String?, text: String?)? {
        guard let entry = entries[handle], let view = entry.view, view.window != nil else { return nil }
        return (view, entry.id, entry.text)
    }
}
#endif
