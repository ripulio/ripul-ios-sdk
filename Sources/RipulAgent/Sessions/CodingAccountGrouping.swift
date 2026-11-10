import Foundation

public enum CodingAccountProvider: String, CaseIterable, Identifiable, Sendable {
    case claude, codex, antigravity

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        }
    }

    /// The provider's web page for checking or changing the account's plan and billing.
    public var billingAndAccountTitle: String {
        switch self {
        case .claude: return "Claude billing & account"
        case .codex: return "ChatGPT billing & account"
        case .antigravity: return "Google AI plan & billing"
        }
    }

    /// Opens the provider's billing and account page. When `email` is given for
    /// Antigravity, Google's account chooser lands on that Google account first.
    public func billingAndAccountURL(email: String? = nil) -> URL {
        switch self {
        case .claude:
            return URL(string: "https://claude.ai/settings/billing")!
        case .codex:
            return URL(string: "https://chatgpt.com/#settings/Subscription")!
        case .antigravity:
            let plan = "https://one.google.com/ai?utm_source=antigravity"
            if let email = CodingAccountEmail.normalized(email),
               var chooser = URLComponents(string: "https://accounts.google.com/AccountChooser") {
                chooser.queryItems = [
                    URLQueryItem(name: "Email", value: email),
                    URLQueryItem(name: "continue", value: plan),
                ]
                if let url = chooser.url { return url }
            }
            return URL(string: plan)!
        }
    }
}

/// Emails compared the way accounts are joined: trimmed and in lower case,
/// plus-address tags kept.
enum CodingAccountEmail {
    static func normalized(_ email: String?) -> String? {
        let value = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value?.isEmpty == false ? value : nil
    }

    /// True when a sign-in meant for `expected` came back as another account.
    /// Claude's page signs in whichever account the browser already holds, so
    /// this is how a sign-in for one account is caught landing on another.
    static func isDifferentAccount(expected: String?, signedIn: String?) -> Bool {
        guard let expected = normalized(expected), let signedIn = normalized(signedIn) else { return false }
        return expected != signedIn
    }
}

/// The account explicitly chosen when adding a computer. This is setup intent,
/// not a verified login; a returned email always takes precedence.
struct CodingAccountPendingLink: Codable, Equatable {
    let accountId: String
    let name: String
    let email: String
}

/// A credential-free account on one machine. Local profile names and slugs
/// are never identities: two machines can call different logins "Default".
struct CodingAccountEntry: Identifiable {
    let provider: CodingAccountProvider
    let machineId: String
    let localId: String
    var name: String
    let email: String?
    let plan: String?
    let usage: CodingAccountUsage?
    let isActive: Bool
    let needsLogin: Bool
    /// When this machine's Claude sign-in for the account stops working.
    var signInEndsAt: Date? = nil
    var signInEnded = false
    var pendingLink: CodingAccountPendingLink? = nil

    var id: String { "\(machineId)/\(localId)" }
    var identity: String {
        // Codex IDs include the upstream workspace ID and user ID. The same
        // email can have separate personal and business accounts.
        if provider == .codex { return "codex/id/\(localId)" }
        if let email = normalizedEmail { return "\(provider.rawValue)/email/\(email)" }
        if let pendingLink { return pendingLink.accountId }
        return "\(provider.rawValue)/profile/\(id)"
    }
    var isUnidentified: Bool { provider != .codex && normalizedEmail == nil && pendingLink == nil }
    var normalizedEmail: String? { CodingAccountEmail.normalized(email) }
}

struct CodingAccountGroup: Identifiable {
    let id: String
    let entries: [CodingAccountEntry]
    /// Another account's card would show the same profile name. Set by `make`.
    var nameIsShared = false

    /// The name the Macs gave this account's profiles, if any: the one most
    /// of them carry, so a Mac that was offline when the account was renamed
    /// does not outvote the rest (ties: the first, in machine order). Each Mac
    /// names its own profiles, so two accounts can end up with one name: a
    /// profile created for one account and signed in to another keeps its name.
    var profileName: String? {
        let names = entries.map(\.name).filter { name in
            !name.isEmpty && name.lowercased() != "default" && !entries.contains { $0.normalizedEmail == name.lowercased() }
        }
        let counts = Dictionary(grouping: names, by: { $0 }).mapValues(\.count)
        return names.max { counts[$0, default: 0] < counts[$1, default: 0] }
    }
    var name: String {
        if nameIsShared, let email { return email }
        return profileName ?? email ?? entries.first?.name ?? "Account"
    }
    var email: String? { entries.compactMap(\.normalizedEmail).first ?? entries.compactMap { $0.pendingLink?.email }.first }
    var isUnidentified: Bool { entries.allSatisfy(\.isUnidentified) }
    var machineIds: [String] { Array(Set(entries.map(\.machineId))).sorted() }
    var usage: CodingAccountUsage? {
        // Usage is shared by the account. Show one reading, never sum limits
        // across hosts or let one host's failed refresh hide a good reading.
        entries.compactMap(\.usage).sorted {
            if ($0.error == nil) != ($1.error == nil) { return $0.error == nil }
            return ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0)
        }.first
    }
    var plan: String? {
        let candidates = entries.compactMap { $0.usage?.plan } + entries.compactMap(\.plan)
        return candidates.first { $0.lowercased().contains("max_") } ?? usage?.plan ?? candidates.first
    }
    /// The sign-in that ends first, across the machines holding the account.
    var soonestSignInEnd: CodingAccountEntry? {
        entries.filter { $0.signInEnded || $0.signInEndsAt != nil }.min {
            ($0.signInEnded ? .distantPast : $0.signInEndsAt ?? .distantFuture)
                < ($1.signInEnded ? .distantPast : $1.signInEndsAt ?? .distantFuture)
        }
    }

    func accounts(on machineId: String) -> [CodingAccountEntry] {
        entries.filter { $0.machineId == machineId }.sorted {
            if $0.isActive != $1.isActive { return $0.isActive }
            if $0.needsLogin != $1.needsLogin { return !$0.needsLogin }
            return $0.localId < $1.localId
        }
    }

    static func make(_ entries: [CodingAccountEntry]) -> [Self] {
        var groups = Dictionary(grouping: entries, by: \.identity).map { id, entries in
            Self(id: id, entries: entries.sorted { $0.id < $1.id })
        }
        // Two cards never share a title: when they would, each shows its
        // email. Unfinished sign-ins have no card, so they never take a name.
        let names = groups.filter { !$0.isUnidentified }.compactMap { $0.profileName?.lowercased() }
        let shared = Set(Dictionary(grouping: names, by: { $0 }).filter { $0.value.count > 1 }.keys)
        for index in groups.indices where !groups[index].isUnidentified {
            groups[index].nameIsShared = groups[index].profileName.map { shared.contains($0.lowercased()) } ?? false
        }
        return groups.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}
