import Foundation

/// Decoded shapes for the repo navigator (the iPhone's GitKraken-style
/// branch/commit graph).
///
/// These mirror the wire structs in `GitRepoNavigator.swift` (macOS host) and
/// `repoGraphBridge.ts` / `relayProtocol.ts` (web). The host owns all git
/// semantics — lane assignment happens on-device (see the native app's
/// RepoGraphLayout), but what a ref *is* (branch vs remote vs tag) is decided
/// host-side against the real remotes list and never re-derived here.
///
/// Field renames must land in all three places.

/// A failure with a message meant for the screen, not a log.
public struct RepoNavigatorError: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

// MARK: - Repo list

public struct RepoSummary: Codable, Sendable, Identifiable, Hashable {
    public let path: String
    public let name: String
    /// nil when HEAD is detached.
    public let currentBranch: String?
    public let headSha: String?
    /// staged + modified + untracked.
    public let dirtyCount: Int
    /// `remote.origin.url`; nil when the repo has no origin (or the host
    /// predates the field).
    public let originUrl: String?

    public init(path: String, name: String, currentBranch: String? = nil, headSha: String? = nil,
                dirtyCount: Int = 0, originUrl: String? = nil) {
        self.path = path
        self.name = name
        self.currentBranch = currentBranch
        self.headSha = headSha
        self.dirtyCount = dirtyCount
        self.originUrl = originUrl
    }

    public var id: String { path }
    public var isDirty: Bool { dirtyCount > 0 }

    /// Lowercased `owner/name` when origin is on github.com, else nil.
    public var githubFullName: String? {
        originUrl.flatMap(RepoGitHubCatalog.githubFullName(fromRemoteURL:))
    }
}

// MARK: - GitHub + clone

/// A repo the host's `gh` login can see.
public struct GitHubRepo: Codable, Sendable, Identifiable, Hashable {
    /// owner/name, as GitHub capitalises it.
    public let fullName: String
    public let name: String
    public let owner: String
    public let description: String?
    public let isPrivate: Bool
    public let isFork: Bool
    public let isArchived: Bool
    /// ISO 8601.
    public let pushedAt: String?
    public let htmlUrl: String
    public let cloneUrl: String
    public let defaultBranch: String?

    public var id: String { fullName }

    public init(fullName: String, name: String, owner: String, description: String? = nil,
                isPrivate: Bool = false, isFork: Bool = false, isArchived: Bool = false,
                pushedAt: String? = nil, htmlUrl: String = "", cloneUrl: String = "",
                defaultBranch: String? = nil) {
        self.fullName = fullName
        self.name = name
        self.owner = owner
        self.description = description
        self.isPrivate = isPrivate
        self.isFork = isFork
        self.isArchived = isArchived
        self.pushedAt = pushedAt
        self.htmlUrl = htmlUrl
        self.cloneUrl = cloneUrl
        self.defaultBranch = defaultBranch
    }

    public var pushedDate: Date? {
        pushedAt.flatMap { ISO8601DateFormatter().date(from: $0) }
    }
}

public struct GitHubRepoList: Sendable {
    public let repos: [GitHubRepo]
    /// Where clones land on the host, e.g. /Users/me/Documents/repos.
    public let cloneRoot: String?
}

/// A GitHub sign-in waiting for approval: enter `code` at `url`.
public struct GitHubAuthPending: Codable, Sendable, Hashable {
    /// e.g. "42D5-EAAE"
    public let code: String
    /// https://github.com/login/device
    public let url: String
    public let startedAt: Double
    public let expiresAt: Double

    public init(code: String, url: String, startedAt: Double = 0, expiresAt: Double = 0) {
        self.code = code
        self.url = url
        self.startedAt = startedAt
        self.expiresAt = expiresAt
    }
}

/// The host `gh` CLI's GitHub login.
public struct GitHubAuthStatus: Codable, Sendable, Hashable {
    public let ghInstalled: Bool
    public let signedIn: Bool
    /// Active account.
    public let login: String?
    public let scopes: String?
    public let pending: GitHubAuthPending?
    /// Why the last sign-in failed, or why the saved login is unusable.
    public let error: String?

    public init(ghInstalled: Bool, signedIn: Bool, login: String? = nil, scopes: String? = nil,
                pending: GitHubAuthPending? = nil, error: String? = nil) {
        self.ghInstalled = ghInstalled
        self.signedIn = signedIn
        self.login = login
        self.scopes = scopes
        self.pending = pending
        self.error = error
    }
}

/// A clone running (or recently finished) on the host.
public struct RepoCloneJob: Codable, Sendable, Identifiable, Hashable {
    public enum State: String, Codable, Sendable {
        case running, succeeded, failed
    }

    public let id: String
    /// What was asked for: owner/repo or a URL.
    public let source: String
    /// Folder name.
    public let name: String
    /// Absolute destination on the host.
    public let path: String
    public let state: State
    /// git's progress phase, e.g. "Receiving objects".
    public let phase: String?
    public let percent: Int?
    public let error: String?
    public let startedAt: Double
    public let finishedAt: Double?

    public init(id: String, source: String, name: String, path: String, state: State,
                phase: String? = nil, percent: Int? = nil, error: String? = nil,
                startedAt: Double = 0, finishedAt: Double? = nil) {
        self.id = id
        self.source = source
        self.name = name
        self.path = path
        self.state = state
        self.phase = phase
        self.percent = percent
        self.error = error
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

// MARK: - Graph

public enum RepoRefType: String, Codable, Sendable {
    case branch
    case remote
    case tag
    /// Bare HEAD marker emitted when HEAD is detached at this commit.
    case head
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RepoRefType(rawValue: raw) ?? .unknown
    }
}

public struct RefDecoration: Codable, Sendable, Hashable {
    public let name: String
    public let type: RepoRefType
    public let isHead: Bool

    public init(name: String, type: RepoRefType, isHead: Bool) {
        self.name = name
        self.type = type
        self.isHead = isHead
    }
}

public struct GraphCommit: Codable, Sendable, Identifiable, Hashable {
    public let sha: String
    public let parents: [String]
    public let authorName: String
    public let authorEmail: String
    /// Unix seconds (author date).
    public let timestamp: Double
    public let subject: String
    public let refs: [RefDecoration]

    public var id: String { sha }
    public var shortSha: String { String(sha.prefix(8)) }
    public var isMerge: Bool { parents.count > 1 }

    public init(sha: String, parents: [String], authorName: String, authorEmail: String = "", timestamp: Double, subject: String, refs: [RefDecoration] = []) {
        self.sha = sha
        self.parents = parents
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.timestamp = timestamp
        self.subject = subject
        self.refs = refs
    }
}

public struct RepoGraph: Codable, Sendable {
    public let repoPath: String
    public let headSha: String?
    public let currentBranch: String?
    /// Newest first, date-ordered.
    public let commits: [GraphCommit]
    public let hasMore: Bool
}

// MARK: - Branches

public struct BranchInfo: Codable, Sendable, Identifiable, Hashable {
    public let name: String
    public let isRemote: Bool
    public let isCurrent: Bool
    public let sha: String
    public let upstream: String?
    public let ahead: Int
    public let behind: Int
    /// Unix seconds.
    public let lastCommitTimestamp: Double
    public let lastCommitSubject: String

    public var id: String { (isRemote ? "remote:" : "local:") + name }
}

// MARK: - Commit detail

public struct CommitFileChange: Codable, Sendable, Hashable {
    public let path: String
    /// Set for renames, nil otherwise.
    public let oldPath: String?
    /// nil for binary files.
    public let added: Int?
    public let deleted: Int?

    public var isBinary: Bool { added == nil && deleted == nil }
}

public struct CommitDetail: Codable, Sendable {
    public let sha: String
    public let shortSha: String
    public let authorName: String
    public let authorEmail: String
    /// Unix seconds (author date).
    public let timestamp: Double
    public let parents: [String]
    /// Subject + body.
    public let message: String
    public let files: [CommitFileChange]
    /// Unified diff, -U3, possibly truncated.
    public let patch: String
    public let patchTruncated: Bool
}

// MARK: - Status

public struct RepoStatus: Codable, Sendable {
    /// nil when detached.
    public let branch: String?
    public let ahead: Int
    public let behind: Int
    public let staged: Int
    public let modified: Int
    public let untracked: Int

    public var dirtyCount: Int { staged + modified + untracked }
}
