import Foundation

// MARK: - NativeTool Protocol
//
// Conform to this protocol to expose any native API as a tool the agent can call.

public protocol NativeTool {
    var name: String { get }
    var description: String { get }
    var inputSchema: [String: Any] { get }
    /// Timeout in seconds for this tool. `0` means no timeout (wait indefinitely).
    /// Default is `30`. Override per-tool for slower operations.
    var timeout: TimeInterval { get }
    func execute(args: [String: Any]) async throws -> Any
}

public extension NativeTool {
    var timeout: TimeInterval { 30 }

    /// MCP-formatted definition sent to the agent during discovery.
    var definition: [String: Any] {
        var def: [String: Any] = [
            "name": name,
            "description": description,
            "inputSchema": inputSchema,
        ]
        def["timeout"] = Int(timeout * 1000) // milliseconds for JS
        return def
    }

    // MARK: - Arg Extraction Helpers

    /// Extract a required string arg. Throws if missing or wrong type.
    func string(_ key: String, from args: [String: Any]) throws -> String {
        guard let value = args[key] as? String else {
            throw ToolError.invalidArgs("Missing required string parameter '\(key)'")
        }
        return value
    }

    /// Extract an optional string arg.
    func optionalString(_ key: String, from args: [String: Any]) -> String? {
        args[key] as? String
    }

    /// Extract a required ISO 8601 date arg. Throws if missing or unparseable.
    func date(_ key: String, from args: [String: Any]) throws -> Date {
        guard let str = args[key] as? String else {
            throw ToolError.invalidArgs("Missing required date parameter '\(key)'")
        }
        guard let date = ToolError.parseISO8601(str) else {
            throw ToolError.invalidArgs("Invalid ISO 8601 date for '\(key)': \(str)")
        }
        return date
    }

    /// Extract an optional ISO 8601 date arg. Returns nil if missing; throws if present but unparseable.
    func optionalDate(_ key: String, from args: [String: Any]) throws -> Date? {
        guard let str = args[key] as? String else { return nil }
        guard let date = ToolError.parseISO8601(str) else {
            throw ToolError.invalidArgs("Invalid ISO 8601 date for '\(key)': \(str)")
        }
        return date
    }

    /// Extract a bool arg with a default value.
    func bool(_ key: String, from args: [String: Any], default defaultValue: Bool = false) -> Bool {
        args[key] as? Bool ?? defaultValue
    }
}

public enum ToolError: LocalizedError {
    case invalidArgs(String)

    public var errorDescription: String? {
        switch self {
        case .invalidArgs(let message): return message
        }
    }

    /// Parse ISO 8601 dates flexibly (with or without fractional seconds).
    static func parseISO8601(_ string: String) -> Date? {
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFrac.date(from: string) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}

// MARK: - Type-Safe Schema Builder

/// Builds a JSON Schema `[String: Any]` dictionary with compile-time checked types.
///
/// Usage:
/// ```
/// let inputSchema = ToolSchema.object(
///     .string("title", "Event title", required: true),
///     .string("notes", "Optional notes"),
///     .bool("isAllDay", "All-day event")
/// )
/// ```
public enum ToolSchema {
    public struct Property {
        let name: String
        let type: String
        let description: String
        let isRequired: Bool

        public static func string(_ name: String, _ description: String, required: Bool = false) -> Property {
            Property(name: name, type: "string", description: description, isRequired: required)
        }

        public static func bool(_ name: String, _ description: String, required: Bool = false) -> Property {
            Property(name: name, type: "boolean", description: description, isRequired: required)
        }

        public static func number(_ name: String, _ description: String, required: Bool = false) -> Property {
            Property(name: name, type: "number", description: description, isRequired: required)
        }

        public static func integer(_ name: String, _ description: String, required: Bool = false) -> Property {
            Property(name: name, type: "integer", description: description, isRequired: required)
        }
    }

    public static func object(_ properties: Property...) -> [String: Any] {
        var props: [String: Any] = [:]
        var required: [String] = []

        for prop in properties {
            props[prop.name] = [
                "type": prop.type,
                "description": prop.description,
            ]
            if prop.isRequired {
                required.append(prop.name)
            }
        }

        var schema: [String: Any] = [
            "type": "object",
            "properties": props,
        ]
        if !required.isEmpty {
            schema["required"] = required
        }
        return schema
    }
}
