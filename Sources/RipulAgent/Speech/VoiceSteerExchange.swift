import Foundation

/// A spoken message sent while the agent was already working on a task.
///
/// Such a message steers the running task (the web app hands it to the agent
/// at its next step) instead of starting a turn of its own, so the turn ending
/// can no longer be what ends the exchange. The agent says when it has
/// answered: the speak call that answers carries `answer: true`. That ends the
/// exchange, and the microphone reopens while the task carries on.
///
/// Nothing here is a timer or a guess: the exchange is open from a send made
/// while the agent was running until the agent's own `answer: true`, or the
/// task's end. An agent that answers in writing only never sends the signal,
/// so the microphone stays closed until the task ends, as before steering.
struct VoiceSteerExchange: Equatable {
    /// A spoken message went in mid-task and has not been answered aloud yet.
    private(set) var awaitingAnswer = false
    /// The answer was spoken and the microphone reopened while the task runs.
    private(set) var listeningMidTask = false

    /// A spoken message was sent. Only one sent while the agent was running
    /// opens an exchange; anything else starts a turn as before.
    mutating func sent(whileAgentRunning: Bool) {
        awaitingAnswer = whileAgentRunning
        listeningMidTask = false
    }

    /// The agent spoke. True when this speech ends the exchange, so the
    /// microphone should reopen once it has played.
    mutating func agentSpoke(answer: Bool, agentRunning: Bool) -> Bool {
        guard answer, awaitingAnswer else { return false }
        awaitingAnswer = false
        listeningMidTask = agentRunning
        return true
    }

    /// The running task ended. True when the microphone had been reopened
    /// mid-task, so the end of the task should be handled as it is today.
    mutating func taskEnded() -> Bool {
        let wasListening = listeningMidTask
        self = VoiceSteerExchange()
        return wasListening
    }

    mutating func reset() { self = VoiceSteerExchange() }
}
