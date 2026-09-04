import Foundation

/// Rendezvous between the agent-callable `speak` tool and the voice loop.
///
/// The tool is registered once and is always present in the CLI's tool list;
/// it reports here whether a voice conversation is actually listening. That
/// keeps the tool's availability truthful without rebuilding the tool list
/// per turn (a changing tool list invalidates the whole prompt-cache prefix,
/// which costs far more than the tool's schema ever saves).
///
/// The tool never holds a reference to a controller — it publishes text here,
/// and whichever VoiceModeController is active consumes it.
@MainActor
public final class VoiceModeCoordinator {
    public static let shared = VoiceModeCoordinator()

    /// True while a hands-free voice conversation is running. The `speak`
    /// tool returns a "nobody is listening" result when false, so the agent
    /// learns not to keep calling it in typed sessions.
    public private(set) var isListening = false

    /// Set by the active VoiceModeController; receives agent-authored speech.
    var onAgentSpeech: ((String) -> Void)?

    /// Whether the agent has spoken at least once during the current turn.
    /// The loop uses this to decide whether to also read the completion
    /// message aloud (it shouldn't, if the agent already narrated).
    public private(set) var spokeThisTurn = false

    private init() {}

    func beginSession(onAgentSpeech: @escaping (String) -> Void) {
        self.onAgentSpeech = onAgentSpeech
        isListening = true
        spokeThisTurn = false
    }

    func endSession() {
        onAgentSpeech = nil
        isListening = false
        spokeThisTurn = false
    }

    /// Called at the start of each agent turn so `spokeThisTurn` reflects
    /// only the turn in flight.
    func markTurnStarted() {
        spokeThisTurn = false
    }

    /// Invoked by the `speak` tool. Returns false when no voice conversation
    /// is active, so the tool can tell the agent its speech wasn't heard.
    @discardableResult
    func deliver(_ text: String) -> Bool {
        guard isListening, let onAgentSpeech else { return false }
        spokeThisTurn = true
        onAgentSpeech(text)
        return true
    }
}
