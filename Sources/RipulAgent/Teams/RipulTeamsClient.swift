import Foundation

// ---------------------------------------------------------------------------
// Native client for TEAMS — the groups a Ripul account belongs to, as
// distinct from `site_key_owners` (a portal's CMS users) and from the
// platform user directory (`RipulUsersClient`, admin-only).
//
// Everything here goes straight to `<baseURL>/api/v1/...` with the signed-in
// account's Clerk token, the same way the Users and Models screens do — not
// through the web-view bridge. The server decides what the caller may do:
// `GET /v1/me` returns the permissions the router resolved, and every write
// is re-checked against team membership server-side. The client never infers
// "can manage" from the subscription tier.
//
// Invitations are by email. Nothing is granted until the invitee accepts as
// themselves, so an invite never tells the sender whether the address has an
// account, and it still works for someone who signs up later.
// ---------------------------------------------------------------------------

public struct RipulDepartmentHost: Identifiable, Codable, Hashable {
    public let ownerId: String
    public let machineId: String
    public let displayName: String
    public let teamId: String
    public let teamName: String
    public let role: String
    /// What this person's role may use of the Mac beyond chats: area → "view" or "control".
    public var access: [String: String]? = nil
    /// Every role's grants. Sent only to the Mac's own owner, who sets them.
    public var sharing: RipulSharedMacAccess? = nil
    public var id: String { ownerId + ":" + machineId }
}

/// What the owner of a shared Mac lets each team role use beyond its chats.
/// A team's owners count as admins. An area that is absent is off.
public struct RipulSharedMacAccess: Codable, Hashable {
    public var member: [String: String]
    public var admin: [String: String]

    public subscript(role: RipulMacRole) -> [String: String] {
        get { role == .admin ? admin : member }
        set { if role == .admin { admin = newValue } else { member = newValue } }
    }
}

public enum RipulMacRole: String, CaseIterable, Identifiable {
    case member, admin
    public var id: String { rawValue }
    public var label: String { self == .admin ? "Admins" : "Members" }
}

public enum RipulMacAreaLevel: String, CaseIterable, Identifiable {
    case off, view, control
    public var id: String { rawValue }
}

/// One part of a shared Mac its owner can let a team use. Kept in step with
/// `MAC_AREAS` in the web app's `src/shared/sharedMacAccess.ts`, which a test
/// there checks: same ids, same order, the same areas with a view level.
public struct RipulMacArea: Identifiable, Hashable {
    public let id: String
    public let label: String
    public let icon: String
    /// What View gives; nil for an area that is only on or off.
    public let view: String?
    public let control: String

    public var levels: [RipulMacAreaLevel] { view == nil ? [.off, .control] : [.off, .view, .control] }

    public func summary(_ level: RipulMacAreaLevel) -> String {
        switch level {
        case .off: return "Not shared"
        case .view: return view ?? control
        case .control:
            guard let view else { return control }
            return "\(view). \(control)"
        }
    }

    public func levelLabel(_ level: RipulMacAreaLevel) -> String {
        switch level {
        case .off: return "Off"
        case .view: return "View"
        case .control: return view == nil ? "On" : "Control"
        }
    }

    public static let all: [RipulMacArea] = [
        .init(id: "screen", label: "Screen", icon: "display", view: "Watch the screen and its windows", control: "Use the mouse and keyboard"),
        .init(id: "dock", label: "Dock", icon: "dock.rectangle", view: "See the apps in the Dock", control: "Open, quit and rearrange apps"),
        .init(id: "processes", label: "Processes", icon: "cpu", view: "See what is running", control: "Quit processes"),
        .init(id: "tabs", label: "Browser tabs", icon: "macwindow.on.rectangle", view: "See the Mac's browser tabs", control: "Open and drive tabs"),
        .init(id: "files", label: "Files", icon: "folder", view: "Browse and read files", control: "Change files"),
        .init(id: "terminal", label: "Terminal", icon: "terminal", view: nil, control: "Run commands in a shell"),
        .init(id: "repos", label: "Repos", icon: "arrow.triangle.branch", view: "See repos, branches and commits", control: "Clone, switch branches and push"),
        .init(id: "scripts", label: "Scripts", icon: "scroll", view: "See the scripts", control: "Run, change and delete scripts"),
        .init(id: "devices", label: "Phones and simulators", icon: "iphone", view: "See devices and their screens", control: "Install, launch and touch"),
        .init(id: "trainyard", label: "Trainyard", icon: "tram.fill", view: "See builds and holds", control: "Request, hold and force builds"),
        .init(id: "system", label: "System", icon: "gauge.with.dots.needle.33percent", view: "See alerts, disk and system details", control: "Clear temporary files"),
    ]

    /// The area a recorded command or remote action belongs to, for the activity list.
    static func area(of command: String) -> RipulMacArea? {
        let prefixes: [(String, String)] = [
            ("dock:", "dock"), ("processes:", "processes"), ("screen:", "screen"), ("mirror:", "screen"),
            ("liveview:", "devices"), ("bridge:", "devices"), ("trainyard:", "trainyard"), ("script:", "scripts"),
            ("alerts:", "system"), ("agent:writeFile", "files"), ("agent:repo", "repos"), ("agent:git", "repos"),
            ("agent:script", "scripts"), ("agent:jobControl", "terminal"),
        ]
        guard let id = prefixes.first(where: { command.hasPrefix($0.0) })?.1 else { return nil }
        return all.first { $0.id == id }
    }
}

public struct RipulDepartmentActivity: Codable, Hashable {
    public let actorId: String
    public let actorName: String
    public let command: String
    public let chatId: String?
    public let createdAt: String
    public var date: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: createdAt) ?? ISO8601DateFormatter().date(from: createdAt)
    }
    public var title: String {
        switch command {
        case "agent:init": return "Created a chat"
        case "agent:start": return "Started a turn"
        case "agent:interrupt": return "Interrupted a turn"
        case "agent:execCommand": return "Ran a command"
        case "agent:setWorkingDirectory": return "Changed working folder"
        case "chat:share": return "Shared a chat with the team"
        case "chat:unshare": return "Made a chat private"
        default:
            if let area = RipulMacArea.area(of: command) { return "Used \(area.label)" }
            return "Updated the host"
        }
    }
}

public enum RipulTeamsError: LocalizedError {
    case notSignedIn
    case malformedResponse
    case transport(Error)
    /// `message` is the server's own wording, shown verbatim.
    case server(status: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Sign in to see your teams."
        case .malformedResponse: return "Unexpected response from the server."
        case .transport(let error): return error.localizedDescription
        case .server(_, let message): return message
        }
    }

    public var status: Int? {
        if case .server(let status, _) = self { return status }
        return nil
    }
}

/// What the signed-in account is allowed to do, as resolved by the server.
public struct RipulMe: Hashable {
    public let userId: String
    public let email: String?
    public let roleId: String
    public let subscriptionTier: String
    /// Holds the admin permission that bypasses every team membership check.
    public let isAdmin: Bool
    public let permissions: Set<String>
    /// `account:team_management` — may create teams (and delete the ones they own).
    public let canManageTeams: Bool

    init?(json: [String: Any]) {
        guard let userId = json["userId"] as? String else { return nil }
        self.userId = userId
        self.email = (json["email"] as? String)?.nilIfBlank
        self.roleId = json["roleId"] as? String ?? ""
        self.subscriptionTier = json["subscriptionTier"] as? String ?? "free"
        self.isAdmin = json["isAdmin"] as? Bool ?? false
        self.permissions = Set(json["permissions"] as? [String] ?? [])
        let can = json["can"] as? [String: Any]
        self.canManageTeams = can?["manageTeams"] as? Bool ?? permissions.contains("account:team_management")
    }
}

public enum RipulTeamRole: String, CaseIterable, Hashable, Comparable {
    case member, admin, owner

    public var label: String {
        switch self {
        case .member: return "Member"
        case .admin: return "Admin"
        case .owner: return "Owner"
        }
    }

    /// Owners and admins may change members, roles and the team itself.
    public var canManage: Bool { self != .member }

    private var rank: Int {
        switch self {
        case .member: return 0
        case .admin: return 1
        case .owner: return 2
        }
    }

    public static func < (lhs: RipulTeamRole, rhs: RipulTeamRole) -> Bool { lhs.rank < rhs.rank }
}

public struct RipulTeam: Identifiable, Hashable {
    public let id: String
    public let name: String
    public let slug: String
    public let description: String?
    public let solutionContextId: String?
    public let createdAt: Date?
    public let createdBy: String

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String, let name = json["name"] as? String else { return nil }
        self.id = id
        self.name = name
        self.slug = json["slug"] as? String ?? id
        self.description = (json["description"] as? String)?.nilIfBlank
        self.solutionContextId = (json["solutionContextId"] as? String)?.nilIfBlank
        self.createdAt = RipulTeamsDates.parse(json["createdAt"])
        self.createdBy = json["createdBy"] as? String ?? ""
    }
}

/// A person on a team. Profile fields are the server's best-effort Clerk
/// join; when it could not be made the row still stands, showing the user id.
public struct RipulTeamMember: Identifiable, Hashable {
    public let userId: String
    public let role: RipulTeamRole
    public let createdAt: Date?
    public let displayName: String?
    public let email: String?
    public let imageURL: String?

    public var id: String { userId }

    init?(json: [String: Any]) {
        guard let userId = json["userId"] as? String,
              let role = RipulTeamRole(rawValue: json["role"] as? String ?? "") else { return nil }
        self.userId = userId
        self.role = role
        self.createdAt = RipulTeamsDates.parse(json["createdAt"])
        self.displayName = (json["displayName"] as? String)?.nilIfBlank
        self.email = (json["email"] as? String)?.nilIfBlank
        self.imageURL = (json["imageUrl"] as? String)?.nilIfBlank
    }

    public var title: String { displayName ?? email ?? userId }

    /// The line under the title: the address when the title is a name, the
    /// user id when there was no profile at all — never the title repeated.
    public var subtitle: String? {
        if displayName != nil { return email }
        if email != nil { return nil }
        return nil
    }

    public var initials: String {
        let source = displayName ?? email ?? userId
        let parts = source.split(separator: " ").prefix(2).compactMap { $0.first }
        if parts.count == 2 { return String(parts).uppercased() }
        return String(source.prefix(1)).uppercased()
    }
}

/// One of the caller's memberships, as `GET /v1/my-teams` lists them.
public struct RipulTeamMembership: Identifiable, Hashable {
    public let teamId: String
    public let teamName: String
    public let role: RipulTeamRole

    public var id: String { teamId }

    init?(json: [String: Any]) {
        guard let teamId = json["teamId"] as? String,
              let role = RipulTeamRole(rawValue: json["role"] as? String ?? "") else { return nil }
        self.teamId = teamId
        self.teamName = json["teamName"] as? String ?? teamId
        self.role = role
    }
}

public struct RipulTeamInvite: Identifiable, Hashable {
    public let id: String
    public let teamId: String
    public let email: String
    public let role: RipulTeamRole
    public let status: String
    public let invitedBy: String
    public let createdAt: Date?
    public let expiresAt: Date?
    /// Present on the invitee's inbox rows only.
    public let teamName: String?
    public let teamDescription: String?
    public let inviterName: String?

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String,
              let teamId = json["teamId"] as? String,
              let email = json["email"] as? String,
              let role = RipulTeamRole(rawValue: json["role"] as? String ?? "") else { return nil }
        self.id = id
        self.teamId = teamId
        self.email = email
        self.role = role
        self.status = json["status"] as? String ?? "pending"
        self.invitedBy = json["invitedBy"] as? String ?? ""
        self.createdAt = RipulTeamsDates.parse(json["createdAt"])
        self.expiresAt = RipulTeamsDates.parse(json["expiresAt"])
        self.teamName = (json["teamName"] as? String)?.nilIfBlank
        self.teamDescription = (json["teamDescription"] as? String)?.nilIfBlank
        self.inviterName = (json["inviterName"] as? String)?.nilIfBlank
    }
}

public struct RipulTeamDetail: Hashable {
    public let team: RipulTeam
    public let members: [RipulTeamMember]

    init?(json: [String: Any]) {
        guard let team = RipulTeam(json: json) else { return nil }
        self.team = team
        self.members = (json["members"] as? [[String: Any]] ?? []).compactMap(RipulTeamMember.init(json:))
    }
}

enum RipulTeamsDates {
    /// The server sends ISO-8601 with fractional seconds; accept both forms.
    static func parse(_ value: Any?) -> Date? {
        guard let string = (value as? String)?.nilIfBlank else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}

public final class RipulTeamsClient {
    private let baseURL: URL
    private let tokenProvider: () -> String?

    public init(
        baseURL: URL = AgentConfiguration.defaultBaseURL,
        tokenProvider: @escaping () -> String?
    ) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
    }

    // MARK: Identity

    public func me() async throws -> RipulMe {
        let json = try await send("GET", "api/v1/me")
        guard let me = RipulMe(json: json) else { throw RipulTeamsError.malformedResponse }
        return me
    }

    // MARK: Teams

    public func departmentHosts(teamId: String) async throws -> [RipulDepartmentHost] {
        let json = try await send("GET", "api/v1/teams/\(encode(teamId))/hosts")
        return try JSONDecoder().decode([RipulDepartmentHost].self, from: JSONSerialization.data(withJSONObject: json["hosts"] ?? []))
    }

    public func availableHostMachines() async throws -> [RemoteMachine] {
        let json = try await send("GET", "api/v1/relay/machines")
        return try JSONDecoder().decode([RemoteMachine].self, from: JSONSerialization.data(withJSONObject: json["machines"] ?? []))
    }

    public func shareHost(teamId: String, machineId: String) async throws {
        _ = try await send("POST", "api/v1/teams/\(encode(teamId))/hosts", body: ["machineId": machineId])
    }

    /// Set what one team role may use of a Mac beyond its chats. Only the
    /// Mac's own owner may; the server says so to anyone else.
    public func setHostAccess(teamId: String, machineId: String, role: RipulMacRole,
                              access: [String: String]) async throws -> RipulSharedMacAccess {
        let json = try await send("PUT", "api/v1/teams/\(encode(teamId))/hosts/access",
                                  body: ["machineId": machineId, "role": role.rawValue, "access": access])
        return try JSONDecoder().decode(RipulSharedMacAccess.self,
                                        from: JSONSerialization.data(withJSONObject: json["sharing"] ?? [:]))
    }

    public func removeHost(teamId: String, host: RipulDepartmentHost) async throws {
        _ = try await send("DELETE", "api/v1/teams/\(encode(teamId))/hosts", body: ["machineId": host.machineId, "ownerId": host.ownerId])
    }

    public func hostActivity(_ host: RipulDepartmentHost) async throws -> [RipulDepartmentActivity] {
        let json = try await send("GET", "api/v1/department-hosts/\(encode(host.ownerId))/\(encode(host.machineId))/activity")
        return try JSONDecoder().decode([RipulDepartmentActivity].self, from: JSONSerialization.data(withJSONObject: json["activity"] ?? []))
    }

    /// The caller's memberships, with the role held in each.
    public func myMemberships() async throws -> [RipulTeamMembership] {
        let json = try await send("GET", "api/v1/my-teams")
        return (json["memberships"] as? [[String: Any]] ?? []).compactMap(RipulTeamMembership.init(json:))
    }

    /// Every team for an admin; only the caller's own teams otherwise.
    public func listTeams() async throws -> [RipulTeam] {
        let json = try await send("GET", "api/v1/teams")
        return (json["teams"] as? [[String: Any]] ?? []).compactMap(RipulTeam.init(json:))
    }

    public func team(_ teamId: String) async throws -> RipulTeamDetail {
        let json = try await send("GET", "api/v1/teams/\(encode(teamId))")
        guard let detail = RipulTeamDetail(json: json) else { throw RipulTeamsError.malformedResponse }
        return detail
    }

    public func createTeam(name: String, description: String?) async throws -> RipulTeam {
        var body: [String: Any] = ["name": name]
        if let description = description?.nilIfBlank { body["description"] = description }
        let json = try await send("POST", "api/v1/teams", body: body)
        guard let team = RipulTeam(json: json) else { throw RipulTeamsError.malformedResponse }
        return team
    }

    public func updateTeam(_ teamId: String, name: String, description: String?) async throws -> RipulTeam {
        // An empty description clears it; the server keeps the old one when
        // the key is absent, so send it explicitly.
        let body: [String: Any] = ["name": name, "description": description ?? ""]
        let json = try await send("PATCH", "api/v1/teams/\(encode(teamId))", body: body)
        guard let team = RipulTeam(json: json) else { throw RipulTeamsError.malformedResponse }
        return team
    }

    public func deleteTeam(_ teamId: String) async throws {
        _ = try await send("DELETE", "api/v1/teams/\(encode(teamId))")
    }

    // MARK: Members

    /// Direct add by Clerk user id — admins have the Users screen to find one.
    public func addMember(teamId: String, userId: String, role: RipulTeamRole) async throws {
        _ = try await send("POST", "api/v1/teams/\(encode(teamId))/members",
                           body: ["userId": userId, "role": role.rawValue])
    }

    public func updateMemberRole(teamId: String, userId: String, role: RipulTeamRole) async throws {
        _ = try await send("PATCH", "api/v1/teams/\(encode(teamId))/members/\(encode(userId))",
                           body: ["role": role.rawValue])
    }

    public func removeMember(teamId: String, userId: String) async throws {
        _ = try await send("DELETE", "api/v1/teams/\(encode(teamId))/members/\(encode(userId))")
    }

    // MARK: Invitations (team side)

    public func invites(teamId: String) async throws -> [RipulTeamInvite] {
        let json = try await send("GET", "api/v1/teams/\(encode(teamId))/invites")
        return (json["invites"] as? [[String: Any]] ?? []).compactMap(RipulTeamInvite.init(json:))
    }

    @discardableResult
    public func invite(teamId: String, email: String, role: RipulTeamRole) async throws -> RipulTeamInvite {
        let json = try await send("POST", "api/v1/teams/\(encode(teamId))/invites",
                                  body: ["email": email, "role": role.rawValue])
        guard let row = json["invite"] as? [String: Any], let invite = RipulTeamInvite(json: row) else {
            throw RipulTeamsError.malformedResponse
        }
        return invite
    }

    public func revokeInvite(teamId: String, inviteId: String) async throws {
        _ = try await send("DELETE", "api/v1/teams/\(encode(teamId))/invites/\(encode(inviteId))")
    }

    // MARK: Invitations (invitee side)

    public func myInvites() async throws -> [RipulTeamInvite] {
        let json = try await send("GET", "api/v1/my-team-invites")
        return (json["invites"] as? [[String: Any]] ?? []).compactMap(RipulTeamInvite.init(json:))
    }

    /// Accepts as the signed-in account; returns the team joined.
    @discardableResult
    public func acceptInvite(_ inviteId: String) async throws -> RipulTeam {
        let json = try await send("POST", "api/v1/my-team-invites/\(encode(inviteId))/accept")
        guard let row = json["team"] as? [String: Any], let team = RipulTeam(json: row) else {
            throw RipulTeamsError.malformedResponse
        }
        return team
    }

    public func declineInvite(_ inviteId: String) async throws {
        _ = try await send("POST", "api/v1/my-team-invites/\(encode(inviteId))/decline")
    }

    // MARK: Transport

    private func encode(_ segment: String) -> String {
        segment.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? segment
    }

    private func send(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        guard let token = tokenProvider(), !token.isEmpty else {
            throw RipulTeamsError.notSignedIn
        }
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw RipulTeamsError.malformedResponse
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
            throw RipulTeamsError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw RipulTeamsError.malformedResponse
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(http.statusCode) else {
            // `{ error: { message } }` is the worker's shape; fall back to the
            // raw body, then to the status, so the user always sees *something*.
            let message = ((object?["error"] as? [String: Any])?["message"] as? String)
                ?? String(data: data, encoding: .utf8)?.nilIfBlank
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw RipulTeamsError.server(status: http.statusCode, message: message)
        }
        return object ?? [:]
    }
}

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
