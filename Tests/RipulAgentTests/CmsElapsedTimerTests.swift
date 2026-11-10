import XCTest
@testable import RipulAgent

/// The elapsed timer against the table both renderers share:
/// `chrome-extension/packages/shared-types/src/cmsElapsedTimer.cases.json`.
final class CmsElapsedTimerTests: XCTestCase {
    private static let table: [String: Any] = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("chrome-extension/packages/shared-types/src/cmsElapsedTimer.cases.json")
        return try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }()

    private func json(_ any: Any?) -> CmsJSON? {
        guard let any, !(any is NSNull) else { return nil }
        let data = try! JSONSerialization.data(withJSONObject: any, options: [.fragmentsAllowed])
        return try? JSONDecoder().decode(CmsJSON.self, from: data)
    }

    func testState() {
        let cases = Self.table["state"] as! [[String: Any]]
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let name = c["name"] as! String
            let timer = CmsElapsedTimer(json(c["props"])?.objectValue ?? [:])
            let now = Date(timeIntervalSince1970: (c["now"] as! Double) / 1000)
            let got = timer.state(row: json(c["row"])?.objectValue, now: now)
            let expect = c["expect"] as! [String: Any]
            if let v = expect["mode"] as? String { XCTAssertEqual(got.mode.rawValue, v, name) }
            if let v = expect["seconds"] as? Int { XCTAssertEqual(got.seconds, v, name) }
            if let v = expect["label"] as? String { XCTAssertEqual(got.label, v, name) }
            if let v = expect["main"] as? String { XCTAssertEqual(got.main, v, name) }
            if let v = expect["sub"] as? String { XCTAssertEqual(got.sub, v, name) }
        }
    }
}
