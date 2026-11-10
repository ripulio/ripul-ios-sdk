import XCTest
@testable import RipulAgent

/// A card's accessory and host actions, against the table the web runs too:
/// `chrome-extension/packages/shared-types/src/cmsCardAccessory.cases.json`
/// (cmsCardAccessory.test.ts).
final class CmsCardAccessoryTests: XCTestCase {
    private static let table: [String: Any] = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("chrome-extension/packages/shared-types/src/cmsCardAccessory.cases.json")
        let data = try! Data(contentsOf: url)
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }()

    private func json(_ any: Any) -> CmsJSON {
        let data = try! JSONSerialization.data(withJSONObject: any, options: [.fragmentsAllowed])
        return try! JSONDecoder().decode(CmsJSON.self, from: data)
    }

    func testInitials() {
        let cases = Self.table["initials"] as! [[String: Any]]
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            XCTAssertEqual(CmsCardAccessory.initials(c["text"] as? String), c["expect"] as? String, c["name"] as! String)
        }
    }

    func testSizes() {
        let cases = Self.table["sizes"] as! [[String: Any]]
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let raw = c["size"].flatMap { $0 is NSNull ? nil : json($0) }
            XCTAssertEqual(CmsCardAccessory.size(raw), CGFloat((c["expect"] as! NSNumber).doubleValue), c["name"] as! String)
        }
    }

    func testAccessoryReadsItsActionAndNeedsALabel() {
        let parts = CmsCardParts(json([
            "accessory": ["label": "Profile", "initials": "{preferred_name}", "open": ["page": "account"]],
        ]).objectValue!)
        XCTAssertEqual(parts.accessory?.label, "Profile")
        XCTAssertEqual(parts.accessory?.initials, "{preferred_name}")
        XCTAssertEqual(parts.accessory?.action, .openPage("account", params: [:]))
        XCTAssertEqual(parts.accessory?.size, 40)
        XCTAssertNil(CmsCardAccessory(json(["open": ["page": "account"]])), "no label, no accessory")
        // A variant's accessory replaces the card's.
        let over = CmsCardParts(json(["accessory": ["label": "Settings", "symbol": "settings", "open": ["page": "settings"]]]).objectValue!)
        XCTAssertEqual(parts.applying(over).accessory?.label, "Settings")
        XCTAssertEqual(parts.applying(CmsCardParts()).accessory?.label, "Profile")
    }

    func testHostActionsAreOnlyAvailableWhereTheAppHandlesThem() {
        let action = CmsCardAction(json(["open": ["host": "signOut"]]))
        XCTAssertEqual(action, .openHost("signOut"))
        XCTAssertTrue(action!.available(hostActions: ["signOut"]))
        XCTAssertFalse(action!.available(hostActions: []))
        XCTAssertTrue(CmsCardAction.openPage("x", params: [:]).available(hostActions: []))
        XCTAssertNil(CmsCardAction(json(["open": ["host": ""]])))
    }

    func testAHostTabGivesWayToASiteTabOfTheSameId() {
        XCTAssertEqual(CmsAppLayout.shownHostTabIDs(["account", "help"], sitePageSlugs: ["home", "account"]), ["help"])
        XCTAssertEqual(CmsAppLayout.shownHostTabIDs(["account"], sitePageSlugs: ["home"]), ["account"])
        // The remembered host tab becomes the site tab that took it over.
        XCTAssertEqual(CmsAppLayout.rememberedTab(CmsAppTabID.host("account"), shownHostTabIDs: [], sitePageSlugs: ["account"]),
                       CmsAppTabID.site("account"))
        XCTAssertEqual(CmsAppLayout.rememberedTab(CmsAppTabID.host("account"), shownHostTabIDs: ["account"], sitePageSlugs: []),
                       CmsAppTabID.host("account"))
        XCTAssertEqual(CmsAppLayout.rememberedTab(CmsAppTabID.site("home"), shownHostTabIDs: [], sitePageSlugs: ["home"]),
                       CmsAppTabID.site("home"))
    }
}
