import Foundation

/// Who the session-list stack currently believes it is signed in as.
///
/// Every server-derived thing the list caches — machines, sessions, their
/// last-active times, the seeded dev context — belongs to ONE Clerk account.
/// Nothing in `UserDefaults` says which, so the caches have to be stamped with
/// an identity that can be compared on the next launch or the next token.
///
/// The Clerk `sub` claim is that identity. It is read, never verified: this is
/// a cache-invalidation key, not an authorization decision — the server
/// re-checks the token on every request regardless.
public enum RipulAccountIdentity {

    /// The `sub` claim of a Clerk JWT — the user id — without verifying it.
    /// Used only to tell one signed-in account from another.
    ///
    /// Returns nil for a nil/malformed token, which callers MUST read as
    /// "unknown, don't act" rather than "signed out": the token provider
    /// returns nil for the whole pre-auth window of a cold launch, and
    /// treating that as an account change would wipe the caches on every
    /// start.
    public static func subject(ofJWT token: String?) -> String? {
        guard let token else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return claims["sub"] as? String
    }
}
