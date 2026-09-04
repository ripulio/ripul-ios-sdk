import XCTest
@testable import RipulAgent

/// Canonical ref grouping: a local branch and its remote twin collapse into
/// one labelled group whose icons say where the branch lives.
final class RepoRefGrouperTests: XCTestCase {

    private func ref(_ name: String, _ type: RepoRefType, isHead: Bool = false) -> RefDecoration {
        RefDecoration(name: name, type: type, isHead: isHead)
    }

    func testLocalAndRemoteTwinCollapseToOneGroup() {
        let groups = RepoRefGrouper.group([
            ref("main", .branch, isHead: true),
            ref("origin/main", .remote),
        ])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].name, "main")
        XCTAssertTrue(groups[0].hasLocal)
        XCTAssertTrue(groups[0].hasRemote)
        XCTAssertTrue(groups[0].isCurrentHead)
        XCTAssertEqual(groups[0].symbols, ["laptopcomputer", "cloud"])
        XCTAssertEqual(groups[0].label, "HEAD → main")
    }

    func testRemoteOnlyBranchGetsShortNameAndCloud() {
        let groups = RepoRefGrouper.group([ref("origin/feature/x", .remote)])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].name, "feature/x")
        XCTAssertFalse(groups[0].hasLocal)
        XCTAssertTrue(groups[0].hasRemote)
        XCTAssertEqual(groups[0].symbols, ["cloud"])
        XCTAssertEqual(groups[0].label, "feature/x")
    }

    func testTwoRemotesSameShortNameMerge() {
        let groups = RepoRefGrouper.group([
            ref("origin/main", .remote),
            ref("upstream/main", .remote),
        ])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].name, "main")
        XCTAssertTrue(groups[0].hasRemote)
    }

    func testTagAndBranchWithSameNameStaySeparate() {
        let groups = RepoRefGrouper.group([
            ref("v1.0", .branch),
            ref("v1.0", .tag),
        ])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].symbols, ["laptopcomputer"])
        XCTAssertEqual(groups[1].symbols, ["tag"])
        XCTAssertTrue(groups[1].isTag)
    }

    func testDetachedHeadIsItsOwnGroup() {
        let groups = RepoRefGrouper.group([ref("HEAD", .head, isHead: true)])
        XCTAssertEqual(groups.count, 1)
        XCTAssertTrue(groups[0].hasDetachedHead)
        XCTAssertEqual(groups[0].symbols, ["flag"])
    }

    func testOrderIsFirstAppearance() {
        let groups = RepoRefGrouper.group([
            ref("main", .branch, isHead: true),
            ref("v2.0", .tag),
            ref("origin/main", .remote),
            ref("develop", .branch),
        ])
        XCTAssertEqual(groups.map(\.name), ["main", "v2.0", "develop"])
        // origin/main merged into the main group, not a fourth entry.
        XCTAssertEqual(groups.count, 3)
        XCTAssertTrue(groups[0].hasRemote)
    }

    func testEmptyInput() {
        XCTAssertTrue(RepoRefGrouper.group([]).isEmpty)
    }
}
