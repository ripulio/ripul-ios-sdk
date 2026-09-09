import Foundation

/// Validates a site key against the LLM proxy and returns a session token.
/// Mirrors the browser-side validation done by EmbedManager.validateSiteKey().
@available(iOS 15.0, macOS 13.0, *)
public enum SiteKeyValidator {
    public struct ValidationResult {
        public let sessionToken: String?
        public let configJSON: String?
    }

    // MARK: - Launch cache

    /// A previous launch's successful validation, replayed so the web view can
    /// start immediately instead of waiting a network round-trip.
    ///
    /// Why: on an iPhone cold start `AgentView.task` awaited `validate()` BEFORE
    /// creating the WKWebView — measured at 3.7s of the ~6s to web boot, fully
    /// serial, for a site key whose answer is the same every launch. The web
    /// app's own boot (`useSiteKeyConfig`) treats a hash-supplied token+config
    /// as pre-validated and skips its validate call; with no token it validates
    /// itself in parallel with chunk loading. So on a warm launch we hand it the
    /// cached pair when the token is still fresh, or nothing at all when it is
    /// not — and in both cases the web view starts ~3.7s sooner. The network
    /// validate then runs in the background to refresh this cache for next time.
    public struct CachedValidation {
        public let result: ValidationResult
        /// Seconds since the cached result was minted by the server.
        public let ageSeconds: TimeInterval
        /// True while the cached session token is comfortably inside the
        /// server's 1-hour lifetime (`TOKEN_EXPIRY_SECONDS` in siteKeyJwt.ts).
        /// A stale token must NOT be handed to the web: it would be marked valid
        /// and never re-minted until a 401.
        public var tokenFresh: Bool { result.sessionToken != nil && ageSeconds < SiteKeyValidator.tokenFreshnessSeconds }
    }

    /// Margin under the server's 3600s token lifetime.
    public static let tokenFreshnessSeconds: TimeInterval = 50 * 60

    private static func cacheKey(siteKey: String, contextId: String?, surface: String?, baseURL: URL) -> String {
        let host = baseURL.host ?? baseURL.absoluteString
        return "ripul.siteKeyValidation.\(siteKey)|\(host)|\(contextId ?? "")|\(surface ?? "")"
    }

    /// The last successful validation for this key/host/context, if any.
    public static func cachedResult(
        siteKey: String,
        contextId: String? = nil,
        surface: String? = nil,
        baseURL: URL
    ) -> CachedValidation? {
        let key = cacheKey(siteKey: siteKey, contextId: contextId, surface: surface, baseURL: baseURL)
        guard let data = UserDefaults.standard.data(forKey: key),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let validatedAt = json["validatedAt"] as? Double else { return nil }
        let result = ValidationResult(
            sessionToken: json["sessionToken"] as? String,
            configJSON: json["configJSON"] as? String
        )
        // A cache entry with neither field is worthless — treat as a miss so the
        // caller takes the blocking first-launch path.
        guard result.sessionToken != nil || result.configJSON != nil else { return nil }
        return CachedValidation(result: result, ageSeconds: Date().timeIntervalSince1970 - validatedAt)
    }

    private static func storeResult(
        _ result: ValidationResult,
        siteKey: String, contextId: String?, surface: String?, baseURL: URL
    ) {
        guard result.sessionToken != nil || result.configJSON != nil else { return }
        var json: [String: Any] = ["validatedAt": Date().timeIntervalSince1970]
        if let t = result.sessionToken { json["sessionToken"] = t }
        if let c = result.configJSON { json["configJSON"] = c }
        if let data = try? JSONSerialization.data(withJSONObject: json) {
            UserDefaults.standard.set(data, forKey: cacheKey(siteKey: siteKey, contextId: contextId, surface: surface, baseURL: baseURL))
        }
    }

    /// Validate a site key, optionally requesting a specific solution context.
    ///
    /// - Parameters:
    ///   - contextId: explicit context id; must be in the key's allowed set.
    ///   - surface: named surface, resolved through the key's surfaceContextMap.
    ///
    /// A refused context/surface comes back as a 403 and fails validation with
    /// the server's message logged. That is deliberate: falling back to the
    /// default context would let a misconfigured screen load the wrong toolset
    /// and prompt while looking like it worked.
    public static func validate(
        siteKey: String,
        contextId: String? = nil,
        surface: String? = nil,
        baseURL: URL
    ) async -> ValidationResult {
        let url = baseURL.appendingPathComponent("api/v1/site-key/validate")

        // Build the origin from baseURL (e.g. "https://demo.ripul.io")
        var components = URLComponents()
        components.scheme = baseURL.scheme
        components.host = baseURL.host
        if let port = baseURL.port { components.port = port }
        let origin = components.url?.absoluteString ?? baseURL.absoluteString

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(origin, forHTTPHeaderField: "Origin")
        // Field names mirror the worker contract (handleSiteKeyValidate);
        // scripts/selftest-api.mjs asserts the parity.
        var body: [String: Any] = ["siteKey": siteKey]
        if let contextId { body["contextId"] = contextId }
        if let surface { body["surface"] = surface }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        NSLog("[SiteKeyValidator] Validating site key from origin: %@", origin)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                NSLog("[SiteKeyValidator] Non-HTTP response")
                return ValidationResult(sessionToken: nil, configJSON: nil)
            }

            guard httpResponse.statusCode == 200 else {
                // Surface the server's message — a 403 here is almost always
                // `context_not_allowed`, and the status alone doesn't say which
                // surface or context was refused.
                let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                    .flatMap { ($0?["error"] as? [String: Any])?["message"] as? String }
                    ?? "no message"
                NSLog("[SiteKeyValidator] Validation failed with status: %d (%@)",
                      httpResponse.statusCode, detail)
                return ValidationResult(sessionToken: nil, configJSON: nil)
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                NSLog("[SiteKeyValidator] Failed to parse response")
                return ValidationResult(sessionToken: nil, configJSON: nil)
            }

            guard json["valid"] as? Bool == true else {
                let error = (json["error"] as? [String: Any])?["message"] as? String ?? "Unknown"
                NSLog("[SiteKeyValidator] Site key invalid: %@", error)
                return ValidationResult(sessionToken: nil, configJSON: nil)
            }

            let sessionToken = json["sessionToken"] as? String

            // Serialize the config to pass via URL hash params
            var configJSON: String?
            if let config = json["config"] {
                if let configData = try? JSONSerialization.data(withJSONObject: config),
                   let configStr = String(data: configData, encoding: .utf8) {
                    configJSON = configStr
                }
            }

            NSLog("[SiteKeyValidator] Validation succeeded (hasToken: %@, hasConfig: %@)",
                  sessionToken != nil ? "true" : "false",
                  configJSON != nil ? "true" : "false")

            let result = ValidationResult(sessionToken: sessionToken, configJSON: configJSON)
            // Remember it for the next launch's fast path (see CachedValidation).
            storeResult(result, siteKey: siteKey, contextId: contextId, surface: surface, baseURL: baseURL)
            return result
        } catch {
            NSLog("[SiteKeyValidator] Network error: %@", error.localizedDescription)
            return ValidationResult(sessionToken: nil, configJSON: nil)
        }
    }
}
