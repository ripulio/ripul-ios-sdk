import Foundation

public enum VoiceSendMode: String, CaseIterable, Sendable {
    case automatic = "automatic"
    case sendCommand = "sendCommand"
}

/// Turn boundaries depend on both the current transcript and live microphone
/// activity. A recognizer stall alone must not count as the command's pause.
enum VoiceSendPolicy {
    static let commandPause: TimeInterval = 0.7
    /// "Send" or "sending", optionally one word, then "command" or "request".
    /// The optional word accommodates "a", "the", "this", etc.
    /// Recognizers mishear the phrase ("same command", "sent command") and
    /// split or join it ("Send. Command.", "sendcommand"). Near-homophones of
    /// "send" with singular "command" count anywhere. Looser forms that occur
    /// in ordinary speech ("run the same command", "how do I send commands")
    /// count only as their own sentence, after recognizer punctuation.
    private static let closingCommand = try! NSRegularExpression(
        pattern: #"""
        (?ix)
        (?:
          (?<![\p{L}\p{N}_]) send(?:ing)? [\s\p{P}]+ (?:[\p{L}\p{M}\p{N}_]+ [\s\p{P}]+)? (?:command|request)
        | (?<![\p{L}\p{N}_]) (?:send|sent|sand) [\s\p{P}]* (?:command|comand|commend)
        | (?<=[.!?,;:…]\s{0,3}) (?:send|sent|sand|same|said) [\s\p{P}]+ (?:command|comand|commend|comment)s?
        )
        [\s\p{P}]*$
        """#
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

    // MARK: Command sessions
    //
    // WHAT A COMMAND SESSION CAN AND CANNOT MEASURE. It has two signals, and
    // on 10 October 2026 both were shown to be weaker than they look.
    //
    //   The microphone level. On a phone it did not register the speaker at
    //   all: sentences were ended mid-word ("Open the chat about app or-",
    //   "Open the chat about agent ru-"), which a working level check cannot
    //   do. So the level may only ever HOLD a send back, never justify one.
    //
    //   The recogniser's text. Scribe reports the open segment about once a
    //   second and about a second behind the voice. A wait shorter than that
    //   interval ends between two reports, while the person is still talking.
    //
    // What can be trusted is a REPEAT: the recogniser reporting again with the
    // same words. That is its own statement that a further second of audio
    // held nothing new. One repeat ends an ordinary sentence. It costs about
    // two seconds from the last word, which is the price of the service's
    // cadence, not a number to tune down: a shorter wait is what cut people
    // off.

    /// The words must also have stood this long. Guards against two reports
    /// arriving back to back.
    static let commandSessionPause: TimeInterval = 1.2

    /// Repeats needed before a sentence that reads as unfinished is ended:
    /// the person is probably finding the word.
    static let unfinishedRepeats = 3

    /// Whether a sentence stops where a sentence does not: on a dash or an
    /// ellipsis the recogniser put there, a trailing comma, or a word that
    /// needs something after it. Deliberately short. "On", "in", "to", "up"
    /// and "with" end real commands ("carry on", "log in").
    static func looksUnfinished(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return false }
        if "-–—…,".contains(last) || trimmed.hasSuffix("...") { return true }
        let words = trimmed.lowercased()
            .components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'’")).inverted)
            .filter { !$0.isEmpty }
        guard let word = words.last else { return false }
        return danglingWords.contains(word)
    }

    /// The words alone: lowercased, with punctuation and spacing removed, so
    /// two reports of the same words compare equal however they are written.
    static func words(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static let danglingWords: Set<String> = [
        "about", "the", "a", "an", "of", "and", "or", "but", "my", "your",
        "from", "into", "called", "named", "because", "if",
    ]

    /// A command session's sentence, once it has ended, or nil while it has
    /// not. `unchangedRepeats` counts the recogniser's reports since the words
    /// last changed; `wordsUnchangedFor` is the time since that change;
    /// `quietFor` is the time since the microphone level last registered a
    /// voice.
    static func commandToRun(
        text: String, quietFor: TimeInterval, wordsUnchangedFor: TimeInterval,
        unchangedRepeats: Int, audioIsFresh: Bool
    ) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // A stalled microphone is not a pause. And a level that has just
        // registered a voice holds everything: the words are about to change.
        if audioIsFresh, quietFor >= 0.5 {
            // The closing phrase of ordinary voice mode is an explicit end,
            // so it needs no repeat.
            if messageBeforeCommand(text) != nil, wordsUnchangedFor >= commandPause { return text }
            let needed = looksUnfinished(text) ? unfinishedRepeats : 1
            if unchangedRepeats >= needed, wordsUnchangedFor >= commandSessionPause { return text }
        }
        // A room too loud to read, or a recogniser that has gone quiet.
        return wordsUnchangedFor >= 6 ? text : nil
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
