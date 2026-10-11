import Foundation

// The orchestrator: a hosted, tool-calling model that is handed the app's
// actions as tools and one sentence, and answers with the actions to run.
//
// WHY IT EXISTS BESIDE THE COMMAND MAP.
//
// The map is shaped by what the on-device model could be trusted with: one
// command from a closed list, a number into a list, and no text of its own.
// Everything a person might say has to be anticipated in the map's examples
// and descriptions, and a sentence that needs two things cannot be expressed
// at all. A model that calls tools needs none of that scaffolding. The action
// registry — layer 1, the code — is already a tool list: each action has a
// name, inputs and something it does. So the orchestrator is given the
// registry directly, and the map's commands, examples and bindings are not
// shown to it.
//
// WHAT DOES NOT CHANGE.
//
//   - One request, no loop, no history. The model answers once with every
//     action it wants, in order; nothing is fed back to it.
//   - Entities are still chosen by NUMBER from a list read at that moment, and
//     every number is still checked against that list.
//   - Anything that does not survive the check goes to the map's fallback,
//     whole. A plan is run completely or not at all.
//   - The model call itself is the host's: this package builds the request and
//     checks the reply, and a `Transport` the host supplies carries it. Nothing
//     here knows where the model lives or how the request is paid for.
//
// It is one more `CommandResolver.Mode`, beside the others, so it can be
// switched on for a try and off again without touching anything else.

// MARK: - What is sent, and what comes back

/// Everything the model is given for one sentence.
public struct OrchestratorRequest: Codable, Equatable, Sendable {
    /// One of the app's actions, as a tool.
    public struct Tool: Codable, Equatable, Sendable {
        public struct Input: Codable, Equatable, Sendable {
            public enum Kind: String, Codable, Sendable {
                /// A 1-based number into one of the lists.
                case number
                case text
            }

            public var name: String
            public var kind: Kind
            public var description: String
            public var isRequired: Bool

            public init(name: String, kind: Kind, description: String, isRequired: Bool) {
                self.name = name
                self.kind = kind
                self.description = description
                self.isRequired = isRequired
            }
        }

        public var name: String
        public var description: String
        public var inputs: [Input]

        public init(name: String, description: String, inputs: [Input] = []) {
            self.name = name
            self.description = description
            self.inputs = inputs
        }
    }

    public var sentence: String
    /// The numbered lists the tools choose from, as text.
    public var lists: String
    public var tools: [Tool]
    /// The tool to use when nothing else fits — the action behind the map's
    /// fallback command. Nil when the map has none.
    public var fallbackTool: String?
    /// How the app is addressed, and misheard: "Ripul", "Ripple".
    public var addressWords: [String]
    /// Where the person is in the app, when the host says.
    public var situation: String?
    /// Set when the same sentence is being resolved several times to see
    /// whether the answer varies. A transport with a cache in front of the
    /// model must then make a new call. Measured: Ripul's answers a repeat in
    /// about 20 ms from its gateway's cache, so without this five tries are
    /// one answer and four copies of it.
    public var fresh: Bool

    public init(sentence: String, lists: String, tools: [Tool], fallbackTool: String? = nil,
                addressWords: [String] = [], situation: String? = nil, fresh: Bool = false) {
        self.sentence = sentence
        self.lists = lists
        self.tools = tools
        self.fallbackTool = fallbackTool
        self.addressWords = addressWords
        self.situation = situation
        self.fresh = fresh
    }
}

/// The model's answer, before it is checked against reality.
public struct OrchestratorReply: Codable, Equatable, Sendable {
    public struct Call: Codable, Equatable, Sendable {
        /// The tool, which is an action id.
        public var name: String
        /// Input name → the number chosen from that input's list.
        public var numbers: [String: Int]
        /// Input name → text the model wrote.
        public var texts: [String: String]

        public init(name: String, numbers: [String: Int] = [:], texts: [String: String] = [:]) {
            self.name = name
            self.numbers = numbers
            self.texts = texts
        }
    }

    /// In the order they should run.
    public var calls: [Call]
    /// Which model answered, and how long it took where it ran — so a measured
    /// time can be split into the model and the journey to it.
    public var model: String?
    public var milliseconds: Int?

    public init(calls: [Call], model: String? = nil, milliseconds: Int? = nil) {
        self.calls = calls
        self.model = model
        self.milliseconds = milliseconds
    }
}

/// The host's route to a tool-calling model.
public struct CommandOrchestrator: Sendable {
    /// Carries one request to the model and brings back its answer. Throwing —
    /// offline, signed out, a server error — sends the sentence to the
    /// resolver that was live before the orchestrator existed.
    public typealias Transport = @Sendable (OrchestratorRequest) async throws -> OrchestratorReply

    public let transport: Transport
    /// The most actions one sentence may run. A longer answer is not trimmed:
    /// running the first three of five is not what was asked for.
    public var maxSteps: Int
    /// The most entries listed from any one source. The lists arrive most
    /// recent first, so what is cut is what is least likely to be meant.
    public var maxListed: Int

    public init(maxSteps: Int = 3, maxListed: Int = 150, transport: @escaping Transport) {
        self.maxSteps = maxSteps
        self.maxListed = maxListed
        self.transport = transport
    }
}

// MARK: - Rendering what the model is sent

public enum OrchestratorPrompt {
    /// Sources some action chooses from, in registry order.
    static func listedSources(registry: CommandRegistry) -> [EntitySource] {
        var ids = Set<String>()
        for action in registry.actions {
            for parameter in action.parameters {
                if case .entity(let sourceId) = parameter.kind { ids.insert(sourceId) }
            }
        }
        return registry.sources.filter { ids.contains($0.id) }
    }

    public static func tools(registry: CommandRegistry) -> [OrchestratorRequest.Tool] {
        registry.actions.map { action in
            OrchestratorRequest.Tool(
                name: action.id,
                description: action.description ?? action.title,
                inputs: action.parameters.map { parameter in
                    switch parameter.kind {
                    case .entity(let sourceId):
                        let list = registry.source(sourceId)?.title ?? sourceId
                        return .init(name: parameter.name, kind: .number,
                                     description: parameter.description ?? "The number of the entry in the \(list) list.",
                                     isRequired: parameter.isRequired)
                    case .text:
                        return .init(name: parameter.name, kind: .text,
                                     description: parameter.description ?? "Text, in the person's own words.",
                                     isRequired: parameter.isRequired)
                    }
                })
        }
    }

    public static func lists(registry: CommandRegistry, snapshot: CommandSnapshot, limit: Int) -> String {
        listedSources(registry: registry).map { source in
            let candidates = snapshot.candidates(source.id).prefix(limit)
            guard !candidates.isEmpty else { return "\(source.title): none." }
            return ([source.title + ":"] + candidates.enumerated().map { "\($0.offset + 1). \($0.element.title)" })
                .joined(separator: "\n")
        }.joined(separator: "\n")
    }

    public static func request(sentence: String, map: CommandMap, registry: CommandRegistry,
                               snapshot: CommandSnapshot, limit: Int, fresh: Bool = false) -> OrchestratorRequest {
        let fallback = map.fallbackCommandId.flatMap(map.command)
            .flatMap { $0.isEnabled ? registry.action($0.actionId)?.id : nil }
        return OrchestratorRequest(sentence: sentence,
                                   lists: lists(registry: registry, snapshot: snapshot, limit: limit),
                                   tools: tools(registry: registry),
                                   fallbackTool: fallback,
                                   addressWords: map.addressWords,
                                   situation: snapshot.situation,
                                   fresh: fresh)
    }

    /// The tools as a person reads them, for the Lab's record of what was sent.
    public static func describe(_ tools: [OrchestratorRequest.Tool]) -> String {
        tools.map { tool in
            let inputs = tool.inputs.map { input in
                "\n    \(input.name) (\(input.kind.rawValue)\(input.isRequired ? "" : ", optional")): \(input.description)"
            }.joined()
            return "- \(tool.name): \(tool.description)\(inputs)"
        }.joined(separator: "\n")
    }
}

// MARK: - Checking a reply against reality

/// Turns the orchestrator's answer into steps, or abandons all of it for the
/// map's fallback. The same door as `CommandBinder`, for a reply that can name
/// several actions.
public enum OrchestratorBinder {
    public static func bind(_ reply: OrchestratorReply, into resolution: inout CommandResolution,
                            map: CommandMap, registry: CommandRegistry, snapshot: CommandSnapshot,
                            maxSteps: Int = 3, maxListed: Int = 150) {
        resolution.reply = reply
        switch steps(for: reply, registry: registry, snapshot: snapshot, maxSteps: maxSteps,
                     maxListed: maxListed, notes: &resolution.notes) {
        case .success(let steps):
            resolution.commandId = commandId(for: steps[0].actionId, map: map)
            resolution.actionId = steps[0].actionId
            resolution.values = steps[0].values
            resolution.laterSteps = Array(steps.dropFirst())
        case .failure(let failure):
            resolution.notes.append(failure.reason)
            CommandBinder.fallBack(into: &resolution, abandoning: nil, text: nil,
                                   map: map, registry: registry, snapshot: snapshot)
        }
    }

    struct Failure: Error { let reason: String }

    static func steps(for reply: OrchestratorReply, registry: CommandRegistry, snapshot: CommandSnapshot,
                      maxSteps: Int, maxListed: Int, notes: inout [String]) -> Result<[CommandStep], Failure> {
        guard !reply.calls.isEmpty else { return .failure(.init(reason: "the orchestrator chose no action")) }
        guard reply.calls.count <= maxSteps else {
            return .failure(.init(reason: "\(reply.calls.count) actions is more than the \(maxSteps) one sentence may run"))
        }
        var steps: [CommandStep] = []
        for call in reply.calls {
            guard let action = registry.action(call.name) else {
                return .failure(.init(reason: "\"\(call.name)\" is not one of this app's actions"))
            }
            var values = ActionValues()
            for parameter in action.parameters {
                switch parameter.kind {
                case .entity(let sourceId):
                    // Zero is how a model says "none" for an optional number.
                    if let number = call.numbers[parameter.name], number != 0 {
                        // Only what was listed can be chosen. A number past the
                        // end is not trimmed to a neighbour or dropped: the
                        // model meant something, and it is not known what.
                        let candidates = Array(snapshot.candidates(sourceId).prefix(maxListed))
                        guard candidates.indices.contains(number - 1) else {
                            return .failure(.init(reason: "\(call.name): \(sourceId) number \(number) is out of range (\(candidates.count) listed)"))
                        }
                        values.entities[parameter.name] = candidates[number - 1]
                    } else if parameter.isRequired {
                        return .failure(.init(reason: "\(call.name): required input \"\(parameter.name)\" was not given"))
                    }
                case .text:
                    let written = (call.texts[parameter.name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !written.isEmpty {
                        values.texts[parameter.name] = written
                    } else if parameter.isRequired {
                        return .failure(.init(reason: "\(call.name): required input \"\(parameter.name)\" was not given"))
                    }
                }
            }
            let known = Set(action.parameters.map(\.name))
            for name in Set(call.numbers.keys).union(call.texts.keys).subtracting(known).sorted() {
                notes.append("\(call.name): ignored \"\(name)\", which \(action.title) doesn't take")
            }
            steps.append(CommandStep(actionId: action.id, values: values))
        }
        return .success(steps)
    }

    /// The map's name for an action, so a live entry point can tell the
    /// fallback from an app command exactly as it does for the other
    /// resolvers. The action id when the map has no command for it — an action
    /// only the orchestrator can reach.
    static func commandId(for actionId: String, map: CommandMap) -> String {
        if let fallback = map.fallbackCommandId.flatMap(map.command), fallback.actionId == actionId {
            return fallback.id
        }
        return map.enabledCommands.first { $0.actionId == actionId }?.id ?? actionId
    }
}
