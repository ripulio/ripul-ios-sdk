import Foundation

/// What happens after a mutation succeeds (`action.after`): a full-screen
/// countdown, a summary of the saved record from the run's result, then a
/// page. The web's `packages/shared-types/src/cmsMutationAfter.ts`, held equal
/// by `cmsMutationAfter.cases.json` (CmsMutationAfterTests).
public struct CmsMutationAfter: Equatable {
    public struct Line: Equatable { public var label: String; public var value: String }
    public struct Summary: Equatable {
        public var title: String
        public var subtitle: String?
        public var lines: [Line]
        public var done: String?
    }

    public struct Round: Equatable {
        public var start: String
        public var end: String
        public var plannedStart: String?
        public var plannedEnd: String?
        public var granularityMinutes: Int
        public var setting: String
        public var title: String
        public var applyRun: String
        public var applyInputs: [String: String]
    }

    public var countdown: Int?
    public var countdownText: String?
    public var openPage: String?
    public var summary: Summary?
    public var round: Round?

    public init?(_ json: CmsJSON?) {
        guard let o = json?.objectValue else { return nil }
        if let n = o.double("countdown"), n >= 1 { countdown = min(10, Int(n)) }
        countdownText = o.string("countdownText").flatMap { $0.isEmpty ? nil : $0 }
        openPage = o.object("open")?.string("page").flatMap { $0.isEmpty ? nil : $0 }
        if let s = o.object("summary"), let title = s.string("title") {
            let lines: [Line] = (s["lines"]?.arrayValue ?? []).compactMap { l in
                guard let lo = l.objectValue, let label = lo.string("label"), let value = lo.string("value") else { return nil }
                return Line(label: label, value: value)
            }
            summary = Summary(title: title, subtitle: s.string("subtitle"), lines: lines,
                              done: s.string("done").flatMap { $0.isEmpty ? nil : $0 })
        }
        if let r = o.object("round"), let start = r.string("start"), let end = r.string("end"),
           let apply = r.object("apply"), let run = apply.string("run") {
            var inputs: [String: String] = [:]
            for (k, v) in apply.object("inputs") ?? [:] { if case .string(let t) = v { inputs[k] = t } }
            let g = r.double("granularityMinutes").map { Int($0) } ?? 5
            round = Round(start: start, end: end, plannedStart: r.string("plannedStart"), plannedEnd: r.string("plannedEnd"),
                          granularityMinutes: g >= 1 ? g : 5,
                          setting: r.string("setting").flatMap { $0.isEmpty ? nil : $0 } ?? "rounding",
                          title: r.string("title").flatMap { $0.isEmpty ? nil : $0 } ?? "Round the times?",
                          applyRun: run, applyInputs: inputs)
        }
        if countdown == nil && openPage == nil && summary == nil && round == nil { return nil }
    }

    /// A dotted path into `{ result }`.
    static func value(_ run: CmsJSON, _ path: String) -> CmsJSON? {
        var v: CmsJSON? = run
        for key in path.split(separator: ".").map(String.init) {
            if case .array(let a)? = v, let i = Int(key) { v = a.indices.contains(i) ? a[i] : nil }
            else { v = v?.objectValue?[key] }
            if v == nil { return nil }
        }
        return v
    }

    /// `hm` (seconds as "7h 05m"), `HH:mm` (a date-time at `offsetMinutes`
    /// from UTC), `money` (£1,234.50), else as text.
    static func format(_ v: CmsJSON?, _ format: String?, offsetMinutes: Int) -> String {
        guard let v, v != .null else { return "" }
        func number() -> Double? {
            switch v { case .number(let n): return n; case .string(let s): return Double(s); default: return nil }
        }
        switch format {
        case "hm":
            guard let n = number() else { return "" }
            let s = max(0, Int(n.rounded()))
            return String(format: "%dh %02dm", s / 3600, (s % 3600) / 60)
        case "HH:mm":
            guard let date = CmsElapsedTimer.time(v) else { return "" }
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(secondsFromGMT: offsetMinutes * 60) ?? .gmt
            let c = cal.dateComponents([.hour, .minute], from: date)
            return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        case "money":
            guard let n = number() else { return "" }
            let f = NumberFormatter()
            f.numberStyle = .decimal
            f.minimumFractionDigits = 2
            f.maximumFractionDigits = 2
            f.locale = Locale(identifier: "en_GB")
            return (n < 0 ? "-" : "") + "£" + (f.string(from: NSNumber(value: abs(n))) ?? "")
        default:
            switch v {
            case .string(let s): return s
            case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
            case .bool(let b): return b ? "true" : "false"
            default:
                guard let data = try? JSONEncoder().encode(v) else { return "" }
                return String(decoding: data, as: UTF8.self)
            }
        }
    }

    /// Text with `{path|format}` slots; `missing` when every slot came out empty.
    static func fill(_ template: String, run: CmsJSON, offsetMinutes: Int = TimeZone.current.secondsFromGMT() / 60) -> (text: String, missing: Bool) {
        guard let re = try? NSRegularExpression(pattern: #"\{([^{}|]+)(?:\|([^{}]+))?\}"#) else { return (template, false) }
        let ns = template as NSString
        var out = ""
        var last = 0
        var slots = 0, filled = 0
        for m in re.matches(in: template, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let path = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let fmt = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces) : nil
            let text = format(value(run, path), fmt, offsetMinutes: offsetMinutes)
            slots += 1
            if !text.isEmpty { filled += 1 }
            out += text
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return (out, slots > 0 && filled == 0)
    }

    // MARK: Rounding (WAC's ShiftQuantiser)

    public struct Quantised: Equatable {
        public var start: Date
        public var end: Date
        public var startChanged: Bool
        public var endChanged: Bool
    }

    static func snap(_ actual: Date, planned: Date?, windowMinutes: Int, granularityMinutes: Int) -> Date {
        if let planned, abs(actual.timeIntervalSince(planned)) / 60 <= Double(windowMinutes) { return planned }
        let step = Double(granularityMinutes * 60)
        return Date(timeIntervalSince1970: (actual.timeIntervalSince1970 / step).rounded() * step)
    }

    /// Both times: never an end at or before the start, and a change only when the whole minute moves.
    static func quantise(start: Date, end: Date, plannedStart: Date?, plannedEnd: Date?, windowMinutes: Int, granularityMinutes: Int = 5) -> Quantised {
        let s = snap(start, planned: plannedStart, windowMinutes: windowMinutes, granularityMinutes: granularityMinutes)
        let e = snap(end, planned: plannedEnd, windowMinutes: windowMinutes, granularityMinutes: granularityMinutes)
        let (safeStart, safeEnd) = [(s, e), (s, end), (start, e)].first { $0.1 > $0.0 } ?? (start, end)
        func minute(_ d: Date) -> Double { (d.timeIntervalSince1970 / 60).rounded(.down) }
        return Quantised(start: safeStart, end: safeEnd, startChanged: minute(safeStart) != minute(start), endChanged: minute(safeEnd) != minute(end))
    }

    /// The device's rounding setting: on by default, window 5 minutes, as WAC's.
    static func roundingSetting(_ key: String, defaults: UserDefaults = .standard) -> (on: Bool, windowMinutes: Int) {
        let on = defaults.object(forKey: "io.ripul.after.\(key).on") as? Bool ?? true
        let window = defaults.integer(forKey: "io.ripul.after.\(key).window")
        return (on, window > 0 ? window : 5)
    }

    static func setRounding(_ key: String, on: Bool, defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: "io.ripul.after.\(key).on")
    }
}
