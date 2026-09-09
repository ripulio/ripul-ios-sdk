import XCTest
@testable import RipulAgent

/// Cover for the split that every directory dropdown in the app renders from.
///
/// The parse is the whole feature: get it wrong and a picker row either loses
/// the repo name (the thing being chosen) or shows a mangled path above it.
final class DirectoryPathDisplayTests: XCTestCase {

    func testSplitsRepoFromItsParentPath() {
        let display = DirectoryPathDisplay.parse("/Users/petermaude/Documents/repos/ripul")
        XCTAssertEqual(display.name, "ripul")
        XCTAssertEqual(display.prefix, "~/Documents/repos")
    }

    /// Home is matched by shape, not against `NSHomeDirectory()` — these paths
    /// describe the remote host, and on iOS the local home is an app sandbox
    /// that would never match.
    func testAbbreviatesAnyUsersOrHomeDirectoryRegardlessOfLocalUser() {
        XCTAssertEqual(DirectoryPathDisplay.parse("/Users/someone-else/src/app").prefix, "~/src")
        XCTAssertEqual(DirectoryPathDisplay.parse("/home/deploy/srv/api").prefix, "~/srv")
    }

    func testHomeDirectoryItselfHasNoPrefix() {
        let display = DirectoryPathDisplay.parse("/Users/petermaude")
        XCTAssertEqual(display.name, "~")
        XCTAssertNil(display.prefix)
    }

    func testKeepsLeadingSlashOnNonHomeAbsolutePaths() {
        let display = DirectoryPathDisplay.parse("/opt/services/worker")
        XCTAssertEqual(display.name, "worker")
        XCTAssertEqual(display.prefix, "/opt/services")
    }

    /// A tilde already stands in for the root; re-adding a slash would render
    /// the prefix as `/~/…`.
    func testDoesNotReintroduceASlashBeforeAnExistingTilde() {
        XCTAssertEqual(DirectoryPathDisplay.parse("~/Documents/repos/ripul").prefix, "~/Documents/repos")
    }

    func testTrailingSlashesDoNotSwallowTheName() {
        let display = DirectoryPathDisplay.parse("/Users/petermaude/repos/ripul//")
        XCTAssertEqual(display.name, "ripul")
        XCTAssertEqual(display.prefix, "~/repos")
    }

    func testDegenerateInputs() {
        XCTAssertEqual(DirectoryPathDisplay.parse("/"), DirectoryPathDisplay(name: "/", prefix: nil))
        XCTAssertEqual(DirectoryPathDisplay.parse("   "), DirectoryPathDisplay(name: "", prefix: nil))
        XCTAssertEqual(DirectoryPathDisplay.parse("ripul"), DirectoryPathDisplay(name: "ripul", prefix: nil))
        XCTAssertEqual(DirectoryPathDisplay.parse("/Users"), DirectoryPathDisplay(name: "Users", prefix: "/"))
    }

    /// `joined` is what VoiceOver reads, so it has to describe the same place
    /// the two visual lines do.
    func testJoinedRebuildsTheDisplayedPath() {
        XCTAssertEqual(DirectoryPathDisplay.parse("/Users/petermaude/repos/ripul").joined, "~/repos/ripul")
        XCTAssertEqual(DirectoryPathDisplay.parse("/opt/worker").joined, "/opt/worker")
        XCTAssertEqual(DirectoryPathDisplay.parse("/").joined, "/")
    }
}
