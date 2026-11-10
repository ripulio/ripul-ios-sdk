import Foundation

/// The `elapsedTimer` block's rules (the web's
/// `packages/shared-types/src/cmsElapsedTimer.ts`, held equal by
/// `cmsElapsedTimer.cases.json` in CmsElapsedTimerTests): a live time counting
/// up from a start column of a query's first row, less a column of seconds
/// (finished unpaid breaks), or a pause's own time while `pausedAt` has a value.
struct CmsElapsedTimer: Equatable {
    var querySlug: String?
    var start: String?
    var minusSeconds: String?
    var pausedAt: String?
    var label: String?
    var pausedLabel: String?
    var emptyText: String?
    /// `hm-s` (H:MM with "SS seconds" under it) or `hms`.
    var format: String
    var centred: Bool

    init(_ props: [String: CmsJSON]) {
        func text(_ k: String) -> String? { props.string(k).flatMap { $0.isEmpty ? nil : $0 } }
        querySlug = text("querySlug")
        start = text("start")
        minusSeconds = text("minusSeconds")
        pausedAt = text("pausedAt")
        label = props.string("label")
        pausedLabel = props.string("pausedLabel")
        emptyText = props.string("emptyText")
        format = props.string("format") == "hms" ? "hms" : "hm-s"
        centred = props.string("align") != "leading"
    }

    /// Read the query again at most this often when the app becomes active.
    static let foregroundRefetch: TimeInterval = 15

    enum Mode: String { case running, paused, empty }

    struct State: Equatable {
        var mode: Mode
        var seconds: Int
        var label: String
        var main: String
        var sub: String
    }

    /// A column's value as a date: ISO 8601 (with or without fractions or a
    /// zone; none is UTC, as a database time), or epoch seconds or milliseconds.
    static func time(_ v: CmsJSON?) -> Date? {
        switch v {
        case .number(let n)?: return Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n)
        case .string(let raw)?:
            let s = raw.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty else { return nil }
            var iso = s.replacingOccurrences(of: " ", with: "T")
            if !(iso.hasSuffix("Z") || iso.range(of: #"[+-]\d\d:?\d\d$"#, options: .regularExpression) != nil) { iso += "Z" }
            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = withFraction.date(from: iso) { return d }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            return plain.date(from: iso)
        default: return nil
        }
    }

    static func format(_ seconds: Int, _ format: String) -> (main: String, sub: String) {
        let s = max(0, seconds)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if format == "hms" { return (String(format: "%d:%02d:%02d", h, m, sec), "") }
        return (String(format: "%d:%02d", h, m), String(format: "%02d seconds", sec))
    }

    func state(row: [String: CmsJSON]?, now: Date) -> State {
        guard let row, let start, let started = Self.time(row[start]) else {
            return State(mode: .empty, seconds: 0, label: emptyText ?? "", main: "", sub: "")
        }
        if let pausedAt, let paused = Self.time(row[pausedAt]) {
            let seconds = max(0, Int(floor(now.timeIntervalSince(paused))))
            let f = Self.format(seconds, format)
            return State(mode: .paused, seconds: seconds, label: pausedLabel ?? "Paused", main: f.main, sub: f.sub)
        }
        var minus = 0.0
        if let minusSeconds {
            switch row[minusSeconds] {
            case .number(let n)?: minus = n
            case .string(let t)?: minus = Double(t) ?? 0
            default: break
            }
        }
        let seconds = max(0, Int(floor(now.timeIntervalSince(started) - minus)))
        let f = Self.format(seconds, format)
        return State(mode: .running, seconds: seconds, label: label ?? "", main: f.main, sub: f.sub)
    }
}
