import Foundation

/// Validates a site key against the LLM proxy and returns a session token.
/// Mirrors the browser-side validation done by EmbedManager.validateSiteKey().
enum SiteKeyValidator {
    struct ValidationResult {
        let sessionToken: String?
        let configJSON: String?
    }

    private static let validationEndpoint = "https://llm-proxy.ripul.io/v1/site-key/validate"

    static func validate(siteKey: String, baseURL: URL) async -> ValidationResult {
        guard let url = URL(string: validationEndpoint) else {
            NSLog("[SiteKeyValidator] Invalid validation endpoint")
            return ValidationResult(sessionToken: nil, configJSON: nil)
        }

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
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["siteKey": siteKey])

        NSLog("[SiteKeyValidator] Validating site key from origin: %@", origin)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                NSLog("[SiteKeyValidator] Non-HTTP response")
                return ValidationResult(sessionToken: nil, configJSON: nil)
            }

            guard httpResponse.statusCode == 200 else {
                NSLog("[SiteKeyValidator] Validation failed with status: %d", httpResponse.statusCode)
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

            return ValidationResult(sessionToken: sessionToken, configJSON: configJSON)
        } catch {
            NSLog("[SiteKeyValidator] Network error: %@", error.localizedDescription)
            return ValidationResult(sessionToken: nil, configJSON: nil)
        }
    }
}
