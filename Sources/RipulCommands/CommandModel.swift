import Foundation

// RipulCommands turns a spoken or typed sentence into one of an app's own
// actions, using Apple's on-device model where it helps and plain rules where
// it does not.
//
// THREE LAYERS, owned by different people and changed at different speeds:
//
//   1. Actions and entity sources — CODE, registered by the host app. What the
//      app can genuinely do ("open a chat"), with named inputs, and the
//      collections those inputs are chosen from ("chats"). Changes with an app
//      release.
//   2. The command map — CONFIG, JSON, versioned. Soft commands the model
//      chooses between, what it is told about each, how people phrase them,
//      which action each maps to and how every input is filled. Editable at
//      runtime, on the device.
//   3. The resolver — this package. Builds the prompt, constrains the model's
//      answer to the commands and entities that exist right now, checks the
//      answer against reality, and records everything it did.
//
// Nothing here knows about Ripul. The Ripul app is one consumer: it registers
// its actions and sources exactly as a third party would.
//
// Every rule in this package that looks fussy came from a measurement of the
// on-device model — on both the iOS 26 (4096) and iOS 27 (8192) generations —
// and the comment beside it says which.

// MARK: - Layer 1: what the host app can do (code)

/// Something the model can choose between: a chat, a machine, a playlist.
public struct CommandEntity: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
    /// What a person might say for it other than the title. "My Mac" for a
    /// machine titled "Peter's MacBook Pro". Matched as whole words.
    public let aliases: [String]

    public init(id: String, title: String, aliases: [String] = []) {
        self.id = id
        self.title = title
        self.aliases = aliases
    }
}

/// A named collection of entities, supplied live by the host app.
///
/// Read once per resolution, so the model only ever chooses from what exists
/// at that moment — never from a list cached when the map was written.
public struct EntitySource: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let candidates: @Sendable () async -> [CommandEntity]

    public init(id: String, title: String, candidates: @escaping @Sendable () async -> [CommandEntity]) {
        self.id = id
        self.title = title
        self.candidates = candidates
    }
}

/// An input an action needs.
public struct ActionParameter: Codable, Hashable, Sendable {
    public enum Kind: Codable, Hashable, Sendable {
        /// One entity from the named source.
        case entity(sourceId: String)
        /// Free text — typically the instruction to pass on.
        case text
    }

    public let name: String
    public let kind: Kind
    /// A required input that cannot be filled sends the resolution to the
    /// map's fallback rather than running the action half-specified.
    public let isRequired: Bool

    public init(name: String, kind: Kind, isRequired: Bool = true) {
        self.name = name
        self.kind = kind
        self.isRequired = isRequired
    }
}

/// The inputs an action receives, keyed by parameter name.
public struct ActionValues: Equatable, Sendable {
    public var entities: [String: CommandEntity]
    public var texts: [String: String]

    public init(entities: [String: CommandEntity] = [:], texts: [String: String] = [:]) {
        self.entities = entities
        self.texts = texts
    }
}

/// Something the host app can genuinely do. The only layer that changes with
/// an app release: command maps point at actions by `id`, never the reverse.
public struct CommandAction: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let parameters: [ActionParameter]
    public let perform: @Sendable (ActionValues) async throws -> Void

    public init(id: String, title: String, parameters: [ActionParameter] = [],
                perform: @escaping @Sendable (ActionValues) async throws -> Void) {
        self.id = id
        self.title = title
        self.parameters = parameters
        self.perform = perform
    }
}

/// Everything a host app registers. A value, built once, handed to the
/// resolver and to the Lab.
public struct CommandRegistry: Sendable {
    public let actions: [CommandAction]
    public let sources: [EntitySource]

    public init(actions: [CommandAction], sources: [EntitySource]) {
        self.actions = actions
        self.sources = sources
    }

    public func action(_ id: String) -> CommandAction? { actions.first { $0.id == id } }
    public func source(_ id: String) -> EntitySource? { sources.first { $0.id == id } }
}

// MARK: - Layer 2: the command map (config)

/// How one action input gets its value.
public enum ParameterBinding: Codable, Hashable, Sendable {
    /// The model chooses, by NUMBER, from the parameter's entity source.
    ///
    /// A number rather than a title or an id: an index is either in range or it
    /// is not, and out of range is a clean fallback. A title has to be
    /// fuzzy-matched back, and an id can be invented.
    case modelPicks
    /// Deterministic alias matching against the sentence; the model is not
    /// asked. Right for short lists of distinct names.
    ///
    /// Measured: asked to pick a machine, the iOS 26 model invented one for a
    /// sentence naming none (1 in 5), and the iOS 27 model dropped one that was
    /// named (5 in 5). Whether a machine was named is alias matching; the model
    /// was never better than the rules at it.
    case rulesMatch
    /// The sentence itself, with the app's name and any rules-matched entity
    /// removed: "tell Ripul on my Mac to run the tests" → "run the tests".
    case utterance
    /// Free text written by the model.
    ///
    /// Discouraged, and kept only so it can be measured. Measured on iOS 27:
    /// asked to write the instruction, the model rephrased people in the third
    /// person ("The person wants to open…") and once pasted part of its own
    /// input into the answer. Output that shares no word with the sentence is
    /// replaced by `.utterance`, but that cannot catch a paraphrase.
    case modelWrites
    case constant(String)
}

/// One command the model can choose. Its `id` is what the model outputs, so
/// keep it short, lowercase and meaningful: "open_chat", not "cmd3".
public struct SoftCommand: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// What the model is told this command is for.
    public var description: String
    /// Things people SAY for this command. Shown to the model as input
    /// examples, and used by the rules resolver as trigger phrases.
    ///
    /// Never put examples of what the model should WRITE here. Measured on
    /// iOS 27: an example of escalate output ("what is failing") was copied
    /// verbatim as the answer to unrelated sentences, five times in five.
    public var examples: [String]
    public var actionId: String
    /// Action parameter name → how to fill it. A parameter with no binding is
    /// left empty.
    public var bindings: [String: ParameterBinding]
    public var isEnabled: Bool

    public init(id: String, description: String, examples: [String] = [], actionId: String,
                bindings: [String: ParameterBinding] = [:], isEnabled: Bool = true) {
        self.id = id
        self.description = description
        self.examples = examples
        self.actionId = actionId
        self.bindings = bindings
        self.isEnabled = isEnabled
    }
}

/// A complete, portable routing configuration. Exported and imported as JSON.
public struct CommandMap: Codable, Hashable, Sendable, Identifiable {
    /// Bumped on any change that an older build could not read correctly.
    public static let currentVersion = 1

    public var version: Int
    public var id: String
    public var name: String
    /// Sent once per session as the model's instructions. Placeholders:
    /// `{{commands}}`, `{{fallback}}`.
    public var instructionsTemplate: String
    /// Sent per sentence. Placeholders: `{{entities}}`, `{{sentence}}`.
    public var promptTemplate: String
    public var commands: [SoftCommand]
    /// Where anything unclear, unmatched or invalid goes. Typically a command
    /// bound to "pass this to the agent". Without one, those resolve to nothing.
    public var fallbackCommandId: String?
    /// Words that address the app rather than make a request — its name and
    /// how speech recognition mishears it ("Ripul", "Ripple"). Removed from
    /// `.utterance` text.
    public var addressWords: [String]

    public init(version: Int = CommandMap.currentVersion, id: String = UUID().uuidString, name: String,
                instructionsTemplate: String = CommandMap.defaultInstructionsTemplate,
                promptTemplate: String = CommandMap.defaultPromptTemplate,
                commands: [SoftCommand], fallbackCommandId: String? = nil, addressWords: [String] = []) {
        self.version = version
        self.id = id
        self.name = name
        self.instructionsTemplate = instructionsTemplate
        self.promptTemplate = promptTemplate
        self.commands = commands
        self.fallbackCommandId = fallbackCommandId
        self.addressWords = addressWords
    }

    public var enabledCommands: [SoftCommand] { commands.filter(\.isEnabled) }

    public func command(_ id: String) -> SoftCommand? { commands.first { $0.id == id } }

    /// The instructions template that measured best on the iOS 27 model.
    ///
    /// Deliberately states the command set and the fallback preference and
    /// nothing else. Every earlier addition that told the model what to WRITE
    /// was copied into its answers.
    public static let defaultInstructionsTemplate = """
    You route one spoken sentence to a single command in this app.

    Choose exactly one command:
    {{commands}}

    Prefer {{fallback}} over guessing: doing the wrong thing is worse than \
    passing the sentence on.
    """

    public static let defaultPromptTemplate = """
    {{entities}}
    Sentence: {{sentence}}
    """
}
