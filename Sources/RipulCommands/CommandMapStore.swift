import Foundation

public enum CommandMapError: Error, LocalizedError, Equatable {
    /// The map was written by a newer build than this one can read.
    case newerVersion(found: Int, supported: Int)

    public var errorDescription: String? {
        switch self {
        case .newerVersion(let found, let supported):
            return "This command map is version \(found); this app reads up to version \(supported)."
        }
    }
}

/// Command maps on disk: one JSON file per map, plus which one is active.
///
/// JSON rather than UserDefaults so a map is a file a person can export,
/// share, diff, commit next to their code and import on another device.
public struct CommandMapStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `Application Support/<name>/`, created if needed.
    public static func applicationSupport(named name: String = "RipulCommands") throws -> CommandMapStore {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let directory = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return CommandMapStore(directory: directory)
    }

    private var activeFile: URL { directory.appendingPathComponent("active-map-id") }

    private func file(for id: String) -> URL {
        let safe = id.replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent("\(safe).commandmap.json")
    }

    /// Every readable map, by name. A map from a newer build is skipped rather
    /// than half-read.
    public func loadAll() -> [CommandMap] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.lastPathComponent.hasSuffix(".commandmap.json") }
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? Self.decode($0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func save(_ map: CommandMap) throws {
        try Self.encode(map).write(to: file(for: map.id), options: .atomic)
    }

    public func delete(id: String) throws {
        try? FileManager.default.removeItem(at: file(for: id))
        if activeMapId == id { try? FileManager.default.removeItem(at: activeFile) }
    }

    public var activeMapId: String? {
        guard let data = try? Data(contentsOf: activeFile) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setActiveMapId(_ id: String?) throws {
        if let id {
            try Data(id.utf8).write(to: activeFile, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: activeFile)
        }
    }

    /// The active map, or `fallback` — which is saved and made active, so a
    /// first launch has something to edit.
    public func activeMap(orInstall fallback: CommandMap) -> CommandMap {
        if let id = activeMapId, let map = loadAll().first(where: { $0.id == id }) { return map }
        try? save(fallback)
        try? setActiveMapId(fallback.id)
        return fallback
    }

    // MARK: Portable JSON

    /// Stable output — sorted keys, pretty-printed — so two exports of the same
    /// map are byte-identical and a diff shows only what changed.
    public static func encode(_ map: CommandMap) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(map)
    }

    public static func decode(_ data: Data) throws -> CommandMap {
        struct Header: Decodable { let version: Int }
        let header = try JSONDecoder().decode(Header.self, from: data)
        guard header.version <= CommandMap.currentVersion else {
            throw CommandMapError.newerVersion(found: header.version, supported: CommandMap.currentVersion)
        }
        return try JSONDecoder().decode(CommandMap.self, from: data)
    }
}
