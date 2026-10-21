import XCTest
@testable import RipulAgent

/// fileWeeks.test.ts's cases on the native port, plus pay periods.
final class CmsFileWeeksTests: XCTestCase {
    private let cal = Calendar(identifier: .gregorian)
    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d))! }
    private var now: Date { day(2026, 8, 19) }

    private func file(_ id: String, _ meta: [String: CmsJSON] = [:], created: String = "2026-08-01T00:00:00Z") -> CmsFileRecord {
        CmsFileRecord(.object(["id": .string(id), "filename": .string("\(id).xlsx"), "metadata": .object(meta), "createdAt": .string(created)]))!
    }

    func testMondaysAndLabels() {
        XCTAssertEqual(CmsFileWeeks.iso(CmsFileWeeks.mondayOf(now)), "2026-08-17")
        XCTAssertEqual(CmsFileWeeks.iso(CmsFileWeeks.mondayOf(day(2026, 8, 23))), "2026-08-17")
        XCTAssertEqual(CmsFileWeeks.iso(CmsFileWeeks.mondayOf(day(2026, 8, 24))), "2026-08-24")
        XCTAssertEqual(CmsFileWeeks.weekLabel(day(2026, 8, 10), now: now), "10 – 16 Aug")
        XCTAssertTrue(CmsFileWeeks.weekLabel(day(2026, 8, 31), now: now).hasPrefix("31 Aug – 6 Sep"))
        XCTAssertEqual(CmsFileWeeks.weekLabel(day(2027, 1, 4), now: now), "4 – 10 Jan 2027")
    }

    func testWeeksAndStatus() {
        let files = [file("a", ["week": .string("2026-08-05")]), file("c"), file("d", ["week": .string("2025-01-06")])]
        let (weeks, unfiled) = CmsFileWeeks.buildWeeks(files, now: now, ahead: 1, back: 2, key: "week")
        XCTAssertEqual(weeks.map(\.start), ["2026-08-24", "2026-08-17", "2026-08-10", "2026-08-03"])
        XCTAssertEqual(weeks[3].files.map(\.id), ["a"])
        XCTAssertEqual(unfiled.map(\.id), ["c", "d"])

        func w(_ offset: Int, _ f: [CmsFileRecord]) -> CmsFileWeeks.Week {
            CmsFileWeeks.Week(start: "2026-08-10", end: "2026-08-17", label: "", offset: offset, files: f)
        }
        XCTAssertEqual(CmsFileWeeks.status(w(1, [])), .due)
        XCTAssertEqual(CmsFileWeeks.status(w(-3, [])), .missing)
        XCTAssertEqual(CmsFileWeeks.status(w(0, [file("a")])), .uploaded)
        XCTAssertEqual(CmsFileWeeks.status(w(-1, [file("a")])), .ready)
        XCTAssertEqual(CmsFileWeeks.status(w(-1, [file("a", ["differences": .number(0)])])), .matched)
        XCTAssertEqual(CmsFileWeeks.status(w(-1, [file("a", ["differences": .string("3")])])), .differences(count: 3, value: nil))
    }

    func testFillPrompt() {
        XCTAssertEqual(CmsFileWeeks.fillPrompt("Check {filename} for {weekLabel} ({nope})", ["filename": "r.xlsx", "weekLabel": "10 – 16 Aug"]),
                       "Check r.xlsx for 10 – 16 Aug ({nope})")
        let unset: [String: String?] = ["week": nil as String?]
        XCTAssertEqual(CmsFileWeeks.fillPrompt("Week {week}", unset), "Week (not set)")
    }

    func testPayPeriods() {
        let today = day(2026, 10, 20)
        let p = CmsFileWeeks.payPeriodOf(today, cutoff: 19)
        XCTAssertEqual(CmsFileWeeks.iso(p.first), "2026-10-20")
        XCTAssertEqual(CmsFileWeeks.iso(p.last), "2026-11-19")
        XCTAssertEqual(CmsFileWeeks.iso(CmsFileWeeks.paydayAfter(day(2026, 10, 19), schedule: "last")!), "2026-10-31")
        XCTAssertEqual(CmsFileWeeks.iso(CmsFileWeeks.paydayAfter(day(2026, 10, 19), schedule: "15")!), "2026-11-15")
        let (weeks, _) = CmsFileWeeks.buildWeeks([], now: today, ahead: 1, back: 6, key: "week")
        let periods = CmsFileWeeks.buildPayPeriods(weeks, now: today, cutoff: 19, paySchedule: "last")
        XCTAssertEqual(periods.first?.offset, 0)
        XCTAssertEqual(periods.map(\.offset).sorted(by: >), periods.map(\.offset))
        XCTAssertTrue(periods.contains { $0.start == "2026-09-20" && $0.lastDay == "2026-10-19" && $0.payday == "2026-10-31" })
    }
}
