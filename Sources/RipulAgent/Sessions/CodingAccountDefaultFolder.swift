import Foundation

/// The profile called "default" is a coding agent's own folder on a Mac
/// (`~/.claude` for Claude Code), not an account. It is listed only while
/// something is signed in there, under that account's email, and never as
/// "Default" or "This Mac's login". On a new Mac it read "Default · Not signed
/// in" beside the account just added, and the Mac's chats were using it
/// (4 November 2026). The web keeps the same rule (`claudeAccountDisplay.ts`).
enum CodingAccountDefaultFolder {
    static let slug = "default"

    /// The folder with nothing signed in: not an account, so no list shows it.
    /// An ended sign-in still shows, so that it can be signed in again.
    static func isEmpty(slug: String, loggedIn: Bool, email: String?, signInEnded: Bool = false) -> Bool {
        slug == Self.slug && !loggedIn && CodingAccountEmail.normalized(email) == nil && !signInEnded
    }

    /// A profile's title: the default folder goes by its account's email
    /// unless someone renamed it; `agent` when even that is unknown (an ended
    /// sign-in the CLI blanked).
    static func title(slug: String, name: String, email: String?, agent: String) -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let unnamed = name.isEmpty || (slug == Self.slug && name.lowercased() == "default")
        guard unnamed else { return name }
        let email = email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return email.isEmpty ? agent : email
    }

    /// The line under the title: the email when the title is something else,
    /// otherwise whether it is signed in. Nil for an account signed out whose
    /// row already says when its sign-in ended.
    static func detail(title: String, email: String?, loggedIn: Bool, saysSignInEnd: Bool = false) -> String? {
        let email = email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !email.isEmpty, email != title { return email }
        if loggedIn { return "Signed in" }
        return saysSignInEnd ? nil : "Not signed in"
    }

    /// What to say when a Mac's chats cannot use the account they are set to:
    /// none is signed in there, or the one in use is not signed in while
    /// another is. `listed` is the Mac's accounts less an empty default
    /// folder. Nil when the account in use can reply.
    static func macNotice(listed: [(slug: String, loggedIn: Bool)], active: String, agent: String) -> String? {
        if !listed.contains(where: \.loggedIn) {
            return "No \(agent) account is signed in on this Mac yet. Add one to use \(agent) here."
        }
        if listed.contains(where: { $0.slug == active && $0.loggedIn }) { return nil }
        return "Chats on this Mac use an account that isn’t signed in. Choose one below."
    }
}
