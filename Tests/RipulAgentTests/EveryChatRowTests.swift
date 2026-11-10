import XCTest
@testable import RipulAgent

/// What the Permissions screen shows for each thing a member holds in every chat on the owner's Mac.
/// Peter, 29 October 2026: "Across the board we need options of broader longer scopes", so devices, simulators,
/// browsers and the page viewer are held in every chat as folders were.
final class EveryChatRowTests: XCTestCase {
    func testAFolderReadsAsItsNameAndPath() {
        let row = MemberAuthorityScreen.everyChatRow("repo:full:/Users/p/Documents/WAC_ios_final", name: nil)
        XCTAssertEqual(row.title, "WAC_ios_final")
        XCTAssertEqual(row.detail, "Read and change · /Users/p/Documents/WAC_ios_final")
        XCTAssertEqual(MemberAuthorityScreen.everyChatRow("repo:read:/Users/p/notes", name: nil).detail, "Read · /Users/p/notes")
        // Held through a team, the Mac's name says so.
        XCTAssertEqual(MemberAuthorityScreen.everyChatRow("repo:full:/Users/p/Documents/WAC_ios_final", name: "WAC_ios_final (for Test team)").title,
                       "WAC_ios_final (for Test team)")
    }

    func testEverythingElseReadsAsTheMacsNameForIt() {
        XCTAssertEqual(MemberAuthorityScreen.everyChatRow("device:simulators", name: nil).title, "Any simulator on this Mac")
        XCTAssertEqual(MemberAuthorityScreen.everyChatRow("device:3f2a9c", name: "Peter Maude (iPhone)").title, "Peter Maude (iPhone)")
        XCTAssertEqual(MemberAuthorityScreen.everyChatRow("device:3f2a9c", name: nil).title, "A device")
        XCTAssertEqual(MemberAuthorityScreen.everyChatRow("pages", name: nil).title, "The page viewer")
        XCTAssertEqual(MemberAuthorityScreen.everyChatRow("browser:mac-608a", name: nil).title, "mac-608a")
    }

    func testTheMacsNamesAreRead() throws {
        let member = try JSONDecoder().decode(MemberAuthorityState.Member.self, from: Data("""
        {"userId":"u","name":"Eden Heath","level":"ask","permissions":[],"everyChat":["device:simulators"],
         "everyChatNames":{"device:simulators":"Any simulator on your Mac"}}
        """.utf8))
        XCTAssertEqual(member.everyChatNames?["device:simulators"], "Any simulator on your Mac")
    }
}
