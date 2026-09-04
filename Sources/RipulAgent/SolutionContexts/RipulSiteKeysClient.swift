import Foundation

// ---------------------------------------------------------------------------
// Native client for the SITE KEYS admin API, scoped to what solution
// management needs: reading keys and writing their CONTEXT TRIPLE.
//
// The triple is (allowedSolutionContextIds, defaultSolutionContextId,
// surfaceContextMap). It is the binding between a key and the contexts its
// sessions may enter — the server treats it as one unit and validates it on
// write (`contextTripleValidation.ts`): the default must be a member of the
// allowed set, and every surface must map into it. A refusal comes back as a
// 400 with a human-readable reason, which this client surfaces verbatim rather
// than second-guessing.
//
// Deliberately NOT a general site-key editor: model, rate limits, origins and
// the rest stay in the web dashboard. This is the context-assignment surface.
// ---------------------------------------------------------------------------

public struct RipulSiteKeySummary: Identifiable, Hashable {
    public let id: String
    public let name: String
    public let publishableKey: String
    public var allowedSolutionContextIds: [String]
    public var defaultSolutionContextId: String?
    public var surfaceContextMap: [String: String]
    /// Set when the key inherits its triple from another key instead of owning
    /// one. Editing such a key here would be a no-op at runtime, so the editor
    /// says so rather than silently writing an ignored triple.
    public let delegateSolutionContextTo: String?
    /// The CMS portal this key is linked to (internal id or portal slug).
    /// Row billing binds to CMS queries, so it needs keys that carry one.
    public let cmsDefinitionId: String?

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String,
              let name = json["name"] as? String,
              let publishableKey = json["publishableKey"] as? String else { return nil }
        self.id = id
        self.name = name
        self.publishableKey = publishableKey
        self.allowedSolutionContextIds = json["allowedSolutionContextIds"] as? [String] ?? []
        self.defaultSolutionContextId = json["defaultSolutionContextId"] as? String
        self.surfaceContextMap = json["surfaceContextMap"] as? [String: String] ?? [:]
        self.delegateSolutionContextTo = json["delegateSolutionContextTo"] as? String
        self.cmsDefinitionId = json["cmsDefinitionId"] as? String
    }

    /// Whether this key's sessions are bound to contexts at all. An unbound key
    /// runs with no context — every tool available, no curated prompt.
    public var hasContextBinding: Bool {
        !allowedSolutionContextIds.isEmpty || delegateSolutionContextTo != nil
    }
}

public final class RipulSiteKeysClient {
    private let baseURL: URL
    private let tokenProvider: () -> String?

    public init(
        baseURL: URL = AgentConfiguration.defaultBaseURL,
        tokenProvider: @escaping () -> String?
    ) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
    }

    public func list() async throws -> [RipulSiteKeySummary] {
        let data = try await send(path: "api/admin/site-keys", method: "GET", body: nil)
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            throw RipulSolutionContextsError.malformedResponse
        }
        // The list endpoint has returned both a bare array and a wrapped
        // object across versions; accept either rather than break on shape.
        let rows: [[String: Any]]
        if let array = json as? [[String: Any]] {
            rows = array
        } else if let object = json as? [String: Any],
                  let array = (object["siteKeys"] ?? object["keys"]) as? [[String: Any]] {
            rows = array
        } else {
            throw RipulSolutionContextsError.malformedResponse
        }
        return rows.compactMap(RipulSiteKeySummary.init(json:))
    }

    /// Write the key's context triple. Sent as one PATCH because the server
    /// validates it as a unit — writing the parts separately would transit
    /// through states it would reject (e.g. a default not yet in the allowed
    /// set).
    ///
    /// An empty `allowed` clears the binding: the key's sessions then run with
    /// no context at all.
    public func updateContextTriple(
        id: String,
        allowedSolutionContextIds: [String],
        defaultSolutionContextId: String?,
        surfaceContextMap: [String: String]
    ) async throws -> RipulSiteKeySummary {
        let body: [String: Any] = [
            "allowedSolutionContextIds": allowedSolutionContextIds,
            // NSNull clears the field server-side; a missing key would mean
            // "leave unchanged", which can't express "no default".
            "defaultSolutionContextId": defaultSolutionContextId ?? NSNull(),
            "surfaceContextMap": surfaceContextMap,
        ]
        let data = try await send(path: "api/admin/site-keys/\(encode(id))", method: "PATCH", body: body)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = RipulSiteKeySummary(json: json) else {
            throw RipulSolutionContextsError.malformedResponse
        }
        return key
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
            // The triple validator's message names the offending id — the
            // factory passes JSON messages through verbatim so the editor can
            // show why the save was refused.
            throw RipulSolutionContextsError.serverError(status: http.statusCode, body: data)
        }
        return data
    }
}
