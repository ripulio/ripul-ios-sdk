import XCTest
@testable import RipulAgent

/// Swipe actions against the table both renderers share:
/// `chrome-extension/packages/shared-types/src/cmsSwipe.cases.json` (the web runs it in cmsSwipe.test.ts).
final class CmsSwipeTests: XCTestCase {
    private static let table: [String: Any] = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("chrome-extension/packages/shared-types/src/cmsSwipe.cases.json")
        let data = try! Data(contentsOf: url)
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }()

    private func json(_ any: Any?) -> CmsJSON? {
        guard let any, !(any is NSNull) else { return nil }
        let data = try! JSONSerialization.data(withJSONObject: any, options: [.fragmentsAllowed])
        return try? JSONDecoder().decode(CmsJSON.self, from: data)
    }

    private func brief(_ a: CmsSwipe.Action) -> [String: Any] {
        var out: [String: Any] = [
            "label": a.label, "color": a.color.rawValue, "destructive": a.destructive, "index": a.index,
            "kind": { if case .run = a.action { return "run" }; return "open" }(),
        ]
        if let confirm = a.confirm { out["confirm"] = confirm }
        return out
    }

    func testSharedTable() {
        let cases = Self.table["cases"] as! [[String: Any]]
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let name = c["name"] as! String
            let row = json(c["row"])?.objectValue ?? [:]
            let got = CmsSwipe.resolve(json(c["config"]), row: row)
            let expect = c["expect"] as! [String: Any]
            let gotJSON: [String: Any] = [
                "leading": got.leading.map(brief), "trailing": got.trailing.map(brief),
                "fullSwipeLeading": got.fullSwipeLeading, "fullSwipeTrailing": got.fullSwipeTrailing,
            ]
            XCTAssertEqual(NSDictionary(dictionary: gotJSON), NSDictionary(dictionary: expect), name)
        }
    }

    func testIconsMapNavKeysAndKeepSymbols() {
        XCTAssertEqual(CmsSwipe.symbol("delete"), CmsNavIcon.symbol(for: "delete"))
        XCTAssertEqual(CmsSwipe.symbol("archivebox"), "archivebox")
        XCTAssertNil(CmsSwipe.symbol(""))
    }
}
