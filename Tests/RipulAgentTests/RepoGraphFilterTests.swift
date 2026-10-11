import XCTest
@testable import RipulAgent

/// Branch-visibility filtering: hiding a branch removes its own line, merged
/// or not; shared history, tags and the checked-out branch always survive.
final class RepoGraphFilterTests: XCTestCase {

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

    private func visible(
        _ commits: [GraphCommit], head: String? = "m", hiding hidden: Set<String>
    ) -> [GraphCommit] {
        RepoGraphFilter.visibleCommits(commits: commits, headSha: head, hiddenBranches: hidden)
    }

    /// An UNMERGED feature branch.
    ///
    ///   M (main, HEAD)  parent: B
    ///   F (feature)     parent: D
    ///   B               parent: R
    ///   D (feature-only) parent: R
    ///   R               (root)
    private func fixture() -> [GraphCommit] {
        [
            commit("m", parents: ["b"], refs: [branch("main", isHead: true)]),
            commit("f", parents: ["d"], refs: [branch("feature")]),
            commit("b", parents: ["r"]),
            commit("d", parents: ["r"]),
            commit("r"),
        ]
    }

    /// A feature branch MERGED into main, its label still on its tip.
    ///
    ///   M (main, HEAD)  parents: B, F   ← the merge
    ///   F (feature)     parent: D
    ///   B               parent: R
    ///   D               parent: R
    ///   R               (root)
    private func mergedFixture() -> [GraphCommit] {
        [
            commit("m", parents: ["b", "f"], refs: [branch("main", isHead: true)]),
            commit("f", parents: ["d"], refs: [branch("feature")]),
            commit("b", parents: ["r"]),
            commit("d", parents: ["r"]),
            commit("r"),
        ]
    }

    // MARK: - Unmerged branches

    func testNoHiddenBranchesIsIdentity() {
        let commits = fixture()
        XCTAssertEqual(visible(commits, hiding: []), commits)
    }

    func testHidingFeatureDropsItsWholeUnmergedLane() {
        let result = visible(fixture(), hiding: ["feature"])
        // F and D are the feature's own line → gone; main's line and the
        // shared root stay. Input order preserved.
        XCTAssertEqual(result.map(\.sha), ["m", "b", "r"])
    }

    // MARK: - Merged branches

    func testHidingAMergedBranchRemovesItsLine() {
        let result = visible(mergedFixture(), hiding: ["feature"])
        // Every commit here is reachable from main through the merge, so
        // reachability alone would hide nothing. The feature's line goes.
        XCTAssertEqual(result.map(\.sha), ["m", "b", "r"])
    }

    func testTheMergeStaysAndLosesItsEdgeToTheHiddenSide() {
        let result = visible(mergedFixture(), hiding: ["feature"])
        // Left in `parents`, "f" would make the layout hold a lane open for
        // a commit that never arrives.
        XCTAssertEqual(result.first?.parents, ["b"])
        let layout = RepoGraphLayout.layout(commits: result)
        XCTAssertEqual(layout.maxLaneCount, 1)
    }

    func testABranchThatMovedOnAfterItsMergeHidesWhole() {
        // feature was merged at D, then gained F. Both are its line.
        let commits = [
            commit("f", parents: ["d"], refs: [branch("feature")]),
            commit("m", parents: ["b", "d"], refs: [branch("main", isHead: true)]),
            commit("b", parents: ["r"]),
            commit("d", parents: ["r"]),
            commit("r"),
        ]
        XCTAssertEqual(visible(commits, hiding: ["feature"]).map(\.sha), ["m", "b", "r"])
    }

    func testWhatWasOnlyMergedIntoAHiddenBranchGoesWithIt() {
        // S was merged into feature (F's second parent) and has no label:
        // nothing still showing leads to it.
        let commits = [
            commit("m", parents: ["b", "f"], refs: [branch("main", isHead: true)]),
            commit("f", parents: ["d", "s"], refs: [branch("feature")]),
            commit("s", parents: ["d"]),
            commit("b", parents: ["r"]),
            commit("d", parents: ["r"]),
            commit("r"),
        ]
        XCTAssertEqual(visible(commits, hiding: ["feature"]).map(\.sha), ["m", "b", "r"])
    }

    func testAnUnlabelledMergedLineSurvivesABranchForkedFromIt() {
        // S1 ← S2 ← S3 was merged into main and its label deleted. feature
        // forked from S2. Hiding feature takes X only: S2 and S1 are still
        // the line S3 continues, though feature's first parents run through
        // them.
        let commits = [
            commit("m", parents: ["b", "s3"], refs: [branch("main", isHead: true)]),
            commit("x", parents: ["s2"], refs: [branch("feature")]),
            commit("s3", parents: ["s2"]),
            commit("s2", parents: ["s1"]),
            commit("b", parents: ["r"]),
            commit("s1", parents: ["r"]),
            commit("r"),
        ]
        let result = visible(commits, hiding: ["feature"])
        XCTAssertEqual(result.map(\.sha), ["m", "s3", "s2", "b", "s1", "r"])
        XCTAssertEqual(result.first?.parents, ["b", "s3"])
    }

    func testAVisibleBranchForkedFromAHiddenOneKeepsTheSharedPart() {
        // child forked from feature at D. D is on child's own line.
        let commits = [
            commit("m", parents: ["b"], refs: [branch("main", isHead: true)]),
            commit("c", parents: ["d"], refs: [branch("child")]),
            commit("f", parents: ["d"], refs: [branch("feature")]),
            commit("b", parents: ["r"]),
            commit("d", parents: ["r"]),
            commit("r"),
        ]
        XCTAssertEqual(visible(commits, hiding: ["feature"]).map(\.sha), ["m", "c", "b", "d", "r"])
    }

    func testAHiddenMainlineMergedIntoTheCheckedOutBranchHides() {
        // HEAD is on work, which merged main in at W. Hiding main leaves
        // work's own line: M2 and M1 came in by the merge.
        let commits = [
            commit("w", parents: ["w1", "m2"], refs: [branch("work", isHead: true)]),
            commit("m2", parents: ["m1"], refs: [branch("main")]),
            commit("w1", parents: ["r"]),
            commit("m1", parents: ["r"]),
            commit("r"),
        ]
        let result = visible(commits, head: "w", hiding: ["main"])
        XCTAssertEqual(result.map(\.sha), ["w", "w1", "r"])
        XCTAssertEqual(result.first?.parents, ["w1"])
    }

    // MARK: - One branch, wherever it lives

    func testHidingABranchHidesItsRemoteCopyToo() {
        // feature and origin/feature on the same commit: hiding one name
        // used to leave the other holding the line up.
        var commits = fixture()
        commits[1] = commit("f", parents: ["d"], refs: [branch("feature"), remote("origin/feature")])
        XCTAssertEqual(visible(commits, hiding: ["feature"]).map(\.sha), ["m", "b", "r"])
    }

    func testAnUnpushedTipAndItsRemoteCopyBehindItHideTogether() {
        var commits = fixture()
        commits[3] = commit("d", parents: ["r"], refs: [remote("origin/feature")])
        XCTAssertEqual(visible(commits, hiding: ["feature"]).map(\.sha), ["m", "b", "r"])
    }

    func testARemoteOnlyBranchHidesByItsBranchName() {
        var commits = fixture()
        commits[1] = commit("f", parents: ["d"], refs: [remote("origin/feature")])
        XCTAssertEqual(visible(commits, hiding: ["feature"]).map(\.sha), ["m", "b", "r"])
    }

    func testARemoteHeadPointerDoesNotHoldAHiddenBranchUp() {
        var commits = fixture()
        commits[1] = commit("f", parents: ["d"], refs: [remote("origin/feature"), remote("origin/HEAD")])
        XCTAssertEqual(visible(commits, hiding: ["feature"]).map(\.sha), ["m", "b", "r"])
    }

    func testARemoteHeadPointerAloneStillShows() {
        var commits = fixture()
        commits[1] = commit("f", parents: ["d"], refs: [remote("origin/HEAD")])
        let result = visible(commits, hiding: ["other"])
        XCTAssertEqual(result.map(\.sha), ["m", "f", "b", "d", "r"])
    }

    // MARK: - Labels

    func testAHiddenBranchLosesItsLabelOnACommitThatStays() {
        // feature's label sits on main's own line (fast-forward merged):
        // there is no line to remove, but the label goes.
        let commits = [
            commit("m", parents: ["b"], refs: [branch("main", isHead: true)]),
            commit("b", parents: ["r"], refs: [branch("feature"), remote("origin/feature")]),
            commit("r"),
        ]
        let result = visible(commits, hiding: ["feature"])
        XCTAssertEqual(result.map(\.sha), ["m", "b", "r"])
        XCTAssertEqual(result[1].refs, [])
    }

    func testTwoBranchesOnOneCommitHideSeparately() {
        var commits = fixture()
        commits[1] = commit("f", parents: ["d"], refs: [branch("feature"), branch("other")])
        let result = visible(commits, hiding: ["feature"])
        // other still points here, so the line stays, under other's name.
        XCTAssertEqual(result.map(\.sha), ["m", "f", "b", "d", "r"])
        XCTAssertEqual(result[1].refs, [branch("other")])
    }

    func testTheRemoteHeadPointerLeavesWithTheBranchItPointedAt() {
        let commits = [
            commit("m", parents: ["b"], refs: [branch("work", isHead: true)]),
            commit("b", parents: ["r"], refs: [remote("origin/main"), remote("origin/HEAD")]),
            commit("r"),
        ]
        XCTAssertEqual(visible(commits, hiding: ["main"])[1].refs, [])
    }

    // MARK: - What never hides

    func testTheCheckedOutBranchNeverHides() {
        let result = visible(fixture(), hiding: ["main"])
        XCTAssertEqual(result, fixture())
    }

    func testTheCheckedOutBranchKeepsItsRemoteCopy() {
        // origin/main is behind the checked-out main. Asked to hide main,
        // nothing changes: not the commits, not either label.
        var commits = fixture()
        commits[2] = commit("b", parents: ["r"], refs: [remote("origin/main")])
        XCTAssertEqual(visible(commits, hiding: ["main"]), commits)
    }

    func testAllBranchesHiddenKeepsHeadChain() {
        let result = visible(fixture(), hiding: ["main", "feature"])
        XCTAssertEqual(result.map(\.sha), ["m", "b", "r"])
    }

    func testADetachedHeadHoldsItsCommitAndWhatIsBelow() {
        // HEAD is detached at D, part-way down the hidden feature.
        let commits = [
            commit("m", parents: ["b"], refs: [branch("main")]),
            commit("f", parents: ["d"], refs: [branch("feature")]),
            commit("b", parents: ["r"]),
            commit("d", parents: ["r"], refs: [RefDecoration(name: "HEAD", type: .head, isHead: true)]),
            commit("r"),
        ]
        let result = visible(commits, head: "d", hiding: ["feature", "main"])
        XCTAssertEqual(result.map(\.sha), ["d", "r"])
    }

    func testTagKeepsCommitVisible() {
        var commits = fixture()
        // f carries BOTH the hidden branch and a tag — the tag pins it visible.
        let tag = RefDecoration(name: "v1.0", type: .tag, isHead: false)
        commits[1] = commit("f", parents: ["d"], refs: [branch("feature"), tag])
        let result = visible(commits, hiding: ["feature"])
        XCTAssertEqual(result.map(\.sha), ["m", "f", "b", "d", "r"])
        XCTAssertEqual(result[1].refs, [tag], "the tag stays, the hidden branch's label goes")
    }

    // MARK: - The window's edge

    func testAParentOutsideTheWindowIsKept() {
        // "older" is past the loaded window. Its lane still runs off the
        // bottom; only a parent hidden inside the window is cut.
        let commits = [
            commit("m", parents: ["b", "f"], refs: [branch("main", isHead: true)]),
            commit("f", parents: ["older"], refs: [branch("feature")]),
            commit("b", parents: ["older"]),
        ]
        let result = visible(commits, hiding: ["feature"])
        XCTAssertEqual(result.map(\.sha), ["m", "b"])
        XCTAssertEqual(result[0].parents, ["b"])
        XCTAssertEqual(result[1].parents, ["older"])
    }
}
