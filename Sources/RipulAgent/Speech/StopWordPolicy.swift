import Foundation

/// Whether what the mic heard during playback was the listener asking it to
/// stop. Pure, so it can be tested without audio.
enum StopWordPolicy {
    /// Words that end a readout. "Pause" and "wait" end it too rather than
    /// freezing it: a frozen conversation can only be resumed by touch, and
    /// someone who interrupts by voice wants the mic, which a stop opens.
    static let commands: Set<String> = ["stop", "pause", "wait"]

    enum Verdict: Equatable {
        /// No command word in what was heard.
        case none
        /// A command word, but the phone's own readout says it in the same
        /// place, so it is most likely the mic hearing the speaker.
        case echo
        case command
    }

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
    }

    /// There is no echo cancellation during playback, so the mic hears the
    /// readout as well as the listener, and the recognizer transcribes both.
    /// A command word is the phone's own voice when it sits next to the same
    /// neighbour in the readout ("say stop now" heard while the phone says
    /// "say stop now"). The listener's "stop" lands between whatever readout
    /// words were playing, a pair the readout doesn't contain, or on its own.
    ///
    /// Ignoring every command word the readout contains was the first version.
    /// A readout explaining the feature says "stop", so it ignored the
    /// listener for exactly the utterance they were testing with.
    static func verdict(heard: String, whileSpeaking speaking: String) -> Verdict {
        let heardWords = words(heard)
        let spokenWords = words(speaking)
        let spokenPairs = Set(zip(spokenWords, spokenWords.dropFirst()).map { "\($0) \($1)" })
        var sawEcho = false
        for (index, word) in heardWords.enumerated() where commands.contains(word) {
            let before = index > 0 ? "\(heardWords[index - 1]) \(word)" : nil
            let after = index + 1 < heardWords.count ? "\(word) \(heardWords[index + 1])" : nil
            if before == nil, after == nil {
                // Alone in the result, so there's nothing to compare. If the
                // readout says this word, it may be the start of the phone's
                // own sentence: wait for the next result, which brings a
                // neighbour either way.
                if spokenWords.contains(word) { sawEcho = true } else { return .command }
            } else if before.map(spokenPairs.contains) == true || after.map(spokenPairs.contains) == true {
                sawEcho = true
            } else {
                return .command
            }
        }
        return sawEcho ? .echo : .none
    }

    static func heardCommand(_ heard: String, whileSpeaking speaking: String) -> Bool {
        verdict(heard: heard, whileSpeaking: speaking) == .command
    }
}
