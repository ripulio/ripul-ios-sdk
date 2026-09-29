import Foundation

/// What a piece of speech is for. Each job can use its own ElevenLabs model
/// because the trade-offs differ: a spoken reply wants expression, an
/// acknowledgement wants speed, and a long read-aloud wants a voice that stays
/// steady. Mirrors `SpeechRole` in the web app
/// (chrome-extension/src/speech/elevenLabsModels.ts); the raw values are the
/// wire spelling used by the `speech` capability.
public enum SpeechRole: String, CaseIterable, Sendable {
    case reply
    case acknowledgement
    case readAloud

    public var title: String {
        switch self {
        case .reply: return "Replies"
        case .acknowledgement: return "Acknowledgements"
        case .readAloud: return "Read aloud"
        }
    }
}

/// An ElevenLabs text-to-speech model offered in settings. Mirrors
/// `ELEVENLABS_TTS_MODELS` in the web app.
public struct ElevenLabsModelOption: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let summary: String

    /// Used when no model is chosen — matches the worker's default.
    public static let defaultModelId = "eleven_multilingual_v2"

    public static let all: [ElevenLabsModelOption] = [
        ElevenLabsModelOption(id: "eleven_multilingual_v2", label: "Multilingual v2",
                              summary: "Steady over long text. Supports every Delivery control."),
        ElevenLabsModelOption(id: "eleven_v4", label: "Eleven v4",
                              summary: "Most expressive, 90+ languages. Ignores Pace."),
        ElevenLabsModelOption(id: "eleven_flash_v2_5", label: "Flash v2.5",
                              summary: "Fastest and cheapest, least expressive."),
    ]

    public static func named(_ id: String?) -> ElevenLabsModelOption? {
        all.first { $0.id == id }
    }

    /// ElevenLabs model ids are short snake_case names; anything else is ignored.
    static func isValidId(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.utf8.allSatisfy { (48...57).contains($0) || (97...122).contains($0) || $0 == 95 }
    }

    /// Eleven v3 and v4 dropped the speed and style controls, so those are
    /// only sent to the models that still take them.
    static func takesPaceAndStyle(_ id: String) -> Bool {
        !id.hasPrefix("eleven_v3") && !id.hasPrefix("eleven_v4")
    }
}
