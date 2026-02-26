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
    /// JSON string of site key config returned from validation.
    /// Set automatically by SiteKeyValidator; not typically set by consumers.
    public var siteKeyConfig: String? = nil
    /// When true, the URL uses `native=true` instead of `embedded=true`.
    /// Native mode enables the bridge but lets the web app use its own
    /// Clerk authentication, giving a full web experience with native tools.
    public var nativeApp: Bool = false
    /// When true, the web app's header is hidden so the native app can
    /// provide its own. Header is shown by default.
    public var hideHeader: Bool = false
    /// When true, the web app's chat tab switcher is hidden so the native
    /// app can provide its own session list. Tab switcher is shown by default.
    public var hideTabSwitcher: Bool = false
    /// Font family name prefixes to inject into the web view.
    /// The SDK scans `Bundle.main` for `.ttf`/`.otf` files whose filenames
    /// begin with each family name, base64-encodes them, and injects
    /// `@font-face` declarations at document load.
    /// Example: `["AvenirNext"]` injects all AvenirNext-*.ttf variants.
    public var fontFamilies: [String]? = nil

    public static let defaultBaseURL = URL(string: "https://demo.ripul.io")!

    public init(
        baseURL: URL,
        path: String = "/app",
        siteKey: String? = nil,
        sessionToken: String? = nil,
        theme: AgentTheme = .system,
        newChat: Bool = false,
        prompt: String? = nil,
        nativeApp: Bool = false,
        hideHeader: Bool = false,
        hideTabSwitcher: Bool = false,
        fontFamilies: [String]? = nil
    ) {
        self.baseURL = baseURL
        self.path = path
        self.siteKey = siteKey
        self.sessionToken = sessionToken
        self.theme = theme
        self.newChat = newChat
        self.prompt = prompt
        self.nativeApp = nativeApp
        self.hideHeader = hideHeader
        self.hideTabSwitcher = hideTabSwitcher
        self.fontFamilies = fontFamilies
    }

    public var embeddedURL: URL {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!

        var hashParams: [String] = [nativeApp ? "native=true" : "embedded=true"]

        if let siteKey {
            hashParams.append("siteKey=\(siteKey)")
            hashParams.append("skipOnboarding=true")
        }

        if let sessionToken {
            hashParams.append("sessionToken=\(sessionToken)")
        }

        if let siteKeyConfig,
           let encoded = siteKeyConfig.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            hashParams.append("siteKeyConfig=\(encoded)")
        }

        // Pass theme so the page can set the correct background before React loads.
        // The bridge also sends theme changes at runtime, but this ensures the
        // very first paint matches (avoiding a dark flash for light themes).
        hashParams.append("theme=\(theme.rawValue)")

        if hideHeader {
            hashParams.append("hideHeader=true")
        }

        if hideTabSwitcher {
            hashParams.append("hideTabSwitcher=true")
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
