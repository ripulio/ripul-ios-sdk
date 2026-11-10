import Foundation

/// WAC's Rails, as WAC's own app calls it: the sign-in routes (`email_login/*`, as
/// `SignInTransport` in WAC's `ProviderLogin.swift`) and the ordinary signed-in API.
/// HTTPS only, no cookies, never follows a redirect.
enum WACAPI {
    struct Failure: Error { let code: String }

    struct User: Equatable {
        let id: String
        let name: String
        let email: String
        let phone: String
    }

    // MARK: Sign-in routes

    static func signIn(_ action: String, _ body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: Config.signInBase.appendingPathComponent("email_login/" + action))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (status, result) = try await send(request)
        if status == 404 { return ["success": false, "error": "trial_unavailable"] }
        // A page that isn't WAC's JSON (a proxy's or Cloudflare's) is reported with its status,
        // so a refusal is never mistaken for a lost connection.
        return result ?? ["success": false, "error": "http_\(status)"]
    }

    // MARK: Signed-in API

    /// The headers every WAC API call carries: WAC's `RipulConfig.portalCredentials()`, which
    /// mirrors `NetworkHelper.getHeader()`. The Ripul worker forwards these same headers to
    /// `GET /api/v1/user`, and WAC's edge rejects a bare credential-only request.
    static func headers(for session: WACSession) -> [String: String] {
        var headers = [
            "secret": session.secret,
            "secret-id": session.secretID,
            "HTTP-LOCALE": "en",
            "HTTP-TIMEZONE": TimeZone.current.identifier,
        ]
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            headers["current-version"] = version
            headers["platform"] = "ios"
        }
        return headers
    }

    /// `GET /api/v1/user`: proves the token works.
    static func user(_ session: WACSession) async throws -> User {
        let (status, result) = try await send(authorized(Config.apiBase.appendingPathComponent("user"), "GET", session))
        guard let result else { throw Failure(code: "http_\(status)") }
        guard result["success"] as? Bool == true, let user = result["user"] as? [String: Any] else {
            // Rails answers an unknown or replaced token with success false ("Login Credentials Failed.").
            throw Failure(code: status == 200 || status == 401 ? "session_ended" : "http_\(status)")
        }
        let first = [user["first_name"], user["last_name"]].compactMap { $0 as? String }.filter { !$0.isEmpty }
        let name = [user["name"] as? String, user["preferred_name"] as? String, first.joined(separator: " ")]
            .compactMap { $0 }.first { !$0.isEmpty } ?? ""
        return User(id: user["id"].map { "\($0)" } ?? "", name: name,
                    email: user["email"] as? String ?? "", phone: user["phone"] as? String ?? "")
    }

    /// `DELETE /api/v1/user/logout`, WAC's own sign-out: ends the token on the server too.
    static func logout(_ session: WACSession) async {
        _ = try? await send(authorized(Config.apiBase.appendingPathComponent("user/logout"), "DELETE", session))
    }

    // MARK: Transport

    private static func authorized(_ url: URL, _ method: String, _ session: WACSession) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers(for: session) { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    private static func send(_ request: URLRequest) async throws -> (Int, [String: Any]?) {
        guard request.url?.scheme == "https" else { throw Failure(code: "https_required") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status, (try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
    }

    /// Credentials never travel on to a redirect's destination.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    /// What to tell the person for a refusal code.
    static func message(for code: String) -> String {
        switch code {
        case "rate_limited": return "The test server has had too many sign-ins from this network this hour. Try again later."
        case "trial_unavailable", "provider_unavailable": return "The test login isn't available on this server."
        case "invalid_synthetic": return "Use a test email ending @example.invalid."
        case "invalid_phone": return "Use a reserved test number: +44 7700 900xxx."
        case "phone_unavailable": return "That test number is already on another account."
        case "email_unavailable": return "That test email is already on another account."
        case "provider_conflict": return "That account already has a different test login."
        case "invalid_provider_token": return "The sign-in expired. Start again."
        case "session_ended": return "This session has ended, perhaps because the account signed in somewhere else. Sign out and sign in again."
        case "https_required": return "Sign-in needs HTTPS."
        case "network": return "We couldn't reach WAC."
        case let code where code.hasPrefix("http_"): return "WAC refused the request (\(code.dropFirst(5)))."
        default: return "Something went wrong (\(code))."
        }
    }
}
