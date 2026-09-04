import Foundation

/// Lane assignment for the repo navigator's GitKraken-style commit graph.
///
/// Input is `git log --all --date-order`: newest first, and — the invariant
/// everything here relies on — **a commit never appears before any of its
/// children**. The walk goes top-down; lanes carry "which sha is expected
/// next in this lane" downward; a commit takes the lowest lane expecting it
/// (or a fresh lane for an unreferenced tip), routes each parent into a lane
/// (first parent inherits the node's lane, merge parents get an existing lane
/// or a fresh one), and frees lanes the moment they collapse.
///
/// Rendering contract: each row is drawn as two half-rows around the node.
/// `verticals` are full-height lines; `topSegments` connect the row's top
/// edge to the node (straight stubs or collapse curves); `bottomSegments`
/// connect the node to the row's bottom edge (straight continuation or
/// branch-off curves). Lane identity (`id`) survives index recycling so
/// colors stay glued to a logical branch line across the whole window.
///
/// Pure Foundation, no SwiftUI — unit-tested via `swift test`.
public struct RepoGraphLayout: Sendable {

    /// A lane index + its persistent identity (survives lane-index recycling).
    public struct LaneRef: Sendable, Hashable {
        public let lane: Int
        public let id: Int
        public init(lane: Int, id: Int) {
            self.lane = lane
            self.id = id
        }
    }

    /// A half-row segment. `fromLane == toLane` is a straight piece; differing
    /// lanes mean a curve (Bezier in the view). The id carries the color.
    public struct Segment: Sendable, Hashable {
        public let fromLane: Int
        public let toLane: Int
        public let id: Int
        public init(fromLane: Int, toLane: Int, id: Int) {
            self.fromLane = fromLane
            self.toLane = toLane
            self.id = id
        }
        public var isStraight: Bool { fromLane == toLane }
    }

    public struct Row: Sendable {
        public let commit: GraphCommit
        public let nodeLane: Int
        public let nodeLaneId: Int
        /// Lanes passing straight through the row, full height.
        public let verticals: [LaneRef]
        /// Top-edge → node segments (node stub and collapses into the node).
        public let topSegments: [Segment]
        /// Node → bottom-edge segments (first-parent line, branch-off curves).
        public let bottomSegments: [Segment]
        /// Highest lane index visible in this row + 1 (strip width hint).
        public let laneCount: Int
    }

    public let rows: [Row]
    /// Widest the graph strip ever gets — size the strip to this so lanes
    /// don't jitter horizontally while scrolling.
    public let maxLaneCount: Int
    /// laneId → color key ("<branch name>" when any commit on the lane carried
    /// a ref, else "lane-<id>"). Hash deterministically — never Swift's
    /// `hashValue`, which is per-process random and would repaint lanes on
    /// every launch.
    public let colorKeyForLaneId: [Int: String]

    public func colorKey(forLaneId id: Int) -> String {
        colorKeyForLaneId[id] ?? "lane-\(id)"
    }

    /// Deterministic djb2 for palette mapping — stable across launches.
    public static func stableHash(_ key: String) -> Int {
        var hash = 5381
        for scalar in key.unicodeScalars {
            hash = ((hash << 5) &+ hash) &+ Int(scalar.value)
        }
        return hash & 0x7FFF_FFFF
    }

    public static func layout(commits: [GraphCommit]) -> RepoGraphLayout {
        var laneExpectation: [Int: String] = [:]   // lane index → sha expected next
        var laneIdAt: [Int: Int] = [:]              // lane index → persistent id
        var freeLanes: [Int] = []                   // recycled lane indices, sorted
        var nextLaneIndex = 0
        var nextLaneId = 0
        var colorKeyForLaneId: [Int: String] = [:]
        var rows: [Row] = []
        var maxLaneCount = 0
        var seenShas: Set<String> = []

        func takeLane() -> Int {
            if !freeLanes.isEmpty { return freeLanes.removeFirst() }
            defer { nextLaneIndex += 1 }
            return nextLaneIndex
        }
        func releaseLane(_ lane: Int) {
            laneExpectation[lane] = nil
            laneIdAt[lane] = nil
            freeLanes.append(lane)
            freeLanes.sort()
        }
        /// Color preference: the branch HEAD points at, then any local branch,
        /// then a tag, then a remote. First decorated commit on the lane wins —
        /// walking newest-first, that's the tip, which is the name a user
        /// recognises as "the branch's color".
        func preferredColorKey(_ commit: GraphCommit) -> String? {
            let refs = commit.refs
            if let head = refs.first(where: { $0.isHead && $0.type == .branch }) { return head.name }
            if let branch = refs.first(where: { $0.type == .branch }) { return branch.name }
            if let tag = refs.first(where: { $0.type == .tag }) { return tag.name }
            if let remote = refs.first(where: { $0.type == .remote }) { return remote.name }
            return nil
        }

        for commit in commits {
            // Defensive: a sha listed twice would corrupt expectations.
            guard seenShas.insert(commit.sha).inserted else { continue }

            let above = Set(laneExpectation.keys)
            let matching = laneExpectation.filter { $0.value == commit.sha }.keys.sorted()

            let nodeLane: Int
            if let first = matching.first {
                nodeLane = first
                laneExpectation[first] = nil
                // Shouldn't happen (eager collapse keeps one expectant per
                // sha), but if duplicates ever occur, collapse them here.
                for extra in matching.dropFirst() { releaseLane(extra) }
            } else {
                nodeLane = takeLane()
                laneIdAt[nodeLane] = nextLaneId
                nextLaneId += 1
            }
            let nodeId = laneIdAt[nodeLane] ?? -1
            if colorKeyForLaneId[nodeId] == nil, let key = preferredColorKey(commit) {
                colorKeyForLaneId[nodeId] = key
            }

            // Route parents into lanes.
            var exits: [Segment] = []
            var nodeLaneContinues = false
            for (index, parent) in commit.parents.enumerated() {
                if let existing = laneExpectation.first(where: { $0.value == parent })?.key {
                    // Another child already opened a lane expecting this parent
                    // — collapse into it. The curve keeps the SOURCE lane's
                    // color: it is this branch's edge, ending where it joins
                    // the other line.
                    exits.append(Segment(fromLane: nodeLane, toLane: existing, id: nodeId))
                } else if index == 0 {
                    laneExpectation[nodeLane] = parent
                    nodeLaneContinues = true
                    exits.append(Segment(fromLane: nodeLane, toLane: nodeLane, id: nodeId))
                } else {
                    let lane = takeLane()
                    laneIdAt[lane] = nextLaneId
                    nextLaneId += 1
                    laneExpectation[lane] = parent
                    exits.append(Segment(fromLane: nodeLane, toLane: lane, id: laneIdAt[lane]!))
                }
            }

            let laneEnds = !nodeLaneContinues
            if laneEnds {
                laneExpectation[nodeLane] = nil
            }
            let below = Set(laneExpectation.keys)

            // Verticals: lanes alive on both sides of the row.
            let verticals = above.intersection(below)
                .sorted()
                .map { LaneRef(lane: $0, id: laneIdAt[$0] ?? -1) }

            // Top half: lanes that end at this row collapse into the node;
            // the node's own lane arriving from above is a straight stub.
            var topSegments: [Segment] = []
            for lane in above.subtracting(below).sorted() {
                if lane == nodeLane {
                    topSegments.append(Segment(fromLane: nodeLane, toLane: nodeLane, id: nodeId))
                } else {
                    topSegments.append(Segment(fromLane: lane, toLane: nodeLane, id: laneIdAt[lane] ?? nodeId))
                }
            }

            // Bottom half: skip straight self-edges already drawn as full
            // verticals; everything else leaves from the node.
            var bottomSegments: [Segment] = []
            for exit in exits {
                if exit.isStraight && above.contains(exit.toLane) { continue }
                bottomSegments.append(exit)
            }

            // Free the node's lane only after geometry is derived.
            if laneEnds {
                releaseLane(nodeLane)
            }

            let visible = above.union(below).union([nodeLane])
            let laneCount = (visible.max() ?? 0) + 1
            maxLaneCount = max(maxLaneCount, laneCount)

            rows.append(Row(
                commit: commit,
                nodeLane: nodeLane,
                nodeLaneId: nodeId,
                verticals: verticals,
                topSegments: topSegments,
                bottomSegments: bottomSegments,
                laneCount: laneCount
            ))
        }

        // Lanes that never met a decorated commit get a positional key.
        for id in 0..<nextLaneId where colorKeyForLaneId[id] == nil {
            colorKeyForLaneId[id] = "lane-\(id)"
        }

        return RepoGraphLayout(
            rows: rows,
            maxLaneCount: maxLaneCount,
            colorKeyForLaneId: colorKeyForLaneId
        )
    }
}
