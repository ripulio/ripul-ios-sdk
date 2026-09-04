import XCTest
@testable import RipulAgent

/// Branch-visibility filtering: hiding a branch drops commits reachable only
/// through its tip; shared history and HEAD always survive.
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

    /// An UNMERGED feature branch — a merged branch has no unique commits
    /// (everything on it is reachable via the merge), so only an unmerged
    /// branch can actually disappear.
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

    func testNoHiddenRefsIsIdentity() {
        let commits = fixture()
        let result = RepoGraphFilter.visibleCommits(commits: commits, headSha: "m", hiddenRefs: [])
        XCTAssertEqual(result.map(\.sha), commits.map(\.sha))
    }

    func testHidingFeatureDropsItsWholeUnmergedLane() {
        let result = RepoGraphFilter.visibleCommits(commits: fixture(), headSha: "m", hiddenRefs: ["feature"])
        // F and D are reachable only through the feature tip → gone; main's
        // line and the shared root stay. Input order preserved.
        XCTAssertEqual(result.map(\.sha), ["m", "b", "r"])
    }

    func testHeadAnchorSurvivesHidingItsOwnBranch() {
        let result = RepoGraphFilter.visibleCommits(commits: fixture(), headSha: "m", hiddenRefs: ["main"])
        // HEAD seeds the walk even though main is hidden → main's chain
        // stays; the still-visible feature branch keeps its lane too.
        XCTAssertEqual(result.map(\.sha).sorted(), ["b", "d", "f", "m", "r"])
    }

    func testAllBranchesHiddenKeepsHeadChain() {
        let result = RepoGraphFilter.visibleCommits(
            commits: fixture(), headSha: "m", hiddenRefs: ["main", "feature"])
        XCTAssertFalse(result.isEmpty)
        XCTAssertEqual(result.first?.sha, "m")
    }

    func testTagKeepsCommitVisible() {
        var commits = fixture()
        // f carries BOTH the hidden branch and a tag — the tag pins it visible.
        commits[1] = commit("f", parents: ["d"], refs: [
            branch("feature"),
            RefDecoration(name: "v1.0", type: .tag, isHead: false),
        ])
        let result = RepoGraphFilter.visibleCommits(commits: commits, headSha: "m", hiddenRefs: ["feature"])
        XCTAssertTrue(result.contains { $0.sha == "f" }, "tagged commit stays despite hidden branch")
        XCTAssertTrue(result.contains { $0.sha == "d" }, "tagged tip's chain stays")
    }
}
