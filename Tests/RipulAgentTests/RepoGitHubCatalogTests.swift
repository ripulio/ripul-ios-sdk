import XCTest
@testable import RipulAgent

/// Matching the host's local repos against its GitHub list: which GitHub
/// repos the Repos screen offers to clone, and what a search keeps.
final class RepoGitHubCatalogTests: XCTestCase {

    func testParsesGitHubRemoteForms() {
        let forms = [
            "https://github.com/ripulio/ripul.git",
            "https://github.com/ripulio/ripul",
            "https://github.com/ripulio/ripul/",
            "https://peter@github.com/ripulio/ripul.git",
            "git@github.com:ripulio/ripul.git",
            "git@github.com:ripulio/ripul",
            "ssh://git@github.com/ripulio/ripul.git",
            "ssh://git@github.com:22/ripulio/ripul.git",
            "  https://GitHub.com/RipulIO/Ripul.git\n",
        ]
        for form in forms {
            XCTAssertEqual(RepoGitHubCatalog.githubFullName(fromRemoteURL: form), "ripulio/ripul", form)
        }
    }

    func testRejectsOtherHostsAndPaths() {
        XCTAssertNil(RepoGitHubCatalog.githubFullName(fromRemoteURL: "https://gitlab.com/ripulio/ripul.git"))
        XCTAssertNil(RepoGitHubCatalog.githubFullName(fromRemoteURL: "git@bitbucket.org:ripulio/ripul.git"))
        XCTAssertNil(RepoGitHubCatalog.githubFullName(fromRemoteURL: "/Users/me/repos/ripul"))
        XCTAssertNil(RepoGitHubCatalog.githubFullName(fromRemoteURL: "https://github.com/ripulio"))
        XCTAssertNil(RepoGitHubCatalog.githubFullName(fromRemoteURL: "https://github.com/a/b/c"))
        XCTAssertNil(RepoGitHubCatalog.githubFullName(fromRemoteURL: ""))
    }

    private let github = [
        GitHubRepo(fullName: "ripulio/ripul", name: "ripul", owner: "ripulio", description: "Monorepo"),
        GitHubRepo(fullName: "georgina-wac/WAC_ios_final", name: "WAC_ios_final", owner: "georgina-wac"),
        GitHubRepo(fullName: "ripulio/web-mcp", name: "web-mcp", owner: "ripulio", description: "Browser MCP server"),
        GitHubRepo(fullName: "ripulio/old-thing", name: "old-thing", owner: "ripulio", isArchived: true),
    ]

    private let local = [
        RepoSummary(path: "/r/ripul", name: "ripul", currentBranch: "main", originUrl: "https://github.com/ripulio/ripul.git"),
        // A differently named clone still counts as cloned.
        RepoSummary(path: "/r/WAC_ios_final-v262-payday", name: "WAC_ios_final-v262-payday",
                    originUrl: "https://github.com/georgina-wac/WAC_ios_final.git"),
        RepoSummary(path: "/r/scratch", name: "scratch"),
    ]

    func testUnclonedDropsReposWithAnyLocalClone() {
        let names = RepoGitHubCatalog.uncloned(github, local: local).map(\.fullName)
        XCTAssertEqual(names, ["ripulio/web-mcp"])
    }

    func testArchivedReposOnlyAppearWhenSearched() {
        XCTAssertFalse(RepoGitHubCatalog.uncloned(github, local: local).contains { $0.name == "old-thing" })
        XCTAssertEqual(RepoGitHubCatalog.uncloned(github, local: local, query: "old").map(\.name), ["old-thing"])
    }

    func testSearchMatchesDescriptionAndAllTokens() {
        XCTAssertEqual(RepoGitHubCatalog.uncloned(github, local: local, query: "browser").map(\.name), ["web-mcp"])
        XCTAssertEqual(RepoGitHubCatalog.uncloned(github, local: local, query: "ripulio mcp").map(\.name), ["web-mcp"])
        XCTAssertTrue(RepoGitHubCatalog.uncloned(github, local: local, query: "ripulio nothing").isEmpty)
    }

    func testFilterLocalMatchesGitHubName() {
        XCTAssertEqual(RepoGitHubCatalog.filterLocal(local, query: "georgina").map(\.name), ["WAC_ios_final-v262-payday"])
        XCTAssertEqual(RepoGitHubCatalog.filterLocal(local, query: "").count, 3)
    }

    func testCloneSourceDetection() {
        for yes in ["ripulio/web-mcp", "https://gitlab.com/a/b.git", "git@github.com:a/b.git", "ssh://git@host/a/b"] {
            XCTAssertTrue(RepoGitHubCatalog.isCloneSource(yes), yes)
        }
        for no in ["web-mcp", "ripulio mcp", "-o/x", "", "a/b/c"] {
            XCTAssertFalse(RepoGitHubCatalog.isCloneSource(no), no)
        }
    }

    func testDefaultFolderName() {
        XCTAssertEqual(RepoGitHubCatalog.defaultFolderName(forSource: "ripulio/web-mcp"), "web-mcp")
        XCTAssertEqual(RepoGitHubCatalog.defaultFolderName(forSource: "https://github.com/a/b.git"), "b")
        XCTAssertEqual(RepoGitHubCatalog.defaultFolderName(forSource: "git@github.com:a/b.git"), "b")
        XCTAssertEqual(RepoGitHubCatalog.defaultFolderName(forSource: "https://github.com/a/b/"), "b")
    }
}
