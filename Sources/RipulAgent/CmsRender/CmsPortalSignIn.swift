import Foundation
import SwiftUI
import AuthenticationServices
import CryptoKit
import Security

// Signing a member in with a site's own identity provider (the site key's
// `portalAuth` 'clerk', bring your own identity provider: WAC's business accounts
// at clerk.wac.rocks), with no web view anywhere. The worker's twin is
// chrome-extension/packages/api/src/siteKeys/nativeHandoff.ts (an authorization
// code with PKCE, RFC 7636):
//
// 1. The app opens the system's sign-in sheet (`WebAuthenticationSession`, i.e.
//    ASWebAuthenticationSession) on `<site>/portal-session?pk=…&siteKey=…&redirect=…&challenge=…`.
//    The page signs the person in with the provider on the site's own address,
//    asks the worker for a one-time code and sends the browser to the app's
//    redirect with it.
// 2. The app trades the code and its verifier for a session of its own (`rns_…`,
//    30 days), kept in the Keychain.
// 3. Every portal request carries it as the Bearer (`CmsClientConfig.portalTokenProvider`),
//    taken by the worker as the same member the provider signed in.
//
// The site key must list the redirect (`portalAuth.nativeRedirects`), or the
// page and the exchange refuse it.

/// A member of a site, as its identity provider names them.
public struct CmsPortalMember: Equatable, Codable, Sendable {
    public var id: String
    public var email: String?
    public var name: String?

    public init(id: String, email: String? = nil, name: String? = nil) {
        self.id = id
        self.email = email
        self.name = name
    }
}

/// Why signing in didn't finish.
public enum CmsPortalSignInError: LocalizedError, Equatable {
    /// The person closed the sign-in sheet.
    case cancelled
    /// The worker refused, in its own words (a used or expired code, a site that
    /// doesn't sign in to apps, too many tries).
    case refused(String)
    /// The network, or an answer that couldn't be read.
    case failed

    public var errorDescription: String? {
        switch self {
        case .cancelled: return "Signing in was cancelled."
        case .refused(let message): return message
        case .failed: return "Signing in didn't finish. Check the connection and try again."
        }
    }
}

/// PKCE's S256 (RFC 7636 §4): a random verifier, and the challenge sent ahead of it.
enum CmsPKCE {
    /// 32 random bytes as unpadded base64url: 43 characters.
    static func verifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "no random bytes for a PKCE verifier")
        return base64url(Data(bytes))
    }

    /// base64url(SHA-256(verifier)), unpadded.
    static func challenge(for verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// The handoff's addresses and answers, apart from the sheet and the Keychain.
struct CmsPortalHandoff {
    let siteURL: URL
    let providerKey: String
    let siteKey: String
    let redirect: URL
    let apiBase: String

    /// The page the sign-in sheet opens. `promptLogin` signs the provider out
    /// first, so a person who just signed out chooses an account again.
    func signInURL(challenge: String, promptLogin: Bool) -> URL {
        var components = URLComponents(url: siteURL, resolvingAgainstBaseURL: false)!
        components.path = "/portal-session"
        components.queryItems = [
            URLQueryItem(name: "pk", value: providerKey),
            URLQueryItem(name: "siteKey", value: siteKey),
            URLQueryItem(name: "redirect", value: redirect.absoluteString),
            URLQueryItem(name: "challenge", value: challenge),
        ] + (promptLogin ? [URLQueryItem(name: "prompt", value: "login")] : [])
        return components.url!
    }

    /// The one-time code in the redirect the page sent the browser to.
    func code(in callback: URL) -> String? {
        guard callback.scheme == redirect.scheme else { return nil }
        let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "code" }?.value
        return code.flatMap { $0.hasPrefix("rnc_") ? $0 : nil }
    }

    func exchangeRequest(code: String, verifier: String) -> URLRequest {
        var request = URLRequest(url: URL(string: apiBase + "/v1/site-key/native-handoff/exchange")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "siteKey": siteKey, "code": code, "verifier": verifier, "redirect": redirect.absoluteString,
        ])
        return request
    }

    func signOutRequest(token: String) -> URLRequest {
        var request = URLRequest(url: URL(string: apiBase + "/v1/site-key/native-handoff/session")!)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// The exchange's answer: `{ token, expiresAt, member: { id, email } }`.
    struct Exchanged: Decodable {
        struct Member: Decodable { let id: String; let email: String? }
        let token: String
        let expiresAt: String
        let member: Member
    }

    static func expiry(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

/// What the Keychain keeps for one site: the session and who it is for.
struct CmsPortalStoredSession: Codable, Equatable {
    var token: String
    var expiresAt: Date
    var member: CmsPortalMember
}

/// A site's own sign-in for a native app: the system's sign-in sheet, then a
/// session of the app's own in the Keychain. One per app.
@MainActor
public final class CmsPortalSession: ObservableObject {
    public enum State: Equatable {
        case signedOut
        /// The sign-in sheet is open, or the code is being exchanged.
        case signingIn
        case signedIn(CmsPortalMember)
    }

    @Published public private(set) var state: State

    public var member: CmsPortalMember? {
        if case .signedIn(let member) = state { return member }
        return nil
    }

    private let handoff: CmsPortalHandoff
    private let keychainService: String
    private var stored: CmsPortalStoredSession?

    /// - Parameters:
    ///   - siteURL: The site's own address, e.g. `https://business.wac.rocks`.
    ///   - providerKey: The identity provider's publishable key (`portalAuth.clerkPublishableKey`).
    ///   - siteKey: The site key's publishable key.
    ///   - redirect: The app's address the page sends the code to; the site key
    ///     must list it (`portalAuth.nativeRedirects`).
    ///   - keychainService: Where the session is kept.
    public init(siteURL: URL, providerKey: String, siteKey: String, redirect: URL,
                apiBase: String = RipulDomain.llmProxyURL,
                keychainService: String = "io.ripul.cms.portal-session") {
        handoff = CmsPortalHandoff(siteURL: siteURL, providerKey: providerKey, siteKey: siteKey,
                                   redirect: redirect, apiBase: apiBase)
        self.keychainService = keychainService
        stored = Self.read(service: keychainService, account: siteKey)
        if let stored, stored.expiresAt > Date() {
            state = .signedIn(stored.member)
        } else {
            state = .signedOut
        }
    }

    /// The session's token while it lasts; nil when signed out or expired.
    public func token() -> String? {
        guard let stored else { return nil }
        guard stored.expiresAt > Date() else {
            forget()
            return nil
        }
        return stored.token
    }

    /// Opens the site's sign-in in the system's sheet and, once the person is
    /// signed in there, exchanges the code for the app's own session. Pass the
    /// view's `@Environment(\.webAuthenticationSession)`.
    public func signIn(using authentication: WebAuthenticationSession) async throws {
        guard let scheme = handoff.redirect.scheme else { throw CmsPortalSignInError.failed }
        let verifier = CmsPKCE.verifier()
        let url = handoff.signInURL(challenge: CmsPKCE.challenge(for: verifier), promptLogin: promptLogin)
        state = .signingIn
        do {
            // A private browser session: iOS asks nothing first (the shared one opens
            // with "…Wants to Use … to Sign In. This allows the app and website to
            // share information about you"), and nothing of Safari's carries over.
            // The app's own session lasts 30 days, so a sign-in is rare.
            let callback = try await authentication.authenticate(
                using: url, callbackURLScheme: scheme, preferredBrowserSession: .ephemeral)
            guard let code = handoff.code(in: callback) else { throw CmsPortalSignInError.failed }
            let (data, response) = try await URLSession.shared.data(for: handoff.exchangeRequest(code: code, verifier: verifier))
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                throw message.map(CmsPortalSignInError.refused) ?? CmsPortalSignInError.failed
            }
            let exchanged = try JSONDecoder().decode(CmsPortalHandoff.Exchanged.self, from: data)
            guard let expiresAt = CmsPortalHandoff.expiry(exchanged.expiresAt) else { throw CmsPortalSignInError.failed }
            let session = CmsPortalStoredSession(
                token: exchanged.token, expiresAt: expiresAt,
                member: CmsPortalMember(id: exchanged.member.id, email: exchanged.member.email)
            )
            Self.write(session, service: keychainService, account: handoff.siteKey)
            stored = session
            promptLogin = false
            state = .signedIn(session.member)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            state = .signedOut
            throw CmsPortalSignInError.cancelled
        } catch let error as CmsPortalSignInError {
            state = .signedOut
            throw error
        } catch {
            state = .signedOut
            throw CmsPortalSignInError.failed
        }
    }

    /// Ends the session on the server and forgets it here. The next sign-in asks
    /// the provider to choose an account again.
    public func signOut() async {
        if let token = stored?.token {
            _ = try? await URLSession.shared.data(for: handoff.signOutRequest(token: token))
        }
        promptLogin = true
        forget()
    }

    /// The server no longer takes the session (it ended elsewhere): forget it
    /// here, so the app shows sign-in.
    public func sessionEnded() {
        forget()
    }

    private func forget() {
        stored = nil
        Self.delete(service: keychainService, account: handoff.siteKey)
        state = .signedOut
    }

    /// After a sign-out, the next sign-in starts with `prompt=login`.
    private var promptLogin: Bool {
        get { UserDefaults.standard.bool(forKey: "\(keychainService).promptLogin.\(handoff.siteKey)") }
        set { UserDefaults.standard.set(newValue, forKey: "\(keychainService).promptLogin.\(handoff.siteKey)") }
    }

    // MARK: Keychain

    private static func query(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func read(service: String, account: String) -> CmsPortalStoredSession? {
        var query = query(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(CmsPortalStoredSession.self, from: data)
    }

    private static func write(_ session: CmsPortalStoredSession, service: String, account: String) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        delete(service: service, account: account)
        var attributes = query(service: service, account: account)
        attributes[kSecValueData as String] = data
        // Readable once the phone has been unlocked after starting, so a launch in
        // the background (a link, a Live Activity) still has the session.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }

    private static func delete(service: String, account: String) {
        SecItemDelete(query(service: service, account: account) as CFDictionary)
    }
}
