import XCTest
@testable import RipulAgent

/// The availability calendar's rules, held to the web's availability.test.ts (the same cases).
final class CmsAvailabilityTests: XCTestCase {
    private func feed(_ starts: [Any], _ ends: [Any], _ available: [Any], refreshedAt: String? = "2026-10-17T11:29:11.061Z") -> CmsAvailability.Unit {
        let data: [String: Any] = ["0.periods.*.start": starts, "0.periods.*.end": ends, "0.periods.*.available": available]
        let json = try! JSONDecoder().decode(CmsJSON.self, from: JSONSerialization.data(withJSONObject: data))
        return CmsAvailability.read(data: json.objectValue, refreshedAt: refreshedAt)
    }

    private var unit: CmsAvailability.Unit {
        feed(["2026-11-01", "2026-11-02", "2026-11-05", "nonsense"], ["2026-11-01", "2026-11-04", "2026-11-08", "2026-11-09"], [0, 1, 0, 1])
    }

    func testExpandsRangesSkippingMalformedOnes() {
        XCTAssertEqual(unit.free, ["2026-11-02", "2026-11-03", "2026-11-04"])
        XCTAssertEqual(unit.unavailable, ["2026-11-01", "2026-11-05", "2026-11-06", "2026-11-07", "2026-11-08"])
        XCTAssertEqual(unit.refreshedAt, "2026-10-17T11:29:11.061Z")
        XCTAssertTrue(CmsAvailability.read(data: nil, refreshedAt: nil).free.isEmpty)
    }

    func testAStaysNights() {
        XCTAssertEqual(CmsAvailability.nights("2026-11-02", "2026-11-05"), ["2026-11-02", "2026-11-03", "2026-11-04"])
        XCTAssertEqual(CmsAvailability.nights("2026-11-05", "2026-11-05"), [])
        XCTAssertEqual(CmsAvailability.nights("2026-12-30", "2027-01-02"), ["2026-12-30", "2026-12-31", "2027-01-01"])
        let ok = CmsAvailability.stay(unit, CmsAvailability.nights("2026-11-02", "2026-11-05"))
        XCTAssertTrue(ok.free); XCTAssertNil(ok.firstTaken)
        let taken = CmsAvailability.stay(unit, CmsAvailability.nights("2026-11-03", "2026-11-07"))
        XCTAssertFalse(taken.free); XCTAssertEqual(taken.firstTaken, "2026-11-05")
        XCTAssertFalse(CmsAvailability.stay(unit, []).free)
    }

    func testRulesOutOnlyWhenEveryUnitsFeedSaysTaken() {
        let other = feed(["2026-11-01", "2026-11-03"], ["2026-11-02", "2026-11-08"], [1, 0], refreshedAt: nil)
        XCTAssertFalse(CmsAvailability.ruledOut([unit, other], ["2026-11-01"]))
        XCTAssertTrue(CmsAvailability.ruledOut([unit, other], ["2026-11-05"]))
        XCTAssertFalse(CmsAvailability.ruledOut([unit, nil], ["2026-11-05"]))
        XCTAssertFalse(CmsAvailability.ruledOut([unit, other], ["2026-11-20"]))
        XCTAssertFalse(CmsAvailability.ruledOut(nil, ["2026-11-05"]))
        XCTAssertFalse(CmsAvailability.ruledOut([unit, other], CmsAvailability.nights("2026-11-02", "2026-11-05")))
        let tooLong = CmsAvailability.nights("2026-11-02", "2026-11-09")
        XCTAssertTrue(CmsAvailability.ruledOut([unit, other], tooLong))
        XCTAssertEqual(CmsAvailability.latestDeparture([unit, other], tooLong), "2026-11-05")
        XCTAssertNil(CmsAvailability.latestDeparture([unit, other], CmsAvailability.nights("2026-11-05", "2026-11-07")))
    }

    func testAFresherCopyOnView() {
        let at = CmsAvailability.parseInstant("2026-10-18T12:00:00Z")!
        XCTAssertTrue(CmsAvailability.wantsRefresh(refreshedAt: "2026-10-18T11:50:00Z", minutes: 5, at: at))
        XCTAssertFalse(CmsAvailability.wantsRefresh(refreshedAt: "2026-10-18T11:58:00Z", minutes: 5, at: at))
        XCTAssertTrue(CmsAvailability.wantsRefresh(refreshedAt: nil, minutes: 5, at: at))
        XCTAssertFalse(CmsAvailability.wantsRefresh(refreshedAt: "2026-10-17T00:00:00Z", minutes: nil, at: at))
        var older = unit; older.refreshedAt = "2026-10-18T11:00:00Z"
        var newer = unit; newer.refreshedAt = "2026-10-18T12:00:00Z"
        XCTAssertEqual(CmsAvailability.newer(newer, older), newer)
        XCTAssertEqual(CmsAvailability.newer(older, newer), newer)
        XCTAssertEqual(CmsAvailability.newer(newer, nil), newer)
        XCTAssertEqual(CmsAvailability.newer(nil, older), older)
    }

    func testChoosingDatesAsTheWebDoes() {
        let other = feed(["2026-11-01", "2026-11-03"], ["2026-11-02", "2026-11-08"], [1, 0], refreshedAt: nil)
        let units: [CmsAvailability.Unit?] = [unit, other]
        let say = { (d: String) in d }
        let none = CmsAvailability.Choice()
        XCTAssertEqual(CmsAvailability.choose("2026-10-31", current: none, units: units, today: "2026-11-01", longDay: say), .ignored)
        XCTAssertEqual(CmsAvailability.choose("2026-11-05", current: none, units: units, today: "2026-11-01", longDay: say),
                       .refused("2026-11-05 is not available."))
        XCTAssertEqual(CmsAvailability.choose("2026-11-02", current: none, units: units, today: "2026-11-01", longDay: say),
                       .chosen(.init(arrival: "2026-11-02")))
        let arrived = CmsAvailability.Choice(arrival: "2026-11-02")
        // Leaving on a taken day is fine.
        XCTAssertEqual(CmsAvailability.choose("2026-11-05", current: arrived, units: units, today: "2026-11-01", longDay: say),
                       .chosen(.init(arrival: "2026-11-02", departure: "2026-11-05")))
        XCTAssertEqual(CmsAvailability.choose("2026-11-09", current: arrived, units: units, today: "2026-11-01", longDay: say),
                       .refused("Not available every night from 2026-11-02 to 2026-11-09. You can stay until 2026-11-05."))
        // A day not after the arrival starts again.
        XCTAssertEqual(CmsAvailability.choose("2026-11-01", current: arrived, units: units, today: "2026-11-01", longDay: say),
                       .chosen(.init(arrival: "2026-11-01")))
    }

    func testPropsDefaults() {
        let p = CmsAvailability.Props([:])
        XCTAssertEqual(p.units.count, 1)
        XCTAssertEqual(p.months, 2)
        XCTAssertEqual(p.togetherLabel, "All available")
        XCTAssertEqual(p.markColor, "color.primary")
        XCTAssertEqual(p.togetherColor, "color.accent")
        XCTAssertTrue(p.surfacePaper)
        XCTAssertEqual(p.helpLabel, "Help")
        XCTAssertFalse(p.checkout)
        XCTAssertEqual(p.colourToken(0), "color.primary")
        XCTAssertEqual(CmsAvailability.listOf(["A", "B", "C"]), "A, B and C")
        XCTAssertEqual(CmsAvailability.listOf(["A"]), "A")
    }
}
