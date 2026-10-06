import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The front door: resolve a sentence against a command map, by model or by
/// rules, and perform the result.
///
/// ```swift
/// let resolver = CommandResolver(registry: myRegistry)
/// let resolution = await resolver.resolve("open the chat about flickering", map: myMap)
/// try await resolver.perform(resolution)
/// ```
public struct CommandResolver: Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        /// The model decides; the rules stand in when it is unavailable or fails.
        case model
        /// Rules only. Instant and deterministic.
        case rules
        /// Rules first; the model is asked only when the rules would fall back.
        case rulesThenModel
    }

    public let registry: CommandRegistry
    /// Bounds a single model call. A spoken interaction that has not resolved
    /// in this long should fall back rather than leave someone at a silent mic.
    public var timeout: Duration

    public init(registry: CommandRegistry, timeout: Duration = .seconds(5)) {
        self.registry = registry
        self.timeout = timeout
    }

    public static var isModelAvailable: Bool { OnDeviceModel.isUsable }

    /// Why the model cannot be used, in words, or nil when it can.
    public static var modelUnavailableReason: String? { OnDeviceModel.unusableReason }

    /// The model's context window, when there is one. 4096 is the iOS 26
    /// generation; 8192 is iOS 27's.
    public static var modelContextSize: Int? {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *), OnDeviceModel.isUsable {
            return SystemLanguageModel.default.contextSize
        }
        #endif
        return nil
    }

    /// Pay the model load before someone speaks, not while they wait.
    public static func prewarm() {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *), OnDeviceModel.isUsable {
            LanguageModelSession().prewarm()
        }
        #endif
    }

    public func snapshot(for map: CommandMap) async -> CommandSnapshot {
        var entities: [String: [CommandEntity]] = [:]
        for source in registry.sources {
            entities[source.id] = await source.candidates()
        }
        return CommandSnapshot(entities: entities)
    }

    public func resolve(_ sentence: String, map: CommandMap, mode: Mode = .model,
                        snapshot given: CommandSnapshot? = nil) async -> CommandResolution {
        let snapshot: CommandSnapshot
        if let given { snapshot = given } else { snapshot = await self.snapshot(for: map) }
        switch mode {
        case .rules:
            return resolveWithRules(sentence, map: map, snapshot: snapshot)
        case .model:
            return await resolveWithModel(sentence, map: map, snapshot: snapshot)
        case .rulesThenModel:
            let ruled = resolveWithRules(sentence, map: map, snapshot: snapshot)
            guard ruled.fellBack || ruled.commandId == nil || ruled.commandId == map.fallbackCommandId else {
                return ruled
            }
            var modelled = await resolveWithModel(sentence, map: map, snapshot: snapshot)
            modelled.notes.insert("rules would have fallen back, so the model was asked", at: 0)
            return modelled
        }
    }

    public func resolveWithRules(_ sentence: String, map: CommandMap, snapshot: CommandSnapshot) -> CommandResolution {
        let start = ContinuousClock.now
        var resolution = CommandResolution(engine: .rules, sentence: sentence)
        if let decision = CommandRules.decide(sentence, map: map, registry: registry, snapshot: snapshot) {
            CommandBinder.bind(decision, into: &resolution, map: map, registry: registry, snapshot: snapshot)
        } else {
            resolution.notes.append("nothing was said")
        }
        resolution.duration = ContinuousClock.now - start
        return resolution
    }

    public func resolveWithModel(_ sentence: String, map: CommandMap, snapshot: CommandSnapshot) async -> CommandResolution {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            var empty = CommandResolution(engine: .model, sentence: sentence)
            empty.notes.append("nothing was said")
            return empty
        }
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *), OnDeviceModel.isUsable {
            return await ModelDecider(registry: registry, timeout: timeout)
                .resolve(trimmed, map: map, snapshot: snapshot)
        }
        #endif
        var ruled = resolveWithRules(trimmed, map: map, snapshot: snapshot)
        ruled.notes.insert("model unavailable (\(Self.modelUnavailableReason ?? "unknown")); used rules", at: 0)
        return ruled
    }

    /// Runs the resolved action. Does nothing for a resolution with no command.
    public func perform(_ resolution: CommandResolution) async throws {
        guard let actionId = resolution.actionId, let action = registry.action(actionId) else { return }
        try await action.perform(resolution.values)
    }
}

#if canImport(FoundationModels)
/// The model half. One constrained decode per sentence, built from the map at
/// call time — commands are defined at runtime, so the allowed answers cannot
/// be a compile-time `@Generable` type.
@available(iOS 26, macOS 26, *)
struct ModelDecider {
    let registry: CommandRegistry
    let timeout: Duration

    static let commandProperty = "command"
    static let textProperty = "text"
    static func pickProperty(_ sourceId: String) -> String { "\(sourceId)Number" }

    func resolve(_ sentence: String, map: CommandMap, snapshot: CommandSnapshot) async -> CommandResolution {
        let start = ContinuousClock.now
        var resolution = CommandResolution(engine: .model, sentence: sentence)
        let instructions = CommandPrompt.instructions(map: map)
        let prompt = CommandPrompt.prompt(sentence: sentence, map: map, registry: registry, snapshot: snapshot)
        resolution.instructions = instructions
        resolution.prompt = prompt

        do {
            let schema = try schema(for: map)
            let decision = try await withThrowingTaskGroup(of: CommandDecision?.self) { group in
                group.addTask {
                    let session = LanguageModelSession(instructions: Instructions(instructions))
                    let response = try await session.respond(to: prompt, schema: schema)
                    return try self.decision(from: response.content, map: map)
                }
                group.addTask {
                    try await Task.sleep(for: self.timeout)
                    return nil
                }
                let first = try await group.next() ?? nil
                group.cancelAll()
                return first
            }
            if let decision {
                CommandBinder.bind(decision, into: &resolution, map: map, registry: registry, snapshot: snapshot)
            } else {
                resolution.notes.append("model timed out after \(timeout); used rules")
                useRules(sentence, map: map, snapshot: snapshot, into: &resolution)
            }
        } catch {
            resolution.notes.append("model failed (\(error.localizedDescription)); used rules")
            useRules(sentence, map: map, snapshot: snapshot, into: &resolution)
        }
        resolution.duration = ContinuousClock.now - start
        return resolution
    }

    private func useRules(_ sentence: String, map: CommandMap, snapshot: CommandSnapshot,
                          into resolution: inout CommandResolution) {
        if let decision = CommandRules.decide(sentence, map: map, registry: registry, snapshot: snapshot) {
            CommandBinder.bind(decision, into: &resolution, map: map, registry: registry, snapshot: snapshot)
        }
    }

    /// Only the properties this map actually needs. Every extra field is one
    /// more thing a small model can fill with nonsense.
    func schema(for map: CommandMap) throws -> GenerationSchema {
        var ids = map.enabledCommands.map(\.id)
        if ids.isEmpty { ids = ["none"] }
        let commands = DynamicGenerationSchema(name: "Command", anyOf: ids)
        var properties: [DynamicGenerationSchema.Property] = [
            .init(name: Self.commandProperty, description: "Which command the person wants.",
                  schema: DynamicGenerationSchema(referenceTo: "Command")),
        ]
        for source in CommandPrompt.pickedSources(map: map, registry: registry) {
            properties.append(.init(
                name: Self.pickProperty(source.id),
                description: "For commands that need one: the number from the \(source.title) list. Otherwise 0.",
                schema: DynamicGenerationSchema(type: Int.self)))
        }
        if usesModelText(map) {
            properties.append(.init(
                name: Self.textProperty,
                description: "Only for commands that need text: the person's instruction, in their own words.",
                schema: DynamicGenerationSchema(type: String.self)))
        }
        return try GenerationSchema(root: DynamicGenerationSchema(name: "Decision", properties: properties),
                                    dependencies: [commands])
    }

    func usesModelText(_ map: CommandMap) -> Bool {
        map.enabledCommands.contains { $0.bindings.values.contains(.modelWrites) }
    }

    func decision(from content: GeneratedContent, map: CommandMap) throws -> CommandDecision {
        let commandId = try content.value(String.self, forProperty: Self.commandProperty)
        var picks: [String: Int] = [:]
        for source in CommandPrompt.pickedSources(map: map, registry: registry) {
            let number = try content.value(Int.self, forProperty: Self.pickProperty(source.id))
            if number > 0 { picks[source.id] = number }
        }
        let text = usesModelText(map) ? try content.value(String.self, forProperty: Self.textProperty) : nil
        return CommandDecision(commandId: commandId, picks: picks, text: text)
    }
}
#endif
