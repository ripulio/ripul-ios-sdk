import Foundation
import Combine

/// Structured task-notification card — mirrors the web's TaskNotificationCard.
public struct NativeTaskNotification: Equatable {
    public let taskId: String?
    public let status: String?
    public let summary: String?

    public init(taskId: String?, status: String?, summary: String?) {
        self.taskId = taskId
        self.status = status
        self.summary = summary
    }
}

public struct NativeReplyQuote: Equatable {
    public let correlationId: String
    public let senderDisplayName: String?
    public let excerpt: String

    public init(correlationId: String, senderDisplayName: String? = nil, excerpt: String) {
        self.correlationId = correlationId
        self.senderDisplayName = senderDisplayName
        self.excerpt = excerpt
    }
}

public struct NativeContextTag: Equatable, Identifiable {
    public var id: String { "\(tagName):\(label):\(content.prefix(32))" }
    public let tagName: String
    public let label: String
    public let content: String

    public init(tagName: String, label: String, content: String) {
        self.tagName = tagName
        self.label = label
        self.content = content
    }
}

/// Context picked in the composer and sent with a user message (an element, the
/// screen, saved instructions). Labelled web-side, so both chats name it alike.
public struct NativeContextAttachment: Equatable, Identifiable {
    public enum Icon: String {
        case instructions, element, screen, app

        /// The composer's own symbols for each kind (`ComposerContextViews`).
        var systemImage: String {
            switch self {
            case .instructions: return "text.badge.checkmark"
            case .element: return "scope"
            case .screen: return "rectangle.inset.filled"
            case .app: return "doc.text"
            }
        }
    }

    public let id: String
    public let title: String
    /// "Screen element · WAC Beta · Reference"
    public let source: String
    public let icon: Icon
    /// "Included with this message"
    public let scope: String
    public let capturedAt: String
    public let content: String

    public init(id: String, title: String, source: String, icon: Icon, scope: String, capturedAt: String, content: String) {
        self.id = id
        self.title = title
        self.source = source
        self.icon = icon
        self.scope = scope
        self.capturedAt = capturedAt
        self.content = content
    }

    /// When it was captured, in the reader's locale; the raw value when it is not a date.
    var capturedLabel: String {
        let date = (try? Date(capturedAt, strategy: .iso8601))
            ?? (try? Date(capturedAt, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        return date?.formatted(.dateTime.month(.abbreviated).day().hour().minute()) ?? capturedAt
    }
}

public struct NativeChatImageAttachment: Equatable, Identifiable {
    public let id: String
    public let mediaType: String
    public let data: String?
    public let url: String?
    public let name: String?
    public let width: Int?
    public let height: Int?

    public init(
        id: String,
        mediaType: String,
        data: String? = nil,
        url: String? = nil,
        name: String? = nil,
        width: Int? = nil,
        height: Int? = nil
    ) {
        self.id = id
        self.mediaType = mediaType
        self.data = data
        self.url = url
        self.name = name
        self.width = width
        self.height = height
    }
}

public struct NativeChatFileAttachment: Equatable, Identifiable {
    public let id: String
    public let name: String
    public let mediaType: String?
    public let sizeBytes: Int?

    public init(id: String, name: String, mediaType: String? = nil, sizeBytes: Int? = nil) {
        self.id = id
        self.name = name
        self.mediaType = mediaType
        self.sizeBytes = sizeBytes
    }
}

public struct NativeChatVideoAttachment: Equatable, Identifiable {
    public let id: String
    public let url: String
    public let posterUrl: String?
    public let name: String?
    public let width: Int?
    public let height: Int?

    public init(id: String, url: String, posterUrl: String? = nil, name: String? = nil, width: Int? = nil, height: Int? = nil) {
        self.id = id; self.url = url; self.posterUrl = posterUrl; self.name = name
        self.width = width; self.height = height
    }
}

public struct NativeMessageTab: Equatable, Identifiable {
    public var id: String { label }
    public let label: String
    public let content: String
    public let markdown: Bool

    public init(label: String, content: String, markdown: Bool = true) {
        self.label = label
        self.content = content
        self.markdown = markdown
    }
}

public struct NativeMessageTable: Equatable {
    public struct Column: Equatable, Identifiable {
        public var id: String { key }
        public let key: String
        public let label: String

        public init(key: String, label: String) {
            self.key = key
            self.label = label
        }
    }
    public let columns: [Column]
    public let rows: [[String: String]]

    public init(columns: [Column], rows: [[String: String]]) {
        self.columns = columns
        self.rows = rows
    }

    /// The same first-column label matching used by the web TableRows card.
    func matchingOption(for row: [String: String], options: [NativeAskUser.Option]) -> NativeAskUser.Option? {
        guard let key = columns.first?.key else { return nil }
        let value = (row[key] ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return options.first {
            let label = $0.label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            return label == value || label.hasPrefix(value) || value.hasPrefix(label)
        }
    }
}

public struct NativeDateInput: Equatable {
    public let includeTime: Bool
    public let minDate: String?
    public let maxDate: String?
    public let defaultDate: String?

    public init(includeTime: Bool = false, minDate: String? = nil, maxDate: String? = nil, defaultDate: String? = nil) {
        self.includeTime = includeTime
        self.minDate = minDate
        self.maxDate = maxDate
        self.defaultDate = defaultDate
    }
}

/// A faithfully-mirrored askUser prompt: question + selectable options, date picker, or free-text input.
/// Mirrors the web UnifiedAgentQuestionPanel / AskUserChoiceRenderer.
public struct NativeAskUser: Equatable {
    public struct Option: Equatable, Identifiable {
        public var id: String { value.isEmpty ? label : value }
        public let label: String
        public let value: String
        public let description: String?
        public let link: String?
        public let image: String?

        public init(
            label: String,
            value: String,
            description: String? = nil,
            link: String? = nil,
            image: String? = nil
        ) {
            self.label = label
            self.value = value
            self.description = description
            self.link = link
            self.image = image
        }
    }
    public let question: String
    public let options: [Option]
    public let multiSelect: Bool
    public let severity: String?
    public var expectsResponse: Bool
    public var enableChatInput: Bool
    public var passwordInput: Bool
    public var completed: Bool
    public var submitting: Bool
    public var submissionError: String?
    public var answer: String?
    public var selectedValues: [String]
    public var responseKey: String?
    public var threadId: String?
    public var actionId: String?
    public var dateInput: NativeDateInput?
    public var tabs: [NativeMessageTab]?
    public var table: NativeMessageTable?

    public init(
        question: String,
        options: [Option],
        multiSelect: Bool,
        severity: String?,
        expectsResponse: Bool = true,
        enableChatInput: Bool = false,
        passwordInput: Bool = false,
        completed: Bool = false,
        submitting: Bool = false,
        submissionError: String? = nil,
        answer: String? = nil,
        selectedValues: [String] = [],
        responseKey: String? = nil,
        threadId: String? = nil,
        actionId: String? = nil,
        dateInput: NativeDateInput? = nil,
        tabs: [NativeMessageTab]? = nil,
        table: NativeMessageTable? = nil
    ) {
        self.question = question
        self.options = options
        self.multiSelect = multiSelect
        self.severity = severity
        self.expectsResponse = expectsResponse
        self.enableChatInput = enableChatInput
        self.passwordInput = passwordInput
        self.completed = completed
        self.submitting = submitting
        self.submissionError = submissionError
        self.answer = answer
        self.selectedValues = selectedValues
        self.responseKey = responseKey
        self.threadId = threadId
        self.actionId = actionId
        self.dateInput = dateInput
        self.tabs = tabs
        self.table = table
    }

    /// Answer text that is not already shown by the choices or date picker.
    public var freeTextAnswer: String? {
        guard completed, dateInput == nil, let answer, !answer.isEmpty else { return nil }
        func matchesOption(_ value: String) -> Bool {
            options.contains { $0.value == value || $0.label == value }
        }
        if matchesOption(answer) { return nil }
        // selectedValues mirrors the transport answer, including arbitrary
        // text. Only suppress text when the choices show the entire answer.
        let shownByChoices = !selectedValues.isEmpty
            && selectedValues.allSatisfy(matchesOption)
            && selectedValues.joined(separator: ", ") == answer
        return shownByChoices ? nil : answer
    }
}

public struct NativeRespondentInfo: Equatable {
    public let label: String
    public let modelId: String?
    public let provider: String?
    public let family: String?
    public let color: String?
    public let icon: String?
    public let contextTokens: Int?
    public let contextWindow: Int?
    public let contextPercent: Int?
    public let durationMs: Double?
    public let costUsd: Double?
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let cacheReadTokens: Int?
    public let cacheWriteTokens: Int?
    public let toolCallCount: Int?
    public let apiMessageId: String?
    public let isRewindable: Bool
    public let metaJson: String?

    public init(
        label: String,
        modelId: String? = nil,
        provider: String? = nil,
        family: String? = nil,
        color: String? = nil,
        icon: String? = nil,
        contextTokens: Int? = nil,
        contextWindow: Int? = nil,
        contextPercent: Int? = nil,
        durationMs: Double? = nil,
        costUsd: Double? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cacheReadTokens: Int? = nil,
        cacheWriteTokens: Int? = nil,
        toolCallCount: Int? = nil,
        apiMessageId: String? = nil,
        isRewindable: Bool = false,
        metaJson: String? = nil
    ) {
        self.label = label
        self.modelId = modelId
        self.provider = provider
        self.family = family
        self.color = color
        self.icon = icon
        self.contextTokens = contextTokens
        self.contextWindow = contextWindow
        self.contextPercent = contextPercent
        self.durationMs = durationMs
        self.costUsd = costUsd
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.toolCallCount = toolCallCount
        self.apiMessageId = apiMessageId
        self.isRewindable = isRewindable
        self.metaJson = metaJson
    }
}

public struct NativeArtefactAcceptedSelection: Equatable {
    public let label: String
    public let summary: String
    public let runId: String

    public init(label: String, summary: String, runId: String) {
        self.label = label
        self.summary = summary
        self.runId = runId
    }
}

public struct NativeArtefactReference: Equatable {
    public let kind: String
    public let artefactId: String
    public let revision: Int
    public let surface: String
    public let presentationId: String
    public let runId: String?
    public let status: String
    public let errorMessage: String?
    public let acceptedSelection: NativeArtefactAcceptedSelection?

    public init(
        kind: String = "artefact_reference/v1",
        artefactId: String,
        revision: Int,
        surface: String,
        presentationId: String,
        runId: String? = nil,
        status: String = "ready",
        errorMessage: String? = nil,
        acceptedSelection: NativeArtefactAcceptedSelection? = nil
    ) {
        self.kind = kind
        self.artefactId = artefactId
        self.revision = revision
        self.surface = surface
        self.presentationId = presentationId
        self.runId = runId
        self.status = status
        self.errorMessage = errorMessage
        self.acceptedSelection = acceptedSelection
    }
}

public struct NativeSystemStatusInfo: Equatable {
    public let severity: String
    public let title: String?
    public let message: String
    public let isSharedEvent: Bool

    public init(severity: String, title: String? = nil, message: String, isSharedEvent: Bool = false) {
        self.severity = severity
        self.title = title
        self.message = message
        self.isSharedEvent = isSharedEvent
    }
}

public struct NativeErrorInfo: Equatable {
    public let title: String
    public let message: String
    public let details: String?

    public init(title: String, message: String, details: String? = nil) {
        self.title = title
        self.message = message
        self.details = details
    }
}

public struct NativeCliEventInfo: Equatable {
    public let kind: String
    public let label: String
    public let codeLabel: Bool
    public let detail: String?
    public let content: String?
    public let chips: [String]
    public let accent: String
    public let rawJson: String?

    public init(
        kind: String,
        label: String,
        codeLabel: Bool = false,
        detail: String? = nil,
        content: String? = nil,
        chips: [String] = [],
        accent: String = "default",
        rawJson: String? = nil
    ) {
        self.kind = kind
        self.label = label
        self.codeLabel = codeLabel
        self.detail = detail
        self.content = content
        self.chips = chips
        self.accent = accent
        self.rawJson = rawJson
    }
}

struct NativeToolCallSummary: Equatable {
    let id: String
    let toolName: String
    let label: String
    let rendererName: String
    let symbol: String?
    let status: String
    let summary: String?
    let defaultAction: ToolDefaultAction?
    let taskRunKind: NativeTaskRunSnapshot.Kind?
    let taskRun: NativeTaskRunSnapshot?
    let agentComms: AgentCommsPresentation?
    let detail: ToolCallDetail?
}

public struct NativeChatMessage: Identifiable, Equatable {
    public enum Role: String {
        case user
        case assistant
    }

    /// Stable across the initial `add` and every subsequent `update`
    /// (the web action's correlationId).
    public let id: String
    public var chatId: String?
    public var role: Role
    public var content: String
    public var status: String?
    public var method: String?
    /// Short human-readable placeholder for rows without real content yet
    /// (tool calls, assistant turns pre-MessagePipeline). e.g. "Read", "Bash".
    public var label: String?
    /// One-line summary extracted web-side, if any.
    public var summary: String?
    /// Structured askUser prompt, if this row is a question.
    public var askUser: NativeAskUser?
    /// Structured task-notification card, if this row is a system task completion.
    public var taskNotification: NativeTaskNotification?
    /// Sender attribution label — user's display name or agent label (e.g. "Claude").
    public var senderLabel: String?
    /// Accumulated streaming "thinking" content, if any has arrived.
    public var thinking: String?
    public var isThinkingStreaming: Bool
    public var timestamp: Double

    // Rich fields for NativeChatView:
    public var hiddenInChat: Bool = false
    public var mergedIntoQuestionId: String? = nil
    public var replyQuote: NativeReplyQuote? = nil
    public var contextTags: [NativeContextTag] = []
    public var contextAttachments: [NativeContextAttachment] = []
    public var imageAttachments: [NativeChatImageAttachment] = []
    public var videoAttachments: [NativeChatVideoAttachment] = []
    public var fileAttachments: [NativeChatFileAttachment] = []
    public var isVoice: Bool = false
    public var isGroupChat: Bool = false
    public var isOwnMessage: Bool = true
    public var avatarUrl: String? = nil
    public var senderUserId: String? = nil
    /// Incoming agent messages keep their source chat identity for icons and actions.
    public var senderAgent: NativeChatAgentSender? = nil
    public var deliveryStatus: String? = nil
    public var respondent: NativeRespondentInfo? = nil
    public var tabs: [NativeMessageTab] = []
    public var table: NativeMessageTable? = nil
    public var isNote: Bool = false
    public var artefactRef: NativeArtefactReference? = nil
    public var systemStatus: NativeSystemStatusInfo? = nil
    public var errorInfo: NativeErrorInfo? = nil
    public var cliEvent: NativeCliEventInfo? = nil
    var toolCall: NativeToolCallSummary? = nil
    var speech: NativeChatSpeech? = nil

    public init(
        id: String,
        chatId: String? = nil,
        role: Role,
        content: String,
        status: String? = nil,
        method: String? = nil,
        label: String? = nil,
        summary: String? = nil,
        askUser: NativeAskUser? = nil,
        taskNotification: NativeTaskNotification? = nil,
        senderLabel: String? = nil,
        thinking: String? = nil,
        isThinkingStreaming: Bool = false,
        timestamp: Double
    ) {
        self.id = id
        self.chatId = chatId
        self.role = role
        self.content = content
        self.status = status
        self.method = method
        self.label = label
        self.summary = summary
        self.askUser = askUser
        self.taskNotification = taskNotification
        self.senderLabel = senderLabel
        self.thinking = thinking
        self.isThinkingStreaming = isThinkingStreaming
        self.timestamp = timestamp
    }

    private static let nonToolMethods: Set<String> = [
        "llmRequest", "user-message", "user-note", "user-answer",
        "askUser", "askUserChoice", "askUserMultiChoice", "respondToUser", "interactWithUser",
        "system-status", "completion",
        "cli.rawEvent", "cli.compactionStatus", "cli.rateLimitStatus",
        "cli.hookEvent", "cli.vcsState", "cli.modelRefusalFallback",
        "cli.toolInventory", "cli.shellOutput", "cli.claudeSignIn", "cli.claudeLimit",
        "cli.turnStart", "cli.turnComplete", "cli.turnInterrupted",
    ]

    /// Whether this message represents a tool invocation / sub-agent / workflow row that groups into a tool strip.
    var isToolRow: Bool {
        if artefactRef != nil || speech != nil { return false }
        if toolCall != nil { return true }
        guard role == .assistant,
              content.isEmpty,
              askUser == nil,
              taskNotification == nil,
              systemStatus == nil,
              errorInfo == nil,
              cliEvent == nil,
              !isNote else { return false }
        if let method, !Self.nonToolMethods.contains(method) {
            return true
        }
        return false
    }
}

// MARK: - Grouped Display Rows for NativeChatView

public struct NativeChatGap: Equatable, Identifiable {
    public let id: String
    public let text: String
    public let timestamp: Double

    public init(id: String, text: String, timestamp: Double) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
    }
}

struct NativeChatTaskRunItem: Equatable, Identifiable {
    let id: String
    let kind: NativeTaskRunSnapshot.Kind
    let snapshot: NativeTaskRunSnapshot
}

struct NativeChatAgentCommsItem: Equatable, Identifiable {
    let id: String
    let timestamp: Double
    let presentation: AgentCommsPresentation
    let detail: ToolCallDetail?
}

public struct NativeChatToolGroup: Equatable, Identifiable {
    public let id: String
    public let chatId: String
    public let updatedAt: Double
    let tools: [NativeToolStripItem]
    let callIdsByToolId: [String: [String]]
    let taskRuns: [NativeChatTaskRunItem]
    let agentComms: [NativeChatAgentCommsItem]
    let calls: [ToolCallDetail]
    public let allCallIds: [String]

    public var totalToolCount: Int {
        tools.reduce(0) { $0 + $1.count } + taskRuns.count + agentComms.count
    }
}

public enum NativeChatRow: Equatable, Identifiable {
    case gap(NativeChatGap)
    case toolGroup(NativeChatToolGroup)
    case thinking(NativeChatMessage)
    case user(NativeChatMessage)
    case note(NativeChatMessage)
    case assistant(NativeChatMessage)
    case taskNotification(NativeChatMessage)
    case systemStatus(NativeChatMessage)
    case error(NativeChatMessage)
    case cliEvent(NativeChatMessage)

    public var id: String {
        switch self {
        case .gap(let gap): return "gap:\(gap.id)"
        case .toolGroup(let group): return "toolGroup:\(group.id)"
        case .thinking(let msg):
            if msg.isToolRow || msg.isNote || msg.method == "user-note" || msg.artefactRef != nil {
                return "thinking:\(msg.id)"
            }
            return msg.id
        case .user(let msg): return msg.id
        case .note(let msg): return msg.id
        case .assistant(let msg): return msg.id
        case .taskNotification(let msg): return msg.id
        case .systemStatus(let msg): return msg.id
        case .error(let msg): return msg.id
        case .cliEvent(let msg): return msg.id
        }
    }
}

public struct NativeChatScrollPosition: Equatable {
    public let chatId: String
    public let webRowId: String?
    public let offset: CGFloat
    public let following: Bool

    public init(chatId: String, webRowId: String?, offset: CGFloat, following: Bool) {
        self.chatId = chatId
        self.webRowId = webRowId
        self.offset = offset
        self.following = following
    }
}

public enum NativeChatScrollCommand: Equatable {
    /// The chat was opened: show its end, and keep it there while it settles.
    case enter
    case bottom(animated: Bool)
    case userMessage(direction: String)
    case message(id: String, highlight: Bool)
    case restore(NativeChatScrollPosition)
}

/// History readiness is independent of whether any visible messages have arrived.
public struct NativeChatLoadingState: Equatable {
    public enum Phase: String { case loading, ready, failed }
    public let phase: Phase
    public let label: String
    public let detail: String?
    public let fraction: Double?

    public static let loading = NativeChatLoadingState(phase: .loading, label: "Loading chat…", detail: nil, fraction: nil)
    public static let ready = NativeChatLoadingState(phase: .ready, label: "", detail: nil, fraction: nil)

    public init?(wire: [String: Any]) {
        guard let rawPhase = wire["phase"] as? String, let phase = Phase(rawValue: rawPhase) else { return nil }
        self.phase = phase
        label = wire["label"] as? String ?? (phase == .failed ? "Couldn’t load this chat’s messages" : "Loading chat…")
        detail = wire["detail"] as? String
        if let number = (wire["fraction"] as? NSNumber)?.doubleValue, number.isFinite {
            fraction = min(1, max(0, number))
        } else { fraction = nil }
    }

    private init(phase: Phase, label: String, detail: String?, fraction: Double?) {
        self.phase = phase
        self.label = label
        self.detail = detail
        self.fraction = fraction
    }
}

/// Leaf `ObservableObject` backing the native chat scroller.
///
/// Kept OFF `AgentBridge` on purpose: messages/streaming deltas write many times
/// per turn, and `@Published` fields on the 60+-field `AgentBridge` re-render the
/// WKWebView host on every write. Isolating them here means only the native
/// scroller observing `bridge.nativeChat` reacts — the host stays untouched.
///
/// IMPORTANT: `messages` is the single `@Published` property mutated on updates
/// so `objectWillChange` fires at most once per batch/update (verified by
/// `ThermalWorkTests.testHistoryBatchPublishesOnceAndIdenticalUpdatesDoNotPublish`).
/// `rows` is updated synchronously right before `messages` is assigned.
@MainActor
public final class NativeChatMessageStore: ObservableObject {
    @Published public private(set) var messages: [NativeChatMessage] = []
    public private(set) var rows: [NativeChatRow] = []
    /// Row IDs mutated by the most recent incremental update (`nil` when all rows were rebuilt).
    public private(set) var lastChangedRowIds: Set<String>? = nil
    public private(set) var truncatedCount: Int = 0
    public private(set) var currentChatId: String? = nil
    public private(set) var loadingState: NativeChatLoadingState = .loading

    /// Progress changes publish without rebuilding messages or their layout.
    public func applyLoadingState(_ state: NativeChatLoadingState, chatId: String) {
        guard chatId == currentChatId, state != loadingState else { return }
        loadingState = state
        objectWillChange.send()
    }

    /// The web chat's place, kept when Native Chat is turned on from it. A chat
    /// that is entered has none: it opens at its end.
    public var pendingScrollRestoration: NativeChatScrollPosition? = nil
    /// Latest scroll snapshot recorded by `NativeChatView` for syncing back to Web Chat.
    public var lastScrollSnapshot: NativeChatScrollPosition? = nil
    /// Live callback registered by `NativeChatView` to sample the exact scroll offset on toggle-off.
    public var captureLiveScrollSnapshot: (() -> NativeChatScrollPosition?)? = nil
    private var awaitingWebToggleRestore: Bool = false

    public func markAwaitingWebToggleRestore() {
        awaitingWebToggleRestore = true
    }

    /// The app opened a chat: it shows its end (`NativeChatScrollCommand.enter`),
    /// and a place kept from the web chat no longer applies. The app turns
    /// Native Chat on from its saved setting at launch, which marks a web-chat
    /// switch; without this the first chat opened after a launch restored the
    /// page's saved place for it instead of opening at its end.
    public func enterChat() {
        awaitingWebToggleRestore = false
        pendingScrollRestoration = nil
        scrollCommands.send(.enter)
    }

    /// What this store takes from the page's forwarder, passed whenever forwarding
    /// is turned on. A page only sends a `patch` to an app that says so here: an
    /// older app logs one as malformed and drops it.
    /// Lean forwarding: while Native Chat draws, the page stops its own chat
    /// pipeline and sends coalesced changes at most every 33 ms. On by default
    /// (27 October 2026, the native chat CPU work); Settings > Debug > Native
    /// Chat Performance, or `-perfOff leanForwarding` in a debug build, asks
    /// for the old forwarding to compare.
    nonisolated public static var forwardingFeaturesJSON: String {
        PerfSwitch.isOff("leanForwarding") || !NativeChatPerformance.isEnabled(.leanForwarding)
            ? "{ patch: true, loading: true }"
            : "{ patch: true, loading: true, lean: true, flushMs: 33 }"
    }

    /// Imperative scroll commands from `AgentBridge` or in-chat interactions.
    public let scrollCommands = PassthroughSubject<NativeChatScrollCommand, Never>()

    /// id → index into `messages`, so add/update are O(1) instead of O(n).
    private var indexById: [String: Int] = [:]

    /// Native row id (`NativeChatRow.id`) → index into `rows` for O(1) in-place row updates.
    private var rowIndexById: [String: Int] = [:]

    /// Raw IDs of current `.toolGroup` rows (`group.id`), used to map `.thinking` rows to `header_` vs `thinking_`.
    private var toolGroupRawIds: Set<String> = []

    /// Native row id (`NativeChatRow.id`) → web row id (`header_…`, `thinking_…`, `gap_…`, or message id),
    /// kept in sync whenever `rows` changes so `resolveWebRowId(forNativeRowId:)` is O(1).
    private var webRowIdByNativeRowId: [String: String] = [:]

    /// Accumulated dirty row IDs since the window coordinator last consumed them.
    private var accumulatedDirtyRowIds: Set<String> = []
    private var dirtyRowsRequireFullScan: Bool = true

    public init() {}

    /// Consumes the union of row IDs that changed since the last call, or returns `nil`
    /// if a full rebuild/backfill occurred and all rows must be re-evaluated.
    public func consumeDirtyRowIds() -> Set<String>? {
        guard NativeChatPerformance.isEnabled(.incrementalRows) else {
            dirtyRowsRequireFullScan = true
            accumulatedDirtyRowIds.removeAll(keepingCapacity: true)
            return nil
        }
        if dirtyRowsRequireFullScan {
            dirtyRowsRequireFullScan = false
            accumulatedDirtyRowIds.removeAll(keepingCapacity: true)
            return nil
        }
        let dirty = accumulatedDirtyRowIds
        accumulatedDirtyRowIds.removeAll(keepingCapacity: true)
        return dirty
    }

    /// Marks dirty-row tracking as requiring a full scan on the next consumption
    /// (for example when a view holds intermediate row publications during a scroll coast).
    public func invalidateDirtyRowTracking() {
        dirtyRowsRequireFullScan = true
        accumulatedDirtyRowIds.removeAll(keepingCapacity: true)
    }

    private func replaceAllRows(_ newRows: [NativeChatRow], dirtyRowIds: Set<String>? = nil) {
        rows = newRows
        var nextRowIndex: [String: Int] = [:]
        nextRowIndex.reserveCapacity(newRows.count)
        var nextToolGroupRawIds = Set<String>()
        for (idx, row) in newRows.enumerated() {
            nextRowIndex[row.id] = idx
            if case .toolGroup(let group) = row {
                nextToolGroupRawIds.insert(group.id)
            }
        }
        rowIndexById = nextRowIndex
        toolGroupRawIds = nextToolGroupRawIds
        webRowIdByNativeRowId = Self.buildWebRowIdMap(for: newRows, toolGroupRawIds: nextToolGroupRawIds)
        if let dirtyRowIds {
            lastChangedRowIds = dirtyRowIds
            if !dirtyRowsRequireFullScan {
                accumulatedDirtyRowIds.formUnion(dirtyRowIds)
            }
        } else {
            lastChangedRowIds = nil
            dirtyRowsRequireFullScan = true
            accumulatedDirtyRowIds.removeAll(keepingCapacity: true)
        }
    }

    private func updateWebRowIdEntry(for row: NativeChatRow) {
        switch row {
        case .toolGroup(let group):
            webRowIdByNativeRowId[row.id] = "header_\(group.id)"
        case .thinking(let msg):
            let webId = toolGroupRawIds.contains(msg.id) ? "header_\(msg.id)" : "thinking_\(msg.id)"
            webRowIdByNativeRowId[row.id] = webId
            webRowIdByNativeRowId[msg.id] = webId
        case .gap(let gap):
            webRowIdByNativeRowId[row.id] = "gap_\(gap.id)"
        case .user, .note, .assistant, .taskNotification, .systemStatus, .error, .cliEvent:
            webRowIdByNativeRowId[row.id] = row.id
        }
    }

    private static func buildWebRowIdMap(
        for rows: [NativeChatRow],
        toolGroupRawIds: Set<String>? = nil
    ) -> [String: String] {
        let resolvedToolGroupIds: Set<String>
        if let toolGroupRawIds {
            resolvedToolGroupIds = toolGroupRawIds
        } else {
            var set = Set<String>()
            for row in rows {
                if case .toolGroup(let group) = row {
                    set.insert(group.id)
                }
            }
            resolvedToolGroupIds = set
        }
        var map: [String: String] = [:]
        map.reserveCapacity(rows.count * 2)
        for row in rows {
            switch row {
            case .toolGroup(let group):
                map[row.id] = "header_\(group.id)"
            case .thinking(let msg):
                let webId = resolvedToolGroupIds.contains(msg.id) ? "header_\(msg.id)" : "thinking_\(msg.id)"
                map[row.id] = webId
                map[msg.id] = webId
            case .gap(let gap):
                map[row.id] = "gap_\(gap.id)"
            case .user, .note, .assistant, .taskNotification, .systemStatus, .error, .cliEvent:
                map[row.id] = row.id
            }
        }
        return map
    }

    public func resolveNativeRowId(forWebRowId webRowId: String) -> String? {
        if rows.contains(where: { $0.id == webRowId }) {
            return webRowId
        }
        let rawId: String
        if webRowId.hasPrefix("header_") {
            rawId = String(webRowId.dropFirst("header_".count))
        } else if webRowId.hasPrefix("thinking_") {
            rawId = String(webRowId.dropFirst("thinking_".count))
        } else if webRowId.hasPrefix("gap_") {
            rawId = String(webRowId.dropFirst("gap_".count))
        } else {
            rawId = webRowId
        }
        if webRowId.hasPrefix("header_") || webRowId.hasPrefix("thinking_") {
            if rows.contains(where: { $0.id == "thinking:\(rawId)" }) {
                return "thinking:\(rawId)"
            }
            if rows.contains(where: { $0.id == "toolGroup:\(rawId)" }) {
                return "toolGroup:\(rawId)"
            }
        }
        if webRowId.hasPrefix("gap_") {
            if rows.contains(where: { $0.id == "gap:\(rawId)" }) {
                return "gap:\(rawId)"
            }
        }
        for row in rows {
            if case .toolGroup(let group) = row {
                if group.id == rawId || group.allCallIds.contains(where: { rawId == $0 || rawId.hasPrefix($0 + "_") }) {
                    return "toolGroup:\(group.id)"
                }
            }
        }
        if rows.contains(where: { $0.id == rawId }) {
            return rawId
        }
        return nil
    }

    public func containsNativeRowId(_ nativeRowId: String) -> Bool {
        webRowIdByNativeRowId[nativeRowId] != nil
    }

    public func resolveWebRowId(forNativeRowId nativeRowId: String) -> String {
        if let mapped = webRowIdByNativeRowId[nativeRowId] {
            return mapped
        }
        if nativeRowId.hasPrefix("toolGroup:") {
            return "header_" + nativeRowId.dropFirst("toolGroup:".count)
        }
        if nativeRowId.hasPrefix("thinking:") {
            let rawId = String(nativeRowId.dropFirst("thinking:".count))
            if webRowIdByNativeRowId["toolGroup:\(rawId)"] != nil {
                return "header_\(rawId)"
            }
            return "thinking_\(rawId)"
        }
        if nativeRowId.hasPrefix("gap:") {
            return "gap_" + nativeRowId.dropFirst("gap:".count)
        }
        return nativeRowId
    }

    /// Handle an `add` wire message (`message` dict from the bridge).
    public func applyAdd(_ msg: [String: Any]) {
        guard let incoming = Self.parseMessage(msg) else { return }
        upsert(incoming)
    }

    /// One publication for history, rather than one per historical action.
    public func applyBackfill(
        _ entries: [[String: Any]],
        truncatedCount newTruncatedCount: Int = 0,
        chatId: String? = nil,
        scrollPosition: [String: Any]? = nil,
        loadingState newLoadingState: NativeChatLoadingState = .ready
    ) {
        let incoming = entries.compactMap(Self.parseMessage)
        var dedupById: [String: Int] = [:]
        var unique: [NativeChatMessage] = []
        for message in incoming {
            if let index = dedupById[message.id] {
                unique[index] = message
            } else {
                dedupById[message.id] = unique.count
                unique.append(message)
            }
        }
        // Sort chronologically by timestamp, preserving insertion order on ties (mirrors MessagePipeline.ts:776-783)
        let sorted = unique.enumerated().sorted { lhs, rhs in
            if lhs.element.timestamp != rhs.element.timestamp {
                return lhs.element.timestamp < rhs.element.timestamp
            }
            return lhs.offset < rhs.offset
        }.map(\.element)

        let chatChanged = (chatId != nil && chatId != currentChatId)
        let wasEmpty = rows.isEmpty
        let isToggleRestore = awaitingWebToggleRestore
        awaitingWebToggleRestore = false
        let resolvedChatId = chatId ?? currentChatId ?? sorted.last?.chatId
        // A chat that is entered opens at its end (Peter, 27 Oct 2026), so the
        // place the page saved for it is not restored. Only turning Native Chat
        // on from the web chat keeps the reader's place.
        if chatChanged && !isToggleRestore {
            pendingScrollRestoration = nil
            if let cid = resolvedChatId, !cid.isEmpty {
                lastScrollSnapshot = NativeChatScrollPosition(chatId: cid, webRowId: nil, offset: 0, following: true)
            }
        }
        var parsedScroll: NativeChatScrollPosition? = nil
        if isToggleRestore, let scrollPosition, let cid = resolvedChatId, !cid.isEmpty {
            let following = (scrollPosition["following"] as? Bool) ?? true
            let rawRowId = scrollPosition["rowId"] as? String
            let rowId = (rawRowId?.isEmpty == false) ? rawRowId : nil
            let offset = (scrollPosition["offset"] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
            let pos = NativeChatScrollPosition(chatId: cid, webRowId: rowId, offset: offset, following: following)
            lastScrollSnapshot = pos
            pendingScrollRestoration = pos
            parsedScroll = pos
        } else if wasEmpty, let pending = pendingScrollRestoration, pending.chatId == resolvedChatId {
            // A switch whose first rows arrived empty (the chat was still loading).
            parsedScroll = pending
        }

        let loadingChanged = newLoadingState != loadingState
        guard sorted != messages || newTruncatedCount != truncatedCount || chatChanged || loadingChanged else {
            if isToggleRestore, let parsedScroll, !rows.isEmpty {
                scrollCommands.send(.restore(parsedScroll))
            }
            return
        }
        indexById = [:]
        for (idx, msg) in sorted.enumerated() {
            indexById[msg.id] = idx
        }
        truncatedCount = newTruncatedCount
        loadingState = newLoadingState
        if let chatId { currentChatId = chatId }
        replaceAllRows(Self.buildRows(from: sorted, previousRows: chatChanged ? [] : rows), dirtyRowIds: nil)
        if #available(iOS 16.0, macOS 14.0, *) {
            NativeChatImagePreloader.shared.preload(messages: sorted)
        }
        if sorted == messages {
            objectWillChange.send()
        } else {
            messages = sorted
        }
        if let parsedScroll, !rows.isEmpty {
            scrollCommands.send(.restore(parsedScroll))
        }
    }

    private static func isTerminalStatus(_ status: String?) -> Bool {
        guard let lower = status?.lowercased() else { return false }
        switch lower {
        case "complete", "completed", "success", "error", "failed", "cancelled", "canceled", "stopped", "done", "killed", "ended", "orphaned":
            return true
        default:
            return false
        }
    }

    /// What one store change did to the chat (chat sync plan, step 3): the rows
    /// it changed or added, the rows to drop, and the count above the window.
    /// Applied in one pass with one rebuild and one publication, where a batch
    /// used to come as the whole chat. Rows merge as `applyAdd` merges one:
    /// streaming thinking and content are never cleared by a copy without them.
    /// Into an empty store, or with no chat yet, it is the chat's first window
    /// and goes through `applyBackfill`, which restores the reading position.
    /// A patch for another chat than the one shown is not applied.
    public func applyPatch(
        _ entries: [[String: Any]],
        removedIds: [String] = [],
        truncatedCount newTruncatedCount: Int = 0,
        chatId: String? = nil
    ) {
        if let chatId, let currentChatId, chatId != currentChatId { return }
        if messages.isEmpty || currentChatId == nil {
            applyBackfill(entries, truncatedCount: newTruncatedCount, chatId: chatId, loadingState: loadingState)
            return
        }
        let incoming = entries.compactMap(Self.parseMessage)
        var next = messages
        var changed = false
        var addedAny = false
        var removedAny = false
        var timestampChanged = false
        var appendedOutOfOrder = false
        var changedIndices: [Int] = []
        var dirtyMessageIds: Set<String> = []

        if !removedIds.isEmpty {
            let removed = Set(removedIds)
            let before = next.count
            next.removeAll { removed.contains($0.id) }
            if next.count != before {
                changed = true
                removedAny = true
                dirtyMessageIds.formUnion(removed)
            }
        }

        let incremental = NativeChatPerformance.isEnabled(.incrementalRows)
        let canUseExistingIndex = incremental && !removedAny
        var fallbackPosition: [String: Int] = [:]
        if !canUseExistingIndex {
            for (idx, msg) in next.enumerated() { fallbackPosition[msg.id] = idx }
        }

        for msg in incoming {
            if let idx = canUseExistingIndex ? indexById[msg.id] : fallbackPosition[msg.id] {
                let existing = next[idx]
                var merged = msg
                merged.thinking = msg.thinking ?? existing.thinking
                if msg.status == nil { merged.status = existing.status }
                if Self.isTerminalStatus(merged.status) {
                    merged.isThinkingStreaming = false
                } else if msg.thinking == nil {
                    merged.isThinkingStreaming = existing.isThinkingStreaming
                }
                if msg.content.isEmpty { merged.content = existing.content }
                if merged != existing {
                    if merged.timestamp != existing.timestamp {
                        timestampChanged = true
                    }
                    next[idx] = merged
                    changed = true
                    changedIndices.append(idx)
                    dirtyMessageIds.insert(merged.id)
                }
            } else {
                var inserted = msg
                if Self.isTerminalStatus(inserted.status) {
                    inserted.isThinkingStreaming = false
                }
                if let lastTs = next.last?.timestamp, inserted.timestamp < lastTs {
                    appendedOutOfOrder = true
                }
                let newIdx = next.count
                if canUseExistingIndex {
                    indexById[inserted.id] = newIdx
                } else {
                    fallbackPosition[inserted.id] = newIdx
                }
                next.append(inserted)
                changed = true
                addedAny = true
                dirtyMessageIds.insert(inserted.id)
            }
        }
        let countChanged = newTruncatedCount != truncatedCount
        guard changed || countChanged else { return }

        let needsSortAndReindex = !incremental || removedAny || timestampChanged || appendedOutOfOrder
        if needsSortAndReindex {
            // Chronological, ties in the order held (a new row after its equals), as a backfill sorts.
            next = next.enumerated().sorted { lhs, rhs in
                if lhs.element.timestamp != rhs.element.timestamp {
                    return lhs.element.timestamp < rhs.element.timestamp
                }
                return lhs.offset < rhs.offset
            }.map(\.element)
            indexById = [:]
            for (idx, msg) in next.enumerated() { indexById[msg.id] = idx }
        }

        truncatedCount = newTruncatedCount

        if incremental, !needsSortAndReindex, !addedAny, !changedIndices.isEmpty,
           tryInPlaceRowUpdate(from: messages, to: next, changedIndices: changedIndices) {
            if #available(iOS 16.0, macOS 14.0, *) {
                NativeChatImagePreloader.shared.preload(messages: incoming)
            }
            if next == messages {
                objectWillChange.send()
            } else {
                messages = next
            }
            return
        }

        let built = Self.buildRowsWithDirtyIds(
            from: next,
            previousRows: rows,
            dirtyMessageIds: (!incremental || needsSortAndReindex) ? nil : dirtyMessageIds
        )
        replaceAllRows(built.rows, dirtyRowIds: incremental ? built.dirtyRowIds : nil)
        if #available(iOS 16.0, macOS 14.0, *) {
            NativeChatImagePreloader.shared.preload(messages: incoming)
        }
        if next == messages {
            objectWillChange.send()
        } else {
            messages = next
        }
    }

    /// Handle an `update` wire message — currently streaming `thinking` deltas.
    public func applyUpdate(_ msg: [String: Any]) {
        guard let id = msg["messageId"] as? String, !id.isEmpty else { return }
        let thinking = msg["thinking"] as? [String: Any]
        let content = thinking?["content"] as? String
        let streaming = thinking?["isStreaming"] as? Bool ?? false

        if let idx = indexById[id] {
            let existing = messages[idx]
            var updated = existing
            if let content, !content.isEmpty || existing.thinking == nil {
                updated.thinking = content
            }
            updated.isThinkingStreaming = streaming && !Self.isTerminalStatus(updated.status)
            if updated != existing {
                let incremental = NativeChatPerformance.isEnabled(.incrementalRows)
                var next = messages
                next[idx] = updated
                if !incremental || !tryInPlaceRowUpdate(from: messages, to: next, changedIndices: [idx]) {
                    let built = Self.buildRowsWithDirtyIds(from: next, previousRows: rows, dirtyMessageIds: incremental ? [id] : nil)
                    replaceAllRows(built.rows, dirtyRowIds: incremental ? built.dirtyRowIds : nil)
                }
                messages = next
            }
        } else {
            // Update before add — materialise a placeholder so streaming is visible.
            let status = msg["status"] as? String
            let placeholder = NativeChatMessage(
                id: id,
                chatId: msg["chatId"] as? String,
                role: .assistant,
                content: "",
                status: status,
                thinking: content,
                isThinkingStreaming: streaming && !Self.isTerminalStatus(status),
                timestamp: (msg["timestamp"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970 * 1000
            )
            upsert(placeholder)
        }
    }

    /// Record an acknowledged answer (live cards wait for the web transport snapshot).
    public func markQuestionAnswered(messageId: String, answer: String, selectedValues: [String] = []) {
        guard let idx = indexById[messageId], var ask = messages[idx].askUser else { return }
        ask.completed = true
        ask.submitting = false
        ask.submissionError = nil
        ask.answer = answer
        if !selectedValues.isEmpty {
            ask.selectedValues = selectedValues
        } else {
            ask.selectedValues = [answer]
        }
        var updated = messages[idx]
        updated.askUser = ask
        updated.status = "complete"
        updated.isThinkingStreaming = false
        if updated != messages[idx] {
            let incremental = NativeChatPerformance.isEnabled(.incrementalRows)
            var next = messages
            next[idx] = updated
            if !incremental || !tryInPlaceRowUpdate(from: messages, to: next, changedIndices: [idx]) {
                let built = Self.buildRowsWithDirtyIds(from: next, previousRows: rows, dirtyMessageIds: incremental ? [messageId] : nil)
                replaceAllRows(built.rows, dirtyRowIds: incremental ? built.dirtyRowIds : nil)
            }
            messages = next
        }
    }

    /// Settle any remaining `isThinkingStreaming` flags when a chat's turn ends,
    /// preserving accumulated `thinking` text.
    public func settleStreaming(chatId: String? = nil) {
        if let chatId, let currentChatId, chatId != currentChatId { return }
        var changedIndices: [Int] = []
        var next = messages
        for idx in next.indices where next[idx].isThinkingStreaming {
            if let chatId, let msgChatId = next[idx].chatId, msgChatId != chatId {
                continue
            }
            next[idx].isThinkingStreaming = false
            changedIndices.append(idx)
        }
        guard !changedIndices.isEmpty else { return }
        let incremental = NativeChatPerformance.isEnabled(.incrementalRows)
        if !incremental || !tryInPlaceRowUpdate(from: messages, to: next, changedIndices: changedIndices) {
            let dirtyIds = Set(changedIndices.map { next[$0].id })
            let built = Self.buildRowsWithDirtyIds(from: next, previousRows: rows, dirtyMessageIds: incremental ? dirtyIds : nil)
            replaceAllRows(built.rows, dirtyRowIds: incremental ? built.dirtyRowIds : nil)
        }
        messages = next
    }

    public func clear() {
        guard !messages.isEmpty || truncatedCount != 0 || loadingState != .loading else { return }
        loadingState = .loading
        replaceAllRows([], dirtyRowIds: nil)
        truncatedCount = 0
        indexById.removeAll()
        messages.removeAll()
    }

    private func upsert(_ msg: NativeChatMessage) {
        if #available(iOS 16.0, macOS 14.0, *) {
            NativeChatImagePreloader.shared.preload(messages: [msg])
        }
        if let idx = indexById[msg.id] {
            // Merge — never clobber accumulated streaming state with an empty add.
            let existing = messages[idx]
            var merged = msg
            merged.thinking = msg.thinking ?? existing.thinking
            if msg.status == nil { merged.status = existing.status }
            if Self.isTerminalStatus(merged.status) {
                merged.isThinkingStreaming = false
            } else if msg.thinking == nil {
                merged.isThinkingStreaming = existing.isThinkingStreaming
            }
            if msg.content.isEmpty { merged.content = existing.content }
            if merged != existing {
                let incremental = NativeChatPerformance.isEnabled(.incrementalRows)
                var next = messages
                next[idx] = merged
                if incremental,
                   merged.timestamp == existing.timestamp,
                   tryInPlaceRowUpdate(from: messages, to: next, changedIndices: [idx]) {
                    messages = next
                    return
                }
                let timestampChanged = merged.timestamp != existing.timestamp
                if timestampChanged {
                    // An update-before-add placeholder uses arrival time. The
                    // persisted add must restore transcript order, as patches do.
                    next = next.enumerated().sorted { lhs, rhs in
                        if lhs.element.timestamp != rhs.element.timestamp {
                            return lhs.element.timestamp < rhs.element.timestamp
                        }
                        return lhs.offset < rhs.offset
                    }.map(\.element)
                    indexById = [:]
                    for (i, item) in next.enumerated() {
                        indexById[item.id] = i
                    }
                }
                let built = Self.buildRowsWithDirtyIds(
                    from: next,
                    previousRows: rows,
                    dirtyMessageIds: (!incremental || timestampChanged) ? nil : [merged.id]
                )
                replaceAllRows(built.rows, dirtyRowIds: incremental ? built.dirtyRowIds : nil)
                messages = next
            }
        } else {
            let incremental = NativeChatPerformance.isEnabled(.incrementalRows)
            var inserted = msg
            if Self.isTerminalStatus(inserted.status) {
                inserted.isThinkingStreaming = false
            }
            var next = messages
            var insertedOutOfOrder = false
            if inserted.timestamp > 0, let insertIdx = next.firstIndex(where: { $0.timestamp > inserted.timestamp }) {
                next.insert(inserted, at: insertIdx)
                insertedOutOfOrder = true
                indexById = [:]
                for (i, item) in next.enumerated() {
                    indexById[item.id] = i
                }
            } else {
                indexById[inserted.id] = next.count
                next.append(inserted)
            }
            let built = Self.buildRowsWithDirtyIds(
                from: next,
                previousRows: rows,
                dirtyMessageIds: (!incremental || insertedOutOfOrder) ? nil : [inserted.id]
            )
            replaceAllRows(built.rows, dirtyRowIds: incremental ? built.dirtyRowIds : nil)
            messages = next
        }
    }

    // MARK: - In-Place Content / Thinking Row Fast Path

    /// Computes the non-tool row(s) produced by a single message in isolation (excluding conversation gap rows).
    /// Returns `nil` if the message is a tool row or would change visibility.
    private static func singleNonToolRows(for msg: NativeChatMessage) -> [NativeChatRow]? {
        if msg.hiddenInChat || msg.mergedIntoQuestionId != nil || msg.isToolRow {
            return nil
        }
        if msg.taskNotification != nil {
            return [.taskNotification(msg)]
        } else if msg.isNote || msg.method == "user-note" || msg.artefactRef != nil {
            var out: [NativeChatRow] = []
            if let thinking = msg.thinking, !thinking.isEmpty {
                out.append(.thinking(msg))
            }
            out.append(.note(msg))
            return out
        } else if msg.role == .user {
            return [.user(msg)]
        } else if msg.systemStatus != nil || msg.method == "system-status" {
            return [.systemStatus(msg)]
        } else if let cliEvent = msg.cliEvent {
            if cliEvent.kind == "rate_limit" && !UserDefaults.standard.bool(forKey: "ripul.showNativeHiddenPanels") {
                return []
            }
            return [.cliEvent(msg)]
        } else if (msg.method ?? "").hasPrefix("cli.") {
            return []
        } else if msg.errorInfo != nil || (msg.status == "error" && msg.askUser == nil && msg.content.isEmpty) {
            return [.error(msg)]
        } else if msg.content.isEmpty && msg.askUser == nil && msg.table == nil && msg.tabs.isEmpty && msg.imageAttachments.isEmpty && msg.videoAttachments.isEmpty {
            if let thinking = msg.thinking, !thinking.isEmpty {
                return [.thinking(msg)]
            } else {
                return [.assistant(msg)]
            }
        } else {
            return [.assistant(msg)]
        }
    }

    /// Attempts to update `rows` in-place when only existing messages changed content/thinking/status
    /// without altering row IDs, row count, timestamps, or tool-group structure.
    private func tryInPlaceRowUpdate(
        from oldMessages: [NativeChatMessage],
        to newMessages: [NativeChatMessage],
        changedIndices: [Int]
    ) -> Bool {
        guard NativeChatPerformance.isEnabled(.incrementalRows) else { return false }
        var pendingRowUpdates: [(rowIdx: Int, newRow: NativeChatRow)] = []
        var dirtyRowIds: Set<String> = []

        for idx in changedIndices {
            let oldMsg = oldMessages[idx]
            let newMsg = newMessages[idx]
            guard oldMsg.timestamp == newMsg.timestamp,
                  oldMsg.role == newMsg.role,
                  oldMsg.isNote == newMsg.isNote,
                  oldMsg.hiddenInChat == newMsg.hiddenInChat,
                  oldMsg.mergedIntoQuestionId == newMsg.mergedIntoQuestionId,
                  oldMsg.isToolRow == newMsg.isToolRow else {
                return false
            }

            if newMsg.isToolRow {
                // Fast path for streaming thinking updates on a tool row when tool fields didn't change
                let oldHasThinking = !(oldMsg.thinking ?? "").isEmpty
                let newHasThinking = !(newMsg.thinking ?? "").isEmpty
                guard oldHasThinking && newHasThinking,
                      oldMsg.chatId == newMsg.chatId,
                      oldMsg.toolCall == newMsg.toolCall,
                      oldMsg.status == newMsg.status,
                      oldMsg.label == newMsg.label,
                      oldMsg.method == newMsg.method,
                      oldMsg.summary == newMsg.summary else {
                    return false
                }
                let updatedRow = NativeChatRow.thinking(newMsg)
                let thinkingRowId = updatedRow.id
                guard let rowIdx = rowIndexById[thinkingRowId] else { return false }
                pendingRowUpdates.append((rowIdx, updatedRow))
                dirtyRowIds.insert(thinkingRowId)
                continue
            }

            guard let oldMessageRows = Self.singleNonToolRows(for: oldMsg),
                  let newMessageRows = Self.singleNonToolRows(for: newMsg),
                  oldMessageRows.count == newMessageRows.count else {
                return false
            }

            for (oldRow, newRow) in zip(oldMessageRows, newMessageRows) {
                guard oldRow.id == newRow.id,
                      let rowIdx = rowIndexById[newRow.id] else {
                    return false
                }
                if oldRow != newRow {
                    pendingRowUpdates.append((rowIdx, newRow))
                    dirtyRowIds.insert(newRow.id)
                }
            }
        }

        var nextRows = rows
        for (rowIdx, newRow) in pendingRowUpdates {
            nextRows[rowIdx] = newRow
            updateWebRowIdEntry(for: newRow)
        }
        lastChangedRowIds = dirtyRowIds
        if !dirtyRowsRequireFullScan {
            accumulatedDirtyRowIds.formUnion(dirtyRowIds)
        }
        rows = nextRows
        return true
    }

    // MARK: - Row Builder (Conversations Gaps + Tool Strip Grouping)

    static func buildRows(from messages: [NativeChatMessage], previousRows: [NativeChatRow] = []) -> [NativeChatRow] {
        buildRowsWithDirtyIds(from: messages, previousRows: previousRows, dirtyMessageIds: nil).rows
    }

    static func buildRowsWithDirtyIds(
        from messages: [NativeChatMessage],
        previousRows: [NativeChatRow] = [],
        dirtyMessageIds: Set<String>? = nil
    ) -> (rows: [NativeChatRow], dirtyRowIds: Set<String>?) {
        let effectiveDirtyMessageIds = NativeChatPerformance.isEnabled(.incrementalRows) ? dirtyMessageIds : nil
        var result: [NativeChatRow] = []
        result.reserveCapacity(previousRows.count + 4)
        var pendingTools: [NativeChatMessage] = []
        var previousTimestamp: Double? = nil
        var existingGroupIdByCallId: [String: String] = [:]
        var existingGroupByCallIds: [[String]: NativeChatToolGroup] = [:]
        var previousRowById: [String: NativeChatRow] = [:]
        previousRowById.reserveCapacity(previousRows.count)
        var usedGroupIds: Set<String> = []
        for row in previousRows {
            previousRowById[row.id] = row
            if case .toolGroup(let group) = row {
                for callId in group.allCallIds {
                    existingGroupIdByCallId[callId] = group.id
                }
                if effectiveDirtyMessageIds != nil {
                    existingGroupByCallIds[group.allCallIds] = group
                }
            }
        }

        func flushTools() {
            guard !pendingTools.isEmpty else { return }
            if let effectiveDirtyMessageIds,
               pendingTools.allSatisfy({ !effectiveDirtyMessageIds.contains($0.id) }),
               let reusable = existingGroupByCallIds[pendingTools.map(\.id)],
               pendingTools.contains(where: { $0.id == reusable.id }),
               !usedGroupIds.contains(reusable.id) {
                usedGroupIds.insert(reusable.id)
                result.append(.toolGroup(reusable))
            } else if let group = buildToolGroup(
                from: pendingTools,
                existingGroupIdByCallId: existingGroupIdByCallId,
                usedGroupIds: &usedGroupIds
            ) {
                result.append(.toolGroup(group))
            }
            if let lastTs = pendingTools.last?.timestamp, lastTs > 0 {
                previousTimestamp = lastTs
            }
            pendingTools.removeAll()
        }

        for msg in messages {
            if msg.hiddenInChat || msg.mergedIntoQuestionId != nil {
                continue
            }

            if msg.isToolRow {
                // If this tool row also carries streaming/settled thinking, surface the thinking peer before the tool group
                if let thinking = msg.thinking, !thinking.isEmpty {
                    flushTools()
                    result.append(.thinking(msg))
                }
                pendingTools.append(msg)
                continue
            }

            flushTools()

            // Insert conversation gap before user messages/notes when >= 1 hour or day changed
            if (msg.role == .user || msg.isNote), msg.timestamp > 0 {
                if let prev = previousTimestamp, prev > 0, let gapText = conversationGapText(previousMs: prev, currentMs: msg.timestamp) {
                    result.append(.gap(NativeChatGap(id: msg.id, text: gapText, timestamp: msg.timestamp)))
                }
            }
            if msg.timestamp > 0 {
                previousTimestamp = msg.timestamp
            }

            if msg.taskNotification != nil {
                result.append(.taskNotification(msg))
            } else if msg.isNote || msg.method == "user-note" || msg.artefactRef != nil {
                if let thinking = msg.thinking, !thinking.isEmpty {
                    result.append(.thinking(msg))
                }
                result.append(.note(msg))
            } else if msg.role == .user {
                result.append(.user(msg))
            } else if msg.systemStatus != nil || msg.method == "system-status" {
                result.append(.systemStatus(msg))
            } else if let cliEvent = msg.cliEvent {
                if cliEvent.kind == "rate_limit" && !UserDefaults.standard.bool(forKey: "ripul.showNativeHiddenPanels") {
                    continue
                }
                result.append(.cliEvent(msg))
            } else if (msg.method ?? "").hasPrefix("cli.") {
                continue
            } else if msg.errorInfo != nil || (msg.status == "error" && msg.askUser == nil && msg.content.isEmpty) {
                result.append(.error(msg))
            } else if msg.content.isEmpty && msg.askUser == nil && msg.table == nil && msg.tabs.isEmpty && msg.imageAttachments.isEmpty && msg.videoAttachments.isEmpty {
                if let thinking = msg.thinking, !thinking.isEmpty {
                    result.append(.thinking(msg))
                } else {
                    result.append(.assistant(msg))
                }
            } else {
                result.append(.assistant(msg))
            }
        }

        flushTools()

        var seenRowIds = Set<String>(minimumCapacity: result.count)
        var hasDuplicateRowId = false
        for row in result {
            if !seenRowIds.insert(row.id).inserted {
                hasDuplicateRowId = true
                break
            }
        }
        if hasDuplicateRowId {
            seenRowIds.removeAll(keepingCapacity: true)
            result = result.filter { seenRowIds.insert($0.id).inserted }
            return (result, nil)
        }

        guard effectiveDirtyMessageIds != nil, !previousRows.isEmpty else {
            return (result, nil)
        }
        var dirtyRowIds: Set<String> = []
        if result.count != previousRows.count {
            for row in result {
                if previousRowById[row.id] != row {
                    dirtyRowIds.insert(row.id)
                }
            }
            for oldRow in previousRows where !seenRowIds.contains(oldRow.id) {
                dirtyRowIds.insert(oldRow.id)
            }
        } else {
            for (oldRow, newRow) in zip(previousRows, result) {
                if oldRow.id != newRow.id {
                    dirtyRowIds.insert(oldRow.id)
                    dirtyRowIds.insert(newRow.id)
                } else if oldRow != newRow {
                    dirtyRowIds.insert(newRow.id)
                }
            }
        }
        return (result, dirtyRowIds)
    }

    private static func buildToolGroup(
        from messages: [NativeChatMessage],
        existingGroupIdByCallId: [String: String] = [:],
        usedGroupIds: inout Set<String>
    ) -> NativeChatToolGroup? {
        guard let first = messages.first else { return nil }
        let chatId = first.chatId ?? "chat"
        let updatedAt = messages.map(\.timestamp).max() ?? first.timestamp

        var taskRuns: [NativeChatTaskRunItem] = []
        var agentComms: [NativeChatAgentCommsItem] = []
        var calls: [ToolCallDetail] = []
        var allCallIds: [String] = []

        struct RawCallItem {
            let id: String
            let label: String
            let rendererName: String
            let symbol: String?
            let status: String?
            let defaultAction: ToolDefaultAction?
        }
        var stripCandidates: [RawCallItem] = []

        for msg in messages {
            allCallIds.append(msg.id)
            if let tc = msg.toolCall {
                let resolvedDetail = tc.detail ?? Self.FallbackToolDetail(for: msg)
                calls.append(resolvedDetail)
                if let run = tc.taskRun, let kind = tc.taskRunKind {
                    taskRuns.append(NativeChatTaskRunItem(id: resolvedDetail.id, kind: kind, snapshot: run))
                } else if let comms = tc.agentComms {
                    agentComms.append(
                        NativeChatAgentCommsItem(
                            id: resolvedDetail.id,
                            timestamp: msg.timestamp,
                            presentation: comms,
                            detail: resolvedDetail
                        )
                    )
                } else {
                    stripCandidates.append(
                        RawCallItem(
                            id: resolvedDetail.id,
                            label: tc.label,
                            rendererName: tc.rendererName,
                            symbol: tc.symbol,
                            status: tc.status,
                            defaultAction: tc.defaultAction
                        )
                    )
                }
            } else {
                let rawName = msg.label ?? msg.method ?? "Tool"
                calls.append(Self.FallbackToolDetail(for: msg))
                stripCandidates.append(
                    RawCallItem(
                        id: msg.id,
                        label: rawName,
                        rendererName: rawName,
                        symbol: nil,
                        status: msg.status,
                        defaultAction: nil
                    )
                )
            }
        }

        // Group display identities in reverse-recent order (matching `buildToolGroupSummary` in `toolGroupSummary.ts`)
        let compact = Set(stripCandidates.map(\.label)).count > 5
        var orderedKeys: [String] = []
        var groupedByKey: [String: (label: String, count: Int, callIds: [String], rendererName: String, symbol: String?, status: String?, defaultAction: ToolDefaultAction?)] = [:]

        for call in stripCandidates {
            let compactedLabel: String
            let compactedRenderer: String
            if compact, call.rendererName.hasPrefix("Bash:"), let firstExec = call.rendererName.dropFirst(5).components(separatedBy: " + ").first, !firstExec.isEmpty {
                compactedRenderer = "Bash:\(firstExec)"
                compactedLabel = call.label.components(separatedBy: " + ").first ?? call.label
            } else {
                compactedRenderer = call.rendererName
                compactedLabel = call.label
            }
            let key = "tool:\(compactedLabel)"
            var entry = groupedByKey[key] ?? (
                label: compactedLabel,
                count: 0,
                callIds: [],
                rendererName: compactedRenderer,
                symbol: call.symbol,
                status: call.status,
                defaultAction: call.defaultAction
            )
            entry.count += 1
            entry.callIds.append(call.id)
            entry.status = call.status
            entry.defaultAction = call.defaultAction
            groupedByKey[key] = entry
            orderedKeys.removeAll { $0 == key }
            orderedKeys.append(key)
        }

        var stripTools: [NativeToolStripItem] = []
        var callIdsByToolId: [String: [String]] = [:]
        for key in orderedKeys.reversed() {
            guard let entry = groupedByKey[key], let firstId = entry.callIds.first else { continue }
            stripTools.append(
                NativeToolStripItem(
                    id: firstId,
                    label: entry.label,
                    count: entry.count,
                    rendererName: entry.rendererName,
                    symbol: entry.symbol,
                    defaultAction: entry.defaultAction,
                    status: entry.status
                )
            )
            callIdsByToolId[firstId] = entry.callIds
        }

        // Only reuse an existing group ID if that ID is actually a member of THIS
        // group's `allCallIds`. Otherwise, when a group `[call-1, call-2]` (whose ID
        // was `"call-2"`) splits into `[call-1]` and `[call-2]` (or when `[call-1, call-2]`
        // reorders across a thinking peer), the first subgroup would steal `"call-2"`
        // via `existingGroupIdByCallId` and force the second subgroup `["call-2"]` to
        // fall back to `first.id == "call-2"`, producing duplicate `"toolGroup:call-2"` row IDs.
        let callIdSet = Set(allCallIds)
        var stableGroupId = allCallIds
            .compactMap { existingGroupIdByCallId[$0] }
            .first(where: { callIdSet.contains($0) && !usedGroupIds.contains($0) })
            ?? allCallIds.first(where: { !usedGroupIds.contains($0) })
            ?? first.id
        if usedGroupIds.contains(stableGroupId) {
            var suffix = 2
            while usedGroupIds.contains("\(first.id)#\(suffix)") {
                suffix += 1
            }
            stableGroupId = "\(first.id)#\(suffix)"
        }
        usedGroupIds.insert(stableGroupId)

        return NativeChatToolGroup(
            id: stableGroupId,
            chatId: chatId,
            updatedAt: updatedAt,
            tools: stripTools,
            callIdsByToolId: callIdsByToolId,
            taskRuns: taskRuns,
            agentComms: agentComms,
            calls: calls,
            allCallIds: allCallIds
        )
    }

    private static func FallbackToolDetail(for msg: NativeChatMessage) -> ToolCallDetail {
        let toolName = msg.toolCall?.toolName ?? msg.method ?? msg.label ?? "Tool"
        let rendererName = msg.toolCall?.rendererName ?? toolName
        let status = msg.toolCall?.status ?? msg.status ?? "completed"
        let summaryText = msg.toolCall?.summary ?? msg.summary
        return ToolCallDetail(
            id: msg.id,
            toolName: toolName,
            status: status,
            timestamp: msg.timestamp,
            arguments: "{}",
            result: summaryText,
            error: status == "error" ? (summaryText ?? "Tool execution failed") : nil,
            diagnostics: "{}",
            rendererName: rendererName,
            renderArguments: nil,
            commandPresentation: nil
        )
    }

    private static let sameYearGapFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, d MMM · HH:mm"
        return formatter
    }()

    private static let differentYearGapFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, d MMM yyyy · HH:mm"
        return formatter
    }()

    /// Mirrors `conversationGaps.ts`: returns a formatted separator string if the day changed
    /// or at least 1 hour passed between `previousMs` and `currentMs`.
    static func conversationGapText(previousMs: Double, currentMs: Double) -> String? {
        let elapsedMs = currentMs - previousMs
        guard elapsedMs > 0 else { return nil }
        let prevDate = Date(timeIntervalSince1970: previousMs / 1000)
        let currDate = Date(timeIntervalSince1970: currentMs / 1000)
        let calendar = Calendar.current
        let sameDay = calendar.isDate(prevDate, inSameDayAs: currDate)
        let hourMs: Double = 3_600_000
        guard !sameDay || elapsedMs >= hourMs else { return nil }

        if sameDay {
            let hours = Int((elapsedMs / hourMs).rounded())
            return hours <= 1 ? "1 hour later" : "\(hours) hours later"
        }

        let sameYear = calendar.component(.year, from: prevDate) == calendar.component(.year, from: currDate)
        let formatter = sameYear ? sameYearGapFormatter : differentYearGapFormatter
        return formatter.string(from: currDate)
    }

    // MARK: - Wire Parsing

    private static func parseMessage(_ msg: [String: Any]) -> NativeChatMessage? {
        guard let id = msg["messageId"] as? String, !id.isEmpty else { return nil }
        let role = NativeChatMessage.Role(rawValue: msg["role"] as? String ?? "") ?? .assistant
        let status = msg["status"] as? String
        let rawStreaming = (msg["thinking"] as? [String: Any])?["isStreaming"] as? Bool ?? false
        var incoming = NativeChatMessage(
            id: id,
            chatId: msg["chatId"] as? String,
            role: role,
            content: msg["content"] as? String ?? "",
            status: status,
            method: msg["method"] as? String,
            label: msg["label"] as? String,
            summary: msg["summary"] as? String,
            askUser: Self.parseAskUser(msg["askUser"]),
            taskNotification: Self.parseTaskNotification(msg["taskNotification"]),
            senderLabel: msg["senderLabel"] as? String,
            thinking: (msg["thinking"] as? [String: Any])?["content"] as? String,
            isThinkingStreaming: rawStreaming && !Self.isTerminalStatus(status),
            timestamp: (msg["timestamp"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970 * 1000
        )

        incoming.hiddenInChat = msg["hiddenInChat"] as? Bool ?? false
        incoming.mergedIntoQuestionId = msg["mergedIntoQuestionId"] as? String
        incoming.replyQuote = Self.parseReplyQuote(msg["replyQuote"])
        incoming.contextTags = Self.parseContextTags(msg["contextTags"])
        incoming.contextAttachments = Self.parseContextAttachments(msg["contextAttachments"])
        incoming.imageAttachments = Self.parseImageAttachments(msg["imageAttachments"])
        incoming.videoAttachments = (msg["videoAttachments"] as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["id"] as? String, let url = item["url"] as? String, !id.isEmpty, !url.isEmpty else { return nil }
            return NativeChatVideoAttachment(id: id, url: url, posterUrl: item["posterUrl"] as? String,
                                             name: item["name"] as? String, width: item["width"] as? Int, height: item["height"] as? Int)
        }
        incoming.fileAttachments = Self.parseFileAttachments(msg["fileAttachments"])
        incoming.isVoice = msg["isVoice"] as? Bool ?? false
        incoming.isGroupChat = msg["isGroupChat"] as? Bool ?? false
        if let own = msg["isOwnMessage"] as? Bool {
            incoming.isOwnMessage = own
        }
        incoming.avatarUrl = msg["avatarUrl"] as? String
        incoming.senderUserId = msg["senderUserId"] as? String
        incoming.senderAgent = (msg["senderAgent"] as? [String: Any]).flatMap(NativeChatAgentSender.init)
        incoming.deliveryStatus = msg["deliveryStatus"] as? String
        incoming.respondent = Self.parseRespondent(msg["respondent"])
        incoming.tabs = Self.parseTabs(msg["tabs"])
        incoming.table = Self.parseTable(msg["table"])
        incoming.isNote = msg["isNote"] as? Bool ?? (msg["type"] as? String == "user-note" || incoming.method == "user-note")
        incoming.artefactRef = Self.parseArtefactRef(msg["artefactRef"])
        incoming.systemStatus = Self.parseSystemStatus(msg["systemStatus"])
        incoming.errorInfo = Self.parseErrorInfo(msg["errorInfo"])
        incoming.cliEvent = Self.parseCliEvent(msg["cliEvent"])
        incoming.toolCall = Self.parseToolCall(msg["toolCall"])
        if role == .assistant, let call = incoming.toolCall?.detail, let speech = NativeChatSpeech(call) {
            incoming.speech = speech
            incoming.content = speech.text
        }
        return incoming
    }

    private static func parseTaskNotification(_ raw: Any?) -> NativeTaskNotification? {
        guard let dict = raw as? [String: Any] else { return nil }
        return NativeTaskNotification(
            taskId: dict["taskId"] as? String,
            status: dict["status"] as? String,
            summary: dict["summary"] as? String
        )
    }

    private static func parseAskUser(_ raw: Any?) -> NativeAskUser? {
        guard let dict = raw as? [String: Any] else { return nil }
        let question = dict["question"] as? String ?? ""
        let rawOptions = dict["options"] as? [[String: Any]] ?? []
        let options = rawOptions.map {
            NativeAskUser.Option(
                label: $0["label"] as? String ?? "",
                value: $0["value"] as? String ?? "",
                description: $0["description"] as? String,
                link: $0["link"] as? String,
                image: $0["image"] as? String
            )
        }
        var answerString: String? = nil
        var selectedValues: [String] = []
        if let ans = dict["answer"] as? String {
            answerString = ans
            selectedValues = [ans]
        } else if let arr = dict["answer"] as? [Any] {
            let strs = arr.map { String(describing: $0) }
            selectedValues = strs
            answerString = strs.joined(separator: ", ")
        }
        var dateInput: NativeDateInput? = nil
        if let di = dict["dateInput"] as? [String: Any] {
            dateInput = NativeDateInput(
                includeTime: di["includeTime"] as? Bool ?? false,
                minDate: di["minDate"] as? String,
                maxDate: di["maxDate"] as? String,
                defaultDate: di["defaultDate"] as? String
            )
        }
        let tabs = parseTabs(dict["tabs"])
        let table = parseTable(dict["table"])
        let responseKey = dict["responseKey"] as? String
        let passwordInput = (dict["passwordInput"] as? Bool ?? false) || (responseKey?.hasPrefix("owner_browser_access_secret_") ?? false)
        return NativeAskUser(
            question: question,
            options: options,
            multiSelect: dict["multiSelect"] as? Bool ?? false,
            severity: dict["severity"] as? String,
            expectsResponse: dict["expectsResponse"] as? Bool ?? (!options.isEmpty || dateInput != nil || passwordInput),
            enableChatInput: dict["enableChatInput"] as? Bool ?? false,
            passwordInput: passwordInput,
            completed: dict["completed"] as? Bool ?? (answerString != nil),
            submitting: dict["submitting"] as? Bool ?? false,
            submissionError: dict["submissionError"] as? String,
            answer: answerString,
            selectedValues: selectedValues,
            responseKey: responseKey,
            threadId: dict["threadId"] as? String,
            actionId: dict["actionId"] as? String,
            dateInput: dateInput,
            tabs: tabs.isEmpty ? nil : tabs,
            table: table
        )
    }

    private static func parseReplyQuote(_ raw: Any?) -> NativeReplyQuote? {
        guard let dict = raw as? [String: Any],
              let correlationId = dict["correlationId"] as? String,
              !correlationId.isEmpty else { return nil }
        return NativeReplyQuote(
            correlationId: correlationId,
            senderDisplayName: dict["senderDisplayName"] as? String,
            excerpt: dict["excerpt"] as? String ?? ""
        )
    }

    private static func parseContextTags(_ raw: Any?) -> [NativeContextTag] {
        guard let list = raw as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let tagName = item["tagName"] as? String else { return nil }
            let label = item["label"] as? String ?? tagName
            let content = item["content"] as? String ?? ""
            return NativeContextTag(tagName: tagName, label: label, content: content)
        }
    }

    private static func parseContextAttachments(_ raw: Any?) -> [NativeContextAttachment] {
        guard let list = raw as? [[String: Any]] else { return [] }
        return list.enumerated().compactMap { index, item in
            guard let title = item["title"] as? String else { return nil }
            return NativeContextAttachment(
                id: "\(index)",
                title: title,
                source: item["source"] as? String ?? "",
                icon: NativeContextAttachment.Icon(rawValue: item["icon"] as? String ?? "") ?? .app,
                scope: item["scope"] as? String ?? "",
                capturedAt: item["capturedAt"] as? String ?? "",
                content: item["content"] as? String ?? ""
            )
        }
    }

    private static func parseImageAttachments(_ raw: Any?) -> [NativeChatImageAttachment] {
        guard let list = raw as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let id = item["id"] as? String, !id.isEmpty else { return nil }
            return NativeChatImageAttachment(
                id: id,
                mediaType: item["mediaType"] as? String ?? "image/png",
                data: item["data"] as? String,
                url: item["url"] as? String,
                name: item["name"] as? String,
                width: (item["width"] as? NSNumber)?.intValue,
                height: (item["height"] as? NSNumber)?.intValue
            )
        }
    }

    private static func parseFileAttachments(_ raw: Any?) -> [NativeChatFileAttachment] {
        guard let list = raw as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let id = item["id"] as? String, !id.isEmpty else { return nil }
            return NativeChatFileAttachment(
                id: id,
                name: item["name"] as? String ?? "Attachment",
                mediaType: item["mediaType"] as? String,
                sizeBytes: (item["sizeBytes"] as? NSNumber)?.intValue
            )
        }
    }

    private static func parseRespondent(_ raw: Any?) -> NativeRespondentInfo? {
        guard let dict = raw as? [String: Any],
              let label = dict["label"] as? String,
              !label.isEmpty else { return nil }
        return NativeRespondentInfo(
            label: label,
            modelId: dict["modelId"] as? String,
            provider: dict["provider"] as? String,
            family: dict["family"] as? String,
            color: dict["color"] as? String,
            icon: dict["icon"] as? String,
            contextTokens: (dict["contextTokens"] as? NSNumber)?.intValue,
            contextWindow: (dict["contextWindow"] as? NSNumber)?.intValue,
            contextPercent: (dict["contextPercent"] as? NSNumber)?.intValue,
            durationMs: (dict["durationMs"] as? NSNumber)?.doubleValue,
            costUsd: (dict["costUsd"] as? NSNumber)?.doubleValue,
            inputTokens: (dict["inputTokens"] as? NSNumber)?.intValue,
            outputTokens: (dict["outputTokens"] as? NSNumber)?.intValue,
            cacheReadTokens: (dict["cacheReadTokens"] as? NSNumber)?.intValue,
            cacheWriteTokens: (dict["cacheWriteTokens"] as? NSNumber)?.intValue,
            toolCallCount: (dict["toolCallCount"] as? NSNumber)?.intValue,
            apiMessageId: dict["apiMessageId"] as? String,
            isRewindable: dict["isRewindable"] as? Bool ?? false,
            metaJson: dict["metaJson"] as? String
        )
    }

    private static func parseTabs(_ raw: Any?) -> [NativeMessageTab] {
        guard let list = raw as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let label = item["label"] as? String else { return nil }
            let content = item["content"] as? String ?? ""
            let markdown = item["markdown"] as? Bool ?? true
            return NativeMessageTab(label: label, content: content, markdown: markdown)
        }
    }

    private static func parseTable(_ raw: Any?) -> NativeMessageTable? {
        guard let dict = raw as? [String: Any],
              let rawCols = dict["columns"] as? [[String: Any]],
              let rawRows = dict["rows"] as? [[String: Any]] else { return nil }
        let columns = rawCols.compactMap { col -> NativeMessageTable.Column? in
            guard let key = col["key"] as? String else { return nil }
            let label = col["label"] as? String ?? key
            return NativeMessageTable.Column(key: key, label: label)
        }
        guard !columns.isEmpty else { return nil }
        let rows: [[String: String]] = rawRows.map { row in
            var mapped: [String: String] = [:]
            for (k, v) in row {
                if v is NSNull { continue }
                mapped[k] = String(describing: v)
            }
            return mapped
        }
        return NativeMessageTable(columns: columns, rows: rows)
    }

    private static func parseArtefactRef(_ raw: Any?) -> NativeArtefactReference? {
        guard let dict = raw as? [String: Any],
              let artefactId = dict["artefactId"] as? String else { return nil }
        let kind = dict["kind"] as? String ?? "artefact_reference/v1"
        let revision = (dict["revision"] as? NSNumber)?.intValue ?? 1
        let surface = dict["surface"] as? String ?? "widget"
        let presentationId = dict["presentationId"] as? String ?? artefactId
        let runId = dict["runId"] as? String
        let status = dict["status"] as? String ?? "ready"
        let errorMessage = dict["errorMessage"] as? String
        var accepted: NativeArtefactAcceptedSelection? = nil
        if let accDict = dict["acceptedSelection"] as? [String: Any],
           let label = accDict["label"] as? String,
           let runIdVal = accDict["runId"] as? String {
            let summary = accDict["summary"] as? String ?? ""
            accepted = NativeArtefactAcceptedSelection(label: label, summary: summary, runId: runIdVal)
        }
        return NativeArtefactReference(
            kind: kind,
            artefactId: artefactId,
            revision: revision,
            surface: surface,
            presentationId: presentationId,
            runId: runId,
            status: status,
            errorMessage: errorMessage,
            acceptedSelection: accepted
        )
    }

    private static func parseSystemStatus(_ raw: Any?) -> NativeSystemStatusInfo? {
        guard let dict = raw as? [String: Any],
              let message = dict["message"] as? String else { return nil }
        return NativeSystemStatusInfo(
            severity: dict["severity"] as? String ?? "info",
            title: dict["title"] as? String,
            message: message,
            isSharedEvent: dict["isSharedEvent"] as? Bool ?? false
        )
    }

    private static func parseErrorInfo(_ raw: Any?) -> NativeErrorInfo? {
        guard let dict = raw as? [String: Any],
              let message = dict["message"] as? String else { return nil }
        return NativeErrorInfo(
            title: dict["title"] as? String ?? "Error",
            message: message,
            details: dict["details"] as? String
        )
    }

    private static func parseCliEvent(_ raw: Any?) -> NativeCliEventInfo? {
        guard let dict = raw as? [String: Any],
              let label = dict["label"] as? String else { return nil }
        return NativeCliEventInfo(
            kind: dict["kind"] as? String ?? "raw_event",
            label: label,
            codeLabel: dict["codeLabel"] as? Bool ?? false,
            detail: dict["detail"] as? String,
            content: dict["content"] as? String,
            chips: dict["chips"] as? [String] ?? [],
            accent: dict["accent"] as? String ?? "default",
            rawJson: dict["rawJson"] as? String
        )
    }

    private static func parseToolCall(_ raw: Any?) -> NativeToolCallSummary? {
        guard let dict = raw as? [String: Any],
              let id = dict["id"] as? String else { return nil }
        let toolName = dict["toolName"] as? String ?? "Tool"
        let label = dict["label"] as? String ?? toolName
        let rendererName = dict["rendererName"] as? String ?? toolName
        let symbol = dict["symbol"] as? String
        let status = dict["status"] as? String ?? "pending"
        let summary = dict["summary"] as? String

        var defaultAction: ToolDefaultAction? = nil
        if let da = dict["defaultAction"] as? [String: Any],
           let daId = da["id"] as? String,
           let daTitle = da["title"] as? String {
            defaultAction = ToolDefaultAction(id: daId, title: daTitle)
        }

        var taskRunKind: NativeTaskRunSnapshot.Kind? = nil
        var taskRun: NativeTaskRunSnapshot? = nil
        if let tr = dict["taskRun"] as? [String: Any],
           let snapshot = try? NativeTaskRunSnapshot.decode(tr) {
            let kindStr = tr["kind"] as? String ?? "agent"
            taskRunKind = kindStr == "workflow" ? .workflow : .agent
            taskRun = snapshot
        } else if let taskDict = dict["task"] as? [String: Any],
                  let taskId = taskDict["id"] as? String,
                  let taskTitle = taskDict["title"] as? String {
            let typeStr = taskDict["type"] as? String ?? "local_agent"
            taskRunKind = typeStr.contains("workflow") ? .workflow : .agent
            let statusStr = taskDict["status"] as? String ?? "completed"
            let mappedState: String
            switch statusStr {
            case "running", "in_progress": mappedState = "running"
            case "failed", "error": mappedState = "failed"
            case "killed", "stopped": mappedState = "stopped"
            default: mappedState = "done"
            }
            let detailStr = (taskDict["usage"] as? String) ?? (taskDict["variant"] as? String) ?? "Sub-agent"
            let rawEntries = (taskDict["entries"] as? [[String: Any]]) ?? []
            let liveEntries: [[String: Any]] = rawEntries.enumerated().map { idx, entry in
                [
                    "id": "\(taskId)-\(idx)",
                    "label": (entry["label"] as? String) ?? "",
                    "detail": (entry["detail"] as? String) ?? "",
                ]
            }
            let synthesized: [String: Any] = [
                "id": id,
                "title": taskTitle,
                "detail": detailStr,
                "state": mappedState,
                "live": liveEntries,
            ]
            taskRun = try? NativeTaskRunSnapshot.decode(synthesized)
        }

        var agentComms: AgentCommsPresentation? = nil
        if let ac = dict["agentComms"],
           let data = try? JSONSerialization.data(withJSONObject: ac),
           let decoded = try? JSONDecoder().decode(AgentCommsPresentation.self, from: data) {
            agentComms = decoded
        }

        var detail: ToolCallDetail? = nil
        if let det = dict["detail"],
           let data = try? JSONSerialization.data(withJSONObject: det),
           let decoded = try? JSONDecoder().decode(ToolCallDetail.self, from: data) {
            detail = decoded
        } else if let data = try? JSONSerialization.data(withJSONObject: dict),
                  let decoded = try? JSONDecoder().decode(ToolCallDetail.self, from: data) {
            detail = decoded
        }

        return NativeToolCallSummary(
            id: id,
            toolName: toolName,
            label: label,
            rendererName: rendererName,
            symbol: symbol,
            status: status,
            summary: summary,
            defaultAction: defaultAction,
            taskRunKind: taskRunKind,
            taskRun: taskRun,
            agentComms: agentComms,
            detail: detail
        )
    }
}
