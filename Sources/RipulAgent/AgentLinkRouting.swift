import Foundation

/// Whether a tapped link belongs in the agent web view or in the browser.
///
/// The agent web view holds one document: the app. A link to any other page
/// opens in the browser, so the app is never replaced by it. Comparing hosts
/// alone is not enough, because the app's own host also serves pages that are
/// not the app (`/ios`, `/mac`, `/a/<token>`). A chat link to one of those
/// used to load over the app: the page showed, and nothing led back to the chat.
enum AgentLinkRouting {
    /// `current` is the document the link would replace. Pass nil when it would
    /// not replace the app's document (a link inside a frame), which leaves the
    /// host comparison as the only test.
    static func leavesApp(_ url: URL, from current: URL?, baseHost: String?) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        guard let host = url.host, let baseHost else { return false }
        if host != baseHost { return true }
        // Mid sign-in the web view sits on another host; a link back is a return.
        guard let current, current.host == baseHost else { return false }
        return documentPath(url) != documentPath(current)
    }

    private static func documentPath(_ url: URL) -> String {
        let path = url.path
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : (path.isEmpty ? "/" : path)
    }
}
