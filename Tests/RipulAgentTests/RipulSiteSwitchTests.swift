import XCTest
@testable import RipulAgent

/// The site switch an SDK developer build offers from the dev helper: the
/// compiled site unless a member site was picked, the choice tied to the key it
/// was made over, and Reset back. (Tests build as Debug, so the switch is in.)
final class RipulSiteSwitchTests: XCTestCase {
    private let compiled = RipulSiteSwitch.CompiledSite(
        publishableKey: "pk_live_compiled", cmsId: "cms_compiled", origin: "https://wac-ios.app", name: "WAC Business")
    private let demo = RipulMemberSite(
        siteKeyId: "sk_demo", publishableKey: "pk_live_demo", name: "wac Demo", slug: "wac-demo-wrap",
        cmsDefinitionId: "cms_demo", role: "manager")

    override func setUp() {
        super.setUp()
        RipulSiteSwitchStore.compiled = compiled
        RipulSiteSwitchStore.set(nil)
    }

    override func tearDown() {
        RipulSiteSwitchStore.set(nil)
        super.tearDown()
    }

    func testCompiledSiteUntilOneIsPicked() {
        XCTAssertTrue(RipulSiteSwitch.isAvailable)
        XCTAssertEqual(RipulSiteSwitch.siteKey(compiled: "pk_live_compiled"), "pk_live_compiled")
        XCTAssertEqual(RipulSiteSwitch.cmsId(compiled: "cms_compiled", compiledKey: "pk_live_compiled"), "cms_compiled")
        XCTAssertNil(RipulSiteSwitch.switchedSiteName(compiledKey: "pk_live_compiled"))
    }

    func testPickedSiteMovesKeyAndDefinition() {
        RipulSiteSwitchStore.set(demo)
        XCTAssertEqual(RipulSiteSwitch.siteKey(compiled: "pk_live_compiled"), "pk_live_demo")
        XCTAssertEqual(RipulSiteSwitch.cmsId(compiled: "cms_compiled", compiledKey: "pk_live_compiled"), "cms_demo")
        XCTAssertEqual(RipulSiteSwitch.switchedSiteName(compiledKey: "pk_live_compiled"), "wac Demo")
    }

    func testChoiceIsIgnoredByABuildWithAnotherCompiledKey() {
        RipulSiteSwitchStore.set(demo)
        XCTAssertEqual(RipulSiteSwitch.siteKey(compiled: "pk_live_other"), "pk_live_other")
    }

    func testResetGoesBackToTheCompiledSite() {
        RipulSiteSwitchStore.set(demo)
        RipulSiteSwitch.reset()
        XCTAssertEqual(RipulSiteSwitch.siteKey(compiled: "pk_live_compiled"), "pk_live_compiled")
    }

    func testPickingTheCompiledSiteClearsTheChoice() {
        RipulSiteSwitchStore.set(demo)
        RipulSiteSwitchStore.set(RipulMemberSite(siteKeyId: "sk_wac", publishableKey: "pk_live_compiled",
                                                 name: "WAC Business", role: "admin"))
        XCTAssertNil(RipulSiteSwitch.switchedSiteName(compiledKey: "pk_live_compiled"))
    }

    func testAChangeIsAnnounced() {
        let announced = expectation(forNotification: RipulSiteSwitch.didChange, object: nil)
        RipulSiteSwitchStore.set(demo)
        wait(for: [announced], timeout: 2)
    }

    func testMarkerStringIsTheOneTheUploadChecksLookFor() {
        XCTAssertEqual(RipulSiteSwitch.marker, "RIPUL_SITE_SWITCH_COMPILED_IN")
    }
}
