import Foundation

// ---------------------------------------------------------------------------
// RipulBuildNumber — build stamps, rendered as the dates they already are
// ---------------------------------------------------------------------------
// Every build number this project mints is a timestamp wearing a disguise:
//
//   "202609190959"  native, shipped — ship_ios.py stamps
//                   datetime.now().strftime("%Y%m%d%H%M") into CFBundleVersion
//   "2026040902"    native, local — project.yml's CURRENT_PROJECT_VERSION, a
//                   date plus a two-digit sequence, no time of day in it
//   "mu87ulgb"      web — scripts/build.mjs stamps Date.now().toString(36)
//
// Nobody reads "202609190959" as half past nine this morning, so every surface
// that shows a build to a person decodes it here instead. The stamps themselves
// are deliberately untouched: CFBundleVersion has to stay numerically ascending
// for iOS to accept an upgrade, and both forms are sort keys elsewhere. This is
// only ever a rendering concern.
//
// Decoding can fail — an unstamped build is literally "1" — and when it does,
// every entry point hands back the raw string rather than inventing a date.
// ---------------------------------------------------------------------------

public enum RipulBuildNumber {

    /// The moment a build stamp encodes.
    public struct Stamp: Equatable, Sendable {
        public let date: Date
        /// False for the date-only forms, where printing a time of day would
        /// invent precision the stamp never carried.
        public let hasTime: Bool
    }

    /// Decode a build number, or nil when it isn't one of the stamped forms.
    public static func stamp(from build: String) -> Stamp? {
        let raw = build.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        return raw.allSatisfy(\.isNumber) ? numericStamp(raw) : base36Stamp(raw)
    }

    /// Human rendering of a build number: "Today at 9:59 AM", "Yesterday at
    /// 3:30 PM", "18 Sep 2026 at 3:30 PM". Returns `build` unchanged when it
    /// doesn't decode.
    ///
    /// - Parameter relative: today/yesterday wording. Turn it off inside a
    ///   sentence, where a capitalised "Today" mid-clause reads as a typo.
    public static func display(_ build: String, relative: Bool = true) -> String {
        guard let stamp = stamp(from: build) else { return build }
        return formatter(hasTime: stamp.hasTime, relative: relative).string(from: stamp.date)
    }

    /// The running build, rendered as a date and time.
    ///
    /// `display` can only report what the stamp encodes, and a locally built
    /// app carries project.yml's `CURRENT_PROJECT_VERSION` verbatim — a date
    /// and a sequence number, fixed months ago, with no time of day in it. So
    /// "you're on 9 Apr 2026" was both timeless and, for a binary compiled this
    /// morning, the wrong day.
    ///
    /// When the stamp carries no time, the compiled-at date does: it is the
    /// executable's own modification date, fixed for the life of an installed
    /// build. A shipped 12-digit stamp still wins, because that is the number
    /// the build feed and the install flow agree on.
    public static func displayRunning(_ build: String, relative: Bool = true) -> String {
        if let stamp = stamp(from: build), stamp.hasTime {
            return formatter(hasTime: true, relative: relative).string(from: stamp.date)
        }
        if let compiledAt {
            return formatter(hasTime: true, relative: relative).string(from: compiledAt)
        }
        return display(build, relative: relative)
    }

    /// When this binary was compiled, to the resolution the filesystem keeps.
    ///
    /// There is no Swift equivalent of `__DATE__`; the bundle executable's
    /// modification date is the closest honest answer, and it identifies the
    /// BUILD rather than the launch because it is baked in at copy time.
    public static let compiledAt: Date? = {
        guard let url = Bundle.main.executableURL else { return nil }
        return try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }()

    /// `display` with the raw stamp kept alongside it, for the diagnostic
    /// surfaces where the exact number is the thing you came to copy.
    /// Collapses to the raw stamp alone when it doesn't decode.
    public static func displayWithRaw(_ build: String, relative: Bool = true) -> String {
        guard stamp(from: build) != nil else { return build }
        return "\(display(build, relative: relative)) (\(build))"
    }

    // MARK: - Decoding

    private static func numericStamp(_ raw: String) -> Stamp? {
        let digits = Array(raw)
        func number(_ range: Range<Int>) -> Int? { Int(String(digits[range])) }

        // 8 = YYYYMMDD, 10 = YYYYMMDD + sequence, 12 = YYYYMMDDHHmm. Any other
        // length is some other numbering scheme and not ours to reinterpret.
        guard [8, 10, 12].contains(digits.count),
              let year = number(0..<4), (2000...2200).contains(year),
              let month = number(4..<6), (1...12).contains(month),
              let day = number(6..<8), (1...31).contains(day)
        else { return nil }

        var components = DateComponents(year: year, month: month, day: day)
        var hasTime = false

        if digits.count == 12 {
            // ship_ios.py resolves a same-minute collision by taking
            // `previous + 1`, so the trailing digits are not always a valid
            // HHmm (…2359 + 1 = …2360). Calendar rolls an over-range component
            // forward rather than refusing it, which lands a minute late — the
            // right answer, and certainly right enough to show someone.
            guard let hour = number(8..<10), (0...24).contains(hour),
                  let minute = number(10..<12), (0...60).contains(minute)
            else { return nil }
            components.hour = hour
            components.minute = minute
            hasTime = true
        }

        guard let date = Calendar.current.date(from: components) else { return nil }
        return Stamp(date: date, hasTime: hasTime)
    }

    private static func base36Stamp(_ raw: String) -> Stamp? {
        guard (6...10).contains(raw.count),
              let millis = UInt64(raw.lowercased(), radix: 36)
        else { return nil }
        let seconds = Double(millis) / 1000
        // Plenty of short base-36-shaped strings are not build stamps — a git
        // sha prefix, for one. Only a plausible calendar date is accepted.
        guard seconds >= 1_577_836_800,  // 2020-01-01
              seconds < 4_102_444_800    // 2100-01-01
        else { return nil }
        return Stamp(date: Date(timeIntervalSince1970: seconds), hasTime: true)
    }

    // MARK: - Formatters

    // Build stamps are local wall-clock time on whichever machine cut them, and
    // that machine is the user's own, so the default (local) time zone is the
    // one that reproduces what the build log said.
    private static let dateAndTimeRelative = formatter(timeStyle: .short, relative: true)
    private static let dateAndTimeAbsolute = formatter(timeStyle: .short, relative: false)
    private static let dateOnlyRelative = formatter(timeStyle: .none, relative: true)
    private static let dateOnlyAbsolute = formatter(timeStyle: .none, relative: false)

    private static func formatter(hasTime: Bool, relative: Bool) -> DateFormatter {
        switch (hasTime, relative) {
        case (true, true): return dateAndTimeRelative
        case (true, false): return dateAndTimeAbsolute
        case (false, true): return dateOnlyRelative
        case (false, false): return dateOnlyAbsolute
        }
    }

    private static func formatter(timeStyle: DateFormatter.Style, relative: Bool) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = timeStyle
        formatter.doesRelativeDateFormatting = relative
        return formatter
    }
}
