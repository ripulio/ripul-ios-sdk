import Foundation

/// Keeps feature payloads intact: editing one setting must not discard others.
public struct RipulViewContext: Identifiable {
    public var id: String
    public var name: String
    public var description: String
    public var tabIds: [String]
    public var defaultTabId: String
    public var features: [String: Any]
    public let isSystem: Bool

    init(json: [String: Any]) throws {
        guard let id = json["id"] as? String, let name = json["name"] as? String,
              let tabs = json["tabIds"] as? [String] else {
            throw RipulSolutionContextsError.malformedResponse
        }
        self.id = id
        self.name = name
        description = json["description"] as? String ?? ""
        tabIds = tabs
        defaultTabId = json["defaultTabId"] as? String ?? ""
        features = json["features"] as? [String: Any] ?? [:]
        isSystem = json["isSystem"] as? Bool ?? false
    }

    var payload: [String: Any] {
        ["id": id, "name": name, "description": description, "tabIds": tabIds,
         "defaultTabId": defaultTabId, "features": features]
    }
}

public final class RipulViewContextsClient {
    private let baseURL: URL
    private let tokenProvider: () -> String?
    private let session: URLSession

    public init(baseURL: URL = AgentConfiguration.defaultBaseURL,
                tokenProvider: @escaping () -> String?, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        self.session = session
    }

    public func list() async throws -> [RipulViewContext] {
        let data = try await send(method: "GET")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["viewContexts"] as? [[String: Any]] else {
            throw RipulSolutionContextsError.malformedResponse
        }
        return try rows.map(RipulViewContext.init(json:))
    }

    public func save(_ context: RipulViewContext, creating: Bool) async throws {
        _ = try await send(method: creating ? "POST" : "PATCH",
                           id: creating ? nil : context.id, body: context.payload)
    }

    public func delete(id: String) async throws {
        _ = try await send(method: "DELETE", id: id)
    }

    private func send(method: String, id: String? = nil, body: [String: Any]? = nil) async throws -> Data {
        guard let token = tokenProvider(), !token.isEmpty else {
            throw NSError(domain: "RipulViewContexts", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: "Sign in to manage view contexts."])
        }
        var url = baseURL.appendingPathComponent("api/admin/view-contexts")
        if let id { url.appendPathComponent(id) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RipulSolutionContextsError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw RipulSolutionContextsError.serverError(status: http.statusCode, body: data)
        }
        return data
    }
}
