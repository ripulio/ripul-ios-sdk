import Foundation

/// Swift twin of `formatValue.ts` — the shared display-format engine
/// (KPI values, column formatters, binding `format` patterns).
/// Number patterns: `#,##0.00`, `$#,##0`, `0%`, `#,##0 hrs` (prefix/suffix
/// inline). Date patterns: date-fns tokens (`dd/MM/yyyy`, `d MMM yyyy HH:mm`)
/// which map 1:1 onto DateFormatter for the token subset the presets use.
public enum CmsFormatValue {
    /// Any y/M/d/H token marks a date pattern — twin of `isDatePattern`.
    public static func isDatePattern(_ pattern: String) -> Bool {
        pattern.contains(where: { "yMdH".contains($0) })
    }

    public static func apply(_ value: String, pattern: String) -> String {
        guard !value.isEmpty, !pattern.isEmpty else { return value }
        if isDatePattern(pattern) {
            guard let date = toDate(value) else { return "" }
            let formatter = DateFormatter()
            formatter.dateFormat = pattern
            return formatter.string(from: date)
        }
        guard let number = Double(value.trimmingCharacters(in: .whitespaces)) else {
            return value
        }
        return applyNumberPattern(number, pattern: pattern)
    }

    /// Parse a stored value for date formatting. Date-only strings parse as a
    /// LOCAL calendar date (never UTC midnight); naive datetimes parse as
    /// local wall-clock — matching the web's default (non-utc) behavior.
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
        return iso.date(from: s)
    }

    /// Twin of `applyNumberPattern`: split the pattern into prefix + numeric
    /// core (`[#0,.]+`) + suffix, derive grouping and fraction digits from the
    /// core, multiply by 100 for a trailing `%`.
    static func applyNumberPattern(_ n: Double, pattern: String) -> String {
        let isPercent = pattern.hasSuffix("%")
        let p = isPercent ? String(pattern.dropLast()) : pattern

        guard let coreRange = p.range(of: "[#0,.]+", options: .regularExpression) else {
            return formatted(n, minFrac: 0, maxFrac: 3, grouping: true)
        }
        let core = String(p[coreRange])
        let prefix = String(p[p.startIndex..<coreRange.lowerBound])
        let suffix = String(p[coreRange.upperBound...])

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

    private static func formatted(_ n: Double, minFrac: Int, maxFrac: Int, grouping: Bool) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = minFrac
        formatter.maximumFractionDigits = maxFrac
        formatter.usesGroupingSeparator = grouping
        return formatter.string(from: NSNumber(value: n)) ?? String(n)
    }
}
