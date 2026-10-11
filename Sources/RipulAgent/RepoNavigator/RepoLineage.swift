import Foundation

// MARK: - Models

/// How a branch stands against the rest of the repo.
public enum LineageState: String, Codable, Sendable {
    /// Holds commits nothing outside its own descendants has.
    case active
    /// Everything on it is in another branch (`mergedInto`), brought in by a
    /// merge commit.
    case merged
    /// Has no line of its own: its tip sits on its base's line, left behind
    /// there or fast-forwarded into it. Everything on it is in its base.
    case onLine
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = LineageState(rawValue: raw) ?? .unknown
    }
}

/// One branch placed in the repo's lineage. A local branch and a remote's
/// copy of it are one branch (`RefDecoration.branchName`).
public struct LineageBranch: Codable, Sendable, Identifiable, Hashable {
    /// Branch name, remote prefix dropped.
    public let name: String
    public let hasLocal: Bool
    public let hasRemote: Bool
    public let isCurrent: Bool
    /// The line everything else is measured against: the remote's default
    /// branch where there is one.
    public let isTrunk: Bool
    /// The tip the lineage was read from: the local branch, unless the
    /// remote's copy is ahead of it on the same line.
    public let sha: String
    /// The branch this one stands on: the one it was cut from, or, where
    /// that one has since been merged away, the branch that took it in.
    /// nil for a root.
    public let base: String?
    /// Git records no parent for a branch. Where two lines part at a commit
    /// no branch points at and nothing says which one carried on, the base
    /// is a guess.
    public let baseIsGuess: Bool
    /// Commits it holds that its base does not, and commits its base holds
    /// that it does not: the two numbers `git rev-list --count` gives for
    /// `base..branch` and `branch..base`. Both 0 for a root and for a
    /// merged branch.
    public let ahead: Int
    public let behind: Int
    /// Where its own line starts. nil for a root.
    public let forkSha: String?
    /// Unix seconds of that commit.
    public let forkTimestamp: Double?
    public let state: LineageState
    /// For `.merged`: the branch that holds it.
    public let mergedInto: String?
    /// Unix seconds.
    public let lastCommitTimestamp: Double
    public let lastCommitSubject: String
    /// Commits the local branch has that its remote copy lacks, and the
    /// reverse, counted along the branch's own line. Both 0 with one copy.
    public let unpushed: Int
    public let unpulled: Int

    public var id: String { name }

    public init(name: String, hasLocal: Bool, hasRemote: Bool, isCurrent: Bool, isTrunk: Bool, sha: String,
                base: String?, baseIsGuess: Bool, ahead: Int, behind: Int,
                forkSha: String?, forkTimestamp: Double?, state: LineageState, mergedInto: String?,
                lastCommitTimestamp: Double, lastCommitSubject: String, unpushed: Int, unpulled: Int) {
        self.name = name
        self.hasLocal = hasLocal
        self.hasRemote = hasRemote
        self.isCurrent = isCurrent
        self.isTrunk = isTrunk
        self.sha = sha
        self.base = base
        self.baseIsGuess = baseIsGuess
        self.ahead = ahead
        self.behind = behind
        self.forkSha = forkSha
        self.forkTimestamp = forkTimestamp
        self.state = state
        self.mergedInto = mergedInto
        self.lastCommitTimestamp = lastCommitTimestamp
        self.lastCommitSubject = lastCommitSubject
        self.unpushed = unpushed
        self.unpulled = unpulled
    }
}

public struct RepoLineage: Codable, Sendable {
    public let repoPath: String
    public let trunk: String?
    /// Trunk first, then newest tip first.
    public let branches: [LineageBranch]
    /// The host read only the newest part of a very large history, so old
    /// forks may be missing.
    public let truncated: Bool

    public init(repoPath: String, trunk: String?, branches: [LineageBranch], truncated: Bool) {
        self.repoPath = repoPath
        self.trunk = trunk
        self.branches = branches
        self.truncated = truncated
    }
}

// MARK: - Builder

/// Reads a repo's branch lineage out of its commit graph: which branch each
/// branch came from, how far the two have moved apart, and what has been
/// merged where.
///
/// Git records none of this. A branch is a label on a commit, so the tree is
/// read from **first-parent lines**: a commit's first parent is the line it
/// was made on, any other parent is something merged in. Every branch's line
/// runs down its first parents, and the lines form a tree.
///
/// - Where lines part at a commit no branch points at, one of them carried
///   on and the others forked from it. The trunk carries on if it is there;
///   then a branch whose name the others extend (`v-3.3.2` over
///   `v-3.3.2-fix`); then the side more branches hang off; then the side
///   that takes more merges from elsewhere. Past that it is a guess, and is
///   marked as one.
/// - A merged branch is finished. What was cut from it, or left on its
///   line, stands on the branch that took it in.
/// - A branch whose tip sits on a line that carries on above it is either
///   what that line was cut from or a label it left behind. A single run of
///   plain commits above it is new work cut from it (`feature` on an
///   unmoved `develop`). A line above that forks or takes merges is a line
///   in its own right, and the branch is a place on it (`.onLine`): so is
///   any label on the trunk's line, or on the line of a branch it is named
///   after.
///
/// Pure Foundation, no git — the host feeds it parsed `git rev-list` and
/// `git for-each-ref` output. Unit-tested via `swift test`.
public enum RepoLineageBuilder {

    public struct Ref: Sendable {
        /// Short ref name: "main", "origin/main".
        public let name: String
        public let isRemote: Bool
        public let sha: String
        public let timestamp: Double
        public let subject: String

        public init(name: String, isRemote: Bool, sha: String, timestamp: Double = 0, subject: String = "") {
            self.name = name
            self.isRemote = isRemote
            self.sha = sha
            self.timestamp = timestamp
            self.subject = subject
        }
    }

    public struct Commit: Sendable {
        public let sha: String
        public let parents: [String]
        public let timestamp: Double

        public init(sha: String, parents: [String], timestamp: Double = 0) {
            self.sha = sha
            self.parents = parents
            self.timestamp = timestamp
        }
    }

    /// - Parameters:
    ///   - commits: every commit the branches reach, in an order where **no
    ///     parent comes before any of its children** (`git rev-list
    ///     --topo-order`). A parent listed out of that order is ignored.
    ///   - defaultBranch: the branch the remote's HEAD points at, if known.
    public static func build(
        repoPath: String,
        refs: [Ref],
        commits: [Commit],
        defaultBranch: String?,
        currentBranch: String?,
        truncated: Bool = false
    ) -> RepoLineage {
        let count = commits.count
        var index: [String: Int] = [:]
        index.reserveCapacity(count)
        for (i, commit) in commits.enumerated() where index[commit.sha] == nil { index[commit.sha] = i }

        // First-parent tree, and each commit's depth in it.
        var firstParent = [Int](repeating: -1, count: count)
        for i in 0..<count {
            if let parent = commits[i].parents.first, let p = index[parent], p > i { firstParent[i] = p }
        }
        var depth = [Int](repeating: 0, count: count)
        for i in stride(from: count - 1, through: 0, by: -1) where firstParent[i] >= 0 {
            depth[i] = depth[firstParent[i]] + 1
        }
        /// Where two commits' first-parent lines meet. nil when they never do.
        func meet(_ a: Int, _ b: Int) -> Int? {
            var x = a, y = b
            while x != y {
                guard x >= 0, y >= 0 else { return nil }
                if depth[x] > depth[y] { x = firstParent[x] }
                else if depth[y] > depth[x] { y = firstParent[y] }
                else { x = firstParent[x]; y = firstParent[y] }
            }
            return x >= 0 ? x : nil
        }

        // One branch per name, from its local and remote copies.
        struct Copy { let tip: Int; let timestamp: Double; let subject: String }
        var locals: [String: Copy] = [:]
        var remotes: [String: Copy] = [:]
        var order: [String] = []
        for ref in refs {
            guard let tip = index[ref.sha] else { continue }
            let decoration = RefDecoration(name: ref.name, type: ref.isRemote ? .remote : .branch, isHead: false)
            guard let name = decoration.branchName else { continue }
            if locals[name] == nil && remotes[name] == nil { order.append(name) }
            let copy = Copy(tip: tip, timestamp: ref.timestamp, subject: ref.subject)
            if ref.isRemote {
                // origin's copy over any other remote's.
                if remotes[name] == nil || ref.name.hasPrefix("origin/") { remotes[name] = copy }
            } else {
                locals[name] = copy
            }
        }

        struct Branch {
            let name: String
            let tip: Int
            let hasLocal: Bool
            let hasRemote: Bool
            let timestamp: Double
            let subject: String
            let unpushed: Int
            let unpulled: Int
        }
        var branches: [Branch] = order.compactMap { name in
            switch (locals[name], remotes[name]) {
            case let (local?, remote?):
                let common = meet(local.tip, remote.tip)
                // The local branch is behind its remote copy on one line:
                // the remote's tip is the branch as it stands.
                let behind = common == local.tip && local.tip != remote.tip
                let chosen = behind ? remote : local
                return Branch(name: name, tip: chosen.tip, hasLocal: true, hasRemote: true,
                              timestamp: chosen.timestamp, subject: chosen.subject,
                              unpushed: common.map { depth[local.tip] - depth[$0] } ?? 0,
                              unpulled: common.map { depth[remote.tip] - depth[$0] } ?? 0)
            case let (local?, nil):
                return Branch(name: name, tip: local.tip, hasLocal: true, hasRemote: false,
                              timestamp: local.timestamp, subject: local.subject, unpushed: 0, unpulled: 0)
            case let (nil, remote?):
                return Branch(name: name, tip: remote.tip, hasLocal: false, hasRemote: true,
                              timestamp: remote.timestamp, subject: remote.subject, unpushed: 0, unpulled: 0)
            case (nil, nil):
                return nil
            }
        }
        // A stable order for every "pick one" below.
        branches.sort { $0.name < $1.name }
        let total = branches.count
        guard total > 0 else {
            return RepoLineage(repoPath: repoPath, trunk: nil, branches: [], truncated: truncated)
        }
        let named = Dictionary(uniqueKeysWithValues: branches.enumerated().map { ($1.name, $0) })
        let trunk = [defaultBranch, "main", "master", currentBranch].compactMap { $0 }.compactMap { named[$0] }.first ?? -1

        // Every commit's parents, by index.
        var parentStart = [Int](repeating: 0, count: count + 1)
        var parentList: [Int] = []
        parentList.reserveCapacity(count + count / 8)
        for i in 0..<count {
            parentStart[i] = parentList.count
            for parent in commits[i].parents {
                if let p = index[parent], p > i { parentList.append(p) }
            }
        }
        parentStart[count] = parentList.count

        // Two sets of branches per commit, as bit rows:
        // `through` — branches whose first-parent line passes through it;
        // `holds`   — branches that have it anywhere in their history.
        let words = (total + 63) / 64
        var through = [UInt64](repeating: 0, count: count * words)
        var holds = [UInt64](repeating: 0, count: count * words)
        for (b, branch) in branches.enumerated() {
            through[branch.tip * words + b / 64] |= 1 << UInt64(b % 64)
            holds[branch.tip * words + b / 64] |= 1 << UInt64(b % 64)
        }
        for i in 0..<count {
            let row = i * words
            if firstParent[i] >= 0 {
                let target = firstParent[i] * words
                for w in 0..<words { through[target + w] |= through[row + w] }
            }
            for parent in commits[i].parents {
                guard let p = index[parent], p > i else { continue }
                let target = p * words
                for w in 0..<words { holds[target + w] |= holds[row + w] }
            }
        }
        func isSet(_ rows: [UInt64], _ commit: Int, _ branch: Int) -> Bool {
            branch >= 0 && rows[commit * words + branch / 64] & (1 << UInt64(branch % 64)) != 0
        }
        func population(_ rows: [UInt64], _ commit: Int) -> Int {
            (0..<words).reduce(0) { $0 + rows[commit * words + $1].nonzeroBitCount }
        }

        // The sides that leave each commit upward, and the labels on it.
        var sides = [[Int]](repeating: [], count: count)
        for i in 0..<count where firstParent[i] >= 0 && population(through, i) > 0 {
            sides[firstParent[i]].append(i)
        }
        var labels: [Int: [Int]] = [:]
        for (b, branch) in branches.enumerated() { labels[branch.tip, default: []].append(b) }

        /// Of several labels on one commit, the one the line is named after.
        func leading(_ candidates: [Int]) -> Int {
            candidates.min { a, b in
                let lhs = (a == trunk ? 0 : 1, branches[a].name == currentBranch ? 0 : 1, branches[a].hasLocal ? 0 : 1,
                           branches[a].name.count, branches[a].name)
                let rhs = (b == trunk ? 0 : 1, branches[b].name == currentBranch ? 0 : 1, branches[b].hasLocal ? 0 : 1,
                           branches[b].name.count, branches[b].name)
                return lhs < rhs
            } ?? candidates[0]
        }
        /// "v-3.3.2-fix" extends "v-3.3.2": a branch named after another.
        func extends(_ name: String, _ other: String) -> Bool {
            guard name.count > other.count, name.hasPrefix(other) else { return false }
            return "-_/.".contains(name[name.index(name.startIndex, offsetBy: other.count)])
        }

        // Which side carries a line on, bottom-up: by the time a commit is
        // reached every side above it knows the branch its line belongs to.
        // `owner[i]` — the branch whose line passes through commit i;
        // `onward[i]` — the side that line continues into, -1 where it ends.
        // `merges[i]` — merges that line takes from i up to its end, not
        // counting the trunk taken in to keep up with it;
        // `ends[i]` — how many lines end above i (1 for a single stack).
        var owner = [Int](repeating: -1, count: count)
        var onward = [Int](repeating: -1, count: count)
        var merges = [Int](repeating: 0, count: count)
        var ends = [Int](repeating: 0, count: count)

        /// Whether merge commit `commit` takes in the line `branch` is on.
        func takes(_ commit: Int, lineOf branch: Int) -> Bool {
            parentList[(parentStart[commit] + 1)..<parentStart[commit + 1]].contains { isSet(through, $0, branch) }
        }
        func isMerge(_ commit: Int) -> Bool { parentStart[commit + 1] - parentStart[commit] > 1 }
        /// Merges the line through `side` takes, from `side` up to its end,
        /// leaving out the trunk and the line through `rival`. Two lines
        /// that part and then merge one way or the other look the same from
        /// both sides (a feature keeping up with its base, a base taking a
        /// feature in), so only what a line takes from elsewhere says it is
        /// the one others are built on.
        func takesIn(_ side: Int, apartFrom rival: Int) -> Int {
            var found = 0
            var commit = side
            while commit >= 0 {
                if isMerge(commit), !takes(commit, lineOf: trunk), !takes(commit, lineOf: owner[rival]) { found += 1 }
                commit = onward[commit]
            }
            return found
        }

        enum Evidence: Int { case trunk, name, fanOut, merges, none }
        /// Whether side `a` carries the line on rather than side `b`, and
        /// what says so.
        func carriesOn(_ a: Int, over b: Int) -> (Bool, Evidence) {
            if isSet(through, a, trunk) { return (true, .trunk) }
            if isSet(through, b, trunk) { return (false, .trunk) }
            let aName = branches[owner[a]].name, bName = branches[owner[b]].name
            if extends(bName, aName) { return (true, .name) }
            if extends(aName, bName) { return (false, .name) }
            let aFan = population(through, a), bFan = population(through, b)
            if aFan != bFan { return (aFan > bFan, .fanOut) }
            let aTakes = takesIn(a, apartFrom: b), bTakes = takesIn(b, apartFrom: a)
            if aTakes != bTakes { return (aTakes > bTakes, .merges) }
            let aTime = branches[owner[a]].timestamp, bTime = branches[owner[b]].timestamp
            if aTime != bTime { return (aTime > bTime, .none) }
            return (aName < bName, .none)
        }

        /// A label with a line above it is one of two things, and git does
        /// not say which: the branch that line was cut from, or a label the
        /// line left behind as it moved on. Whether the line carries on past
        /// the labels `here` into `side`:
        func carriesPast(_ here: [Int], into side: Int) -> Bool {
            // The trunk's line is the trunk's, whatever was left along it.
            if isSet(through, side, trunk) { return true }
            let above = branches[owner[side]].name
            // Named after the branch above ("v-3.3.2-fix" under "v-3.3.2"):
            // a piece of work that line took in.
            if here.allSatisfy({ extends(branches[$0].name, above) }) { return true }
            // The branch above is named after this one: cut from it.
            if here.contains(where: { extends(above, branches[$0].name) }) { return false }
            // A single run of plain commits above reads as new work on top
            // of this branch. A line that forks or takes merges is a line in
            // its own right, and this label is a place it passed.
            return ends[side] > 1 || merges[side] > 0
        }

        for i in 0..<count {
            let here = labels[i] ?? []
            let above = sides[i]
            guard !here.isEmpty || !above.isEmpty else { continue }
            let best = above.dropFirst().reduce(above.first) { best, side in
                best.map { carriesOn(side, over: $0).0 ? side : $0 }
            }
            ends[i] = above.isEmpty ? 1 : above.reduce(0) { $0 + ends[$1] }
            if here.contains(trunk) {
                // The trunk's line ends at its tip; what is above forked from it.
                owner[i] = trunk
            } else if let best, here.isEmpty {
                onward[i] = best
            } else if let best, carriesPast(here, into: best) {
                onward[i] = best
            } else {
                // The line ends at this label; whatever is above was cut from it.
                owner[i] = leading(here)
            }
            if onward[i] >= 0 {
                owner[i] = owner[onward[i]]
                merges[i] = merges[onward[i]]
            }
            if isMerge(i), !takes(i, lineOf: trunk) { merges[i] += 1 }
        }

        // Top-down: where each line starts is where its branch left its base.
        var base = [Int](repeating: -1, count: total)
        var fork = [Int](repeating: -1, count: total)
        var guess = [Bool](repeating: false, count: total)
        var ownsLine = [Bool](repeating: false, count: total)
        for i in stride(from: count - 1, through: 0, by: -1) where owner[i] >= 0 {
            let below = firstParent[i]
            guard below < 0 || onward[below] != i else { continue }
            let branch = owner[i]
            ownsLine[branch] = true
            guard below >= 0, owner[below] >= 0 else { continue }
            base[branch] = owner[below]
            fork[branch] = below
            if onward[below] >= 0 {
                let evidence = carriesOn(onward[below], over: i).1
                guess[branch] = evidence == .merges || evidence == .none
            }
        }
        // A branch with no line of its own sits on someone else's.
        for b in 0..<total where !ownsLine[b] {
            base[b] = owner[branches[b].tip]
        }

        /// Whether `branch` descends from `ancestor` in the lineage.
        func descends(_ branch: Int, from ancestor: Int) -> Bool {
            var current = base[branch], steps = 0
            while current >= 0, steps <= total {
                if current == ancestor { return true }
                current = base[current]
                steps += 1
            }
            return false
        }
        func generation(_ branch: Int) -> Int {
            var current = base[branch], steps = 0
            while current >= 0, steps <= total { current = base[current]; steps += 1 }
            return steps
        }

        // Merged: held by a branch that is not one of its own descendants.
        // A descendant holding it only means the descendant is up to date
        // with it. The trunk is what things merge into, never the reverse.
        var mergedInto = [Int](repeating: -1, count: total)
        for b in 0..<total where ownsLine[b] && b != trunk {
            let tip = branches[b].tip
            let holders = (0..<total).filter { other in
                other != b && isSet(holds, tip, other) && branches[other].tip != tip
                    && !isSet(through, tip, other) && !descends(other, from: b)
            }
            guard !holders.isEmpty else { continue }
            let lines = holders.filter { ownsLine[$0] }
            mergedInto[b] = holders.contains(base[b]) ? base[b]
                : holders.contains(trunk) ? trunk
                : (lines.isEmpty ? holders : lines).min {
                    (generation($0), branches[$0].name) < (generation($1), branches[$1].name)
                } ?? -1
        }
        /// A merged branch is finished: what was cut from it, or left on its
        /// line, now stands on whichever branch took it in.
        func standing(_ branch: Int) -> Int {
            var current = branch, steps = 0
            while current >= 0, mergedInto[current] >= 0, steps <= total {
                current = mergedInto[current]
                steps += 1
            }
            return current
        }

        // Commit counts the way git gives them, for one pair at a time.
        var visited = [Int32](repeating: 0, count: count)
        var visit: Int32 = 0
        /// Commits reachable from `from` that `other` does not hold.
        func missing(from: Int, in other: Int) -> Int {
            visit += 1
            var found = 0
            var stack = [from]
            while let commit = stack.popLast() {
                guard visited[commit] != visit, !isSet(holds, commit, other) else { continue }
                visited[commit] = visit
                found += 1
                stack.append(contentsOf: parentList[parentStart[commit]..<parentStart[commit + 1]])
            }
            return found
        }

        let built: [LineageBranch] = branches.enumerated().map { b, branch in
            var state = LineageState.active
            var stands = base[b]
            var into = -1
            if !ownsLine[b] {
                // On someone's line. If that line has been merged away, so
                // has everything left on it.
                let line = base[b]
                stands = standing(line)
                if stands == line { state = .onLine } else { state = .merged; into = stands }
            } else if mergedInto[b] >= 0 {
                state = .merged
                into = standing(mergedInto[b])
                stands = standing(base[b])
            } else {
                stands = standing(base[b])
            }

            var ahead = 0, behind = 0
            if stands >= 0, state != .merged {
                if state == .active { ahead = missing(from: branch.tip, in: stands) }
                behind = missing(from: branches[stands].tip, in: b)
            }

            return LineageBranch(
                name: branch.name,
                hasLocal: branch.hasLocal,
                hasRemote: branch.hasRemote,
                isCurrent: branch.name == currentBranch && branch.hasLocal,
                isTrunk: b == trunk,
                sha: commits[branch.tip].sha,
                base: stands >= 0 ? branches[stands].name : nil,
                // Which side carried on at the fork stops mattering once the
                // branch stands on whoever holds that fork.
                baseIsGuess: guess[b] && stands == base[b],
                ahead: ahead,
                behind: behind,
                forkSha: fork[b] >= 0 ? commits[fork[b]].sha : nil,
                forkTimestamp: fork[b] >= 0 ? commits[fork[b]].timestamp : nil,
                state: state,
                mergedInto: into >= 0 ? branches[into].name : nil,
                lastCommitTimestamp: branch.timestamp,
                lastCommitSubject: branch.subject,
                unpushed: branch.unpushed,
                unpulled: branch.unpulled
            )
        }

        return RepoLineage(
            repoPath: repoPath,
            trunk: trunk >= 0 ? branches[trunk].name : nil,
            branches: built.sorted {
                ($0.isTrunk ? 0 : 1, -$0.lastCommitTimestamp, $0.name) < ($1.isTrunk ? 0 : 1, -$1.lastCommitTimestamp, $1.name)
            },
            truncated: truncated
        )
    }
}
