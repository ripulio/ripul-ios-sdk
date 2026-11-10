import XCTest
@testable import RipulAgent

/// In-app web pages' rules, against the table the web runs too:
/// `chrome-extension/packages/shared-types/src/cmsWebPage.cases.json` (cmsWebPage.test.ts).
final class CmsWebPageTests: XCTestCase {
    private static let table: [String: Any] = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("chrome-extension/packages/shared-types/src/cmsWebPage.cases.json")
        return try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }()

    private func json(_ any: Any) -> CmsJSON {
        try! JSONDecoder().decode(CmsJSON.self, from: JSONSerialization.data(withJSONObject: any))
    }

    func testRoutes() {
        let cases = Self.table["routes"] as! [[String: Any]]
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let expect: CmsWebPage.Route = ["inside": .inside, "system": .system, "refuse": .refuse][c["expect"] as! String]!
            XCTAssertEqual(CmsWebPage.route(scheme: (c["scheme"] as! String).lowercased()), expect, c["scheme"] as! String)
        }
    }

    func testAddresses() {
        let cases = Self.table["addresses"] as! [[String: Any]]
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            XCTAssertEqual(CmsWebPage.address(c["text"] as! String) != nil, c["ok"] as! Bool, c["name"] as! String)
        }
    }

    func testTheActionReadsAddressAndTitle() {
        XCTAssertEqual(CmsCardAction(json(["open": ["web": "{rights_url}", "title": "Basic employee rights"]])),
                       .openWeb("{rights_url}", title: "Basic employee rights"))
        XCTAssertEqual(CmsCardAction(json(["open": ["web": "https://wac.rocks/faqs/"]])), .openWeb("https://wac.rocks/faqs/", title: nil))
        XCTAssertNil(CmsCardAction(json(["open": ["web": ""]])))
    }
}
