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

    public var id: String { path }
    public var isDirty: Bool { dirtyCount > 0 }
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
