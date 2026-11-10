import XCTest
@testable import RipulAgent

final class CmsRunningActivityTests: XCTestCase {
    private let spec = CmsRunningRecordSpec(.object([
        "query": .string("running_shift"), "title": .string("{job}"),
        "subtitle": .string("In at {wac_in_at|HH:mm}, {live.break_count} breaks"),
        "start": .string("wac_in_at"), "minusSeconds": .string("live.break_seconds"),
        "pausedAt": .string("live.break_started_at"), "label": .string("Worked"),
        "pausedLabel": .string("On break"), "open": .object(["page": .string("shift_now")]),
    ]))!

    func testSpec() {
        XCTAssertNil(CmsRunningRecordSpec(.object(["query": .string("q")])), "a start is needed")
        XCTAssertEqual(spec.key, "id")
        XCTAssertEqual(spec.openPage, "shift_now")
    }

    func testRunning() throws {
        let row: [String: CmsJSON] = ["id": .number(318), "job": .string("Corner Shop"), "wac_in_at": .string("2026-10-30 09:00:00"),
                                      "live.break_seconds": .number(600), "live.break_count": .number(1), "live.break_started_at": .null]
        let c = try XCTUnwrap(spec.content(row, offsetMinutes: 0))
        XCTAssertEqual(c.title, "Corner Shop")
        XCTAssertEqual(c.state.subtitle, "In at 09:00, 1 breaks")
        XCTAssertFalse(c.state.paused)
        XCTAssertEqual(c.state.label, "Worked")
        XCTAssertEqual(c.state.timerStart, ISO8601DateFormatter().date(from: "2026-10-30T09:10:00Z"))
        XCTAssertEqual(spec.recordKey(row), "318")
    }

    func testPaused() throws {
        let row: [String: CmsJSON] = ["id": .string("7"), "job": .string("Gym"), "wac_in_at": .string("2026-10-30T09:00:00Z"),
                                      "live.break_started_at": .string("2026-10-30T12:00:00Z")]
        let c = try XCTUnwrap(spec.content(row, offsetMinutes: 0))
        XCTAssertTrue(c.state.paused)
        XCTAssertEqual(c.state.label, "On break")
        XCTAssertEqual(c.state.timerStart, ISO8601DateFormatter().date(from: "2026-10-30T12:00:00Z"))
    }

    func testNoRowOrStartIsNothing() {
        XCTAssertNil(spec.content(nil))
        XCTAssertNil(spec.content(["id": .number(1)]))
    }

    func testOneSpecPerQuery() {
        func def(_ slug: String) -> CmsMutationDef {
            let json = #"{"slug":"\#(slug)","action":{"after":{"activity":{"query":"q","start":"s"}}}}"#
            return try! JSONDecoder().decode(CmsMutationDef.self, from: Data(json.utf8))
        }
        XCTAssertEqual(CmsRunningRecordSpec.all(["a": def("a"), "b": def("b")]).count, 1)
    }
}
