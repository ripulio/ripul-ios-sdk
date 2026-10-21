import Foundation

/// A file in a CMS file store (CmsFileRecord in cmsDefinitionsService.ts).
struct CmsFileRecord: Identifiable, Equatable {
    var id: String
    var partition: String
    var filename: String
    var mediaType: String
    var size: Double
    var metadata: [String: CmsJSON]
    var uploadedByEmail: String?
    var createdAt: String

    init?(_ json: CmsJSON) {
        guard let o = json.objectValue, let id = o.string("id") else { return nil }
        self.id = id
        partition = o.string("partition") ?? ""
        filename = o.string("filename") ?? "File"
        mediaType = o.string("mediaType") ?? "application/octet-stream"
        size = o.double("size") ?? 0
        metadata = o.object("metadata") ?? [:]
        uploadedByEmail = o.string("uploadedByEmail")
        createdAt = o.string("createdAt") ?? ""
    }
}

/// The file store's answer to a listing: who may do what, and the files.
struct CmsFileListing: Equatable {
    /// nil = 'all' (owners, admins); otherwise the accounts the member reaches.
    var partitions: [String]?
    var upload: Bool
    var delete: Bool
    var files: [CmsFileRecord]

    init(_ json: CmsJSON) {
        let o = json.objectValue ?? [:]
        let perms = o.object("permissions") ?? [:]
        if case .array(let list)? = perms["partitions"] {
            partitions = list.compactMap(\.stringValue)
        } else {
            partitions = nil
        }
        upload = perms.bool("upload") ?? false
        delete = perms.bool("delete") ?? false
        if case .array(let list)? = o["files"] { files = list.compactMap(CmsFileRecord.init) } else { files = [] }
    }

    /// `spansAccounts` (fileLibraryAccount.ts).
    var spansAccounts: Bool { partitions == nil || (partitions?.count ?? 0) > 1 }

    /// `boundAccount`: the bound account when the member spans several and reaches it.
    func boundAccount(_ account: String?) -> String? {
        guard let a = account?.trimmingCharacters(in: .whitespaces), !a.isEmpty, spansAccounts else { return nil }
        guard let partitions else { return a }
        return partitions.contains(a) ? a : nil
    }
}

/// fileWeeks.ts, ported function for function: weeks of rotas, their status,
/// and pay periods.
enum CmsFileWeeks {
    struct Week: Identifiable, Equatable {
        var start: String
        var end: String
        var label: String
        var offset: Int
        var files: [CmsFileRecord] = []
        var id: String { start }
    }

    enum Status: Equatable {
        case due, missing, uploaded, ready, matched
        case differences(count: Double, value: Double?)
    }

    struct PayPeriod: Identifiable, Equatable {
        var start: String
        var end: String
        var lastDay: String
        var label: String
        var offset: Int
        var payday: String?
        var weeks: [Week] = []
        var files: [CmsFileRecord] = []
        var id: String { start }
    }

    struct Summary: Equatable {
        var weeksDue = 0, weeksWithRota = 0, weeksChecked = 0
        var differences = 0.0
        var differencesValue: Double?
    }

    static let replacedKind = "rota-replaced"
    private static let gb = Locale(identifier: "en_GB")
    private static var cal: Calendar { Calendar(identifier: .gregorian) }

    static func iso(_ d: Date) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    static func parse(_ iso: String) -> Date {
        let p = iso.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return Date.distantPast }
        return cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))!
    }

    static func addDays(_ d: Date, _ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: d)! }

    /// Local midnight on the Monday of `d`'s week.
    static func mondayOf(_ d: Date) -> Date {
        let day = cal.startOfDay(for: d)
        let weekday = cal.component(.weekday, from: day) // 1 = Sunday
        return addDays(day, -((weekday + 5) % 7))
    }

    private static func month(_ d: Date) -> String { d.formatted(.dateTime.month(.abbreviated).locale(gb)) }
    private static func dayNum(_ d: Date) -> Int { cal.component(.day, from: d) }
    private static func year(_ d: Date) -> Int { cal.component(.year, from: d) }
    private static func monthNum(_ d: Date) -> Int { cal.component(.month, from: d) }

    static func rangeLabel(_ from: Date, _ to: Date, now: Date) -> String {
        let y = year(to) != year(now) ? " \(year(to))" : ""
        return monthNum(from) == monthNum(to) && year(from) == year(to)
            ? "\(dayNum(from)) – \(dayNum(to)) \(month(to))\(y)"
            : "\(dayNum(from)) \(month(from)) – \(dayNum(to)) \(month(to))\(y)"
    }

    static func weekLabel(_ monday: Date, now: Date) -> String { rangeLabel(monday, addDays(monday, 6), now: now) }

    private static func isoDay(_ v: CmsJSON?) -> String? {
        guard let s = v?.stringValue, s.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil else { return nil }
        return String(s.prefix(10))
    }

    static func fileWeekStart(_ f: CmsFileRecord, key: String) -> String? {
        guard let day = isoDay(f.metadata[key]) else { return nil }
        return iso(mondayOf(parse(day)))
    }

    static func coverage(_ f: CmsFileRecord, key: String) -> (from: String, to: String)? {
        if let from = isoDay(f.metadata["from"]), let to = isoDay(f.metadata["to"]), from <= to { return (from, to) }
        guard let start = fileWeekStart(f, key: key) else { return nil }
        return (start, iso(addDays(parse(start), 6)))
    }

    static func spansWeeks(_ f: CmsFileRecord, key: String) -> Bool {
        guard let c = coverage(f, key: key) else { return false }
        return iso(mondayOf(parse(c.from))) != iso(mondayOf(parse(c.to)))
    }

    static func resultKey(_ f: CmsFileRecord, weekStart: String?, key: String, name: String = "differences") -> String {
        if let weekStart, spansWeeks(f, key: key) { return "\(name):\(weekStart)" }
        return name
    }

    static func isReplaced(_ f: CmsFileRecord) -> Bool { f.metadata.string("kind") == replacedKind }

    private static func newest(_ files: [CmsFileRecord]) -> CmsFileRecord {
        files.reduce(files[0]) { $1.createdAt > $0.createdAt ? $1 : $0 }
    }

    static func buildWeeks(_ files: [CmsFileRecord], now: Date, ahead: Int, back: Int, key: String) -> (weeks: [Week], unfiled: [CmsFileRecord]) {
        let thisMonday = mondayOf(now)
        var weeks: [Week] = []
        for offset in stride(from: ahead, through: -back, by: -1) {
            let monday = addDays(thisMonday, offset * 7)
            weeks.append(Week(start: iso(monday), end: iso(addDays(monday, 7)), label: weekLabel(monday, now: now), offset: offset))
        }
        var unfiled: [CmsFileRecord] = []
        for f in files where !isReplaced(f) {
            let cover = coverage(f, key: key)
            let holding = cover.map { c in weeks.indices.filter { c.from < weeks[$0].end && c.to >= weeks[$0].start } } ?? []
            if holding.isEmpty { unfiled.append(f) } else { for i in holding { weeks[i].files.append(f) } }
        }
        // One rota per week: the newest upload is the week's rota.
        for i in weeks.indices where weeks[i].files.count > 1 { weeks[i].files = [newest(weeks[i].files)] }
        return (weeks, unfiled)
    }

    /// `replacedRotas`: rotas every one of whose weeks a newer upload covers, per account.
    static func replacedRotas(_ files: [CmsFileRecord], key: String) -> [(file: CmsFileRecord, by: CmsFileRecord)] {
        let live = files.filter { !isReplaced($0) && coverage($0, key: key) != nil }
        func mondays(_ f: CmsFileRecord) -> [String] {
            let c = coverage(f, key: key)!
            var out: [String] = []
            var day = mondayOf(parse(c.from))
            while iso(day) <= c.to { out.append(iso(day)); day = addDays(day, 7) }
            return out
        }
        var byWeek: [String: [CmsFileRecord]] = [:]
        for f in live { for w in mondays(f) { byWeek["\(f.partition)|\(w)", default: []].append(f) } }
        var out: [(CmsFileRecord, CmsFileRecord)] = []
        for f in live {
            let newestPerWeek = mondays(f).map { newest(byWeek["\(f.partition)|\($0)"]!) }
            if !newestPerWeek.isEmpty, newestPerWeek.allSatisfy({ $0.id != f.id && $0.createdAt > f.createdAt }) {
                out.append((f, newestPerWeek[0]))
            }
        }
        return out
    }

    private static func labelNumber(_ v: CmsJSON?) -> Double? {
        switch v {
        case .number(let n)?: return n.isFinite ? n : nil
        case .string(let s)?: let t = s.trimmingCharacters(in: .whitespaces); return t.isEmpty ? nil : Double(t)
        default: return nil
        }
    }

    static func status(_ week: Week) -> Status {
        if week.files.isEmpty { return week.offset >= 0 ? .due : .missing }
        let checked: [(Double, Double?)] = week.files.compactMap { f in
            let many = spansWeeks(f, key: "week")
            let count = labelNumber(f.metadata["differences:\(week.start)"]) ?? (many ? nil : labelNumber(f.metadata["differences"]))
            let value = labelNumber(f.metadata["differencesValue:\(week.start)"]) ?? (many ? nil : labelNumber(f.metadata["differencesValue"]))
            return count.map { ($0, value) }
        }
        if let worst = checked.max(by: { $0.0 < $1.0 }) {
            if worst.0 <= 0 { return .matched }
            return .differences(count: worst.0, value: worst.1.map(abs))
        }
        return week.offset < 0 ? .ready : .uploaded
    }

    static func coverageLabel(_ c: (from: String, to: String), now: Date) -> String {
        rangeLabel(parse(c.from), parse(c.to), now: now)
    }

    /// `fillPrompt`: a missing value reads "(not set)"; an unknown name stays as written.
    static func fillPrompt(_ template: String, _ vars: [String: String?]) -> String {
        let re = try! NSRegularExpression(pattern: "\\{([a-zA-Z]+)\\}")
        var out = ""
        var last = template.startIndex
        for m in re.matches(in: template, range: NSRange(template.startIndex..., in: template)) {
            let whole = Range(m.range, in: template)!, name = String(template[Range(m.range(at: 1), in: template)!])
            out += template[last..<whole.lowerBound]
            if let value = vars[name] { out += value ?? "(not set)" } else { out += template[whole] }
            last = whole.upperBound
        }
        return out + template[last...]
    }

    static func weekOfStart(_ start: String, now: Date) -> Week {
        let monday = parse(start)
        return Week(start: start, end: iso(addDays(monday, 7)), label: weekLabel(monday, now: now), offset: 0)
    }

    // MARK: Pay periods

    static func parseCutoffDay(_ raw: String?) -> Int? {
        guard let t = raw?.trimmingCharacters(in: .whitespaces), t.range(of: #"^\d{1,2}$"#, options: .regularExpression) != nil,
              let n = Int(t), (1...31).contains(n) else { return nil }
        return n
    }

    private static func daysInMonth(_ y: Int, _ m: Int) -> Int {
        let first = cal.date(from: DateComponents(year: y, month: m, day: 1))!
        return cal.range(of: .day, in: .month, for: first)!.count
    }

    /// A date from a possibly out-of-range month (JS Date semantics).
    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var year = y, month = m
        while month < 1 { month += 12; year -= 1 }
        while month > 12 { month -= 12; year += 1 }
        return cal.date(from: DateComponents(year: year, month: month, day: d))!
    }

    private static func cutoffIn(_ y: Int, _ m: Int, _ cutoff: Int) -> Date {
        var year = y, month = m
        while month < 1 { month += 12; year -= 1 }
        while month > 12 { month -= 12; year += 1 }
        return date(year, month, min(cutoff, daysInMonth(year, month)))
    }

    static func payPeriodOf(_ d: Date, cutoff: Int?) -> (first: Date, last: Date) {
        let y = year(d), m = monthNum(d)
        guard let cutoff else { return (date(y, m, 1), date(y, m, daysInMonth(y, m))) }
        let day = cal.startOfDay(for: d)
        let thisCutoff = cutoffIn(y, m, cutoff)
        let last = day <= thisCutoff ? thisCutoff : cutoffIn(y, m + 1, cutoff)
        let previous = cutoffIn(year(last), monthNum(last) - 1, cutoff)
        return (addDays(previous, 1), last)
    }

    static func paydayAfter(_ lastDay: Date, schedule: String?) -> Date? {
        let text = (schedule ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return nil }
        func inMonth(_ y: Int, _ m: Int) -> Date? {
            var year = y, month = m
            while month > 12 { month -= 12; year += 1 }
            if text == "last" { return date(year, month, daysInMonth(year, month)) }
            if text == "last_working" {
                var d = date(year, month, daysInMonth(year, month))
                while [1, 7].contains(cal.component(.weekday, from: d)) { d = addDays(d, -1) }
                return d
            }
            return parseCutoffDay(text).map { date(year, month, min($0, daysInMonth(year, month))) }
        }
        guard let same = inMonth(year(lastDay), monthNum(lastDay)) else { return nil }
        return same >= lastDay ? same : inMonth(year(lastDay), monthNum(lastDay) + 1)
    }

    static func buildPayPeriods(_ weeks: [Week], now: Date, cutoff: Int?, paySchedule: String?) -> [PayPeriod] {
        let today = payPeriodOf(now, cutoff: cutoff)
        var byStart: [String: PayPeriod] = [:]
        func key(_ d: Date) -> String {
            let (first, last) = payPeriodOf(d, cutoff: cutoff)
            let start = iso(first)
            if byStart[start] == nil {
                let offset = (year(last) - year(today.last)) * 12 + (monthNum(last) - monthNum(today.last))
                byStart[start] = PayPeriod(start: start, end: iso(addDays(last, 1)), lastDay: iso(last),
                                           label: rangeLabel(first, last, now: now), offset: offset,
                                           payday: paydayAfter(last, schedule: paySchedule).map(iso))
            }
            return start
        }
        for week in weeks {
            let monday = parse(week.start)
            let early = key(monday), late = key(addDays(monday, 6))
            byStart[early]!.weeks.append(week); byStart[early]!.files += week.files
            if late != early { byStart[late]!.weeks.append(week); byStart[late]!.files += week.files }
        }
        for k in byStart.keys {
            var seen = Set<String>()
            byStart[k]!.files = byStart[k]!.files.filter { seen.insert($0.id).inserted }
        }
        return byStart.values.filter { !$0.weeks.isEmpty }.sorted { $0.start > $1.start }
    }

    static func summary(_ p: PayPeriod) -> Summary {
        var s = Summary()
        for w in p.weeks {
            let st = status(w)
            if w.offset <= 1 || !w.files.isEmpty { s.weeksDue += 1 }
            if !w.files.isEmpty { s.weeksWithRota += 1 }
            switch st {
            case .matched: s.weeksChecked += 1
            case .differences(let count, let value):
                s.weeksChecked += 1
                s.differences += count
                if let value { s.differencesValue = (s.differencesValue ?? 0) + value }
            default: break
            }
        }
        if let v = s.differencesValue { s.differencesValue = (v * 100).rounded() / 100 }
        return s
    }

    /// "Sat 31 Oct".
    static func dayLabel(_ iso: String) -> String {
        parse(iso).formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(gb))
    }

    static func daysUntil(_ iso: String, now: Date) -> Int {
        cal.dateComponents([.day], from: cal.startOfDay(for: now), to: parse(iso)).day ?? 0
    }
}
