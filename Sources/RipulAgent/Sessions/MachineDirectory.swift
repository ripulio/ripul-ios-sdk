import Foundation

/// Fetches the relay machine registry (the set of host Macs the signed-in
/// developer can pair with). Extracted from the app's `loadRemoteMachines`.
public enum MachineDirectory {
    private struct MachinesResponse: Decodable {
        let machines: [RemoteMachine]
        let count: Int
    }

    /// Fetch the relay machine registry.
    ///
    /// Returns nil when the request FAILED (network error, non-200) so callers
    /// can distinguish "unreachable" from an authoritative empty list —
    /// onboarding and empty-state UI must never treat a failed fetch as
    /// "brand-new account".
    public static func fetch(token: String, baseURL: URL = AgentConfiguration.defaultBaseURL) async -> [RemoteMachine]? {
        do {
            var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/relay/machines"))
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return nil
            }

            return try JSONDecoder().decode(MachinesResponse.self, from: data).machines
        } catch {
            return nil
        }
    }

    /// Share a chat on a team's Mac with the team, or take it back. Only the
    /// person who started the chat may. Returns the server's reason on refusal.
    public static func setChatShared(_ shared: Bool, chat: TeamChatSharing, token: String,
                                     baseURL: URL = AgentConfiguration.defaultBaseURL) async -> String? {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        let chatId = chat.chatId.addingPercentEncoding(withAllowedCharacters: allowed) ?? chat.chatId
        guard let url = URL(string: "api/v1/department-hosts/\(chat.ownerId)/\(chat.machineId)/chats/\(chatId)/visibility", relativeTo: baseURL) else {
            return "This chat cannot be shared."
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["visibility": shared ? "team" : "private"])
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 200 { return nil }
            let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            return (body?["error"] as? [String: Any])?["message"] as? String
                ?? body?["error"] as? String ?? "Could not change who sees this chat."
        } catch {
            return error.localizedDescription
        }
    }
}

/// A chat on a Mac a team shares: whether the team may use it, and whether
/// this person may decide that.
public struct TeamChatSharing: Equatable {
    public let teamName: String
    public let shared: Bool
    /// Only the person who started a chat decides who sees it.
    public let canChange: Bool
    let ownerId: String
    let machineId: String
    let chatId: String
}
