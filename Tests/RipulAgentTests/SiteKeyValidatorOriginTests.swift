import XCTest
@testable import RipulAgent

/// The `Origin` a site-key check presents. The key's `allowedOrigins` must list
/// it, and a native app has no page of its own: before 27 Oct 2026 every app
/// presented the Ripul portal host, so a key that allowed only the app's own
/// address (WAC Next's) refused every check.
final class SiteKeyValidatorOriginTests: XCTestCase {
    private let portal = URL(string: "https://demo.ripul.io")!

    func testPresentsThePortalHostByDefault() {
        XCTAssertEqual(SiteKeyValidator.presentedOrigin(nil, baseURL: portal), "https://demo.ripul.io")
    }

    func testAnEmptyOriginKeepsTheDefault() {
        XCTAssertEqual(SiteKeyValidator.presentedOrigin("", baseURL: portal), "https://demo.ripul.io")
    }

    func testPresentsTheAppsOwnOrigin() {
        XCTAssertEqual(SiteKeyValidator.presentedOrigin("https://wac-next.app", baseURL: portal), "https://wac-next.app")
    }

    func testTheDefaultKeepsAPortAndDropsThePath() {
        let local = URL(string: "http://localhost:3334/popup")!
        XCTAssertEqual(SiteKeyValidator.presentedOrigin(nil, baseURL: local), "http://localhost:3334")
    }

    func testTheCmsClientPassesItsConfiguredOrigin() {
        let set = CmsClient(config: CmsClientConfig(getToken: { nil }, origin: "https://wac-next.app"))
        XCTAssertEqual(set.origin, "https://wac-next.app")
        let empty = CmsClient(config: CmsClientConfig(getToken: { nil }, origin: ""))
        XCTAssertNil(empty.origin, "an empty origin must fall back to the portal host, not present \"\"")
        XCTAssertNil(CmsClient(config: CmsClientConfig(getToken: { nil })).origin)
    }
}
