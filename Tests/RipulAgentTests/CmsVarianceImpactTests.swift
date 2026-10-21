import XCTest
@testable import RipulAgent

/// The cases of varianceImpact.test.ts, on the native port.
final class CmsVarianceImpactTests: XCTestCase {
    private let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 12))!
    private let rows: [[String: CmsJSON]] = [
        ["id": .string("a"), "kind": .string("wac_out"), "person": .string("Grace"), "direction": .string("worker"),
         "hours": .number(5), "amount": .number(61.05), "found_at": .string("2026-10-19T08:46:51Z"),
         "fixed_at": .string("2026-10-19T11:15:23Z"), "found_by": .string("Flagged shifts review"), "fixed_how": .string("grid")],
        ["id": .string("b"), "kind": .string("hours"), "person": .string("Lillie"), "direction": .string("company"),
         "hours": .number(1.5), "amount": .number(18), "found_at": .string("2026-09-01T09:00:00Z"),
         "fixed_at": .string("2026-09-03T09:00:00Z"), "found_by": .string("location"), "fixed_how": .string("manager")],
    ]

    func testSummarise() {
        let s = Impact.summarise(rows, shifts: nil, now: now)
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s.amount, 79.05, accuracy: 0.001)
        XCTAssertEqual(s.worker.count, 1)
        XCTAssertEqual(s.worker.amount, 61.05, accuracy: 0.001)
        XCTAssertEqual(s.company.hours, 1.5, accuracy: 0.001)
        XCTAssertEqual(s.fixedOnShifts, 1)
        XCTAssertEqual(s.avgDaysToFix ?? 0, (2.47 / 24 + 2) / 2, accuracy: 0.05)
        XCTAssertEqual(s.byMonth.count, 12)
        XCTAssertEqual(s.byMonth[11].count, 1)
        XCTAssertEqual(s.byMonth[11].amount, 61.05, accuracy: 0.001)
        XCTAssertEqual(s.byMonth[10].count, 1)
        XCTAssertEqual(Impact.summarise([], shifts: nil, now: now).count, 0)
    }

    func testWords() {
        XCTAssertEqual(Impact.foundByLabel("location"), "Location check")
        XCTAssertEqual(Impact.foundByLabel("Dashboard"), "Dashboard")
        XCTAssertEqual(Impact.foundByLabel("Flagged shifts review"), "Reconcile report")
        XCTAssertEqual(Impact.hoursLabel(5.5), "5h 30m")
        XCTAssertEqual(Impact.hoursLabel(0.75), "45m")
        XCTAssertEqual(Impact.hoursLabel(1234), "1,234h")
        let t = Impact.shiftTotals([
            ["shifts": .number(823), "hours": .number(4000), "pay": .number(1), "people": .number(20), "first_day": .string("2026-05-07")],
            ["shifts": .number(47), "hours": .number(200), "pay": .number(1), "people": .number(8), "first_day": .string("2026-06-01")],
        ])
        XCTAssertEqual(t?.shifts, 870)
        XCTAssertEqual(t?.people, 20)
        XCTAssertEqual(t?.firstDay, "2026-05-07")
    }

    func testReportNormaliseAndCsv() throws {
        let json = #"{"title":"Pay period · 20 Sep – 19 Oct","stats":[{"value":"£27.95","label":"variance"}],"groups":[{"title":"Grace","bars":[{"label":"Mon","planned":8,"worked":9,"note":"1h over"}]}],"table":{"columns":["Name","Hours"],"rows":[["=Grace","9"]]}}"#
        let report = try XCTUnwrap(CmsReport.normalise(try JSONSerialization.jsonObject(with: Data(json.utf8))))
        XCTAssertEqual(report.groups.first?.bars.first?.value, 1)
        XCTAssertTrue(report.csv.contains("Name,Detail,Day,Planned hours,Worked hours,Variance,Note"))
        XCTAssertTrue(report.csv.contains("Grace,,Mon,8,9,1,1h over"))
        XCTAssertTrue(report.csv.contains("'=Grace,9"))
        XCTAssertEqual(report.fileName(), "pay-period-20-sep-19-oct.csv")
        XCTAssertNil(CmsReport.normalise(["title": "Heading only"]))
    }
}
