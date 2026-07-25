import Foundation

// MARK: - Output Schema Types

/// Rendering style hint for a single output field.
public enum OutputFieldStyle: String {
    case `default` = "default"
    case prominent = "prominent"
    case badge = "badge"
    case codeBlock = "codeBlock"
    case timestamp = "timestamp"
    case bytes = "bytes"
    case progressBar = "progressBar"

    /// Decode from string, falling back to `.default` for unknown values.
    public init(from string: String) {
        self = OutputFieldStyle(rawValue: string) ?? .default
    }
}

/// Layout mode for schema-driven result rendering.
public enum OutputLayout: String {
    case card = "card"
    case list = "list"
    case raw = "raw"

    /// Decode from string, falling back to `.card` for unknown values.
    public init(from string: String) {
        self = OutputLayout(rawValue: string) ?? .card
    }
}

/// Describes how a single field in the action result should render.
public struct OutputFieldDescriptor {
    public let key: String
    public let label: String?
    public let icon: String?
    public let style: OutputFieldStyle

    public init(key: String, label: String? = nil, icon: String? = nil, style: OutputFieldStyle = .default) {
        self.key = key
        self.label = label
        self.icon = icon
        self.style = style
    }

    public var toDict: [String: Any] {
        var dict: [String: Any] = ["key": key, "style": style.rawValue]
        if let label { dict["label"] = label }
        if let icon { dict["icon"] = icon }
        return dict
    }

    public init?(from dict: [String: Any]) {
        guard let key = dict["key"] as? String else { return nil }
        self.key = key
        self.label = dict["label"] as? String
        self.icon = dict["icon"] as? String
        self.style = OutputFieldStyle(from: dict["style"] as? String ?? "default")
    }
}

/// Describes how an action's result should be laid out.
public struct OutputSchema {
    public let layout: OutputLayout
    public let fields: [OutputFieldDescriptor]

    public init(layout: OutputLayout = .card, fields: [OutputFieldDescriptor] = []) {
        self.layout = layout
        self.fields = fields
    }

    public var toDict: [String: Any] {
        [
            "layout": layout.rawValue,
            "fields": fields.map { $0.toDict },
        ]
    }

    public init?(from dict: [String: Any]) {
        self.layout = OutputLayout(from: dict["layout"] as? String ?? "card")
        if let fieldDicts = dict["fields"] as? [[String: Any]] {
            self.fields = fieldDicts.compactMap { OutputFieldDescriptor(from: $0) }
        } else {
            self.fields = []
        }
    }

    /// Parse an OutputSchema from a result dict's "outputSchema" key.
    public static func fromResult(_ result: [String: Any]) -> OutputSchema? {
        guard let dict = result["outputSchema"] as? [String: Any] else { return nil }
        return OutputSchema(from: dict)
    }
}

// MARK: - Descriptor

/// Describes a single remotely-callable action exposed by a provider.
public struct RemoteActionDescriptor: Identifiable {
    public let id: String
    public let displayName: String
    public let description: String
    public let inputSchema: [String: Any]
    public let category: String
    public let icon: String?
    public let destructive: Bool
    public let timeout: TimeInterval  // seconds, default 30
    public let outputSchema: OutputSchema?
    public let resultView: String  // "native" | "html"
    public let emphasis: String    // "primary" (square tile) | "secondary" (compact row)

    public init(
        id: String,
        displayName: String,
        description: String,
        inputSchema: [String: Any] = ["type": "object", "properties": [:] as [String: Any]],
        category: String,
        icon: String? = nil,
        destructive: Bool = false,
        timeout: TimeInterval = 30,
        outputSchema: OutputSchema? = nil,
        resultView: String = "native",
        emphasis: String = "secondary"
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.inputSchema = inputSchema
        self.category = category
        self.icon = icon
        self.destructive = destructive
        self.timeout = timeout
        self.outputSchema = outputSchema
        self.resultView = resultView
        self.emphasis = emphasis
    }

    public var isPrimary: Bool { emphasis == "primary" }

    /// Serialize to a JSON-compatible dictionary for the relay protocol.
    public var toDict: [String: Any] {
        var dict: [String: Any] = [
            "id": id,
            "displayName": displayName,
            "description": description,
            "inputSchema": inputSchema,
            "category": category,
            "destructive": destructive,
            "timeout": Int(timeout * 1000),  // convert to ms for the wire
        ]
        if let icon { dict["icon"] = icon }
        if let outputSchema { dict["outputSchema"] = outputSchema.toDict }
        if resultView != "native" { dict["resultView"] = resultView }
        if emphasis != "secondary" { dict["emphasis"] = emphasis }
        return dict
    }

    /// Decode from a JSON dictionary (controller-side use on iOS).
    public init?(from dict: [String: Any]) {
        guard let id = dict["id"] as? String,
              let displayName = dict["displayName"] as? String,
              let description = dict["description"] as? String,
              let category = dict["category"] as? String else {
            return nil
        }
        self.id = id
        self.displayName = displayName
        self.description = description
        self.inputSchema = dict["inputSchema"] as? [String: Any] ?? ["type": "object", "properties": [:] as [String: Any]]
        self.category = category
        self.icon = dict["icon"] as? String
        self.destructive = dict["destructive"] as? Bool ?? false
        let timeoutMs = dict["timeout"] as? Int ?? 30_000
        self.timeout = TimeInterval(timeoutMs) / 1000.0
        if let schemaDict = dict["outputSchema"] as? [String: Any] {
            self.outputSchema = OutputSchema(from: schemaDict)
        } else {
            self.outputSchema = nil
        }
        self.resultView = dict["resultView"] as? String ?? "native"
        self.emphasis = dict["emphasis"] as? String ?? "secondary"
    }

    // MARK: - Cache

    private static let cacheKey = "ripulCachedRemoteActions"

    /// Load cached remote actions for a specific machine. Returns instantly from the cache.
    public static func loadCached(machineId: String, cache: RipulSessionCache) -> [RemoteActionDescriptor] {
        guard let allData = cache.data(forKey: cacheKey),
              let allDict = try? JSONSerialization.jsonObject(with: allData) as? [String: [[String: Any]]],
              let machineActions = allDict[machineId] else {
            return []
        }
        return machineActions.compactMap { RemoteActionDescriptor(from: $0) }
    }

    /// Load cached remote actions for all machines. Used to pre-populate state on init.
    public static func loadAllCached(cache: RipulSessionCache) -> [String: [RemoteActionDescriptor]] {
        guard let allData = cache.data(forKey: cacheKey),
              let allDict = try? JSONSerialization.jsonObject(with: allData) as? [String: [[String: Any]]] else {
            return [:]
        }
        var result: [String: [RemoteActionDescriptor]] = [:]
        for (machineId, actionDicts) in allDict {
            result[machineId] = actionDicts.compactMap { RemoteActionDescriptor(from: $0) }
        }
        return result
    }

    /// Save discovered remote actions for a machine to cache.
    public static func saveToCache(machineId: String, actions: [RemoteActionDescriptor], cache: RipulSessionCache) {
        var allDict: [String: [[String: Any]]] = [:]
        // Load existing cache
        if let allData = cache.data(forKey: cacheKey),
           let existing = try? JSONSerialization.jsonObject(with: allData) as? [String: [[String: Any]]] {
            allDict = existing
        }
        // Update this machine's actions
        allDict[machineId] = actions.map { $0.toDict }
        // Write back
        if let data = try? JSONSerialization.data(withJSONObject: allDict) {
            cache.set(data, forKey: cacheKey)
        }
    }
}

// MARK: - Provider Protocol

/// A provider that can discover and execute a category of remote actions.
@MainActor public protocol RemoteActionProvider {
    var category: String { get }
    func discoverActions() -> [RemoteActionDescriptor]
    func execute(actionId: String, params: [String: Any]) async throws -> [String: Any]
}

// MARK: - Errors

public enum RemoteActionError: LocalizedError {
    case unknownAction(String)
    case executionFailed(String)
    case timeout(String)

    public var errorDescription: String? {
        switch self {
        case .unknownAction(let id): return "Unknown action: \(id)"
        case .executionFailed(let msg): return "Action failed: \(msg)"
        case .timeout(let id): return "Action timed out: \(id)"
        }
    }
}
