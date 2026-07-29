import Foundation

// ---------------------------------------------------------------------------
// Native client for the SOLUTION CONTEXTS admin API — the peer of
// `RipulToolCollectionsClient`, same auth model (developer's Clerk token, the
// same-origin `/api/*` proxy to llm-proxy).
//
// A solution context is the ONE context concept: server-side, it selects a
// session's tool whitelist and prompt. There is deliberately no native-only
// "context" — creating one here creates it for the dashboard, the console,
// and the app's site key alike (native-tool-registry decision 1: dev is not
// a snowflake).
// ---------------------------------------------------------------------------

/// A solution context as the admin API returns it. Response-only fields
/// (`expandedIncludedTools`, `systemPromptContent`) are read, never written.
public struct RipulSolutionContext: Identifiable, Hashable {
    public let id: String
    public var name: String
    public var description: String?
    public var icon: String?
    public var includedTools: [String]
    public var excludedTools: [String]
    public let expandedIncludedTools: [String]?
    public let isBuiltIn: Bool
    public let createdBy: String?
    /// Reference to the context's SystemPrompt entity, if any.
    public let systemPromptId: String?
    /// Resolved prompt content (response-only; saving goes through the
    /// system-prompts CRUD, see `RipulSolutionContextsClient`).
    public let systemPromptContent: String?

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String, let name = json["name"] as? String else { return nil }
        self.id = id
        self.name = name
        self.description = json["description"] as? String
        self.icon = json["icon"] as? String
        self.includedTools = json["includedTools"] as? [String] ?? []
        self.excludedTools = json["excludedTools"] as? [String] ?? []
        self.expandedIncludedTools = json["expandedIncludedTools"] as? [String]
        self.isBuiltIn = json["isBuiltIn"] as? Bool ?? false
        self.createdBy = json["createdBy"] as? String
        self.systemPromptId = json["systemPromptId"] as? String
        self.systemPromptContent = json["systemPromptContent"] as? String
    }

    /// The seeded per-account pair (`sc_<hash12>_user` / `sc_<hash12>_dev`) —
    /// editable and deletable like any context (a starting point, not a
    /// fixture), but worth badging so the developer knows where it came from.
    public var isSeeded: Bool {
        id.range(of: "^sc_[a-z0-9]{12}_(user|dev)$", options: .regularExpression) != nil
    }
}

public enum RipulSolutionContextsError: LocalizedError {
    case notSignedIn
    case malformedResponse
    case transport(Error)
    case server(status: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Sign in to manage solution contexts."
        case .malformedResponse: return "Unexpected response from the server."
        case .transport(let error): return error.localizedDescription
        case .server(let status, let message): return "Server error \(status): \(message)"
        }
    }
}

public final class RipulSolutionContextsClient {
    private let baseURL: URL
    private let tokenProvider: () -> String?

    public init(
        baseURL: URL = AgentConfiguration.defaultBaseURL,
        tokenProvider: @escaping () -> String?
    ) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
    }

    public func list() async throws -> [RipulSolutionContext] {
        let data = try await send(path: "api/admin/solution-contexts", method: "GET", body: nil)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["solutionContexts"] as? [[String: Any]] else {
            throw RipulSolutionContextsError.malformedResponse
        }
        return rows.compactMap(RipulSolutionContext.init(json:))
    }

    public func create(
        name: String,
        description: String?,
        includedTools: [String],
        excludedTools: [String],
        systemPromptId: String? = nil
    ) async throws -> RipulSolutionContext {
        var body: [String: Any] = ["name": name, "includedTools": includedTools, "excludedTools": excludedTools]
        if let description, !description.isEmpty { body["description"] = description }
        if let systemPromptId { body["systemPromptId"] = systemPromptId }
        let data = try await send(path: "api/admin/solution-contexts", method: "POST", body: body)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let context = RipulSolutionContext(json: json) else {
            throw RipulSolutionContextsError.malformedResponse
        }
        return context
    }

    public func update(
        id: String,
        name: String,
        description: String?,
        includedTools: [String],
        excludedTools: [String],
        systemPromptId: String? = nil
    ) async throws -> RipulSolutionContext {
        var body: [String: Any] = [
            "name": name,
            "description": description ?? "",
            "includedTools": includedTools,
            "excludedTools": excludedTools,
        ]
        if let systemPromptId { body["systemPromptId"] = systemPromptId }
        let data = try await send(path: "api/admin/solution-contexts/\(encode(id))", method: "PATCH", body: body)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let context = RipulSolutionContext(json: json) else {
            throw RipulSolutionContextsError.malformedResponse
        }
        return context
    }

    public func delete(id: String) async throws {
        _ = try await send(path: "api/admin/solution-contexts/\(encode(id))", method: "DELETE", body: nil)
    }

    // MARK: - System prompts (the context's prompt is a referenced entity)

    /// Create a SystemPrompt and return its id — the editor names it after the
    /// context ("<name> prompt") so the dashboard list stays legible.
    public func createSystemPrompt(name: String, content: String) async throws -> String {
        let data = try await send(
            path: "api/admin/system-prompts",
            method: "POST",
            body: ["name": name, "content": content]
        )
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String else {
            throw RipulSolutionContextsError.malformedResponse
        }
        return id
    }

    public func updateSystemPrompt(id: String, content: String) async throws {
        _ = try await send(
            path: "api/admin/system-prompts/\(encode(id))",
            method: "PATCH",
            body: ["content": content]
        )
    }

    private func encode(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
    }

    private func send(path: String, method: String, body: [String: Any]?) async throws -> Data {
        guard let token = tokenProvider(), !token.isEmpty else {
            throw RipulSolutionContextsError.notSignedIn
        }
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw RipulSolutionContextsError.malformedResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw RipulSolutionContextsError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw RipulSolutionContextsError.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0["error"] as? String }
                ?? String(data: data, encoding: .utf8) ?? ""
            throw RipulSolutionContextsError.server(status: http.statusCode, message: message)
        }
        return data
    }
}
