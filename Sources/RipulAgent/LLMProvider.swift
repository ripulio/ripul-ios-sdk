import Foundation

/// Result of an LLM inference request — a tool call the model wants to execute.
public struct LLMToolCallResult {
    public let toolName: String
    public let toolArgs: [String: Any]
    public let inputTokens: Int
    public let outputTokens: Int

    public init(toolName: String, toolArgs: [String: Any], inputTokens: Int = 0, outputTokens: Int = 0) {
        self.toolName = toolName
        self.toolArgs = toolArgs
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

/// Protocol for native LLM providers.
/// Conform to this to provide on-device inference via Apple Foundation Models or other engines.
@MainActor
public protocol LLMProvider {
    /// Run inference on the conversation and return a tool call.
    ///
    /// - Parameters:
    ///   - threadId: Conversation thread identifier (for session tracking)
    ///   - systemPrompt: System instructions for the model
    ///   - timeline: Conversation history as array of message dicts ({role, content, tool_calls})
    ///   - tools: Available tool definitions ({name, description, parameters})
    /// - Returns: The tool call the model wants to execute
    func generate(
        threadId: String,
        systemPrompt: String,
        timeline: [[String: Any]],
        tools: [[String: Any]]
    ) async throws -> LLMToolCallResult
}
