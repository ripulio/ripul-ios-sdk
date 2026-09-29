import Foundation

/// Merges the host's local repos with its GitHub list for the Repos screen:
/// which GitHub repos are still to clone, and what a search matches in each.
///
/// Repos are matched by origin, not folder name. Local folders are often
/// named differently from their GitHub repo (`WAC_ios_final-v262-payday` is
/// `georgina-wac/WAC_ios_final`), and one GitHub repo can have several local
/// clones; any clone at all means it isn't offered for cloning again.
public enum RepoGitHubCatalog {

    /// Lowercased `owner/name` for a github.com remote, nil for any other host
    /// or anything unparseable. Accepts https (with or without a user), ssh://
    /// and scp-style `git@github.com:owner/name.git`, with or without `.git`
    /// or a trailing slash.
    public static func githubFullName(fromRemoteURL raw: String) -> String? {
        let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var path: Substring

        if let schemeEnd = url.range(of: "://") {
            var rest = url[schemeEnd.upperBound...]
            if let slash = rest.firstIndex(of: "/") {
                var host = rest[..<slash]
                if let at = host.lastIndex(of: "@") { host = host[host.index(after: at)...] }
                if let colon = host.firstIndex(of: ":") { host = host[..<colon] }
                guard host.lowercased() == "github.com" || host.lowercased() == "www.github.com" else { return nil }
                rest = rest[rest.index(after: slash)...]
            } else {
                return nil
            }
            path = rest
        } else if let at = url.firstIndex(of: "@"), let colon = url.firstIndex(of: ":"), at < colon {
            let host = url[url.index(after: at)..<colon]
            guard host.lowercased() == "github.com" else { return nil }
            path = url[url.index(after: colon)...]
        } else {
            return nil
        }

        while path.hasSuffix("/") { path = path.dropLast() }
        if path.hasSuffix(".git") { path = path.dropLast(4) }
        let parts = path.split(separator: "/")
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return "\(parts[0])/\(parts[1])".lowercased()
    }

    /// GitHub repos with no local clone on this host, in the order given (the
    /// host sends most recently pushed first). Archived repos only appear
    /// when a search names them.
    public static func uncloned(_ github: [GitHubRepo], local: [RepoSummary], query: String = "") -> [GitHubRepo] {
        let cloned = Set(local.compactMap(\.githubFullName))
        let tokens = searchTokens(query)
        return github.filter { repo in
            guard !cloned.contains(repo.fullName.lowercased()) else { return false }
            if tokens.isEmpty { return !repo.isArchived }
            return matches(tokens, in: [repo.fullName, repo.description ?? ""])
        }
    }

    /// Local repos matching a search on folder name, path, branch or GitHub name.
    public static func filterLocal(_ local: [RepoSummary], query: String) -> [RepoSummary] {
        let tokens = searchTokens(query)
        guard !tokens.isEmpty else { return local }
        return local.filter { repo in
            matches(tokens, in: [repo.name, repo.path, repo.currentBranch ?? "", repo.githubFullName ?? ""])
        }
    }

    /// Whether a search looks like something to clone directly — `owner/repo`
    /// or a git URL — rather than a filter over the list.
    public static func isCloneSource(_ query: String) -> Bool {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.hasPrefix("-"), text.rangeOfCharacter(from: .whitespaces) == nil else { return false }
        if text.hasPrefix("https://") || text.hasPrefix("ssh://") { return true }
        if text.range(of: #"^[A-Za-z0-9._-]+@[A-Za-z0-9.-]+:[A-Za-z0-9._/-]+$"#, options: .regularExpression) != nil { return true }
        return text.range(of: #"^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
    }

    /// The folder a clone of `source` gets by default: the repo name without
    /// `.git`. Mirrors the host's rule so the sheet shows the real name.
    public static func defaultFolderName(forSource source: String) -> String {
        var text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        let last = text.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? ""
        return last.hasSuffix(".git") ? String(last.dropLast(4)) : last
    }

    private static func searchTokens(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func matches(_ tokens: [String], in fields: [String]) -> Bool {
        let haystack = fields.joined(separator: " ").lowercased()
        return tokens.allSatisfy { haystack.contains($0) }
    }
}
