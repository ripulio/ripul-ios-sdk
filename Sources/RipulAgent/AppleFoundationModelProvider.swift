#if canImport(FoundationModels)
import Foundation
import FoundationModels

/// Apple Foundation Models provider for on-device LLM inference.
/// Requires iOS 26+ with Apple Intelligence support.
///
/// Uses `@Generable` structured output (not `@Tool`) so we can intercept
/// the model's tool call decision and route it through the bridge, rather
/// than having Apple FM auto-execute the tool locally.
///
/// Supports two generation modes:
/// - **Dynamic**: generic envelope (toolName + JSON string). Works with any tool.
/// - **Static**: typed fields per tool. May give better discrimination but
///   requires updating the `@Generable` struct when tools change.
///
/// Stateless: creates a fresh LanguageModelSession per generate() call
/// with the full conversation context.
@available(iOS 26, *)
@MainActor
public final class AppleFoundationModelProvider: LLMProvider {

    public var mode: AppleFMGenerationMode

    public init(mode: AppleFMGenerationMode = .dynamic) {
        self.mode = mode
    }

    public func generate(
        threadId: String,
        systemPrompt: String,
        timeline: [[String: Any]],
        tools toolDefs: [[String: Any]]
    ) async throws -> LLMToolCallResult {
        let fullInstructions = buildInstructions(systemPrompt: systemPrompt, tools: toolDefs)
        let session = LanguageModelSession(instructions: Instructions(fullInstructions))

        let prompt = buildPrompt(from: timeline)

        switch mode {
        case .dynamic:
            let response = try await session.respond(to: prompt, generating: DynamicToolCallDecision.self)
            let decision = response.content
            return LLMToolCallResult(
                toolName: decision.toolName,
                toolArgs: decision.toolArgs
            )

        case .static:
            let response = try await session.respond(to: prompt, generating: StaticToolCallDecision.self)
            let decision = response.content
            return LLMToolCallResult(
                toolName: decision.toolName,
                toolArgs: decision.toolArgs
            )
        }
    }

    // MARK: - Private

    /// Build compact instructions for the model. Includes tool names, descriptions,
    /// and parameter names (but not full JSON schemas which overwhelm the on-device model).
    private func buildInstructions(systemPrompt: String, tools: [[String: Any]]) -> String {
        var parts = [systemPrompt, "Available tools:"]

        // Tool name + description + parameter names
        for tool in tools {
            let name = tool["name"] as? String ?? "unknown"
            let description = tool["description"] as? String ?? ""
            var line = "- \(name): \(description)"

            // Extract parameter names from schema
            if let schema = tool["parameters"] ?? tool["inputSchema"],
               let schemaDict = schema as? [String: Any],
               let props = schemaDict["properties"] as? [String: Any] {
                let paramNames = props.keys.sorted().joined(separator: ", ")
                let required = schemaDict["required"] as? [String] ?? []
                if !paramNames.isEmpty {
                    let requiredNote = required.isEmpty ? "" : " (required: \(required.joined(separator: ", ")))"
                    line += "\n  Parameters: \(paramNames)\(requiredNote)"
                }
            }

            parts.append(line)
        }

        switch mode {
        case .dynamic:
            parts.append("""
            Set toolName to the chosen tool. \
            Set toolArgsJSON to a JSON object string with the tool's arguments. \
            All dates must be ISO 8601 format like 2025-03-15T09:00:00Z.
            """)

        case .static:
            parts.append("""
            Set toolName to the chosen tool. \
            Fill in the fields listed below for that tool. Leave all other fields empty. \
            Ignore the "Parameters" line above — use ONLY these field names. \
            All dates must be ISO 8601 format like 2025-03-15T09:00:00Z.

            Field mapping:
            - list_events: set startDate, endDate
            - create_event: set title, startDate, endDate, notes, location, isAllDay
            - delete_event: set eventId
            - search_events: set query, startDate, endDate
            - interactWithUser: set message (your text), expectResponse (true/false). \
            For multiple choice, also set optionsJSON to a JSON array like [{"label":"Yes","value":"yes"},{"label":"No","value":"no"}]
            """)
        }

        return parts.joined(separator: "\n")
    }

    /// Build a prompt string from the conversation timeline.
    private func buildPrompt(from timeline: [[String: Any]]) -> String {
        var parts: [String] = []

        for message in timeline {
            let role = message["role"] as? String ?? "user"
            let content = message["content"]

            if let text = content as? String {
                parts.append("[\(role)]: \(text)")
            } else if let blocks = content as? [[String: Any]] {
                for block in blocks {
                    let blockType = block["type"] as? String ?? ""
                    if blockType == "text", let text = block["text"] as? String {
                        parts.append("[\(role)]: \(text)")
                    } else if blockType == "tool_result" {
                        let toolName = block["tool_name"] as? String ?? "unknown"
                        if let resultContent = block["content"] as? [[String: Any]] {
                            for item in resultContent {
                                if let text = item["text"] as? String {
                                    parts.append("[tool_result from \(toolName)]: \(text)")
                                }
                            }
                        } else if let resultText = block["content"] as? String {
                            parts.append("[tool_result from \(toolName)]: \(resultText)")
                        }
                    }
                }
            }
        }

        if parts.isEmpty {
            return "Hello"
        }

        return parts.joined(separator: "\n\n")
    }
}

#endif
