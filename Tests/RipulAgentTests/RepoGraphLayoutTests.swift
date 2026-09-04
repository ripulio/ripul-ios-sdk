import XCTest
@testable import RipulAgent

/// Lane-assignment engine tests. Every fixture obeys the input invariant the
/// host guarantees via `git log --all --date-order`: newest first, and a
/// commit never appears before any of its children.
final class RepoGraphLayoutTests: XCTestCase {

    private func commit(
        _ sha: String,
        parents: [String] = [],
        refs: [RefDecoration] = []
    ) -> GraphCommit {
        GraphCommit(sha: sha, parents: parents, authorName: "T", timestamp: 0, subject: sha, refs: refs)
    }

    private func branch(_ name: String, isHead: Bool = false) -> RefDecoration {
        RefDecoration(name: name, type: .branch, isHead: isHead)
    }

    // MARK: - Linear history

    func testLinearHistoryStaysInLaneZero() {
        // C ← B ← A (A newest)
        let layout = RepoGraphLayout.layout(commits: [
            commit("a", parents: ["b"]),
            commit("b", parents: ["c"]),
            commit("c"),
        ])

        XCTAssertEqual(layout.rows.count, 3)
        XCTAssertEqual(layout.rows.map(\.nodeLane), [0, 0, 0])
        XCTAssertEqual(layout.maxLaneCount, 1)

        // Every edge straight; no curves anywhere.
        for row in layout.rows {
            XCTAssertTrue(row.topSegments.allSatisfy(\.isStraight))
            XCTAssertTrue(row.bottomSegments.allSatisfy(\.isStraight))
        }
        // Root row: lane ends — no bottom segments, lane freed.
        XCTAssertTrue(layout.rows[2].bottomSegments.isEmpty)
        XCTAssertTrue(layout.rows[2].verticals.isEmpty)
    }

    // MARK: - Branch + merge

    ///   M (main)  parents: A, F
    ///   A         parent:  B
    ///   F         parent:  B
    ///   B         (root)
    func testBranchAndMerge() {
        let layout = RepoGraphLayout.layout(commits: [
            commit("m", parents: ["a", "f"], refs: [branch("main", isHead: true)]),
            commit("a", parents: ["b"]),
            commit("f", parents: ["b"]),
            commit("b"),
        ])

        XCTAssertEqual(layout.rows.map(\.nodeLane), [0, 0, 1, 0])
        XCTAssertEqual(layout.maxLaneCount, 2)

        let m = layout.rows[0]
        // M: straight continuation to A in lane 0, branch-off curve into the
        // new lane 1 for F.
        XCTAssertEqual(m.bottomSegments.count, 2)
        XCTAssertTrue(m.bottomSegments.contains(RepoGraphLayout.Segment(fromLane: 0, toLane: 0, id: m.nodeLaneId)))
        XCTAssertTrue(m.bottomSegments.contains { !$0.isStraight && $0.fromLane == 0 && $0.toLane == 1 })

        let a = layout.rows[1]
        // Lane 1 (expecting F) passes through A's row as a full vertical.
        XCTAssertTrue(a.verticals.contains { $0.lane == 1 })
        XCTAssertTrue(a.verticals.contains { $0.lane == 0 })

        let f = layout.rows[2]
        // F's own lane arrives as a stub above the node...
        XCTAssertTrue(f.topSegments.contains { $0.isStraight && $0.fromLane == 1 && $0.toLane == 1 })
        // ...and its edge to B collapses into lane 0 as a curve.
        XCTAssertTrue(f.bottomSegments.contains { !$0.isStraight && $0.fromLane == 1 && $0.toLane == 0 })
        // Lane 1 is freed at F's row: B's row sees only lane 0.
        XCTAssertEqual(layout.rows[3].laneCount, 1)
    }

    // MARK: - Two tips sharing a parent

    ///   A (feature)  parent: C
    ///   B (main)     parent: C
    ///   C            (root)
    func testSiblingTipsCollapseIntoSharedParent() {
        let layout = RepoGraphLayout.layout(commits: [
            commit("a", parents: ["c"], refs: [branch("feature")]),
            commit("b", parents: ["c"], refs: [branch("main", isHead: true)]),
            commit("c"),
        ])

        XCTAssertEqual(layout.rows.map(\.nodeLane), [0, 1, 0])
        // B could not inherit lane 0 (it expects C already) — it opens lane 1
        // and its edge to C collapses back into lane 0.
        let b = layout.rows[1]
        XCTAssertTrue(b.bottomSegments.contains { !$0.isStraight && $0.fromLane == 1 && $0.toLane == 0 })
    }

    // MARK: - Octopus merge

    ///   M parents: A, B, C
    ///   A parent: R   B parent: R   C parent: R
    ///   R (root)
    func testOctopusMergeOpensTwoLanes() {
        let layout = RepoGraphLayout.layout(commits: [
            commit("m", parents: ["a", "b", "c"], refs: [branch("main", isHead: true)]),
            commit("a", parents: ["r"]),
            commit("b", parents: ["r"]),
            commit("c", parents: ["r"]),
            commit("r"),
        ])

        XCTAssertEqual(layout.rows.map(\.nodeLane), [0, 0, 1, 2, 0])
        XCTAssertEqual(layout.maxLaneCount, 3)

        let m = layout.rows[0]
        let curves = m.bottomSegments.filter { !$0.isStraight }
        XCTAssertEqual(Set(curves.map(\.toLane)), [1, 2])
    }

    // MARK: - Lane recycling

    /// A collapsed lane's index is reused before a wider one is opened, so
    /// long histories with sequential branches stay narrow.
    func testLaneIndexIsRecycled() {
        // Two sequential branch/merge episodes against main.
        //   M2 parents: A2, F2     A2 parent: B2     F2 parent: B2
        //   B2 parent: M1
        //   M1 parents: A1, F1     A1 parent: R      F1 parent: R
        //   R (root)
        let layout = RepoGraphLayout.layout(commits: [
            commit("m2", parents: ["a2", "f2"]),
            commit("a2", parents: ["b2"]),
            commit("f2", parents: ["b2"]),
            commit("b2", parents: ["m1"]),
            commit("m1", parents: ["a1", "f1"]),
            commit("a1", parents: ["r"]),
            commit("f1", parents: ["r"]),
            commit("r"),
        ])

        XCTAssertEqual(layout.maxLaneCount, 2)
        // F2's collapse frees lane 1 before M1 opens its second-parent lane —
        // the recycled index is used.
        XCTAssertEqual(layout.rows[6].nodeLane, 1)
    }

    // MARK: - Color keys

    func testColorKeyPrefersHeadBranchThenAnyBranch() {
        let layout = RepoGraphLayout.layout(commits: [
            commit("a", parents: ["b"], refs: [branch("main", isHead: true)]),
            commit("b", parents: ["c"], refs: [branch("older-name")]),
            commit("c"),
        ])
        // Lane 0's newest decorated commit carries HEAD -> main; that wins
        // over the older decoration further down the same lane.
        let laneId = layout.rows[0].nodeLaneId
        XCTAssertEqual(layout.colorKey(forLaneId: laneId), "main")
    }

    func testColorKeyFallsBackToPositional() {
        let layout = RepoGraphLayout.layout(commits: [
            commit("a", parents: ["b", "c"]),
            commit("b"),
            commit("c"),
        ])
        let anonLaneId = layout.rows[2].nodeLaneId
        XCTAssertEqual(layout.colorKey(forLaneId: anonLaneId), "lane-\(anonLaneId)")
    }

    // MARK: - Robustness

    func testDuplicateShaIsIgnored() {
        let layout = RepoGraphLayout.layout(commits: [
            commit("a", parents: ["b"]),
            commit("a", parents: ["b"]),
            commit("b"),
        ])
        XCTAssertEqual(layout.rows.count, 2)
    }

    func testEmptyInput() {
        let layout = RepoGraphLayout.layout(commits: [])
        XCTAssertTrue(layout.rows.isEmpty)
        XCTAssertEqual(layout.maxLaneCount, 0)
    }

    func testStableHashIsDeterministic() {
        XCTAssertEqual(RepoGraphLayout.stableHash("main"), RepoGraphLayout.stableHash("main"))
        XCTAssertNotEqual(RepoGraphLayout.stableHash("main"), RepoGraphLayout.stableHash("feature"))
    }
}
