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
    ///   - catalogs: the app's tool surfaces, evaluated lazily because the
    ///     developer catalog is derived from a live bridge. Listings report
    ///     membership per catalog: a collection can span surfaces, and one
    ///     number could never say which agent it actually economises.
    public static func all(
        isEnabled: Bool,
        catalogs: @escaping () -> [RipulToolCatalog],
        baseURL: URL = AgentConfiguration.defaultBaseURL,
        tokenProvider: @escaping () -> String?
    ) -> [NativeTool] {
        guard isEnabled else { return [] }
        let client = RipulToolCollectionsClient(baseURL: baseURL, tokenProvider: tokenProvider)
        return [
            RipulListToolCollectionsTool(client: client, catalogs: catalogs),
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
        "List the account's tool collections (progressive-discovery categories) with their "
        + "membership rules, and how each one maps onto this app's tool surfaces. "
        + "The app has more than one surface — the end-user agent's tools and the in-app dev "
        + "agent's tools are separate sets — so membership is reported per surface. "
        + "A collection is shown to an agent as one tool it expands on demand."
    }
    public var inputSchema: [String: Any] {
        ["type": "object", "properties": [:], "required": []]
    }

    let client: RipulToolCollectionsClient
    let catalogs: () -> [RipulToolCatalog]

    @MainActor
    public func execute(args: [String: Any]) async throws -> Any {
        let surfaces = catalogs()
        let collections = try await client.list(type: "category")
        return [
            "collections": collections.map { collection -> [String: Any] in
                // Per-surface, because a collection can span them. Reporting a
                // single count against one surface is what made every
                // collection look empty when the wrong one was consulted.
                var perSurface: [[String: Any]] = []
                var accountedFor = Set<String>()
                for surface in surfaces {
                    let matcher = RipulToolCollectionMatcher(
                        explicitTools: collection.explicitTools,
                        toolPatterns: collection.toolPatterns,
                        toolNames: surface.toolNames
                    )
                    matcher.presentMatches.forEach { accountedFor.insert(RipulToolCollectionMatcher.canonicalName($0)) }
                    perSurface.append([
                        "surface": surface.name,
                        "surfaceId": surface.id,
                        "tools": matcher.presentMatches,
                        "count": matcher.presentCount,
                    ])
                }
                let elsewhere = collection.explicitTools.filter {
                    !$0.hasPrefix("group://")
                    && !accountedFor.contains(RipulToolCollectionMatcher.canonicalName($0))
                }
                return [
                    "id": collection.id,
                    "name": collection.name,
                    "label": collection.displayLabel,
                    "description": collection.description,
                    "mode": collection.mode,
                    "toolPatterns": collection.toolPatterns,
                    "explicitTools": collection.explicitTools,
                    "bySurface": perSurface,
                    // Members native to no surface here: web app tools, or
                    // tools belonging to another device.
                    "membersNotNativeHere": elsewhere,
                ]
            },
            "surfaces": surfaces.map { ["id": $0.id, "name": $0.name, "purpose": $0.purpose, "toolCount": $0.tools.count] },
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
