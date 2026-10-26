import XCTest
@testable import RipulAgent

/// Which addresses end a Claude sign-in in Ripul's browser, and with what.
/// The callback is Anthropic's code page; its `state` must be the sign-in's own.
final class ClaudeSignInBrowserTests: XCTestCase {
    private let authUrl = URL(string: "https://claude.ai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&response_type=code&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&scope=user%3Ainference&code_challenge=abc&code_challenge_method=S256&state=STATE123")!

    private func outcome(_ address: String) -> ClaudeSignInBrowser.Outcome? {
        ClaudeSignInBrowser.outcome(for: URL(string: address)!, authUrl: authUrl)
    }

    func testCallbackWithItsOwnStateGivesCodeHashState() {
        XCTAssertEqual(outcome("https://platform.claude.com/oauth/code/callback?code=CODE9&state=STATE123"), .code("CODE9#STATE123"))
        XCTAssertEqual(outcome("https://PLATFORM.claude.com/oauth/code/callback/?state=STATE123&code=CODE9"), .code("CODE9#STATE123"))
    }

    func testAnotherSignInsStateIsRefused() {
        guard case .refused = outcome("https://platform.claude.com/oauth/code/callback?code=CODE9&state=OTHER") else {
            return XCTFail("a mismatched state must be refused")
        }
        guard case .refused = outcome("https://platform.claude.com/oauth/code/callback?code=CODE9") else {
            return XCTFail("a missing state must be refused")
        }
    }

    func testMissingCodeIsRefusedAndDeclineIsDenied() {
        guard case .refused = outcome("https://platform.claude.com/oauth/code/callback?state=STATE123") else {
            return XCTFail("no code")
        }
        guard case .denied = outcome("https://platform.claude.com/oauth/code/callback?error=access_denied&state=STATE123") else {
            return XCTFail("declined")
        }
    }

    func testOtherPagesAreNotTheCallback() {
        XCTAssertNil(outcome("https://claude.ai/oauth/authorize?code=true&state=STATE123"))
        XCTAssertNil(outcome("https://claude.ai/login"))
        XCTAssertNil(outcome("https://accounts.google.com/o/oauth2/v2/auth?state=STATE123"))
        XCTAssertNil(outcome("http://platform.claude.com/oauth/code/callback?code=CODE9&state=STATE123"))
        XCTAssertNil(outcome("https://platform.claude.com.evil.example/oauth/code/callback?code=CODE9&state=STATE123"))
    }

    func testAnAuthorizeAddressWithoutStateNeverSendsACode() {
        let bare = URL(string: "https://claude.ai/oauth/authorize?code=true")!
        let found = ClaudeSignInBrowser.outcome(for: URL(string: "https://platform.claude.com/oauth/code/callback?code=C&state=S")!, authUrl: bare)
        guard case .refused = found else { return XCTFail("no expected state, so nothing may be sent") }
    }
}
