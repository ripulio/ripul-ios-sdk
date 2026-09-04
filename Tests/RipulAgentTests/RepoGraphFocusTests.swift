import XCTest
@testable import RipulAgent

/// First-parent heritage: the branch's own line, merge-ins as one-row stubs.
final class RepoGraphFocusTests: XCTestCase {

    private func commit(
        _ sha: String,
        parents: [String] = [],
        refs: [RefDecoration] = []
    ) -> GraphCommit {
        GraphCommit(sha: sha, parents: parents, authorName: "T", timestamp: 0, subject: sha, refs: refs)
    }

    ///   T (tip)     parent: M
    ///   M           parents: A, F    ← merge of feature into the branch
    ///   A           parent: R
    ///   F (feature) parent: R        ← unmerged-elsewhere feature tip
    ///   R           (root)
    private func fixture() -> [GraphCommit] {
        [
            commit("t", parents: ["m"], refs: [RefDecoration(name: "main", type: .branch, isHead: true)]),
            commit("m", parents: ["a", "f"]),
            commit("a", parents: ["r"]),
            commit("f", parents: ["r"], refs: [RefDecoration(name: "feature", type: .branch, isHead: false)]),
            commit("r"),
        ]
    }

    func testChainPlusStubBelowMerge() {
        let heritage = RepoGraphFocus.firstParentHeritage(commits: fixture(), tipSha: "t")
        XCTAssertEqual(heritage.map(\.sha), ["t", "m", "f", "a", "r"])
    }

    func testStubHasParentsStrippedAndKeepsRefs() {
        let heritage = RepoGraphFocus.firstParentHeritage(commits: fixture(), tipSha: "t")
        let stub = heritage.first { $0.sha == "f" }!
        XCTAssertTrue(stub.parents.isEmpty, "stub lane must terminate")
        XCTAssertEqual(stub.refs.first?.name, "feature", "stub keeps its branch pill")
    }

    func testLayoutInvariantHolds() {
        // Every commit appears after any child that references it.
        let heritage = RepoGraphFocus.firstParentHeritage(commits: fixture(), tipSha: "t")
        var seen: Set<String> = []
        for commit in heritage {
            for parent in commit.parents {
                XCTAssertFalse(seen.contains(parent), "parent \(parent) must not precede its child \(commit.sha)")
            }
            seen.insert(commit.sha)
        }
    }

    func testSideParentOnChainGetsNoStub() {
        // Merge whose second parent is further down the first-parent line.
        let commits = [
            commit("t", parents: ["m"]),
            commit("m", parents: ["a", "r"]),   // merges the root itself
            commit("a", parents: ["r"]),
            commit("r"),
        ]
        let heritage = RepoGraphFocus.firstParentHeritage(commits: commits, tipSha: "t")
        XCTAssertEqual(heritage.map(\.sha), ["t", "m", "a", "r"], "no duplicate row for the on-chain parent")
    }

    func testSideParentOutsideWindowGetsNoStub() {
        let commits = [
            commit("t", parents: ["m"]),
            commit("m", parents: ["a", "zzz"]),   // zzz not loaded
            commit("a"),
        ]
        let heritage = RepoGraphFocus.firstParentHeritage(commits: commits, tipSha: "t")
        XCTAssertEqual(heritage.map(\.sha), ["t", "m", "a"])
    }

    func testUnknownTipYieldsEmpty() {
        XCTAssertTrue(RepoGraphFocus.firstParentHeritage(commits: fixture(), tipSha: "nope").isEmpty)
    }

    func testLinearBranchIsIdentity() {
        let commits = [
            commit("a", parents: ["b"]),
            commit("b", parents: ["c"]),
            commit("c"),
        ]
        let heritage = RepoGraphFocus.firstParentHeritage(commits: commits, tipSha: "a")
        XCTAssertEqual(heritage.map(\.sha), ["a", "b", "c"])
    }
}
