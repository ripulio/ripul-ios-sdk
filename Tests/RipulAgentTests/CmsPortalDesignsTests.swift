import XCTest
@testable import RipulAgent

/// Same cases as portalDesigns.test.ts's applyDesign, on the native twin.
final class CmsPortalDesignsTests: XCTestCase {
    private func page(_ id: String, _ slug: String, shell: String? = nil) -> CmsPage {
        CmsPage(id: id, slug: slug, title: slug, bodyType: "blocks", shellPageId: shell)
    }

    func testSwapKeepsAddressAndDesignShellReplacesSiteShell() {
        let pages = [
            page("shell2", "shell-v2"), page("shell3", "shell-v3"),
            page("dash2", "dashboard-v2"), page("dash3", "dashboard-v3"),
            page("emp", "employees", shell: "shell2"), page("own", "own-shell", shell: "other"),
        ]
        let design = CmsPortalDesign(id: "topbar", shellPageId: "shell3", pages: ["dash2": "dash3"])
        let out = CmsPortalDesigns.apply(pages: pages, shellPageId: "shell2", landingPageId: "dash2", design: design)

        XCTAssertEqual(out.shellPageId, "shell3")
        XCTAssertEqual(out.landingPageId, "dash3")
        XCTAssertEqual(out.pages.map(\.slug), ["shell-v2", "shell-v3", "dashboard-v2", "employees", "own-shell"])
        let dashboard = out.pages.first { $0.slug == "dashboard-v2" }
        XCTAssertEqual(dashboard?.id, "dash3")
        XCTAssertEqual(out.pages.first { $0.slug == "employees" }?.shellPageId, "shell3")
        XCTAssertEqual(out.pages.first { $0.slug == "own-shell" }?.shellPageId, "other")
    }

    func testNoDesignLeavesSiteAlone() {
        let pages = [page("a", "a")]
        let out = CmsPortalDesigns.apply(pages: pages, shellPageId: "s", landingPageId: "a", design: nil)
        XCTAssertEqual(out.pages, pages)
        XCTAssertEqual(out.shellPageId, "s")
        XCTAssertEqual(out.landingPageId, "a")
    }

    func testChosenFallsBackToFirstWhenStoredIsGone() {
        let defaults = UserDefaults(suiteName: "CmsPortalDesignsTests")!
        defaults.set("removed", forKey: CmsPortalDesigns.storageKey("cms"))
        let designs = [CmsPortalDesign(id: "topbar"), CmsPortalDesign(id: "sidebar")]
        XCTAssertEqual(CmsPortalDesigns.chosen(cmsId: "cms", designs: designs, defaults: defaults)?.id, "topbar")
        defaults.set("sidebar", forKey: CmsPortalDesigns.storageKey("cms"))
        XCTAssertEqual(CmsPortalDesigns.chosen(cmsId: "cms", designs: designs, defaults: defaults)?.id, "sidebar")
    }
}
