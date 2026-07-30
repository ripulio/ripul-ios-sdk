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
/// - `resolveForActuation` — only while no mutation has happened since the
///   snapshot that issued the handle. Any tap/type/scroll bumps
///   `actuationGeneration`, so a handle from before the mutation REFUSES to
///   actuate: the screen the agent read no longer exists (cells get reused,
///   lists reorder), and pressing whatever now sits at "e7" is how drives go
///   wrong silently. The agent must re-inspect.
///
/// - `resolveForObservation` — any generation, as long as the view is alive
///   and still attached to a window. Used by `wait_for_element(state:"gone")`:
///   the tap that SHOULD dismiss the element invalidates handles for
///   actuation, but the handle must still answer "is this exact view still on
///   screen?" — which is a fact about the view, not the snapshot.
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
    }

    private var entries: [String: Entry] = [:]
    private var nextOrdinal = 0
    /// Bumped by `beginSnapshot` (a fresh inspect) — marks when `entries` were issued.
    private var snapshotGeneration = 0
    /// Bumped by `invalidate` (any actuation) — compared against `snapshotGeneration`.
    private var actuationGeneration = 0

    /// A fresh inspect starts a new snapshot: all previously issued handles go
    /// stale for BOTH modes (the agent has fresh ones that describe reality).
    func beginSnapshot() {
        snapshotGeneration += 1
        entries = [:]
        nextOrdinal = 0
    }

    /// Any successful actuation. Handles stay resolvable for observation (did
    /// this exact view leave the screen?) but refuse actuation — the tree the
    /// agent read no longer describes the screen.
    func invalidate() {
        actuationGeneration += 1
    }

    /// Record one element of the current snapshot; returns its handle.
    @discardableResult
    func register(view: UIView, id: String?, text: String?) -> String {
        nextOrdinal += 1
        let handle = "e\(nextOrdinal)"
        entries[handle] = Entry(view: view, id: id, text: text)
        return handle
    }

    /// Whether the handle was ever issued by the current snapshot — lets the
    /// actuation tools distinguish "unknown handle" from "stale handle" in
    /// their error messages.
    func contains(_ handle: String) -> Bool { entries[handle] != nil }

    /// Actuation mode: nil unless the handle is from the current snapshot AND
    /// no actuation has happened since AND the view is still on screen.
    func resolveForActuation(_ handle: String) -> (view: UIView, id: String?, text: String?)? {
        guard snapshotGeneration == actuationGeneration else { return nil }
        return live(handle)
    }

    /// Observation mode: nil only once the view is deallocated or off-window.
    func resolveForObservation(_ handle: String) -> (view: UIView, id: String?, text: String?)? {
        live(handle)
    }

    private func live(_ handle: String) -> (view: UIView, id: String?, text: String?)? {
        guard let entry = entries[handle], let view = entry.view, view.window != nil else { return nil }
        return (view, entry.id, entry.text)
    }
}
#endif
