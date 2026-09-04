import Foundation

/// Groups a commit's ref decorations into one canonical label per branch.
///
/// `git log` decorations restate the same branch once per location: a local
/// `main` and `origin/main` on the same commit are two refs but ONE branch.
/// The group collapses them: a single pill carries the short name, and the
/// icons in front say where the branch lives (computer = local, cloud =
/// remote, both = in sync on both). Tags group separately from branches —
/// a `v1.0` tag and a `v1.0` branch are different things.
///
/// Remote short names drop the first path component ("origin/feature/x" →
/// "feature/x"); two remotes carrying the same branch name merge into one
/// group either way.
public struct RefGroup: Sendable, Hashable {
    /// The short branch/tag name ("main", "feature/x"). No remote prefix.
    public let name: String
    public let isTag: Bool
    public let hasLocal: Bool
    public let hasRemote: Bool
    /// A bare HEAD decoration (detached HEAD) on this commit.
    public let hasDetachedHead: Bool
    /// HEAD points at the local branch in this group.
    public let isCurrentHead: Bool

    /// Pill text — the current branch announces itself; a bare detached
    /// HEAD marker just reads HEAD.
    public var label: String {
        if hasDetachedHead { return "HEAD" }
        return isCurrentHead && hasLocal ? "HEAD → \(name)" : name
    }

    /// Kind glyphs in display order: computer, cloud / tag / flag.
    public var symbols: [String] {
        var out: [String] = []
        if isTag { out.append("tag") }
        if hasLocal { out.append("laptopcomputer") }
        if hasRemote { out.append("cloud") }
        if hasDetachedHead { out.append("flag") }
        return out
    }
}

public enum RepoRefGrouper {

    /// Group refs, preserving first-appearance order (git's decoration
    /// order puts the HEAD branch first, which is the order users expect).
    public static func group(_ refs: [RefDecoration]) -> [RefGroup] {
        var order: [String] = []
        var byKey: [String: (name: String, isTag: Bool, local: Bool, remote: Bool, detached: Bool, head: Bool)] = [:]

        for ref in refs {
            switch ref.type {
            case .branch:
                let key = "branch:\(ref.name)"
                var g = byKey[key] ?? (ref.name, false, false, false, false, false)
                g.local = true
                if ref.isHead { g.head = true }
                if byKey[key] == nil { order.append(key) }
                byKey[key] = g
            case .remote:
                let short = ref.name.components(separatedBy: "/").dropFirst().joined(separator: "/")
                let key = "branch:\(short)"
                var g = byKey[key] ?? (short, false, false, false, false, false)
                g.remote = true
                if byKey[key] == nil { order.append(key) }
                byKey[key] = g
            case .tag:
                let key = "tag:\(ref.name)"
                var g = byKey[key] ?? (ref.name, true, false, false, false, false)
                g.isTag = true
                if byKey[key] == nil { order.append(key) }
                byKey[key] = g
            case .head:
                // Bare HEAD (detached) — its own marker, no branch name.
                let key = "head:\(ref.name)"
                if byKey[key] == nil {
                    order.append(key)
                    byKey[key] = ("", false, false, false, true, false)
                }
            case .unknown:
                continue
            }
        }

        return order.compactMap { key in
            guard let g = byKey[key] else { return nil }
            return RefGroup(
                name: g.name,
                isTag: g.isTag,
                hasLocal: g.local,
                hasRemote: g.remote,
                hasDetachedHead: g.detached,
                isCurrentHead: g.head
            )
        }
    }
}
