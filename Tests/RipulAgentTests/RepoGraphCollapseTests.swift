import XCTest
@testable import RipulAgent

/// Collapse pass over RepoGraphLayout rows: long runs of structurally
/// invisible commits fold into one marker; anything with geometry or refs
/// breaks a run.
final class RepoGraphCollapseTests: XCTestCase {

    private func commit(
        _ sha: String,
        parents: [String] = [],
        refs: [RefDecoration] = []
    ) -> GraphCommit {
        GraphCommit(sha: sha, parents: parents, authorName: "T", timestamp: 0, subject: sha, refs: refs)
    }

    /// A linear chain: shas[0] newest … shas.last is the root.
    private func linearRows(_ shas: [String]) -> [RepoGraphLayout.Row] {
        let commits = shas.enumerated().map { index, sha in
            commit(sha, parents: index == shas.count - 1 ? [] : [shas[index + 1]])
        }
        return RepoGraphLayout.layout(commits: commits).rows
    }

    private func collapsedItems(_ items: [RepoGraphItem]) -> [CollapsedRun] {
        items.compactMap { if case .collapsed(let run) = $0 { return run } ; return nil }
    }

    private func rowShas(_ items: [RepoGraphItem]) -> [String] {
        items.compactMap { if case .row(let row) = $0 { return row.commit.sha } ; return nil }
    }

    // MARK: - Runs

    func testShortRunIsNotCollapsed() {
        let items = RepoGraphCollapse.items(rows: linearRows((1...8).reversed().map { "c\($0)" }), headSha: nil)
        XCTAssertTrue(collapsedItems(items).isEmpty)
        XCTAssertEqual(items.count, 8)
    }

    func testLongRunCollapsesToEdgesPlusMarker() {
        // 20 linear commits, threshold 9 → keep 2 + marker(16) + 2.
        let shas = (1...20).reversed().map { "c\($0)" }
        // Head gets a ref so it reads as a tip — but note it must not collapse anyway.
        let rows = RepoGraphLayout.layout(commits: shas.enumerated().map { index, sha in
            commit(sha,
                   parents: index == shas.count - 1 ? [] : [shas[index + 1]],
                   refs: index == 0 ? [RefDecoration(name: "main", type: .branch, isHead: true)] : [])
        }).rows

        let items = RepoGraphCollapse.items(rows: rows, headSha: "c20")
        let markers = collapsedItems(items)
        XCTAssertEqual(markers.count, 1)
        // Run is c19…c2 (18 rows — c20 has refs, c1 is the root): 2 + 14 + 2.
        XCTAssertEqual(markers[0].count, 14)
        // HEAD row + 2 edge rows + marker + 2 edge rows + root row.
        XCTAssertEqual(items.count, 7)
        // The two rows above the marker are the run's first two (newest).
        XCTAssertEqual(rowShas(items).prefix(3), ["c20", "c19", "c18"])
        // Tail rows preserved: oldest two collapsible + root.
        XCTAssertEqual(rowShas(items).suffix(3), ["c3", "c2", "c1"])
    }

    func testRefBreaksRun() {
        // 12 commits; the middle one carries a tag.
        let shas = (1...12).reversed().map { "c\($0)" }
        let rows = RepoGraphLayout.layout(commits: shas.enumerated().map { index, sha in
            commit(sha,
                   parents: index == shas.count - 1 ? [] : [shas[index + 1]],
                   refs: sha == "c7" ? [RefDecoration(name: "v1.0", type: .tag, isHead: false)] : [])
        }).rows

        let items = RepoGraphCollapse.items(rows: rows, headSha: nil)
        // Runs on either side of the tag are 5 and 6 long — under threshold.
        XCTAssertTrue(collapsedItems(items).isEmpty)
        XCTAssertEqual(items.count, 12)
    }

    func testMergeBreaksRunAndNeverHides() {
        // main: M has parents A and F; linear tail after B.
        //   M, A, F, B, then 12 linear commits below B.
        let tail = (1...12).reversed().map { "t\($0)" }
        var commits: [GraphCommit] = [
            commit("m", parents: ["a", "f"], refs: [RefDecoration(name: "main", type: .branch, isHead: true)]),
            commit("a", parents: ["b"]),
            commit("f", parents: ["b"]),
            commit("b", parents: [tail.first!]),
        ]
        commits += tail.enumerated().map { index, sha in
            commit(sha, parents: index == tail.count - 1 ? [] : [tail[index + 1]])
        }
        let rows = RepoGraphLayout.layout(commits: commits).rows

        let items = RepoGraphCollapse.items(rows: rows, headSha: "m")
        let visible = rowShas(items)
        // Structural rows are always visible.
        for sha in ["m", "a", "f", "b"] {
            XCTAssertTrue(visible.contains(sha), "\(sha) must stay visible")
        }
        // The linear tail collapses into one marker.
        XCTAssertEqual(collapsedItems(items).count, 1)
    }

    func testHeadRowNeverCollapses() {
        // 15 commits, HEAD mid-run with no refs — the sha alone protects it.
        let shas = (1...15).reversed().map { "c\($0)" }
        let rows = linearRows(shas)
        let items = RepoGraphCollapse.items(rows: rows, headSha: "c8")
        XCTAssertTrue(rowShas(items).contains("c8"))
        // And the run split around it: two runs of 7 — under threshold, so
        // actually nothing collapses at all.
        XCTAssertTrue(collapsedItems(items).isEmpty)
    }

    // MARK: - Expansion

    func testExpandedRunFlattensAndGetsReCollapseHandle() {
        let shas = (1...20).reversed().map { "c\($0)" }
        let rows = linearRows(shas)

        let collapsed = RepoGraphCollapse.items(rows: rows, headSha: nil)
        let marker = collapsedItems(collapsed).first!
        // Run is c19…c2: c20 opens the lane (segment out) and c1 is the root,
        // leaving 18 collapsible — 2 edge rows at each end hides 14.
        XCTAssertEqual(marker.count, 14)

        let expanded = RepoGraphCollapse.items(rows: rows, headSha: nil, expanded: [marker.id])
        let handles = collapsedItems(expanded)
        XCTAssertEqual(handles.count, 1)
        XCTAssertTrue(handles[0].isReCollapseHandle)
        // All 20 commits visible + the handle.
        XCTAssertEqual(rowShas(expanded).count, 20)
        XCTAssertEqual(expanded.count, 21)
    }

    func testMarkerLanesMatchRunVerticals() {
        // A parallel lane floats past the whole run: merge at top whose
        // second parent lands below the collapsed region.
        //   M parents A,F ; A parent F ; then F → 12 linear.
        let tail = (1...12).reversed().map { "t\($0)" }
        var commits: [GraphCommit] = [
            commit("m", parents: ["a", "f"]),
            commit("a", parents: ["f"]),
            commit("f", parents: [tail.first!]),
        ]
        commits += tail.enumerated().map { index, sha in
            commit(sha, parents: index == tail.count - 1 ? [] : [tail[index + 1]])
        }
        let rows = RepoGraphLayout.layout(commits: commits).rows
        let items = RepoGraphCollapse.items(rows: rows, headSha: nil)
        let marker = collapsedItems(items).first!
        // Lanes carried through the marker match what the run's rows draw.
        XCTAssertEqual(marker.lanes.count, rows[3].verticals.count)
    }
}
