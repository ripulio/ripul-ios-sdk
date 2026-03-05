import Foundation
import RipulAgent

// ═══════════════════════════════════════════════════════════════════════════
// Tool Registration — this is the only new code you write
// ═══════════════════════════════════════════════════════════════════════════
//
// Each struct wraps your existing CalendarService (from AppServices.swift)
// and describes it for the agent with a name, description, and JSON Schema.
//
// The SDK provides:
//
// Schema builder (type-safe):
//   ToolSchema.object(
//       .string("title", "Event title", required: true),
//       .bool("isAllDay", "All-day event")
//   )
//
// Arg extraction helpers:
//   try string("title", from: args)
//   try date("startDate", from: args)
//   optionalString("notes", from: args)
//   bool("isAllDay", from: args)
//

enum YourTools {
    static let all: [NativeTool] = [
        ListEventsTool(),
        CreateEventTool(),
        DeleteEventTool(),
        SearchEventsTool(),
        StoreReceiptTool(),
    ]
}

// MARK: - list_events

struct ListEventsTool: NativeTool {
    let name = "list_events"
    let description = "Lists calendar events within a date range. Defaults to the next 7 days if no dates are provided."
    let inputSchema = ToolSchema.object(
        .string("startDate", "Start of range in ISO 8601 format (e.g. 2025-03-15T00:00:00Z). Defaults to now."),
        .string("endDate", "End of range in ISO 8601 format. Defaults to 7 days from start.")
    )

    func execute(args: [String: Any]) async throws -> Any {
        let start = try optionalDate("startDate", from: args) ?? Date()
        let end = try optionalDate("endDate", from: args) ?? Calendar.current.date(byAdding: .day, value: 7, to: start)!

        // ⬇ Call your existing API (AppServices.swift)
        let events = CalendarService.shared.fetchEvents(from: start, to: end)

        return [
            "success": true,
            "count": events.count,
            "events": events.map(\.asDictionary),
        ] as [String: Any]
    }
}

// MARK: - create_event

struct CreateEventTool: NativeTool {
    let name = "create_event"
    let description = "Creates a new calendar event. Returns the created event details including its ID."
    let inputSchema = ToolSchema.object(
        .string("title", "Event title", required: true),
        .string("startDate", "Start time in ISO 8601 format (e.g. 2025-03-15T09:00:00Z)", required: true),
        .string("endDate", "End time in ISO 8601 format (e.g. 2025-03-15T10:00:00Z)", required: true),
        .string("notes", "Optional notes for the event"),
        .string("location", "Optional location for the event"),
        .bool("isAllDay", "Whether this is an all-day event. Defaults to false.")
    )

    func execute(args: [String: Any]) async throws -> Any {
        let title = try string("title", from: args)
        let start = try date("startDate", from: args)
        let end = try date("endDate", from: args)

        do {
            // ⬇ Call your existing API (AppServices.swift)
            let event = try CalendarService.shared.createEvent(
                title: title,
                startDate: start,
                endDate: end,
                notes: optionalString("notes", from: args),
                location: optionalString("location", from: args),
                isAllDay: bool("isAllDay", from: args)
            )
            return [
                "success": true,
                "event": event.asDictionary,
            ] as [String: Any]
        } catch {
            // Enrich the underlying error with context the LLM can act on
            throw ToolError.invalidArgs(
                "Failed to create event '\(title)': \(error.localizedDescription). "
                + "Check that the device has a calendar configured and the dates are valid."
            )
        }
    }
}

// MARK: - delete_event

struct DeleteEventTool: NativeTool {
    let name = "delete_event"
    let description = "Deletes a calendar event by its ID. Use list_events first to find the event ID."
    let inputSchema = ToolSchema.object(
        .string("id", "The event identifier returned by list_events or create_event", required: true)
    )

    func execute(args: [String: Any]) async throws -> Any {
        let id = try string("id", from: args)

        // ⬇ Call your existing API (AppServices.swift)
        let deleted = try CalendarService.shared.deleteEvent(identifier: id)
        return [
            "success": deleted,
            "id": id,
        ] as [String: Any]
    }
}

// MARK: - store_receipt

struct StoreReceiptTool: NativeTool {
    let name = "store_receipt"
    let description = "Stores a receipt as a calendar event. Captures formal receipt fields and saves them to the calendar with formatted notes. Use this when a user wants to log or save a purchase receipt."
    let inputSchema = ToolSchema.object(
        .string("storeName", "Name of the store or merchant", required: true),
        .string("date", "Purchase date in ISO 8601 format (e.g. 2025-03-15T00:00:00Z)", required: true),
        .string("total", "Total amount including currency symbol (e.g. $42.50)", required: true),
        .string("items", "Line items, one per line (e.g. Coffee $4.50\\nSandwich $8.00)"),
        .string("paymentMethod", "Payment method (e.g. Visa ending 1234, Cash, Apple Pay)"),
        .string("receiptNumber", "Transaction or receipt reference number"),
        .string("tax", "Tax amount including currency symbol (e.g. $3.50)"),
        .string("currency", "Currency code (e.g. USD, EUR). Defaults to local currency.")
    )

    func execute(args: [String: Any]) async throws -> Any {
        let storeName = try string("storeName", from: args)
        let purchaseDate = try date("date", from: args)
        let total = try string("total", from: args)
        let items = optionalString("items", from: args)
        let paymentMethod = optionalString("paymentMethod", from: args)
        let receiptNumber = optionalString("receiptNumber", from: args)
        let tax = optionalString("tax", from: args)
        let currency = optionalString("currency", from: args)

        // Build formatted notes
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short

        var lines: [String] = []
        lines.append("🧾 Receipt")
        lines.append("Store: \(storeName)")
        lines.append("Date: \(formatter.string(from: purchaseDate))")
        if let receiptNumber { lines.append("Receipt #: \(receiptNumber)") }
        if let currency { lines.append("Currency: \(currency)") }
        lines.append("")
        if let items {
            lines.append("Items:")
            lines.append(items)
            lines.append("")
        }
        if let tax { lines.append("Tax: \(tax)") }
        lines.append("Total: \(total)")
        if let paymentMethod { lines.append("Payment: \(paymentMethod)") }

        let notes = lines.joined(separator: "\n")

        // Create an all-day event on the purchase date
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: purchaseDate)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

        do {
            let event = try CalendarService.shared.createEvent(
                title: "Receipt: \(storeName)",
                startDate: startOfDay,
                endDate: endOfDay,
                notes: notes,
                location: storeName,
                isAllDay: true
            )
            return [
                "success": true,
                "event": event.asDictionary,
            ] as [String: Any]
        } catch {
            throw ToolError.invalidArgs(
                "Failed to store receipt for '\(storeName)': \(error.localizedDescription). "
                + "Check that the device has a calendar configured."
            )
        }
    }
}

// MARK: - search_events

struct SearchEventsTool: NativeTool {
    let name = "search_events"
    let description = "Searches calendar events by keyword in title, notes, or location. Searches the next 30 days by default."
    let inputSchema = ToolSchema.object(
        .string("query", "Search term to match against event title, notes, or location", required: true),
        .string("startDate", "Start of search range in ISO 8601 format. Defaults to now."),
        .string("endDate", "End of search range in ISO 8601 format. Defaults to 30 days from start.")
    )

    func execute(args: [String: Any]) async throws -> Any {
        let query = try string("query", from: args)
        let start = try optionalDate("startDate", from: args) ?? Date()
        let end = try optionalDate("endDate", from: args) ?? Calendar.current.date(byAdding: .day, value: 30, to: start)!

        // ⬇ Call your existing API (AppServices.swift)
        let events = CalendarService.shared.searchEvents(query: query, from: start, to: end)

        return [
            "success": true,
            "query": query,
            "count": events.count,
            "events": events.map(\.asDictionary),
        ] as [String: Any]
    }
}