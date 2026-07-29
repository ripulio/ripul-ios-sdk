import Foundation
import WebKit

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
    /// Explicit solution context id to request at validate. Must be in the site
    /// key's allowed set — the server 403s otherwise, deliberately: a silent
    /// fallback would hide a misconfigured screen behind plausible output.
    public var solutionContextId: String? = nil
    /// Named surface to request, resolved through the key's surfaceContextMap.
    /// Preferred over `solutionContextId`: the app names its screens and the
    /// key's admin decides which context each screen gets, so re-pointing a
    /// screen is a config change rather than an app release.
    public var surface: String? = nil
    /// Clerk-mode boot context (native-tool-registry phase 3): a registry
    /// context id the web session auto-enters once contexts load, emitted as
    /// `context=<id>`. The developer console passes its account's seeded
    /// Developer context here. Distinct from `solutionContextId`/`surface`,
    /// which are SITE-KEY validate requests — under a site-key lock the web
    /// side refuses client-side entry, so this param is inert there.
    public var clerkContextId: String? = nil
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
    /// When true, the web app's chat input box is hidden so the native
    /// app can provide its own input widget. Chat input is shown by default.
    public var hideChatInput: Bool = false
    /// Height in CSS pixels to reserve at the bottom of the chat scroll area
    /// for the native chat input. Only used when `hideChatInput` is true.
    public var nativeChatInputHeight: Int = 0
    /// Font family name prefixes to inject into the web view.
    /// The SDK scans `Bundle.main` for `.ttf`/`.otf` files whose filenames
    /// begin with each family name, base64-encodes them, and injects
    /// `@font-face` declarations at document load.
    /// Example: `["AvenirNext"]` injects all AvenirNext-*.ttf variants.
    public var fontFamilies: [String]? = nil
    /// When true, this web view acts as a relay host for remote machine
    /// connections. The web app's RemoteHostBridgeContext will only
    /// activate its relay bridge when this parameter is present,
    /// preventing duplicate bridges across multiple web views.
    public var relayHost: Bool = false

    /// When set, the web app boots in a minimal "file viewer only" mode that
    /// auto-opens this path in the Monaco viewer and hides the rest of the UI.
    /// Intended for standalone sheet-hosted viewers that share localStorage
    /// (and therefore the relay pairing) with the main chat web view.
    public var fileViewerPath: String? = nil

    /// Optional chat ID the file viewer should route relay reads through.
    /// When absent, the relay falls back to broadcasting to all paired
    /// machines — that works but is less targeted. The native app normally
    /// passes the active session's sourceChatId.
    public var fileViewerChatId: String? = nil

    /// Optional 1-based line number the file viewer should scroll to on open.
    /// Used when the user taps a grep hit — the viewer jumps directly to the
    /// matching line instead of opening at the top of the file.
    public var fileViewerLine: Int? = nil

    /// Custom WKWebsiteDataStore for profile-isolated multi-instance support.
    /// When set, the AgentWebView uses this store instead of `.default()`,
    /// giving each instance its own cookies, localStorage, and IndexedDB.
    public var websiteDataStore: WKWebsiteDataStore? = nil

    /// Optional hook to customize the WKWebViewConfiguration before the web view is created.
    /// Use this to register URL scheme handlers, add user scripts, etc.
    public var configureWebView: ((WKWebViewConfiguration) -> Void)? = nil

    public static let defaultBaseURL = URL(string: RipulDomain.demoURL)!

    /// API base URL derived from baseURL. Used for all backend API calls
    /// (relay machines, site key validation, etc.) via the same-origin proxy.
    public var apiURL: URL {
        baseURL.appendingPathComponent("api")
    }

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
        hideChatInput: Bool = false,
        nativeChatInputHeight: Int = 0,
        fontFamilies: [String]? = nil,
        relayHost: Bool = false,
        solutionContextId: String? = nil,
        surface: String? = nil
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
        self.hideChatInput = hideChatInput
        self.nativeChatInputHeight = nativeChatInputHeight
        self.fontFamilies = fontFamilies
        self.relayHost = relayHost
        self.solutionContextId = solutionContextId
        self.surface = surface
    }

    /// Strict per-value percent-encoding for hash params: RFC 3986 unreserved
    /// characters only — the set JavaScript's `encodeURIComponent` keeps bare
    /// (minus `!'()*`, which we also encode; decoding is unaffected).
    ///
    /// `.urlQueryAllowed` is NOT safe for these values: it leaves `&`, `=` and
    /// `+` literal, so a value containing `&` (e.g. "Company & Employees"
    /// inside the siteKeyConfig JSON) splits the hash param in two and
    /// truncates the JSON on the web side, and a literal `+` decodes to a
    /// space there (URLSearchParams semantics).
    private static let hashParamValueAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private static func hashParamValue(_ value: String) -> String? {
        value.addingPercentEncoding(withAllowedCharacters: hashParamValueAllowed)
    }

    public var embeddedURL: URL {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!

        var hashParams: [String] = [nativeApp ? "native=true" : "embedded=true"]

        if let siteKey {
            hashParams.append("siteKey=\(siteKey)")
            hashParams.append("skipOnboarding=true")
        }

        // Which solution context this surface wants. Only meaningful alongside
        // a siteKey — the web boot forwards them to validate, which resolves
        // the surface and mints a token scoped to the result.
        if let solutionContextId, let encoded = Self.hashParamValue(solutionContextId) {
            hashParams.append("solutionContext=\(encoded)")
        }

        if let surface, let encoded = Self.hashParamValue(surface) {
            hashParams.append("surface=\(encoded)")
        }

        if let clerkContextId, let encoded = Self.hashParamValue(clerkContextId) {
            hashParams.append("context=\(encoded)")
        }

        if let sessionToken {
            hashParams.append("sessionToken=\(sessionToken)")
        }

        if let siteKeyConfig,
           let encoded = Self.hashParamValue(siteKeyConfig) {
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

        if hideChatInput {
            hashParams.append("hideChatInput=true")
        }

        if nativeChatInputHeight > 0 {
            hashParams.append("nativeChatInputHeight=\(nativeChatInputHeight)")
        }

        if newChat {
            hashParams.append("newChat=true")
        }

        if let prompt, let encoded = Self.hashParamValue(prompt) {
            hashParams.append("prompt=\(encoded)")
            if !newChat {
                hashParams.append("newChat=true")
            }
        }

        if relayHost {
            hashParams.append("relayHost=true")
        }

        if let fileViewerPath,
           let encoded = Self.hashParamValue(fileViewerPath) {
            hashParams.append("fileViewerPath=\(encoded)")
        }

        if let fileViewerChatId,
           let encoded = Self.hashParamValue(fileViewerChatId) {
            hashParams.append("fileViewerChatId=\(encoded)")
        }

        if let fileViewerLine, fileViewerLine > 0 {
            hashParams.append("fileViewerLine=\(fileViewerLine)")
        }

        // Match EmbedManager format: #/?param1=val&param2=val
        // The web app's hash parsers expect a '?' separator.
        // Use percentEncodedFragment to avoid double-encoding values
        // that were already percent-encoded (e.g. prompt text).
        components.percentEncodedFragment = "/?" + hashParams.joined(separator: "&")
        return components.url!
    }
}
