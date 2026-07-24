import SwiftUI

private enum RelativeTimeTicker {
    static let shared = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
}

/// Shows seconds for the first minute, then rounds to minutes.
/// Re-renders only when the displayed label would actually change.
struct RelativeTimeText: View {
    let date: Date
    @State private var now = Date()

    private var label: String { RelativeTimeText.string(for: date, relativeTo: now) }

    /// Single source of truth for terse relative-time strings ("5s", "1m", "2h", "3d").
    static func string(for date: Date, relativeTo now: Date) -> String {
        let secs = Int(max(0, now.timeIntervalSince(date)))
        if secs < 60 { return "\(secs)s" }
        let mins = secs / 60
        if mins < 60 { return "\(mins)m" }
        let hrs = mins / 60
        if hrs < 24 { return "\(hrs)h" }
        return "\(hrs / 24)d"
    }

    var body: some View {
        Text(label)
            .monospacedDigit()
            .frame(minWidth: 28, alignment: .trailing)
            .onReceive(RelativeTimeTicker.shared) { tick in
                // Only touch state when the rendered label changes — rows past
                // the seconds range skip 59 of every 60 ticks instead of
                // re-rendering.
                if Self.string(for: date, relativeTo: tick) != label { now = tick }
            }
    }
}
