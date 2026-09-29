import Foundation

/// Deterministic matching of a sentence against entities, and the small amount
/// of English that needs. Used by `.rulesMatch` bindings, by the rules
/// resolver, and to check the model's answers — so every path agrees on what a
/// word is.
public enum EntityMatcher {
    public static func tokens(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_GB"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Words that carry no meaning for matching. "one" is here because "the one
    /// about X" names a title, not row 1.
    public static let stopWords: Set<String> = [
        "the", "a", "an", "and", "or", "of", "to", "in", "on", "for", "with", "about",
        "my", "me", "it", "is", "at", "s", "one", "open", "go", "back", "please",
        "chat", "session", "conversation", "thing", "where", "was", "that", "this",
    ]

    static let fillerWords: Set<String> = ["my", "the", "a", "an", "this", "that"]

    // MARK: Words

    /// Whether two words are the same word for matching purposes.
    ///
    /// Exact, or one is a prefix of the other and the shorter has at least four
    /// letters: "flicker" ~ "flickering", "deploy" ~ "deployed". Measured on the
    /// iPhone: the rules missed "Open the chat about flickering" against a
    /// title containing "flicker", which the model got 5/5 — the model's only
    /// clear win in that run was a missing suffix rule.
    public static func sameWord(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        return short.count >= 4 && long.hasPrefix(short)
    }

    static func overlap(_ said: [String], _ words: [String]) -> Int {
        let content = words.filter { !stopWords.contains($0) }
        return Set(content).filter { word in said.contains { sameWord($0, word) } }.count
    }

    // MARK: Positions

    private static let numberWords = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
    private static let ordinalWords = ["first", "second", "third", "fourth", "fifth",
                                       "sixth", "seventh", "eighth", "ninth", "tenth"]

    /// A 1-based position said anywhere in the sentence: "four", "the fourth
    /// one", "number 2", "the last one". Bounded by `count`, so a position
    /// nothing occupies is not a position.
    ///
    /// Anywhere, not the whole sentence: exact matching against a synonym list
    /// is why Siri's numbered menu cannot accept "the fourth one".
    public static func position(in tokens: [String], count: Int) -> Int? {
        guard count > 0 else { return nil }
        if tokens.contains("last") { return count }
        for (offset, token) in tokens.enumerated() {
            if token == "one" {
                // "the one about the deploy lock" is a title, not row 1.
                let previous = offset > 0 ? tokens[offset - 1] : ""
                guard previous == "number" || previous == "option" else { continue }
                return 1
            }
            if let digits = Int(token), (1...count).contains(digits) { return digits }
            if let index = numberWords.firstIndex(of: token), index < count { return index + 1 }
            if let index = ordinalWords.firstIndex(of: token), index < count { return index + 1 }
        }
        return nil
    }

    // MARK: Entities

    /// The words that can name an entity: its title's content words and every
    /// alias, as whole phrases.
    static func names(of entity: CommandEntity) -> [[String]] {
        [tokens(entity.title)] + entity.aliases.map(tokens)
    }

    /// The entity whose full title or an alias is said in the sentence, as a
    /// whole phrase. For short lists of distinct names — machines, rooms,
    /// accounts.
    public static func namedEntity(in text: String, candidates: [CommandEntity]) -> CommandEntity? {
        let said = tokens(text)
        for entity in candidates {
            for name in names(of: entity) where !name.isEmpty {
                if containsPhrase(said, name) { return entity }
            }
        }
        return nil
    }

    /// The best entity for a sentence by position, then by title words.
    /// For long lists of descriptive titles — chats, documents, playlists.
    public static func bestEntity(for text: String, candidates: [CommandEntity]) -> CommandEntity? {
        let said = tokens(text)
        if let number = position(in: said, count: candidates.count) { return candidates[number - 1] }
        if let named = namedEntity(in: text, candidates: candidates) { return named }
        var best: (entity: CommandEntity, score: Int)?
        for entity in candidates {
            let score = overlap(said, tokens(entity.title))
            guard score > 0 else { continue }
            if best == nil || score > best!.score { best = (entity, score) }
        }
        return best?.entity
    }

    static func containsPhrase(_ said: [String], _ phrase: [String]) -> Bool {
        guard !phrase.isEmpty, phrase.count <= said.count else { return false }
        for start in 0...(said.count - phrase.count)
        where zip(said[start...], phrase).allSatisfy({ sameWord($0, $1) }) {
            return true
        }
        return false
    }

    // MARK: Text

    /// The sentence with the app's name and any named entity removed — what to
    /// hand on as an instruction. "tell Ripul on my Mac to run the tests" →
    /// "run the tests".
    public static func strippingAddress(from text: String, addressWords: [String],
                                        entities: [CommandEntity]) -> String {
        let address = Set(addressWords.flatMap(tokens)).union(["tell", "ask", "hey", "please"])
        let entityPhrases = entities.flatMap { $0.aliases.map(tokens) }.filter { !$0.isEmpty }
        let words = tokens(text)
        var kept: [String] = []
        var index = 0
        while index < words.count {
            // A named entity, with the preposition and filler that led into it:
            // "on my Mac", "to the phone".
            if let length = entityPhrases.first(where: { phrase in
                index + phrase.count <= words.count
                    && zip(words[index...], phrase).allSatisfy { sameWord($0, $1) }
            })?.count {
                while let last = kept.last, fillerWords.contains(last) || last == "on" || last == "to" {
                    kept.removeLast()
                }
                index += length
                continue
            }
            if address.contains(words[index]) { index += 1; continue }
            kept.append(words[index])
            index += 1
        }
        while kept.first == "to" { kept.removeFirst() }
        let stripped = kept.joined(separator: " ")
        return stripped.isEmpty ? text.trimmingCharacters(in: .whitespacesAndNewlines) : stripped
    }

    /// Whether model-written text is about what was said at all.
    ///
    /// Measured on iOS 27: text copied from the instructions came back as the
    /// "instruction" for unrelated sentences. Sharing no content word with the
    /// sentence is the tell.
    public static func sharesContent(_ written: String, with said: String) -> Bool {
        overlap(tokens(said), tokens(written)) > 0
    }
}
