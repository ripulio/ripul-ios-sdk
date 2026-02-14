import SwiftUI
import RipulAgent

#if canImport(FoundationModels)
import FoundationModels
#endif

struct LocalModelTestView: View {
    @State private var inputText = ""
    @State private var messages: [ChatMessage] = []
    @State private var isGenerating = false
    @State private var modelAvailable = false
    @State private var generationMode: AppleFMGenerationMode = .dynamic
    @State private var promptHistory: [String] = []
    @State private var historyIndex: Int? = nil

    var body: some View {
        VStack(spacing: 0) {
            if !modelAvailable {
                unavailableView
            } else {
                modeSelector
                messageList
                inputBar
            }
        }
        .navigationTitle("Local Model")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Clear") {
                    messages.removeAll()
                }
                .disabled(messages.isEmpty)
            }
        }
        .task { checkAvailability() }
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if messages.isEmpty {
                        emptyState
                    }
                    ForEach(messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding()
            }
            .onChange(of: messages.count) { _, _ in
                if let last = messages.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "apple.intelligence")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Apple Foundation Models")
                .font(.headline)
            Text("Test on-device inference with the app's real tools.\nTry: \"what's on my calendar?\", \"search for lunch\", or just say hello.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: - Mode Selector

    private var modeSelector: some View {
        VStack(spacing: 4) {
            Picker("Generation Mode", selection: $generationMode) {
                ForEach(AppleFMGenerationMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)

            Text(generationMode == .dynamic
                 ? "Generic envelope: toolName + JSON string"
                 : "Typed fields per tool for stronger discrimination")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Message…", text: $inputText)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .onSubmit { sendMessage() }
                .onKeyPress(.upArrow) { cycleHistory(direction: .up); return .handled }
                .onKeyPress(.downArrow) { cycleHistory(direction: .down); return .handled }

            Button {
                sendMessage()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isGenerating)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Unavailable

    private var unavailableView: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Apple Foundation Models Unavailable")
                .font(.title3.weight(.semibold))
            Text("Requires iOS 26+ with Apple Intelligence enabled on a supported device.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func checkAvailability() {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            modelAvailable = true
        }
        #endif
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        promptHistory.append(text)
        historyIndex = nil

        let userMessage = ChatMessage(role: .user, content: text)
        messages.append(userMessage)
        inputText = ""
        isGenerating = true

        Task {
            await generateResponse(for: text)
            isGenerating = false
        }
    }

    private enum HistoryDirection { case up, down }

    private func cycleHistory(direction: HistoryDirection) {
        guard !promptHistory.isEmpty else { return }

        switch direction {
        case .up:
            if let idx = historyIndex {
                if idx > 0 { historyIndex = idx - 1 }
            } else {
                historyIndex = promptHistory.count - 1
            }
        case .down:
            if let idx = historyIndex {
                if idx < promptHistory.count - 1 {
                    historyIndex = idx + 1
                } else {
                    historyIndex = nil
                    inputText = ""
                    return
                }
            }
        }

        if let idx = historyIndex {
            inputText = promptHistory[idx]
        }
    }

    // MARK: - Tool Definitions

    /// interactWithUser is the conversation tool — not in YourTools since it's
    /// handled by the web agent, but we need it here for the model to talk back.
    private static let interactWithUserDef: [String: Any] = [
        "name": "interactWithUser",
        "description": "Send a message to the user. Use this for greetings, answers, and general conversation.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "interactions": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "message": ["type": "string", "description": "The message to display"],
                            "expectResponse": ["type": "boolean", "description": "Whether to wait for user input"],
                        ]
                    ]
                ]
            ]
        ]
    ]

    /// All tool definitions: real app tools first, interactWithUser last.
    /// Ordering matters — LLMs have positional bias toward earlier tools.
    private var toolDefs: [[String: Any]] {
        YourTools.all.map { $0.definition } + [Self.interactWithUserDef]
    }

    // MARK: - Generate

    private func generateResponse(for prompt: String) async {
        #if canImport(FoundationModels)
        guard #available(iOS 26, *) else {
            messages.append(ChatMessage(role: .assistant, content: "Apple Foundation Models requires iOS 26+."))
            return
        }

        do {
            let provider = AppleFoundationModelProvider(mode: generationMode)

            let timeline: [[String: Any]] = messages.filter { $0.role == .user }.map { msg in
                ["role": "user", "content": msg.content]
            }

            let tools = toolDefs

            let systemPrompt = """
            You are a calendar assistant. You MUST use the calendar tools for any request \
            about events, schedules, meetings, appointments, or time. \
            Only use interactWithUser when the user is just saying hello or greeting you.

            Examples:
            - "what's on my calendar" → list_events
            - "find lunch meetings" → search_events
            - "create a meeting tomorrow" → create_event
            - "delete that event" → delete_event
            - "hello" → interactWithUser
            """

            // Serialize the input payload for debugging
            let rawInputJSON = Self.toJSON([
                "mode": generationMode.rawValue,
                "systemPrompt": systemPrompt,
                "timeline": timeline,
                "tools": tools,
            ])

            let result = try await provider.generate(
                threadId: "test-\(UUID().uuidString)",
                systemPrompt: systemPrompt,
                timeline: timeline,
                tools: tools
            )

            // Serialize the output payload for debugging
            let rawOutputJSON = Self.toJSON([
                "toolName": result.toolName,
                "toolArgs": result.toolArgs,
            ])

            // Show the tool call decision
            let toolCallText = "**\(result.toolName)**\n\n" + Self.formatArgs(result.toolArgs)
            messages.append(ChatMessage(role: .assistant, content: toolCallText, rawInputJSON: rawInputJSON, rawOutputJSON: rawOutputJSON, mode: generationMode.rawValue))

            // Execute the tool if it's a real NativeTool
            if let nativeTool = YourTools.all.first(where: { $0.name == result.toolName }) {
                do {
                    let toolResult = try await nativeTool.execute(args: result.toolArgs)
                    let resultJSON = Self.toJSON(toolResult) ?? "\(toolResult)"
                    messages.append(ChatMessage(role: .toolResult, content: resultJSON))
                } catch {
                    messages.append(ChatMessage(role: .error, content: "Tool error: \(error.localizedDescription)"))
                }
            }
        } catch {
            messages.append(ChatMessage(role: .error, content: "Error: \(error.localizedDescription)"))
        }
        #else
        messages.append(ChatMessage(role: .error, content: "FoundationModels framework not available in this build."))
        #endif
    }

    // MARK: - Helpers

    private static func toJSON(_ value: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }

    private static func formatArgs(_ args: [String: Any]) -> String {
        // For interactWithUser, extract the message text
        if let interactions = args["interactions"] as? [[String: Any]] {
            let text = interactions.compactMap { $0["message"] as? String }.joined(separator: "\n\n")
            if !text.isEmpty { return text }
        }
        // For everything else, show pretty JSON
        return toJSON(args) ?? "(empty)"
    }
}

// MARK: - Models

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: ChatRole
    let content: String
    let rawInputJSON: String?
    let rawOutputJSON: String?
    let mode: String?
    let timestamp = Date()

    init(role: ChatRole, content: String, rawInputJSON: String? = nil, rawOutputJSON: String? = nil, mode: String? = nil) {
        self.role = role
        self.content = content
        self.rawInputJSON = rawInputJSON
        self.rawOutputJSON = rawOutputJSON
        self.mode = mode
    }
}

enum ChatRole {
    case user
    case assistant
    case toolResult
    case error
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: ChatMessage
    @State private var showInput = false
    @State private var showOutput = false

    private var hasDebugInfo: Bool {
        message.rawInputJSON != nil || message.rawOutputJSON != nil
    }

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 60) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                Text(roleLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 0) {
                    Text(LocalizedStringKey(message.content))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)

                    if hasDebugInfo {
                        Divider().padding(.horizontal, 8)

                        HStack(spacing: 12) {
                            if message.rawInputJSON != nil {
                                debugToggle(label: "Input", isOn: $showInput)
                            }
                            if message.rawOutputJSON != nil {
                                debugToggle(label: "Output", isOn: $showOutput)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                    }

                    if showInput, let json = message.rawInputJSON {
                        jsonSection(title: "Request", json: json)
                    }

                    if showOutput, let json = message.rawOutputJSON {
                        jsonSection(title: "Response", json: json)
                    }
                }
                .background(bubbleColor)
                .foregroundStyle(message.role == .user ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }

            if message.role != .user { Spacer(minLength: 60) }
        }
    }

    private func debugToggle(label: String, isOn: Binding<Bool>) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isOn.wrappedValue.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isOn.wrappedValue ? "chevron.up" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                Text(label)
                    .font(.caption2.weight(.medium))
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }

    private func jsonSection(title: String, json: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.horizontal, 8)
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 4)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(json)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
        }
    }

    private var roleLabel: String {
        switch message.role {
        case .user: "You"
        case .assistant:
            if let mode = message.mode {
                "Apple FM (\(mode))"
            } else {
                "Apple FM"
            }
        case .toolResult: "Tool Result"
        case .error: "Error"
        }
    }

    private var bubbleColor: Color {
        switch message.role {
        case .user: .blue
        case .assistant: Color(.systemGray5)
        case .toolResult: .green.opacity(0.15)
        case .error: .red.opacity(0.15)
        }
    }
}

#Preview {
    NavigationStack {
        LocalModelTestView()
    }
}
