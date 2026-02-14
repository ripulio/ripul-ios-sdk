#if canImport(FoundationModels)
import Foundation
import FoundationModels

// MARK: - Generation Mode

/// Controls whether Apple FM uses a dynamic JSON string envelope or typed fields.
public enum AppleFMGenerationMode: String, CaseIterable {
    case dynamic = "Dynamic"
    case `static` = "Static"
}

// MARK: - Dynamic approach (generic envelope)

/// The model outputs a tool name + a JSON string of arguments.
/// Fully generic — any tool definition is supported without per-tool structs.
@available(iOS 26, *)
@Generable
struct DynamicToolCallDecision {
    @Guide(description: "The name of the tool to call.")
    var toolName: String

    @Guide(description: "The tool arguments as a JSON object string, e.g. {\"key\": \"value\"}.")
    var toolArgsJSON: String
}

@available(iOS 26, *)
extension DynamicToolCallDecision {
    var toolArgs: [String: Any] {
        guard let data = toolArgsJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return dict
    }
}

// MARK: - Static approach (typed fields)

/// The model outputs a tool name + typed optional fields.
/// @Guide descriptions are kept short and tool-neutral to avoid biasing
/// the model toward any particular tool.
@available(iOS 26, *)
@Generable
struct StaticToolCallDecision {
    @Guide(description: "The tool to call.")
    var toolName: String

    // Date range fields
    @Guide(description: "Start date in ISO 8601 format, e.g. 2025-03-15T09:00:00Z.")
    var startDate: String?

    @Guide(description: "End date in ISO 8601 format, e.g. 2025-03-15T10:00:00Z.")
    var endDate: String?

    // Event fields
    @Guide(description: "Event title.")
    var title: String?

    @Guide(description: "Event notes.")
    var notes: String?

    @Guide(description: "Event location.")
    var location: String?

    @Guide(description: "All-day flag.")
    var isAllDay: Bool?

    // ID field
    @Guide(description: "Event identifier.")
    var eventId: String?

    // Search field
    @Guide(description: "Search keyword.")
    var query: String?

    // Conversation fields
    @Guide(description: "Message text to display.")
    var message: String?

    @Guide(description: "Whether to wait for a response.")
    var expectResponse: Bool?
}

@available(iOS 26, *)
extension StaticToolCallDecision {
    /// Convert the typed fields into a [String: Any] dictionary based on toolName.
    var toolArgs: [String: Any] {
        switch toolName {
        case "list_events":
            var args: [String: Any] = [:]
            if let v = startDate { args["startDate"] = v }
            if let v = endDate { args["endDate"] = v }
            return args

        case "create_event":
            var args: [String: Any] = [:]
            if let v = title { args["title"] = v }
            if let v = startDate { args["startDate"] = v }
            if let v = endDate { args["endDate"] = v }
            if let v = notes { args["notes"] = v }
            if let v = location { args["location"] = v }
            if let v = isAllDay { args["isAllDay"] = v }
            return args

        case "delete_event":
            var args: [String: Any] = [:]
            if let v = eventId { args["id"] = v }
            return args

        case "search_events":
            var args: [String: Any] = [:]
            if let v = query { args["query"] = v }
            if let v = startDate { args["startDate"] = v }
            if let v = endDate { args["endDate"] = v }
            return args

        case "interactWithUser":
            var interaction: [String: Any] = [:]
            if let v = message { interaction["message"] = v }
            if let v = expectResponse { interaction["expectResponse"] = v }
            return ["interactions": [interaction]]

        default:
            return [:]
        }
    }
}

#endif
