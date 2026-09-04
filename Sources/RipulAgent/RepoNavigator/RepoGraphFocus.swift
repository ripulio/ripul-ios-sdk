import Foundation

/// First-parent heritage — the "story of one branch" — for focus mode.
///
/// `git log --all` answers "what's the topology"; this answers "what happened
/// on THIS branch". The walk follows first parents only from the tip, so the
/// branch's own commits form one clean line. Merge commits stay (they are the
/// branch's events), and each merge's other parents become one-row STUBS
/// placed immediately below the merge: a short incoming curve ending in a
/// node that carries the merged branch's pill, instead of the whole incoming
/// lane. Stub parents are stripped so their lanes terminate — the point is
/// "feature/x merged in here", not feature/x's entire history.
///
/// Below the fork point the walk naturally descends into the parent branch's
/// ancestry — that descent IS the heritage.
public enum RepoGraphFocus {

    /// The first-parent chain from `tipSha`, plus merge stubs, in an order
    /// that satisfies RepoGraphLayout's invariant (no parent before its
    /// children: each stub follows its merge, chain order otherwise kept).
    /// Empty when the tip isn't in the loaded window.
    public static func firstParentHeritage(commits: [GraphCommit], tipSha: String) -> [GraphCommit] {
        let bySha = Dictionary(uniqueKeysWithValues: commits.map { ($0.sha, $0) })
        guard bySha[tipSha] != nil else { return [] }

        // The chain first, so a merge whose side-parent is itself further
        // down the mainline doesn't yield a duplicate row.
        var chain: [GraphCommit] = []
        var onChain: Set<String> = []
        var current: String? = tipSha
        while let sha = current, let commit = bySha[sha] {
            onChain.insert(sha)
            chain.append(commit)
            current = commit.parents.first
        }

        var result: [GraphCommit] = []
        for commit in chain {
            result.append(commit)
            // Merge side-parents become stubs directly below the merge.
            for parent in commit.parents.dropFirst() {
                guard let stubCommit = bySha[parent], !onChain.contains(parent) else { continue }
                result.append(GraphCommit(
                    sha: stubCommit.sha,
                    parents: [],   // strip: the stub's lane ends here
                    authorName: stubCommit.authorName,
                    authorEmail: stubCommit.authorEmail,
                    timestamp: stubCommit.timestamp,
                    subject: stubCommit.subject,
                    refs: stubCommit.refs
                ))
            }
        }

        return result
    }
}
