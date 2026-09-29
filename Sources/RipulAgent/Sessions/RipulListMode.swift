import SwiftUI
import Observation

/// Whether an agent workspace shows its session list or the chat, owned by
/// the host and shared with `RipulAgentScreen` and `SessionListMenu`.
///
/// Prefer this to a `Binding<Bool>` when the host is a large view: creating a
/// `Binding` calls its getter to snapshot the value, so building one in the
/// host's body subscribes that whole body to the mode, and every list/chat
/// flip re-renders it (the app's shell: 122–143ms per flip). Handing over
/// the object lets each consumer read it in its own body.
@MainActor
@Observable
public final class RipulListMode {
    public var showingSessionList: Bool
    public init(showingSessionList: Bool = true) {
        self.showingSessionList = showingSessionList
    }
}
