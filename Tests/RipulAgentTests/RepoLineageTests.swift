import XCTest
@testable import RipulAgent

/// Branch lineage read from first-parent lines. Every fixture lists commits
/// the way the host does (`git rev-list --topo-order`): no parent before any
/// of its children. A commit's FIRST parent is the line it was made on.
final class RepoLineageTests: XCTestCase {

    private func commit(_ sha: String, _ parents: String...) -> RepoLineageBuilder.Commit {
        RepoLineageBuilder.Commit(sha: sha, parents: parents)
    }

    private func local(_ name: String, _ sha: String) -> RepoLineageBuilder.Ref {
        RepoLineageBuilder.Ref(name: name, isRemote: false, sha: sha)
    }

    private func remote(_ name: String, _ sha: String) -> RepoLineageBuilder.Ref {
        RepoLineageBuilder.Ref(name: name, isRemote: true, sha: sha)
    }

    private func lineage(
        _ commits: [RepoLineageBuilder.Commit], _ refs: [RepoLineageBuilder.Ref],
        trunk: String? = "main", current: String? = nil
    ) -> [String: LineageBranch] {
        let built = RepoLineageBuilder.build(
            repoPath: "/repo", refs: refs, commits: commits, defaultBranch: trunk, currentBranch: current)
        return Dictionary(uniqueKeysWithValues: built.branches.map { ($0.name, $0) })
    }

    // MARK: - What a branch was cut from

    func testABranchCutFromTheTrunkCountsBothWays() {
        // main: R ← M1 ← M2.  feature: M1 ← F1 ← F2.
        let branches = lineage([
            commit("f2", "f1"), commit("f1", "m1"),
            commit("m2", "m1"), commit("m1", "r"), commit("r"),
        ], [local("main", "m2"), local("feature", "f2")])

        let feature = branches["feature"]!
        XCTAssertEqual(feature.base, "main")
        XCTAssertEqual(feature.state, .active)
        XCTAssertEqual(feature.ahead, 2)
        XCTAssertEqual(feature.behind, 1)
        XCTAssertEqual(feature.forkSha, "m1")
        XCTAssertFalse(feature.baseIsGuess)
        XCTAssertNil(branches["main"]!.base)
        XCTAssertTrue(branches["main"]!.isTrunk)
    }

    func testNewWorkOnABranchThatHasNotMovedStandsOnThatBranch() {
        // develop left main at M1 and stopped at D2; feature is plain
        // commits on top of D2. develop's tip is on feature's line, and
        // develop is what feature was cut from.
        let branches = lineage([
            commit("f2", "f1"), commit("f1", "d2"),
            commit("d2", "d1"), commit("d1", "m1"),
            commit("m2", "m1"), commit("m1", "r"), commit("r"),
        ], [local("main", "m2"), local("develop", "d2"), local("feature", "f2")])

        XCTAssertEqual(branches["feature"]!.base, "develop")
        XCTAssertEqual(branches["feature"]!.ahead, 2)
        XCTAssertEqual(branches["feature"]!.behind, 0)
        XCTAssertFalse(branches["feature"]!.baseIsGuess)
        XCTAssertEqual(branches["develop"]!.base, "main")
        XCTAssertEqual(branches["develop"]!.state, .active)
        XCTAssertEqual(branches["develop"]!.ahead, 2)
    }

    func testAStackReadsBottomToTop() {
        let branches = lineage([
            commit("c1", "b1"), commit("b1", "a1"), commit("a1", "m1"), commit("m1"),
        ], [local("main", "m1"), local("a", "a1"), local("b", "b1"), local("c", "c1")])

        XCTAssertEqual(branches["a"]!.base, "main")
        XCTAssertEqual(branches["b"]!.base, "a")
        XCTAssertEqual(branches["c"]!.base, "b")
    }

    // MARK: - Labels a line left behind

    func testALabelOnTheTrunksLineIsAPlaceOnIt() {
        let branches = lineage([
            commit("m3", "m2"), commit("m2", "m1"), commit("m1"),
        ], [local("main", "m3"), local("old", "m1")])

        let old = branches["old"]!
        XCTAssertEqual(old.state, .onLine)
        XCTAssertEqual(old.base, "main")
        XCTAssertEqual(old.ahead, 0)
        XCTAssertEqual(old.behind, 2)
    }

    func testALabelUnderALineThatForksIsAPlaceOnThatLine() {
        // live runs L1…L4 with topic cut from L3. backup was left at L2.
        // The line above backup forks, so it is a line in its own right and
        // backup is where it once stood, not what it was cut from.
        let branches = lineage([
            commit("l4", "l3"), commit("t1", "l3"), commit("l3", "l2"),
            commit("l2", "l1"), commit("l1", "m1"), commit("m1"),
        ], [local("main", "m1"), local("live", "l4"), local("backup", "l2"), local("topic", "t1")])

        XCTAssertEqual(branches["live"]!.base, "main")
        XCTAssertEqual(branches["live"]!.ahead, 4)
        XCTAssertEqual(branches["backup"]!.state, .onLine)
        XCTAssertEqual(branches["backup"]!.base, "live")
        XCTAssertEqual(branches["backup"]!.behind, 2)
        XCTAssertEqual(branches["topic"]!.base, "live")
    }

    func testALabelNamedAfterTheBranchAboveItIsAPlaceOnItsLine() {
        // v-1-fix was fast-forwarded into v-1, which then moved on. Without
        // the name it would read as what v-1 was cut from.
        let branches = lineage([
            commit("v2", "v1"), commit("v1", "m1"), commit("m1"),
        ], [local("main", "m1"), local("v-1", "v2"), local("v-1-fix", "v1")])

        XCTAssertEqual(branches["v-1"]!.base, "main")
        XCTAssertEqual(branches["v-1-fix"]!.state, .onLine)
        XCTAssertEqual(branches["v-1-fix"]!.base, "v-1")
    }

    func testTwoNamesOnOneCommit() {
        let branches = lineage([
            commit("f1", "m1"), commit("m1"),
        ], [local("main", "m1"), local("feature", "f1"), remote("origin/copy", "f1")])

        XCTAssertEqual(branches["feature"]!.base, "main")
        XCTAssertEqual(branches["feature"]!.state, .active)
        XCTAssertEqual(branches["copy"]!.state, .onLine)
        XCTAssertEqual(branches["copy"]!.base, "feature")
        XCTAssertEqual(branches["copy"]!.behind, 0)
    }

    // MARK: - Where lines part with no label

    func testABranchOthersAreNamedAfterCarriesTheLineOn() {
        // v-1 and v-1-fix part at X, which no branch points at.
        let branches = lineage([
            commit("f1", "x"), commit("v1", "x"), commit("x", "m1"), commit("m1"),
        ], [local("main", "m1"), local("v-1", "v1"), local("v-1-fix", "f1")])

        XCTAssertEqual(branches["v-1"]!.base, "main")
        XCTAssertEqual(branches["v-1-fix"]!.base, "v-1")
        XCTAssertFalse(branches["v-1-fix"]!.baseIsGuess)
    }

    func testTheSideMoreBranchesHangOffCarriesTheLineOn() {
        // Above X: release with two more branches cut from it, and lone.
        let branches = lineage([
            commit("a1", "r2"), commit("b1", "r1"), commit("r2", "r1"), commit("r1", "x"),
            commit("l1", "x"), commit("x", "m1"), commit("m1"),
        ], [local("main", "m1"), local("release", "r2"), local("a", "a1"), local("b", "b1"), local("lone", "l1")])

        XCTAssertEqual(branches["lone"]!.base, "release")
        XCTAssertFalse(branches["lone"]!.baseIsGuess)
        XCTAssertEqual(branches["release"]!.base, "main")
        XCTAssertEqual(branches["b"]!.base, "release")
        XCTAssertEqual(branches["a"]!.base, "release")
    }

    func testTwoPlainBranchesPartingIsAGuess() {
        // Nothing says whether one was cut from two or two from one.
        let branches = lineage([
            commit("a1", "x"), commit("b1", "x"), commit("x", "m1"), commit("m1"),
        ], [local("main", "m1"), local("one", "a1"), local("two", "b1")])

        let based = [branches["one"]!, branches["two"]!].filter { $0.base != "main" }
        XCTAssertEqual(based.count, 1)
        XCTAssertTrue(based[0].baseIsGuess)
    }

    func testKeepingUpWithABaseDoesNotMakeABranchTheBase() {
        // topic took develop in at T2. A merge on its line must not make it
        // look like the line others are built on: develop taking topic in
        // would look the same from the other side.
        let branches = lineage([
            commit("t2", "t1", "d2"), commit("d2", "x"), commit("t1", "x"),
            commit("x", "m1"), commit("m1"),
        ], [local("main", "m1"), local("develop", "d2"), local("topic", "t2")])

        let based = [branches["develop"]!, branches["topic"]!].filter { $0.base != "main" }
        XCTAssertEqual(based.count, 1)
        XCTAssertTrue(based[0].baseIsGuess, "a merge between the two sides is no evidence either way")
    }

    // MARK: - Merged

    func testABranchMergedByAMergeCommit() {
        let branches = lineage([
            commit("m2", "m1", "f1"), commit("f1", "m1"), commit("m1"),
        ], [local("main", "m2"), local("feature", "f1")])

        let feature = branches["feature"]!
        XCTAssertEqual(feature.state, .merged)
        XCTAssertEqual(feature.mergedInto, "main")
        XCTAssertEqual(feature.ahead, 0)
        XCTAssertEqual(feature.behind, 0)
    }

    func testWhatWasCutFromAMergedBranchStandsOnWhatTookItIn() {
        // child was cut from feature; feature has since gone into main.
        let branches = lineage([
            commit("c1", "f1"), commit("m2", "m1", "f1"), commit("f1", "m1"), commit("m1"),
        ], [local("main", "m2"), local("feature", "f1"), local("child", "c1")])

        XCTAssertEqual(branches["feature"]!.state, .merged)
        let child = branches["child"]!
        XCTAssertEqual(child.base, "main")
        XCTAssertEqual(child.state, .active)
        XCTAssertEqual(child.ahead, 1)
        XCTAssertEqual(child.behind, 1)
    }

    func testABranchMergedSomewhereOtherThanWhereItCameFrom() {
        // feature was cut from main and merged into release, which main
        // has not taken.
        let branches = lineage([
            commit("r2", "r1", "f1"), commit("f1", "m1"), commit("r1", "m1"),
            commit("m2", "m1"), commit("m1"),
        ], [local("main", "m2"), local("release", "r2"), local("feature", "f1")])

        XCTAssertEqual(branches["feature"]!.state, .merged)
        XCTAssertEqual(branches["feature"]!.mergedInto, "release")
        XCTAssertEqual(branches["release"]!.state, .active)
    }

    func testABaseItsBranchKeptUpWithIsNotMerged() {
        // feature took develop in. develop is held by feature, but feature
        // was cut from develop: that is keeping up, not develop merged away.
        let branches = lineage([
            commit("f2", "f1", "d3"), commit("d3", "d2"), commit("f1", "d2"),
            commit("d2", "d1"), commit("d1", "m1"), commit("m2", "m1"), commit("m1"),
        ], [local("main", "m2"), local("develop", "d3"), local("develop-feature", "f2")])

        XCTAssertEqual(branches["develop"]!.state, .active)
        XCTAssertEqual(branches["develop-feature"]!.base, "develop")
        XCTAssertEqual(branches["develop-feature"]!.behind, 0)
    }

    func testALabelLeftOnAMergedLineIsMergedToo() {
        // line ran L1…L3 with topic cut from L2, and went into main at M2.
        // snapshot was left at L1.
        let branches = lineage([
            commit("m2", "m1", "l3"), commit("t1", "l2"), commit("l3", "l2"),
            commit("l2", "l1"), commit("l1", "m1"), commit("m1"),
        ], [local("main", "m2"), local("line", "l3"), local("snapshot", "l1"), local("topic", "t1")])

        XCTAssertEqual(branches["line"]!.state, .merged)
        XCTAssertEqual(branches["snapshot"]!.state, .merged)
        XCTAssertEqual(branches["snapshot"]!.mergedInto, "main")
        XCTAssertEqual(branches["topic"]!.base, "main")
    }

    func testTheTrunkIsNeverMerged() {
        // side took main in. main is still the trunk.
        let branches = lineage([
            commit("s2", "s1", "m2"), commit("s1", "m1"), commit("m2", "m1"), commit("m1"),
        ], [local("main", "m2"), local("side", "s2")])

        XCTAssertEqual(branches["main"]!.state, .active)
        XCTAssertEqual(branches["side"]!.behind, 0)
        XCTAssertEqual(branches["side"]!.ahead, 2)
    }

    // MARK: - One branch, wherever it lives

    func testUnpushedCommitsAndTheLocalTip() {
        let branches = lineage([
            commit("f3", "f2"), commit("f2", "f1"), commit("f1", "m1"), commit("m1"),
        ], [local("main", "m1"), local("feature", "f3"), remote("origin/feature", "f1")])

        let feature = branches["feature"]!
        XCTAssertTrue(feature.hasLocal && feature.hasRemote)
        XCTAssertEqual(feature.sha, "f3")
        XCTAssertEqual(feature.unpushed, 2)
        XCTAssertEqual(feature.unpulled, 0)
        XCTAssertEqual(feature.ahead, 3)
    }

    func testALocalBranchBehindItsRemoteIsReadAtTheRemotesTip() {
        let branches = lineage([
            commit("f3", "f2"), commit("f2", "f1"), commit("f1", "m1"), commit("m1"),
        ], [local("main", "m1"), local("feature", "f1"), remote("origin/feature", "f3")])

        let feature = branches["feature"]!
        XCTAssertEqual(feature.sha, "f3")
        XCTAssertEqual(feature.unpulled, 2)
        XCTAssertEqual(feature.unpushed, 0)
        XCTAssertEqual(feature.ahead, 3)
    }

    func testARemoteHeadPointerIsNoBranch() {
        let branches = lineage([commit("m1")], [remote("origin/main", "m1"), remote("origin/HEAD", "m1")])
        XCTAssertEqual(Array(branches.keys), ["main"])
    }

    // MARK: - Roots, and input the host may hand over

    func testAnUnrelatedLineIsARootOfItsOwn() {
        let branches = lineage([
            commit("p2", "p1"), commit("p1"), commit("m1"),
        ], [local("main", "m1"), local("pages", "p2")])

        XCTAssertNil(branches["pages"]!.base)
        XCTAssertEqual(branches["pages"]!.state, .active)
        XCTAssertEqual(branches["pages"]!.ahead, 0)
    }

    func testTheTrunkFallsBackWhenTheRemoteNamesNone() {
        let built = RepoLineageBuilder.build(
            repoPath: "/repo", refs: [local("master", "m1"), local("x", "x1")],
            commits: [commit("x1", "m1"), commit("m1")], defaultBranch: nil, currentBranch: "x")
        XCTAssertEqual(built.trunk, "master")
        XCTAssertEqual(built.branches.first?.name, "master")
    }

    func testARefWhoseCommitWasNotReadIsLeftOut() {
        let branches = lineage([commit("m1")], [local("main", "m1"), local("ghost", "zzz")])
        XCTAssertEqual(Array(branches.keys), ["main"])
    }

    func testTheCurrentBranchIsMarked() {
        let branches = lineage([
            commit("f1", "m1"), commit("m1"),
        ], [local("main", "m1"), local("feature", "f1")], current: "feature")
        XCTAssertTrue(branches["feature"]!.isCurrent)
        XCTAssertFalse(branches["main"]!.isCurrent)
    }
}
