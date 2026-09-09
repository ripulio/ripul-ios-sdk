import Foundation

/// What the worker will say about a key it holds: that it has one, when it
/// arrived, the last four characters, and whose account it belongs to. Never
/// the key. `/v1/user-secrets` has no read-back route by design, so there is
/// no decoding path here that could produce one.
struct UserSecretStatus: Codable, Identifiable, Equatable {
    let provider: String
    let configured: Bool
    let hint: String?
    let updatedAt: String?
    let accountLabel: String?
    /// True when RIPUL has a shared key to fall back on. Drives the difference
    /// between "using the shared key" and "speech is off".
    let platformFallbackAvailable: Bool

    var id: String { provider }
}

struct UserSecretsSnapshot: Equatable {
    var secrets: [UserSecretStatus]
    /// False when the deployment has no USER_SECRET_ENCRYPTION_KEY. The field
    /// must be offered as disabled rather than hidden — a key field that
    /// silently discards what is typed into it is worse than no field.
    var storageEnabled: Bool

    static let empty = UserSecretsSnapshot(secrets: [], storageEnabled: false)

    func status(for provider: String) -> UserSecretStatus? {
        secrets.first { $0.provider == provider }
    }
}

/// Client for the caller's own bring-your-own-key credentials.
///
/// Same auth model as the native speech routes: bearer token from the
/// caller-supplied provider, Clerk token when the web view has one and the
/// machine token otherwise. Both are accepted for these routes precisely so
/// this works on an unattended host, which is where someone installing the
/// Mac app would go looking for it.
@MainActor
final class UserSecretsClient {
    enum ClientError: LocalizedError {
        case notAuthenticated
        /// Carries the worker's own message — "ElevenLabs rejected that key"
        /// is the sentence the user needs, and a generic HTTP code buries it.
        case server(String)

        var errorDescription: String? {
            switch self {
            case .notAuthenticated:
                return "Not signed in — no auth token available."
            case .server(let message):
                return message
            }
        }
    }

    private let baseURL: URL
    private let tokenProvider: () -> String?

    init(baseURL: URL = AgentConfiguration.defaultBaseURL, tokenProvider: @escaping () -> String?) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
    }

    func list() async throws -> UserSecretsSnapshot {
        struct ListResponse: Codable {
            let secrets: [UserSecretStatus]
            let storageEnabled: Bool
        }
        let data = try await send(path: "api/v1/user-secrets", method: "GET")
        let decoded = try JSONDecoder().decode(ListResponse.self, from: data)
        return UserSecretsSnapshot(secrets: decoded.secrets, storageEnabled: decoded.storageEnabled)
    }

    func save(provider: String, key: String) async throws -> UserSecretStatus {
        struct Body: Codable { let key: String }
        struct SecretResponse: Codable { let secret: UserSecretStatus }
        let data = try await send(
            path: "api/v1/user-secrets/\(provider)",
            method: "PUT",
            body: try JSONEncoder().encode(Body(key: key))
        )
        return try JSONDecoder().decode(SecretResponse.self, from: data).secret
    }

    func remove(provider: String) async throws -> UserSecretStatus {
        struct SecretResponse: Codable { let secret: UserSecretStatus }
        let data = try await send(path: "api/v1/user-secrets/\(provider)", method: "DELETE")
        return try JSONDecoder().decode(SecretResponse.self, from: data).secret
    }

    private func send(path: String, method: String, body: Data? = nil) async throws -> Data {
        guard let token = tokenProvider() else { throw ClientError.notAuthenticated }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ClientError.server(Self.message(from: data, status: status))
        }
        return data
    }

    /// Unwrap the worker's `{ error: { message } }` envelope, falling back to
    /// the status code when the body is not one.
    private static func message(from data: Data, status: Int) -> String {
        struct ErrorEnvelope: Codable {
            struct Inner: Codable { let message: String? }
            let error: Inner?
        }
        if let decoded = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
           let message = decoded.error?.message, !message.isEmpty {
            return message
        }
        return "Server error \(status)"
    }
}
