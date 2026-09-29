import SwiftUI
import Observation

/// Last-active times keyed by UnifiedSession.id: the cold-start fallback for
/// ordering rows before live activity arrives, persisted across launches.
///
/// While the app runs, every entry is a copy of a live time the list already
/// tracks (`SessionListStore.lastActiveTimeByChatId`, through per-chat cells
/// and `recencyRevision`), taken over the same keys `effectiveLastActive`
/// reads. So incremental updates, which arrive every ~2s while an agent runs,
/// change nothing on screen, and announcing them re-rendered the whole
/// session list mid-swipe (`GlassSessionsList: @self changed`, 30-50ms).
/// Only wholesale replacement (restore at launch, sign-out) is announced.
@MainActor
@Observable
public final class RipulLastActiveStore {
    @ObservationIgnored public private(set) var bySessionId: [String: Date] = [:]
    /// Moves when the map is replaced wholesale; readers subscribe to this.
    public private(set) var revision = 0
    public init() {}

    /// Restore or clear: views re-read.
    func replaceAll(_ map: [String: Date]) {
        bySessionId = map
        revision &+= 1
    }

    /// Mirror live times into the persisted map without re-rendering.
    func mergeLive(_ map: [String: Date]) {
        bySessionId = map
    }
}

/// Re-renders its content only when the last-active map is replaced wholesale.
public struct LastActiveReader<Content: View>: View {
    private let store: RipulLastActiveStore
    private let content: ([String: Date]) -> Content

    public init(_ store: RipulLastActiveStore, @ViewBuilder content: @escaping ([String: Date]) -> Content) {
        self.store = store
        self.content = content
    }

    public var body: some View {
        let _ = store.revision
        content(store.bySessionId)
    }
}
