import Foundation

// The two decisions behind the pushes the web app sends about a running
// agent, kept apart from the bridge so they can be read and tested as values:
// what a status push does to a chat's turn state, and what an activity event
// does to the subtitle on its row. The bridge does what they say.

/// What an `agent:status` push does to the chat it is about.
///
/// The push carries the chat it is ABOUT (the web's active chat, which may
/// not be native's), so it is applied to that chat and never to the active
/// chat's flags directly.
enum StatusPushDecision: Equatable {
    /// Why the web is asked again instead of the push being believed.
    enum PullReason: Equatable {
        /// The chat has turn events, and the push disagrees with them: the
        /// final lifecycle message may have been lost.
        case disagreesWithTurnEvents
        /// A chat known only by status was live, and the push says it is not.
        /// A not-running push here used to hard-clear to completed, but
        /// pushes can be transiently wrong mid-turn (the web's question-prompt
        /// valve pushes not-running while a tool waits on the user).
        case liveChatSaidNotRunning
    }

    /// Nothing changes.
    case leave
    /// The push is believed: the chat is running, or waiting on input.
    case apply(AgentTurnPhase)
    /// The push is not believed outright. Arbitrate with a chat-scoped pull
    /// of the web's lifecycle snapshot.
    case pull(PullReason)

    /// - Parameters:
    ///   - current: the phase native holds for the chat, if any.
    ///   - hasTurnEvents: the chat has lifecycle-event history. Events are
    ///     then the primary source of truth and a push never writes the phase.
    static func decide(running: Bool, paused: Bool, current: AgentTurnPhase?, hasTurnEvents: Bool) -> StatusPushDecision {
        if hasTurnEvents {
            let saysNotRunning = !running && current == .running
            let saysPaused = paused && current != .awaitingInput
            return saysNotRunning || saysPaused ? .pull(.disagreesWithTurnEvents) : .leave
        }
        if running || paused { return .apply(paused ? .awaitingInput : .running) }
        if current == .running || current == .awaitingInput { return .pull(.liveChatSaidNotRunning) }
        return .leave
    }
}

/// What an activity event does to the tool subtitle on a chat's row.
enum ActivitySubtitleDecision: Equatable {
    /// Session-row actions are stored separately: they persist across turns
    /// and are not part of the tool-activity subtitle.
    case storeSessionActions([SessionRowAction])
    /// A `completion` or a `TodoWrite`: the subtitle is cleared. A completion
    /// is a strong signal the turn ended; if the agent is still shown running
    /// the lifecycle event was lost, so the authoritative state is pulled.
    case clear(pullStatus: Bool)
    /// The event becomes the subtitle.
    ///
    /// Both a tool start and a tool end latch: Claude CLI tool actions come
    /// through as a single end with status=success (never a start), so
    /// filtering to start-only drops every CLI tool call.
    case latch
    /// A replayed event (an old timestamp): latching it would show a live
    /// subtitle, for a turn that finished offline, that never clears.
    case leave

    static func decide(event: AgentActivityEvent, isFresh: Bool, isAgentRunning: Bool) -> ActivitySubtitleDecision {
        if case .sessionAction(let actions) = event { return .storeSessionActions(actions) }
        let toolName: String?
        switch event {
        case .toolStart(let name, _, _, _): toolName = name
        case .toolEnd(let name, _, _, _, _): toolName = name
        default: toolName = nil
        }
        if toolName == "completion" { return .clear(pullStatus: isAgentRunning) }
        if toolName == "TodoWrite" { return .clear(pullStatus: false) }
        return isFresh ? .latch : .leave
    }
}
