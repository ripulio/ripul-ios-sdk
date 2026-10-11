import Foundation

/// Which chips the graph's legend shows, and in what order.
///
/// One chip per named line. A hidden branch keeps its chip so it can be
/// switched back on, and a line that takes a new name once the branch above
/// it is hidden gains one — otherwise its color would have no key.
///
/// Chips are ordered by where each name first appears in the window, newest
/// first. That depends on the commits alone, so a chip holds its place while
/// branches are hidden and shown.
public enum RepoGraphLegend {

    /// Legend keys for `commits` (the whole loaded window) when `shown` is
    /// the layout on screen and `hiddenBranches` are hidden. A key is a ref
    /// name, the same string the lane's color hashes from.
    public static func keys(
        commits: [GraphCommit],
        shown: RepoGraphLayout,
        hiddenBranches: Set<String>
    ) -> [String] {
        // Where each ref name first appears, and the branch it stands for.
        var firstIndex: [String: Int] = [:]
        var branchForName: [String: String] = [:]
        for (index, commit) in commits.enumerated() {
            for ref in commit.refs {
                if firstIndex[ref.name] == nil { firstIndex[ref.name] = index }
                if branchForName[ref.name] == nil, let branch = ref.branchName {
                    branchForName[ref.name] = branch
                }
            }
        }

        // Named lines of the unfiltered graph (a hidden branch that led a
        // line keeps the chip it had) and of the graph on screen. The
        // positional fallback "lane-<id>" is an anonymous lane: no chip.
        let full = RepoGraphLayout.layout(commits: commits)
        let unfiltered = Set(full.colorKeyForLaneId.values)
        var keys = unfiltered
            .union(shown.colorKeyForLaneId.values)
            .filter { !$0.hasPrefix("lane-") }

        // A hidden branch that never led a line in the unfiltered graph (its
        // label sat part-way down another's) has no chip yet. Name it the
        // way its lane was named while it showed: local first, then remote.
        var represented = Set(keys.compactMap { branchForName[$0] })
        for commit in commits {
            let locals = commit.refs.filter { $0.type == .branch }
            for ref in locals + commit.refs.filter({ $0.type != .branch }) {
                guard let branch = ref.branchName, hiddenBranches.contains(branch),
                      represented.insert(branch).inserted else { continue }
                keys.insert(ref.name)
            }
        }

        // Two names on one commit: the one that had the chip first keeps its
        // place, and the other's chip arrives after it. Sorted by name alone,
        // a chip could step aside from under the tap that hid it.
        return keys.sorted {
            let lhs = (firstIndex[$0] ?? .max, unfiltered.contains($0) ? 0 : 1, $0)
            let rhs = (firstIndex[$1] ?? .max, unfiltered.contains($1) ? 0 : 1, $1)
            return lhs < rhs
        }
    }
}
