import XCTest
@testable import RipulAgent

/// Cover for the rule that keeps a tapped link from replacing the app.
///
/// The app's host also serves pages that are not the app. A chat link to
/// `demo.ripul.io/ios` once loaded over the chat, and back led to the session
/// list with the app gone.
final class AgentLinkRoutingTests: XCTestCase {
    private let app = URL(string: "https://demo.ripul.io/popup?_cb=1#native=true&siteKey=abc")!

    private func leaves(_ link: String, from current: URL? = nil, noDocument: Bool = false) -> Bool {
        AgentLinkRouting.leavesApp(URL(string: link)!, from: noDocument ? nil : (current ?? app), baseHost: "demo.ripul.io")
    }

    func testOtherHostsLeaveTheApp() {
        XCTAssertTrue(leaves("https://example.com/"))
        XCTAssertTrue(leaves("http://ripul.io/popup"))
    }

    func testOtherPagesOnTheAppsOwnHostLeaveTheApp() {
        XCTAssertTrue(leaves("https://demo.ripul.io/ios"))
        XCTAssertTrue(leaves("https://demo.ripul.io/mac"))
        XCTAssertTrue(leaves("https://demo.ripul.io/a/token"))
        XCTAssertTrue(leaves("https://demo.ripul.io/"))
    }

    func testTheAppsOwnDocumentStays() {
        XCTAssertFalse(leaves("https://demo.ripul.io/popup#/settings"))
        XCTAssertFalse(leaves("https://demo.ripul.io/popup?mode=x"))
        XCTAssertFalse(leaves("https://demo.ripul.io/popup/"))
    }

    func testOtherSchemesAreNotBrowserLinks() {
        XCTAssertFalse(leaves("ripul://settings"))
        XCTAssertFalse(leaves("about:blank"))
        XCTAssertFalse(leaves("mailto:hello@example.com"))
    }

    /// A link inside a frame replaces that frame, not the app.
    func testFrameLinksOnTheAppsHostStay() {
        XCTAssertFalse(leaves("https://demo.ripul.io/a/token", noDocument: true))
        XCTAssertTrue(leaves("https://example.com/", noDocument: true))
    }

    /// Sign-in passes through other hosts; the link back is a return.
    func testReturningFromAnotherHostStays() {
        let signIn = URL(string: "https://accounts.google.com/o/oauth2/auth")!
        XCTAssertFalse(leaves("https://demo.ripul.io/sso-callback", from: signIn))
    }

    func testWithoutABaseHostNothingLeaves() {
        XCTAssertFalse(AgentLinkRouting.leavesApp(URL(string: "https://example.com/")!, from: app, baseHost: nil))
    }
}
