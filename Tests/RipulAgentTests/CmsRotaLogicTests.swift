import XCTest
@testable import RipulAgent

/// The cases of rotaBuilder.test.ts, on the native port (CmsRotaLogic.swift).
final class CmsRotaLogicTests: XCTestCase {
    private var n = 0
    private func makeId() -> String { n += 1; return "s\(n)" }

    private func person(_ code: String, _ name: String, _ extra: [String: CmsJSON] = [:], _ avail: [[String: CmsJSON]] = []) -> Rota.Person {
        var row: [String: CmsJSON] = ["employee_code": .string(code), "name": .string(name), "rate": .number(12), "rate_unit": .string("Hourly")]
        if !extra.isEmpty { row["pref_code"] = .string(code) }
        row.merge(extra) { $1 }
        let weeks = CmsRotaTeamBlockView.weeks(avail.map { var a = $0; a["employee_code"] = .string(code); return a })
        return Rota.person(row, week: weeks[code])!
    }
    private func off(_ code: String, _ from: String, _ to: String, _ extra: [String: CmsJSON] = [:]) -> Rota.TimeOff {
        var row: [String: CmsJSON] = ["id": .string(code + from), "employee_code": .string(code), "start_date": .string(from), "end_date": .string(to),
                                      "status": .string("approved"), "kind": .string("holiday"), "part": .string("all_day")]
        row.merge(extra) { $1 }
        return CmsRotaTeamBlockView.timeOff(row)!
    }
    private func every(_ n: Int) -> CmsJSON { .object(Dictionary(uniqueKeysWithValues: Rota.weekdays.map { ($0, CmsJSON.number(Double(n))) })) }
    private func ps(_ o: [String: CmsJSON]) -> Rota.PlanShift { Rota.planShift(.object(o))! }
    private var earlyShift: Rota.PlanShift { ps(["id": "early", "name": "Early", "start": "7", "end": "3pm", "breakMinutes": 30, "people": every(1)]) }
    private var lateShift: Rota.PlanShift { ps(["id": "late", "name": "Late", "start": "14:00", "end": "22:00", "breakMinutes": 30, "people": ["fri": 1, "sat": 1, "sun": 1]]) }
    private func inputs(_ shifts: [Rota.PlanShift], special: [Rota.SpecialDay] = []) -> (types: [Rota.ShiftType], needs: [Rota.Need], busy: [Rota.Busy]) {
        Rota.planInputs(Rota.Plan(shifts: shifts, special: special))
    }
    private var week: Rota.Period { Rota.periodFor("2026-10-21", mode: "week") }

    func testPeriodsAndTimes() {
        XCTAssertEqual(week.start, "2026-10-19"); XCTAssertEqual(week.end, "2026-10-26")
        let month = Rota.periodFor("2026-10-21", mode: "month")
        XCTAssertEqual([month.start, month.end, month.label], ["2026-10-01", "2026-11-01", "October 2026"])
        XCTAssertEqual(Rota.movePeriod(week, by: -1).start, "2026-10-12")
        XCTAssertEqual(Rota.movePeriod(Rota.periodFor("2026-01-15", mode: "month"), by: -1).start, "2025-12-01")
        XCTAssertEqual(["7", "7am", "3:30pm", "0700", "15.30", "noon"].map(Rota.normTime), ["07:00", "07:00", "15:30", "07:00", "15:30", ""])
        XCTAssertEqual(Rota.paidHours("07:00", "15:00", 30), 7.5)
        XCTAssertEqual(Rota.paidHours("22:00", "06:00"), 8)
        XCTAssertEqual(Rota.hourlyRate(3500, "Monthly"), 21.54, accuracy: 0.01)
        XCTAssertEqual(Rota.shiftKind("07:00", "15:00"), "early")
        XCTAssertEqual(Rota.shiftKind("14:00", "22:00"), "late")
        XCTAssertEqual(Rota.shiftKind("22:00", "06:00"), "night")
        XCTAssertEqual(Rota.shiftKind("10:00", "16:00", name: "Night porter"), "night")
    }

    func testDemand() {
        let late4 = ps(["id": "late", "name": "Late", "start": "14:00", "end": "22:00", "people": ["sat": 4], "skill": "Keyholder", "skillPeople": 1])
        let i = inputs([earlyShift, late4])
        XCTAssertEqual(Rota.demandFor(["2026-10-24"], types: i.types, needs: i.needs, busy: i.busy).map { $0.type.id + ($0.skill.isEmpty ? "" : ":\($0.skill)") },
                       ["early", "late:Keyholder", "late", "late", "late"])
        XCTAssertEqual(Rota.demandFor(["2026-10-21"], types: i.types, needs: i.needs, busy: i.busy).map(\.type.id), ["early"])

        let special = [Rota.SpecialDay(id: "a", date: "2026-10-24", label: "Half term", extra: 2, shiftId: ""),
                       Rota.SpecialDay(id: "b", date: "2026-10-21", label: "Quiet", extra: -1, shiftId: "early"),
                       Rota.SpecialDay(id: "c", date: "2026-10-20", label: "Party", extra: 2, shiftId: "late")]
        var four = earlyShift; four.people = Dictionary(uniqueKeysWithValues: Rota.weekdays.map { ($0, 4) })
        let j = inputs([four, lateShift], special: special)
        XCTAssertEqual(Rota.demandFor(["2026-10-24"], types: j.types, needs: j.needs, busy: j.busy).filter { $0.type.id == "early" }.count, 6)
        XCTAssertEqual(Rota.demandFor(["2026-10-24"], types: j.types, needs: j.needs, busy: j.busy)[0].busy, "Half term")
        XCTAssertEqual(Rota.demandFor(["2026-10-21"], types: j.types, needs: j.needs, busy: j.busy).count, 3)
        XCTAssertEqual(Rota.demandFor(["2026-10-20"], types: j.types, needs: j.needs, busy: j.busy).filter { $0.type.id == "late" }.count, 2)
        let d = Rota.planDemand(Rota.Plan(shifts: [four], special: special), week)
        XCTAssertEqual(d.places, 29); XCTAssertEqual(d.hours, 217.5)
    }

    func testPlanRoundTripAndSuggestion() {
        var p = Rota.Plan(shifts: [earlyShift], special: [Rota.SpecialDay(id: "a", date: "2026-10-24", label: "x", extra: 1, shiftId: "")], budgetGbp: 700, budgetHours: 70)
        let back = Rota.plan(["plan": .string(Rota.planToJson(p)), "budget_gbp": 700, "budget_hours": 70])
        XCTAssertEqual(back.shifts[0].start, "07:00"); XCTAssertEqual(back.shifts[0].end, "15:00")
        XCTAssertEqual(back.special.count, 1)
        let lenient = Rota.plan(["plan": .string(#"{"shifts":[{"start":"9","end":"5pm","people":{"mon":"2"}}, {"start":"x"}],"special":[{"date":"nope"}]}"#)])
        XCTAssertEqual(lenient.shifts.count, 1); XCTAssertEqual(lenient.shifts[0].people["mon"], 2); XCTAssertEqual(lenient.special.count, 0)
        let next = Rota.carryPlan(back, from: "week", to: Rota.periodFor("2026-11-02", mode: "month"))
        XCTAssertEqual(next.special.count, 0); XCTAssertEqual(next.budgetGbp, 3000)

        var s = earlyShift; s.suggested = true
        p = Rota.Plan(shifts: [s], special: [Rota.SpecialDay(id: "a", date: "2026-10-24", label: "Party", extra: 2, shiftId: "", suggested: true)],
                      suggestion: Rota.Suggestion(from: ["your last 4 weeks", "Bookings.xlsx"], at: "2026-10-15T10:00:00Z", cells: Rota.suggestionCells([earlyShift]), note: "Saturdays busier"))
        let b2 = Rota.plan(["plan": .string(Rota.planToJson(p))])
        XCTAssertEqual(b2.suggestion?.cells.count, 7)
        XCTAssertTrue(b2.shifts[0].suggested); XCTAssertTrue(b2.special[0].suggested)
        let ok = Rota.acceptSuggestion(b2)
        XCTAssertNil(ok.suggestion); XCTAssertFalse(ok.shifts[0].suggested)
    }

    func testPlanFromWorkedAndTeam() {
        var worked: [Rota.Shift] = []
        func add(_ d: String, _ a: String, _ b: String) {
            worked.append(Rota.Shift(id: d + a, rotaId: "", code: "A", date: d, start: a, end: b, breakMinutes: 30, typeId: "", skill: "", siteId: "", hours: 0, cost: 0, source: "worked", note: ""))
        }
        for d in ["2026-10-05", "2026-10-12"] { add(d, "07:00", "15:15"); add(d, "06:45", "15:00"); add(d, "14:00", "22:00") }
        add("2026-10-10", "10:00", "12:00")
        let shifts = Rota.planFromWorked(worked) { "x" }
        XCTAssertEqual(shifts.map { "\($0.name) \($0.start) \($0.end) \($0.people["mon"]!)" }, ["Early 07:00 15:15 2", "Late 14:00 22:00 1"])

        func mk(_ name: String, _ a: String, _ b: String) -> Rota.PlanShift { ps(["id": .string(a), "name": .string(name), "start": .string(a), "end": .string(b), "people": ["mon": 1]]) }
        XCTAssertEqual(Rota.nameByPeriod([mk("Day", "09:00", "18:15"), mk("Day 2", "09:30", "17:15"), mk("Day 4", "11:00", "15:00"), mk("Late", "13:00", "18:15"), mk("Party host", "10:00", "14:00")]).map(\.name),
                       ["Middle", "Middle", "Middle", "Late", "Party host"])
        let team = [person("A", "Ana", ["preferred_shift": "early"], [["weekday": "sun", "kind": "unavailable"]]),
                    person("B", "Ben", ["preferred_shift": "late"], [["weekday": "sun", "kind": "unavailable"]])]
        XCTAssertEqual(Rota.planFromTeam(team) { "x" }.map { "\($0.name) \($0.start) \($0.end) \($0.people["mon"]!) \($0.people["sun"]!)" },
                       ["Early 07:00 15:00 1 0", "Late 14:00 22:00 1 0"])
        XCTAssertEqual(Rota.planFromTeam([person("A", "Ana")]) { "x" }.map(\.name), ["Middle"])
    }

    func testBuildingAWeek() {
        let i = inputs([earlyShift, lateShift])
        let people = [person("A", "Ana", ["target_week_hours": 30]), person("B", "Ben", [:], [["weekday": "sun", "kind": "unavailable"]]),
                      person("C", "Cal", ["preferred_shift": "late"])]
        let timeOff = [off("A", "2026-10-24", "2026-10-24")]
        let r = Rota.build(period: week, rotaId: "r1", people: people, types: i.types, needs: [], busy: [], timeOff: timeOff, budget: nil, makeId: makeId)
        XCTAssertEqual(r.shifts.count, 10)
        XCTAssertTrue(r.shifts.allSatisfy { !$0.code.isEmpty })
        XCTAssertFalse(r.shifts.contains { $0.code == "A" && $0.date == "2026-10-24" })
        XCTAssertFalse(r.shifts.contains { $0.code == "B" && $0.date == "2026-10-25" })
        XCTAssertTrue(r.shifts.filter { $0.typeId == "late" }.map(\.code).contains("C"))
        XCTAssertTrue(r.why.values.contains { $0.contains("prefers lates") })
        let ctx = Rota.Context(period: week, people: people, types: i.types, needs: [], busy: [], timeOff: timeOff)
        XCTAssertTrue(Rota.check(r.shifts, ctx).filter { $0.severity == "error" }.isEmpty)
    }

    func testOpenShiftsAndRules() {
        let day = inputs([ps(["id": "x", "name": "Day", "start": "09:00", "end": "17:00", "people": ["mon": 1]])])
        let r = Rota.build(period: Rota.periodFor("2026-10-19", mode: "week"), rotaId: "r1", people: [person("A", "Ana", [:], [["weekday": "mon", "kind": "unavailable"]])],
                           types: day.types, needs: day.needs, busy: day.busy, timeOff: [], budget: nil, makeId: makeId)
        XCTAssertEqual(r.shifts.count, 1); XCTAssertEqual(r.shifts[0].code, "")
        XCTAssertEqual(r.shifts[0].note, "Nobody free: 1 unavailable on Mondays")

        var keyed = earlyShift; keyed.skill = "keyholder"; keyed.skillPeople = 1
        let k = inputs([keyed])
        let r2 = Rota.build(period: week, rotaId: "r1", people: [person("A", "Ana", ["days_off": "2026-10-21; 2026-10-24 to 2026-10-25"]), person("K", "Kim")],
                            types: k.types, needs: k.needs, busy: k.busy, timeOff: [], budget: nil, makeId: makeId)
        XCTAssertFalse(r2.shifts.filter { $0.code == "A" }.contains { ["2026-10-21", "2026-10-24", "2026-10-25"].contains($0.date) })
        XCTAssertTrue(r2.shifts.allSatisfy { !$0.code.isEmpty })

        let pair = inputs([ps(["id": "mon", "name": "Day", "start": "09:00", "end": "17:00", "people": ["mon": 2]])])
        let r3 = Rota.build(period: week, rotaId: "r1", people: [person("A", "Ana", ["target_week_hours": 8]), person("B", "Ben", ["target_week_hours": 8, "works_with": "Ana (A)"]),
                                                                person("C", "Cat", ["target_week_hours": 8])],
                            types: pair.types, needs: pair.needs, busy: pair.busy, timeOff: [], budget: nil, makeId: makeId)
        XCTAssertEqual(r3.shifts.map(\.code).sorted(), ["A", "B"])
        XCTAssertTrue(r3.why.values.joined(separator: " ").contains("works well with"))

        let long = inputs([ps(["id": "long", "name": "Long", "start": "08:00", "end": "18:00", "people": every(1)])])
        let r4 = Rota.build(period: week, rotaId: "r1", people: [person("Y", "Yas", ["under_18": 1])], types: long.types, needs: long.needs, busy: long.busy,
                            timeOff: [], budget: nil, makeId: makeId)
        XCTAssertTrue(r4.shifts.allSatisfy { $0.code.isEmpty })

        let r5 = Rota.build(period: week, rotaId: "r1", people: [person("A", "Ana", ["target_week_hours": 37.5]), person("B", "Ben", ["target_week_hours": 15])],
                            types: [inputs([earlyShift]).types[0]], needs: [], busy: [], timeOff: [], budget: nil, makeId: makeId)
        func hours(_ c: String) -> Double { r5.shifts.filter { $0.code == c }.reduce(0) { $0 + $1.hours } }
        XCTAssertGreaterThan(hours("A"), hours("B")); XCTAssertGreaterThan(hours("B"), 0)
    }

    func testCopying() {
        let people = [person("A", "Ana"), person("B", "Ben")]
        func s(_ id: String, _ code: String, _ date: String, _ br: Int = 30, name: String? = nil) -> Rota.Shift {
            Rota.Shift(id: id, rotaId: "old", code: code, date: date, start: "09:00", end: "17:00", breakMinutes: br, typeId: "", skill: "", siteId: "",
                       hours: br == 0 ? 8 : 7.5, cost: 90, source: "build", note: "", name: name)
        }
        let last = [s("x1", "A", "2026-10-13"), s("x2", "B", "2026-10-14"), s("x3", "Z", "2026-10-15", 0, name: "Zoe")]
        let out = Rota.copyForward(last, to: week, people: people, timeOff: [off("B", "2026-10-21", "2026-10-21")], rotaId: "new", makeId: makeId)
        XCTAssertEqual(out.map { "\($0.date) \($0.code)" }, ["2026-10-20 A", "2026-10-21 ", "2026-10-22 "])
        XCTAssertEqual(out[1].note, "Was Ben's: on holiday")
        XCTAssertEqual(out[2].note, "Was Zoe's: no longer active")
        let nov = Rota.periodFor("2026-11-10", mode: "month")
        var a = last[0]; a.date = "2026-10-05"
        var b = last[0]; b.id = "y"; b.date = "2026-10-26"
        XCTAssertEqual(Rota.copyForward([a, b], to: nov, people: people, timeOff: [], rotaId: "m", makeId: makeId).map(\.date), ["2026-11-02", "2026-11-23", "2026-11-30"])
        let worked = Rota.shiftsFromWorked([["employee_code": "A", "user_name": "Ana", "clocked_in_at": "2026-10-13T08:02:00Z", "clocked_out_at": "2026-10-13T16:31:00Z", "hours_worked": 8],
                                            ["employee_code": "B", "clocked_in_at": "2026-10-13T08:00:00Z"]], people: people)
        XCTAssertEqual(worked.count, 1); XCTAssertEqual(worked[0].hours, 8)
    }

    func testChecksSummaryAndFile() {
        let people = [person("A", "Ana", ["max_week_hours": 10])]
        let early = inputs([earlyShift]).types[0]
        func s(_ id: String, _ date: String, _ code: String = "A") -> Rota.Shift {
            Rota.Shift(id: id, rotaId: "r", code: code, date: date, start: "09:00", end: "17:00", breakMinutes: 0, typeId: "early", skill: "", siteId: "", hours: 8, cost: 96, source: "hand", note: "")
        }
        let w = Rota.check([s("1", "2026-10-19"), s("2", "2026-10-20"), s("3", "2026-10-21", "")],
                           Rota.Context(period: week, people: people, types: [early], needs: [], busy: [],
                                        timeOff: [off("A", "2026-10-19", "2026-10-19", ["status": "requested"])], budget: Rota.Budget(gbp: 100, hours: nil, note: "")))
        XCTAssertEqual(w[0].severity, "error")
        let texts = w.map(\.text)
        XCTAssertTrue(texts.contains("Ana, Tue 20 Oct Early 09:00–17:00: at their limit of 10h a week"))
        XCTAssertTrue(texts.contains("Over budget by £92.00 (£192.00 of £100.00)"))
        XCTAssertTrue(texts.contains("Ana has asked for Mon 19 Oct off"))
        XCTAssertTrue(texts.contains { $0.hasPrefix("Open shift, Wed 21 Oct") })

        let shifts = [s("1", "2026-10-19"), s("2", "2026-10-20", "")]
        let sum = Rota.summarise(shifts, Rota.Context(period: week, people: people, types: [], needs: [], busy: [], timeOff: []))
        XCTAssertEqual([sum.shifts, sum.open, sum.people], [2, 1, 1]); XCTAssertEqual(sum.hours, 8); XCTAssertEqual(sum.cost, 96)
        let csv = Rota.csv(shifts, nameOf: { _ in "Ana, B" }, typeName: { _ in "Early" })
        XCTAssertEqual(csv.split(separator: "\n")[1], #""Ana, B",A,2026-10-19,Monday,09:00,17:00,0,8,Early,,"#)
        XCTAssertEqual(csv.trimmingCharacters(in: .newlines).split(separator: "\n").count, 2)

        let am = off("A", "2026-10-19", "2026-10-19", ["part": "am"])
        XCTAssertNotNil(Rota.timeOffClash("A", date: "2026-10-19", start: "09:00", end: "12:00", [am]))
        XCTAssertNil(Rota.timeOffClash("A", date: "2026-10-19", start: "14:00", end: "20:00", [am]))
    }
}

// Literals for test fixtures only.
extension CmsJSON: @retroactive ExpressibleByStringLiteral, @retroactive ExpressibleByIntegerLiteral,
                   @retroactive ExpressibleByFloatLiteral, @retroactive ExpressibleByBooleanLiteral,
                   @retroactive ExpressibleByDictionaryLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(dictionaryLiteral elements: (String, CmsJSON)...) { self = .object(Dictionary(elements, uniquingKeysWith: { $1 })) }
}
