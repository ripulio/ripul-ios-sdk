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
    case invalidDocument, invalidResponse, signIn, conflict, permissionDenied(String?), http(Int)
    public var errorDescription: String? {
        switch self {
        case .invalidDocument: return "The theme must be a valid JSON object no larger than 512 KiB."
        case .invalidResponse: return "The theme server returned an invalid response."
        case .signIn: return "Sign in to publish this theme."
        case .conflict: return "The theme changed on the server. Your draft is kept. Reload the server version and review your changes before publishing again."
        case .permissionDenied(let reason):
            return (reason.map { $0 + "." } ?? "Your account does not have permission to publish this theme.")
                + " Your draft is kept."
        case .http(let status): return "The theme server returned HTTP \(status). Your draft is kept."
        }
    }
}

/// One earlier publication of a theme, newest first in `RipulThemePublisher.versions`.
public struct RipulThemeVersion: Identifiable, Equatable {
    public let id: Int
    public let etag: String
    public let publishedAt: Date?
    /// Who published it: their email when known, otherwise their account id.
    public let publishedBy: String
    public let bytes: Int
}

/// Publishes to the theme's site route, which accepts a Ripul admin or a designer of the
/// site the theme belongs to. A publish is conditional on the exact server version
/// reviewed by the editor; missing versions use create-only PUT.
///
/// Sign-in: the host app's own login (`hostCredentials`, e.g. WAC's credential headers)
/// is tried first, so a designer publishes as themselves without a Ripul account; the
/// Ripul sign-in (`tokenProvider`) is tried next, or alone when the host has none.
@MainActor
public final class RipulThemePublisher {
    /// The host app's own login, as request headers, when it has one. Set once at launch.
    public static var hostCredentials: (@MainActor () -> [String: String]?)?

    private let baseURL: URL
    private let tokenProvider: () -> String?
    private let credentials: () -> [String: String]?
    private let fetch: (URLRequest) async throws -> (Data, URLResponse)

    public convenience init(baseURL: URL, tokenProvider: @escaping () -> String?) {
        self.init(baseURL: baseURL, tokenProvider: tokenProvider,
                  credentials: { RipulThemePublisher.hostCredentials?() },
                  fetch: { try await URLSession.shared.data(for: $0) })
    }
    init(baseURL: URL, tokenProvider: @escaping () -> String?,
         credentials: @escaping () -> [String: String]? = { nil },
         fetch: @escaping (URLRequest) async throws -> (Data, URLResponse)) {
        self.baseURL = baseURL; self.tokenProvider = tokenProvider
        self.credentials = credentials; self.fetch = fetch
    }

    /// Each way this person can sign in, host login first. Empty when signed out.
    private var signIns: [(inout URLRequest) -> Void] {
        var result: [(inout URLRequest) -> Void] = []
        if let headers = credentials(), !headers.isEmpty {
            result.append { request in for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) } }
        }
        if let token = tokenProvider(), !token.isEmpty {
            result.append { $0.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        }
        return result
    }

    /// Send `request` with each sign-in in turn, moving on when one is refused.
    private func authorized(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let signIns = signIns
        guard !signIns.isEmpty else { throw RipulThemePublishError.signIn }
        var last: (Data, HTTPURLResponse)?
        for signIn in signIns {
            var attempt = request
            signIn(&attempt)
            let (body, response) = try await fetch(attempt)
            guard let http = response as? HTTPURLResponse else { throw RipulThemePublishError.invalidResponse }
            last = (body, http)
            if http.statusCode != 401 && http.statusCode != 403 { break }
        }
        return last!
    }

    private static func refusal(_ body: Data) -> String? {
        let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        return (object?["error"] as? [String: Any])?["message"] as? String
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
        var request = try request(id: id, path: "api/v1/app-themes")
        request.httpMethod = "PUT"; request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // This API's version is the manifest's SHA-256 digest. Cloudflare may mark
        // that same digest weak when compressing GET responses; D1 stores it strong.
        if let etag { request.setValue(etag.hasPrefix("W/\"") ? String(etag.dropFirst(2)) : etag, forHTTPHeaderField: "If-Match") }
        else { request.setValue("*", forHTTPHeaderField: "If-None-Match") }
        let (body, http) = try await authorized(request)
        switch http.statusCode {
        case 200: break
        case 401: throw RipulThemePublishError.signIn
        case 403: throw RipulThemePublishError.permissionDenied(Self.refusal(body))
        case 412: throw RipulThemePublishError.conflict
        default: throw RipulThemePublishError.http(http.statusCode)
        }
        guard let result = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let newTag = result["etag"] as? String, !newTag.isEmpty else {
            throw RipulThemePublishError.invalidResponse
        }
        return try RipulThemeManifest(data: data, etag: newTag)
    }

    /// The theme's publication history, newest first. Readable by the people who may publish it.
    public func versions(id: String) async throws -> [RipulThemeVersion] {
        let (body, http) = try await authorized(try request(id: id, path: "api/v1/app-themes", suffix: "versions"))
        try Self.check(http, body)
        guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let rows = object["versions"] as? [[String: Any]] else { throw RipulThemePublishError.invalidResponse }
        let dates = ISO8601DateFormatter(); dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return rows.compactMap { row in
            guard let id = row["id"] as? Int, let etag = row["etag"] as? String else { return nil }
            return RipulThemeVersion(id: id, etag: etag,
                                     publishedAt: (row["publishedAt"] as? String).flatMap(dates.date(from:)),
                                     publishedBy: row["publishedBy"] as? String ?? "", bytes: row["bytes"] as? Int ?? 0)
        }
    }

    /// One earlier publication's complete document.
    public func document(id: String, version: RipulThemeVersion) async throws -> Data {
        let (body, http) = try await authorized(try request(id: id, path: "api/v1/app-themes", suffix: "versions/\(version.id)"))
        try Self.check(http, body)
        guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let document = object["document"] as? [String: Any] else { throw RipulThemePublishError.invalidResponse }
        let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys, .prettyPrinted])
        return try RipulThemeManifest(data: data, etag: nil).data
    }

    private static func check(_ http: HTTPURLResponse, _ body: Data) throws {
        switch http.statusCode {
        case 200: return
        case 401: throw RipulThemePublishError.signIn
        case 403: throw RipulThemePublishError.permissionDenied(refusal(body))
        default: throw RipulThemePublishError.http(http.statusCode)
        }
    }

    private func request(id: String, path: String, suffix: String? = nil) throws -> URLRequest {
        guard id.range(of: "^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$", options: .regularExpression) != nil else {
            throw RipulThemePublishError.invalidDocument
        }
        var url = baseURL.appendingPathComponent(path).appendingPathComponent(id)
        if let suffix { url = url.appendingPathComponent(suffix) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}
