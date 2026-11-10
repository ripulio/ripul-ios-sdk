import XCTest
@testable import RipulAgent

@MainActor
final class CodingAccountsOverviewTests: XCTestCase {
    private func entry(_ provider: CodingAccountProvider, on mac: String, _ id: String, email: String?,
                       usage: CodingAccountUsage? = nil, active: Bool = false, signedOut: Bool = false) -> CodingAccountEntry {
        CodingAccountEntry(provider: provider, machineId: mac, localId: id, name: id, email: email, plan: nil,
                           usage: usage, isActive: active, needsLogin: signedOut)
    }

    /// - Parameter failed: Macs whose answer was an error ("not ready", a timeout).
    private func reading(_ provider: CodingAccountProvider, _ entries: [CodingAccountEntry],
                         macs: [(String, Bool)] = [("studio", true), ("book", true)],
                         answered: Set<String> = ["studio", "book"], failed: Set<String> = []) -> CodingAccountsOverview.ProviderReading {
        .init(provider: provider, groups: CodingAccountGroup.make(entries).filter { !$0.isUnidentified },
              machines: macs.map { (id: $0.0, name: $0.0.capitalized, online: $0.1) }, answered: answered,
              answeredWithoutError: answered.subtracting(failed))
    }

    func testOneLoginOnTwoMacsIsOneAccountWithItsTightestCurrentLimit() {
        let usage = CodingAccountUsage(windows: [.init(id: "5h", label: "5-hour", usedPercent: 40),
                                                 .init(id: "week", label: "Weekly", usedPercent: 85)], updatedAt: 1)
        let summary = CodingAccountsOverview.summarise([
            reading(.claude, [entry(.claude, on: "studio", "work", email: "Me@x.com", usage: usage, active: true),
                              entry(.claude, on: "book", "default", email: "me@x.com", signedOut: true)]),
            reading(.codex, []), reading(.antigravity, []),
        ])
        XCTAssertEqual(summary.reading, .read)
        XCTAssertEqual(summary.accounts.count, 1)
        let account = summary.accounts[0]
        XCTAssertEqual(account.machines, ["Book", "Studio"])
        XCTAssertEqual(account.signedOutOn, ["Book"])
        XCTAssertFalse(account.needsSignIn, "still signed in on the Studio")
        XCTAssertTrue(account.isActive)
        XCTAssertEqual(account.activeOn, ["Studio"], "in use on the Studio only: signed out on the MacBook")
        XCTAssertEqual(account.tightestWindow?.label, "Weekly")
        XCTAssertFalse(account.atLimit)

        // A limit used up: a new chat on it would stop at once.
        let full = CodingAccountUsage(windows: [.init(id: "week", label: "Weekly", usedPercent: 100)], updatedAt: 1)
        let spent = CodingAccountsOverview.summarise([
            reading(.claude, [entry(.claude, on: "book", "personal", email: "p@x.com", usage: full, active: true)]),
        ]).accounts[0]
        XCTAssertTrue(spent.atLimit)
        XCTAssertEqual(spent.activeOn, ["Book"])

        // A reading the host could not refresh is old: no limit is offered from it.
        let stale = CodingAccountUsage(windows: usage.windows, updatedAt: 1, error: "expired")
        let signedOut = CodingAccountsOverview.summarise([
            reading(.codex, [entry(.codex, on: "studio", "acct-1", email: "me@x.com", usage: stale, signedOut: true)]),
        ]).accounts[0]
        XCTAssertNil(signedOut.tightestWindow)
        XCTAssertTrue(signedOut.needsSignIn)
    }

    func testNobodySignedInIsSaidOnlyOnceEveryOnlineMacHasAnswered() {
        let none = [reading(.claude, []), reading(.codex, []), reading(.antigravity, [])]
        XCTAssertEqual(CodingAccountsOverview.summarise(none).reading, .read)
        XCTAssertTrue(CodingAccountsOverview.summarise(none).accounts.isEmpty)

        // Codex has not answered from the MacBook yet.
        let waiting = [reading(.claude, []), reading(.codex, [], answered: ["studio"]), reading(.antigravity, [])]
        XCTAssertEqual(CodingAccountsOverview.summarise(waiting).reading, .unknown)

        // An offline Mac is not waited for; with every Mac offline nothing can be said.
        let offline = [("studio", true), ("book", false)]
        XCTAssertEqual(CodingAccountsOverview.summarise(CodingAccountProvider.allCases.map {
            reading($0, [], macs: offline, answered: ["studio"]) }).reading, .read)
        XCTAssertEqual(CodingAccountsOverview.summarise(CodingAccountProvider.allCases.map {
            reading($0, [], macs: [("studio", false)], answered: []) }).reading, .unknown)

        // At launch the page answers "not ready" to every call: that is not "nobody signed in".
        XCTAssertEqual(CodingAccountsOverview.summarise(CodingAccountProvider.allCases.map {
            reading($0, [], failed: ["studio", "book"]) }).reading, .unknown)
        // One agent failing on a Mac (not installed there) still lets the others answer for it.
        XCTAssertEqual(CodingAccountsOverview.summarise([
            reading(.claude, []), reading(.codex, []), reading(.antigravity, [], failed: ["book"]),
        ]).reading, .read)

        // No Mac that runs agents: there is nothing to sign in on.
        XCTAssertEqual(CodingAccountsOverview.summarise(CodingAccountProvider.allCases.map {
            reading($0, [], macs: [], answered: []) }).reading, .noMacs)
    }

    func testAccountsKeepTheProvidersOrderWithTheOneInUseFirst() {
        let summary = CodingAccountsOverview.summarise([
            reading(.claude, [entry(.claude, on: "studio", "a", email: "alpha@x.com"),
                              entry(.claude, on: "studio", "b", email: "beta@x.com", active: true)]),
            reading(.codex, [entry(.codex, on: "studio", "c1", email: "c@x.com")]),
            reading(.antigravity, []),
        ])
        XCTAssertEqual(summary.accounts.map(\.provider), [.claude, .claude, .codex])
        XCTAssertEqual(summary.accounts.map(\.email), ["beta@x.com", "alpha@x.com", "c@x.com"])
    }
}
