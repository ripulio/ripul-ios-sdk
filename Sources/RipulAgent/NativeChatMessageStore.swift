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
    public var completed: Bool
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
        completed: Bool = false,
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
        self.completed = completed
        self.answer = answer
        self.selectedValues = selectedValues
        self.responseKey = responseKey
        self.threadId = threadId
        self.actionId = actionId
        self.dateInput = dateInput
        self.tabs = tabs
        self.table = table
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
    public var imageAttachments: [NativeChatImageAttachment] = []
    public var fileAttachments: [NativeChatFileAttachment] = []
    public var isVoice: Bool = false
    public var isGroupChat: Bool = false
    public var isOwnMessage: Bool = true
    public var avatarUrl: String? = nil
    public var senderUserId: String? = nil
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
        if artefactRef != nil { return false }
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
    case bottom(animated: Bool)
    case userMessage(direction: String)
    case message(id: String, highlight: Bool)
    case restore(NativeChatScrollPosition)
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
    public private(set) var rows: [NativeChatRow] = [] {
        didSet {
            webRowIdByNativeRowId = Self.buildWebRowIdMap(for: rows)
        }
    }
    public private(set) var truncatedCount: Int = 0
    public private(set) var currentChatId: String? = nil

    /// Scroll restoration captured from Web Chat when toggling or switching into Native Chat.
    public var pendingScrollRestoration: NativeChatScrollPosition? = nil
    /// Latest scroll snapshot recorded by `NativeChatView` for syncing back to Web Chat.
    public var lastScrollSnapshot: NativeChatScrollPosition? = nil
    /// Live callback registered by `NativeChatView` to sample the exact scroll offset on toggle-off.
    public var captureLiveScrollSnapshot: (() -> NativeChatScrollPosition?)? = nil
    private var awaitingWebToggleRestore: Bool = false

    public func markAwaitingWebToggleRestore() {
        awaitingWebToggleRestore = true
    }

    /// What this store takes from the page's forwarder, passed whenever forwarding
    /// is turned on. A page only sends a `patch` to an app that says so here: an
    /// older app logs one as malformed and drops it.
    nonisolated public static let forwardingFeaturesJSON = "{ patch: true }"

    /// Imperative scroll commands from `AgentBridge` or in-chat interactions.
    public let scrollCommands = PassthroughSubject<NativeChatScrollCommand, Never>()

    /// id → index into `messages`, so add/update are O(1) instead of O(n).
    private var indexById: [String: Int] = []
        .reduce(into: [String: Int]()) { _, _ in }

    /// Native row id (`NativeChatRow.id`) → web row id (`header_…`, `thinking_…`, `gap_…`, or message id),
    /// rebuilt whenever `rows` changes so `resolveWebRowId(forNativeRowId:)` is O(1).
    private var webRowIdByNativeRowId: [String: String] = [:]

    public init() {}

    private static func buildWebRowIdMap(for rows: [NativeChatRow]) -> [String: String] {
        var toolGroupRawIds = Set<String>()
        for row in rows {
            if case .toolGroup(let group) = row {
                toolGroupRawIds.insert(group.id)
            }
        }
        var map: [String: String] = [:]
        map.reserveCapacity(rows.count * 2)
        for row in rows {
            switch row {
            case .toolGroup(let group):
                map[row.id] = "header_\(group.id)"
            case .thinking(let msg):
                let webId = toolGroupRawIds.contains(msg.id) ? "header_\(msg.id)" : "thinking_\(msg.id)"
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
        scrollPosition: [String: Any]? = nil
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
        if chatChanged && scrollPosition == nil {
            pendingScrollRestoration = nil
        }
        var parsedScroll: NativeChatScrollPosition? = nil
        if let scrollPosition, let cid = resolvedChatId, !cid.isEmpty {
            let following = (scrollPosition["following"] as? Bool) ?? true
            let rawRowId = scrollPosition["rowId"] as? String
            let rowId = (rawRowId?.isEmpty == false) ? rawRowId : nil
            let offset = (scrollPosition["offset"] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
            let pos = NativeChatScrollPosition(chatId: cid, webRowId: rowId, offset: offset, following: following)
            lastScrollSnapshot = pos
            if chatChanged || wasEmpty || isToggleRestore {
                pendingScrollRestoration = pos
                parsedScroll = pos
            }
        } else if wasEmpty, let pending = pendingScrollRestoration, pending.chatId == resolvedChatId {
            parsedScroll = pending
        }

        guard sorted != messages || newTruncatedCount != truncatedCount || chatChanged else {
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
        if let chatId { currentChatId = chatId }
        rows = Self.buildRows(from: sorted, previousRows: chatChanged ? [] : rows)
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
        if messages.isEmpty || currentChatId == nil {
            applyBackfill(entries, truncatedCount: newTruncatedCount, chatId: chatId)
            return
        }
        if let chatId, chatId != currentChatId { return }
        let incoming = entries.compactMap(Self.parseMessage)
        var next = messages
        var changed = false
        if !removedIds.isEmpty {
            let removed = Set(removedIds)
            let before = next.count
            next.removeAll { removed.contains($0.id) }
            changed = next.count != before
        }
        var position: [String: Int] = [:]
        for (idx, msg) in next.enumerated() { position[msg.id] = idx }
        for msg in incoming {
            if let idx = position[msg.id] {
                var merged = msg
                merged.thinking = msg.thinking ?? next[idx].thinking
                if msg.thinking == nil { merged.isThinkingStreaming = next[idx].isThinkingStreaming }
                if msg.content.isEmpty { merged.content = next[idx].content }
                if merged != next[idx] {
                    next[idx] = merged
                    changed = true
                }
            } else {
                position[msg.id] = next.count
                next.append(msg)
                changed = true
            }
        }
        let countChanged = newTruncatedCount != truncatedCount
        guard changed || countChanged else { return }
        // Chronological, ties in the order held (a new row after its equals), as a backfill sorts.
        next = next.enumerated().sorted { lhs, rhs in
            if lhs.element.timestamp != rhs.element.timestamp {
                return lhs.element.timestamp < rhs.element.timestamp
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
        indexById = [:]
        for (idx, msg) in next.enumerated() { indexById[msg.id] = idx }
        truncatedCount = newTruncatedCount
        rows = Self.buildRows(from: next, previousRows: rows)
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
            var updated = messages[idx]
            if let content { updated.thinking = content }
            updated.isThinkingStreaming = streaming
            if updated != messages[idx] {
                var next = messages
                next[idx] = updated
                rows = Self.buildRows(from: next, previousRows: rows)
                messages = next
            }
        } else {
            // Update before add — materialise a placeholder so streaming is visible.
            let placeholder = NativeChatMessage(
                id: id,
                chatId: msg["chatId"] as? String,
                role: .assistant,
                content: "",
                thinking: content,
                isThinkingStreaming: streaming,
                timestamp: (msg["timestamp"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970 * 1000
            )
            upsert(placeholder)
        }
    }

    /// Optimistically mark an `askUser` question as answered from `NativeChatView`.
    public func markQuestionAnswered(messageId: String, answer: String, selectedValues: [String] = []) {
        guard let idx = indexById[messageId], var ask = messages[idx].askUser else { return }
        ask.completed = true
        ask.answer = answer
        if !selectedValues.isEmpty {
            ask.selectedValues = selectedValues
        } else {
            ask.selectedValues = [answer]
        }
        var updated = messages[idx]
        updated.askUser = ask
        updated.status = "complete"
        if updated != messages[idx] {
            var next = messages
            next[idx] = updated
            rows = Self.buildRows(from: next, previousRows: rows)
            messages = next
        }
    }

    public func clear() {
        guard !messages.isEmpty || truncatedCount != 0 else { return }
        rows = []
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
            var merged = msg
            merged.thinking = msg.thinking ?? messages[idx].thinking
            if msg.thinking == nil { merged.isThinkingStreaming = messages[idx].isThinkingStreaming }
            if msg.content.isEmpty { merged.content = messages[idx].content }
            if merged != messages[idx] {
                var next = messages
                next[idx] = merged
                rows = Self.buildRows(from: next, previousRows: rows)
                messages = next
            }
        } else {
            var next = messages
            if msg.timestamp > 0, let insertIdx = next.firstIndex(where: { $0.timestamp > msg.timestamp }) {
                next.insert(msg, at: insertIdx)
                indexById = [:]
                for (i, item) in next.enumerated() {
                    indexById[item.id] = i
                }
            } else {
                indexById[msg.id] = next.count
                next.append(msg)
            }
            rows = Self.buildRows(from: next, previousRows: rows)
            messages = next
        }
    }

    // MARK: - Row Builder (Conversations Gaps + Tool Strip Grouping)

    static func buildRows(from messages: [NativeChatMessage], previousRows: [NativeChatRow] = []) -> [NativeChatRow] {
        var result: [NativeChatRow] = []
        var pendingTools: [NativeChatMessage] = []
        var previousTimestamp: Double? = nil
        var existingGroupIdByCallId: [String: String] = [:]
        var usedGroupIds: Set<String> = []
        for row in previousRows {
            if case .toolGroup(let group) = row {
                for callId in group.allCallIds {
                    existingGroupIdByCallId[callId] = group.id
                }
            }
        }

        func flushTools() {
            guard !pendingTools.isEmpty else { return }
            if let group = buildToolGroup(
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
            } else if msg.content.isEmpty && msg.askUser == nil && msg.table == nil && msg.tabs.isEmpty && msg.imageAttachments.isEmpty {
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
        return result
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
                if let detail = tc.detail {
                    calls.append(detail)
                } else {
                    calls.append(Self.FallbackToolDetail(for: msg))
                }
                if let run = tc.taskRun, let kind = tc.taskRunKind {
                    taskRuns.append(NativeChatTaskRunItem(id: run.id, kind: kind, snapshot: run))
                } else if let comms = tc.agentComms {
                    agentComms.append(
                        NativeChatAgentCommsItem(
                            id: msg.id,
                            timestamp: msg.timestamp,
                            presentation: comms,
                            detail: tc.detail ?? Self.FallbackToolDetail(for: msg)
                        )
                    )
                } else {
                    stripCandidates.append(
                        RawCallItem(
                            id: tc.id,
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

        let stableGroupId = allCallIds
            .compactMap { existingGroupIdByCallId[$0] }
            .first(where: { !usedGroupIds.contains($0) })
            ?? (usedGroupIds.contains(first.id) ? (allCallIds.first(where: { !usedGroupIds.contains($0) }) ?? first.id) : first.id)
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

        let formatter = DateFormatter()
        let sameYear = calendar.component(.year, from: prevDate) == calendar.component(.year, from: currDate)
        formatter.dateFormat = sameYear ? "EEE, d MMM · HH:mm" : "EEE, d MMM yyyy · HH:mm"
        return formatter.string(from: currDate)
    }

    // MARK: - Wire Parsing

    private static func parseMessage(_ msg: [String: Any]) -> NativeChatMessage? {
        guard let id = msg["messageId"] as? String, !id.isEmpty else { return nil }
        let role = NativeChatMessage.Role(rawValue: msg["role"] as? String ?? "") ?? .assistant
        var incoming = NativeChatMessage(
            id: id,
            chatId: msg["chatId"] as? String,
            role: role,
            content: msg["content"] as? String ?? "",
            status: msg["status"] as? String,
            method: msg["method"] as? String,
            label: msg["label"] as? String,
            summary: msg["summary"] as? String,
            askUser: Self.parseAskUser(msg["askUser"]),
            taskNotification: Self.parseTaskNotification(msg["taskNotification"]),
            senderLabel: msg["senderLabel"] as? String,
            thinking: (msg["thinking"] as? [String: Any])?["content"] as? String,
            isThinkingStreaming: (msg["thinking"] as? [String: Any])?["isStreaming"] as? Bool ?? false,
            timestamp: (msg["timestamp"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970 * 1000
        )

        incoming.hiddenInChat = msg["hiddenInChat"] as? Bool ?? false
        incoming.mergedIntoQuestionId = msg["mergedIntoQuestionId"] as? String
        incoming.replyQuote = Self.parseReplyQuote(msg["replyQuote"])
        incoming.contextTags = Self.parseContextTags(msg["contextTags"])
        incoming.imageAttachments = Self.parseImageAttachments(msg["imageAttachments"])
        incoming.fileAttachments = Self.parseFileAttachments(msg["fileAttachments"])
        incoming.isVoice = msg["isVoice"] as? Bool ?? false
        incoming.isGroupChat = msg["isGroupChat"] as? Bool ?? false
        if let own = msg["isOwnMessage"] as? Bool {
            incoming.isOwnMessage = own
        }
        incoming.avatarUrl = msg["avatarUrl"] as? String
        incoming.senderUserId = msg["senderUserId"] as? String
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
        return NativeAskUser(
            question: question,
            options: options,
            multiSelect: dict["multiSelect"] as? Bool ?? false,
            severity: dict["severity"] as? String,
            expectsResponse: dict["expectsResponse"] as? Bool ?? (!options.isEmpty || dateInput != nil),
            enableChatInput: dict["enableChatInput"] as? Bool ?? false,
            completed: dict["completed"] as? Bool ?? (answerString != nil),
            answer: answerString,
            selectedValues: selectedValues,
            responseKey: dict["responseKey"] as? String,
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
                "id": taskId,
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
