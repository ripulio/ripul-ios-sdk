import Foundation

/// Only platform-issued capture links can open a native credential field. In
/// particular, a lookalike service may never supply the URL receiving the key.
struct SecureConnectionRequest: Sendable, CustomStringConvertible {
    let connectionID: String
    let endpoint: URL
    private let token: String

    static func recognizes(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return parts.scheme == "https" && parts.host == RipulDomain.llmProxyHost
            && (parts.port == nil || parts.port == 443) && parts.user == nil && parts.password == nil
            && parts.query == nil && parts.percentEncodedPath.hasPrefix("/secure/cms-credentials/")
    }

    init?(url: URL) {
        guard Self.recognizes(url), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let token = parts.fragment, token.count == 72,
              UUID(uuidString: String(token.prefix(36))) != nil,
              UUID(uuidString: String(token.suffix(36))) != nil else { return nil }
        let id = String(parts.percentEncodedPath.dropFirst("/secure/cms-credentials/".count))
        guard id.hasPrefix("int_"), id.count == 40, UUID(uuidString: String(id.dropFirst(4))) != nil else { return nil }
        self.connectionID = id
        self.endpoint = URL(string: "\(RipulDomain.llmProxyURL)/secure/cms-credentials/\(id)")!
        self.token = token
    }

    var description: String { "Secure connection request (private link)" }

    static func validKey(_ key: String) -> Bool {
        (8...8192).contains(key.utf8.count) && key.utf8.allSatisfy { (0x21...0x7e).contains($0) }
    }

    func statusRequest() throws -> URLRequest { try request(action: "status", body: ["token": token]) }

    func saveRequest(key: String, access: SecureConnectionAccess? = nil, origin: String? = nil) throws -> URLRequest {
        guard Self.validKey(key) else { throw SecureConnectionFailure.invalidKey }
        var body: [String: Any] = ["token": token, "key": key, "approved": true, "reviewVersion": 2]
        if let access { body["access"] = access.rawValue }
        if access == .all { body["origin"] = origin ?? "" }
        return try request(action: "save", body: body)
    }

    func approveRequest() throws -> URLRequest {
        try request(action: "save", body: ["token": token, "approved": true, "reviewVersion": 2])
    }

    private func request(action: String, body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: endpoint.appendingPathComponent(action), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Same capability endpoint as the isolated form; no account token or cookies.
        request.setValue(RipulDomain.llmProxyURL, forHTTPHeaderField: "Origin")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}

enum SecureConnectionAccess: String, Decodable, Sendable {
    case stored, restricted, all
}

enum SecureConnectionRequestKind: String, Decodable, Sendable {
    case credential, permissions
}

enum SecureConnectionFailure: LocalizedError, Equatable {
    case unavailable, invalidKey, invalidForm, network, saveUnconfirmed
    var errorDescription: String? {
        switch self {
        case .unavailable: return "This private link has expired or was already used. Ask for a new connection link in the chat."
        case .invalidKey: return "Use 8–8192 characters, with no spaces."
        case .invalidForm: return "Check the credential and API destination, then try again."
        case .network: return "Couldn’t reach the secure store. Check your connection and try again."
        case .saveUnconfirmed: return "We couldn’t confirm the save. Return to the chat to check the connection before trying again."
        }
    }
}

struct SecureConnectionDetails: Decodable, Sendable {
    let siteName: String
    let connection: Connection
    let requestKind: SecureConnectionRequestKind?
    var isPermissions: Bool { requestKind == .permissions }
    struct Connection: Decodable, Sendable {
        let id: String
        let name: String
        let environment: String
        let configured: Bool
        let operations: [Operation]
        let access: SecureConnectionAccess?
        let origin: String?
        var apiAccess: SecureConnectionAccess { access ?? (operations.isEmpty ? .stored : .restricted) }
    }
    struct Operation: Decodable, Sendable {
        let name: String
        let url: String
        let method: String
        let inputFields: [String]
        let outputFields: [String]
    }
    var destination: String {
        if connection.apiAccess == .stored { return "No API calls allowed" }
        if connection.origin == "*.*" { return "Any public HTTPS destination" }
        return connection.origin.flatMap { URL(string: $0)?.host }
            ?? connection.operations.first.flatMap { URL(string: $0.url)?.host } ?? "API destination"
    }

    var validReview: Bool {
        if isPermissions && !connection.configured { return false }
        switch connection.apiAccess {
        case .stored: return connection.operations.isEmpty
        case .restricted: return !connection.operations.isEmpty
        case .all: return connection.operations.isEmpty && Self.validOrigin(connection.origin ?? "")
        }
    }

    static func validOrigin(_ value: String) -> Bool {
        if value == "*.*" { return true }
        guard let url = URLComponents(string: value), url.scheme == "https", let host = url.host,
              host.contains("."), url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.port == nil || url.port == 443,
              url.path.isEmpty || url.path == "/" else { return false }
        return true
    }
}

/// Ephemeral, cookie-free native transport. Neither requests nor responses pass
/// through the web view, bridge, API monitor, tool arguments or chat history.
final class SecureConnectionClient: @unchecked Sendable {
    private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
    private let session: URLSession
    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 25
        return configuration
    }
    init(configuration: URLSessionConfiguration = SecureConnectionClient.configuration()) {
        session = URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    func cancel() { session.invalidateAndCancel() }

    func details(for request: SecureConnectionRequest) async throws -> SecureConnectionDetails {
        let data = try await send(request.statusRequest(), saving: false)
        guard let details = try? JSONDecoder().decode(SecureConnectionDetails.self, from: data),
              details.connection.id == request.connectionID, details.validReview else {
            throw SecureConnectionFailure.unavailable
        }
        return details
    }

    func save(_ key: String, for request: SecureConnectionRequest, access: SecureConnectionAccess? = nil, origin: String? = nil) async throws {
        _ = try await send(request.saveRequest(key: key, access: access, origin: origin), saving: true)
    }

    func approve(for request: SecureConnectionRequest) async throws {
        _ = try await send(request.approveRequest(), saving: true)
    }

    private func send(_ request: URLRequest, saving: Bool) async throws -> Data {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.url == request.url else { throw SecureConnectionFailure.unavailable }
            if http.statusCode == 410 { throw SecureConnectionFailure.unavailable }
            if http.statusCode == 400 { throw SecureConnectionFailure.invalidForm }
            guard http.statusCode == 200 else { throw saving ? SecureConnectionFailure.saveUnconfirmed : .network }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 65_536 else { throw SecureConnectionFailure.unavailable }
                data.append(byte)
            }
            if saving {
                // Decode only the fixed receipt; never display a server's raw error/body.
                struct Receipt: Decodable { let configured: Bool }
                guard (try? JSONDecoder().decode(Receipt.self, from: data))?.configured == true else {
                    throw SecureConnectionFailure.saveUnconfirmed
                }
            }
            return data
        } catch let failure as SecureConnectionFailure { throw failure }
        catch { throw saving ? SecureConnectionFailure.saveUnconfirmed : .network }
    }
}
