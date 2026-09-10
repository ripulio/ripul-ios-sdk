import Foundation

/// Complete host-owned JSON. Editing/publishing never serializes only the engine slice.
public struct RipulThemeManifest {
    public let data: Data
    public let etag: String?
    public init(data: Data, etag: String?) throws {
        guard data.count <= 512 * 1024,
              (try JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            throw RipulThemePublishError.invalidDocument
        }
        self.data = data; self.etag = etag
    }
    public var formatted: String {
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let bytes = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "" }
        return String(decoding: bytes, as: UTF8.self)
    }
}

public enum RipulThemePublishError: LocalizedError {
    case invalidDocument, invalidResponse, signIn, conflict, permissionDenied, http(Int)
    public var errorDescription: String? {
        switch self {
        case .invalidDocument: return "The theme must be a valid JSON object no larger than 512 KiB."
        case .invalidResponse: return "The theme server returned an invalid response."
        case .signIn: return "Sign in to publish this theme."
        case .conflict: return "The theme changed on the server. Your draft is kept. Reload the server version and review your changes before publishing again."
        case .permissionDenied: return "Your account does not have permission to publish app themes."
        case .http(let status): return "The theme server returned HTTP \(status). Your draft is kept."
        }
    }
}

/// Uses the same authenticated API as Solution Management. A publish is conditional on
/// the exact server version reviewed by the editor; missing versions use create-only PUT.
@MainActor
public final class RipulThemePublisher {
    private let baseURL: URL
    private let tokenProvider: () -> String?
    private let fetch: (URLRequest) async throws -> (Data, URLResponse)

    public convenience init(baseURL: URL, tokenProvider: @escaping () -> String?) {
        self.init(baseURL: baseURL, tokenProvider: tokenProvider,
                  fetch: { try await URLSession.shared.data(for: $0) })
    }
    init(baseURL: URL, tokenProvider: @escaping () -> String?,
         fetch: @escaping (URLRequest) async throws -> (Data, URLResponse)) {
        self.baseURL = baseURL; self.tokenProvider = tokenProvider; self.fetch = fetch
    }

    public func load(id: String) async throws -> RipulThemeManifest? {
        let request = try request(id: id, path: "api/v1/app-themes")
        let (data, response) = try await fetch(request)
        guard let http = response as? HTTPURLResponse else { throw RipulThemePublishError.invalidResponse }
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else { throw RipulThemePublishError.http(http.statusCode) }
        guard let etag = http.value(forHTTPHeaderField: "ETag"), !etag.isEmpty else {
            throw RipulThemePublishError.invalidResponse
        }
        return try RipulThemeManifest(data: data, etag: etag)
    }

    public func publish(id: String, data: Data, replacing etag: String?) async throws -> RipulThemeManifest {
        _ = try RipulThemeManifest(data: data, etag: etag)
        guard let token = tokenProvider(), !token.isEmpty else { throw RipulThemePublishError.signIn }
        var request = try request(id: id, path: "api/admin/app-themes")
        request.httpMethod = "PUT"; request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-Match") }
        else { request.setValue("*", forHTTPHeaderField: "If-None-Match") }
        let (body, response) = try await fetch(request)
        guard let http = response as? HTTPURLResponse else { throw RipulThemePublishError.invalidResponse }
        switch http.statusCode {
        case 200: break
        case 401: throw RipulThemePublishError.signIn
        case 403: throw RipulThemePublishError.permissionDenied
        case 412: throw RipulThemePublishError.conflict
        default: throw RipulThemePublishError.http(http.statusCode)
        }
        guard let result = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let newTag = result["etag"] as? String, !newTag.isEmpty else {
            throw RipulThemePublishError.invalidResponse
        }
        return try RipulThemeManifest(data: data, etag: newTag)
    }

    private func request(id: String, path: String) throws -> URLRequest {
        guard id.range(of: "^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$", options: .regularExpression) != nil else {
            throw RipulThemePublishError.invalidDocument
        }
        var request = URLRequest(url: baseURL.appendingPathComponent(path).appendingPathComponent(id),
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}
