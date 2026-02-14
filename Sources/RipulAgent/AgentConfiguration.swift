import Foundation

public enum AgentTheme: String {
    case light, dark, system
}

public struct AgentConfiguration {
    public var baseURL: URL
    public var path: String = "/app"
    public var siteKey: String? = nil
    public var sessionToken: String? = nil
    public var theme: AgentTheme = .system
    public var newChat: Bool = false
    public var prompt: String? = nil

    public static let defaultBaseURL = URL(string: "https://demo.ripul.io")!

    public init(
        baseURL: URL,
        path: String = "/app",
        siteKey: String? = nil,
        sessionToken: String? = nil,
        theme: AgentTheme = .system,
        newChat: Bool = false,
        prompt: String? = nil
    ) {
        self.baseURL = baseURL
        self.path = path
        self.siteKey = siteKey
        self.sessionToken = sessionToken
        self.theme = theme
        self.newChat = newChat
        self.prompt = prompt
    }

    public var embeddedURL: URL {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!

        var hashParams: [String] = ["embedded=true"]

        if let siteKey {
            hashParams.append("siteKey=\(siteKey)")
            hashParams.append("skipOnboarding=true")
        }

        if let sessionToken {
            hashParams.append("sessionToken=\(sessionToken)")
        }

        if newChat {
            hashParams.append("newChat=true")
        }

        if let prompt, let encoded = prompt.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            hashParams.append("prompt=\(encoded)")
            if !newChat {
                hashParams.append("newChat=true")
            }
        }

        // Match EmbedManager format: #/?param1=val&param2=val
        // The web app's hash parsers expect a '?' separator.
        // Use percentEncodedFragment to avoid double-encoding values
        // that were already percent-encoded (e.g. prompt text).
        components.percentEncodedFragment = "/?" + hashParams.joined(separator: "&")
        return components.url!
    }
}
