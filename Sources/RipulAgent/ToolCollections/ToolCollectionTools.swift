import Foundation

// ---------------------------------------------------------------------------
// DEV tools that let an agent reorganise tool collections, mirroring the
// on-device editor. Same move as `RipulDevThemeTools`: a human surface and an
// agent surface driving one mechanism, so "group all my calendar tools" works
// by asking instead of tapping.
//
// Semantics match the web app's `manageToolCollection` handler — these are a
// native front door to the same endpoints, not a second model of the domain.
//
// Writes are Clerk-authed, so these are only useful where a token exists:
// register them from the signed-in console. Gated by the host via
// `RipulDevToolCollectionTools.all(isEnabled:)`.
// ---------------------------------------------------------------------------

public enum RipulDevToolCollectionTools {
    /// All four tools, or none when disabled.
    ///
    /// - Parameters:
    ///   - isEnabled: host gate — these are development affordances and do not
    ///     belong in an end user's tool list.
    ///   - bridge: supplies the live tool set so listings can report how many
    ///     registered tools each collection actually captures.
    public static func all(
        isEnabled: Bool,
        bridge: AgentBridge,
        baseURL: URL = AgentConfiguration.defaultBaseURL,
        tokenProvider: @escaping () -> String?
    ) -> [NativeTool] {
        guard isEnabled else { return [] }
        let client = RipulToolCollectionsClient(baseURL: baseURL, tokenProvider: tokenProvider)
        return [
            RipulListToolCollectionsTool(client: client, bridge: bridge),
            RipulCreateToolCollectionTool(client: client),
            RipulUpdateToolCollectionTool(client: client),
            RipulDeleteToolCollectionTool(client: client),
        ]
    }
}

/// Shared description of the restart requirement — every write tool repeats it
/// because the agent otherwise reports success and the developer sees no change.
private let restartNote =
    "Takes effect when the app restarts: collections are resolved at session start."

// MARK: - list_tool_collections

public struct RipulListToolCollectionsTool: NativeTool {
    public var name: String { "list_tool_collections" }
    public var description: String {
        "List the account's tool collections (progressive-discovery categories), with each "
        + "collection's membership rules and how many of THIS app's registered tools it currently captures. "
        + "A collection is shown to the agent as one tool it expands on demand."
    }
    public var inputSchema: [String: Any] {
        ["type": "object", "properties": [:], "required": []]
    }

    let client: RipulToolCollectionsClient
    let bridge: AgentBridge

    @MainActor
    public func execute(args: [String: Any]) async throws -> Any {
        let toolNames = bridge.registeredToolSummaries.map(\.name)
        let collections = try await client.list(type: "category")
        return [
            "collections": collections.map { collection -> [String: Any] in
                let matcher = RipulToolCollectionMatcher(
                    explicitTools: collection.explicitTools,
                    toolPatterns: collection.toolPatterns,
                    toolNames: toolNames
                )
                return [
                    "id": collection.id,
                    "name": collection.name,
                    "label": collection.displayLabel,
                    "description": collection.description,
                    "mode": collection.mode,
                    "toolPatterns": collection.toolPatterns,
                    "explicitTools": collection.explicitTools,
                    "matchedTools": matcher.allMatches,
                    "matchedCount": matcher.matchCount,
                ]
            },
            "registeredToolCount": toolNames.count,
        ]
    }
}

// MARK: - create_tool_collection

public struct RipulCreateToolCollectionTool: NativeTool {
    public var name: String { "create_tool_collection" }
    public var description: String {
        "Create a progressive-discovery collection that collapses several tools into one entry "
        + "the agent expands on demand. Membership is the union of explicitTools and toolPatterns. "
        + "Prefer patterns where a naming convention exists — they absorb future tools automatically. "
        + restartNote
    }
    public var inputSchema: [String: Any] {
        ["type": "object",
         "required": ["name"],
         "properties": [
            "name": ["type": "string", "description": "Unique identifier, snake_case (e.g. calendar_tools)"],
            "label": ["type": "string", "description": "Label the agent sees. Defaults to name."],
            "description": ["type": "string", "description": "What these tools do together — the agent reads this to decide whether to expand."],
            "mode": ["type": "string", "enum": ["expand", "isolate"],
                     "description": "expand: tools join the current scope. isolate: a focused sub-agent runs with only these tools."],
            "prompt": ["type": "string", "description": "System prompt for the isolate-mode sub-agent."],
            "toolPatterns": ["type": "array", "items": ["type": "string"],
                             "description": "Regexes matched against tool names, e.g. ^calendar_. Match the registered name, not the host_-prefixed one."],
            "explicitTools": ["type": "array", "items": ["type": "string"],
                              "description": "Exact tool names to include."],
         ]]
    }

    let client: RipulToolCollectionsClient

    public func execute(args: [String: Any]) async throws -> Any {
        guard let name = args["name"] as? String, !name.isEmpty else {
            throw ToolError.invalidArgs("name is required")
        }
        let created = try await client.createCategory(name: name, edit: edit(from: args))
        return ["success": true, "id": created.id, "name": created.name, "note": restartNote]
    }
}

// MARK: - update_tool_collection

public struct RipulUpdateToolCollectionTool: NativeTool {
    public var name: String { "update_tool_collection" }
    public var description: String {
        "Update a tool collection's membership or presentation. Only supplied fields change; "
        + "arrays are REPLACED wholesale, so send the full intended list. Use list_tool_collections for ids. "
        + restartNote
    }
    public var inputSchema: [String: Any] {
        ["type": "object",
         "required": ["id"],
         "properties": [
            "id": ["type": "string", "description": "Collection id from list_tool_collections"],
            "label": ["type": "string"],
            "description": ["type": "string"],
            "mode": ["type": "string", "enum": ["expand", "isolate"]],
            "prompt": ["type": "string"],
            "toolPatterns": ["type": "array", "items": ["type": "string"],
                             "description": "Replaces the existing patterns entirely."],
            "explicitTools": ["type": "array", "items": ["type": "string"],
                              "description": "Replaces the existing picked tools entirely."],
         ]]
    }

    let client: RipulToolCollectionsClient

    public func execute(args: [String: Any]) async throws -> Any {
        guard let id = args["id"] as? String, !id.isEmpty else {
            throw ToolError.invalidArgs("id is required")
        }
        let updated = try await client.update(id: id, edit: edit(from: args))
        return ["success": true, "id": updated.id, "name": updated.name, "note": restartNote]
    }
}

// MARK: - delete_tool_collection

public struct RipulDeleteToolCollectionTool: NativeTool {
    public var name: String { "delete_tool_collection" }
    public var description: String {
        "Delete a tool collection. Its member tools are NOT deleted — they return to being "
        + "passed to the agent individually. " + restartNote
    }
    public var inputSchema: [String: Any] {
        ["type": "object",
         "required": ["id"],
         "properties": ["id": ["type": "string", "description": "Collection id from list_tool_collections"]]]
    }

    let client: RipulToolCollectionsClient

    public func execute(args: [String: Any]) async throws -> Any {
        guard let id = args["id"] as? String, !id.isEmpty else {
            throw ToolError.invalidArgs("id is required")
        }
        try await client.delete(id: id)
        return ["success": true, "id": id, "note": restartNote]
    }
}

// MARK: - Shared arg mapping

/// Map tool args onto an edit. Absent keys stay nil so an update leaves them
/// untouched — the agent must not have to resend fields it isn't changing.
private func edit(from args: [String: Any]) -> RipulToolCollectionEdit {
    RipulToolCollectionEdit(
        label: args["label"] as? String,
        description: args["description"] as? String,
        mode: args["mode"] as? String,
        prompt: args["prompt"] as? String,
        toolPatterns: args["toolPatterns"] as? [String],
        explicitTools: args["explicitTools"] as? [String]
    )
}
