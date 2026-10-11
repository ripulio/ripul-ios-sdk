import XCTest
@testable import RipulAgent

/// Legend chips: one per named line, a chip for every hidden branch, and an
/// order that holds still while branches are hidden and shown.
final class RepoGraphLegendTests: XCTestCase {

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

    private func remote(_ name: String) -> RefDecoration {
        RefDecoration(name: name, type: .remote, isHead: false)
    }

    /// The legend the store would show for `commits` with `hidden` hidden.
    private func legend(_ commits: [GraphCommit], head: String = "m", hiding hidden: Set<String> = []) -> [String] {
        let visible = RepoGraphFilter.visibleCommits(commits: commits, headSha: head, hiddenBranches: hidden)
        return RepoGraphLegend.keys(
            commits: commits,
            shown: RepoGraphLayout.layout(commits: visible),
            hiddenBranches: hidden
        )
    }

    /// release sits on top of a line that is also staging's, further down.
    ///
    ///   T (release)        parent: S
    ///   M (main, HEAD)     parent: R
    ///   S (staging)        parent: R
    ///   R                  (root)
    private func stacked() -> [GraphCommit] {
        [
            commit("t", parents: ["s"], refs: [branch("release")]),
            commit("m", parents: ["r"], refs: [branch("main", isHead: true)]),
            commit("s", parents: ["r"], refs: [branch("staging")]),
            commit("r"),
        ]
    }

    func testOneChipPerNamedLineNewestTipFirst() {
        // staging is a label part-way down release's line: no chip of its own.
        XCTAssertEqual(legend(stacked()), ["release", "main"])
    }

    func testAnUnnamedLaneHasNoChip() {
        // The merged side line carries no label.
        let commits = [
            commit("m", parents: ["b", "s"], refs: [branch("main", isHead: true)]),
            commit("s", parents: ["r"]),
            commit("b", parents: ["r"]),
            commit("r"),
        ]
        XCTAssertEqual(legend(commits), ["main"])
    }

    func testAHiddenBranchKeepsItsChip() {
        XCTAssertEqual(legend(stacked(), hiding: ["release"]).first, "release")
    }

    func testTheLineBelowAHiddenBranchGainsAChipInPlace() {
        // With release hidden the rest of its line is staging's. Its color
        // needs a key, and the chips already there do not move.
        XCTAssertEqual(legend(stacked(), hiding: ["release"]), ["release", "main", "staging"])
    }

    func testABranchHiddenAfterItSurfacedKeepsItsChip() {
        // staging led no line in the unfiltered graph, so only the hidden
        // set says it is there to switch back on.
        XCTAssertEqual(legend(stacked(), hiding: ["release", "staging"]), ["release", "main", "staging"])
    }

    func testAHiddenChipKeepsItsPlaceWhenAnotherNameTakesItsCommit() {
        // release and alpha sit on one commit and release names the line.
        // With release hidden the line is alpha's. alpha sorts first by
        // name, but its chip must arrive after release's, not push it along
        // from under the tap.
        let commits = [
            commit("t", parents: ["r"], refs: [branch("release"), branch("alpha")]),
            commit("m", parents: ["r"], refs: [branch("main", isHead: true)]),
            commit("r"),
        ]
        XCTAssertEqual(legend(commits), ["release", "main"])
        XCTAssertEqual(legend(commits, hiding: ["release"]), ["release", "alpha", "main"])
    }

    func testOneChipForABranchHiddenInBothPlaces() {
        // The line is keyed by the remote copy on top; the local branch
        // further down is the same branch and adds no second chip.
        let commits = [
            commit("t", parents: ["s"], refs: [remote("origin/release")]),
            commit("m", parents: ["r"], refs: [branch("main", isHead: true)]),
            commit("s", parents: ["r"], refs: [branch("release")]),
            commit("r"),
        ]
        XCTAssertEqual(legend(commits, hiding: ["release"]), ["origin/release", "main"])
    }

    func testARemoteBranchNamesTheLineBeforeItsHeadPointer() {
        let commits = [
            commit("m", parents: ["r"], refs: [branch("work", isHead: true)]),
            commit("o", parents: ["r"], refs: [remote("origin/HEAD"), remote("origin/main")]),
            commit("r"),
        ]
        XCTAssertEqual(legend(commits), ["work", "origin/main"])
    }
}
