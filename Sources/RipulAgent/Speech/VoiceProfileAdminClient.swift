import Foundation

/// A voice profile record as served by /admin/voice-profiles — the shareable
/// per-site-key speech configuration (vp_*). Field names mirror the web
/// `VoiceProfile` interface exactly; JSON keys are identical camelCase.
struct VoiceProfileRecord: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var description: String?
    var ttsProviderId: String?
    var voiceId: String?
    var ttsModelId: String?
    var pace: Double?
    var expressiveness: Double?
    var sttProviderId: String?
    var language: String?
    var keyterms: [String]?
    var voiceEnabled: Bool?
    var readAloudEnabled: Bool?
    var voiceModeEnabled: Bool?
    var voiceModeStyle: String?
    var autoSpeakReplies: Bool?
    var allowUserOverride: Bool?
    var organizationId: String?
    var createdBy: String?
    var createdAt: String?
    var updatedAt: String?
    var isSystem: Bool?
}

/// Editable subset sent on create/PATCH — all optional server-side; the
/// native editor sends the full editable set for simplicity.
struct VoiceProfileInput: Codable {
    var name: String
    var description: String?
    var ttsProviderId: String?
    var voiceId: String?
    var pace: Double?
    var expressiveness: Double?
    var sttProviderId: String?
    var language: String?
    var keyterms: [String]?
    var voiceEnabled: Bool?
    var voiceModeStyle: String?
    var allowUserOverride: Bool?
}

/// Thin client for the org-scoped voice profile admin API. Same auth model
/// as the native speech routes: bearer token from the caller-supplied
/// provider (Clerk token when the web view has one, machine token fallback).
@MainActor
final class VoiceProfileAdminClient {
    enum ClientError: LocalizedError {
        case notAuthenticated
        case httpError(Int, String)

        var errorDescription: String? {
            switch self {
            case .notAuthenticated:
                return "Not signed in — no auth token available."
            case .httpError(let status, let body):
                return "Server error \(status): \(body)"
            }
        }
    }

    private let baseURL: URL
    private let tokenProvider: () -> String?

    init(baseURL: URL = AgentConfiguration.defaultBaseURL, tokenProvider: @escaping () -> String?) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
    }

    func list() async throws -> [VoiceProfileRecord] {
        struct ListResponse: Codable { let voiceProfiles: [VoiceProfileRecord] }
        let data = try await send(path: "api/admin/voice-profiles", method: "GET")
        return try JSONDecoder().decode(ListResponse.self, from: data).voiceProfiles
    }

    func create(_ input: VoiceProfileInput) async throws -> VoiceProfileRecord {
        let data = try await send(
            path: "api/admin/voice-profiles", method: "POST", body: input)
        return try JSONDecoder().decode(VoiceProfileRecord.self, from: data)
    }

    func update(id: String, _ input: VoiceProfileInput) async throws -> VoiceProfileRecord {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let data = try await send(
            path: "api/admin/voice-profiles/\(encoded)", method: "PATCH", body: input)
        return try JSONDecoder().decode(VoiceProfileRecord.self, from: data)
    }

    func delete(id: String) async throws {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        _ = try await send(path: "api/admin/voice-profiles/\(encoded)", method: "DELETE")
    }

    private func send(path: String, method: String, body: VoiceProfileInput? = nil) async throws -> Data {
        guard let token = tokenProvider() else { throw ClientError.notAuthenticated }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let text = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw ClientError.httpError(status, text)
        }
        return data
    }
}
