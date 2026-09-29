import Foundation
import Observation

/// One press of Run: the same sentence resolved `tries` times, grouped by
/// outcome, with the rules' answer alongside and exactly what the model was
/// sent. Codable, so it is also the file a test rig reads back.
public struct CommandLabRun: Codable, Equatable, Sendable, Identifiable {
    public struct Outcome: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var commandId: String?
        public var actionId: String?
        /// Parameter name → what filled it, readable: "Native slot… (s4)".
        public var inputs: [String: String]
        public var count: Int
        public var fellBack: Bool
        public var notes: [String]
        public var averageMilliseconds: Double
    }

    public var id: UUID
    public var date: Date
    public var sentence: String
    public var mode: CommandResolver.Mode
    public var tries: Int
    public var mapId: String
    public var mapName: String
    public var modelAvailable: Bool
    public var contextSize: Int?
    /// Distinct outcomes across the tries, most frequent first.
    public var outcomes: [Outcome]
    /// What the rules alone would do, for comparison.
    public var rules: Outcome
    public var instructions: String?
    public var prompt: String?
    /// Every raw decision, one per try, before correction.
    public var rawDecisions: [String]
    /// Set once the top outcome has been run for real.
    public var performed: String?

    /// Whether every try gave the same outcome. An unstable answer cannot be
    /// shipped in front of a person, however good it looks once.
    public var isStable: Bool { outcomes.count <= 1 }
}

/// The state behind the Lab screen, and its remote control.
///
/// Everything the screen can do is also reachable by URL (`handle(_:)`), and
/// every run is written to `lastRunFile`, so a person or an agent on another
/// machine can drive the Lab and read the result without touching the device.
@MainActor
@Observable
public final class CommandLab {
    public let resolver: CommandResolver
    public let store: CommandMapStore?
    public let defaultMap: CommandMap

    public var map: CommandMap
    public var sentence = ""
    public var mode: CommandResolver.Mode = .model
    public var tries = 3
    /// Resolve against `demoEntities` instead of the live sources, so a result
    /// is reproducible regardless of what the device holds right now.
    public var useDemoEntities = false
    public let demoEntities: [String: [CommandEntity]]

    public private(set) var isRunning = false
    public private(set) var run: CommandLabRun?
    public private(set) var status: String?

    /// A screen inside the Lab.
    public enum Route: Hashable, Identifiable, Sendable {
        case maps, commands, command(String), templates, appWords
        public var id: String {
            switch self {
            case .maps: return "maps"
            case .commands: return "commands"
            case .command(let name): return "command:\(name)"
            case .templates: return "templates"
            case .appWords: return "words"
            }
        }
    }

    /// The screen pushed over the Lab, or nil for the Lab itself.
    ///
    /// Navigation is state rather than a chain of system links so that it can
    /// be driven without touching the screen: measured on iOS 27, UI
    /// automation cannot press the navigation bar's back button (the glass
    /// platter button is not wired to a tappable control), so a rig that
    /// depended on it could go in but never come back out.
    public var route: Route?

    /// Resolutions behind `run.outcomes`, by outcome id, for running for real.
    private var resolutionsByOutcome: [String: CommandResolution] = [:]
    /// Where every run is also logged — the host routes it wherever its logs
    /// are readable remotely.
    private let log: @MainActor (String) -> Void

    /// What the host calls its live entry points, shown in the Lab — e.g.
    /// "Siri: \"Tell Ripul to …\" runs the matching command."
    public let liveDescription: String?

    public init(registry: CommandRegistry, defaultMap: CommandMap, store: CommandMapStore?,
                demoEntities: [String: [CommandEntity]] = [:],
                liveDescription: String? = nil,
                log: @escaping @MainActor (String) -> Void = { print("[INTENT-LAB] \($0)") }) {
        self.resolver = CommandResolver(registry: registry)
        self.store = store
        self.defaultMap = defaultMap
        self.demoEntities = demoEntities
        self.liveDescription = liveDescription
        self.log = log
        if let file = store?.directory.appendingPathComponent("live-settings.json"),
           let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode(LiveSettings.self, from: data) {
            self.live = saved
        }
        let active = store?.activeMap(orInstall: defaultMap) ?? defaultMap
        self.map = active
        self.maps = store?.loadAll() ?? [active]
    }

    public var registry: CommandRegistry { resolver.registry }

    // MARK: Maps

    /// Every saved map, by name. The one being edited and run is `map`.
    public private(set) var maps: [CommandMap] = []

    /// What is wrong with the active map, in words. Empty when it is sound.
    public var problems: [String] { map.problems(registry: registry) }

    /// Persist the active map. The screen calls this on every edit.
    public func saveMap() {
        do {
            try store?.save(map)
            try store?.setActiveMapId(map.id)
        } catch {
            status = "Could not save the map: \(error.localizedDescription)"
        }
        if let index = maps.firstIndex(where: { $0.id == map.id }) {
            maps[index] = map
        } else {
            maps.append(map)
        }
        maps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Make a saved map the one that is edited and run.
    public func activate(_ id: String) {
        guard let chosen = maps.first(where: { $0.id == id }), chosen.id != map.id else { return }
        map = chosen
        saveMap()
        status = "Using \(chosen.name)."
    }

    /// A new map, saved and made active. From the built-in default when
    /// `source` is nil; otherwise a copy of `source` under a new id.
    @discardableResult
    public func createMap(named name: String, from source: CommandMap? = nil) -> CommandMap {
        var created = source ?? defaultMap
        created.id = UUID().uuidString
        created.name = uniqueName(name)
        created.version = CommandMap.currentVersion
        map = created
        saveMap()
        status = "Created \(created.name)."
        return created
    }

    public func duplicateActiveMap() {
        createMap(named: "\(map.name) copy", from: map)
    }

    /// Delete a saved map. The last one cannot go: something has to be active.
    /// Deleting the active one switches to the next.
    public func deleteMap(_ id: String) {
        guard maps.count > 1 else {
            status = "The only map can't be deleted — reset it instead."
            return
        }
        try? store?.delete(id: id)
        maps.removeAll { $0.id == id }
        if map.id == id, let next = maps.first {
            map = next
            saveMap()
        }
    }

    /// Put the active map's commands, templates and app words back to the
    /// built-in default. Keeps its name and id, so it stays the same map.
    public func resetMap() {
        var reset = defaultMap
        reset.id = map.id
        reset.name = map.name
        map = reset
        saveMap()
        status = "\(map.name) reset to the default commands."
    }

    /// Import a map from JSON, as a NEW map: an import never overwrites one
    /// already here, so a bad paste cannot cost you a map you were tuning.
    @discardableResult
    public func importMap(_ data: Data) -> Bool {
        do {
            var imported = try CommandMapStore.decode(data)
            if maps.contains(where: { $0.id == imported.id }) { imported.id = UUID().uuidString }
            imported.name = uniqueName(imported.name)
            map = imported
            saveMap()
            status = "Imported \(imported.name)."
            return true
        } catch {
            status = "Import failed: \(error.localizedDescription)"
            return false
        }
    }

    public func exportMap() -> Data? { try? CommandMapStore.encode(map) }

    private func uniqueName(_ wanted: String) -> String {
        let base = wanted.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled map" : wanted
        let taken = Set(maps.map(\.name))
        guard taken.contains(base) else { return base }
        var number = 2
        while taken.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }

    // MARK: Live requests

    /// How requests from outside the Lab — Siri, a voice entry point — use
    /// the active map. Persisted beside the maps.
    public struct LiveSettings: Codable, Equatable, Sendable {
        public var isEnabled = true
        /// Rules first by default: instant and deterministic when a sentence
        /// plainly names a command, the model only when the rules would fall
        /// back — a live request has a person waiting on it.
        public var mode: CommandResolver.Mode = .rulesThenModel
        public init() {}
    }

    public var live = LiveSettings()
    public private(set) var lastLive: CommandLabRun?

    public var lastLiveFile: URL? { store?.directory.appendingPathComponent("live-last-run.json") }

    public func saveLive() {
        guard let file = store?.directory.appendingPathComponent("live-settings.json"),
              let data = try? JSONEncoder().encode(live) else { return }
        try? data.write(to: file, options: .atomic)
    }

    /// Resolve a live request against the active map, and record it where the
    /// Lab — and `lastLiveFile` — can show it. Nil when live routing is off.
    public func resolveLive(_ sentence: String) async -> CommandResolution? {
        guard live.isEnabled else { return nil }
        let snapshot = await resolver.snapshot(for: map)
        let resolution = await resolver.resolve(sentence, map: map, mode: live.mode, snapshot: snapshot)
        let ruled = resolver.resolveWithRules(sentence, map: map, snapshot: snapshot)
        var outcome = Self.outcome(resolution, key: Self.key(resolution), registry: registry)
        outcome.count = 1
        let run = CommandLabRun(
            id: UUID(), date: Date(), sentence: sentence, mode: live.mode, tries: 1,
            mapId: map.id, mapName: map.name,
            modelAvailable: CommandResolver.isModelAvailable, contextSize: CommandResolver.modelContextSize,
            outcomes: [outcome], rules: Self.outcome(ruled, key: Self.key(ruled), registry: registry),
            instructions: resolution.instructions, prompt: resolution.prompt,
            rawDecisions: [Self.describe(resolution)],
            performed: isAppAction(resolution) ? nil : "passed on — not a confident app command"
        )
        lastLive = run
        record(run, to: lastLiveFile, prefix: "live ")
        return resolution
    }

    /// Whether a resolution names one of the app's own commands with
    /// confidence, rather than landing on the fallback. A live entry point
    /// should act on these and keep its usual behaviour for everything else.
    public func isAppAction(_ resolution: CommandResolution) -> Bool {
        guard let commandId = resolution.commandId else { return false }
        return !resolution.fellBack && commandId != map.fallbackCommandId
    }

    /// Perform a live resolution. Returns whether the action ran.
    @discardableResult
    public func performLive(_ resolution: CommandResolution) async -> Bool {
        var ran = false
        do {
            try await resolver.perform(resolution)
            lastLive?.performed = "ran \(resolution.actionId ?? "nothing")"
            ran = true
        } catch {
            lastLive?.performed = "failed: \(error.localizedDescription)"
        }
        if let run = lastLive { record(run, to: lastLiveFile, prefix: "live ") }
        return ran
    }

    // MARK: Running

    public var lastRunFile: URL? { store?.directory.appendingPathComponent("lab-last-run.json") }

    public func runSentence() async {
        let sentence = self.sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sentence.isEmpty, !isRunning else { return }
        isRunning = true
        status = nil
        defer { isRunning = false }

        let snapshot = useDemoEntities
            ? CommandSnapshot(entities: demoEntities)
            : await resolver.snapshot(for: map)
        var resolutions: [CommandResolution] = []
        for _ in 0..<max(1, tries) {
            resolutions.append(await resolver.resolve(sentence, map: map, mode: mode, snapshot: snapshot))
        }
        let ruled = resolver.resolveWithRules(sentence, map: map, snapshot: snapshot)

        var grouped: [(outcome: CommandLabRun.Outcome, resolution: CommandResolution, total: Double)] = []
        for resolution in resolutions {
            let key = Self.key(resolution)
            let ms = Self.milliseconds(resolution.duration)
            if let index = grouped.firstIndex(where: { $0.outcome.id == key }) {
                grouped[index].outcome.count += 1
                grouped[index].total += ms
                for note in resolution.notes where !grouped[index].outcome.notes.contains(note) {
                    grouped[index].outcome.notes.append(note)
                }
            } else {
                grouped.append((Self.outcome(resolution, key: key, registry: registry), resolution, ms))
            }
        }
        grouped.sort { $0.outcome.count > $1.outcome.count }
        var outcomes: [CommandLabRun.Outcome] = []
        resolutionsByOutcome = [:]
        for var entry in grouped {
            entry.outcome.averageMilliseconds = entry.total / Double(entry.outcome.count)
            outcomes.append(entry.outcome)
            resolutionsByOutcome[entry.outcome.id] = entry.resolution
        }

        let run = CommandLabRun(
            id: UUID(), date: Date(), sentence: sentence, mode: mode, tries: resolutions.count,
            mapId: map.id, mapName: map.name,
            modelAvailable: CommandResolver.isModelAvailable, contextSize: CommandResolver.modelContextSize,
            outcomes: outcomes, rules: Self.outcome(ruled, key: Self.key(ruled), registry: registry),
            instructions: resolutions.compactMap(\.instructions).first,
            prompt: resolutions.compactMap(\.prompt).first,
            rawDecisions: resolutions.map(Self.describe),
            performed: nil
        )
        self.run = run
        record(run)
    }

    /// Run an outcome's action for real.
    public func perform(_ outcome: CommandLabRun.Outcome) async {
        guard let resolution = resolutionsByOutcome[outcome.id] else { return }
        do {
            try await resolver.perform(resolution)
            run?.performed = "ran \(outcome.actionId ?? "nothing")"
        } catch {
            run?.performed = "failed: \(error.localizedDescription)"
        }
        if let run { record(run) }
    }

    private func record(_ run: CommandLabRun) {
        record(run, to: lastRunFile, prefix: "")
    }

    private func record(_ run: CommandLabRun, to file: URL?, prefix: String) {
        if let file, let data = try? Self.encoder.encode(run) {
            try? data.write(to: file, options: .atomic)
        }
        let summary = run.outcomes.map { "\($0.commandId ?? "nothing") x\($0.count)/\(run.tries)" }.joined(separator: ", ")
        log("\(prefix)\"\(run.sentence)\" [\(run.mode.rawValue)] -> \(summary); rules: \(run.rules.commandId ?? "nothing")"
            + (run.performed.map { "; \($0)" } ?? ""))
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    // MARK: Remote control

    /// Drive the Lab by URL. Every parameter is optional; any scheme or host
    /// works, so the host app decides how the URL reaches here.
    ///
    ///   say=<sentence>        sentence to run (runs immediately)
    ///   tries=<1-10>          tries per run
    ///   mode=model|rules|rulesThenModel
    ///   demo=1|0              demo entities instead of the live sources
    ///   perform=1             run the top outcome for real afterwards
    ///   instructions=<text>   replace the instructions template
    ///   map=<base64url JSON>  import a map (as a new map) and make it active
    ///   activate=<map id>     make a saved map active
    ///   reset=1               reset the active map to the default commands
    ///   screen=root|maps|commands|command:<name>|templates|words
    ///                         show that screen of the Lab
    ///
    /// Returns once any requested run has finished, so a caller can read
    /// `lastRunFile` straight after.
    public func handle(_ url: URL) async {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        if let screen = value("screen") { route = Self.route(screen) }
        if let id = value("activate") { activate(id) }
        if value("reset") == "1" { resetMap() }
        if let encoded = value("map"), let data = Self.base64URLDecode(encoded) { importMap(data) }
        if let instructions = value("instructions"), !instructions.isEmpty {
            map.instructionsTemplate = instructions
            saveMap()
        }
        if let raw = value("mode"), let mode = CommandResolver.Mode(rawValue: raw) { self.mode = mode }
        if let raw = value("tries"), let tries = Int(raw) { self.tries = min(10, max(1, tries)) }
        if let demo = value("demo") { useDemoEntities = demo == "1" }
        if let say = value("say"), !say.isEmpty {
            sentence = say
            await runSentence()
            if value("perform") == "1", let top = run?.outcomes.first { await perform(top) }
        }
    }

    static func route(_ screen: String) -> Route? {
        switch screen {
        case "maps": return .maps
        case "commands": return .commands
        case "templates": return .templates
        case "words": return .appWords
        default:
            if screen.hasPrefix("command:") { return .command(String(screen.dropFirst("command:".count))) }
            return nil
        }
    }

    static func base64URLDecode(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }

    // MARK: Describing

    static func key(_ resolution: CommandResolution) -> String {
        let entities = resolution.values.entities.map { "\($0.key)=\($0.value.id)" }.sorted()
        let texts = resolution.values.texts.map { "\($0.key)=\($0.value)" }.sorted()
        return ([resolution.commandId ?? "nothing"] + entities + texts).joined(separator: "|")
    }

    static func outcome(_ resolution: CommandResolution, key: String, registry: CommandRegistry) -> CommandLabRun.Outcome {
        var inputs: [String: String] = [:]
        for (name, entity) in resolution.values.entities { inputs[name] = "\(entity.title) (\(entity.id))" }
        for (name, text) in resolution.values.texts { inputs[name] = "\"\(text)\"" }
        return CommandLabRun.Outcome(
            id: key, commandId: resolution.commandId, actionId: resolution.actionId, inputs: inputs,
            count: 1, fellBack: resolution.fellBack, notes: resolution.notes,
            averageMilliseconds: milliseconds(resolution.duration))
    }

    static func describe(_ resolution: CommandResolution) -> String {
        guard let decision = resolution.decision else { return "\(resolution.engine.rawValue): no decision" }
        var parts = ["\(resolution.engine.rawValue): \(decision.commandId)"]
        parts += decision.picks.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        if let text = decision.text, !text.isEmpty { parts.append("text=\"\(text)\"") }
        return parts.joined(separator: " ")
    }

    static func milliseconds(_ duration: Duration?) -> Double {
        guard let duration else { return 0 }
        return Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
}
