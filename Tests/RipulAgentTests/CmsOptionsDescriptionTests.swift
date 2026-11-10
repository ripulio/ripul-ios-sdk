import XCTest
@testable import RipulAgent

final class CmsOptionsDescriptionTests: XCTestCase {
    private func query(_ json: String) -> CmsActionOptionsQuery {
        try! JSONDecoder().decode(CmsActionOptionsQuery.self, from: Data(json.utf8))
    }

    func testDescriptionFormatShowsMoney() {
        let q = query(#"{"querySlug":"job_roles","valueColumn":"uuid","descriptionColumn":"base_rate","descriptionFormat":"£#,##0.00"}"#)
        XCTAssertEqual(q.describe(["base_rate": .string("12.5")]), "£12.50")
        XCTAssertEqual(q.describe(["base_rate": .number(15)]), "£15.00")
    }

    func testWithoutAFormatTheValueShowsAsItIs() {
        let q = query(#"{"querySlug":"q","valueColumn":"id","descriptionColumn":"role"}"#)
        XCTAssertEqual(q.describe(["role": .string("Assistant Manager")]), "Assistant Manager")
        XCTAssertNil(q.describe(["role": .string("")]))
        XCTAssertNil(q.describe([:]))
    }

    /// wac-app's planned shift: "Planned {start_time|HH:mm} – {end_time|HH:mm}" over
    /// the rota's moments, as the web shows it (it read the raw ISO text before).
    func testADatePatternShowsTheTime() {
        let q = query(#"{"querySlug":"planned_shift_near","valueColumn":"id","description":"Planned {start_time|HH:mm} – {end_time|HH:mm}"}"#)
        XCTAssertEqual(q.describe(["start_time": .string("2026-11-01 17:36:00"), "end_time": .string("2026-11-01 20:36:00")]),
                       "Planned 17:36 – 20:36")
        let local = DateFormatter()
        local.dateFormat = "HH:mm"
        let start = ISO8601DateFormatter().date(from: "2026-11-01T17:36:00Z")!
        let end = ISO8601DateFormatter().date(from: "2026-11-01T20:36:00Z")!
        XCTAssertEqual(q.describe(["start_time": .string("2026-11-01T17:36:00.000Z"), "end_time": .string("2026-11-01T20:36:00.000Z")]),
                       "Planned \(local.string(from: start)) – \(local.string(from: end))")
        let column = query(#"{"querySlug":"q","valueColumn":"id","descriptionColumn":"start_time","descriptionFormat":"HH:mm"}"#)
        XCTAssertEqual(column.describe(["start_time": .string("2026-11-03 09:00:00")]), "09:00")
    }

    func testEmptyChoiceDecodes() {
        let q = query(#"{"querySlug":"q","valueColumn":"id","emptyChoice":{"label":"Default rate","description":"{job_id.rate|£#,##0.00}"}}"#)
        XCTAssertEqual(q.emptyChoice?.label, "Default rate")
        XCTAssertEqual(q.emptyChoice?.description, "{job_id.rate|£#,##0.00}")
    }
}
