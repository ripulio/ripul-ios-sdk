import EventKit
import Foundation

// ═══════════════════════════════════════════════════════════════════════════
// Your app's existing calendar service
// ═══════════════════════════════════════════════════════════════════════════
//
// This is the kind of service your app already has. It wraps EventKit and
// provides a clean API for your view models. Nothing here is agent-specific.

final class CalendarService: ObservableObject {
    static let shared = CalendarService()

    let store = EKEventStore()
    @Published var hasAccess = false

    private init() {}

    // MARK: - Permissions

    func requestAccess() async -> Bool {
        do {
            let granted = try await store.requestFullAccessToEvents()
            await MainActor.run { hasAccess = granted }
            return granted
        } catch {
            return false
        }
    }

    // MARK: - Read

    func fetchEvents(from startDate: Date, to endDate: Date) -> [EKEvent] {
        let predicate = store.predicateForEvents(withStart: startDate, end: endDate, calendars: nil)
        return store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
    }

    func searchEvents(query: String, from startDate: Date, to endDate: Date) -> [EKEvent] {
        fetchEvents(from: startDate, to: endDate).filter {
            $0.title?.localizedCaseInsensitiveContains(query) == true ||
            $0.notes?.localizedCaseInsensitiveContains(query) == true ||
            $0.location?.localizedCaseInsensitiveContains(query) == true
        }
    }

    // MARK: - Write

    func createEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        notes: String? = nil,
        location: String? = nil,
        isAllDay: Bool = false
    ) throws -> EKEvent {
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = startDate
        event.endDate = endDate
        event.notes = notes
        event.location = location
        event.isAllDay = isAllDay
        event.calendar = store.defaultCalendarForNewEvents
        try store.save(event, span: .thisEvent)
        NotificationCenter.default.post(name: .calendarDidChange, object: nil)
        return event
    }

    func deleteEvent(identifier: String) throws -> Bool {
        guard let event = store.event(withIdentifier: identifier) else {
            return false
        }
        try store.remove(event, span: .thisEvent)
        NotificationCenter.default.post(name: .calendarDidChange, object: nil)
        return true
    }

    /// Delete all events from all calendars. Returns the number deleted.
    func deleteAllEvents() throws -> Int {
        let cal = Calendar.current
        let start = cal.date(byAdding: .year, value: -5, to: Date())!
        let end = cal.date(byAdding: .year, value: 5, to: Date())!
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate)
        for event in events {
            try store.remove(event, span: .thisEvent)
        }
        if !events.isEmpty {
            NotificationCenter.default.post(name: .calendarDidChange, object: nil)
        }
        return events.count
    }
}

// MARK: - Notification

extension Notification.Name {
    static let calendarDidChange = Notification.Name("calendarDidChange")
}

// MARK: - Helpers

extension EKEvent {
    /// Dictionary representation for the agent.
    var asDictionary: [String: Any] {
        var dict: [String: Any] = [
            "id": eventIdentifier ?? "",
            "title": title ?? "",
            "startDate": ISO8601DateFormatter().string(from: startDate),
            "endDate": ISO8601DateFormatter().string(from: endDate),
            "isAllDay": isAllDay,
        ]
        if let notes { dict["notes"] = notes }
        if let location { dict["location"] = location }
        if let calendar { dict["calendar"] = calendar.title }
        return dict
    }
}
