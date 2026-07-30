import Foundation

// ---------------------------------------------------------------------------
// Macro persistence — CRUD over `/v1/macros`, mirroring
// `ToolCollectionsClient.swift`'s transport/auth/error-handling shape
// exactly (same base URL, same Bearer-token pattern, same error envelope).
//
// Deliberately decodes/encodes `RipulMacro` DIRECTLY (declared `Codable` in
// MacroModels.swift for exactly this reason) rather than a parallel wire
// struct like `RipulToolCollection` — the backend's `Macro` response shape
// (chrome-extension/packages/api/src/macros/types.ts) matches field-for-field.
// ---------------------------------------------------------------------------

/// Fields to write on create/update. Nil means "leave unchanged" on update
/// (mirrors `RipulToolCollectionEdit`'s convention exactly).
public struct RipulMacroEdit {
    public var name: String?
    public var description: String?
    public var steps: [MacroStep]?
    public var parameters: [MacroParameter]?
    /// The publish/unpublish toggle (phase 4) — the one field with no
    /// `RipulToolCollectionEdit` analog, since collections have no such gate.
    public var published: Bool?
    public var siteKeyId: String?

    public init(name: String? = nil, description: String? = nil, steps: [MacroStep]? = nil,
               parameters: [MacroParameter]? = nil, published: Bool? = nil, siteKeyId: String? = nil) {
        self.name = name
        self.description = description
        self.steps = steps
        self.parameters = parameters
        self.published = published
        self.siteKeyId = siteKeyId
    }

    func body(encoder: JSONEncoder) -> [String: Any] {
        var out: [String: Any] = [:]
        if let name { out["name"] = name }
        if let description { out["description"] = description }
        if let steps, let data = try? encoder.encode(steps), let json = try? JSONSerialization.jsonObject(with: data) {
            out["steps"] = json
        }
        if let parameters, let data = try? encoder.encode(parameters), let json = try? JSONSerialization.jsonObject(with: data) {
            out["parameters"] = json
        }
        if let published { out["published"] = published }
        if let siteKeyId { out["siteKeyId"] = siteKeyId }
        return out
    }
}

public enum RipulMacroClientError: LocalizedError {
    case notSignedIn
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

/// CRUD over `/v1/macros`, reached through the web app's API proxy
/// (`<baseURL>/api/*`) exactly as `RipulToolCollectionsClient` and
/// `MachineDirectory` do.
public final class RipulMacroClient {
    private let baseURL: URL
    private let tokenProvider: () -> String?

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// - Parameter tokenProvider: supplies the Clerk token — same convention
    ///   every other console sub-component (`RipulToolCollectionsClient`,
    ///   `MachineDirectory`) takes.
    public init(baseURL: URL = AgentConfiguration.defaultBaseURL, tokenProvider: @escaping () -> String?) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
    }

    /// All macros in scope. `siteKeyId` filters to that site key's team-shared
    /// macros (matching `listToolCollections`' scoping) — nil lists the
    /// caller's own macros only (see `listMacros`'s server-side reasoning for
    /// why this is deliberately NOT a "global" default).
    public func list(siteKeyId: String? = nil) async throws -> [RipulMacro] {
        var path = "api/v1/macros"
        if let siteKeyId { path += "?siteKeyId=\(siteKeyId)" }
        let data = try await send(path: path, method: "GET", body: nil)
        struct ListResponse: Decodable { let macros: [RipulMacro] }
        guard let decoded = try? Self.decoder.decode(ListResponse.self, from: data) else {
            throw RipulMacroClientError.malformedResponse
        }
        return decoded.macros
    }

    /// Persist a recorded macro. Always created as a draft — `published` is
    /// never sent, so the server's own default (also always `false`) is what
    /// takes effect either way; belt and braces, same posture as
    /// `ToolCollectionsClient.createCategory`'s client-forced `siteKeyId`.
    public func create(_ macro: RipulMacro) async throws -> RipulMacro {
        var body: [String: Any] = [
            "name": macro.name,
            "description": macro.description,
        ]
        if let data = try? Self.encoder.encode(macro.steps), let json = try? JSONSerialization.jsonObject(with: data) {
            body["steps"] = json
        }
        if let data = try? Self.encoder.encode(macro.parameters), let json = try? JSONSerialization.jsonObject(with: data) {
            body["parameters"] = json
        }
        if let siteKeyId = macro.siteKeyId { body["siteKeyId"] = siteKeyId }

        let data = try await send(path: "api/v1/macros", method: "POST", body: body)
        guard let decoded = try? Self.decoder.decode(RipulMacro.self, from: data) else {
            throw RipulMacroClientError.malformedResponse
        }
        return decoded
    }

    /// Partial update — the same call publishes (`RipulMacroEdit(published: true)`)
    /// as edits any other field (phase 4's publish/unpublish affordance).
    public func update(id: String, edit: RipulMacroEdit) async throws -> RipulMacro {
        let data = try await send(path: "api/v1/macros/\(encode(id))", method: "PATCH", body: edit.body(encoder: Self.encoder))
        guard let decoded = try? Self.decoder.decode(RipulMacro.self, from: data) else {
            throw RipulMacroClientError.malformedResponse
        }
        return decoded
    }

    public func delete(id: String) async throws {
        _ = try await send(path: "api/v1/macros/\(encode(id))", method: "DELETE", body: nil)
    }

    // MARK: - Transport (identical shape to RipulToolCollectionsClient.send)

    private func send(path: String, method: String, body: [String: Any]?) async throws -> Data {
        guard let token = tokenProvider(), !token.isEmpty else {
            throw RipulMacroClientError.notSignedIn
        }
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw RipulMacroClientError.malformedResponse
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
            throw RipulMacroClientError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw RipulMacroClientError.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw RipulMacroClientError.server(status: http.statusCode, message: Self.errorMessage(from: data))
        }
        return data
    }

    private static func errorMessage(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? String {
            return error
        }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }
}
