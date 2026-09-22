import Foundation

// Stand-ins for the RipulAgent symbols RipulInviteManager.swift uses, so the
// production file compiles on its own.
public enum AgentConfiguration { public static let defaultBaseURL = URL(string: "https://invites.test")! }

public protocol RipulSessionCache: AnyObject {
    func stringArray(forKey key: String) -> [String]?
    func set(_ value: Any?, forKey key: String)
}

public final class MemoryCache: RipulSessionCache {
    var values: [String: Any] = [:]
    public func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    public func set(_ value: Any?, forKey key: String) { values[key] = value }
}

/// The app's token store, as its `configure(authStore:)` adapter reads it.
@MainActor final class AuthTokenStore {
    var userId: String? = "alice"
    var forcedRefreshes = 0
    func requestToken(forceRefresh: Bool = false) async -> String? {
        if forceRefresh { forcedRefreshes += 1 }
        return userId.map { "\($0)-\(forceRefresh ? "fresh" : "cached")" }
    }
}

/// A Clerk-shaped JWT for `subject` (unsigned; only the payload is read).
func jwt(_ subject: String) -> String {
    func b64url(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    return "\(b64url("{\"alg\":\"RS256\"}")).\(b64url("{\"sub\":\"\(subject)\",\"exp\":1}")).sig"
}
