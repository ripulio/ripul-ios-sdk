import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Authenticated, employment-bound conversations. Separate from the anonymous AgentView session.
/// Call resetIdentity on logout/account change before displaying another account's content.
public actor EmbeddedAgentClient {
    public struct Claim: Decodable, Sendable {
        public let id: String
        public let binding_key: String
        public let organisation_id: String
        public let generation: Int
    }
    public struct Conversation: Decodable, Sendable {
        public let id: String
        public let binding_key: String
        public let organisation_id: String
        public let claim_generation: Int
    }
    public struct Message: Decodable, Sendable {
        public let id: String
        public let author_subject: String
        public let content: String
        public let created_at: String
    }
    public enum ClientError: Error {
        case invalidConfiguration, invalidResponse, identityChanged
        case server(status: Int, message: String)
    }
    private struct Session: Decodable { let token: String; let expiresAt: Double }
    private struct ClaimsReply: Decodable { let claims: [Claim] }
    private struct AvailabilityReply: Decodable { let enabled: Bool }
    private struct ConversationsReply: Decodable { let conversations: [Conversation] }
    private struct ClaimReply: Decodable { let claim: Claim }
    private struct ConversationReply: Decodable { let conversation: Conversation }
    private struct MessagesReply: Decodable { let messages: [Message] }
    private struct ErrorReply: Decodable { let error: String }
    private struct MessageReply: Decodable { let accepted: Bool; let runnerStatus: String }

    private let endpoint: URL
    private let origin: String
    private let credentials: @Sendable () async throws -> [String: String]
    private let transport: URLSession
    private var session: Session?
    private var identityGeneration = 0

    /// baseURL is the API host (for example https://llm-proxy.ripul.io), not the web app URL.
    /// credentials returns the customer's current opaque login headers. They are sent only to session exchange.
    public init(baseURL: URL, siteKeyID: String, origin: String, transport: URLSession = .shared,
                credentials: @escaping @Sendable () async throws -> [String: String]) throws {
        guard baseURL.scheme == "https", baseURL.host != nil, baseURL.user == nil,
              baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil,
              !siteKeyID.isEmpty, siteKeyID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }),
              URL(string: origin)?.scheme == "https" else { throw ClientError.invalidConfiguration }
        self.endpoint = baseURL.appendingPathComponent("v1/embedded-agents").appendingPathComponent(siteKeyID)
        self.origin = origin
        self.transport = transport
        self.credentials = credentials
    }

    /// Immediately invalidates in-flight results. A failed remote logout still leaves this client cleared.
    public func resetIdentity() async {
        identityGeneration += 1
        let old = session
        session = nil
        if let old {
            _ = try? await send("DELETE", path: "session", token: old.token, body: nil)
        }
    }

    public func isEnabled(code: String) async throws -> Bool {
        try await call(AvailabilityReply.self, "POST", path: "availability", body: ["code": code]).enabled
    }
    public func conversations(claimID: String) async throws -> [Conversation] {
        try await call(ConversationsReply.self, "GET", path: "conversations", query: [URLQueryItem(name: "claimId", value: claimID)]).conversations
    }
    public func claims() async throws -> [Claim] {
        try await call(ClaimsReply.self, "GET", path: "claims").claims
    }
    public func claim(code: String) async throws -> Claim {
        try await call(ClaimReply.self, "POST", path: "claims", body: ["code": code]).claim
    }
    public func createConversation(claimID: String) async throws -> Conversation {
        try await call(ConversationReply.self, "POST", path: "conversations", body: ["claimId": claimID]).conversation
    }
    public func conversation(id: String) async throws -> Conversation {
        try await call(ConversationReply.self, "GET", path: "conversations/\(try checkedID(id))").conversation
    }
    public func messages(conversationID: String) async throws -> [Message] {
        try await call(MessagesReply.self, "GET", path: "conversations/\(try checkedID(conversationID))/messages").messages
    }
    /// Retain messageID across retries. A changed payload must use a new ID.
    /// Returns runnerStatus explicitly: persistence is not a promise that an agent has answered.
    public func sendMessage(conversationID: String, messageID: String, content: String) async throws -> String {
        let result = try await call(MessageReply.self, "POST", path: "conversations/\(try checkedID(conversationID))/messages",
                                    body: ["id": messageID, "content": content])
        guard result.accepted else { throw ClientError.invalidResponse }
        return result.runnerStatus
    }
    private func checkedID(_ id: String) throws -> String {
        guard id.hasPrefix("ecv_"), UUID(uuidString: String(id.dropFirst(4))) != nil else { throw ClientError.invalidConfiguration }
        return id
    }

    private func token(generation: Int) async throws -> String {
        if let session, session.expiresAt > Date().timeIntervalSince1970 + 30 { return session.token }
        let headers = try await credentials()
        guard generation == identityGeneration else { throw ClientError.identityChanged }
        let data = try await send("POST", path: "session", token: nil, body: nil, credentialHeaders: headers)
        guard generation == identityGeneration else { throw ClientError.identityChanged }
        let fresh = try JSONDecoder().decode(Session.self, from: data)
        guard fresh.expiresAt > Date().timeIntervalSince1970, fresh.token.count == 64 else { throw ClientError.invalidResponse }
        session = fresh
        return fresh.token
    }
    private func call<T: Decodable>(_ type: T.Type, _ method: String, path: String, body: [String: String]? = nil, query: [URLQueryItem] = []) async throws -> T {
        let generation = identityGeneration
        let accessToken = try await token(generation: generation)
        guard generation == identityGeneration else { throw ClientError.identityChanged }
        let data = try await send(method, path: path, token: accessToken, body: body, query: query)
        guard generation == identityGeneration else { throw ClientError.identityChanged }
        return try JSONDecoder().decode(type, from: data)
    }
    private func send(_ method: String, path: String, token: String?, body: [String: String]?, credentialHeaders: [String: String] = [:], query: [URLQueryItem] = []) async throws -> Data {
        var components = URLComponents(url: endpoint.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw ClientError.invalidConfiguration }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        for (key, value) in credentialHeaders {
            // Caller may provide only customer credentials/metadata; it cannot redirect the request or replace origin.
            guard !["host", "authorization", "origin", "content-length", "connection", "cookie"].contains(key.lowercased()) else { continue }
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONEncoder().encode(body) }
        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorReply.self, from: data).error) ?? "The request failed."
            throw ClientError.server(status: http.statusCode, message: message)
        }
        return data
    }
}
