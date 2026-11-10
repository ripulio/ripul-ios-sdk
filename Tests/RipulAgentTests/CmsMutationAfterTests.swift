import XCTest
@testable import RipulAgent

/// `action.after` against the table both renderers share:
/// `chrome-extension/packages/shared-types/src/cmsMutationAfter.cases.json`.
final class CmsMutationAfterTests: XCTestCase {
    private static let table: [String: Any] = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("chrome-extension/packages/shared-types/src/cmsMutationAfter.cases.json")
        return try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }()

    private func json(_ any: Any?) -> CmsJSON? {
        guard let any, !(any is NSNull) else { return nil }
        let data = try! JSONSerialization.data(withJSONObject: any, options: [.fragmentsAllowed])
        return try? JSONDecoder().decode(CmsJSON.self, from: data)
    }

    func testResolve() {
        for c in Self.table["resolve"] as! [[String: Any]] {
            let name = c["name"] as! String
            let got = CmsMutationAfter(json(c["after"]))
            guard let expect = c["expect"] as? [String: Any] else { XCTAssertNil(got, name); continue }
            XCTAssertEqual(got?.countdown, expect["countdown"] as? Int, name)
            XCTAssertEqual(got?.countdownText, expect["countdownText"] as? String, name)
            XCTAssertEqual(got?.openPage, (expect["open"] as? [String: Any])?["page"] as? String, name)
            if let s = expect["summary"] as? [String: Any] {
                XCTAssertEqual(got?.summary?.title, s["title"] as? String, name)
                XCTAssertEqual(got?.summary?.lines.count, (s["lines"] as? [Any])?.count, name)
            } else {
                XCTAssertNil(got?.summary, name)
            }
        }
    }

    func testFill() {
        for c in Self.table["fill"] as! [[String: Any]] {
            let name = c["name"] as! String
            let got = CmsMutationAfter.fill(c["template"] as! String, run: json(c["run"]) ?? .object([:]), offsetMinutes: c["offset"] as! Int)
            let expect = c["expect"] as! [String: Any]
            XCTAssertEqual(got.text, expect["text"] as? String, name)
            XCTAssertEqual(got.missing, expect["missing"] as? Bool, name)
        }
    }

    func testQuantise() {
        let iso = ISO8601DateFormatter()
        func d(_ v: Any?) -> Date? { (v as? String).flatMap(iso.date(from:)) }
        for c in Self.table["quantise"] as! [[String: Any]] {
            let name = c["name"] as! String
            let got = CmsMutationAfter.quantise(start: d(c["start"])!, end: d(c["end"])!, plannedStart: d(c["plannedStart"]),
                                                plannedEnd: d(c["plannedEnd"]), windowMinutes: c["window"] as! Int)
            let e = c["expect"] as! [String: Any]
            if let v = d(e["start"]) { XCTAssertEqual(got.start, v, name) }
            if let v = d(e["end"]) { XCTAssertEqual(got.end, v, name) }
            if let v = e["startChanged"] as? Bool { XCTAssertEqual(got.startChanged, v, name) }
            if let v = e["endChanged"] as? Bool { XCTAssertEqual(got.endChanged, v, name) }
        }
    }
}
