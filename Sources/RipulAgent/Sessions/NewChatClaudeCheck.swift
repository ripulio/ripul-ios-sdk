import Foundation

/// Whether a Claude chat started on a Mac could reply, from the Mac's account
/// list (`AgentBridge.fetchClaudeAccounts`): the account its new chats use,
/// signed in and not ended, and not at a limit. The New Chat sheet says so
/// before the chat starts. On 9 November 2026 Peter's first chat on the Mac
/// mini, onboarded afresh, answered "Not logged in · Please run /login": its
/// account had never been signed in there, and nothing said so beforehand.
public struct NewChatClaudeCheck: Equatable, Sendable {
    public enum Verdict: Equatable, Sendable {
        case canReply
        /// The account new chats use was never signed in on that Mac.
        case notSignedIn
        /// Its sign-in has ended: it needs signing in again.
        case ended
        /// It has used its limit until then: chats there wait.
        case limited(until: Date)
    }

    public let verdict: Verdict
    /// The account as a person knows it: its email, else its name.
    public let accountName: String
    /// The profile on that Mac a sign-in is for.
    public let accountSlug: String

    public init(verdict: Verdict, accountName: String, accountSlug: String) {
        self.verdict = verdict
        self.accountName = accountName
        self.accountSlug = accountSlug
    }

    /// Nil when the list could not be read, or comes from a host that lists no
    /// accounts: nothing is said then, and the chat starts as before.
    public static func from(_ info: ClaudeAccountsListInfo, now: Date = Date()) -> NewChatClaudeCheck? {
        guard info.error == nil, !info.accounts.isEmpty else { return nil }
        guard let account = info.accounts.first(where: { $0.slug == info.active }) else {
            return NewChatClaudeCheck(verdict: .notSignedIn, accountName: info.active, accountSlug: info.active)
        }
        let name = account.email ?? (account.name.isEmpty ? account.slug : account.name)
        if account.signInEnded { return NewChatClaudeCheck(verdict: .ended, accountName: name, accountSlug: account.slug) }
        if !account.loggedIn { return NewChatClaudeCheck(verdict: .notSignedIn, accountName: name, accountSlug: account.slug) }
        // A model's own allowance ("model:…") leaves the others: only the account's own limits stop every chat.
        let resets = (account.usage?.windows ?? [])
            .filter { !$0.id.hasPrefix("model:") && $0.usedPercent >= 100 }
            .compactMap { $0.resetsAt.map { Date(timeIntervalSince1970: $0) } }
            .filter { $0 > now }
        if let until = resets.max() { return NewChatClaudeCheck(verdict: .limited(until: until), accountName: name, accountSlug: account.slug) }
        return NewChatClaudeCheck(verdict: .canReply, accountName: name, accountSlug: account.slug)
    }

    /// A Claude chat started there would not reply at all until someone signs in.
    public var blocksStart: Bool { verdict == .notSignedIn || verdict == .ended }

    /// What the sheet says about the Mac called `mac`; nil when Claude can reply there.
    public func message(mac: String, calendar: Calendar = .current) -> String? {
        switch verdict {
        case .canReply:
            return nil
        case .notSignedIn:
            return "Claude isn’t signed in on \(mac), so a Claude chat there can’t reply. Sign it in first, or choose another Mac."
        case .ended:
            return "The Claude sign-in for \(accountName) on \(mac) has ended, so a Claude chat there can’t reply. Sign in again first, or choose another Mac."
        case .limited(let until):
            var format = Date.FormatStyle(date: .omitted, time: .shortened).weekday(.abbreviated)
            format.calendar = calendar
            format.timeZone = calendar.timeZone
            return "Claude’s account \(accountName) on \(mac) has used its limit until \(until.formatted(format)). A Claude chat there waits until then."
        }
    }

    /// The link that opens the sign-in for this account on the Mac with id `machineID`
    /// (the app's `ripul://claude-account`, as the sign-in alert's push opens it).
    public func signInLink(machineID: String) -> URL? {
        var link = URLComponents()
        link.scheme = "ripul"
        link.host = "claude-account"
        link.queryItems = [URLQueryItem(name: "machine", value: machineID),
                           URLQueryItem(name: "profile", value: accountSlug),
                           URLQueryItem(name: "action", value: "sign-in")]
        return link.url
    }
}
