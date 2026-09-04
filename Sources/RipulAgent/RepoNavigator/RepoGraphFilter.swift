import Foundation

/// Branch-visibility filtering for the commit graph.
///
/// Hiding a branch means its tip no longer seeds the walk: commits reachable
/// ONLY through hidden tips drop out, shared history stays, and the branch's
/// lane disappears on relayout. Computed client-side from the already-loaded
/// window — no host round-trip.
///
/// HEAD is always an anchor (you cannot hide the commit you have checked
/// out), and tags always seed — the branches sheet toggles branches and
/// remotes only.
public enum RepoGraphFilter {

    /// The subset of `commits` visible when `hiddenRefs` ref names are hidden.
    /// Input order is preserved (already date-ordered newest-first).
    ///
    /// Ref names match RefDecoration.name — the same short names BranchInfo
    /// carries ("main", "origin/main").
    public static func visibleCommits(
        commits: [GraphCommit],
        headSha: String?,
        hiddenRefs: Set<String>
    ) -> [GraphCommit] {
        guard !hiddenRefs.isEmpty else { return commits }

        // Seed the walk with every commit carrying at least one visible ref,
        // plus HEAD.
        var seeds: Set<String> = []
        for commit in commits {
            if commit.sha == headSha {
                seeds.insert(commit.sha)
                continue
            }
            for ref in commit.refs {
                // Tags never hide — they are not in the branches sheet.
                guard ref.type == .branch || ref.type == .remote else {
                    seeds.insert(commit.sha)
                    continue
                }
                if !hiddenRefs.contains(ref.name) {
                    seeds.insert(commit.sha)
                    break
                }
            }
        }

        // BFS from the tips through parents.
        let parentsBySha = Dictionary(uniqueKeysWithValues: commits.map { ($0.sha, $0.parents) })
        var reachable: Set<String> = []
        var queue = Array(seeds)
        while let sha = queue.popLast() {
            guard reachable.insert(sha).inserted else { continue }
            queue.append(contentsOf: parentsBySha[sha] ?? [])
        }

        return commits.filter { reachable.contains($0.sha) }
    }
}
