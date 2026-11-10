import Foundation

/// Swift twin of `formatValue.ts` — the shared display-format engine
/// (KPI values, column formatters, binding `format` patterns).
/// Number patterns: `#,##0.00`, `$#,##0`, `0%`, `#,##0 hrs` (prefix/suffix
/// inline). Date patterns: date-fns tokens (`dd/MM/yyyy`, `d MMM yyyy HH:mm`)
/// which map 1:1 onto DateFormatter for the token subset the presets use.
/// Duration patterns: lowercase time tokens only (`mm:ss`, `hh:mm:ss`) applied
/// to a bare integer treated as total seconds.
public enum CmsFormatValue {
    /// Any y/M/d/H token marks a date pattern — twin of `isDatePattern`.
    public static func isDatePattern(_ pattern: String) -> Bool {
        unquoted(pattern).contains(where: { "yMdH".contains($0) })
    }

    /// The pattern without its quoted text (`"h"`, `'km'`): words kept as
    /// written, never read as tokens. Twin of `unquoted` in formatValue.ts.
    static func unquoted(_ pattern: String) -> String {
        pattern.replacingOccurrences(of: #""[^"]*"|'[^']*'"#, with: "", options: .regularExpression)
    }

    /// Quoted text with its quotes taken off. Twin of `literal`.
    static func literal(_ text: String) -> String {
        text.replacingOccurrences(of: #""([^"]*)"|'([^']*)'"#, with: "$1$2", options: .regularExpression)
    }

    /// Duration pattern: lowercase h/m/s tokens only, no calendar tokens.
    /// Twin of `isDurationPattern` in formatValue.ts.
    public static func isDurationPattern(_ pattern: String) -> Bool {
        !isDatePattern(pattern) && unquoted(pattern).contains(where: { "hms".contains($0) })
    }

    public static func apply(_ value: String, pattern: String) -> String {
        guard !value.isEmpty, !pattern.isEmpty else { return value }
        if isDatePattern(pattern) {
            guard let date = toDate(value) else { return "" }
            let formatter = DateFormatter()
            // DateFormatter quotes with single quotes; a pattern may use double.
            formatter.dateFormat = pattern.replacingOccurrences(of: #""([^"]*)""#, with: "'$1'", options: .regularExpression)
            return formatter.string(from: date)
        }
        guard let number = Double(value.trimmingCharacters(in: .whitespaces)) else {
            return value
        }
        // Duration: treat integer as total seconds, format hh/mm/ss components.
        // Manual substitution mirrors the web's timezone-safe approach so
        // the displayed hours/minutes/seconds are never offset-shifted.
        if isDurationPattern(pattern) {
            let total = Int(abs(number.rounded()))
            let h = total / 3600
            let m = (total % 3600) / 60
            let s = total % 60
            func pad(_ v: Int) -> String { String(format: "%02d", v) }
            return pattern
                .replacingOccurrences(of: "hh", with: pad(h))
                .replacingOccurrences(of: "h",  with: String(h))
                .replacingOccurrences(of: "mm", with: pad(m))
                .replacingOccurrences(of: "m",  with: String(m))
                .replacingOccurrences(of: "ss", with: pad(s))
                .replacingOccurrences(of: "s",  with: String(s))
        }
        return applyNumberPattern(number, pattern: pattern)
    }

    /// Parse a stored value for date formatting. Date-only strings parse as a
    /// LOCAL calendar date (never UTC midnight); naive datetimes parse as
    /// local wall-clock — matching the web's default (non-utc) behavior.
    /// `naiveUTC`: a naive datetime (no zone) is UTC rather than local, the
    /// web's `toDate(value, { utc: true })`. A bare date is always local.
    /// `localZone`: the zone a local naive datetime is read in (the viewer's).
    static func toDate(_ raw: String, naiveUTC: Bool, localZone: TimeZone = .current) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard s.count > 10,
              s.range(of: #"^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2}(\.\d+)?)?$"#, options: .regularExpression) != nil
        else { return toDate(raw) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = naiveUTC ? TimeZone(identifier: "UTC") : localZone
        let normalized = s.replacingOccurrences(of: " ", with: "T")
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm"] {
            f.dateFormat = format
            if let d = f.date(from: normalized) { return d }
        }
        return toDate(raw)
    }

    static func toDate(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current

        // yyyy-MM-dd — local calendar date
        if s.count == 10, s[s.index(s.startIndex, offsetBy: 4)] == "-" {
            return CmsDatePredicate.date(fromIso: s)
        }
        // yyyy-MM-dd[T ]HH:mm[:ss] — naive local datetime
        let normalized = s.replacingOccurrences(of: " ", with: "T")
        let formats = ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm"]
        for format in formats {
            let f = DateFormatter()
            f.dateFormat = format
            f.timeZone = TimeZone.current
            if let d = f.date(from: normalized) { return d }
        }
        // Zone-suffixed ISO instant
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        // Bare integer — mirrors JS `new Date("N")` which parses it as year N,
        // January 1 (V8 extended-year heuristic). Allows an integer column
        // formatted with a calendar date/time pattern (e.g. "MM:ss") to match
        // web output. Duration patterns (mm:ss) are handled before toDate is
        // called and never reach this path.
        if let year = Int(s) {
            var components = DateComponents()
            components.year = year
            components.month = 1
            components.day = 1
            components.hour = 0
            components.minute = 0
            components.second = 0
            return Calendar.current.date(from: components)
        }
        return nil
    }

    /// Twin of `applyNumberPattern`: split the pattern into prefix + numeric
    /// core (`[#0,.]+`) + suffix, derive grouping and fraction digits from the
    /// core, multiply by 100 for a trailing `%`.
    static func applyNumberPattern(_ n: Double, pattern: String) -> String {
        let isPercent = pattern.hasSuffix("%")
        let p = isPercent ? String(pattern.dropLast()) : pattern

        // The numeric core is the first run of #0,. outside quotes: a unit in
        // quotes rides along ('#,##0 "m"' → "1,285 m"; '0.##"h"' → "6h").
        var coreRange: Range<String.Index>?
        var search = p.startIndex
        while let r = p.range(of: #""[^"]*"|'[^']*'|[#0,.]+"#, options: .regularExpression, range: search..<p.endIndex) {
            if p[r.lowerBound] != "\"", p[r.lowerBound] != "'" { coreRange = r; break }
            search = r.upperBound
        }
        guard let coreRange else {
            return formatted(n, minFrac: 0, maxFrac: 3, grouping: true)
        }
        let core = String(p[coreRange])
        let prefix = literal(String(p[p.startIndex..<coreRange.lowerBound]))
        let suffix = literal(String(p[coreRange.upperBound...]))

        let parts = core.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let intPart = String(parts[0])
        let fracPart = parts.count > 1 ? String(parts[1]) : ""

        let useGrouping = intPart.contains(",")
        let minFrac = fracPart.filter { $0 == "0" }.count
        let maxFrac = fracPart.count

        let num = isPercent ? n * 100 : n
        let body = formatted(num, minFrac: minFrac, maxFrac: maxFrac, grouping: useGrouping)
        return "\(prefix)\(body)\(suffix)\(isPercent ? "%" : "")"
    }

    /// Apply a named value transform before format-pattern rendering.
    /// Twin of `applyTransform` in formatValue.ts.
    public static func applyTransform(_ value: String, transform: String) -> String {
        guard let n = Double(value.trimmingCharacters(in: .whitespaces)) else { return value }
        let result: Double
        switch transform {
        case "seconds_to_minutes":      result = n / 60
        case "seconds_to_hours":        result = n / 3600
        case "milliseconds_to_seconds": result = n / 1000
        case "milliseconds_to_minutes": result = n / 60000
        default:
            if transform.hasPrefix("divide:"),
               let d = Double(transform.dropFirst(7)), d != 0 {
                result = n / d
            } else if transform.hasPrefix("multiply:"),
                      let f = Double(transform.dropFirst(9)) {
                result = n * f
            } else {
                return value
            }
        }
        // Preserve integer-ness: 3600/60 = 60, not 60.0
        if result == result.rounded() && abs(result) < 1e15 {
            return String(Int64(result))
        }
        return String(result)
    }

    private static func formatted(_ n: Double, minFrac: Int, maxFrac: Int, grouping: Bool) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = minFrac
        formatter.maximumFractionDigits = maxFrac
        formatter.usesGroupingSeparator = grouping
        return formatter.string(from: NSNumber(value: n)) ?? String(n)
    }
}
