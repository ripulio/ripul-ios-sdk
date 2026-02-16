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
    @State private var enabledTools: Set<String> = Set(Self.allToolNames)
    @State private var showToolToggles = false
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if !modelAvailable {
                unavailableView
            } else {
                modeSelector
                toolTogglesSection
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

    private static let samplePrompts = [
        "What's on my calendar this week?",
        "Search for lunch meetings",
        "Hello, what can you do?",
        "Setup a lunch meeting with Bob at The Whitehall Restaurant next monday at 1pm for 2hrs",
        "Ask me a multiple choice quiz question",
    ]

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "apple.intelligence")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Apple Foundation Models")
                .font(.headline)
            Text("Test on-device inference with the app's real tools.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 8) {
                ForEach(Self.samplePrompts, id: \.self) { prompt in
                    Button {
                        inputText = prompt
                        isInputFocused = true
                    } label: {
                        Text(prompt)
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color(.systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
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

    // MARK: - Tool Toggles

    /// All tool names in display order: real tools first, then interactWithUser.
    private static let allToolNames: [String] =
        YourTools.all.map(\.name) + ["interactWithUser"]

    private var toolTogglesSection: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showToolToggles.toggle()
                }
            } label: {
                HStack {
                    Image(systemName: showToolToggles ? "wrench.and.screwdriver.fill" : "wrench.and.screwdriver")
                        .font(.caption)
                    Text("Tools (\(enabledTools.count)/\(Self.allToolNames.count))")
                        .font(.caption.weight(.medium))
                    Spacer()
                    Image(systemName: showToolToggles ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)

            if showToolToggles {
                VStack(spacing: 0) {
                    ForEach(Self.allToolNames, id: \.self) { name in
                        toolToggleRow(name: name)
                    }

                    HStack(spacing: 12) {
                        Button("All") {
                            enabledTools = Set(Self.allToolNames)
                        }
                        .disabled(enabledTools.count == Self.allToolNames.count)

                        Button("None") {
                            enabledTools.removeAll()
                        }
                        .disabled(enabledTools.isEmpty)
                    }
                    .font(.caption)
                    .padding(.vertical, 6)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Divider()
        }
        .background(Color(.systemGray6).opacity(0.5))
    }

    private func toolToggleRow(name: String) -> some View {
        let isOn = Binding<Bool>(
            get: { enabledTools.contains(name) },
            set: { enabled in
                if enabled { enabledTools.insert(name) }
                else { enabledTools.remove(name) }
            }
        )

        return Toggle(isOn: isOn) {
            HStack(spacing: 6) {
                Image(systemName: toolIcon(for: name))
                    .font(.caption)
                    .frame(width: 16)
                Text(name)
                    .font(.system(.caption, design: .monospaced))
            }
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .padding(.horizontal)
        .padding(.vertical, 4)
    }

    private func toolIcon(for name: String) -> String {
        switch name {
        case "list_events": return "list.bullet"
        case "create_event": return "plus.circle"
        case "delete_event": return "trash"
        case "search_events": return "magnifyingglass"
        case "interactWithUser": return "bubble.left"
        default: return "wrench"
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message…", text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($isInputFocused)
                .onSubmit { sendMessage() }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .onKeyPress(.upArrow) { cycleHistory(direction: .up); return .handled }
                .onKeyPress(.downArrow) { cycleHistory(direction: .down); return .handled }

            Button {
                sendMessage()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isGenerating || enabledTools.isEmpty)
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
        "description": "Communicate with the user through messages, questions, or multiple-choice prompts. Prefer to ask the user multiple choice questions where-ever possible, as they can choose to ignore the multiple choices and reply by text.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "interactions": [
                    "type": "array",
                    "description": "Array of interaction objects to process sequentially",
                    "items": [
                        "type": "object",
                        "properties": [
                            "message": [
                                "type": "string",
                                "description": "The content to display. Supports markdown formatting."
                            ],
                            "expectResponse": [
                                "type": "boolean",
                                "description": "If true, this interaction pauses for user input. False to notify."
                            ],
                            "options": [
                                "type": "array",
                                "description": "Choices to present as buttons. If provided, the tool will wait for user selection regardless of expectResponse.",
                                "items": [
                                    "type": "object",
                                    "properties": [
                                        "label": ["type": "string", "description": "Text shown on the button"],
                                        "value": ["description": "Value returned when this option is selected"],
                                        "description": ["type": "string", "description": "Additional context shown as a tooltip"]
                                    ],
                                    "required": ["label", "value"]
                                ]
                            ],
                            "multiSelect": [
                                "type": "boolean",
                                "description": "When true, allows multiple options to be selected. Only applies when options are provided. Defaults to false."
                            ],
                            "severity": [
                                "type": "string",
                                "enum": ["info", "warning", "error"],
                                "description": "Visual styling to indicate message importance."
                            ]
                        ],
                        "required": ["message", "expectResponse"]
                    ]
                ]
            ],
            "required": ["interactions"]
        ]
    ]

    /// All tool definitions filtered by the enabled toggles.
    /// Ordering matters — LLMs have positional bias toward earlier tools.
    private var toolDefs: [[String: Any]] {
        let appTools = YourTools.all
            .filter { enabledTools.contains($0.name) }
            .map { $0.definition }
        let conversationTool = enabledTools.contains("interactWithUser") ? [Self.interactWithUserDef] : []
        return appTools + conversationTool
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

            let toolNames = tools.compactMap { $0["name"] as? String }
            let now = Date()
            let dateFmt = DateFormatter()
            dateFmt.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a"
            let nowString = dateFmt.string(from: now)

            let systemPrompt = """
            You are a calendar assistant. Today is \(nowString). \
            You MUST set toolName to one of these exact values: \(toolNames.joined(separator: ", ")). \
            Use calendar tools for anything about events, schedules, meetings, or time. \
            Use interactWithUser for greetings, general conversation, questions, and answers. \
            Use multiple choice options when it makes sense.

            IMPORTANT: delete_event requires an event ID. If the user asks to delete an event \
            by name or description, use search_events FIRST to find the ID, then delete_event.

            Examples:
            - "what's on my calendar" → toolName: list_events
            - "find lunch meetings" → toolName: search_events
            - "create a meeting tomorrow" → toolName: create_event
            - "delete the lunch meeting" → toolName: search_events (find ID first, then delete)
            - "delete event ID abc123" → toolName: delete_event (only when you have the ID)
            - "hello" → toolName: interactWithUser
            - "ask me something" → toolName: interactWithUser (with options)
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
            let toolArgsJSON = Self.toJSON(result.toolArgs)
            let toolCallText = "**\(result.toolName)**\n\n" + Self.formatArgs(result.toolArgs)
            messages.append(ChatMessage(role: .assistant, content: toolCallText, toolName: result.toolName, toolCallJSON: toolArgsJSON, rawInputJSON: rawInputJSON, rawOutputJSON: rawOutputJSON, mode: generationMode.rawValue))

            // Execute the tool if it's a real NativeTool and currently enabled
            if let nativeTool = YourTools.all.first(where: { $0.name == result.toolName && enabledTools.contains($0.name) }) {
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
        // For interactWithUser, extract message + options
        if let interactions = args["interactions"] as? [[String: Any]] {
            var parts: [String] = []
            for interaction in interactions {
                if let msg = interaction["message"] as? String {
                    parts.append(msg)
                }
                if let severity = interaction["severity"] as? String {
                    parts.append("*\(severity.uppercased())*")
                }
                if let options = interaction["options"] as? [[String: Any]] {
                    let multi = interaction["multiSelect"] as? Bool ?? false
                    let prefix = multi ? "Select multiple:" : "Choose one:"
                    parts.append(prefix)
                    for opt in options {
                        let label = opt["label"] as? String ?? "?"
                        let desc = opt["description"] as? String
                        if let desc { parts.append("- \(label) — \(desc)") }
                        else { parts.append("- \(label)") }
                    }
                }
            }
            if !parts.isEmpty { return parts.joined(separator: "\n") }
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
    let toolName: String?
    let toolCallJSON: String?
    let rawInputJSON: String?
    let rawOutputJSON: String?
    let mode: String?
    let timestamp = Date()

    init(role: ChatRole, content: String, toolName: String? = nil, toolCallJSON: String? = nil, rawInputJSON: String? = nil, rawOutputJSON: String? = nil, mode: String? = nil) {
        self.role = role
        self.content = content
        self.toolName = toolName
        self.toolCallJSON = toolCallJSON
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
    @State private var showRawJSON = false
    private var hasDebugInfo: Bool {
        message.rawInputJSON != nil || message.rawOutputJSON != nil
    }
    /// Whether this bubble has structured data to render as a form.
    private var hasStructuredContent: Bool {
        message.role == .toolResult || (message.role == .assistant && message.toolCallJSON != nil)
    }

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user { Spacer(minLength: 60) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                Text(roleLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                HStack(alignment: .top, spacing: 6) {
                    VStack(alignment: .leading, spacing: 0) {
                        if hasStructuredContent {
                            structuredContent
                        } else {
                            Text(LocalizedStringKey(message.content))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                        }

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

                    if message.role != .user {
                        CopyButton(text: message.content)
                            .padding(.top, 8)
                    }
                }
            }

            if message.role != .user { Spacer(minLength: 40) }
        }
    }

    // MARK: - Structured Content (tool call + tool result)

    private var structuredContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row: tool name (for tool calls) + JSON toggle
            HStack(spacing: 6) {
                if let name = message.toolName {
                    Text(name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showRawJSON.toggle()
                    }
                } label: {
                    Image(systemName: showRawJSON ? "list.bullet.rectangle" : "curlybraces")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)

            let jsonContent = message.toolCallJSON ?? message.content

            if showRawJSON {
                Divider().padding(.horizontal, 10)
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(jsonContent)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
            } else {
                FieldValueView(json: jsonContent)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
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
            HStack {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                CopyButton(text: json)
            }
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

// MARK: - Field-Value Renderer

/// Renders a JSON string as a clean field-value form with aligned columns,
/// dividers between rows, and indented nested sections.
private struct FieldValueView: View {
    let json: String

    var body: some View {
        if let parsed = Self.parse(json) {
            VStack(alignment: .leading, spacing: 0) {
                Self.renderValue(parsed, depth: 0, isRoot: true)
            }
        } else {
            Text(json)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private static func parse(_ json: String) -> Any? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    // MARK: - Recursive renderers (AnyView to break opaque type recursion)

    private static func renderValue(_ value: Any, depth: Int, isRoot: Bool = false) -> AnyView {
        if let dict = value as? [String: Any] {
            return renderDict(dict, depth: depth, isRoot: isRoot)
        } else if let arr = value as? [Any] {
            return renderArray(arr, depth: depth)
        } else {
            return AnyView(
                Text(scalarString(value))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
            )
        }
    }

    private static func renderDict(_ dict: [String: Any], depth: Int, isRoot: Bool = false) -> AnyView {
        let keys = dict.keys.sorted().filter { !isIDField($0) }
        return AnyView(
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(keys.enumerated()), id: \.element) { idx, key in
                    let val = dict[key]!

                    if isScalar(val) {
                        fieldRow(key: key, depth: depth) {
                            AnyView(
                                Text(scalarString(val))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.primary)
                            )
                        }
                    } else if val is [String: Any] {
                        VStack(alignment: .leading, spacing: 0) {
                            sectionHeader(key: key, depth: depth)
                            renderValue(val, depth: depth + 1)
                        }
                    } else if let arr = val as? [Any] {
                        if arr.allSatisfy({ isScalar($0) }) {
                            fieldRow(key: key, depth: depth) {
                                AnyView(
                                    Text(arr.map { scalarString($0) }.joined(separator: ", "))
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.primary)
                                )
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 0) {
                                sectionHeader(key: "\(key) (\(arr.count))", depth: depth)
                                renderValue(val, depth: depth + 1)
                            }
                        }
                    }

                    // Divider between rows at root level
                    if isRoot && idx < keys.count - 1 {
                        Divider()
                            .padding(.leading, CGFloat(depth) * 14)
                            .padding(.vertical, 1)
                    }
                }
            }
        )
    }

    private static func renderArray(_ arr: [Any], depth: Int) -> AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(arr.enumerated()), id: \.offset) { idx, item in
                    if item is [String: Any] {
                        VStack(alignment: .leading, spacing: 0) {
                            if arr.count > 1 {
                                sectionHeader(key: "[\(idx)]", depth: depth)
                            }
                            renderValue(item, depth: arr.count > 1 ? depth + 1 : depth)
                        }
                    } else {
                        fieldRow(key: "[\(idx)]", depth: depth) {
                            AnyView(
                                Text(scalarString(item))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.primary)
                            )
                        }
                    }

                    if idx < arr.count - 1 {
                        Divider()
                            .padding(.leading, CGFloat(depth) * 14)
                            .padding(.vertical, 1)
                    }
                }
            }
        )
    }

    // MARK: - Row components

    private static func fieldRow<V: View>(key: String, depth: Int, @ViewBuilder value: () -> V) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(displayName(key))
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 60, alignment: .trailing)
                .padding(.trailing, 8)

            value()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(depth) * 14)
        .padding(.vertical, 4)
    }

    private static func sectionHeader(key: String, depth: Int) -> some View {
        Text(displayName(key))
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.leading, CGFloat(depth) * 14)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }

    // MARK: - Helpers

    /// Convert a camelCase or snake_case key into a capitalised display name.
    /// e.g. "endDate" → "End Date", "isAllDay" → "Is All Day", "start_date" → "Start Date"
    private static func displayName(_ key: String) -> String {
        // Handle snake_case first
        let base = key.replacingOccurrences(of: "_", with: " ")
        // Split on camelCase boundaries
        var result = ""
        for char in base {
            if char.isUppercase && !result.isEmpty && result.last != " " {
                result += " "
            }
            result.append(char)
        }
        // Capitalise each word
        return result.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined(separator: " ")
    }

    /// Hide internal identifier fields from the form view.
    private static func isIDField(_ key: String) -> Bool {
        let lower = key.lowercased()
        return lower == "id" || lower.hasSuffix("id") || lower.hasSuffix("identifier")
    }

    private static func isScalar(_ value: Any) -> Bool {
        value is String || value is Bool || value is NSNumber
    }

    private static func scalarString(_ value: Any) -> String {
        if let b = value as? Bool { return b ? "true" : "false" }
        if let s = value as? String { return formatIfDate(s) ?? s }
        if let n = value as? NSNumber { return n.stringValue }
        return "\(value)"
    }

    /// Try to parse an ISO 8601 date string and return a human-friendly format.
    private static func formatIfDate(_ string: String) -> String? {
        guard string.count >= 10, string.count <= 30 else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: string) ?? {
            iso.formatOptions = [.withInternetDateTime]
            return iso.date(from: string)
        }() {
            let fmt = DateFormatter()
            let cal = Calendar.current
            if cal.component(.hour, from: date) == 0 && cal.component(.minute, from: date) == 0 {
                fmt.dateFormat = "EEE, MMM d, yyyy"
            } else {
                fmt.dateFormat = "EEE, MMM d, yyyy 'at' h:mm a"
            }
            return fmt.string(from: date)
        }
        return nil
    }
}

// MARK: - Copy Button

private struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    NavigationStack {
        LocalModelTestView()
    }
}
