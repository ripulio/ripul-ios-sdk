import Foundation

enum AgentTheme: String {
    case light, dark, system
}

struct AgentConfiguration {
    var baseURL: URL
    var path: String = "/app"
    var siteKey: String? = nil
    var sessionToken: String? = nil
    var theme: AgentTheme = .system
    var newChat: Bool = false
    var prompt: String? = nil

    static let defaultBaseURL = URL(string: "https://demo.ripul.io")!

    var embeddedURL: URL {
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
        // The web app's hash parsers expect a '?' separator
        components.fragment = "/?" + hashParams.joined(separator: "&")
        return components.url!
    }
}
