import Foundation

/// The rota builder's logic, ported function for function from
/// `rotaBuilder.ts` (and the parts of `rotaPreferences.ts` it reads): periods
/// and times, the plan, demand, who can work a shift and who fits best,
/// building, copying, checking and the file Reconcile reads. Pure, so the
/// block and `CmsRotaLogicTests` (the cases of rotaBuilder.test.ts) share it.
enum Rota {
    typealias TimeOff = CmsRotaTeamBlockView.TimeOff
    typealias Day = CmsRotaTeamBlockView.Day

    static let weekdays = CmsRotaTeamBlockView.weekdays
    static let weekdayLabel = CmsRotaTeamBlockView.weekdayLabel
    static let legal = (minRestHours: 11.0, maxShiftHours: 10.0, under18MaxDay: 8.0, under18MaxWeek: 40.0, weekAverageMax: 48.0)

    static func round2(_ n: Double) -> Double { (n * 100).rounded() / 100 }
    static func str(_ v: CmsJSON?) -> String {
        guard let v, v != .null else { return "" }
        return v.displayString.trimmingCharacters(in: .whitespaces)
    }
    static func num(_ v: CmsJSON?) -> Double? {
        let s = str(v)
        return s.isEmpty ? nil : Double(s).flatMap { $0.isFinite ? $0 : nil }
    }

    // MARK: - Dates

    static func parse(_ s: String) -> Date { CmsFileWeeks.parse(s) }
    static func iso(_ d: Date) -> String { CmsFileWeeks.iso(d) }
    static func addDays(_ s: String, _ n: Int) -> String { iso(CmsFileWeeks.addDays(parse(s), n)) }
    static func weekdayOf(_ s: String) -> String {
        weekdays[(Calendar(identifier: .gregorian).component(.weekday, from: parse(s)) + 5) % 7]
    }
    static func mondayOf(_ s: String) -> String { iso(CmsFileWeeks.mondayOf(parse(s))) }
    static func datesBetween(_ from: String, _ to: String) -> [String] {
        var out: [String] = []
        var d = from
        while d < to && out.count < 400 { out.append(d); d = addDays(d, 1) }
        return out
    }
    static func dayLabelShort(_ s: String) -> String {
        parse(s).formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(Locale(identifier: "en_GB")))
    }

    struct Period: Equatable {
        var mode: String   // week | month
        var start: String
        var end: String
        var label: String
    }

    static func periodFor(_ anchor: String, mode: String) -> Period {
        if mode == "week" {
            let start = mondayOf(anchor), end = addDays(start, 7)
            return Period(mode: mode, start: start, end: end, label: CmsRotaTeamBlockView.rangeLabel(start, addDays(end, -1)))
        }
        let cal = Calendar(identifier: .gregorian)
        let d = parse(anchor)
        let first = cal.date(from: cal.dateComponents([.year, .month], from: d))!
        let next = cal.date(byAdding: .month, value: 1, to: first)!
        return Period(mode: mode, start: iso(first), end: iso(next),
                      label: first.formatted(.dateTime.month(.wide).year().locale(Locale(identifier: "en_GB"))))
    }

    static func movePeriod(_ p: Period, by: Int) -> Period {
        if p.mode == "week" { return periodFor(addDays(p.start, 7 * by), mode: "week") }
        let d = Calendar(identifier: .gregorian).date(byAdding: .month, value: by, to: parse(p.start))!
        return periodFor(iso(d), mode: "month")
    }

    // MARK: - Times

    /// "7", "7am", "0700", "15.30", "3:30pm" → "HH:MM"; "" when it is not a time.
    static func normTime(_ v: String) -> String {
        let s = v.lowercased().replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        guard let m = s.wholeMatch(of: #/^(\d{1,2})(?:[:.]?(\d{2}))?(am|pm)?$/#) else { return "" }
        var h = Int(m.output.1)!
        let min = m.output.2.map { Int($0)! } ?? 0
        if m.output.3 == "pm" && h < 12 { h += 12 }
        if m.output.3 == "am" && h == 12 { h = 0 }
        if h > 24 || min > 59 { return "" }
        if h == 24 { h = 0 }
        return String(format: "%02d:%02d", h, min)
    }
    static func minutesOf(_ t: String) -> Int {
        let p = t.split(separator: ":").map { Int($0) ?? 0 }
        return (p.first ?? 0) * 60 + (p.count > 1 ? p[1] : 0)
    }
    static func spanMinutes(_ start: String, _ end: String) -> Int {
        let a = minutesOf(start), b = minutesOf(end)
        return b > a ? b - a : b + 24 * 60 - a
    }
    static func paidHours(_ start: String, _ end: String, _ breakMinutes: Int = 0) -> Double {
        guard !start.isEmpty, !end.isEmpty else { return 0 }
        return round2(Double(max(0, spanMinutes(start, end) - breakMinutes)) / 60)
    }
    static func timeRange(_ start: String, _ end: String, compact: Bool = false) -> String {
        guard compact else { return "\(start)–\(end)" }
        func c(_ t: String) -> String {
            let p = t.split(separator: ":")
            guard p.count == 2 else { return t }
            return p[1] == "00" ? String(Int(p[0]) ?? 0) : "\(Int(p[0]) ?? 0):\(p[1])"
        }
        return "\(c(start))–\(c(end))"
    }
    static func hourlyRate(_ rate: Double?, _ unit: String, weekHours: Double = 37.5) -> Double {
        guard let rate, rate != 0 else { return 0 }
        let u = unit.lowercased()
        if u.isEmpty || u.hasPrefix("hour") { return rate }
        if u.hasPrefix("day") { return rate / 7.5 }
        if u.hasPrefix("week") { return rate / weekHours }
        if u.hasPrefix("fortnight") { return rate / 2 / weekHours }
        if u.hasPrefix("month") { return rate * 12 / 52 / weekHours }
        if u.hasPrefix("year") || u.hasPrefix("annual") { return rate / 52 / weekHours }
        return rate
    }
    static func hhmm(_ mins: Int) -> String {
        let m = ((mins % 1440) + 1440) % 1440
        return String(format: "%02d:%02d", m / 60, m % 60)
    }
    static func formatHours(_ n: Double) -> String {
        let r = round2(n)
        if r.rounded() == r { return "\(Int(r))h" }
        var t = String(format: "%.1f", r)
        if t.hasSuffix(".0") { t.removeLast(2) }
        return "\(t)h"
    }
    static func formatMoney(_ n: Double) -> String {
        "£" + n.formatted(.number.precision(.fractionLength(2)).locale(Locale(identifier: "en_GB")))
    }
    static func pounds(_ n: Double) -> String {
        "£" + n.rounded().formatted(.number.precision(.fractionLength(0)).locale(Locale(identifier: "en_GB")))
    }

    // MARK: - Preferences (rotaPreferences.ts)

    struct Prefs: Equatable {
        var targetWeek, minWeek, maxWeek, targetMonth, maxDays, maxShift, minShift, minRest, minNoticeDays: Double?
        var optOut48 = false, under18 = false
        var skills = "", preferredShift = "", shiftLength = "", daysOff = "", worksWith = "", note = ""
    }

    struct DayOff: Equatable { var from: String; var to: String }

    struct Person: Equatable, Identifiable {
        var id: String { code }
        var code: String
        var name: String
        var headshot: String
        var jobType: String
        var rate: Double
        var skills: [String]
        var daysOff: [DayOff]
        var siteId: String
        var prefs: Prefs
        var week: [String: Day]
    }

    static func truthy(_ v: CmsJSON?) -> Bool { ["1", "true", "Y"].contains(str(v)) }

    /// `personFromRow` + `rotaPerson`.
    static func person(_ r: [String: CmsJSON], week: [String: Day]?) -> Person? {
        let code = str(r["employee_code"])
        guard !code.isEmpty else { return nil }
        let p = Prefs(
            targetWeek: num(r["target_week_hours"]), minWeek: num(r["min_week_hours"]), maxWeek: num(r["max_week_hours"]),
            targetMonth: num(r["target_month_hours"]), maxDays: num(r["max_days_week"]), maxShift: num(r["max_shift_hours"]),
            minShift: num(r["min_shift_hours"]), minRest: num(r["min_rest_hours"]), minNoticeDays: num(r["min_notice_days"]),
            optOut48: truthy(r["opt_out_48h"]), under18: truthy(r["under_18"]), skills: str(r["skills"]),
            preferredShift: str(r["preferred_shift"]), shiftLength: str(r["shift_length"]), daysOff: str(r["days_off"]),
            worksWith: str(r["works_with"]), note: str(r["note"]))
        return Person(
            code: code, name: str(r["name"]).isEmpty ? code : str(r["name"]), headshot: str(r["headshot"]), jobType: str(r["job_type_code"]),
            rate: round2(hourlyRate(num(r["rate"]), str(r["rate_unit"]), weekHours: p.targetWeek ?? 37.5)),
            skills: p.skills.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty },
            daysOff: daysOffDates(p.daysOff), siteId: str(r["site_id"]), prefs: p,
            week: week ?? CmsRotaTeamBlockView.blankWeek())
    }

    static func daysOffDates(_ text: String) -> [DayOff] {
        var out: [DayOff] = []
        for part in text.split(whereSeparator: { $0 == ";" || $0 == "\n" }) {
            let days = String(part).matches(of: #/\d{4}-\d{2}-\d{2}/#).map { String($0.output) }
            guard let from = days.first else { continue }
            let to = days.count > 1 ? days[1] : from
            out.append(from <= to ? DayOff(from: from, to: to) : DayOff(from: to, to: from))
        }
        return out.sorted { $0.from < $1.from }
    }

    static func onDayOff(_ date: String, _ ranges: [DayOff]) -> Bool { ranges.contains { date >= $0.from && date <= $0.to } }

    /// `worksWithCodes`.
    static func worksWithCodes(_ text: String, team: [Person]) -> [String] {
        var codes: [String] = []
        let parts = text.replacingOccurrences(of: #"\band\b"#, with: ",", options: [.regularExpression, .caseInsensitive])
            .split(whereSeparator: { ",;\n".contains($0) })
        for raw in parts {
            let part = raw.trimmingCharacters(in: .whitespaces)
            guard !part.isEmpty else { continue }
            let inBrackets = part.firstMatch(of: #/\(([^)]+)\)\s*$/#).map { String($0.output.1).trimmingCharacters(in: .whitespaces) }
            if let p = team.first(where: { !$0.code.isEmpty && ($0.code == inBrackets || $0.code == part) }) { if !codes.contains(p.code) { codes.append(p.code) }; continue }
            let name = part.replacingOccurrences(of: #"\([^)]*\)\s*$"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces).lowercased()
            if let p = team.first(where: { $0.name.trimmingCharacters(in: .whitespaces).lowercased() == name }) { if !codes.contains(p.code) { codes.append(p.code) }; continue }
            let first = name.split(separator: " ").first.map(String.init) ?? ""
            let same = team.filter { ($0.name.lowercased().split(separator: " ").first.map(String.init) ?? "") == first }
            if same.count == 1, !codes.contains(same[0].code) { codes.append(same[0].code) }
        }
        return codes
    }

    // MARK: - The plan

    struct PlanShift: Equatable, Identifiable {
        var id: String
        var name: String
        var start: String
        var end: String
        var breakMinutes: Int
        var people: [String: Int]
        var skill: String
        var skillPeople: Int
        var siteId: String
        var suggested = false
    }
    struct SpecialDay: Equatable, Identifiable {
        var id: String
        var date: String
        var label: String
        var extra: Int
        var shiftId: String
        var suggested = false
    }
    struct Suggestion: Equatable { var from: [String]; var at: String; var cells: [String]; var note: String }
    struct Source: Equatable { var kind: String; var name: String; var at: String; var fileId: String? }
    struct Plan: Equatable {
        var shifts: [PlanShift] = []
        var special: [SpecialDay] = []
        var budgetGbp: Double?
        var budgetHours: Double?
        var sources: [Source] = []
        var suggestion: Suggestion?
    }

    static func noPeople() -> [String: Int] { Dictionary(uniqueKeysWithValues: weekdays.map { ($0, 0) }) }
    static func planId(_ company: String, _ mode: String, _ start: String) -> String { "\(company)|\(mode)|\(start)" }

    static func newId(_ prefix: String = "rs") -> String {
        let chars = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        return prefix + "_" + String((0..<9).map { _ in chars[Int.random(in: 0..<36)] })
    }

    private static func json(_ v: CmsJSON?) -> CmsJSON? {
        if case .string(let s)? = v { return s.data(using: .utf8).flatMap { try? JSONDecoder().decode(CmsJSON.self, from: $0) } }
        return v
    }

    static func planShift(_ v: CmsJSON, _ i: Int = 0) -> PlanShift? {
        guard let o = v.objectValue else { return nil }
        let start = normTime(str(o["start"])), end = normTime(str(o["end"]))
        guard !start.isEmpty, !end.isEmpty else { return nil }
        let raw = o["people"]?.objectValue ?? [:]
        var people = noPeople()
        for d in weekdays { people[d] = max(0, Int((num(raw[d]) ?? 0).rounded())) }
        let skill = str(o["skill"])
        return PlanShift(id: str(o["id"]).isEmpty ? "shift_\(i + 1)" : str(o["id"]), name: str(o["name"]), start: start, end: end,
                         breakMinutes: max(0, Int((num(o["breakMinutes"] ?? o["break_minutes"]) ?? 0).rounded())), people: people,
                         skill: skill, skillPeople: skill.isEmpty ? 0 : max(1, Int((num(o["skillPeople"]) ?? 1).rounded())),
                         siteId: str(o["siteId"]), suggested: o["suggested"] == .bool(true))
    }

    /// `planFromRow`, read leniently: the agent writes it too.
    static func plan(_ r: [String: CmsJSON]) -> Plan {
        let raw = json(r["plan"])?.objectValue ?? [:]
        var p = Plan()
        if case .array(let list)? = raw["shifts"] { p.shifts = nameByPeriod(list.enumerated().compactMap { planShift($0.element, $0.offset) }) }
        if case .array(let list)? = raw["special"] {
            p.special = list.enumerated().compactMap { i, x in
                guard let o = x.objectValue else { return nil }
                let date = String(str(o["date"]).prefix(10))
                guard date.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
                return SpecialDay(id: str(o["id"]).isEmpty ? "day_\(i + 1)" : str(o["id"]), date: date, label: str(o["label"]),
                                  extra: Int((num(o["extra"]) ?? 0).rounded()), shiftId: str(o["shiftId"]), suggested: o["suggested"] == .bool(true))
            }
        }
        if case .array(let list)? = raw["sources"] {
            p.sources = list.compactMap { x in
                guard let o = x.objectValue, ["file", "note", "calendar", "booking"].contains(str(o["kind"])) else { return nil }
                return Source(kind: str(o["kind"]), name: str(o["name"]), at: str(o["at"]), fileId: str(o["fileId"]).isEmpty ? nil : str(o["fileId"]))
            }
        }
        if let sg = raw["suggestion"]?.objectValue {
            func list(_ v: CmsJSON?) -> [String] { if case .array(let a)? = v { return a.map { str($0) }.filter { !$0.isEmpty } } else { return [] } }
            p.suggestion = Suggestion(from: list(sg["from"]), at: str(sg["at"]), cells: list(sg["cells"]), note: str(sg["note"]))
        }
        p.budgetGbp = num(r["budget_gbp"]) ?? num(raw["budgetGbp"])
        p.budgetHours = num(r["budget_hours"]) ?? num(raw["budgetHours"])
        return p
    }

    static func planToJson(_ p: Plan) -> String {
        func shift(_ s: PlanShift) -> CmsJSON {
            var o: [String: CmsJSON] = [
                "id": .string(s.id), "name": .string(s.name), "start": .string(s.start), "end": .string(s.end),
                "breakMinutes": .number(Double(s.breakMinutes)),
                "people": .object(Dictionary(uniqueKeysWithValues: weekdays.map { ($0, CmsJSON.number(Double(s.people[$0] ?? 0))) })),
                "skill": .string(s.skill), "skillPeople": .number(Double(s.skillPeople)), "siteId": .string(s.siteId),
            ]
            if s.suggested { o["suggested"] = .bool(true) }
            return .object(o)
        }
        var root: [String: CmsJSON] = [
            "shifts": .array(p.shifts.map(shift)),
            "special": .array(p.special.map { d in
                var o: [String: CmsJSON] = ["id": .string(d.id), "date": .string(d.date), "label": .string(d.label),
                                            "extra": .number(Double(d.extra)), "shiftId": .string(d.shiftId)]
                if d.suggested { o["suggested"] = .bool(true) }
                return .object(o)
            }),
            "sources": .array(p.sources.map { s in
                var o: [String: CmsJSON] = ["kind": .string(s.kind), "name": .string(s.name), "at": .string(s.at)]
                if let f = s.fileId { o["fileId"] = .string(f) }
                return .object(o)
            }),
        ]
        if let sg = p.suggestion {
            root["suggestion"] = .object(["from": .array(sg.from.map { .string($0) }), "at": .string(sg.at),
                                          "cells": .array(sg.cells.map { .string($0) }), "note": .string(sg.note)])
        }
        let data = (try? JSONEncoder().encode(CmsJSON.object(root))) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func suggestionCells(_ shifts: [PlanShift]) -> [String] {
        shifts.flatMap { s in weekdays.filter { (s.people[$0] ?? 0) > 0 }.map { "\(s.id)|\($0)" } }
    }

    static func acceptSuggestion(_ p: Plan) -> Plan {
        var out = p
        out.suggestion = nil
        out.shifts = p.shifts.map { var x = $0; x.suggested = false; return x }
        out.special = p.special.map { var x = $0; x.suggested = false; return x }
        return out
    }

    static func carryPlan(_ prev: Plan, from: String, to: Period) -> Plan {
        let days = Double(datesBetween(to.start, to.end).count)
        let scale = from == to.mode ? 1 : (to.mode == "month" ? days / 7 : 12.0 / 52)
        let clean = acceptSuggestion(prev)
        return Plan(shifts: clean.shifts, special: [], budgetGbp: prev.budgetGbp.map { round2($0 * scale) },
                    budgetHours: prev.budgetHours.map { round2($0 * scale) }, sources: [])
    }

    struct ShiftType: Equatable, Identifiable {
        var id: String
        var name: String
        var start: String
        var end: String
        var breakMinutes: Int
        var days: [String]?
        var siteId: String
        var sort: Int
    }
    struct Need { var shiftTypeId: String; var days: [String]?; var people: Int; var skill: String; var siteId: String }
    struct Busy { var from: String; var to: String; var kind: String; var extra: Int; var percent: Double; var label: String; var siteId: String; var shiftTypeId: String? }
    struct Budget { var gbp: Double?; var hours: Double?; var note: String }

    static func planInputs(_ plan: Plan) -> (types: [ShiftType], needs: [Need], busy: [Busy]) {
        var types: [ShiftType] = [], needs: [Need] = []
        for (i, s) in plan.shifts.enumerated() {
            let days = weekdays.filter { (s.people[$0] ?? 0) > 0 }
            types.append(ShiftType(id: s.id, name: s.name.isEmpty ? timeRange(s.start, s.end) : s.name, start: s.start, end: s.end,
                                   breakMinutes: s.breakMinutes, days: days.count == 7 ? nil : days, siteId: s.siteId, sort: i))
            for d in days {
                let n = s.people[d] ?? 0
                let skilled = s.skill.isEmpty ? 0 : min(max(s.skillPeople, 1), n)
                if skilled > 0 { needs.append(Need(shiftTypeId: s.id, days: [d], people: skilled, skill: s.skill, siteId: s.siteId)) }
                if n - skilled > 0 { needs.append(Need(shiftTypeId: s.id, days: [d], people: n - skilled, skill: "", siteId: s.siteId)) }
            }
        }
        let busy = plan.special.map { d in
            Busy(from: d.date, to: d.date, kind: d.extra < 0 ? "quiet" : "busy", extra: abs(d.extra), percent: 0, label: d.label,
                 siteId: "", shiftTypeId: d.shiftId.isEmpty ? nil : d.shiftId)
        }
        return (types, needs, busy)
    }

    static func budgetOf(_ plan: Plan, _ p: Period) -> Budget {
        Budget(gbp: plan.budgetGbp, hours: plan.budgetHours, note: p.mode == "week" ? "this week's budget" : "this month's budget")
    }

    static func planDemand(_ plan: Plan, _ p: Period) -> (places: Int, hours: Double) {
        let i = planInputs(plan)
        let slots = demandFor(datesBetween(p.start, p.end), types: i.types, needs: i.needs, busy: i.busy)
        return (slots.count, round2(slots.reduce(0) { $0 + paidHours($1.type.start, $1.type.end, $1.type.breakMinutes) }))
    }

    /// `planFromWorked`: the usual shifts and numbers from what was worked.
    static func planFromWorked(_ worked: [Shift], makeId: () -> String = { newId("sh") }) -> [PlanShift] {
        let weeks = max(1, Set(worked.map { mondayOf($0.date) }).count)
        var clusters: [(a: Int, b: Int, list: [Shift])] = []
        for s in worked.sorted(by: { $0.start < $1.start }) {
            let a = minutesOf(s.start), b = a + spanMinutes(s.start, s.end)
            if let i = clusters.firstIndex(where: { abs($0.a - a) <= 30 && abs($0.b - b) <= 30 }) { clusters[i].list.append(s) } else { clusters.append((a, b, [s])) }
        }
        func median(_ xs: [Int]) -> Int { let s = xs.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
        func quarter(_ m: Int) -> String { hhmm(Int((Double(m) / 15).rounded()) * 15) }
        var groups: [(key: String, list: [Shift])] = []
        for c in clusters {
            let key = "\(quarter(median(c.list.map { minutesOf($0.start) })))-\(quarter(median(c.list.map { minutesOf($0.start) + spanMinutes($0.start, $0.end) })))"
            if let i = groups.firstIndex(where: { $0.key == key }) { groups[i].list = c.list } else { groups.append((key, c.list)) }
        }
        var out: [PlanShift] = []
        let ranked = groups.filter { $0.list.count >= 2 }.enumerated().sorted { a, b in
            a.element.list.count != b.element.list.count ? a.element.list.count > b.element.list.count : a.offset < b.offset
        }.prefix(6).map(\.element)
        for g in ranked {
            let parts = g.key.split(separator: "-").map(String.init)
            var people = noPeople()
            for d in weekdays { people[d] = Int((Double(g.list.filter { weekdayOf($0.date) == d }.count) / Double(weeks)).rounded()) }
            guard weekdays.contains(where: { (people[$0] ?? 0) > 0 }) else { continue }
            let breaks = g.list.map(\.breakMinutes).sorted()
            out.append(PlanShift(id: makeId(), name: "", start: parts[0], end: parts[1], breakMinutes: breaks.isEmpty ? 0 : breaks[breaks.count / 2],
                                 people: people, skill: "", skillPeople: 0, siteId: ""))
        }
        return nameByPeriod(out.sorted { $0.start < $1.start })
    }

    /// `planFromTeam`: one shift per part of the day people prefer.
    static func planFromTeam(_ people: [Person], makeId: () -> String = { newId("sh") }) -> [PlanShift] {
        let times = ["early": ("07:00", "15:00"), "middle": ("09:00", "17:00"), "late": ("14:00", "22:00"), "night": ("22:00", "06:00")]
        let kinds = ["early", "middle", "late", "night"].filter { k in people.contains { $0.prefs.preferredShift == k } }
        let use = kinds.isEmpty ? ["middle"] : kinds
        return nameByPeriod(use.map { k in
            let pref = people.filter { kinds.isEmpty || $0.prefs.preferredShift == k || $0.prefs.preferredShift.isEmpty || $0.prefs.preferredShift == "any" }
            let pool = pref.isEmpty ? people : pref
            var n = noPeople()
            for d in weekdays { n[d] = pool.contains { $0.week[d]?.kind != "unavailable" } ? 1 : 0 }
            return PlanShift(id: makeId(), name: "", start: times[k]!.0, end: times[k]!.1, breakMinutes: 30, people: n,
                             skill: "", skillPeople: 0, siteId: "", suggested: true)
        })
    }

    static let periodName = ["early": "Early", "middle": "Middle", "late": "Late", "night": "Night"]

    static func nameByPeriod(_ shifts: [PlanShift]) -> [PlanShift] {
        shifts.map { x in
            let auto = x.name.trimmingCharacters(in: .whitespaces)
                .wholeMatch(of: #/^(?:|(?:Early|Day|Middle|Late|Night)(?: \d+| \(\d\d:\d\d\))?)$/#) != nil
            guard auto else { return x }
            var y = x
            y.name = periodName[shiftKind(x.start, x.end)]!
            return y
        }
    }

    static func shiftKind(_ start: String, _ end: String, name: String = "") -> String {
        let n = name.lowercased()
        if n.contains("night") { return "night" }
        if n.range(of: "early|morning|open", options: .regularExpression) != nil { return "early" }
        if n.range(of: "late|evening|close", options: .regularExpression) != nil { return "late" }
        if n.range(of: "mid|middle|day", options: .regularExpression) != nil { return "middle" }
        let a = minutesOf(start), e = a + spanMinutes(start, end)
        if e > 26 * 60 || a >= 21 * 60 { return "night" }
        if a < 9 * 60 { return "early" }
        if a >= 12 * 60 { return "late" }
        return "middle"
    }

    // MARK: - Shifts

    struct Shift: Equatable, Identifiable {
        var id: String
        var rotaId: String
        var code: String
        var date: String
        var start: String
        var end: String
        var breakMinutes: Int
        var typeId: String
        var skill: String
        var siteId: String
        var hours: Double
        var cost: Double
        var source: String
        var note: String
        var name: String?
        var rotaStatus: String?
    }

    static func shift(_ r: [String: CmsJSON]) -> Shift? {
        let id = str(r["id"]), date = String(str(r["shift_date"]).prefix(10))
        let start = normTime(str(r["start_time"])), end = normTime(str(r["end_time"]))
        guard !id.isEmpty, !date.isEmpty, !start.isEmpty, !end.isEmpty else { return nil }
        let br = max(0, Int((num(r["break_minutes"]) ?? 0).rounded()))
        return Shift(id: id, rotaId: str(r["rota_id"]), code: str(r["employee_code"]), date: date, start: start, end: end, breakMinutes: br,
                     typeId: str(r["shift_type_id"]), skill: str(r["skill"]), siteId: str(r["site_id"]),
                     hours: num(r["hours"]) ?? paidHours(start, end, br), cost: num(r["cost"]) ?? 0, source: str(r["source"]),
                     note: str(r["note"]), name: str(r["name"]).isEmpty ? nil : str(r["name"]),
                     rotaStatus: str(r["rota_status"]).isEmpty ? nil : str(r["rota_status"]))
    }

    static func shiftRow(_ s: Shift) -> CmsJSON {
        func opt(_ v: String) -> CmsJSON { v.isEmpty ? .null : .string(v) }
        return .object([
            "id": .string(s.id), "site_id": opt(s.siteId), "employee_code": opt(s.code), "shift_date": .string(s.date),
            "start_time": .string(s.start), "end_time": .string(s.end), "break_minutes": .number(Double(s.breakMinutes)),
            "shift_type_id": opt(s.typeId), "skill": opt(s.skill), "hours": .number(s.hours), "cost": .number(s.cost),
            "source": opt(s.source), "note": opt(s.note),
        ])
    }

    static func compare(_ a: Shift, _ b: Shift) -> Bool {
        if a.date != b.date { return a.date < b.date }
        if a.start != b.start { return a.start < b.start }
        return a.code < b.code
    }

    private static func span(_ date: String, _ start: String, _ end: String, origin: String) -> (Int, Int) {
        let day = Calendar(identifier: .gregorian).dateComponents([.day], from: parse(origin), to: parse(date)).day ?? 0
        let a = day * 1440 + minutesOf(start)
        return (a, a + spanMinutes(start, end))
    }

    // MARK: - Demand

    struct Slot { var date: String; var type: ShiftType; var skill: String; var siteId: String; var busy: String }

    static func demandFor(_ dates: [String], types: [ShiftType], needs: [Need], busy: [Busy], siteId: String = "") -> [Slot] {
        var out: [Slot] = []
        let sorted = types.sorted { $0.sort != $1.sort ? $0.sort < $1.sort : $0.start < $1.start }
        for date in dates {
            let wd = weekdayOf(date)
            for type in sorted {
                if !siteId.isEmpty && !type.siteId.isEmpty && type.siteId != siteId { continue }
                let periods = busy.filter { $0.from <= date && $0.to >= date && ($0.siteId.isEmpty || type.siteId.isEmpty || $0.siteId == type.siteId)
                    && ($0.shiftTypeId == nil || $0.shiftTypeId == type.id) }
                let runs = type.days == nil || type.days!.contains(wd)
                if !runs && !periods.contains(where: { $0.shiftTypeId == type.id && $0.kind == "busy" }) { continue }
                let today = needs.filter { $0.shiftTypeId == type.id && ($0.days == nil || $0.days!.contains(wd)) }
                var groups: [(people: Int, skill: String)] = !runs ? [(0, "")] : (today.isEmpty ? [(1, "")] : today.map { ($0.people, $0.skill) })
                for b in periods {
                    let sign = b.kind == "quiet" ? -1.0 : 1.0
                    if b.percent != 0 { for i in groups.indices { groups[i].people = max(0, Int((Double(groups[i].people) * (1 + sign * abs(b.percent) / 100)).rounded())) } }
                    if b.extra != 0 {
                        let i = groups.firstIndex { $0.skill.isEmpty } ?? 0
                        groups[i].people = max(0, groups[i].people + Int(sign) * abs(b.extra))
                    }
                }
                let label = periods.map(\.label).filter { !$0.isEmpty }.joined(separator: ", ")
                for g in groups.enumerated().sorted(by: { a, b in
                    let x = a.element.skill.isEmpty ? 0 : 1, y = b.element.skill.isEmpty ? 0 : 1
                    return x != y ? x > y : a.offset < b.offset
                }).map(\.element) {
                    for _ in 0..<max(0, g.people) { out.append(Slot(date: date, type: type, skill: g.skill, siteId: type.siteId, busy: label)) }
                }
            }
        }
        return out
    }

    // MARK: - Who can work a shift

    static func timeOffClash(_ code: String, date: String, start: String, end: String, _ timeOff: [TimeOff]) -> TimeOff? {
        let (a, b) = span(date, start, end, origin: date)
        let parts: [String: (Int, Int)] = ["am": (0, 13 * 60), "pm": (12 * 60, 24 * 60)]
        return timeOff.first { t in
            guard t.code == code, t.status != "declined", t.kind != "extra" else { return false }
            if t.from > date || t.to < date {
                let next = addDays(date, 1)
                if b <= 1440 || t.from > next || t.to < next { return false }
                return t.part == "all_day" || t.part == "am"
            }
            if t.part == "all_day" || t.part.isEmpty { return true }
            let (x, y) = t.part == "between"
                ? (minutesOf(t.fromTime.isEmpty ? "00:00" : t.fromTime), minutesOf(t.toTime.isEmpty ? "23:59" : t.toTime))
                : (parts[t.part] ?? (0, 1440))
            return a < y && b > x
        }
    }

    static func canWorkExtra(_ code: String, _ date: String, _ timeOff: [TimeOff]) -> Bool {
        timeOff.contains { $0.code == code && $0.kind == "extra" && $0.status != "declined" && $0.from <= date && $0.to >= date }
    }

    static let kindWord = ["holiday": "on holiday", "sick": "off sick", "unpaid": "on unpaid leave", "training": "at training", "unavailable": "can't work", "other": "off"]

    struct Load {
        var spans: [(Int, Int)] = []
        var weekHours: [String: Double] = [:]
        var weekDays: [String: Set<String>] = [:]
        var hours = 0.0
        var shifts = 0
        var dates: Set<String> = []

        mutating func add(_ date: String, _ start: String, _ end: String, _ hours: Double, origin: String) {
            spans.append(Rota.span(date, start, end, origin: origin))
            let wk = Rota.mondayOf(date)
            weekHours[wk, default: 0] += hours
            weekDays[wk, default: []].insert(date)
            self.hours += hours
            shifts += 1
            dates.insert(date)
        }
    }

    static func loadFrom(_ shifts: [Shift], origin: String) -> Load {
        var l = Load()
        for s in shifts { l.add(s.date, s.start, s.end, s.hours, origin: origin) }
        return l
    }

    static func limits(_ p: Person) -> (maxShift: Double?, maxWeek: Double, maxDays: Double, minRest: Double) {
        let f = p.prefs
        let legalWeek = f.under18 ? legal.under18MaxWeek : (f.optOut48 ? Double.infinity : legal.weekAverageMax)
        return (f.maxShift ?? (f.under18 ? legal.under18MaxDay : nil), min(f.maxWeek ?? .infinity, legalWeek),
                f.maxDays ?? (f.under18 ? 5 : 6), f.minRest ?? (f.under18 ? 12 : legal.minRestHours))
    }

    /// `blockedReason`: why a person cannot work a shift, or nil.
    static func blocked(_ p: Person, date: String, start: String, end: String, hours: Double, siteId: String,
                        load: Load, timeOff: [TimeOff], origin: String) -> String? {
        if !siteId.isEmpty && !p.siteId.isEmpty && siteId != p.siteId { return "works at another site" }
        if onDayOff(date, p.daysOff) { return "has asked for the day off" }
        if let off = timeOffClash(p.code, date: date, start: start, end: end, timeOff), off.status == "approved" { return kindWord[off.kind] ?? "off" }
        let wd = weekdayOf(date)
        let day = p.week[wd] ?? Day()
        if !canWorkExtra(p.code, date, timeOff) {
            if day.kind == "unavailable" { return "unavailable on \(weekdayLabel[wd]!)s" }
            if day.kind == "between", !day.from.isEmpty, !day.to.isEmpty {
                let a = minutesOf(start), b = a + spanMinutes(start, end)
                if a < minutesOf(day.from) || b > minutesOf(day.from) + spanMinutes(day.from, day.to) { return "only free \(day.from)–\(day.to) on \(weekdayLabel[wd]!)s" }
            }
        }
        let lim = limits(p)
        if let ms = lim.maxShift, hours > ms + 0.01 { return "shifts no longer than \(fmt(ms))h" }
        let (a, b) = span(date, start, end, origin: origin)
        let rest = Int(lim.minRest * 60)
        for x in load.spans {
            if a < x.1 && b > x.0 { return "already working then" }
            if (a >= x.1 && a - x.1 < rest) || (x.0 >= b && x.0 - b < rest) { return "needs \(fmt(lim.minRest))h rest between shifts" }
        }
        let wk = mondayOf(date)
        if let days = load.weekDays[wk], !days.contains(date), Double(days.count) >= lim.maxDays { return "at most \(fmt(lim.maxDays)) days a week" }
        if (load.weekHours[wk] ?? 0) + hours > lim.maxWeek + 0.01 { return "at their limit of \(fmt(lim.maxWeek))h a week" }
        return nil
    }

    /// A number as JS prints it: 10, 7.5.
    static func fmt(_ n: Double) -> String { n.rounded() == n ? String(Int(n)) : String(n) }

    // MARK: - Who fits best

    private static func score(_ p: Person, slot s: Slot, hours: Double, load: Load, weeks: Double, tight: Bool, minRate: Double, maxRate: Double,
                              timeOff: [TimeOff], onShift: [(code: String, name: String)], buddies: [String]) -> (Double, [String]) {
        var why: [String] = []
        var score = 0.0
        let f = p.prefs
        let target = weeks > 1.5 ? (f.targetMonth ?? f.targetWeek.map { $0 * weeks }) : f.targetWeek
        if let target, target > 0 {
            let gap = (target - load.hours) / target
            score += 3 * gap
            if load.hours + hours > target + 2 { score -= 2 }
            if gap > 0.3 { why.append("below their \(fmt(target))h target (\(fmt(round2(load.hours)))h so far)") }
        } else {
            let min = weeks > 1.5 ? (f.minWeek ?? 0) * weeks : (f.minWeek ?? 0)
            if min > 0 && load.hours < min { score += 1.5; why.append("under their minimum of \(fmt(min))h") }
            score += 1 - load.hours / (40 * max(1, weeks))
        }
        let kind = shiftKind(s.type.start, s.type.end, name: s.type.name)
        if !f.preferredShift.isEmpty && f.preferredShift != "any" {
            if f.preferredShift == kind { score += 1; why.append("prefers \(kind)s") } else { score -= 0.4 }
        }
        if f.shiftLength == "longer" { score += hours >= 8 ? 0.4 : -0.3 }
        if f.shiftLength == "shorter" { score += hours <= 6 ? 0.4 : -0.3 }
        if let ms = f.minShift, hours < ms { score -= 1 }
        let wd = weekdayOf(s.date)
        if p.week[wd]?.kind == "prefer_not" { score -= 1.5; why.append("prefers not \(weekdayLabel[wd]!)s") }
        if canWorkExtra(p.code, s.date, timeOff) { score += 1; why.append("said they can work extra") }
        if let asked = timeOffClash(p.code, date: s.date, start: s.type.start, end: s.type.end, timeOff), asked.status == "requested" {
            score -= 6; why.append("has asked for this day off")
        }
        if tight && maxRate > minRate {
            score -= 1.5 * (p.rate - minRate) / (maxRate - minRate)
            if p.rate <= minRate + 0.01 { why.append("keeps to the budget") }
        }
        score -= 0.15 * Double(load.shifts)
        if let mate = onShift.first(where: { buddies.contains($0.code) }) {
            score += 1
            why.append("works well with \(mate.name.split(separator: " ").first.map(String.init) ?? mate.name)")
        }
        return (score, why)
    }

    // MARK: - Building

    /// `buildRota`: fill every shift the period needs with the person who fits best.
    static func build(period: Period, rotaId: String, people: [Person], types: [ShiftType], needs: [Need], busy: [Busy],
                      timeOff: [TimeOff], budget: Budget?, siteId: String = "", fixed: [Shift] = [],
                      makeId: () -> String = { newId() }) -> (shifts: [Shift], why: [String: String]) {
        let origin = addDays(period.start, -7)
        let slots = demandFor(datesBetween(period.start, period.end), types: types, needs: needs, busy: busy, siteId: siteId)
        var loads = Dictionary(uniqueKeysWithValues: people.map { ($0.code, Load()) })
        var buddies = Dictionary(uniqueKeysWithValues: people.map { ($0.code, worksWithCodes($0.prefs.worksWith, team: people)) })
        for (code, mates) in buddies { for m in mates where buddies[m] != nil && !(buddies[m]!.contains(code)) { buddies[m]!.append(code) } }
        for s in fixed where !s.code.isEmpty && loads[s.code] != nil { loads[s.code]!.add(s.date, s.start, s.end, s.hours, origin: origin) }
        for k in loads.keys { loads[k]!.hours = 0; loads[k]!.shifts = 0 }

        let rates = people.map(\.rate).filter { $0 > 0 }
        let minRate = rates.min() ?? 0, maxRate = rates.max() ?? 0
        let avgRate = rates.isEmpty ? 0 : rates.reduce(0, +) / Double(rates.count)
        let demandHours = slots.reduce(0) { $0 + paidHours($1.type.start, $1.type.end, $1.type.breakMinutes) }
        let tight = (budget?.gbp).map { $0 > 0 && demandHours * avgRate > $0 * 0.95 } ?? false
        let weeks = Double(datesBetween(period.start, period.end).count) / 7

        func free(_ s: Slot) -> Int {
            people.filter { blocked($0, date: s.date, start: s.type.start, end: s.type.end, hours: 0, siteId: s.siteId, load: Load(), timeOff: timeOff, origin: origin) == nil }.count
        }
        let order = slots.enumerated().map { (s: $0.element, i: $0.offset, n: free($0.element)) }.sorted { a, b in
            let x = a.s.skill.isEmpty ? 0 : 1, y = b.s.skill.isEmpty ? 0 : 1
            if x != y { return x > y }
            if a.n != b.n { return a.n < b.n }
            if a.s.date != b.s.date { return a.s.date < b.s.date }
            return a.i < b.i
        }

        var placed: [(slot: Slot, shift: Shift)] = []
        var why: [String: String] = [:]
        for item in order {
            let s = item.s
            let hours = paidHours(s.type.start, s.type.end, s.type.breakMinutes)
            var shift = Shift(id: makeId(), rotaId: rotaId, code: "", date: s.date, start: s.type.start, end: s.type.end,
                              breakMinutes: s.type.breakMinutes, typeId: s.type.id, skill: s.skill,
                              siteId: s.siteId.isEmpty ? siteId : s.siteId, hours: hours, cost: 0, source: "build", note: "")
            let onShift = placed.filter { $0.slot.date == s.date && !$0.shift.code.isEmpty }
                .map { x in (code: x.shift.code, name: people.first { $0.code == x.shift.code }?.name ?? "") }
            var reasons: [String: Int] = [:]
            var reasonOrder: [String] = []
            var best: (p: Person, score: Double, why: [String])?
            for p in people {
                if let b = blocked(p, date: shift.date, start: shift.start, end: shift.end, hours: shift.hours, siteId: shift.siteId,
                                   load: loads[p.code]!, timeOff: timeOff, origin: origin) {
                    if reasons[b] == nil { reasonOrder.append(b) }
                    reasons[b, default: 0] += 1
                    continue
                }
                let (sc, w) = score(p, slot: s, hours: hours, load: loads[p.code]!, weeks: weeks, tight: tight, minRate: minRate, maxRate: maxRate,
                                    timeOff: timeOff, onShift: onShift, buddies: buddies[p.code] ?? [])
                if best == nil || sc > best!.score + 1e-9 || (abs(sc - best!.score) < 1e-9 && p.name.localizedCompare(best!.p.name) == .orderedAscending) {
                    best = (p, sc, w)
                }
            }
            if let best {
                shift.code = best.p.code
                shift.cost = round2(hours * best.p.rate)
                loads[best.p.code]!.add(shift.date, shift.start, shift.end, shift.hours, origin: origin)
                if !best.why.isEmpty { why[shift.id] = best.why.joined(separator: ", ") }
            } else {
                let top = reasonOrder.enumerated().sorted { a, b in
                    reasons[a.element]! != reasons[b.element]! ? reasons[a.element]! > reasons[b.element]! : a.offset < b.offset
                }.prefix(3).map { "\(reasons[$0.element]!) \($0.element)" }
                shift.note = people.isEmpty ? "Nobody on the team yet" : "Nobody free: \(top.joined(separator: "; "))"
            }
            placed.append((s, shift))
        }
        return (placed.map(\.shift).sorted(by: compare), why)
    }

    // MARK: - Copying

    static func copyForward(_ source: [Shift], to: Period, people: [Person], timeOff: [TimeOff], rotaId: String,
                            makeId: () -> String = { newId() }) -> [Shift] {
        var byDate: [String: [Shift]] = [:]
        for s in source { byDate[s.date, default: []].append(s) }
        var out: [Shift] = []
        let origin = addDays(to.start, -7)
        var loads = Dictionary(uniqueKeysWithValues: people.map { ($0.code, Load()) })
        for date in datesBetween(to.start, to.end) {
            var from = addDays(date, to.mode == "week" ? -7 : -28)
            if to.mode == "month" && from >= to.start { from = addDays(date, -35) }
            for s in (byDate[from] ?? []).sorted(by: compare) {
                var copy = s
                copy.id = makeId(); copy.rotaId = rotaId; copy.date = date; copy.source = "copy"; copy.note = ""; copy.name = nil; copy.rotaStatus = nil
                let person = people.first { $0.code == s.code }
                if !s.code.isEmpty && person == nil {
                    copy.code = ""; copy.cost = 0
                    copy.note = "Was \(s.name ?? s.code)'s: no longer active"
                } else if let person {
                    if let b = blocked(person, date: copy.date, start: copy.start, end: copy.end, hours: copy.hours, siteId: copy.siteId,
                                       load: loads[person.code]!, timeOff: timeOff, origin: origin) {
                        copy.code = ""; copy.cost = 0
                        copy.note = "Was \(person.name)'s: \(b)"
                    } else {
                        copy.cost = round2(copy.hours * person.rate)
                        loads[person.code]!.add(copy.date, copy.start, copy.end, copy.hours, origin: origin)
                    }
                }
                out.append(copy)
            }
        }
        return out
    }

    /// `shiftsFromWorked`: what was worked, to the nearest quarter hour, read in this device's zone.
    static func shiftsFromWorked(_ rows: [[String: CmsJSON]], people: [Person]) -> [Shift] {
        var out: [Shift] = []
        let cal = Calendar.current
        for r in rows {
            guard let a = stamp(r["clocked_in_at"]), let b = stamp(r["clocked_out_at"]), b > a else { continue }
            let code = str(r["employee_code"])
            guard !code.isEmpty else { continue }
            func q(_ d: Date) -> String {
                let c = cal.dateComponents([.hour, .minute], from: d)
                return hhmm(Int((Double((c.hour ?? 0) * 60 + (c.minute ?? 0)) / 15).rounded()) * 15)
            }
            let start = q(a), end = q(b)
            if start == end { continue }
            let length = spanMinutes(start, end)
            let worked = num(r["hours_worked"])
            let br = worked.map { $0 * 60 < Double(length) ? Int(((Double(length) - $0 * 60) / 5).rounded()) * 5 : 0 } ?? 0
            let hours = paidHours(start, end, br)
            let person = people.first { $0.code == code }
            out.append(Shift(id: "worked_\(out.count)", rotaId: "", code: code, date: iso(a), start: start, end: end, breakMinutes: br,
                             typeId: "", skill: "", siteId: "", hours: hours, cost: round2(hours * (person?.rate ?? 0)), source: "worked",
                             note: "", name: str(r["user_name"]).isEmpty ? nil : str(r["user_name"])))
        }
        return out
    }

    static func stamp(_ v: CmsJSON?) -> Date? {
        var raw = v
        if let o = v?.objectValue, let inner = o["value"] { raw = inner }
        var s = str(raw)
        guard !s.isEmpty else { return nil }
        s = s.replacingOccurrences(of: " UTC", with: "Z")
        if s.range(of: #"^\d{4}-\d{2}-\d{2} "#, options: .regularExpression) != nil { s = s.replacingCharacters(in: s.index(s.startIndex, offsetBy: 10)...s.index(s.startIndex, offsetBy: 10), with: "T") }
        if s.range(of: #"T\d{2}:\d{2}(:\d{2}(\.\d+)?)?$"#, options: .regularExpression) != nil { s += "Z" }
        return Impact.date(s)
    }

    // MARK: - Checking

    struct Warning: Identifiable, Equatable { var id: String; var severity: String; var text: String; var shiftId: String?; var code: String?; var date: String? }

    struct Context {
        var period: Period
        var people: [Person]
        var types: [ShiftType]
        var needs: [Need]
        var busy: [Busy]
        var timeOff: [TimeOff]
        var budget: Budget?
        var siteId = ""
    }

    static func check(_ shifts: [Shift], _ ctx: Context) -> [Warning] {
        var out: [Warning] = []
        let p0 = ctx.period
        let inPeriod = shifts.filter { $0.date >= p0.start && $0.date < p0.end }
        let origin = addDays(p0.start, -7)
        func typeName(_ id: String) -> String { ctx.types.first { $0.id == id }?.name ?? "" }
        func whereOf(_ s: Shift) -> String { "\(dayLabelShort(s.date))\(typeName(s.typeId).isEmpty ? "" : " \(typeName(s.typeId))") \(timeRange(s.start, s.end))" }

        for s in inPeriod where s.code.isEmpty {
            out.append(Warning(id: "open:\(s.id)", severity: "warn", text: "Open shift, \(whereOf(s))\(s.note.isEmpty ? "" : ". \(s.note)")", shiftId: s.id, date: s.date))
        }
        for p in ctx.people {
            let mine = shifts.filter { $0.code == p.code }.sorted(by: compare)
            guard !mine.isEmpty else { continue }
            var load = Load()
            for s in mine {
                let inside = s.date >= p0.start && s.date < p0.end
                let b = inside ? blocked(p, date: s.date, start: s.start, end: s.end, hours: s.hours, siteId: s.siteId, load: load, timeOff: ctx.timeOff, origin: origin) : nil
                if let b {
                    out.append(Warning(id: "rule:\(s.id)", severity: "error", text: "\(p.name), \(whereOf(s)): \(b)", shiftId: s.id, code: p.code, date: s.date))
                } else if inside {
                    if timeOffClash(p.code, date: s.date, start: s.start, end: s.end, ctx.timeOff)?.status == "requested" {
                        out.append(Warning(id: "asked:\(s.id)", severity: "warn", text: "\(p.name) has asked for \(dayLabelShort(s.date)) off", shiftId: s.id, code: p.code, date: s.date))
                    }
                    let wd = weekdayOf(s.date)
                    if p.week[wd]?.kind == "prefer_not" {
                        out.append(Warning(id: "pref:\(s.id)", severity: "info", text: "\(p.name) prefers not to work \(weekdayLabel[wd]!)s (\(dayLabelShort(s.date)))", shiftId: s.id, code: p.code, date: s.date))
                    }
                }
                load.add(s.date, s.start, s.end, s.hours, origin: origin)
            }
            let weeks = Double(datesBetween(p0.start, p0.end).count) / 7
            let f = p.prefs
            let hours = mine.filter { $0.date >= p0.start && $0.date < p0.end }.reduce(0) { $0 + $1.hours }
            let target = weeks > 1.5 ? (f.targetMonth ?? f.targetWeek.map { $0 * weeks }) : f.targetWeek
            let min = f.minWeek.map { $0 * max(1, weeks) }
            if let min, hours < min - 0.01 {
                out.append(Warning(id: "min:\(p.code)", severity: "warn", text: "\(p.name): \(formatHours(hours)), under their minimum of \(formatHours(min))", code: p.code))
            } else if let target, target > 0, hours > target * 1.1 {
                out.append(Warning(id: "over:\(p.code)", severity: "info", text: "\(p.name): \(formatHours(hours)), over their \(formatHours(target)) target", code: p.code))
            } else if let target, target > 0, hours < target * 0.75 {
                out.append(Warning(id: "under:\(p.code)", severity: "info", text: "\(p.name): \(formatHours(hours)), under their \(formatHours(target)) target", code: p.code))
            }
        }
        for s in inPeriod where !s.code.isEmpty && !ctx.people.contains(where: { $0.code == s.code }) {
            out.append(Warning(id: "gone:\(s.id)", severity: "warn", text: "\(s.name ?? s.code) is not an active employee, \(whereOf(s))", shiftId: s.id, date: s.date))
        }
        if !ctx.types.isEmpty && !inPeriod.isEmpty {
            var need: [String: Int] = [:], keys: [String] = []
            for slot in demandFor(datesBetween(p0.start, p0.end), types: ctx.types, needs: ctx.needs, busy: ctx.busy, siteId: ctx.siteId) {
                let k = "\(slot.date)|\(slot.type.id)"
                if need[k] == nil { keys.append(k) }
                need[k, default: 0] += 1
            }
            var have: [String: Int] = [:]
            for s in inPeriod where !s.typeId.isEmpty { have["\(s.date)|\(s.typeId)", default: 0] += 1 }
            for k in keys {
                let got = have[k] ?? 0, n = need[k]!
                if got < n {
                    let parts = k.split(separator: "|").map(String.init)
                    out.append(Warning(id: "short:\(k)", severity: "warn", text: "\(dayLabelShort(parts[0])) \(typeName(parts[1])): \(got) of \(n) people planned", date: parts[0]))
                }
            }
        }
        let sum = summarise(shifts, ctx)
        if let g = ctx.budget?.gbp, sum.cost > g + 0.005 {
            out.append(Warning(id: "budget:gbp", severity: "error", text: "Over budget by \(formatMoney(sum.cost - g)) (\(formatMoney(sum.cost)) of \(formatMoney(g)))"))
        }
        if let h = ctx.budget?.hours, sum.hours > h + 0.005 {
            out.append(Warning(id: "budget:hours", severity: "warn", text: "Over the hours budget by \(formatHours(sum.hours - h)) (\(formatHours(sum.hours)) of \(formatHours(h)))"))
        }
        let rank = ["error": 0, "warn": 1, "info": 2]
        return out.enumerated().sorted { a, b in
            let x = rank[a.element.severity]!, y = rank[b.element.severity]!
            if x != y { return x < y }
            let da = a.element.date ?? "", db = b.element.date ?? ""
            return da != db ? da < db : a.offset < b.offset
        }.map(\.element)
    }

    struct Summary: Equatable { var shifts = 0, open = 0; var hours = 0.0, cost = 0.0; var people = 0; var prefsMet: Int? }

    static func summarise(_ shifts: [Shift], _ ctx: Context) -> Summary {
        let p0 = ctx.period
        let inPeriod = shifts.filter { $0.date >= p0.start && $0.date < p0.end }
        let filled = inPeriod.filter { !$0.code.isEmpty }
        var kept = 0
        for s in filled {
            guard let p = ctx.people.first(where: { $0.code == s.code }) else { continue }
            let wd = weekdayOf(s.date), pref = p.prefs.preferredShift
            let day = p.week[wd]?.kind ?? "available"
            if day != "prefer_not" && day != "unavailable" && timeOffClash(p.code, date: s.date, start: s.start, end: s.end, ctx.timeOff) == nil
                && (pref.isEmpty || pref == "any" || pref == shiftKind(s.start, s.end)) { kept += 1 }
        }
        return Summary(shifts: inPeriod.count, open: inPeriod.count - filled.count, hours: round2(filled.reduce(0) { $0 + $1.hours }),
                       cost: round2(filled.reduce(0) { $0 + $1.cost }), people: Set(filled.map(\.code)).count,
                       prefsMet: filled.isEmpty ? nil : Int((Double(kept) / Double(filled.count) * 100).rounded()))
    }

    // MARK: - The file Reconcile reads

    static func csv(_ shifts: [Shift], nameOf: (String) -> String, typeName: (String) -> String, siteName: (String) -> String = { _ in "" }) -> String {
        func cell(_ s: String) -> String { s.rangeOfCharacter(from: CharacterSet(charactersIn: "\",\n")) != nil ? "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\"" : s }
        let head = ["Name", "Employee code", "Date", "Day", "Start", "End", "Unpaid break (minutes)", "Paid hours", "Shift", "Site", "Note"]
        let rows = shifts.filter { !$0.code.isEmpty }.sorted { a, b in
            if a.date != b.date { return a.date < b.date }
            let na = nameOf(a.code), nb = nameOf(b.code)
            if na != nb { return na.localizedCompare(nb) == .orderedAscending }
            return a.start < b.start
        }.map { s in [nameOf(s.code), s.code, s.date, weekdayLabel[weekdayOf(s.date)]!, s.start, s.end, String(s.breakMinutes), fmt(s.hours),
                      typeName(s.typeId), siteName(s.siteId), s.note] }
        return ([head] + rows).map { $0.map(cell).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }
}
