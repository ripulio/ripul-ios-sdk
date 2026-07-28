import Foundation

// ---------------------------------------------------------------------------
// Tool collections — the data behind progressive discovery.
//
// A *category* collection collapses N registered tools into one CategoryTool
// the agent expands on demand. Membership is the UNION of `explicitTools` and
// `toolPatterns`, matched against the tool name the app registered (the
// `host_` / `web_tool_` transport prefixes are stripped upstream of matching,
// so the names here are canonical).
//
// Writes are Clerk-authed. The site-key path is deliberately read-only —
// site keys ship inside the app binary, so a write-capable one would let any
// extracted key rewrite the account's collections. That is why this client
// takes a token provider and lives behind the signed-in console.
// ---------------------------------------------------------------------------

/// A tool collection as returned by `/v1/tool-collections`.
public struct RipulToolCollection: Codable, Identifiable, Hashable {
    public var id: String
    public var name: String
    /// `"category"` (progressive discovery) or `"group"` (a named set referenced
    /// elsewhere as `group://name`). This editor manages categories.
    public var type: String
    public var label: String
    public var description: String
    /// `"expand"` (tools join the current scope) or `"isolate"` (focused sub-agent).
    public var mode: String
    /// System prompt for the isolate-mode sub-agent, when set.
    public var prompt: String?
    public var toolPatterns: [String]
    public var explicitTools: [String]
    public var siteKeyId: String?
    public var createdAt: String
    public var updatedAt: String

    public var isCategory: Bool { type == "category" }
    public var isIsolate: Bool { mode == "isolate" }

    /// What the agent sees as the collection's name.
    public var displayLabel: String { label.isEmpty ? name : label }
}

/// Fields to write on create/update. Nil means "leave unchanged" on update.
public struct RipulToolCollectionEdit {
    public var name: String?
    public var label: String?
    public var description: String?
    public var mode: String?
    public var prompt: String?
    public var toolPatterns: [String]?
    public var explicitTools: [String]?

    public init(
        name: String? = nil,
        label: String? = nil,
        description: String? = nil,
        mode: String? = nil,
        prompt: String? = nil,
        toolPatterns: [String]? = nil,
        explicitTools: [String]? = nil
    ) {
        self.name = name
        self.label = label
        self.description = description
        self.mode = mode
        self.prompt = prompt
        self.toolPatterns = toolPatterns
        self.explicitTools = explicitTools
    }

    var body: [String: Any] {
        var out: [String: Any] = [:]
        if let name { out["name"] = name }
        if let label { out["label"] = label }
        if let description { out["description"] = description }
        if let mode { out["mode"] = mode }
        if let prompt { out["prompt"] = prompt }
        if let toolPatterns { out["toolPatterns"] = toolPatterns }
        if let explicitTools { out["explicitTools"] = explicitTools }
        return out
    }
}

public enum RipulToolCollectionsError: LocalizedError {
    case notSignedIn
    /// Non-2xx. Carries the server's message — the API validates regex
    /// compilability and name uniqueness, and its wording is better than
    /// anything this client could synthesize.
    case server(status: Int, message: String)
    case transport(Error)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Not signed in to Ripul."
        case .server(let status, let message):
            return message.isEmpty ? "Request failed (HTTP \(status))." : message
        case .transport(let error):
            return error.localizedDescription
        case .malformedResponse:
            return "The server returned an unexpected response."
        }
    }
}

/// CRUD over `/v1/tool-collections`, reached through the web app's API proxy
/// (`<baseURL>/api/*` → llm-proxy) exactly as `MachineDirectory` and
/// `BuildFeed` do.
public final class RipulToolCollectionsClient {
    private let baseURL: URL
    private let tokenProvider: () -> String?

    /// - Parameter tokenProvider: supplies the Clerk token. Pass the console's
    ///   `{ authStore.token }` — the same closure its other sub-components take.
    public init(
        baseURL: URL = AgentConfiguration.defaultBaseURL,
        tokenProvider: @escaping () -> String?
    ) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
    }

    /// All collections of `type`, or every collection when nil.
    public func list(type: String? = nil) async throws -> [RipulToolCollection] {
        var path = "api/v1/tool-collections"
        if let type { path += "?type=\(type)" }
        let data = try await send(path: path, method: "GET", body: nil)
        struct ListResponse: Decodable { let collections: [RipulToolCollection] }
        guard let decoded = try? JSONDecoder().decode(ListResponse.self, from: data) else {
            throw RipulToolCollectionsError.malformedResponse
        }
        return decoded.collections
    }

    /// Create a category. `siteKeyId` is intentionally not settable here:
    /// a collection with the wrong site-key scope is silently excluded from the
    /// interceptor's scoped fetch, with no error anywhere — the failure that
    /// once hid `iphone_inspect` from every CLI session. New collections are
    /// account-global.
    public func createCategory(
        name: String,
        edit: RipulToolCollectionEdit
    ) async throws -> RipulToolCollection {
        var body = edit.body
        body["name"] = name
        body["type"] = "category"
        body["siteKeyId"] = "__global__"
        let data = try await send(path: "api/v1/tool-collections", method: "POST", body: body)
        guard let decoded = try? JSONDecoder().decode(RipulToolCollection.self, from: data) else {
            throw RipulToolCollectionsError.malformedResponse
        }
        return decoded
    }

    public func update(id: String, edit: RipulToolCollectionEdit) async throws -> RipulToolCollection {
        let data = try await send(
            path: "api/v1/tool-collections/\(encode(id))",
            method: "PATCH",
            body: edit.body
        )
        guard let decoded = try? JSONDecoder().decode(RipulToolCollection.self, from: data) else {
            throw RipulToolCollectionsError.malformedResponse
        }
        return decoded
    }

    public func delete(id: String) async throws {
        _ = try await send(path: "api/v1/tool-collections/\(encode(id))", method: "DELETE", body: nil)
    }

    // MARK: - Transport

    private func send(path: String, method: String, body: [String: Any]?) async throws -> Data {
        guard let token = tokenProvider(), !token.isEmpty else {
            throw RipulToolCollectionsError.notSignedIn
        }

        // `path` already carries a query string on list(), which
        // appendingPathComponent would percent-escape into the path.
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw RipulToolCollectionsError.malformedResponse
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
            throw RipulToolCollectionsError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw RipulToolCollectionsError.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw RipulToolCollectionsError.server(
                status: http.statusCode,
                message: Self.errorMessage(from: data)
            )
        }
        return data
    }

    /// The API returns `{ "error": "..." }` on failure; fall back to the raw
    /// body so a proxy/HTML error page is still legible rather than blank.
    private static func errorMessage(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? String {
            return error
        }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }
}
