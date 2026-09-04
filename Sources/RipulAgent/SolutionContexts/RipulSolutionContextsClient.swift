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
    /// `message` is always human-legible; `detail` carries the raw response
    /// body when the message had to summarise it (a proxy's HTML error page,
    /// long text) — UIs surface it behind an "Advanced" reveal with copy.
    case server(status: Int, message: String, detail: String?)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Sign in to manage solution contexts."
        case .malformedResponse: return "Unexpected response from the server."
        case .transport(let error): return error.localizedDescription
        case .server(let status, let message, _): return "Server error \(status): \(message)"
        }
    }

    /// The raw response body behind a summarised `.server` message, when the
    /// two differ. `nil` means the message already IS the whole story.
    public var serverDetail: String? {
        if case .server(_, _, let detail) = self { return detail }
        return nil
    }

    /// Builds `.server` from a non-2xx body. The API returns
    /// `{ "error": { "message": ... } }` (older paths `{ "error": "..." }`) —
    /// those messages pass through verbatim. Anything else — a proxy's HTML
    /// 502 page, plain text — is summarised (the page's `<title>`, or a
    /// truncated first chunk) with the raw body preserved as `detail`.
    static func serverError(status: Int, body: Data) -> RipulSolutionContextsError {
        let raw = String(data: body, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Pasteboard-sane cap; a Cloudflare error page is ~10-20 KB.
        let detail = raw.count > 16_000 ? String(raw.prefix(16_000)) + "\n… (truncated)" : raw
        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let nested = json["error"] as? [String: Any], let message = nested["message"] as? String {
                return .server(status: status, message: message, detail: raw == message ? nil : detail)
            }
            if let flat = json["error"] as? String {
                return .server(status: status, message: flat, detail: raw == flat ? nil : detail)
            }
        }
        if raw.isEmpty {
            return .server(status: status, message: "The server returned an empty response.", detail: nil)
        }
        if raw.hasPrefix("<") {
            let message = htmlTitle(in: raw).map { "The server returned an error page (\($0))." }
                ?? "The server returned an error page instead of an API response."
            return .server(status: status, message: message, detail: detail)
        }
        if raw.count > 200 {
            return .server(status: status, message: String(raw.prefix(200)) + "\u{2026}", detail: detail)
        }
        return .server(status: status, message: raw, detail: nil)
    }

    private static func htmlTitle(in html: String) -> String? {
        guard let open = html.range(of: "<title>", options: .caseInsensitive),
              let close = html.range(of: "</title>", options: .caseInsensitive, range: open.upperBound..<html.endIndex)
        else { return nil }
        let title = html[open.upperBound..<close.lowerBound]
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
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
            throw RipulSolutionContextsError.serverError(status: http.statusCode, body: data)
        }
        return data
    }
}
