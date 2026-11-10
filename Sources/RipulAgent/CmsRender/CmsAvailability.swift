import Foundation

// MARK: - The availability calendar: model and rules
//
// Twin of the web's `src/cms/blocks/availability.ts` and the props of
// AvailabilityCalendarBlock.tsx: each unit's availability read from a published
// integration feed (parallel lists of inclusive day ranges, 1 free and 0 not),
// a stay's nights, which choices the feeds rule out, and when to ask a feed for
// a fresher copy. Days are `yyyy-MM-dd` keys in the viewer's calendar. Tested
// against the web's own cases (CmsAvailabilityTests). Drawn by
// CmsAvailabilityCalendarBlock.swift.

enum CmsAvailability {
    /// What one unit's feed says.
    struct Unit: Equatable {
        var free: Set<String>
        var unavailable: Set<String>
        var refreshedAt: String?
    }

    enum DayState: Equatable { case free, taken, unknown }

    // MARK: Days

    private static let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }

    /// A day's key: the viewer's own date for that moment.
    static func key(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func isDayKey(_ s: String) -> Bool {
        s.count == 10 && keyFormatter.date(from: s) != nil
    }

    /// The day after a key.
    static func next(_ day: String) -> String? {
        guard let d = keyFormatter.date(from: day), let n = utc.date(byAdding: .day, value: 1, to: d) else { return nil }
        return keyFormatter.string(from: n)
    }

    /// A key as a date at noon UTC, for formatting its weekday and day.
    static func date(_ day: String) -> Date? {
        keyFormatter.date(from: day).map { $0.addingTimeInterval(12 * 3600) }
    }

    // MARK: Reading a feed

    /// The first list in `data` whose path ends with `suffix`, so any feed's path naming works.
    private static func list(_ data: [String: CmsJSON], endingWith suffix: String) -> [CmsJSON] {
        data.keys.sorted().lazy.compactMap { path -> [CmsJSON]? in
            guard path.hasSuffix(suffix) else { return nil }
            return data[path]?.arrayValue
        }.first ?? []
    }

    /// A feed's ranges as days. Days it does not mention are neither free nor unavailable.
    static func read(data: [String: CmsJSON]?, refreshedAt: String?) -> Unit {
        var free = Set<String>(), unavailable = Set<String>()
        let data = data ?? [:]
        let starts = list(data, endingWith: ".start")
        let ends = list(data, endingWith: ".end")
        let flags = list(data, endingWith: ".available")
        for i in starts.indices {
            guard let start = starts[i].stringValue.map({ String($0.prefix(10)) }) else { continue }
            let end = (i < ends.count ? ends[i].stringValue.map { String($0.prefix(10)) } : nil) ?? start
            guard isDayKey(start), isDayKey(end) else { continue }
            let flag = i < flags.count ? (flags[i].doubleValue ?? Double(flags[i].stringValue ?? "") ?? (flags[i].boolValue == true ? 1 : 0)) : 0
            var day: String? = start
            var n = 0
            // A year of days at most per range, whatever a feed says.
            while let d = day, d <= end, n < 400 {
                if flag > 0 { free.insert(d) } else { unavailable.insert(d) }
                day = next(d)
                n += 1
            }
        }
        unavailable.subtract(free)
        return Unit(free: free, unavailable: unavailable, refreshedAt: refreshedAt)
    }

    static func state(_ unit: Unit?, _ day: String) -> DayState {
        guard let unit else { return .unknown }
        return unit.free.contains(day) ? .free : unit.unavailable.contains(day) ? .taken : .unknown
    }

    // MARK: Stays

    /// The nights of a stay: arrival up to the day before departure.
    static func nights(_ arrival: String, _ departure: String) -> [String] {
        var out: [String] = []
        var day: String? = arrival
        while let d = day, d < departure, out.count < 400 {
            out.append(d)
            day = next(d)
        }
        return out
    }

    /// Whether a unit is free every night of a stay; the first night it is not, when it is not.
    static func stay(_ unit: Unit, _ nights: [String]) -> (free: Bool, firstTaken: String?) {
        if let taken = nights.first(where: { !unit.free.contains($0) }) { return (false, taken) }
        return (!nights.isEmpty, nil)
    }

    /// Whether the feeds rule these nights out for every unit, each taken on at
    /// least one of them. A unit whose feed has not answered, or a night it does
    /// not mention, keeps the choice open.
    static func ruledOut(_ units: [Unit?]?, _ nights: [String]) -> Bool {
        guard let units, !units.isEmpty, !nights.isEmpty else { return false }
        return units.allSatisfy { unit in
            guard let unit else { return false }
            return nights.contains { unit.unavailable.contains($0) }
        }
    }

    /// For stay nights ruled out, the latest day the stay could end instead.
    static func latestDeparture(_ units: [Unit?], _ nights: [String]) -> String? {
        var latest: String?
        for unit in units {
            guard let unit, let taken = nights.first(where: { unit.unavailable.contains($0) }) else { continue }
            if taken != nights.first, latest == nil || taken > latest! { latest = taken }
        }
        return latest
    }

    /// Whether to ask a feed for a fresh copy: it refreshes on view and its copy is older than its minutes.
    static func wantsRefresh(refreshedAt: String?, minutes: Double?, at: Date = Date()) -> Bool {
        guard let minutes, minutes > 0 else { return false }
        guard let refreshedAt, let then = parseInstant(refreshedAt) else { return true }
        return at.timeIntervalSince(then) >= minutes * 60
    }

    /// Of two copies of a unit's availability, the later; one that did not load never replaces one that did.
    static func newer(_ a: Unit?, _ b: Unit?) -> Unit? {
        guard let a else { return b }
        guard let b else { return a }
        return (b.refreshedAt ?? "") >= (a.refreshedAt ?? "") ? b : a
    }

    static func parseInstant(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    // MARK: Choosing dates

    struct Choice: Equatable {
        var arrival: String?
        var departure: String?
    }

    enum Outcome: Equatable {
        case chosen(Choice)
        /// Nothing changes; the words say why.
        case refused(String)
        case ignored
    }

    /// A tap on a day, as the web's `choose`: before today nothing; with no
    /// arrival (or a stay chosen, or a day not after the arrival) it becomes the
    /// arrival unless every unit is taken that night; otherwise it becomes the
    /// departure unless a night of the stay is taken in every unit.
    static func choose(_ day: String, current: Choice, units: [Unit?]?, today: String,
                       longDay: (String) -> String) -> Outcome {
        if day < today { return .ignored }
        if current.arrival == nil || current.departure != nil || day <= current.arrival! {
            if ruledOut(units, [day]) { return .refused("\(longDay(day)) is not available.") }
            return .chosen(Choice(arrival: day, departure: nil))
        }
        let arrival = current.arrival!
        // The departure day's own night may be taken: the guest leaves that morning.
        let stay = nights(arrival, day)
        if ruledOut(units, stay) {
            let latest = latestDeparture(units ?? [], stay)
            return .refused("Not available every night from \(longDay(arrival)) to \(longDay(day))."
                            + (latest.map { " You can stay until \(longDay($0))." } ?? ""))
        }
        return .chosen(Choice(arrival: arrival, departure: day))
    }

    // MARK: Props

    struct UnitProps: Equatable {
        var label: String
        var short: String
        var feed: String
        var bookUrl: String
        var color: String?
        var bookingKey: String?
        var maxGuests: Int
    }

    struct Props: Equatable {
        var units: [UnitProps]
        var months: Int
        var togetherLabel: String
        var markColor: String
        var togetherColor: String
        var surfacePaper: Bool
        var explainMarks: Bool
        var helpLabel: String
        var checkout: Bool

        /// A unit without its own colour takes the next of these, so each reads apart.
        static let unitColourTokens = ["color.primary", "color.success", "color.warning", "color.info", "color.error", "color.text.secondary"]

        /// The web's defaults (AvailabilityCalendarBlock.tsx `defaults`).
        init(_ p: [String: CmsJSON]) {
            let parsed = (p["units"]?.arrayValue ?? []).compactMap { raw -> UnitProps? in
                guard let o = raw.objectValue else { return nil }
                return UnitProps(label: o.string("label") ?? "Cottage", short: o.string("short") ?? "C",
                                 feed: o.string("feed") ?? "", bookUrl: o.string("bookUrl") ?? "",
                                 color: o.string("color").flatMap { $0.isEmpty ? nil : $0 },
                                 bookingKey: o.string("bookingKey").flatMap { $0.isEmpty ? nil : $0 },
                                 maxGuests: Int(o.double("maxGuests") ?? 6))
            }
            units = parsed.isEmpty ? [UnitProps(label: "Cottage", short: "C", feed: "", bookUrl: "", color: nil, bookingKey: nil, maxGuests: 6)] : parsed
            months = Int(p.double("months") ?? 2)
            togetherLabel = p.string("togetherLabel") ?? "All available"
            markColor = p.string("markColor").flatMap { $0.isEmpty ? nil : $0 } ?? "color.primary"
            togetherColor = p.string("togetherColor").flatMap { $0.isEmpty ? nil : $0 } ?? "color.accent"
            surfacePaper = p.string("surface") != "none"
            explainMarks = p.bool("explainMarks") == true
            helpLabel = p.string("helpLabel") ?? "Help"
            checkout = p.bool("checkout") == true
        }

        func colourToken(_ i: Int) -> String {
            units[i].color ?? Self.unitColourTokens[i % Self.unitColourTokens.count]
        }
    }

    /// "East Hampton, Montauk and Sag Harbor".
    static func listOf(_ names: [String]) -> String {
        names.count < 2 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + names.last!
    }

    static let numberWords = ["none", "one", "two", "three", "four", "five", "six"]
}
