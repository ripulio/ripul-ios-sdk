import Foundation
import OSLog

/// WebKit's UI-process messages belong to this app's log store, even though
/// the renderer runs in another process. They can contain a termination reason
/// that WKNavigationDelegate doesn't expose. A generic "Crash" still needs an
/// OS crash/jetsam report to distinguish the underlying causes.
public struct WebKitTerminationLog: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public let timestamp: Date
        public let category: String
        public let message: String
    }

    public let entries: [Entry]
    public let error: String?
    public let truncated: Bool

    /// Call off the main thread, after allowing the log daemon to flush. Keep
    /// the query anchored to the incident if the app was suspended meanwhile.
    static func read(around incident: Date) -> Self {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let start = incident.addingTimeInterval(-10)
            let end = incident.addingTimeInterval(2)
            let predicate = NSPredicate(format: "subsystem BEGINSWITH %@ AND ("
                + "eventMessage CONTAINS[c] %@ OR eventMessage CONTAINS[c] %@ OR "
                + "eventMessage CONTAINS[c] %@ OR eventMessage CONTAINS[c] %@ OR "
                + "eventMessage CONTAINS[c] %@ OR eventMessage CONTAINS[c] %@)",
                "com.apple.WebKit", "terminat", "crash", "exceeded", "memory limit", "invalid message", "unresponsive")
            let records = try store.getEntries(at: store.position(date: start), matching: predicate)
            var entries: [Entry] = []
            for case let entry as OSLogEntryLog in records {
                // Some OS versions enumerate entries before the requested position.
                guard entry.date >= start else { continue }
                if entry.date > end { break }
                if entries.count == 20 { return Self(entries: entries, error: nil, truncated: true) }
                entries.append(Entry(timestamp: entry.date, category: entry.category,
                                     message: WebViewLogRedaction.text(entry.composedMessage, limit: 800)))
            }
            return Self(entries: entries, error: nil, truncated: false)
        } catch {
            return Self(entries: [], error: WebViewLogRedaction.text(error.localizedDescription, limit: 300), truncated: false)
        }
    }
}
