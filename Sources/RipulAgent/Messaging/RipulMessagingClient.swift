import Foundation

// ---------------------------------------------------------------------------
// Native client for ADMIN MESSAGES — a push notification an admin sends to
// chosen accounts and teams (`POST /admin/notifications/send`, gated on
// `admin:manage_users` server-side, the same permission as the Users screen
// the recipients come from).
//
// The server expands teams into their members and drops duplicates, so the
// only honest count of who a message reaches is the server's. `send(dryRun:)`
// asks for exactly that without sending, which is what the confirmation shows.
// ---------------------------------------------------------------------------

/// A `ripul://` destination a message may open. The server and the app's
/// push handler accept only these hosts: the app's URL handler also takes
/// hosts that act (`siri-command`, `move-chat`), which a notification must
/// never reach.
public enum RipulMessageLink: String, CaseIterable, Identifiable {
    case agents
    case newSession = "new-session"
    case teams
    case billing
    case floatChat = "float-chat"

    public var id: String { rawValue }

    public var url: String { "ripul://\(rawValue)" }

    public var label: String {
        switch self {
        case .agents: "Agents"
        case .newSession: "New Chat"
        case .teams: "Teams"
        case .billing: "Billing"
        case .floatChat: "Float Chat"
        }
    }

    /// Every `ripul://` host a message may open — the list above plus `share`,
    /// which needs a token and so is typed rather than picked.
    public static let allowedHosts: Set<String> = Set(allCases.map(\.rawValue)).union(["share"])

    /// Mirrors `isAllowedMessageLink` in the worker's adminMessages.ts.
    public static func isAllowed(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https": return true
        case "ripul": return url.host.map(allowedHosts.contains) ?? false
        default: return false
        }
    }
}

public struct RipulAdminMessage {
    public var title: String
    public var body: String
    public var userIds: [String]
    public var teamIds: [String]
    public var link: String?

    public init(title: String, body: String, userIds: [String], teamIds: [String], link: String?) {
        self.title = title
        self.body = body
        self.userIds = userIds
        self.teamIds = teamIds
        self.link = link
    }
}

/// What the server made of a send (or a dry run).
public struct RipulAdminMessageResult: Hashable {
    public let dryRun: Bool
    /// Distinct accounts, after teams are expanded.
    public let recipients: Int
    /// Accounts with at least one registered device.
    public let reachable: Int
    public let devices: Int
    public let delivered: Int
    public let failed: Int
    /// Account ids with no registered device — nothing goes to them.
    public let unreachable: [String]

    init?(json: [String: Any]) {
        guard let recipients = json["recipients"] as? Int else { return nil }
        self.dryRun = json["dryRun"] as? Bool ?? false
        self.recipients = recipients
        self.reachable = json["reachable"] as? Int ?? 0
        self.devices = json["devices"] as? Int ?? 0
        self.delivered = json["delivered"] as? Int ?? 0
        self.failed = json["failed"] as? Int ?? 0
        self.unreachable = json["unreachable"] as? [String] ?? []
    }
}

public final class RipulMessagingClient {
    private let baseURL: URL
    private let tokenProvider: () -> String?

    public init(
        baseURL: URL = AgentConfiguration.defaultBaseURL,
        tokenProvider: @escaping () -> String?
    ) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
    }

    /// Registered devices per account id. Accounts with none are absent.
    public func reach() async throws -> [String: Int] {
        let json = try await request("GET", "api/admin/notifications/reach")
        return json["devices"] as? [String: Int] ?? [:]
    }

    /// Sends `message`, or with `dryRun` only resolves who it would reach.
    public func send(_ message: RipulAdminMessage, dryRun: Bool) async throws -> RipulAdminMessageResult {
        var body: [String: Any] = [
            "title": message.title,
            "body": message.body,
            "userIds": message.userIds,
            "teamIds": message.teamIds,
            "dryRun": dryRun,
        ]
        if let link = message.link, !link.isEmpty { body["link"] = link }
        let json = try await request("POST", "api/admin/notifications/send", body: body)
        guard let result = RipulAdminMessageResult(json: json) else {
            throw RipulSolutionContextsError.malformedResponse
        }
        return result
    }

    private func request(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
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
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
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
            throw RipulSolutionContextsError.serverError(status: http.statusCode, body: data)
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}
