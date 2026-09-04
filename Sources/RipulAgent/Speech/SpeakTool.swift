import Foundation

/// Agent-callable text-to-speech for hands-free voice conversations.
///
/// This tool's `description` IS the voice protocol — it replaces the
/// per-turn prompt rider. Tool definitions are re-sent (and prompt-cached)
/// on every request, so the instruction can never decay out of context the
/// way a conversational primer does, and it costs nothing per turn beyond a
/// cache read.
///
/// Registered unconditionally rather than swapped in when voice mode starts:
/// a changing tool list invalidates the whole cached prompt prefix, and the
/// CLI's tool-list watcher only polls periodically, so a just-registered
/// tool would miss the first turn. Instead the tool stays present and tells
/// the agent truthfully whether anyone is listening.
public struct SpeakTool: NativeTool {
    public let name = "speak"

    public let description = """
        Speak text aloud to the user in a hands-free voice conversation.

        A user message wrapped in <voice>…</voice> markup was spoken aloud — \
        the user is listening, not reading. When the latest user message \
        carries this markup, talk to them through this tool and close your \
        turn by speaking the answer. The markup applies per message: a later \
        user message WITHOUT it means the user is back to typing and \
        reading, so reply in writing and stop speaking.

        Write for the ear: one to three short conversational sentences, \
        plain prose only — no markdown, no code, no tables, no file paths, \
        no URLs, no identifiers. When your reply contains that kind of \
        material, refer the listener to the screen instead (for example, \
        "the diff is in the chat").

        You may call this several times in one turn: a brief acknowledgement \
        when you start, an occasional plain-language progress note during \
        long work, and a closing call that delivers the answer. If you speak \
        at all during a turn, finish by speaking the answer — your written \
        reply is not read aloud when you have spoken for yourself.

        Returns spoken=false when no voice conversation is active. That means \
        nobody heard it: stop calling this for the rest of the turn and put \
        your answer in the written reply as normal.
        """

    public let inputSchema: [String: Any] = ToolSchema.object(
        .string("text", "The words to speak aloud. Plain conversational prose, no markup.", required: true)
    )

    public let outputSchema: [String: Any]? = ToolSchema.object(
        .bool("spoken", "True if the text was spoken to a listening user"),
        .string("reason", "Why it was not spoken, when spoken is false")
    )

    public init() {}

    @MainActor
    public func execute(args: [String: Any]) async throws -> Any {
        let text = try string("text", from: args)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ["spoken": false, "reason": "Empty text — nothing to speak."]
        }
        guard VoiceModeCoordinator.shared.deliver(trimmed) else {
            return [
                "spoken": false,
                "reason": "No voice conversation is active — the user is reading, not listening. Put your answer in the written reply instead.",
            ]
        }
        return ["spoken": true]
    }
}
