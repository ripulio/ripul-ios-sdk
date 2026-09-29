import Foundation

// MARK: - A decision, and what became of it

/// What a resolver decided, before it is checked against reality. The same
/// shape whether it came from the model or from the rules.
public struct CommandDecision: Codable, Hashable, Sendable {
    public var commandId: String
    /// Entity source id → the 1-based number chosen from that source's list.
    public var picks: [String: Int]
    /// Model-written text, for `.modelWrites` bindings only.
    public var text: String?

    public init(commandId: String, picks: [String: Int] = [:], text: String? = nil) {
        self.commandId = commandId
        self.picks = picks
        self.text = text
    }
}

/// The live candidates for every source, read once per resolution so the
/// prompt, the schema and the check all see the same list.
public struct CommandSnapshot: Sendable, Equatable {
    public var entities: [String: [CommandEntity]]

    public init(entities: [String: [CommandEntity]] = [:]) {
        self.entities = entities
    }

    public func candidates(_ sourceId: String) -> [CommandEntity] { entities[sourceId] ?? [] }
}

/// Everything a resolution did, in the order it did it. The Lab shows this
/// whole record; a resolver that cannot explain itself cannot be tuned.
public struct CommandResolution: Sendable, Equatable {
    public enum Engine: String, Codable, Sendable { case model, rules }

    public var engine: Engine
    public var sentence: String
    /// Exactly what the model was sent. Nil for the rules.
    public var instructions: String?
    public var prompt: String?
    /// The raw answer, before any correction.
    public var decision: CommandDecision?
    /// The command that will run, after checking. Nil means nothing runs.
    public var commandId: String?
    public var actionId: String?
    public var values: ActionValues
    /// Every correction applied, in words: "chats number 9 is out of range".
    public var notes: [String]
    /// Whether the chosen command was abandoned for the map's fallback.
    public var fellBack: Bool
    public var duration: Duration?

    public init(engine: Engine, sentence: String) {
        self.engine = engine
        self.sentence = sentence
        self.values = ActionValues()
        self.notes = []
        self.fellBack = false
    }
}

// MARK: - Rendering what the model is sent

public enum CommandPrompt {
    /// Entity sources the model chooses from by number, in registry order.
    public static func pickedSources(map: CommandMap, registry: CommandRegistry) -> [EntitySource] {
        sources(map: map, registry: registry) { $0 == .modelPicks }
    }

    /// Entity sources matched by rules. Listed to the model unnumbered, so it
    /// knows those names are addresses rather than requests.
    public static func matchedSources(map: CommandMap, registry: CommandRegistry) -> [EntitySource] {
        sources(map: map, registry: registry) { $0 == .rulesMatch }
            .filter { source in !pickedSources(map: map, registry: registry).contains { $0.id == source.id } }
    }

    static func sources(map: CommandMap, registry: CommandRegistry,
                        where wanted: (ParameterBinding) -> Bool) -> [EntitySource] {
        var ids = Set<String>()
        for command in map.enabledCommands {
            guard let action = registry.action(command.actionId) else { continue }
            for parameter in action.parameters {
                guard case .entity(let sourceId) = parameter.kind,
                      let binding = command.bindings[parameter.name], wanted(binding) else { continue }
                ids.insert(sourceId)
            }
        }
        return registry.sources.filter { ids.contains($0.id) }
    }

    public static func instructions(map: CommandMap) -> String {
        let commands = map.enabledCommands.map { command in
            var line = "- \(command.id): \(command.description)"
            let examples = command.examples.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if !examples.isEmpty {
                line += " People say things like " + examples.map { "\"\($0)\"" }.joined(separator: ", ") + "."
            }
            return line
        }.joined(separator: "\n")
        let fallback = map.fallbackCommandId.flatMap { map.command($0)?.isEnabled == true ? $0 : nil }
        return map.instructionsTemplate
            .replacingOccurrences(of: "{{commands}}", with: commands)
            .replacingOccurrences(of: "{{fallback}}", with: fallback ?? "doing nothing")
    }

    public static func prompt(sentence: String, map: CommandMap, registry: CommandRegistry,
                              snapshot: CommandSnapshot) -> String {
        var blocks: [String] = []
        for source in pickedSources(map: map, registry: registry) {
            let candidates = snapshot.candidates(source.id)
            if candidates.isEmpty {
                blocks.append("\(source.title): none.")
            } else {
                blocks.append(([source.title + ":"] + candidates.enumerated().map { "\($0.offset + 1). \($0.element.title)" })
                    .joined(separator: "\n"))
            }
        }
        for source in matchedSources(map: map, registry: registry) {
            let names = snapshot.candidates(source.id).map(\.title)
            guard !names.isEmpty else { continue }
            blocks.append("\(source.title), named rather than chosen: \(names.joined(separator: ", ")).")
        }
        return map.promptTemplate
            .replacingOccurrences(of: "{{entities}}", with: blocks.joined(separator: "\n"))
            .replacingOccurrences(of: "{{sentence}}", with: sentence)
    }
}

// MARK: - Checking a decision against reality

/// Turns a decision into a command, an action and its inputs, correcting or
/// abandoning anything that does not survive contact with the live snapshot
/// and the words actually said. Model and rules decisions go through the same
/// door, so the two can only ever differ in what they chose.
public enum CommandBinder {
    public static func bind(_ decision: CommandDecision, into resolution: inout CommandResolution,
                            map: CommandMap, registry: CommandRegistry, snapshot: CommandSnapshot) {
        resolution.decision = decision
        if let command = map.command(decision.commandId), command.isEnabled {
            switch values(for: command, decision: decision, sentence: resolution.sentence,
                          map: map, registry: registry, snapshot: snapshot, notes: &resolution.notes) {
            case .success(let values):
                resolution.commandId = command.id
                resolution.actionId = command.actionId
                resolution.values = values
                return
            case .failure(let reason):
                resolution.notes.append("\(command.id): \(reason)")
            }
        } else {
            resolution.notes.append("\"\(decision.commandId)\" is not an enabled command")
        }

        resolution.fellBack = true
        // Retrying the fallback when it is the thing that just failed would
        // only fail the same way.
        guard let fallbackId = map.fallbackCommandId, fallbackId != decision.commandId,
              let fallback = map.command(fallbackId), fallback.isEnabled else {
            resolution.notes.append("no fallback command, so nothing runs")
            return
        }
        // The fallback is bound with no model picks: whatever the model chose
        // was the thing that just failed.
        let clean = CommandDecision(commandId: fallback.id, picks: [:], text: decision.text)
        switch values(for: fallback, decision: clean, sentence: resolution.sentence,
                      map: map, registry: registry, snapshot: snapshot, notes: &resolution.notes) {
        case .success(let values):
            resolution.commandId = fallback.id
            resolution.actionId = fallback.actionId
            resolution.values = values
        case .failure(let reason):
            resolution.notes.append("fallback \(fallback.id): \(reason), so nothing runs")
        }
    }

    enum BindingFailure: Error, CustomStringConvertible {
        case missingAction(String)
        case requiredInput(String)
        var description: String {
            switch self {
            case .missingAction(let id): return "action \"\(id)\" is not registered"
            case .requiredInput(let name): return "required input \"\(name)\" could not be filled"
            }
        }
    }

    static func values(for command: SoftCommand, decision: CommandDecision, sentence: String,
                       map: CommandMap, registry: CommandRegistry, snapshot: CommandSnapshot,
                       notes: inout [String]) -> Result<ActionValues, BindingFailure> {
        guard let action = registry.action(command.actionId) else {
            return .failure(.missingAction(command.actionId))
        }
        var values = ActionValues()

        // Entities first: a text input strips whichever entity was named, so it
        // has to know which one that was.
        for parameter in action.parameters {
            guard case .entity(let sourceId) = parameter.kind else { continue }
            let candidates = snapshot.candidates(sourceId)
            switch command.bindings[parameter.name] {
            case .modelPicks:
                if let number = decision.picks[sourceId], number > 0 {
                    if candidates.indices.contains(number - 1) {
                        values.entities[parameter.name] = candidates[number - 1]
                    } else {
                        notes.append("\(sourceId) number \(number) is out of range (\(candidates.count) listed)")
                    }
                }
            case .rulesMatch:
                if let named = EntityMatcher.namedEntity(in: sentence, candidates: candidates) {
                    values.entities[parameter.name] = named
                }
            case .constant(let id):
                if let entity = candidates.first(where: { $0.id == id }) {
                    values.entities[parameter.name] = entity
                } else {
                    notes.append("\(parameter.name): no \(sourceId) with id \"\(id)\"")
                }
            case .utterance, .modelWrites, nil:
                break
            }
            if parameter.isRequired && values.entities[parameter.name] == nil {
                return .failure(.requiredInput(parameter.name))
            }
        }

        let named = Array(values.entities.values)
        let ownWords = EntityMatcher.strippingAddress(from: sentence, addressWords: map.addressWords, entities: named)
        for parameter in action.parameters where parameter.kind == .text {
            switch command.bindings[parameter.name] {
            case .utterance:
                values.texts[parameter.name] = ownWords
            case .modelWrites:
                let written = (decision.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !written.isEmpty, EntityMatcher.sharesContent(written, with: sentence) {
                    values.texts[parameter.name] = written
                } else {
                    if !written.isEmpty { notes.append("model text \"\(written)\" is not about what was said; used the sentence") }
                    values.texts[parameter.name] = ownWords
                }
            case .constant(let text):
                values.texts[parameter.name] = text
            case .modelPicks, .rulesMatch, nil:
                break
            }
            if parameter.isRequired && (values.texts[parameter.name] ?? "").isEmpty {
                return .failure(.requiredInput(parameter.name))
            }
        }
        return .success(values)
    }
}

// MARK: - Checking a map before it is run

public extension CommandMap {
    /// Everything about this map that will make it misbehave against this
    /// registry, in words a person editing it can act on. Empty when sound.
    ///
    /// A map is config that outlives the code it was written for: an action
    /// can be renamed or removed in a release, and a map edited on a phone
    /// can be half-finished. These are the mistakes that otherwise surface
    /// only as a sentence that mysteriously falls back.
    func problems(registry: CommandRegistry) -> [String] {
        var problems: [String] = []
        let enabled = enabledCommands

        if enabled.isEmpty { problems.append("No command is enabled, so nothing can be chosen.") }

        var seen = Set<String>()
        for command in commands where !seen.insert(command.id).inserted {
            problems.append("Two commands are called \(command.id).")
        }

        for command in enabled {
            if command.description.trimmingCharacters(in: .whitespaces).isEmpty {
                problems.append("\(command.id) has no description, so the model has only its name to go on.")
            }
            guard let action = registry.action(command.actionId) else {
                problems.append("\(command.id) runs \"\(command.actionId)\", which this app doesn't have.")
                continue
            }
            for name in command.bindings.keys where !action.parameters.contains(where: { $0.name == name }) {
                problems.append("\(command.id) fills \"\(name)\", which \(action.title) doesn't take.")
            }
            for parameter in action.parameters {
                let binding = command.bindings[parameter.name]
                if parameter.isRequired && binding == nil {
                    problems.append("\(command.id) never fills \"\(parameter.name)\", which \(action.title) needs — it will always fall back.")
                }
                switch (parameter.kind, binding) {
                case (.entity, .utterance), (.entity, .modelWrites), (.text, .modelPicks), (.text, .rulesMatch):
                    problems.append("\(command.id) fills \"\(parameter.name)\" in a way that doesn't fit it.")
                case (.text, .modelWrites):
                    problems.append("\(command.id) has the model write \"\(parameter.name)\" — measured as the least reliable thing it produces.")
                default:
                    break
                }
            }
        }

        if let fallbackId = fallbackCommandId {
            if let fallback = command(fallbackId) {
                if !fallback.isEnabled { problems.append("The fallback, \(fallbackId), is turned off, so anything unclear does nothing.") }
            } else {
                problems.append("The fallback, \"\(fallbackId)\", isn't one of the commands.")
            }
        } else {
            problems.append("There's no fallback, so anything unclear does nothing.")
        }

        if !instructionsTemplate.contains("{{commands}}") {
            problems.append("The instructions don't include {{commands}}, so the model never sees the command list.")
        }
        if !promptTemplate.contains("{{sentence}}") {
            problems.append("The prompt doesn't include {{sentence}}, so the model never sees what was said.")
        }
        if !promptTemplate.contains("{{entities}}"), !CommandPrompt.pickedSources(map: self, registry: registry).isEmpty {
            problems.append("The prompt doesn't include {{entities}}, so the model never sees the lists it has to choose from.")
        }
        return problems
    }
}

// MARK: - The rules resolver

/// No model. Two jobs, both load-bearing: the path for every device without
/// Apple Intelligence (a normal path, not an error), and the baseline a model
/// has to beat before it earns its latency.
public enum CommandRules {
    public static func decide(_ sentence: String, map: CommandMap, registry: CommandRegistry,
                              snapshot: CommandSnapshot) -> CommandDecision? {
        let said = EntityMatcher.tokens(sentence)
        guard !said.isEmpty else { return nil }

        // 1. The command whose example phrase appears in the sentence. The
        //    longest match wins, so "open voice mode" beats "open".
        var best: (command: SoftCommand, length: Int)?
        for command in map.enabledCommands {
            for example in command.examples {
                let phrase = EntityMatcher.tokens(example)
                guard !phrase.isEmpty, EntityMatcher.containsPhrase(said, phrase) else { continue }
                if best == nil || phrase.count > best!.length { best = (command, phrase.count) }
            }
        }

        // 2. Otherwise, the first command that picks from a source in which the
        //    sentence plainly names something — "the fourth one", "the flicker
        //    thing".
        if best == nil {
            for command in map.enabledCommands {
                for source in pickSources(of: command, registry: registry)
                where EntityMatcher.bestEntity(for: sentence, candidates: snapshot.candidates(source)) != nil {
                    best = (command, 0)
                    break
                }
                if best != nil { break }
            }
        }

        guard let command = best?.command ?? map.fallbackCommandId.flatMap(map.command) else { return nil }
        var picks: [String: Int] = [:]
        for source in pickSources(of: command, registry: registry) {
            let candidates = snapshot.candidates(source)
            if let entity = EntityMatcher.bestEntity(for: sentence, candidates: candidates),
               let index = candidates.firstIndex(of: entity) {
                picks[source] = index + 1
            }
        }
        return CommandDecision(commandId: command.id, picks: picks)
    }

    static func pickSources(of command: SoftCommand, registry: CommandRegistry) -> [String] {
        guard let action = registry.action(command.actionId) else { return [] }
        return action.parameters.compactMap { parameter in
            guard case .entity(let sourceId) = parameter.kind,
                  command.bindings[parameter.name] == .modelPicks else { return nil }
            return sourceId
        }
    }
}
