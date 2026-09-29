import Combine

/// The active chat's turn phase, split off `AgentBridge`. Every turn start,
/// pause and finish flipped these on the bridge, and every view observing the
/// bridge re-rendered — the whole app shell included, measured on iPhone as an
/// 84-107ms hitch mid-swipe. Only the composer draws them; it observes this.
@MainActor
public final class RipulAgentTurnState: ObservableObject {
    @Published public internal(set) var phase: AgentTurnPhase = .idle
    @Published public internal(set) var isRunning = false
    @Published public internal(set) var isPaused = false
    public init() {}
}
