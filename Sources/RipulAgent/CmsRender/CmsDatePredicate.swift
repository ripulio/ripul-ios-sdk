import Foundation

/// Swift twin of `chrome-extension/src/cms/blocks/datePredicate.ts` — the
/// value-side date-predicate fold. The SQL stays static and half-open
/// (`WHERE DATE(col) >= @from AND DATE(col) < @to`); the operator is folded
/// into the two bound VALUES here. Keep behavior identical to the web module;
/// this is data-plane semantics, not presentation.
public enum CmsRangePredicateOperator: String, CaseIterable {
    case eq, gt, gte, lt, lte, any
    case between
    // Relative-period shortcuts — resolve to a full [from, to) from today,
    // so they need no date pick.
    case today, thisWeek, thisMonth, thisQuarter, thisYear

    public var label: String {
        switch self {
        case .eq: return "On this date"
        case .lt: return "Before this date"
        case .lte: return "On or before this date"
        case .gt: return "After this date"
        case .gte: return "On or after this date"
        case .between: return "Between"
        case .today: return "Today"
        case .thisWeek: return "This week"
        case .thisMonth: return "This month"
        case .thisQuarter: return "This quarter"
        case .thisYear: return "This year"
        case .any: return "Any date (no filter)"
        }
    }

    /// Menu order — mirrors RANGE_PREDICATE_OPTIONS.
    public static let menuOrder: [CmsRangePredicateOperator] = [
        .eq, .lt, .lte, .gt, .gte, .between,
        .today, .thisWeek, .thisMonth, .thisQuarter, .thisYear, .any,
    ]

    public var isPeriod: Bool {
        switch self {
        case .today, .thisWeek, .thisMonth, .thisQuarter, .thisYear: return true
        default: return false
        }
    }

    /// Operators that need a picked date before a filter can be emitted.
    public var needsDate: Bool { !isPeriod && self != .any }
}

public struct CmsDateBounds: Equatable {
    public var from: String
    public var to: String
}

public enum CmsDatePredicate {
    /// DATE-domain sentinels for open-ended half-open ranges.
    public static let dateMin = "0001-01-01"
    public static let dateMax = "9999-12-31"

    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        return f
    }()

    /// Monday-start calendar — `thisWeek` matches the web fold, which
    /// hardcodes weekStartsOn: 1 regardless of the block's display prop.
    private static var mondayCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        return cal
    }

    public static func iso(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }

    public static func date(fromIso s: String) -> Date? {
        guard s.count >= 10 else { return nil }
        return isoFormatter.date(from: String(s.prefix(10)))
    }

    /// The day after `date` (ISO), clamped at the DATE-domain ceiling.
    static func nextDay(_ isoDate: String) -> String {
        if isoDate >= dateMax { return dateMax }
        guard let d = date(fromIso: isoDate),
              let next = mondayCalendar.date(byAdding: .day, value: 1, to: d) else { return isoDate }
        return iso(next)
    }

    /// Single-date fold — twin of `boundsFor`.
    public static func bounds(for op: CmsRangePredicateOperator, date isoDate: String) -> CmsDateBounds {
        switch op {
        case .eq: return CmsDateBounds(from: isoDate, to: nextDay(isoDate))
        case .gte: return CmsDateBounds(from: isoDate, to: dateMax)
        case .gt: return CmsDateBounds(from: nextDay(isoDate), to: dateMax)
        case .lte: return CmsDateBounds(from: dateMin, to: nextDay(isoDate))
        case .lt: return CmsDateBounds(from: dateMin, to: isoDate)
        default: return CmsDateBounds(from: dateMin, to: dateMax)
        }
    }

    /// Range fold — twin of `boundsForRange`. `between` spans
    /// `min(start, end)` … `nextDay(max)`; periods resolve from today;
    /// everything else delegates to the single-date fold.
    public static func boundsForRange(
        _ op: CmsRangePredicateOperator,
        start: String,
        end: String? = nil
    ) -> CmsDateBounds {
        if op.isPeriod { return periodBounds(op) }
        if op == .between {
            let lo = (end != nil && end! < start) ? end! : start
            let hi = (end != nil && end! > start) ? end! : start
            return CmsDateBounds(from: lo, to: nextDay(hi))
        }
        return bounds(for: op, date: start)
    }

    static func periodBounds(_ op: CmsRangePredicateOperator, now: Date = Date()) -> CmsDateBounds {
        let cal = mondayCalendar
        func span(_ component: Calendar.Component) -> CmsDateBounds {
            guard let interval = cal.dateInterval(of: component, for: now) else {
                return CmsDateBounds(from: dateMin, to: dateMax)
            }
            let lastDay = cal.date(byAdding: .day, value: -1, to: interval.end) ?? interval.end
            return CmsDateBounds(from: iso(interval.start), to: nextDay(iso(lastDay)))
        }
        switch op {
        case .today:
            let today = iso(cal.startOfDay(for: now))
            return CmsDateBounds(from: today, to: nextDay(today))
        case .thisWeek: return span(.weekOfYear)
        case .thisMonth: return span(.month)
        case .thisQuarter: return span(.quarter)
        case .thisYear: return span(.year)
        default: return CmsDateBounds(from: dateMin, to: dateMax)
        }
    }
}
