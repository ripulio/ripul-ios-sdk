import Foundation
import Combine

/// Structured task-notification card — mirrors the web's TaskNotificationCard.
public struct NativeTaskNotification: Equatable {
    public let taskId: String?
    public let status: String?
    public let summary: String?
}

/// One chat message as rendered by the native scroller.
///
/// This is the native twin of the web app's message model. PR 1/2 carry a
/// best-effort projection over the bridge (see `nativeChatMessageForwarder.ts`):
/// user text is real; assistant `content` is still a stub until the web side
/// runs `MessagePipeline` headlessly. `thinking` accumulates streaming deltas.
/// A faithfully-mirrored askUser prompt: question + selectable options.
/// Mirrors the web AskUserChoiceRenderer (left accent border, option rows, value chips).
public struct NativeAskUser: Equatable {
    public struct Option: Equatable {
        public let label: String
        public let value: String
        public let description: String?
    }
    public let question: String
    public let options: [Option]
    public let multiSelect: Bool
    public let severity: String?
}

public struct NativeChatMessage: Identifiable, Equatable {
    public enum Role: String {
        case user
        case assistant
    }

    /// Stable across the initial `add` and every subsequent `update`
    /// (the web action's correlationId).
    public let id: String
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

    public init(
        id: String,
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
}

/// Leaf `ObservableObject` backing the native chat scroller.
///
/// Kept OFF `AgentBridge` on purpose: messages/streaming deltas write many times
/// per turn, and `@Published` fields on the 60+-field `AgentBridge` re-render the
/// WKWebView host on every write. Isolating them here means only the native
/// scroller observing `bridge.nativeChat` reacts — the host stays untouched.
/// (Same reasoning as `SessionListStore` / `ChatStatusStore`.)
@MainActor
public final class NativeChatMessageStore: ObservableObject {
    @Published public private(set) var messages: [NativeChatMessage] = []

    /// id → index into `messages`, so add/update are O(1) instead of O(n).
    private var indexById: [String: Int] = [:]

    public init() {}

    /// Handle an `add` wire message (`message` dict from the bridge).
    public func applyAdd(_ msg: [String: Any]) {
        guard let id = msg["messageId"] as? String, !id.isEmpty else { return }
        let role = NativeChatMessage.Role(rawValue: msg["role"] as? String ?? "") ?? .assistant
        let incoming = NativeChatMessage(
            id: id,
            role: role,
            content: msg["content"] as? String ?? "",
            status: msg["status"] as? String,
            method: msg["method"] as? String,
            label: msg["label"] as? String,
            summary: msg["summary"] as? String,
            askUser: Self.parseAskUser(msg["askUser"]),
            taskNotification: Self.parseTaskNotification(msg["taskNotification"]),
            senderLabel: msg["senderLabel"] as? String,
            timestamp: (msg["timestamp"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970 * 1000
        )
        upsert(incoming)
    }

    /// Handle an `update` wire message — currently streaming `thinking` deltas.
    public func applyUpdate(_ msg: [String: Any]) {
        guard let id = msg["messageId"] as? String, !id.isEmpty else { return }
        let thinking = msg["thinking"] as? [String: Any]
        let content = thinking?["content"] as? String
        let streaming = thinking?["isStreaming"] as? Bool ?? false

        if let idx = indexById[id] {
            if let content { messages[idx].thinking = content }
            messages[idx].isThinkingStreaming = streaming
        } else {
            // Update before add — materialise a placeholder so streaming is visible.
            let placeholder = NativeChatMessage(
                id: id,
                role: .assistant,
                content: "",
                thinking: content,
                isThinkingStreaming: streaming,
                timestamp: (msg["timestamp"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970 * 1000
            )
            upsert(placeholder)
        }
    }

    public func clear() {
        messages.removeAll()
        indexById.removeAll()
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
                description: $0["description"] as? String
            )
        }
        return NativeAskUser(
            question: question,
            options: options,
            multiSelect: dict["multiSelect"] as? Bool ?? false,
            severity: dict["severity"] as? String
        )
    }

    private func upsert(_ msg: NativeChatMessage) {
        if let idx = indexById[msg.id] {
            // Merge — never clobber accumulated streaming state with an empty add.
            var merged = msg
            merged.thinking = msg.thinking ?? messages[idx].thinking
            if msg.content.isEmpty { merged.content = messages[idx].content }
            messages[idx] = merged
        } else {
            indexById[msg.id] = messages.count
            messages.append(msg)
        }
    }
}
