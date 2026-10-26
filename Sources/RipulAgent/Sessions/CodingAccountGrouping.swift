import Foundation

enum CodingAccountProvider: String {
    case claude, codex, antigravity

    var title: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        }
    }
}

/// A credential-free account on one machine. Local profile names and slugs
/// are never identities: two machines can call different logins "Default".
struct CodingAccountEntry: Identifiable {
    let provider: CodingAccountProvider
    let machineId: String
    let localId: String
    let name: String
    let email: String?
    let plan: String?
    let usage: CodingAccountUsage?
    let isActive: Bool
    let needsLogin: Bool
    /// When this machine's Claude sign-in for the account stops working.
    var signInEndsAt: Date? = nil
    var signInEnded = false

    var id: String { "\(machineId)/\(localId)" }
    var identity: String {
        // Codex IDs include the upstream workspace ID and user ID. The same
        // email can have separate personal and business accounts.
        if provider == .codex { return "codex/id/\(localId)" }
        if let email = normalizedEmail { return "\(provider.rawValue)/email/\(email)" }
        return "\(provider.rawValue)/profile/\(id)"
    }
    var normalizedEmail: String? {
        let value = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value?.isEmpty == false ? value : nil
    }
}

struct CodingAccountGroup: Identifiable {
    let id: String
    let entries: [CodingAccountEntry]

    var name: String {
        entries.first(where: {
            !$0.name.isEmpty && $0.name.lowercased() != "default" && $0.name.lowercased() != $0.normalizedEmail
        })?.name ?? email ?? entries.first?.name ?? "Account"
    }
    var email: String? { entries.compactMap(\.normalizedEmail).first }
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
        Dictionary(grouping: entries, by: \.identity).map { id, entries in
            Self(id: id, entries: entries.sorted { $0.id < $1.id })
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}
