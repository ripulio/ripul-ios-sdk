import XCTest
@testable import RipulAgent

/// Reads the web's fixture file, so the two classifiers can't drift.
final class CmsQueryErrorTextTests: XCTestCase {
    private struct Case: Decodable { let error: String; let kind: String }

    func testSharedFixtures() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("chrome-extension/src/cms/blocks/queryErrorText.fixtures.json")
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            XCTAssertEqual(CmsQueryErrorText.describe(c.error).kind.rawValue, c.kind, c.error)
        }
    }

    func testVisitorNeverSeesDiagnostic() {
        let text = CmsQueryErrorText.describe("[BigQuery] The job encountered an error during execution.\n\n[diag] Params in SQL: a")
        XCTAssertFalse(text.message.contains("diag"))
        XCTAssertFalse(text.message.contains("BigQuery"))
        XCTAssertTrue(text.retry)
    }
}
