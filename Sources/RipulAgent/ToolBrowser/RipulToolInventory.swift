import Foundation

/// A chat's tool inventory as the tool browser sees it: every progressive-
/// discovery category with its member tools, the chat's per-category switch,
/// what state the category is in right now, and the tools that belong to no
/// category. Parsed from the web's `__ripulGetChatToolInventory`.
///
/// This is a value type with no view logic so it can back any surface — the
/// session metadata panel today, a full-screen browser or a picker later.
public struct RipulToolInventory: Equatable {
    /// Where a tool executes. Encoded in the name prefix on the wire
    /// (`host_` / `device_`); surfaced here so views need not parse names.
    public enum Origin: String, Equatable {
        case host, device, web

        /// Vantage-free word. `host` depends on who computed the inventory —
        /// use `Tool.originLabel` for display.
        public var label: String {
            switch self {
            case .host: return "host"
            case .device: return "device"
            case .web: return "web"
            }
        }
    }

    /// What progressive discovery is doing with a category in this chat.
    public enum CategoryStatus: String, Equatable {
        /// Switched off for the chat — no stub, no tools reach the model.
        case hidden
        /// On, folded into a single stub the model can call to reveal the tools.
        case collapsed
        /// On and revealed — the member tools are in the model's list.
        case expanded

        public var label: String {
            switch self {
            case .hidden: return "hidden"
            case .collapsed: return "collapsed"
            case .expanded: return "expanded"
            }
        }
    }

    /// One parameter of a tool's JSON Schema, flattened for a native list.
    public struct Parameter: Identifiable, Equatable {
        public var id: String { name }
        public let name: String
        public let type: String
        public let description: String
        public let required: Bool
        public let enumValues: [String]
    }

    /// Which machine computed the inventory, and whether that is the chat's
    /// host (truth) or this device's own vantage (approximation).
    public struct Vantage: Equatable {
        public let machineId: String
        public let machineName: String
        /// Platform word for `host_` tools as seen from the computing machine.
        public let hostLabel: String
        /// True when fetched from the machine that hosts the chat.
        public let remote: Bool
        /// Set when the host could not be asked and this is a local fallback.
        public let fallback: String?
    }

    public struct Tool: Identifiable, Equatable {
        public var id: String { name }
        public let name: String
        public let description: String
        public let origin: Origin
        /// Origin as a word relative to the computing machine — `host_` tools
        /// are "macOS" when the Mac answered and "iPhone" when the phone did.
        public let originLabel: String
        /// True when the resolver served this exact name on its last list —
        /// false for members of a collapsed or hidden category.
        public let visibleNow: Bool
        /// Set for CATALOG-ONLY members: defined server-side but absent from
        /// this chat for a structural reason — `web-agent-only` (never opted in
        /// for CLI sessions), `abstract` (prompt-scoped), `no-handler`. Nil for
        /// a live tool. Description and schema are still real.
        public let absentReason: String?

        public var absentReasonLabel: String? {
            switch absentReason {
            case nil: return nil
            case "web-agent-only": return "web agent only"
            case "abstract": return "prompt-scoped"
            case "no-handler": return "no handler here"
            default: return "not available"
            }
        }
        /// The raw JSON Schema, pretty-printed with sorted keys.
        public let schemaJSON: String
        public let parameters: [Parameter]

        public static func == (lhs: Tool, rhs: Tool) -> Bool {
            lhs.name == rhs.name && lhs.visibleNow == rhs.visibleNow && lhs.schemaJSON == rhs.schemaJSON
        }
    }

    public struct Category: Identifiable, Equatable {
        public var id: String { name }
        public let name: String
        public let label: String
        public let description: String
        public let mode: String
        public var enabled: Bool
        public var status: CategoryStatus
        public let tools: [Tool]
        /// Declared members found in the catalog but structurally absent from
        /// this chat — openable, with `absentReason` set.
        public let catalogOnly: [Tool]
        /// Declared members (explicit names in the category definition) that did
        /// not resolve from the computing machine — shown greyed so an empty
        /// node still says what it is for.
        public let unresolvedDeclared: [String]
        /// Regex patterns the category also matches by; membership by pattern
        /// cannot be enumerated ahead of a tool existing.
        public let declaredPatterns: [String]
    }

    public let chatId: String
    public var categories: [Category]
    public let uncategorized: [Tool]
    public let resolvedNames: Set<String>
    public let vantage: Vantage?

    /// Names of every category currently switched off — what the write-back
    /// (`setChatToolCategories`) needs.
    public var disabledCategoryNames: [String] {
        categories.filter { !$0.enabled }.map(\.name).sorted()
    }

    public var totalToolCount: Int {
        categories.reduce(0) { $0 + $1.tools.count } + uncategorized.count
    }

    // MARK: - Parsing

    /// Parse the `__ripulGetChatToolInventory` payload. Returns nil when the
    /// shape is not recognisable (a webview that predates the callable).
    public static func parse(_ raw: [String: Any]) -> RipulToolInventory? {
        guard let chatId = raw["chatId"] as? String,
              let cats = raw["categories"] as? [[String: Any]] else { return nil }
        let resolved = Set((raw["resolvedNames"] as? [String]) ?? [])
        let vantage: Vantage? = (raw["vantage"] as? [String: Any]).map { v in
            Vantage(
                machineId: (v["machineId"] as? String) ?? "",
                machineName: (v["machineName"] as? String) ?? "",
                hostLabel: (v["hostLabel"] as? String) ?? "macOS",
                remote: (v["remote"] as? Bool) ?? false,
                fallback: v["fallback"] as? String
            )
        }
        let hostLabel = vantage?.hostLabel ?? "macOS"
        let categories: [Category] = cats.compactMap { c in
            guard let name = c["name"] as? String else { return nil }
            let tools = ((c["tools"] as? [[String: Any]]) ?? []).compactMap { parseTool($0, hostLabel: hostLabel) }
            let catalogOnly = ((c["catalogOnly"] as? [[String: Any]]) ?? []).compactMap { parseTool($0, hostLabel: hostLabel) }
            return Category(
                name: name,
                label: (c["label"] as? String) ?? name,
                description: (c["description"] as? String) ?? "",
                mode: (c["mode"] as? String) ?? "expand",
                enabled: (c["enabled"] as? Bool) ?? true,
                status: CategoryStatus(rawValue: (c["status"] as? String) ?? "") ?? .collapsed,
                tools: tools,
                catalogOnly: catalogOnly,
                unresolvedDeclared: (c["unresolvedDeclared"] as? [String]) ?? [],
                declaredPatterns: (c["declaredPatterns"] as? [String]) ?? []
            )
        }
        let uncategorized = ((raw["uncategorized"] as? [[String: Any]]) ?? []).compactMap { parseTool($0, hostLabel: hostLabel) }
        return RipulToolInventory(chatId: chatId, categories: categories, uncategorized: uncategorized, resolvedNames: resolved, vantage: vantage)
    }

    static func parseTool(_ t: [String: Any], hostLabel: String) -> Tool? {
        guard let name = t["name"] as? String else { return nil }
        let schema = (t["inputSchema"] as? [String: Any]) ?? [:]
        let origin = Origin(rawValue: (t["origin"] as? String) ?? "") ?? .web
        return Tool(
            name: name,
            description: (t["description"] as? String) ?? "",
            origin: origin,
            originLabel: origin == .host ? hostLabel : origin.label,
            visibleNow: (t["visibleNow"] as? Bool) ?? false,
            absentReason: t["absentReason"] as? String,
            schemaJSON: prettyJSON(schema),
            parameters: parseParameters(schema)
        )
    }

    static func prettyJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// Flatten `properties` / `required` into rows. Nested objects are shown
    /// by type only — the raw schema is one tap away for the full shape.
    static func parseParameters(_ schema: [String: Any]) -> [Parameter] {
        guard let props = schema["properties"] as? [String: Any] else { return [] }
        let required = Set((schema["required"] as? [String]) ?? [])
        return props.keys.sorted().compactMap { key in
            guard let def = props[key] as? [String: Any] else { return nil }
            var type: String
            if let t = def["type"] as? String {
                type = t
            } else if let ts = def["type"] as? [String] {
                type = ts.joined(separator: " | ")
            } else if def["enum"] != nil {
                type = "enum"
            } else if def["oneOf"] != nil || def["anyOf"] != nil {
                type = "union"
            } else {
                type = "any"
            }
            if type == "array", let items = def["items"] as? [String: Any], let it = items["type"] as? String {
                type = "\(it)[]"
            }
            let enumValues = ((def["enum"] as? [Any]) ?? []).map { "\($0)" }
            return Parameter(
                name: key,
                type: type,
                description: (def["description"] as? String) ?? "",
                required: required.contains(key),
                enumValues: enumValues
            )
        }
    }
}
