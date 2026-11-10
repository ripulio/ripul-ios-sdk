import XCTest
@testable import RipulAgent

/// The New Chat sheet's check that a Claude chat on the chosen Mac could reply
/// (NewChatClaudeCheck): on 9 November 2026 Peter's first chat on the Mac mini,
/// onboarded afresh, answered "Not logged in", with nothing said beforehand.
final class NewChatClaudeCheckTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_794_225_600) // 9 November 2026, 12:00 UTC

    private func account(_ slug: String, email: String? = nil, loggedIn: Bool = true, ended: Bool = false, windows: [CodingAccountUsage.Window] = []) -> ClaudeAccountProfile {
        var profile = ClaudeAccountProfile(slug: slug, name: slug == "default" ? "Default" : slug, email: email, loggedIn: loggedIn, isDefault: slug == "default")
        profile.signInEnded = ended
        profile.usage = CodingAccountUsage(plan: nil, windows: windows, updatedAt: nil, error: nil)
        return profile
    }

    private func list(_ accounts: [ClaudeAccountProfile], active: String, error: String? = nil) -> ClaudeAccountsListInfo {
        ClaudeAccountsListInfo(accounts: accounts, active: active, error: error)
    }

    func testAMacWhoseAccountNeverSignedInBlocksAClaudeChat() throws {
        let check = try XCTUnwrap(NewChatClaudeCheck.from(list([account("default", loggedIn: false), account("peter", email: "peter@example.com")], active: "default"), now: now))
        XCTAssertEqual(check.verdict, .notSignedIn)
        XCTAssertTrue(check.blocksStart)
        XCTAssertEqual(check.message(mac: "Mac mini"), "Claude isn’t signed in on Mac mini, so a Claude chat there can’t reply. Sign it in first, or choose another Mac.")
        XCTAssertEqual(check.signInLink(machineID: "machine-1")?.absoluteString, "ripul://claude-account?machine=machine-1&profile=default&action=sign-in")
    }

    func testAnEndedSignInBlocksAndNamesTheAccount() throws {
        let check = try XCTUnwrap(NewChatClaudeCheck.from(list([account("wac", email: "peter@wac.example", ended: true)], active: "wac"), now: now))
        XCTAssertEqual(check.verdict, .ended)
        XCTAssertTrue(check.blocksStart)
        XCTAssertTrue(check.message(mac: "Studio")?.contains("The Claude sign-in for peter@wac.example on Studio has ended") == true)
    }

    func testAUsedUpLimitWarnsWithoutBlocking() throws {
        let resets = now.addingTimeInterval(34 * 3600)
        let check = try XCTUnwrap(NewChatClaudeCheck.from(list([account("peter", email: "peter@example.com", windows: [
            .init(id: "seven_day", label: "Weekly limit", usedPercent: 100, resetsAt: resets.timeIntervalSince1970),
            .init(id: "model:Fable", label: "Fable", usedPercent: 100, resetsAt: now.addingTimeInterval(99 * 3600).timeIntervalSince1970),
        ])], active: "peter"), now: now))
        XCTAssertEqual(check.verdict, .limited(until: resets), "the account's own limit, not a model's")
        XCTAssertFalse(check.blocksStart, "a chat waits for the limit; it is said, not refused")
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertTrue(check.message(mac: "Mac mini", calendar: utc)?.contains("has used its limit until Tue") == true, check.message(mac: "Mac mini", calendar: utc) ?? "nil")
    }

    func testASignedInAccountUnderItsLimitsSaysNothing() throws {
        let check = try XCTUnwrap(NewChatClaudeCheck.from(list([account("peter", windows: [.init(id: "seven_day", label: "Weekly", usedPercent: 75, resetsAt: nil)])], active: "peter"), now: now))
        XCTAssertEqual(check.verdict, .canReply)
        XCTAssertNil(check.message(mac: "Studio"))
        XCTAssertFalse(check.blocksStart)
    }

    func testAListThatCouldNotBeReadSaysNothing() {
        XCTAssertNil(NewChatClaudeCheck.from(list([], active: "default", error: "not ready"), now: now))
        XCTAssertNil(NewChatClaudeCheck.from(list([], active: "default"), now: now), "a host that lists no accounts")
        XCTAssertEqual(NewChatClaudeCheck.from(list([account("other")], active: "gone"), now: now)?.verdict, .notSignedIn,
                       "an account the Mac names but no longer has")
    }
}
