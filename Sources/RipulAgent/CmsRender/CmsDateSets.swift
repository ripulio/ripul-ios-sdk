import Foundation

/// A set of days: an action input of `type: "dates"` (the web's
/// `packages/shared-types/src/cmsDateSets.ts`, to the same rules; both test
/// against `cmsDateSets.cases.json`). Its value is a list of days
/// (`yyyy-MM-dd`), sorted, each once.
///
/// - `range: { from, to }`: two date inputs; only the days between them
///   (inclusive) can be chosen.
/// - `defaultSelection`: what a new range starts with, `all` its days or
///   `none` (the default).
/// - `itemField`: each day is sent, and read from a row, as
///   `{ <itemField>: day }` (a backend's nested records).
///
/// In a record form's draft a set is its days joined with commas.
public enum CmsDateSets {
    /// The longest range a set of days offers.
    public static let maxDays = 366

    private static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = utc
        f.timeZone = utc.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// A real calendar day written `yyyy-MM-dd`, as a date at UTC midnight.
    static func parse(_ text: String) -> Date? {
        guard text.count == 10, let d = dayFormatter.date(from: text), dayFormatter.string(from: d) == text else { return nil }
        return d
    }

    /// A value's day: `yyyy-MM-dd`, or the day part of a timestamp; nil otherwise.
    public static func day(of value: CmsJSON?) -> String? {
        guard case .string(let s)? = value else { return nil }
        let head = String(s.trimmingCharacters(in: .whitespaces).prefix(10))
        return parse(head) == nil ? nil : head
    }

    /// Every day from `from` to `to`, inclusive, at most `maxDays`; empty
    /// when either isn't a day or `to` is before `from`.
    public static func daysBetween(_ from: CmsJSON?, _ to: CmsJSON?) -> [String] {
        guard let a = day(of: from), let b = day(of: to), a <= b,
              var at = parse(a), let end = parse(b) else { return [] }
        var out: [String] = []
        while at <= end, out.count < maxDays {
            out.append(dayFormatter.string(from: at))
            guard let next = utc.date(byAdding: .day, value: 1, to: at) else { break }
            at = next
        }
        return out
    }

    /// A set of days from any value it may arrive as: an array (of days, of
    /// timestamps, or of records holding the day at `itemField`), JSON text
    /// of one, or days joined with commas. Sorted, each once.
    public static func value(itemField: String?, _ raw: CmsJSON?) -> [String] {
        var items: [CmsJSON]
        switch raw {
        case .array(let list)?: items = list
        case .string(let s)?:
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { return [] }
            if t.hasPrefix("[") {
                guard let data = t.data(using: .utf8), case .array(let list)? = try? JSONDecoder().decode(CmsJSON.self, from: data) else { return [] }
                items = list
            } else {
                items = t.split(separator: ",").map { .string(String($0)) }
            }
        default: return []
        }
        var days = Set<String>()
        for item in items {
            let v: CmsJSON?
            if case .object(let o) = item { v = itemField.flatMap { o[$0] } } else { v = item }
            if let d = day(of: v) { days.insert(d) }
        }
        return days.sorted()
    }

    /// What a set holds once its range changes: all the range's days, or none.
    public static func forRange(defaultSelection: String?, _ from: CmsJSON?, _ to: CmsJSON?) -> [String] {
        defaultSelection == "all" ? daysBetween(from, to) : []
    }

    /// A set's value as sent: plain days, or `{ <itemField>: day }` each.
    public static func wire(itemField: String?, _ days: [String]) -> CmsJSON {
        guard let itemField, !itemField.isEmpty else { return .array(days.map(CmsJSON.string)) }
        return .array(days.map { .object([itemField: .string($0)]) })
    }

    /// The sets of days that read `changed` as an end of their range.
    public static func readingRange(_ inputs: [CmsActionInputDef], changed: String) -> [CmsActionInputDef] {
        inputs.filter { $0.type == "dates" && ($0.range?.from == changed || $0.range?.to == changed) }
    }

    /// Why a set's value is refused, or nil: it isn't a list of days, or a
    /// day lies outside its range (when both ends have a value).
    public static func issue(_ input: CmsActionInputDef, _ raw: CmsJSON, values: [String: CmsJSON]) -> String? {
        let label = input.displayLabel
        var list: [CmsJSON]
        switch raw {
        case .array(let l): list = l
        case .string(let s):
            guard let data = s.data(using: .utf8), case .array(let l)? = try? JSONDecoder().decode(CmsJSON.self, from: data) else {
                return "\(label) must be a list of days."
            }
            list = l
        default: return "\(label) must be a list of days."
        }
        if let bad = list.first(where: { value(itemField: input.itemField, .array([$0])).isEmpty }) {
            return "\(label) has \(bad.displayString), which isn't a day (yyyy-MM-dd)."
        }
        let days = value(itemField: input.itemField, .array(list))
        if let range = input.range, let from = day(of: values[range.from]), let to = day(of: values[range.to]),
           let outside = days.first(where: { $0 < from || $0 > to }) {
            return "\(label): \(outside) is outside \(from) to \(to)."
        }
        return nil
    }

    /// A day as the viewer's calendar names it, for a picker: the
    /// components `MultiDatePicker` itself uses (calendar, era, year, month,
    /// day), so a chosen day matches the picker's own.
    public static func components(_ day: String, calendar: Calendar = .current) -> DateComponents? {
        guard let date = date(day, calendar: calendar) else { return nil }
        return calendar.dateComponents([.calendar, .era, .year, .month, .day], from: date)
    }

    /// A day's start on the viewer's calendar.
    public static func date(_ day: String, calendar: Calendar = .current) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// A picker's day back as `yyyy-MM-dd`, read on the viewer's calendar.
    public static func day(_ components: DateComponents, calendar: Calendar = .current) -> String? {
        guard let date = (components.calendar ?? calendar).date(from: components) else { return nil }
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        guard let y = c.year, let m = c.month, let d = c.day else { return nil }
        return String(format: "%04d-%02d-%02d", y, m, d)
    }
}

/// `CmsActionInput.range`: the two date inputs a set of days lies between.
public struct CmsDateRange: Codable, Equatable {
    public var from: String
    public var to: String
}
