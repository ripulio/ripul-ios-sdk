import Foundation

/// Branch-visibility filtering for the commit graph.
///
/// Hiding a branch removes its line: the commits on the first-parent chain
/// below its tip, and anything that reached the graph only through them
/// (branches merged into it). Where that chain runs on into history other
/// lines share, the shared part stays, because a line still showing reaches
/// it through first parents of its own.
///
/// The rule is about lines, not reachability. A merged branch's commits are
/// all reachable from the branch that merged it, so "drop what only hidden
/// tips can reach" removes nothing for most branches. Here a merge of a
/// hidden branch stays where it is, on the branch it was merged into, and
/// loses its edge to the hidden side.
///
/// A branch is one thing wherever it lives: a hidden name hides the local
/// branch and every remote's copy (`RefDecoration.branchName`). Commits that
/// stay lose the hidden branches' labels.
///
/// Always showing: the checked-out branch, the commit HEAD is on, and tags
/// (the branches sheet toggles branches only). Computed client-side from the
/// already-loaded window — no host round-trip.
public enum RepoGraphFilter {

    /// The subset of `commits` visible when the branches named in
    /// `hiddenBranches` are hidden. Input order is preserved (already
    /// date-ordered newest-first).
    ///
    /// Names are branch names as `RefDecoration.branchName` gives them:
    /// "main" hides both `main` and `origin/main`.
    ///
    /// A returned commit can differ from its input: hidden branches' labels
    /// are gone from `refs`, and `parents` no longer lists a hidden commit,
    /// so RepoGraphLayout draws no lane toward it. A parent outside the
    /// window is kept — that lane runs off the bottom as it always did.
    public static func visibleCommits(
        commits: [GraphCommit],
        headSha: String?,
        hiddenBranches: Set<String>
    ) -> [GraphCommit] {
        // The checked-out branch never hides, in either place it lives.
        var hidden = hiddenBranches
        for commit in commits {
            for ref in commit.refs where ref.isHead {
                if let name = ref.branchName { hidden.remove(name) }
            }
        }
        guard !hidden.isEmpty else { return commits }

        func isHidden(_ ref: RefDecoration) -> Bool {
            ref.branchName.map(hidden.contains) ?? false
        }

        // A commit is a visible tip when something still showing points at
        // it, and a hidden tip when only hidden branches do. A remote's HEAD
        // pointer follows the branch it points at, so it decides nothing
        // unless it is the only label there.
        var visibleTips: [String] = []
        var hiddenTips: [String] = []
        for commit in commits {
            let named = commit.refs.filter { !$0.isRemoteHeadPointer }
            if commit.sha == headSha
                || named.contains(where: { !isHidden($0) })
                || (named.isEmpty && !commit.refs.isEmpty) {
                visibleTips.append(commit.sha)
            } else if !named.isEmpty {
                hiddenTips.append(commit.sha)
            }
        }

        let bySha = Dictionary(commits.map { ($0.sha, $0) }, uniquingKeysWith: { first, _ in first })

        // Each hidden branch's line: first parents from its tip. Below the
        // fork point this runs on into shared history, which stays when a
        // line still showing reaches it by first parents of its own.
        var hiddenLine: Set<String> = []
        for tip in hiddenTips {
            var next: String? = tip
            while let sha = next, let commit = bySha[sha], hiddenLine.insert(sha).inserted {
                next = commit.parents.first
            }
        }

        // Walk down from everything still showing. A first parent is the
        // commit's own line continuing, so it always follows. Any other
        // parent is something merged in, and a hidden line merged in stays
        // hidden.
        var visible: Set<String> = []
        var queue = visibleTips
        while let sha = queue.popLast() {
            guard let commit = bySha[sha], visible.insert(sha).inserted else { continue }
            for (index, parent) in commit.parents.enumerated() where index == 0 || !hiddenLine.contains(parent) {
                queue.append(parent)
            }
        }

        return commits.compactMap { commit in
            guard visible.contains(commit.sha) else { return nil }
            let parents = commit.parents.filter { visible.contains($0) || bySha[$0] == nil }
            var refs = commit.refs.filter { !isHidden($0) }
            // A remote's HEAD pointer goes with the branch it pointed at.
            if refs.count != commit.refs.count,
               !refs.contains(where: { $0.type == .remote && !$0.isRemoteHeadPointer }) {
                refs.removeAll(where: \.isRemoteHeadPointer)
            }
            guard parents != commit.parents || refs != commit.refs else { return commit }
            return GraphCommit(
                sha: commit.sha,
                parents: parents,
                authorName: commit.authorName,
                authorEmail: commit.authorEmail,
                timestamp: commit.timestamp,
                subject: commit.subject,
                refs: refs,
                sessionId: commit.sessionId,
                sessionTitle: commit.sessionTitle
            )
        }
    }
}
