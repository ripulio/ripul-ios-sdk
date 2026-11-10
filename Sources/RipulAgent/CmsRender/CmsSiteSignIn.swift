import Foundation
import Security

// A site's own sign-in by an emailed code (the site key's `portalAuth`
// provider 'email', as Sandsend Retreats'), for a native app. The twin of the
// web's `src/auth/siteSignIn.ts` and `EmailCodeAdapter.tsx`, over the same
// worker routes (packages/api/src/siteKeys/emailSignIn.ts):
//
//   POST   /v1/site-key/sign-in/code    {siteKey, email}      → {sent: true}
//   POST   /v1/site-key/sign-in/verify  {siteKey, email, code} → {token, email, expiresAt}
//   DELETE /v1/site-key/sign-in/session  Bearer <token>
//
// Both POSTs are refused unless the request comes from one of the site key's
// allowed origins, so they present the app's `CmsClientConfig.origin`.
//
// The session is kept in the Keychain, one per site key, never in defaults. The
// token is a Bearer on the site's portal routes (query runs, `/site-key/me`) and
// on its booking routes (`/v1/cms-bookings/<site>/guest|staff/...`). A code
// reaches the app only from the person typing it.

/// A signed-in session on one site: what `verify` answers.
public struct CmsSiteSession: Codable, Equatable, Sendable {
    public var token: String
    public var email: String
    /// ISO 8601, as the server writes it.
    public var expiresAt: String

    public init(token: String, email: String, expiresAt: String) {
        self.token = token
        self.email = email
        self.expiresAt = expiresAt
    }

    /// The web's `parseSiteSession`: a session with all three and not run out.
    public func isValid(now: Date = Date()) -> Bool {
        guard !token.isEmpty, !email.isEmpty, let expires = Self.date(expiresAt) else { return false }
        return expires > now
    }

    static func date(_ iso: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    }
}

/// Where a site's session is kept. The Keychain in an app; memory in tests.
public protocol CmsSiteSessionStore: Sendable {
    func load(siteKey: String) -> CmsSiteSession?
    func save(_ session: CmsSiteSession?, siteKey: String)
}

/// The Keychain, one generic password per site key, readable after the first
/// unlock and never leaving this device (no iCloud Keychain, no backup restore
/// onto another phone).
public struct CmsKeychainSiteSessionStore: CmsSiteSessionStore {
    static let service = "io.ripul.cms.site-sign-in"

    public init() {}

    private func query(_ siteKey: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: siteKey]
    }

    public func load(siteKey: String) -> CmsSiteSession? {
        // A simulator developer build takes a test identity's session the
        // host dropped (CmsTestSessionDrop); every other build skips this.
        if CmsTestSessionDrop.enabled,
           let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
           let dropped = CmsTestSessionDrop.take(siteKey: siteKey, caches: caches) {
            save(dropped, siteKey: siteKey)
            return dropped
        }
        var q = query(siteKey)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(CmsSiteSession.self, from: data)
    }

    public func save(_ session: CmsSiteSession?, siteKey: String) {
        SecItemDelete(query(siteKey) as CFDictionary)
        guard let session, let data = try? JSONEncoder().encode(session) else { return }
        var q = query(siteKey)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
}

/// A store in memory, for tests and previews.
public final class CmsMemorySiteSessionStore: CmsSiteSessionStore, @unchecked Sendable {
    private var sessions: [String: CmsSiteSession] = [:]
    private let lock = NSLock()
    public init() {}
    public func load(siteKey: String) -> CmsSiteSession? { lock.withLock { sessions[siteKey] } }
    public func save(_ session: CmsSiteSession?, siteKey: String) { lock.withLock { sessions[siteKey] = session } }
}

/// The rules the web's forms apply to what is typed, kept apart so they can be tested.
public enum CmsSiteSignInRules {
    /// The authForm's `emailOk`.
    public static func isEmail(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil
    }

    /// What the code field keeps: digits and spaces, at most seven characters
    /// (the guest form's `replace(/[^\d ]/g, '').slice(0, 7)`).
    public static func codeField(_ text: String) -> String {
        String(text.filter { $0.isASCII && ($0.isNumber || $0 == " ") }.prefix(7))
    }

    /// The code as sent: spaces removed. Six digits is the only code there is.
    public static func code(_ text: String) -> String { text.filter { !$0.isWhitespace } }

    public static func isCompleteCode(_ text: String) -> Bool {
        code(text).range(of: #"^\d{6}$"#, options: .regularExpression) != nil
    }
}

/// Whether a site key's embedded config says it signs people in by email.
public enum CmsSiteSignInConfig {
    /// `config.portalAuth.provider == 'email'` in a validate response's config JSON.
    public static func signsInByEmail(configJSON: Data) -> Bool {
        struct Config: Decodable {
            struct PortalAuth: Decodable { var provider: String? }
            var portalAuth: PortalAuth?
        }
        return (try? JSONDecoder().decode(Config.self, from: configJSON))?.portalAuth?.provider == "email"
    }
}

public enum CmsSiteSignInError: Error, LocalizedError, Equatable {
    /// The server's own words (`{error}`), or the web's fallback for that step.
    case refused(status: Int, message: String)
    /// The session the request carried is no longer known (401): signed out.
    case signedOut
    case askForCodeFirst

    public var errorDescription: String? {
        switch self {
        case .refused(_, let message): return message
        case .signedOut: return "Your sign-in has run out; please sign in again."
        case .askForCodeFirst: return "Ask for a code first."
        }
    }
}

/// One site's sign-in for a native app: who is signed in, asking for and
/// checking a code, the token for requests, and signing out. One per site key,
/// made by the page loader when the site signs in by email
/// (`CmsRuntime.siteSignIn`).
@MainActor
public final class CmsSiteSignIn: ObservableObject {
    /// The signed-in person's email, or nil. The token itself is not published.
    @Published public private(set) var email: String?
    /// The address the last code went to, which the code is checked against.
    @Published public private(set) var pendingEmail: String?

    public let siteKey: String
    let baseUrl: String
    let origin: String
    private let store: CmsSiteSessionStore
    private let send: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private var session: CmsSiteSession?
    /// Told after signing in or out, with the new email (the loader re-reads
    /// who the person is on the site).
    var onChange: ((String?) -> Void)?

    public var isSignedIn: Bool { email != nil }

    public init(
        siteKey: String,
        origin: String,
        baseUrl: String = RipulDomain.llmProxyURL,
        store: CmsSiteSessionStore = CmsKeychainSiteSessionStore(),
        send: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }
    ) {
        self.siteKey = siteKey
        self.origin = origin
        self.baseUrl = baseUrl
        self.store = store
        self.send = send
        let saved = store.load(siteKey: siteKey)
        if let saved, saved.isValid() {
            session = saved
            email = saved.email
        } else if saved != nil {
            store.save(nil, siteKey: siteKey)
        }
    }

    /// The session's token, or nil when nobody is signed in or it has run out.
    public func token() -> String? {
        guard let session else { return nil }
        guard session.isValid() else {
            keep(nil)
            return nil
        }
        return session.token
    }

    /// Email a sign-in code. The answer is the same whether or not the email
    /// belongs to anyone. The code email's link goes to the website (the site's
    /// `signInUrl`): the app sends none of its own.
    public func sendCode(to email: String) async throws {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await post("code", ["siteKey": siteKey, "email": trimmed],
                           fallback: "The code could not be sent; please try again.")
        pendingEmail = trimmed
    }

    /// Check the code sent to `pendingEmail`; a match signs in and keeps the session.
    public func verify(code: String) async throws {
        guard let pendingEmail else { throw CmsSiteSignInError.askForCodeFirst }
        let data = try await post("verify", ["siteKey": siteKey, "email": pendingEmail, "code": CmsSiteSignInRules.code(code)],
                                  fallback: "That did not work; please try again.")
        guard let session = try? JSONDecoder().decode(CmsSiteSession.self, from: data), session.isValid() else {
            throw CmsSiteSignInError.refused(status: 200, message: "That did not work; please try again.")
        }
        self.pendingEmail = nil
        keep(session)
    }

    /// Back to asking for an email (the form's "Use a different email").
    public func startAgain() { pendingEmail = nil }

    /// Sign out here, and end the session on the server.
    public func signOut() async {
        let token = session?.token
        keep(nil)
        guard let token, let url = URL(string: baseUrl + "/v1/site-key/sign-in/session") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try? await send(request)
    }

    /// A session the server no longer knows (it answered 401): forget it here too.
    public func forget() { keep(nil) }

    private func keep(_ next: CmsSiteSession?) {
        let changed = next?.email != email
        session = next
        email = next?.email
        store.save(next, siteKey: siteKey)
        if changed { onChange?(email) }
    }

    private func post(_ action: String, _ body: [String: String], fallback: String) async throws -> Data {
        guard let url = URL(string: baseUrl + "/v1/site-key/sign-in/" + action) else {
            throw CmsSiteSignInError.refused(status: 0, message: fallback)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The site's own address: the routes refuse any other.
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await send(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw CmsSiteSignInError.refused(status: status, message: CmsSiteSignInError.message(in: data) ?? fallback)
        }
        return data
    }
}

extension CmsSiteSignInError {
    /// The `error` of a JSON refusal.
    static func message(in data: Data) -> String? {
        struct Refusal: Decodable { var error: String? }
        return (try? JSONDecoder().decode(Refusal.self, from: data))?.error.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// A request for the site's sign-in sheet.
public struct CmsSignInRequest: Identifiable, Equatable {
    public let id = UUID()
    /// The page to open once signed in.
    public var returnTo: String?

    public init(returnTo: String? = nil) { self.returnTo = returnTo }
}

/// What the emailed-code form says at each step. The web has two forms over the
/// one sign-in, worded differently: the `authForm` block on a sign-in page, and
/// the sign-in inside My bookings (`guestBookings`). Each is kept as written.
public struct CmsSiteSignInWording {
    public var heading: String?
    /// Above the email field.
    public var emailIntro: String
    public var emailLabel: String
    public var sendButton: String
    public var sendingButton: String
    public var codeHeading: String?
    /// Above the code field, for the address the code went to.
    public var codeIntro: (String) -> String
    public var codeButton: String
    public var checkingButton: String
    public var resend: String
    public var otherEmail: String
    public var footnote: String?
    /// Under the email field when what was typed is not an email (after a try).
    public var emailProblem: (String) -> String
    public var sendFallback: String
    public var verifyFallback: String

    /// The `authForm` block on a site that signs in by email (`codeOnly`).
    public static func authForm(_ props: [String: CmsJSON]) -> CmsSiteSignInWording {
        func text(_ key: String, _ fallback: String) -> String {
            let value = props.string(key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? fallback : value
        }
        let emailLabel = text("emailLabel", "Email")
        let footnote = props.string("signInFootnote")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return CmsSiteSignInWording(
            heading: text("signInHeading", "Welcome back"),
            emailIntro: "Enter your email and we will send you a 6-digit code to sign in.",
            emailLabel: emailLabel,
            sendButton: "Email me a code",
            sendingButton: "One moment…",
            codeHeading: "Check your email",
            codeIntro: { "We sent a code to \($0). Enter it to sign in." },
            codeButton: "Continue",
            checkingButton: "Checking…",
            resend: "Resend code",
            otherEmail: "Use a different email",
            footnote: footnote.isEmpty ? nil : footnote,
            emailProblem: { $0.isEmpty ? "\(emailLabel) is required." : "Enter a valid email address." },
            sendFallback: "Could not send a code to that address.",
            verifyFallback: "Could not verify that code."
        )
    }

    /// The returning guest's sign-in from the availability calendar's checkout
    /// (the web's ReturningGuest, AvailabilityCheckout.tsx): the chosen stay is kept.
    public static let returningGuest = CmsSiteSignInWording(
        heading: nil,
        emailIntro: "Enter the email you booked with and we will send you a 6-digit code.",
        emailLabel: "Email",
        sendButton: "Email me a code",
        sendingButton: "Email me a code",
        codeHeading: nil,
        codeIntro: { "Enter the code we sent to \($0). Your chosen stay is kept." },
        codeButton: "Sign in",
        checkingButton: "Sign in",
        resend: "Send a new code",
        otherEmail: "Use a different email",
        footnote: nil,
        emailProblem: { _ in "Enter your email address." },
        sendFallback: "That did not work; please try again.",
        verifyFallback: "That did not work; please try again."
    )

    /// The sign-in inside My bookings, with the block's own `intro`.
    public static func guestBookings(intro: String?) -> CmsSiteSignInWording {
        let intro = intro?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return CmsSiteSignInWording(
            heading: nil,
            emailIntro: intro.isEmpty ? "Sign in with the email you booked with, and we will email you a code." : intro,
            emailLabel: "Email",
            sendButton: "Email me a code",
            sendingButton: "Email me a code",
            codeHeading: nil,
            codeIntro: { "We have emailed a 6-digit code to \($0). It works for 10 minutes." },
            codeButton: "Sign in",
            checkingButton: "Sign in",
            resend: "Send a new code",
            otherEmail: "Use a different email",
            footnote: nil,
            emailProblem: { _ in "Enter your email address." },
            sendFallback: "The code could not be sent; please try again.",
            verifyFallback: "That did not work; please try again."
        )
    }
}
