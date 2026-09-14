import Foundation

public enum VoiceSendMode: String, CaseIterable, Sendable {
    case automatic = "automatic"
    case sendCommand = "sendCommand"
}

/// Turn boundaries depend on both the current transcript and live microphone
/// activity. A recognizer stall alone must not count as the command's pause.
enum VoiceSendPolicy {
    static let commandPause: TimeInterval = 0.7
    private static let closingCommand = try! NSRegularExpression(
        pattern: #"(?i)(?<![\p{L}\p{N}_])send[\s\p{P}]+command[\s\p{P}]*$"#
    )

    /// Nil means the closing command is absent or has no message before it.
    /// Only the final occurrence is removed; mentions inside the message stay.
    static func messageBeforeCommand(_ text: String) -> String? {
        guard let match = closingCommand.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        let body = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.rangeOfCharacter(from: .alphanumerics) != nil else { return nil }
        return body
    }

    static func messageToSend(
        mode: VoiceSendMode, text: String, quietFor: TimeInterval,
        transcriptIdleFor: TimeInterval, audioIsFresh: Bool
    ) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        switch mode {
        case .automatic:
            // Preserve the existing 1.8-second pause and noisy-room escape.
            return quietFor >= 1.8 || transcriptIdleFor >= 6 ? text : nil
        case .sendCommand:
            // No noisy-room escape: this mode explicitly requires quiet.
            guard audioIsFresh, quietFor >= commandPause,
                  transcriptIdleFor >= commandPause else { return nil }
            return messageBeforeCommand(text)
        }
    }
}
