import Foundation

// ---------------------------------------------------------------------------
// Native client for the PLATFORM USERS directory — the people with a Ripul
// account, as opposed to `site_key_owners`, which are a portal's CMS users.
//
// The distinction matters and is easy to get wrong: a site-key owner row
// carries its own `role` (owner/admin/manager/…) governing that portal, and it
// lives in D1. A *Ripul* user is a Clerk identity, and their platform role is
// not stored anywhere — the API derives it per-request from the session token
// (`resolveForUser` in permissions/resolver.ts): the `role` claim if it reads
// "admin", otherwise the subscription tier. So the only source of truth is
// Clerk, reachable solely through `GET /admin/users`, which holds the secret
// key server-side.
//
// Read-only by design. Changing a tier or granting admin is a Clerk-dashboard
// act with billing consequences; this surface answers "who is this person and
// what can they do", nothing more.
// ---------------------------------------------------------------------------

/// One Ripul account, as projected by `GET /admin/users`.
public struct RipulPlatformUser: Identifiable, Hashable {
    public let id: String
    public let email: String
    public let firstName: String?
    public let lastName: String?
    public let username: String?
    public let imageURL: String?
    /// Clerk `public_metadata.role`. Only the literal "admin" is load-bearing —
    /// `isAdmin()` in auth/clerk.ts tests for exactly that string.
    public let role: String?
    /// "free" | "pro" | "enterprise".
    public let tier: String
    public let quotaUsed: Int
    public let quotaLimit: Int
    public let percentUsed: Int
    public let lastActive: Date?
    public let createdAt: Date?

    init?(json: [String: Any]) {
        guard let id = json["userId"] as? String else { return nil }
        self.id = id
        self.email = json["email"] as? String ?? "—"
        self.firstName = (json["firstName"] as? String)?.nilIfBlank
        self.lastName = (json["lastName"] as? String)?.nilIfBlank
        self.username = (json["username"] as? String)?.nilIfBlank
        self.imageURL = (json["imageUrl"] as? String)?.nilIfBlank
        self.role = (json["role"] as? String)?.nilIfBlank
        self.tier = json["tier"] as? String ?? "free"
        self.quotaUsed = json["quotaUsed"] as? Int ?? 0
        self.quotaLimit = json["quotaLimit"] as? Int ?? 0
        self.percentUsed = json["percentUsed"] as? Int ?? 0
        self.lastActive = RipulPlatformUser.date(json["lastActive"])
        self.createdAt = RipulPlatformUser.date(json["createdAt"])
    }

    /// The server sends ISO-8601; `.withInternetDateTime` alone rejects the
    /// fractional seconds `Date.toISOString()` always emits, so try both.
    private static func date(_ value: Any?) -> Date? {
        guard let string = (value as? String)?.nilIfBlank else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    public var isAdmin: Bool { role?.lowercased() == "admin" }

    public var displayName: String {
        let full = [firstName, lastName].compactMap { $0 }.joined(separator: " ")
        if !full.isEmpty { return full }
        if let username { return username }
        return email
    }

    public var initials: String {
        let parts = [firstName, lastName].compactMap { $0?.first }
        if !parts.isEmpty { return String(parts).uppercased() }
        return String(email.prefix(1)).uppercased()
    }

    /// The role the API would actually resolve for this person, mirroring
    /// `PermissionResolver.resolveForUser`: admin wins, otherwise the tier
    /// decides. Shown verbatim so the screen answers the same question the
    /// server would.
    public var resolvedRoleId: String {
        isAdmin ? "admin:standard" : "user:\(tier)"
    }

    /// Section heading — admins are pulled out of the tier ordering entirely,
    /// because being an admin is what matters about them.
    public var group: String {
        if isAdmin { return "Admins" }
        switch tier {
        case "enterprise": return "Enterprise"
        case "pro": return "Pro"
        default: return "Free"
        }
    }
}

public final class RipulUsersClient {
    private let baseURL: URL
    private let tokenProvider: () -> String?

    public init(
        baseURL: URL = AgentConfiguration.defaultBaseURL,
        tokenProvider: @escaping () -> String?
    ) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
    }

    /// Every Ripul account. The server walks Clerk's paginated list to
    /// exhaustion (`fetchClerkUsers`), so there is no paging to do here — but
    /// it also means the call costs one Clerk round-trip per 100 users and a
    /// KV read per user. Load once and refresh on pull, never on keystroke.
    public func list() async throws -> [RipulPlatformUser] {
        guard let token = tokenProvider(), !token.isEmpty else {
            throw RipulSolutionContextsError.notSignedIn
        }
        guard let url = URL(string: "api/admin/users", relativeTo: baseURL) else {
            throw RipulSolutionContextsError.malformedResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

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
            // A 403 here is the ordinary case for a non-admin, not a fault:
            // the route demands `admin:manage_users`.
            throw RipulSolutionContextsError.serverError(status: http.statusCode, body: data)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["users"] as? [[String: Any]] else {
            throw RipulSolutionContextsError.malformedResponse
        }
        return rows.compactMap(RipulPlatformUser.init(json:))
    }
}

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
