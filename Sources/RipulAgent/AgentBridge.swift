import Combine
import Foundation
import Network
import WebKit
#if canImport(UIKit)
import UIKit
#endif

private let protocolVersion = "1.0.0"
private let messagePrefix = "agent-framework:"

/// Metadata about a search result the user clicked in the universal search.
public struct SearchClickContext {
    /// The type of result (e.g. "page", "chat", "action", "tool").
    public let resultType: String
    /// A unique identifier for the clicked item, if available.
    public let resultId: String?
    /// The display title shown in the search result.
    public let title: String?
    /// A URL associated with the result, if any.
    public let url: String?
    /// Any additional payload the web app attached to the click event.
    public let metadata: [String: Any]
}

/// Implement this protocol to respond when the user clicks a result in the
/// universal search (ctrl-k). Return `true` if you handled the click natively;
/// return `false` to let the web app handle it.
@MainActor
public protocol SearchClickDelegate: AnyObject {
    func agentBridge(_ bridge: AgentBridge, didClickSearchResult context: SearchClickContext) -> Bool
}

/// Implement this protocol to handle link navigation requests from the web app.
/// Fired when a user clicks an interactWithUser option that carries a `link` URI.
@MainActor
public protocol LinkOpenDelegate: AnyObject {
    func agentBridge(_ bridge: AgentBridge, didRequestOpenLink url: URL)
}

/// A chat session descriptor received from the web app.
public struct ChatSession: Identifiable, Equatable, Codable {
    public let id: String
    public let sourceChatId: String
    public var displayName: String
    public let createdAt: Date
    /// Name of the remote machine this session is paired to, or nil for local sessions.
    public var remoteMachineName: String?
    /// CLI provider for this session (e.g. "claude-cli", "codex-cli"), or nil for non-CLI sessions.
    public var provider: String?
    /// Human-readable provider label (e.g. "Claude Code", "Codex"), or nil.
    public var providerLabel: String?
    /// The canonical host-side chat ID (e.g. "cli_<UUID>") when this tab is paired to a
    /// remote machine. Used to dedup against JSONL-scanned sessions in the unified list.
    public var hostChatId: String?
    /// Serialised byte size of this chat's action stream. Only populated for the
    /// active session — the web app only reports size for the session the user
    /// is currently looking at, since computing this serialises the full action
    /// array. `nil` means "not measured" (either inactive or pre-first-measurement).
    public var sizeBytes: Int?
    /// Where the `displayName` came from on the web side: "cli" (from CLI history
    /// or a user rename written through to JSONL), "user" (explicit rename via
    /// ThreadStorageManager), or "auto" (descriptor in-memory name or date
    /// fallback). The CLI rename detector ignores changes whose source is "auto"
    /// to prevent date-fallback strings from leaking into Claude's JSONL as a
    /// `custom-title`. Older host versions don't send this field; nil is treated
    /// as "user" for backwards compatibility (preserves prior rename behaviour).
    public var displayNameSource: String?
    /// Rename-event timestamp (epoch ms) for displayName when its source is a
    /// user rename ("cli"). Carried unchanged into `onCliSessionRenamed` so the
    /// CLI server's stale-stamp guard can reject late echoes — a wire value
    /// observed here must never be re-stamped as a fresh rename. nil =
    /// unversioned; unversioned writebacks can't overwrite a versioned title.
    public var displayNameRenamedAt: Double?

    public init(
        id: String,
        sourceChatId: String,
        displayName: String,
        createdAt: Date,
        remoteMachineName: String? = nil,
        provider: String? = nil,
        providerLabel: String? = nil,
        hostChatId: String? = nil,
        sizeBytes: Int? = nil,
        displayNameSource: String? = nil,
        displayNameRenamedAt: Double? = nil
    ) {
        self.id = id
        self.sourceChatId = sourceChatId
        self.displayName = displayName
        self.createdAt = createdAt
        self.remoteMachineName = remoteMachineName
        self.provider = provider
        self.providerLabel = providerLabel
        self.hostChatId = hostChatId
        self.sizeBytes = sizeBytes
        self.displayNameSource = displayNameSource
        self.displayNameRenamedAt = displayNameRenamedAt
    }

    // MARK: - Cache

    private static let cacheKey = "ripulCachedChatSessions"

    static func loadCached() -> [ChatSession] {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return [] }
        return (try? JSONDecoder().decode([ChatSession].self, from: data)) ?? []
    }

    static func saveToCache(_ sessions: [ChatSession]) {
        if let data = try? JSONEncoder().encode(sessions) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
    }
}

/// An option for a slash command sub-menu.
public struct SlashCommandOption: Identifiable {
    public let value: String
    public let label: String
    public let description: String?
    public var id: String { value }
}

/// A slash command descriptor received from the web app.
public struct SlashCommandInfo: Identifiable {
    public let command: String
    public let description: String
    public let icon: String?
    public let type: String   // "template" or "action"
    public let hasVariables: Bool
    public let options: [SlashCommandOption]
    public var id: String { command }
}

/// A model descriptor received from the web app's model catalog.
public struct ModelInfo: Identifiable, Equatable {
    public let id: String           // Catalog ID (e.g., "anthropic-claude-sonnet-4")
    public let name: String         // Display name (e.g., "Claude Sonnet 4")
    public let modelId: String      // API model ID (e.g., "claude-sonnet-4-20250514")
    public let provider: String     // Provider (e.g., "anthropic", "openai")
    public let group: String        // Display group (e.g., "Anthropic", "OpenAI")
    public let description: String? // Optional description
    public let supportsThinking: Bool

    // ── CLI-model-editor fields (populated for CLI models; defaulted otherwise) ──
    public let type: String?        // Client model type, e.g. "claude-cli" / "antigravity-cli"
    public let url: String          // Companion server URL (CLI); "" for Claude native bridge
    public let enabled: Bool
    public let sortOrder: Int?
    public let cliModelId: String?  // Alias passed to the CLI via --model (e.g. "fable")
    public let cliRawMode: Bool
    public let cliEffort: String?   // low | medium | high | xhigh | max
    public let cliMode: String?     // session | stateless

    /// True when this is a CLI model (Claude Code / Codex / Antigravity).
    public var isCli: Bool { (type ?? "").hasSuffix("-cli") }

    public init(
        id: String,
        name: String,
        modelId: String,
        provider: String,
        group: String,
        description: String?,
        supportsThinking: Bool,
        type: String? = nil,
        url: String = "",
        enabled: Bool = true,
        sortOrder: Int? = nil,
        cliModelId: String? = nil,
        cliRawMode: Bool = false,
        cliEffort: String? = nil,
        cliMode: String? = nil
    ) {
        self.id = id
        self.name = name
        self.modelId = modelId
        self.provider = provider
        self.group = group
        self.description = description
        self.supportsThinking = supportsThinking
        self.type = type
        self.url = url
        self.enabled = enabled
        self.sortOrder = sortOrder
        self.cliModelId = cliModelId
        self.cliRawMode = cliRawMode
        self.cliEffort = cliEffort
        self.cliMode = cliMode
    }
}

/// A session descriptor from a remote machine, returned by the remote discovery protocol.
public struct RemoteSessionInfo: Identifiable, Equatable {
    public let id: String
    public let sourceChatId: String
    public let displayName: String
    public let createdAt: Date
    /// Last time any message was written to the session file (in any app). Nil if Mac app is older.
    public let lastModified: Date?
    public let isRunning: Bool
    public let projectName: String?
    /// Absolute working directory (cwd) of the session — drives the folder-tree re-root.
    public let cwd: String?
    public let gitBranch: String?
    public let messageCount: Int?
    public let provider: String?
    public let providerLabel: String?
    /// Model of the most recent assistant message in the session JSONL
    /// (e.g. "claude-opus-4-6"), resolved by the host scanner. Session rows
    /// render this in place of the harness label.
    public let model: String?
    /// Host-side Ripul tab ID when this session is also open as a tab on the host.
    /// Used by clients to dedup remote rows against their local tabs via pairing `hostChatId`.
    public let hostChatId: String?
    /// The machine this session was discovered on. Stamped client-side after the
    /// per-machine fetch so routing (archive, delete, restore) lands on the owner.
    public let machineId: String?
}

/// A todo item owned by the signed-in user, surfaced to the native "Pick to do"
/// picker. Shape matches `TodoItem` in chrome-extension/src/api/services/todoItemsService.ts.
public struct RipulTodoItem: Identifiable, Equatable, Hashable {
    public let id: String
    /// Chat the item was created from. Nullable because older rows may lack one.
    public let chatId: String?
    public let chatName: String?
    public let text: String
    public let completed: Bool
}

/// Result of listing todo items, returned by `AgentBridge.listTodoItems()`.
/// `currentChatId` is the web app's active chat, used by the picker to put
/// "this chat" items on top.
public struct RipulTodoItemsResult {
    public let items: [RipulTodoItem]
    public let currentChatId: String?
}

/// A single grep hit across the remote host's tracked files.
public struct RipulGrepHit: Equatable, Hashable, Identifiable {
    public let path: String
    /// 1-based line number where the match occurred.
    public let line: Int
    /// The matching line content (trimmed by the host to a safe length).
    public let snippet: String

    public var id: String { "\(path):\(line)" }

    public init(path: String, line: Int, snippet: String) {
        self.path = path
        self.line = line
        self.snippet = snippet
    }
}

/// Find-in-file result: `current` is 1-based (0 when no matches).
public struct RipulFindResult: Equatable {
    public let total: Int
    public let current: Int

    public init(total: Int, current: Int) {
        self.total = total
        self.current = current
    }

    static func parse(_ raw: Any?) -> RipulFindResult {
        guard let dict = raw as? [String: Any] else {
            return RipulFindResult(total: 0, current: 0)
        }
        let total = (dict["total"] as? Int) ?? Int((dict["total"] as? Double) ?? 0)
        let current = (dict["current"] as? Int) ?? Int((dict["current"] as? Double) ?? 0)
        return RipulFindResult(total: total, current: current)
    }
}

/// Aggregated usage stats from CLI session JSONL files.
public struct CliUsageStats {
    public let totalSessions: Int
    public let totalTurns: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheCreationTokens: Int
    public let cacheReadTokens: Int
    /// Model name → turn count
    public let models: [String: Int]
    /// Date string (YYYY-MM-DD) → daily stats
    public let daily: [String: DailyStats]

    public struct DailyStats {
        public let turns: Int
        public let inputTokens: Int
        public let outputTokens: Int
    }

    static let empty = CliUsageStats(totalSessions: 0, totalTurns: 0, inputTokens: 0, outputTokens: 0,
                                     cacheCreationTokens: 0, cacheReadTokens: 0, models: [:], daily: [:])

    static func from(dict: [String: Any]) -> CliUsageStats {
        let models = dict["models"] as? [String: Int] ?? [:]
        var daily: [String: DailyStats] = [:]
        if let rawDaily = dict["daily"] as? [String: [String: Int]] {
            for (date, stats) in rawDaily {
                daily[date] = DailyStats(
                    turns: stats["turns"] ?? 0,
                    inputTokens: stats["inputTokens"] ?? 0,
                    outputTokens: stats["outputTokens"] ?? 0
                )
            }
        }
        return CliUsageStats(
            totalSessions: dict["totalSessions"] as? Int ?? 0,
            totalTurns: dict["totalTurns"] as? Int ?? 0,
            inputTokens: dict["inputTokens"] as? Int ?? 0,
            outputTokens: dict["outputTokens"] as? Int ?? 0,
            cacheCreationTokens: dict["cacheCreationTokens"] as? Int ?? 0,
            cacheReadTokens: dict["cacheReadTokens"] as? Int ?? 0,
            models: models,
            daily: daily
        )
    }
}

/// Rate limit quota data from the Anthropic OAuth usage endpoint.
public struct CliRateLimits {
    /// Percentage of 5-hour session window used (0–100)
    public let fiveHourPercent: Double?
    /// Percentage of 7-day weekly window used (0–100)
    public let sevenDayPercent: Double?
    /// Rate limit tier string (e.g. "default_claude_max_20x")
    public let rateLimitTier: String?
    /// Subscription type (e.g. "max", "pro")
    public let subscriptionType: String?

    static let empty = CliRateLimits(fiveHourPercent: nil, sevenDayPercent: nil, rateLimitTier: nil, subscriptionType: nil)

    static func from(dict: [String: Any]) -> CliRateLimits {
        return CliRateLimits(
            fiveHourPercent: dict["fiveHourPercent"] as? Double,
            sevenDayPercent: dict["sevenDayPercent"] as? Double,
            rateLimitTier: dict["rateLimitTier"] as? String,
            subscriptionType: dict["subscriptionType"] as? String
        )
    }
}

/// Claude Code CLI account information from ~/.claude.json on a machine.
public struct CliAccountInfo: Identifiable {
    public let emailAddress: String?
    public let displayName: String?
    public let organizationName: String?
    public let billingType: String?
    public let hasExtraUsageEnabled: Bool
    public let hasAvailableSubscription: Bool
    public let hostname: String
    public let error: String?
    public let usage: CliUsageStats
    public let rateLimits: CliRateLimits

    public var id: String { hostname + (emailAddress ?? "unknown") }

    static func from(dict: [String: Any]) -> CliAccountInfo {
        let account = dict["account"] as? [String: Any]
        let usageDict = dict["usage"] as? [String: Any]
        let rateLimitsDict = dict["rateLimits"] as? [String: Any]
        return CliAccountInfo(
            emailAddress: account?["emailAddress"] as? String,
            displayName: account?["displayName"] as? String,
            organizationName: account?["organizationName"] as? String,
            billingType: account?["billingType"] as? String,
            hasExtraUsageEnabled: account?["hasExtraUsageEnabled"] as? Bool ?? false,
            hasAvailableSubscription: dict["hasAvailableSubscription"] as? Bool ?? false,
            hostname: dict["hostname"] as? String ?? "Unknown",
            error: dict["error"] as? String,
            usage: usageDict.map { CliUsageStats.from(dict: $0) } ?? .empty,
            rateLimits: rateLimitsDict.map { CliRateLimits.from(dict: $0) } ?? .empty
        )
    }
}

public struct ConsoleLogEntry: Identifiable, Codable {
    public let id: UUID
    public let timestamp: Date
    public let level: String   // "LOG", "WARN", "ERROR"
    public let message: String
    public let stack: String?

    public init(timestamp: Date, level: String, message: String, stack: String? = nil) {
        self.id = UUID()
        self.timestamp = timestamp
        self.level = level
        self.message = message
        self.stack = stack
    }
}

public struct NetworkLogEntry: Identifiable {
    public let id = UUID()
    public let timestamp: Date
    public let method: String
    public let url: String
    public let status: Int            // 0 = pending or network error
    public let statusText: String     // e.g. "OK", "Not Found"
    public let durationMs: Int        // -1 = still pending
    public let requestSize: Int       // bytes, -1 = unknown
    public let responseSize: Int      // bytes, -1 = unknown
    public let requestHeaders: [String: String]
    public let responseHeaders: [String: String]
    public let error: String?         // non-nil for network failures
}

/// A recorded web content process termination event, persisted to UserDefaults.
public struct WebViewCrashEvent: Codable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let appMemoryMB: Double
    public let availableMemoryMB: Double
    public let thermalState: String
    public let url: String?
    public let wasConnected: Bool
    public let crashNumber: Int
}

/// Snapshot of web view health from a native-side probe.
public struct WebViewHealthReport: Codable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let trigger: String // "manual", "post-crash", "auto"
    // Native-side (always available)
    public let webViewExists: Bool
    public let currentURL: String?
    public let pageTitle: String?
    public let isLoading: Bool
    public let estimatedProgress: Double
    public let bridgeConnected: Bool
    public let loadError: String?
    public let appMemoryMB: Double
    public let availableMemoryMB: Double
    public let thermalState: String
    public let crashCount: Int
    // JS-side (nil if JS context is dead)
    public let jsContextAlive: Bool
    public let domNodeCount: Int?
    public let documentReadyState: String?
    public let activeSessionId: String?
    public let sessionsInMemory: Int?
    public let sessionsTotal: Int?
    public let sessionMemoryBytes: Int?
    public let cacheKeys: Int?
}

/// A diagnostic status message from the CLI pipeline, displayed in the native status bar.
public struct ChatStatusEntry: Identifiable {
    public let id = UUID()
    public let timestamp: Date
    public let chatId: String
    public let message: String

    public init(timestamp: Date, chatId: String, message: String) {
        self.timestamp = timestamp
        self.chatId = chatId
        self.message = message
    }
}

/// Well-known behaviors the native side knows how to fulfil.
/// New tool actions pick one of these — no native code changes needed.
public enum SessionActionBehavior: String, Equatable {
    /// Present `data["title"]` + `data["content"]` in a scrollable sheet
    case showContent
    /// Navigate to the chat session
    case focusSession
    /// Send the action back to the web app via the bridge (escape hatch)
    case postToWeb
}

/// An action button that a tool can surface on the native session row.
public struct SessionRowAction: Equatable, Identifiable {
    public let id: String
    public let label: String
    public let icon: String?
    public let style: Style
    public let behavior: SessionActionBehavior
    /// Behavior-specific data (keys depend on behavior)
    public let data: [String: String]

    public enum Style: String, Equatable {
        case `default`
        case primary
        case destructive
    }

    public static func from(dict: [String: Any]) -> SessionRowAction? {
        guard let id = dict["id"] as? String,
              let label = dict["label"] as? String else { return nil }
        let icon = dict["icon"] as? String
        let styleStr = dict["style"] as? String ?? "default"
        let style = Style(rawValue: styleStr) ?? .default
        let behaviorStr = dict["behavior"] as? String ?? "postToWeb"
        let behavior = SessionActionBehavior(rawValue: behaviorStr) ?? .postToWeb
        var flatData: [String: String] = [:]
        if let raw = dict["data"] as? [String: Any] {
            for (k, v) in raw { flatData[k] = "\(v)" }
        }
        return SessionRowAction(id: id, label: label, icon: icon, style: style, behavior: behavior, data: flatData)
    }
}

/// Structured agent activity event for native consumers (Dynamic Island, widgets, etc.).
public enum AgentActivityEvent: Equatable {
    case thinking
    case toolStart(toolName: String, toolId: String, toolLabel: String?, toolDetail: String?)
    case toolEnd(toolName: String, toolId: String, status: String, toolLabel: String?, toolDetail: String?)
    case sessionAction(actions: [SessionRowAction])
    case response(preview: String)
    case error(message: String)
    case complete

    /// The human-readable display name for tool events. Prefers toolLabel, falls back to toolName.
    public var displayName: String? {
        switch self {
        case .toolStart(let toolName, _, let toolLabel, _):
            return toolLabel ?? toolName
        case .toolEnd(let toolName, _, _, let toolLabel, _):
            return toolLabel ?? toolName
        default:
            return nil
        }
    }

    /// The raw underlying tool name (without any friendly-label remapping). Used to look up
    /// SF Symbol icons — the icon map is keyed by tool name, not display label.
    public var toolNameForIcon: String? {
        switch self {
        case .toolStart(let toolName, _, _, _):
            return toolName
        case .toolEnd(let toolName, _, _, _, _):
            return toolName
        default:
            return nil
        }
    }

    /// The "second lozenge" detail string for tool events — e.g. the filename for Read/Write/Edit,
    /// the pattern for Grep/Glob, the description for Bash. Mirrors the web chat log's header lozenge.
    public var detail: String? {
        switch self {
        case .toolStart(_, _, _, let toolDetail):
            return toolDetail
        case .toolEnd(_, _, _, _, let toolDetail):
            return toolDetail
        default:
            return nil
        }
    }

    /// `true` while a tool call is in-flight (`.toolStart` latched, `.toolEnd` not yet seen).
    /// Subtitles use this to drive a brighter/glowing presentation during active work and
    /// dim back to secondary once the tool finishes.
    public var isActive: Bool {
        if case .toolStart = self { return true }
        return false
    }

    /// Parse from a JSON dictionary received from the web app.
    public static func from(dict: [String: Any]) -> AgentActivityEvent? {
        guard let kind = dict["kind"] as? String else { return nil }
        switch kind {
        case "thinking":
            return .thinking
        case "toolStart":
            let toolName = dict["toolName"] as? String ?? ""
            let toolId = dict["toolId"] as? String ?? ""
            let toolLabel = dict["toolLabel"] as? String
            let toolDetail = dict["toolDetail"] as? String
            return .toolStart(toolName: toolName, toolId: toolId, toolLabel: toolLabel, toolDetail: toolDetail)
        case "toolEnd":
            let toolName = dict["toolName"] as? String ?? ""
            let toolId = dict["toolId"] as? String ?? ""
            let status = dict["status"] as? String ?? "success"
            let toolLabel = dict["toolLabel"] as? String
            let toolDetail = dict["toolDetail"] as? String
            return .toolEnd(toolName: toolName, toolId: toolId, status: status, toolLabel: toolLabel, toolDetail: toolDetail)
        case "response":
            let preview = dict["preview"] as? String ?? ""
            return .response(preview: preview)
        case "error":
            let message = dict["message"] as? String ?? ""
            return .error(message: message)
        case "sessionAction":
            let rawActions = dict["actions"] as? [[String: Any]] ?? []
            let actions = rawActions.compactMap { SessionRowAction.from(dict: $0) }
            guard !actions.isEmpty else { return nil }
            return .sessionAction(actions: actions)
        case "complete":
            return .complete
        default:
            return nil
        }
    }
}

/// Masthead configuration received from the web app's ViewContext features.
public struct MastheadConfig: Equatable {
    public var text: String?
    public var imageUrl: String?
    public var backgroundColor: String?  // CSS color string (e.g. "#FF6600")
    public var textColor: String?        // CSS color string
    public var height: CGFloat?          // Default: 48
    public var imageWidth: String?       // CSS value (e.g. "120px", "50%")
    public var fontSize: CGFloat?        // Default: 17 (body size)
    public var topOffset: CGFloat?       // Extra top offset in points
    public var glassStyle: String?       // "regular", "clear", or "identity" (iOS 26+ only)
}

/// A multichoice question from the web app, presented natively as a sheet.
public struct UserInteractionQuestion: Identifiable {
    public let id: String  // responseKey
    public let question: String
    public let options: [Option]
    public let multiSelect: Bool
    /// Structured table rows from the tool (array of dictionaries, keys are column headers).
    public let table: [[String: String]]?

    public struct Option {
        public let label: String
        public let value: Any
        public let description: String?
        public let link: String?
    }
}

/// A free-text input question from the web app, presented natively as a sheet.
public struct UserTextQuestion: Identifiable {
    public let id: String  // responseKey
    public let question: String
}

/// A file view request from the web app, presented natively as a sheet.
public struct FileViewRequest: Identifiable {
    public let id: String
    public let filePath: String
    public let content: String?
    public let language: String?
}

/// A date picker question from the web app, presented natively as a sheet.
/// When `includeTime` is true, the picker shows both date and time components
/// and the response is formatted as "YYYY-MM-DDTHH:mm".
public struct UserDateQuestion: Identifiable {
    public let id: String  // responseKey
    public let question: String
    public let includeTime: Bool
    public let minDate: Date?
    public let maxDate: Date?
    public let defaultDate: Date?
}

public enum AgentTurnPhase: String {
    case idle = "idle"
    case running = "running"
    case awaitingInput = "awaiting_input"
    case completed = "completed"
    case failed = "failed"
}

/// A single TodoWrite item pushed from the web app.
/// Mirrors the shape used in the chrome-extension TodoWriteToolRenderer.
public struct TodoItem: Codable, Hashable {
    public let content: String
    /// "pending" | "in_progress" | "completed"
    public let status: String
    /// Present-continuous form for in-progress items (e.g. "Running tests").
    public let activeForm: String?

    public init(content: String, status: String, activeForm: String?) {
        self.content = content
        self.status = status
        self.activeForm = activeForm
    }
}

/// The authoritative TodoWrite state for a single chat, pushed by the web app.
/// The native side renders this as a pinned lozenge in the chat title bar
/// and (on iOS) in the Dynamic Island / Live Activity.
public struct TodoState: Codable, Hashable {
    /// Monotonic per-chat counter. Used to drop out-of-order updates and
    /// scope dismissal — a new version re-shows a previously dismissed state.
    public let version: Int
    public let todos: [TodoItem]
    public let updatedAt: Date
}

/// Describes the current web page context, sent by the web app on every SPA route change.
/// The native side uses this to show/hide chrome (header, chat input, context menus)
/// and adjust safe area treatment for different page types (login vs chat vs content).
public struct PageContext: Equatable {
    /// Identifier for the page type (e.g. "chat", "sign-in", "mobile", or a route name).
    public let page: String
    /// Whether the native header (glass top bar) should be shown.
    public let showNativeHeader: Bool
    /// Whether the native chat input should be shown.
    public let showNativeChatInput: Bool
    /// Whether session controls (context menu, todo lozenge) should be shown.
    public let showSessionControls: Bool
    /// Safe area mode: "full" = glass header + status bar; "minimal" = status bar only.
    public let safeAreaMode: String

    /// Default context before the web app sends its first page:context message.
    /// Defaults to chat mode (full chrome) since that's the most common state.
    public static let `default` = PageContext(
        page: "chat",
        showNativeHeader: true,
        showNativeChatInput: true,
        showSessionControls: true,
        safeAreaMode: "full"
    )

    /// Minimal context used during external navigations (OAuth redirects) where
    /// the web app can't send messages. Hides all native chrome.
    public static let externalNavigation = PageContext(
        page: "external",
        showNativeHeader: false,
        showNativeChatInput: false,
        showSessionControls: false,
        safeAreaMode: "minimal"
    )
}

// MARK: - Native logging that reaches the log tools

/// Drop-in replacements for `NSLog` that ALSO append to the `consoleLogs` buffer
/// `device_console_logs` / `host_console_logs` read — so native diagnostics are
/// readable by the tools, not just in Xcode/Console. Prefer these over a bare
/// `NSLog` for any native log worth surfacing. They tee to the OS log too, so a
/// message emitted before the bridge exists is still visible in Xcode.
public func nlog(_ message: String) {
    Foundation.NSLog("%@", message)   // Foundation.* bypasses the NSLog tee shadow (no double-append)
    Task { @MainActor in AgentBridge.current?.handleConsoleLog("LOG: [native] \(message)") }
}
public func nwarn(_ message: String) {
    Foundation.NSLog("%@", message)
    Task { @MainActor in AgentBridge.current?.handleConsoleLog("WARN: [native] \(message)") }
}
public func nerror(_ message: String) {
    Foundation.NSLog("%@", message)
    Task { @MainActor in AgentBridge.current?.handleConsoleLog("ERROR: [native] \(message)") }
}

@MainActor
public final class AgentBridge: NSObject, ObservableObject {
    @Published public var isConnected = false
    /// Per-thread native CPU sampler (this app process only, not WebKit).
    /// Off by default; a Settings toggle drives `start()`/`stop()`. Spikes are
    /// routed to the bridge console so they show up in `host_console_logs`.
    public let cpuSampler = CpuSampler()
    /// When true, native host UI (e.g. the session list) freezes to save resources
    /// while the host serves remotely. Written by HostRenderSuspensionController on
    /// macOS; mirrors the web "Suspend Host Session Rendering" flag.
    @Published public var hostRenderSuspended = false
    @Published public var isThemeReady = false
    /// Fires once when the web app's CachedStorage is initialized and
    /// `__ripulGetSessions` will return real data. Used by SessionManager
    /// to replace the 2-second polling loop with a push-triggered fetch.
    @Published public var isSessionsReady = false
    @Published public var wantsMinimize = false
    /// Set to true to request the Console Log viewer sheet. AgentView observes
    /// this and presents the sheet, then resets the flag.
    @Published public var wantsShowConsoleLogs = false
    /// Set to true to request the View Inspector overlay. AgentView observes
    /// this and presents the overlay, then resets the flag.
    @Published public var wantsShowViewInspector = false
    @Published public var sessions: [ChatSession] = ChatSession.loadCached()
    /// Tab IDs of ephemeral commit-viewer sessions that should be excluded
    /// from the sessions list. Managed by CommitsScreen (insert on open)
    /// and AgentScreen (remove on back-nav / close).
    /// Persisted to UserDefaults so app-kill during viewing doesn't leak tabs.
    public private(set) var ephemeralSessionIds: Set<String> = {
        let arr = UserDefaults.standard.stringArray(forKey: "ripulEphemeralSessionIds") ?? []
        return Set(arr)
    }()

    private static let ephemeralKey = "ripulEphemeralSessionIds"

    private func persistEphemeralIds() {
        UserDefaults.standard.set(Array(ephemeralSessionIds), forKey: Self.ephemeralKey)
    }

    public func markSessionEphemeral(_ id: String) {
        ephemeralSessionIds.insert(id)
        persistEphemeralIds()
    }

    public func unmarkSessionEphemeral(_ id: String) {
        ephemeralSessionIds.remove(id)
        persistEphemeralIds()
    }

    /// Working directory the NEXT new chat should be created in, mirrored from
    /// the session list's project filter (selected project's cwd; nil = "All
    /// Projects" => host default workspace). `createNewChat()` passes it to the
    /// web `__ripulCreateChat`, which seeds it so the new session's first turn
    /// starts the CLI in that folder instead of under the default workspace.
    /// Intentionally NOT @Published — it is written during a web interaction
    /// (filter change) and must not re-render the WKWebView host.
    public var pendingNewChatWorkingDirectory: String?

    /// When true, the native chat input is hidden even if the page context
    /// says to show it. Used by the commit viewer to enforce read-only mode.
    @Published public var suppressNativeChatInput: Bool = false

    /// Close any ephemeral tabs left over from a previous session (e.g. app
    /// was killed while viewing a commit). Call once after the web view is ready.
    public func cleanupStaleEphemeralSessions() async {
        let stale = ephemeralSessionIds
        guard !stale.isEmpty else { return }
        NSLog("[AgentBridge] Cleaning up %d stale ephemeral session(s)", stale.count)
        for id in stale {
            await closeSession(id: id)
        }
        ephemeralSessionIds.removeAll()
        persistEphemeralIds()
    }

    @Published public var activeSessionId: String? {
        didSet {
            guard activeSessionId != oldValue else { return }
            markActiveSessionTodoViewedInList()
            // The pause/play buttons are a projection of the ACTIVE chat's
            // phase — any change of active session must re-derive them.
            refreshActiveAgentFlags()
        }
    }

    /// The currently-active ChatSession, derived from `activeSessionId` and `sessions`.
    public var activeSession: ChatSession? {
        guard let activeSessionId else { return nil }
        return sessions.first(where: { $0.id == activeSessionId })
    }

    /// True when the active session is a Claude Code CLI session.
    /// Used to gate Plan/Edit-mode UI, which only applies to claude-cli.
    public var isActiveSessionClaudeCli: Bool {
        activeSession?.provider == "claude-cli"
    }
    @Published public var lastSessionsError: String?
    /// Kept for source compatibility — no longer used for transitions.
    @Published public var isSwitchingSession = false
    /// Set to the session id being navigated to; cleared to nil after the slide
    /// animation completes. SessionsListSections uses this to keep the row spinner
    /// running until the animation is done (not just until focusSession starts).
    /// Lives on navigationStore so writes don't fire bridge.objectWillChange.
    public var navigatingToSessionId: String? {
        get { navigationStore.navigatingToSessionId }
        set { navigationStore.navigatingToSessionId = newValue }
    }
    // Scroll-to-bottom button state lives in its OWN ObservableObject (NOT @Published
    // on the bridge) so that crossing the bottom threshold while scrolling does not
    // invalidate AgentView. AgentView hosts the WKWebView; re-rendering it on the
    // app main thread mid-scroll stalls the web view's scroll (proven by isolating
    // this exact post). Only the small button overlay observes scrollButton.
    public let scrollButton = ScrollButtonModel()
    /// Text to prefill in the native chat input (set by welcome card / prompt suggestion clicks).
    @Published public var pendingInputText: String?
    /// Text to append to the native chat input without replacing existing content.
    @Published public var pendingInputAppend: String?
    @Published public var availableModels: [ModelInfo] = []
    @Published public var selectedModelId: String?
    @Published public var selectedEffort: String?   // CLI reasoning effort override (nil = default)
    @Published public var modelSelectionEnabled: Bool = true
    @Published public var lastModelsError: String?
    /// The most recent structured agent activity event from the web app.
    /// Not @Published — fires at very high frequency during agent runs and is only
    /// consumed via Combine (LiveActivityManager). Avoiding objectWillChange prevents
    /// every view observing AgentBridge from re-rendering on each activity event.
    public var latestActivity: AgentActivityEvent? {
        didSet { latestActivitySubject.send(latestActivity) }
    }
    /// Dedicated publisher for latestActivity changes (replaces $latestActivity).
    public let latestActivitySubject = PassthroughSubject<AgentActivityEvent?, Never>()
    /// Session-list-only per-chat maps, isolated onto their own leaf
    /// ObservableObject so writes (many per second during a run) re-render the
    /// session list WITHOUT re-rendering the WKWebView host that observes
    /// `AgentBridge`. See SessionListStore for the full rationale. Access the
    /// maps as `sessionList.latestActivityByChatId`, etc.
    public let sessionList = SessionListStore()

    /// Native chat scroller store — messages forwarded from the web app over the
    /// bridge (see `handleNativeChatMessage`). Its OWN leaf ObservableObject so
    /// high-frequency message/streaming writes re-render only the native scroller,
    /// not the WKWebView host. Same rationale as `sessionList` / `chatStatus`.
    public let nativeChat = NativeChatMessageStore()

    /// Debug: render the chat natively (NativeChatView over the web view) instead of
    /// the web-rendered scroller. The existing ChatComposer + top bar are reused.
    /// Flipped rarely (a settings toggle), so plain @Published is fine.
    @Published public var nativeChatScrollerEnabled = false

    /// Navigation + model-display state on a leaf store so writes don't fire
    /// bridge.objectWillChange and re-render the WKWebView host or list containers.
    public let navigationStore = NavigationStore()

    /// True when the native chat input's text view is the first responder.
    /// Used to gate the keyboard-avoidance offset so that web inputs inside
    /// the WKWebView (e.g. metadata panel) don't shift the whole view up.
    @Published public var nativeChatInputFocused: Bool = false
    /// Per-chat lifecycle sequence, used to drop out-of-order phase events.
    /// Sequences are per-chat monotonic counters on the web side — they must
    /// never be compared across chats.
    private var sessionLifecycleSequences: [String: Int] = [:]
    /// Tracks whether we've logged the first stateSnapshot batch for startup diagnostics.
    private var hasLoggedFirstSnapshotBatch = false
    /// High-frequency publisher for todo state changes. Sends `(chatId, newState?)`
    /// where a nil state indicates a dismissal. Mirrors the latestActivitySubject
    /// pattern above — used by LiveActivityManager without forcing every
    /// observer of AgentBridge to re-render.
    public let todoStateSubject = PassthroughSubject<(String, TodoState?), Never>()
    /// Authoritative lifecycle phase for the active chat turn. Derived — see
    /// `refreshActiveAgentFlags()`, the only writer.
    @Published public var agentTurnPhase: AgentTurnPhase = .idle
    /// Whether the agent is currently running (processing) for the active session.
    /// Derived from `chatTurnPhases[activeSourceChatId]` — never set directly.
    @Published public var isAgentRunning = false
    /// Whether the agent is paused (awaiting user input) for the active session.
    /// Derived from `chatTurnPhases[activeSourceChatId]` — never set directly.
    @Published public var isAgentPaused = false
    /// Raw (uncollapsed) turn phase per chat, keyed by sourceChatId. This is the
    /// single source of truth for the chat-box pause/play buttons; the collapsed
    /// `sessionList.sessionPhases` variant (completed/failed → awaitingInput) is
    /// only for session-row hand icons. Entries are removed on `.idle`.
    private var chatTurnPhases: [String: AgentTurnPhase] = [:]
    /// sourceChatId of a just-created chat that isn't in `sessions` yet. Bridges
    /// the gap between `__ripulCreateChat` returning and the sessions push
    /// landing, so `activeSourceChatId` (and therefore the pause button) points
    /// at the new chat immediately instead of the previous one. Cleared once the
    /// active session resolves to the same sourceChatId.
    private var pendingActiveSourceChatId: String?
    /// How thinking is displayed in LLM panels: "none", "folded", or "open".
    /// Lives on navigationStore so writes don't fire bridge.objectWillChange.
    public var showThinkingMode: String {
        get { navigationStore.showThinkingMode }
        set { navigationStore.showThinkingMode = newValue }
    }
    /// Guard against stale agent:status pushes during web app initialization.
    /// Set to true after the first syncAgentStatus completes post-connection.
    private var initialStatusSyncComplete = false
    /// Polling task that periodically syncs agent status while the agent is running.
    /// Ensures the button clears even if push notifications are lost.
    private var statusPollingTask: Task<Void, Never>?
    /// Start polling agent status while the active chat is running. The pull
    /// result is applied per-chat by `syncAgentStatus`, so a poll can never
    /// poison another chat's state — it only corrects the chat it's about.
    private func startStatusPolling() {
        statusPollingTask?.cancel()
        statusPollingTask = Task { [weak self] in
            // Wait 5s before first poll
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            for _ in 0..<100 { // max ~5 min
                guard let self, !Task.isCancelled else { return }
                let (running, _) = await self.syncAgentStatus()
                if !running {
                    self.stopStatusPolling()
                    return
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private func stopStatusPolling() {
        statusPollingTask?.cancel()
        statusPollingTask = nil
    }

    private func resetLifecycleState() {
        pendingActiveSourceChatId = nil
        stopStatusPolling()
        chatTurnPhases = [:]
        sessionList.sessionPhases = [:]
        sessionLifecycleSequences = [:]
        refreshActiveAgentFlags()
    }

    /// Recompute the active-chat button state (`agentTurnPhase`, `isAgentRunning`,
    /// `isAgentPaused`) as a projection of `chatTurnPhases[activeSourceChatId]`.
    /// This is the ONLY writer of those flags — events from background chats can
    /// never leak into the active chat's UI, and switching sessions immediately
    /// shows the target chat's true state (no reset-then-resync gap).
    private func refreshActiveAgentFlags() {
        // Hand off the pending new-chat override once the sessions list has
        // caught up and resolves the active session to the same chat.
        if let pending = pendingActiveSourceChatId,
           let activeSessionId,
           sessions.first(where: { $0.id == activeSessionId })?.sourceChatId == pending {
            pendingActiveSourceChatId = nil
        }

        let phase: AgentTurnPhase
        if let chatId = activeSourceChatId, let current = chatTurnPhases[chatId] {
            phase = current
        } else {
            phase = .idle
        }
        let running: Bool
        let paused: Bool
        switch phase {
        case .running:       running = true;  paused = false
        case .awaitingInput: running = true;  paused = true
        case .idle, .completed, .failed: running = false; paused = false
        }
        if agentTurnPhase != phase { agentTurnPhase = phase }
        if isAgentRunning != running { isAgentRunning = running }
        if isAgentPaused != paused { isAgentPaused = paused }
        if phase == .running {
            if statusPollingTask == nil { startStatusPolling() }
        } else {
            stopStatusPolling()
        }
    }

    /// The `sourceChatId` of the currently-active session — the chat whose
    /// per-chat phase drives the pause/play buttons via
    /// `refreshActiveAgentFlags()`. A just-created chat that hasn't landed in
    /// `sessions` yet is covered by `pendingActiveSourceChatId`.
    private var activeSourceChatId: String? {
        if let pending = pendingActiveSourceChatId { return pending }
        guard let activeSessionId else { return nil }
        return sessions.first(where: { $0.id == activeSessionId })?.sourceChatId
    }

    /// Update the per-session phase map for a single chat. Drops out-of-order
    /// events via per-chat sequence tracking.
    ///
    /// Phase → indicator mapping:
    /// - `.running`                 — spinner (agent is actively working)
    /// - `.awaitingInput`           — "hand" (mid-turn pause: permission / ask_user)
    /// - `.completed` / `.failed`   — "hand" (turn finished, user's next prompt needed)
    /// - `.idle`                    — cleared (never ran anything)
    ///
    /// Treating `.completed` / `.failed` as "awaiting user" matches how people
    /// read the sessions list — a finished turn *is* waiting for you.
    private func applySessionPhase(
        _ phase: AgentTurnPhase,
        chatId: String?,
        sequence: Int?,
        timestamp: Any? = nil
    ) {
        guard let chatId, !chatId.isEmpty else { return }
        if let sequence, let last = sessionLifecycleSequences[chatId], sequence < last {
            return
        }
        if let sequence {
            sessionLifecycleSequences[chatId] = sequence
        }
        let phaseDate = Self.parseEpochMs(timestamp) ?? Date()
        switch phase {
        case .running, .awaitingInput, .completed, .failed:
            // Stored RAW — turnPhase(for:) collapses at read time so completed
            // can be filtered against the viewed stamp (unseen-completion hand).
            sessionList.sessionPhases[chatId] = phase
            sessionList.phaseTimestampByChatId[chatId] = phaseDate
        case .idle:
            sessionList.sessionPhases.removeValue(forKey: chatId)
            sessionList.phaseTimestampByChatId.removeValue(forKey: chatId)
        }
        // The raw phase map keeps completed/failed distinct — the chat box must
        // NOT show the paused/play state for a finished turn.
        if phase == .idle {
            chatTurnPhases.removeValue(forKey: chatId)
        } else {
            chatTurnPhases[chatId] = phase
        }
        // Drop any stale per-chat tool-call subtitle when the session
        // goes idle OR the turn completes/fails. We keep the label across
        // running ↔ awaitingInput transitions (CLI sessions frequently
        // sit on `.awaitingInput` mid-tool-run), but once a turn is truly
        // over we don't want the subtitle showing the last tool name
        // from the previous turn.
        if phase == .idle || phase == .completed || phase == .failed {
            sessionList.latestActivityByChatId.removeValue(forKey: chatId)
        }
        refreshActiveAgentFlags()
    }

    /// Route a lifecycle turn event into the per-chat phase maps. The active
    /// chat's buttons update as a side effect (`applySessionPhase` →
    /// `refreshActiveAgentFlags`); events for background chats only touch their
    /// own row indicators. Events without a `chatId` are dropped — attributing
    /// them to the active chat is exactly how another chat's state used to leak
    /// into a fresh session's pause button.
    private func handleLifecycleEvent(_ phase: AgentTurnPhase, dict: [String: Any], isSnapshot: Bool = false) {
        guard let chatId = dict["chatId"] as? String, !chatId.isEmpty else {
            Self.debugLog("[AgentBridge] Dropping lifecycle event without chatId (phase=\(phase.rawValue))")
            return
        }
        applySessionPhase(phase, chatId: chatId, sequence: dict["sequence"] as? Int, timestamp: dict["timestamp"])
        // Stamp last-active time for session list sort order — but NOT on
        // snapshots, which fire for every session on connect and would
        // reset all timestamps to "just now".
        if !isSnapshot {
            advanceLastActive(chatId: chatId, eventTimestamp: dict["timestamp"])
        }
    }

    /// Update `sessionList.lastActiveTimeByChatId` from an incoming event.
    ///
    /// When the event carries a real timestamp (epoch ms on the wire), we
    /// trust it as authoritative — the web app reads it from the action's
    /// own `timestamp` field, which reflects when the action was genuinely
    /// created.  We write it unconditionally so a previously-polluted cache
    /// entry (e.g. from a build that stamped Date.now() for every action)
    /// can be corrected downward.
    ///
    /// When no parseable timestamp is present we fall back to Date() but
    /// only *advance* — this prevents a missing-timestamp event from
    /// overwriting a known-good older value.
    /// Parse an epoch-milliseconds wire timestamp into a Date, or nil.
    private static func parseEpochMs(_ raw: Any?) -> Date? {
        if let ms = raw as? TimeInterval, ms > 0 { return Date(timeIntervalSince1970: ms / 1000) }
        if let ms = raw as? Int, ms > 0 { return Date(timeIntervalSince1970: TimeInterval(ms) / 1000) }
        return nil
    }

    private func advanceLastActive(chatId: String, eventTimestamp: Any?) {
        if let ms = eventTimestamp as? TimeInterval, ms > 0 {
            sessionList.lastActiveTimeByChatId[chatId] = Date(timeIntervalSince1970: ms / 1000)
        } else if let ms = eventTimestamp as? Int, ms > 0 {
            sessionList.lastActiveTimeByChatId[chatId] = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        } else {
            // No parseable timestamp — fall back to "now" but only advance.
            let now = Date()
            if let existing = sessionList.lastActiveTimeByChatId[chatId], existing >= now {
                return
            }
            sessionList.lastActiveTimeByChatId[chatId] = now
        }
    }

    private func handleLifecycleSnapshot(_ dict: [String: Any]) {
        guard let rawPhase = dict["phase"] as? String,
              let phase = AgentTurnPhase(rawValue: rawPhase) else {
            return
        }
        handleLifecycleEvent(phase, dict: dict, isSnapshot: true)

        if !hasLoggedFirstSnapshotBatch {
            hasLoggedFirstSnapshotBatch = true
        }
    }

    /// Set when the web view fails to load. Cleared on successful connection.
    @Published public var loadError: String?

    // MARK: - WebView Crash Tracking

    private static let crashEventsKey = "ripulWebViewCrashEvents"

    /// Process termination events recorded this session + persisted from prior sessions.
    @Published public var crashEvents: [WebViewCrashEvent] = {
        guard let data = UserDefaults.standard.data(forKey: crashEventsKey) else { return [] }
        return (try? JSONDecoder().decode([WebViewCrashEvent].self, from: data)) ?? []
    }()

    /// Number of process terminations in this app session (since launch).
    public private(set) var sessionCrashCount: Int = 0

    private func persistCrashEvents() {
        // Keep only last 20 events
        let trimmed = Array(crashEvents.suffix(20))
        if let data = try? JSONEncoder().encode(trimmed) {
            UserDefaults.standard.set(data, forKey: Self.crashEventsKey)
        }
    }

    private static let healthReportsKey = "ripulWebViewHealthReports"

    /// Persisted health probe reports (survives app restarts).
    @Published public var healthReports: [WebViewHealthReport] = {
        guard let data = UserDefaults.standard.data(forKey: healthReportsKey) else { return [] }
        return (try? JSONDecoder().decode([WebViewHealthReport].self, from: data)) ?? []
    }()

    private func persistHealthReports() {
        let trimmed = Array(healthReports.suffix(30))
        if let data = try? JSONEncoder().encode(trimmed) {
            UserDefaults.standard.set(data, forKey: Self.healthReportsKey)
        }
    }

    /// Set by recordProcessTermination — triggers an auto-probe once the bridge reconnects.
    private var pendingPostCrashProbe = false

    /// Masthead configuration from the web app (text, image, colors for native glass lozenge).
    @Published public var mastheadConfig: MastheadConfig?
    /// Glass style for the native chat input: "regular", "clear", or "identity".
    @Published public var chatInputGlassStyle: String?
    /// Layout mode for the native chat input: nil/"single" (default) or "twoRow" (buttons below text area).
    @Published public var chatInputLayout: String?
    /// Whether to show "New to do" and "Pick to do" in the native chat "+" menu. Default true.
    @Published public var chatInputShowTodos: Bool = true
    /// Whether to show "Quick Commands" in the native chat "+" menu. Default true.
    @Published public var chatInputShowQuickCommands: Bool = true
    /// A multichoice question awaiting native UI presentation.
    @Published public var pendingUserInteraction: UserInteractionQuestion?
    /// A free-text question awaiting native UI presentation.
    @Published public var pendingTextQuestion: UserTextQuestion?
    /// A date picker question awaiting native UI presentation.
    @Published public var pendingDateQuestion: UserDateQuestion?
    /// A file view request awaiting native sheet presentation.
    @Published public var pendingFileView: FileViewRequest?
    /// True while the web file viewer is open — native chat input should be hidden.
    @Published public var fileViewerExpanded: Bool = false
    /// Filename shown in the native title bar while the file viewer is open; nil when closed.
    @Published public var fileViewerTitle: String? = nil
    /// True when the file viewer is showing a markdown file (enables zoom/raw menu items).
    @Published public var fileViewerIsMarkdown: Bool = false
    /// Full file path of the file currently shown in the viewer; nil when closed.
    @Published public var fileViewerFilePath: String? = nil
    /// When true, closing the file viewer should navigate back to the sessions list.
    public var fileViewerReturnToSessions: Bool = false

    /// Current web page context — drives native chrome visibility.
    /// Updated by the web app via `page:context` messages and by the navigation
    /// delegate when the WKWebView leaves the app domain (OAuth redirects).
    @Published public var currentPageContext: PageContext = .default

    private weak var webView: WKWebView?
    private var registeredTools: [NativeTool] = []
    private var builtInTools: [NativeTool] = []
    private var llmProvider: LLMProvider?
    private var sessionsRetryCount = 0
    private static let maxSessionsRetries = 5
    private var hasAttemptedCacheReload = false
    private var connectionTimeoutTask: Task<Void, Never>?

    /// Set this delegate to handle search result clicks from the universal search.
    public weak var searchClickDelegate: SearchClickDelegate?

    /// Set this delegate to handle link navigation requests from interactWithUser options.
    public weak var linkOpenDelegate: LinkOpenDelegate?

    /// Additional capabilities to merge into the handshake response.
    /// These override auto-detected values (e.g., set `"dom": true`).
    public var extraCapabilities: [String: Any] = [:]

    /// Router for browser capability requests from the web app.
    /// Register capability handlers (e.g., TabsCapability, ScriptingCapability)
    /// to enable browser control from the native app.
    public let capabilityRouter = CapabilityRouter()

    /// Callback for custom message types not handled by the bridge.
    /// The message type (with `agent-framework:` prefix stripped) and full dict are passed.
    /// Return `true` if the message was handled, `false` to log it as unhandled.
    public var onUnhandledMessage: ((_ messageType: String, _ message: [String: Any]) -> Bool)?

    /// Called when a CLI-provider session is successfully renamed.
    /// Parameters are (sourceChatId, confirmedDisplayName).
    public var onCliSessionRenamed: ((_ sessionId: String, _ displayName: String, _ renamedAt: Double?) -> Void)?

    /// Called when the user toggles plan mode in the native chat input.
    /// The host app should use this to set plan mode on the CLI server directly.
    public var onPlanModeChanged: ((_ enabled: Bool) -> Void)?

    public override init() {
        super.init()
        AgentBridge.current = self
        startNetworkPathMonitoring()
        startProcessLifecycleMonitoring()
        // Route CPU spikes into the bridge console (visible in host_console_logs
        // / device_console_logs). onSpike is invoked on the main thread.
        cpuSampler.onSpike = { [weak self] line in self?.handleConsoleLog(line) }
    }

    /// Most-recently-initialized bridge, so static / off-instance native logging
    /// (e.g. `debugLog`, the free `nlog()` helper) can reach the `consoleLogs`
    /// buffer that `device_console_logs` / `host_console_logs` read. Weak so it
    /// never keeps a bridge alive.
    public static weak var current: AgentBridge?

    /// Verbose per-message bridge tracing. OFF by default. These NSLog calls sit
    /// on the streaming hot path — `agent:activity` "thinking" events arrive at
    /// ~30 Hz, so an unconditional NSLog here is ~30+ synchronous main-thread
    /// log writes per second during a run (a confirmed thermal source on iPhone).
    /// NSLog output is invisible on-device without Xcode attached anyway, so this
    /// is pure cost in production. Flip it on only when debugging with Xcode; the
    /// in-app `consoleLogs` buffer (read by device_console_logs) is unaffected.
    public static var verboseBridgeLog = false

    /// Render the WKWebView opaque instead of transparent (thermal A/B test). A
    /// transparent web view must blend every repaint against the layers behind it;
    /// during streaming the chat repaints changing text ~30x/sec, so an opaque view
    /// (a cheap copy, no per-repaint blend) should run cooler if that blend is the
    /// heat. Read at web-view creation, so a relaunch is required to apply.
    public static var opaqueWebView = false

    /// Debug log to file (macOS unified log redacts NSLog content as <private>).
    /// ALSO mirrors into the `consoleLogs` buffer so native diagnostics are
    /// readable by `device_console_logs` / `host_console_logs`, not just on disk.
    public static func debugLog(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "\(ts) \(message)\n"
        let path = "/tmp/ripul-debug.log"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
        }
        // Mirror into the unified buffer the log tools read (hop to the main actor;
        // debugLog may be called from any thread).
        Task { @MainActor in AgentBridge.current?.handleConsoleLog("LOG: [native] \(message)") }
    }

    // MARK: - Recently Edited Files

    // MARK: - Tool Registration

    /// Register native tools that the agent can discover and invoke.
    public func register(_ tools: [NativeTool]) {
        registeredTools.append(contentsOf: tools)
    }

    /// Register SDK built-in tools (e.g. console_logs, network_logs).
    /// These persist across `setTools()` calls — app-provided tools are
    /// replaced but built-in tools remain.
    public func registerBuiltInTools(_ tools: [NativeTool]) {
        builtInTools = tools
    }

    /// The tools currently registered with this bridge — the live tool set of
    /// *this* build, which is more than any server-side view of it knows.
    ///
    /// Read-only by design: registration stays with `register` / `setTools`.
    /// The tool-collections editor uses this to show which tools a membership
    /// pattern captures before the developer saves.
    ///
    /// Names are canonical (no `host_` prefix — that is added downstream by the
    /// web layer), which is also what collection patterns match against.
    public var registeredToolSummaries: [RipulRegisteredTool] {
        let builtInNames = Set(builtInTools.map(\.name))
        return allTools.map { tool in
            RipulRegisteredTool(
                name: tool.name,
                description: tool.description,
                isBuiltIn: builtInNames.contains(tool.name)
            )
        }
    }

    /// Replace all app-registered tools and re-broadcast to the web app.
    /// Built-in tools (registered via `registerBuiltInTools`) are preserved.
    /// Use this when the tool list changes dynamically (e.g. user scripts).
    public func setTools(_ tools: [NativeTool]) {
        registeredTools = tools
        guard isConnected else { return }
        let defs = toolDefinitions
        send([
            "type": "\(messagePrefix)mcp:tools",
            "version": protocolVersion,
            "timestamp": currentTimestamp(),
            "tools": defs,
        ])
    }

    /// Configure a native LLM provider for on-device inference.
    /// When set, the handshake will advertise `llm: true` capability.
    public func setLLMProvider(_ provider: LLMProvider) {
        self.llmProvider = provider
        NSLog("[AgentBridge] LLM provider configured")
    }

    public func attach(to webView: WKWebView) {
        self.webView = webView
        NSLog("[AgentBridge] Attached to WKWebView")
    }

    /// Master switch for native console logging. Off (the default) means no
    /// console.* output crosses the bridge (the JS `window.__ripulNativeLog` gate)
    /// and the hot-path NSLog traces stay silenced — the quiet/cool default. On
    /// restores the full firehose for debugging. Pushed live to the web view so a
    /// toggle change takes effect immediately, no reload. Uncaught errors are
    /// captured regardless (they bypass the console gate).
    public func setVerboseLogging(_ on: Bool) {
        AgentBridge.verboseBridgeLog = on
        evaluateJavaScript("window.__ripulNativeLog = \(on)")
    }

    /// Called by the web view coordinator when the page finishes loading.
    /// Starts a timeout — if the bridge doesn't connect within 10 seconds,
    /// clears the cache and reloads once to evict stale web app bundles.
    public func pageDidFinishLoading() {
        // Push persisted network capture state into the web view
        if isNetworkCaptureEnabled {
            evaluateJavaScript("window.__ripulNetworkCapture && window.__ripulNetworkCapture(true)")
        }
        // Push the native-console-logging master flag. Default false => console.*
        // does not cross the bridge (quiet/cool). Re-pushed on every load so a
        // self-heal reload keeps the setting.
        evaluateJavaScript("window.__ripulNativeLog = \(AgentBridge.verboseBridgeLog)")
        // Refresh the host-prefs mirror with CURRENT UserDefaults values — the
        // documentStart script is baked at webview creation, so this is what
        // keeps reloads of the same webview accurate after host-prefs:set writes.
        pushHostPrefsToPage()
        pushHostTokenToPage()
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000) // 5s
            guard let self, !Task.isCancelled else { return }
            if !self.isConnected && !self.hasAttemptedCacheReload {
                self.hasAttemptedCacheReload = true
                NSLog("[AgentBridge] Bridge did not connect within 5s — clearing cache and reloading (one-time)")
                self.clearCacheAndReload()
            } else if !self.isConnected {
                NSLog("[AgentBridge] Bridge did not connect after cache reload — giving up.")
                if !self.jsErrorMessages.isEmpty {
                    self.loadError = "The app failed to load"
                    self.loadErrorDetails = self.jsErrorMessages.joined(separator: "\n")
                } else {
                    self.loadError = "Could not connect"
                    self.loadErrorDetails = "The page loaded but the app bridge did not respond. This usually means the web app failed to initialize."
                }
            }
        }
    }

    /// Reload the web view, clearing any load error.
    public func reload() {
        guard let webView else {
            NSLog("[AgentBridge] Cannot reload — webView is nil")
            return
        }
        loadError = nil
        loadErrorDetails = nil
        isConnected = false
        isThemeReady = false
        initialStatusSyncComplete = false
        resetLifecycleState()
        jsErrorMessages = []
        jsErrorDebounce?.cancel()
        webView.reload()
    }

    /// Clear cached resources (JS, CSS, images) and reload the web view.
    /// Preserves cookies, localStorage, and session data so the user stays logged in.
    public func clearCacheAndReload() {
        let cacheTypes: Set<String> = [
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache,
            WKWebsiteDataTypeOfflineWebApplicationCache,
            WKWebsiteDataTypeFetchCache,
        ]
        let store = webView?.configuration.websiteDataStore ?? WKWebsiteDataStore.default()
        store.removeData(ofTypes: cacheTypes, modifiedSince: .distantPast) { [weak self] in
            guard let self, let webView = self.webView else {
                NSLog("[AgentBridge] Cannot reload — webView is nil")
                return
            }
            NSLog("[AgentBridge] Cache cleared, performing fresh load (not reloadFromOrigin)")
            self.isConnected = false
            self.isThemeReady = false
            // Use a fresh URLRequest with a cache-busting query parameter.
            // WKWebView's removeData() is unreliable — it often doesn't actually
            // clear the HTTP cache. A unique URL forces a real network fetch.
            // Once the HTML loads fresh, it references new content-hashed JS
            // filenames, so the entire bundle chain is guaranteed fresh.
            if let url = webView.url,
               var components = URLComponents(url: url, resolvingAgainstBaseURL: true) {
                var items = components.queryItems ?? []
                items.removeAll { $0.name == "_cb" }
                items.append(URLQueryItem(name: "_cb", value: "\(Int(Date().timeIntervalSince1970))"))
                components.queryItems = items
                if let bustURL = components.url {
                    var request = URLRequest(url: bustURL)
                    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                    webView.load(request)
                } else {
                    webView.reloadFromOrigin()
                }
            } else {
                webView.reloadFromOrigin()
            }
        }
    }

    /// Clear ALL website data (cache, cookies, localStorage, IndexedDB, etc.) and reload.
    /// This is a full reset — the user will need to log in again.
    public func clearAllDataAndReload() {
        let allTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        let store = webView?.configuration.websiteDataStore ?? WKWebsiteDataStore.default()
        store.removeData(ofTypes: allTypes, modifiedSince: .distantPast) { [weak self] in
            guard let webView = self?.webView else {
                return
            }
            NSLog("[AgentBridge] All website data cleared, performing fresh load")
            self?.isConnected = false
            self?.isThemeReady = false
            self?.hasAttemptedCacheReload = false
            // Use a fresh URLRequest to bypass WKWebView's ES module cache
            if let url = webView.url {
                var request = URLRequest(url: url)
                request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                webView.load(request)
            } else {
                webView.reloadFromOrigin()
            }
        }
    }

    /// Navigate the attached web view to a new URL (e.g. to start a new chat with a prompt).
    public func navigate(to url: URL) {
        guard let webView else {
            NSLog("[AgentBridge] Cannot navigate — webView is nil")
            return
        }
        isConnected = false
        isThemeReady = false
        wantsMinimize = false
        NSLog("[AgentBridge] Navigating to: %@", url.absoluteString)
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        webView.load(request)
    }

    /// Update the web app's bottom padding to match the measured native chat input height.
    /// Retries until the web callable is available (it registers after ChatTabContent mounts).
    private var lastReportedInputHeight: Int = 0
    private var pendingInputHeight: Int?
    public func setNativeChatInputHeight(_ px: Int) {
        guard px != lastReportedInputHeight else { return }
        lastReportedInputHeight = px
        pendingInputHeight = px
        pushInputHeightToWeb(px)
    }

    /// Re-push the last measured height after the web view reconnects.
    public func resendInputHeight() {
        if let px = pendingInputHeight {
            pushInputHeightToWeb(px)
        }
    }

    private func pushInputHeightToWeb(_ px: Int) {
        evaluateJavaScript("""
            window.__ripulNativeChatInputHeight = \(px);
            if (window.__ripulSetBottomPadding) {
                window.__ripulSetBottomPadding(\(px));
            } else {
                var _attempts = 0;
                var _iv = setInterval(function() {
                    _attempts++;
                    if (window.__ripulSetBottomPadding) {
                        window.__ripulSetBottomPadding(\(px));
                        clearInterval(_iv);
                    } else if (_attempts > 20) {
                        clearInterval(_iv);
                    }
                }, 250);
            }
        """)
    }

    /// Notify the web app that the native app returned to the foreground so relay
    /// connections can detect and rebuild a stale/zombie WebSocket.
    ///
    /// Two signals are sent because WKWebView does not reliably set
    /// `document.visibilityState` to `'visible'` on resume — so a bare synthetic
    /// `visibilitychange` event can be ignored by handlers gated on visibility:
    ///   1. The synthetic `visibilitychange` event (legacy path).
    ///   2. `window.__ripulForegrounded()`, which forces relay/session-channel
    ///      recovery UNCONDITIONALLY (ignores visibilityState). This is the fix
    ///      for the iPhone "locked into a dead comms channel until app restart"
    ///      failure mode.
    public func notifyWebViewBecameVisible() {
        // ROOT-CAUSE FIX for the network-switch / background wedge:
        //
        // While the app is backgrounded, iOS can suspend or jettison the
        // WKWebView content process (jetsam, worsened by a network-switch
        // reconnect storm). WKWebView CANNOT perform a load while backgrounded,
        // so any recovery reload triggered off-foreground (recordProcessTermination,
        // self-heal) is silently dropped — and the process is still dead on
        // return. That's why the app came back wedged and the FIRST evals to
        // fail were these foreground-resume ones. Mobile Safari auto-reloads a
        // jettisoned tab on foreground and macOS doesn't suspend the process,
        // which is exactly why both were fine while the iPhone wedged.
        //
        // So on foreground: (1) flush any reload we deferred while backgrounded,
        // then (2) probe the context and reload it if it's dead — instead of
        // firing the sync evals into a corpse (which only logs "unsupported type").
        if consumeDeferredRecoveryReload() { return }
        Task { @MainActor in
            let health = await probeWebContextHealth()
            if health == .contextDead || health == .webCrashed {
                handleConsoleLog("WARN: [WEBVIEW_HEAL] context \(health.rawValue) on foreground — healing before foreground sync")
                await healWebContext(reason: "foreground: context \(health.rawValue)")
                return
            }
            fireForegroundSyncEvals()
        }
    }

    /// The foreground relay/visibility sync. Trailing `true;` forces a bridgeable
    /// completion value (a bare Promise return logs a spurious "unsupported type").
    private func fireForegroundSyncEvals() {
        evaluateJavaScript("""
            document.dispatchEvent(new Event('visibilitychange'));
            if (window.__ripulForegrounded) { window.__ripulForegrounded(); }
            true;
        """)
    }

    // MARK: - Foreground-gated recovery + process-lifecycle instrumentation

    /// True only when the app is actively foregrounded — the only state in which
    /// a WKWebView will actually perform a network load. Always true on macOS
    /// (no content-process suspension on background).
    private var isAppActive: Bool {
        #if os(iOS)
        return UIApplication.shared.applicationState == .active
        #else
        return true
        #endif
    }

    /// A recovery reload that was requested while backgrounded and deferred until
    /// foreground (WKWebView drops loads while suspended).
    private var deferredRecoveryReload: (() -> Void)?

    /// Run a recovery reload now if foregrounded, else defer it to the next
    /// foreground. This is the fix for "reload() dropped while backgrounded →
    /// still dead on resume". User-initiated reloads do NOT go through here.
    private func recoveryReload(label: String, _ action: @escaping () -> Void) {
        if isAppActive {
            action()
        } else {
            handleConsoleLog("WARN: [WEBVIEW_HEAL] \(label) deferred — app backgrounded (WKWebView can't load while suspended); will run on foreground")
            deferredRecoveryReload = action
        }
    }

    /// If a recovery reload was deferred while backgrounded, perform it now.
    @discardableResult
    private func consumeDeferredRecoveryReload() -> Bool {
        guard let action = deferredRecoveryReload else { return false }
        deferredRecoveryReload = nil
        handleConsoleLog("LOG: [WEBVIEW_HEAL] performing deferred recovery reload on foreground")
        action()
        return true
    }

    /// Observe app lifecycle + memory-pressure so a wedge's context (was it
    /// backgrounded? was there a memory warning just before?) is in the log,
    /// turning the next incident into a root-cause-grade timeline.
    private func startProcessLifecycleMonitoring() {
        #if os(iOS)
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleConsoleLog("LOG: [LIFECYCLE] app → background") }
        }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleConsoleLog("LOG: [LIFECYCLE] app → foreground (will enter)") }
        }
        nc.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let avail = Double(os_proc_available_memory()) / 1_048_576
                self.handleConsoleLog(String(format: "WARN: [MEMORY_WARNING] iOS memory warning — Avail=%.0fMB (jetsam risk for the web content process)", avail))
            }
        }
        #endif
    }

    // MARK: - Network Path Monitoring

    private var pathMonitor: NWPathMonitor?
    private let pathMonitorQueue = DispatchQueue(label: "io.ripul.network-path-monitor")
    /// Fingerprint of the last observed network path (reachability + active
    /// interface). We only force recovery when this actually changes, so the
    /// baseline callback and duplicate updates are ignored.
    private var lastPathFingerprint: String?

    /// Start watching for network path changes so a cellular <-> Wi-Fi handoff (or
    /// connectivity returning) forces the web app's relay/session sockets to
    /// rebuild IMMEDIATELY.
    ///
    /// WHY: when the device changes networks while the app stays FOREGROUNDED, the
    /// OS swaps the active interface and the existing WebSocket is stranded on the
    /// old/dead one as a half-open zombie (readyState stays OPEN, no `onclose`).
    /// No app-lifecycle recovery path fires (the app never backgrounded), so
    /// recovery would otherwise wait out the web heartbeat's liveness window
    /// (~37.5s relay / ~75s session). NWPathMonitor delivers the handoff the
    /// moment it happens; we reuse the existing `__ripulForegrounded()` hook — the
    /// same "re-validate every socket now" entry point used on foreground.
    private func startNetworkPathMonitoring() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            // Derive a Sendable fingerprint off the path on this (background) queue,
            // then hop to the main actor to compare against the last one and act.
            let satisfied = path.status == .satisfied
            let fingerprint = "\(path.status)"
                + "|wifi:\(path.usesInterfaceType(.wifi))"
                + "|cell:\(path.usesInterfaceType(.cellular))"
                + "|wired:\(path.usesInterfaceType(.wiredEthernet))"
            Task { @MainActor in
                guard let self else { return }
                let previous = self.lastPathFingerprint
                self.lastPathFingerprint = fingerprint
                // First callback only establishes the baseline. Act on a genuine
                // change that leaves us with a usable ('satisfied') network.
                guard let previous, previous != fingerprint, satisfied else { return }
                AgentBridge.debugLog("[AgentBridge] network path changed (\(previous) -> \(fingerprint)) — forcing comms recovery")
                self.notifyNetworkPathChanged()
            }
        }
        monitor.start(queue: pathMonitorQueue)
        pathMonitor = monitor
    }

    /// Force relay/session-channel recovery after a network handoff.
    /// `__ripulNetworkChanged` challenge-probes every socket (a handoff strands
    /// them half-open with OPEN readyState + fresh liveness, which the plain
    /// foreground hook trusts — costing the full ~37.5s/75s liveness window
    /// before rebuild). Falls back to the foreground hook on a web bundle that
    /// predates the network-change callable. No fake `visibilitychange` —
    /// visibility never changed, only the network did.
    public func notifyNetworkPathChanged() {
        evaluateJavaScript("""
            if (window.__ripulNetworkChanged) { window.__ripulNetworkChanged(); }
            else if (window.__ripulForegrounded) { window.__ripulForegrounded(); }
            true;
        """)
    }

    deinit {
        pathMonitor?.cancel()
    }

    /// Evaluate arbitrary JavaScript in the attached web view.
    /// Use for extracting data (e.g. auth tokens) from the web app context.
    public func evaluateJavaScript(_ script: String, completion: ((Any?) -> Void)? = nil) {
        guard let webView else {
            NSLog("[AgentBridge] Cannot evaluate JS — webView is nil")
            completion?(nil)
            return
        }
        webView.evaluateJavaScript(script) { [weak self] result, error in
            if let error {
                // WKWebView returns code 5 (javaScriptResultTypeIsUnsupported)
                // whenever the evaluated script's last expression yields a value it
                // can't bridge (undefined, a DOM node, a function). The JS ran fine;
                // swallow this benign case so it doesn't mask real crashes.
                let ns = error as NSError
                let benignUnsupportedResult = ns.domain == WKError.errorDomain
                    && ns.code == WKError.Code.javaScriptResultTypeIsUnsupported.rawValue
                if !benignUnsupportedResult {
                    NSLog("[AgentBridge] JS eval error: %@", error.localizedDescription)
                    let snippet = script.prefix(80).replacingOccurrences(of: "\n", with: " ")
                    self?.handleConsoleLog("ERROR: [JS_EVAL] \(AgentBridge.describeEvalError(error)) | script: \(snippet)")
                    Task { @MainActor in self?.noteJsEvalFailure() }
                }
                completion?(nil)
            } else {
                Task { @MainActor in self?.consecutiveJsEvalFailures = 0 }
                completion?(result)
            }
        }
    }

    /// Fire-and-forget JS whose return value we don't use. Appends `; true;` so a
    /// HEALTHY context returns a bridgeable value instead of `undefined` — a bare
    /// `window.__ripulFoo?.()` returns undefined and trips WebKit's
    /// "result of an unsupported type" error on EVERY call, which both spams the
    /// log and pollutes the consecutive-failure counter that drives the self-heal.
    /// A genuinely dead context still fails even `true;`, so the counter stays an
    /// accurate liveness signal. Use this for all void UI-poke evals.
    func evaluateVoidJavaScript(_ body: String) {
        evaluateJavaScript(body + "\n; true;")
    }

    /// Consecutive `evaluateJavaScript` failures. A run of these is the
    /// signature of a wedged/terminated JS context (every script fails, even
    /// ones ending in a bridgeable literal) — the state that previously left
    /// the app permanently broken until a manual cache clear.
    private var consecutiveJsEvalFailures = 0

    private func noteJsEvalFailure() {
        consecutiveJsEvalFailures += 1
        guard consecutiveJsEvalFailures >= 3 else { return }
        consecutiveJsEvalFailures = 0
        Task { [weak self] in
            guard let self else { return }
            if await self.probeWebContextHealth() == .contextDead {
                await self.healWebContext(reason: "3 consecutive JS eval failures")
            }
        }
    }

    /// Evaluate async JavaScript that may contain `await`. Returns the resolved value.
    /// Unlike `evaluateJavaScript`, this properly awaits Promises.
    @available(iOS 15.0, macOS 13.0, *)
    public func callAsyncJavaScript(_ script: String) async throws -> Any? {
        guard let webView else {
            throw NSError(domain: "AgentBridge", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "webView is nil"])
        }
        return try await webView.callAsyncJavaScript(script, contentWorld: .page)
    }

    // MARK: - JS-context health probe & self-heal

    /// Result of probing the web view's JS context with a canary eval.
    public enum WebContextHealth: String {
        /// Canary round-tripped and the remote-session callables are installed.
        case healthy
        /// JS runs, but the React tree crashed (window.__ripulWebAppCrashed set) —
        /// remote-session providers are gone until the page reloads.
        case webCrashed
        /// JS runs, but the __ripul* callables aren't installed YET and the page
        /// is plausibly still booting (young document / not `complete`).
        /// Retrying genuinely can succeed.
        case callablesMissing
        /// JS runs, the page has SETTLED (or its boot beacon says the boot chain
        /// finished or failed), and the callables still aren't there. Retrying will
        /// never fix this — the web boot chain broke. Distinct from
        /// `callablesMissing` so we stop telling the user to "try again in a
        /// moment" about a page that is done trying.
        case callablesAbsent

        /// Even a string-literal eval fails — the context is wedged or the
        /// content process is gone. Only a reload recovers this.
        case contextDead
        case noWebView
    }

    /// Human description of a WKWebView eval error incl. domain + code + name.
    /// The code is the single most diagnostic datum for the JS-context wedge.
    static func describeEvalError(_ error: Error) -> String {
        let ns = error as NSError
        let name: String
        switch (ns.domain, ns.code) {
        case ("WKErrorDomain", 2): name = "WebContentProcessTerminated"
        case ("WKErrorDomain", 4): name = "JavaScriptExceptionOccurred"
        case ("WKErrorDomain", 5): name = "JavaScriptResultTypeIsUnsupported"
        case ("WKErrorDomain", 9): name = "ContentRuleListStoreLookUpFailed"
        default: name = ns.localizedDescription
        }
        return "\(ns.domain)#\(ns.code) \(name)"
    }

    /// Everything the probe canary could see, gathered from PLAIN BROWSER APIs.
    ///
    /// Deliberately does not touch `window.__ripulDiagnostics`: that callable is
    /// installed by `registerNativeCallables()`, the very thing that is missing
    /// in the state we most need to explain — so the old forensic path went dark
    /// exactly when it mattered and every report came back empty.
    public struct WebContextProbe {
        public var health: WebContextHealth
        /// `document.readyState` at probe time.
        public var readyState: String?
        /// Age of the current document — separates a boot race from a dead boot.
        public var docAgeMs: Int?
        /// Which page is actually loaded (a non-app shell has no callables by design).
        public var path: String?
        /// `navigation` timing type: navigate / reload / back_forward.
        public var navType: String?
        /// Does the UA carry `RipulNative`? If false, `isNativeAppMode()` said no
        /// and the callables were never even attempted.
        public var uaNative: Bool?
        /// How many `__ripul*` globals exist. 0 = the boot chain never got there;
        /// many-but-not-ours = partial/foreign registration.
        public var ripulGlobals: Int?
        /// Last phase recorded by the web boot beacon, plus its error if it threw.
        public var bootPhase: String?
        public var bootError: String?
        public var build: String?
        /// The canary's raw JSON, for the copyable technical details.
        public var raw: String?

        /// One-line digest for logs and the user-visible error string. This is
        /// what turns "it flapped again" into a diagnosable event.
        public var digest: String {
            var parts: [String] = []
            if let path { parts.append("path=\(path)") }
            if let readyState { parts.append("ready=\(readyState)") }
            if let docAgeMs { parts.append("age=\(docAgeMs / 1000)s") }
            if let navType { parts.append("nav=\(navType)") }
            if let ripulGlobals { parts.append("globals=\(ripulGlobals)") }
            if let uaNative { parts.append("uaNative=\(uaNative)") }
            if let bootPhase { parts.append("boot=\(bootPhase)") }
            if let bootError { parts.append("bootErr=\(bootError.prefix(120))") }
            if let build { parts.append("build=\(build)") }
            return parts.joined(separator: " ")
        }
    }

    /// A document younger than this is given the benefit of the doubt as a boot
    /// race; past it, absent callables are treated as a broken boot, not a slow one.
    private static let callableInstallGraceMs = 8_000

    /// Back-compat shim for call sites that only need the verdict.
    public func probeWebContextHealth() async -> WebContextHealth {
        await probeWebContext().health
    }

    /// Probe the JS context with a canary that returns a plain string (always
    /// bridgeable — a probe must never itself fail with "unsupported type").
    /// A canary failure is captured with its WKError code so `.contextDead`
    /// carries WHY (process gone vs suspended vs unbridgeable).
    public func probeWebContext() async -> WebContextProbe {
        guard let webView else { return WebContextProbe(health: .noWebView) }
        let canary = """
        (function () {
          try {
            var w = window, keys = [];
            try { keys = Object.keys(w).filter(function (k) { return k.indexOf('__ripul') === 0; }); } catch (e) {}
            var nav = null;
            try { var n = performance.getEntriesByType('navigation')[0]; if (n) nav = n.type; } catch (e) {}
            var boot = null;
            try { boot = w.__ripulBoot || null; } catch (e) {}
            return JSON.stringify({
              callables: !!w.__ripulOpenRemoteSession,
              crashed: !!w.__ripulWebAppCrashed,
              globals: keys.length,
              globalNames: keys.slice(0, 12),
              readyState: document.readyState,
              docAgeMs: Math.round(performance.now()),
              path: location.pathname,
              nav: nav,
              uaNative: (navigator.userAgent || '').indexOf('RipulNative') >= 0,
              bootPhase: boot ? boot.phase : null,
              bootError: boot ? (boot.error || null) : null,
              bootHistory: boot ? boot.history : null,
              build: boot ? boot.build : null
            });
          } catch (e) { return JSON.stringify({ probeError: String(e) }); }
        })();
        """
        let raw: String? = await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            webView.evaluateJavaScript(canary) { [weak self] value, error in
                if let error {
                    Task { @MainActor in
                        self?.handleConsoleLog("WARN: [CONN_DIAG] context probe canary failed: \(AgentBridge.describeEvalError(error)) — active=\(self?.isAppActive ?? false) url=\(self?.webView?.url?.absoluteString ?? "nil")")
                    }
                    cont.resume(returning: nil)
                } else {
                    cont.resume(returning: value as? String)
                }
            }
        }
        guard let raw,
              let data = raw.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return WebContextProbe(health: .contextDead, raw: raw)
        }

        var probe = WebContextProbe(health: .healthy)
        probe.readyState = dict["readyState"] as? String
        probe.docAgeMs = dict["docAgeMs"] as? Int
        probe.path = dict["path"] as? String
        probe.navType = dict["nav"] as? String
        probe.uaNative = dict["uaNative"] as? Bool
        probe.ripulGlobals = dict["globals"] as? Int
        probe.bootPhase = dict["bootPhase"] as? String
        probe.bootError = dict["bootError"] as? String
        probe.build = dict["build"] as? String
        probe.raw = raw

        if (dict["crashed"] as? Bool) == true {
            probe.health = .webCrashed
        } else if (dict["callables"] as? Bool) != true {
            // Booting, or broken? The boot beacon answers directly when present:
            // a terminal phase means the chain ran to its end WITHOUT registering.
            // Without a beacon (old bundle, or a shell that never loads the app),
            // fall back to document age + readyState.
            let terminalPhases = ["boot-complete", "boot-failed", "native-mode-false", "sidepanel-initialized"]
            let bootSettled = probe.bootPhase.map { terminalPhases.contains($0) } ?? false
            let ageSettled = (probe.docAgeMs ?? 0) >= Self.callableInstallGraceMs
                && (probe.readyState ?? "") == "complete"
            probe.health = (bootSettled || ageSettled) ? .callablesAbsent : .callablesMissing
        }
        return probe
    }

    // MARK: Escalating self-heal ladder
    //
    // A plain reload() is NOT enough: the wedge often recurs on the fresh boot
    // because persisted state re-poisons it (remote-tab-pairings / cliSessionMap
    // in localStorage rebind to a dead/stranded machine; IndexedDB preloads
    // stale chat actions). That is exactly why the manual fix is "Clear cache &
    // reload" + "Clear sessions data", not just a reload. So the heal escalates:
    //   attempt 1 → reload()                     (cheap, fixes transient wedges)
    //   attempt 2 → purgeWebStateAndReload()     (auto "clear sessions data")
    //   attempt 3 → purgeWebStateAndReload()     (network may have settled)
    //   attempt 4+ → macOS: keep purging with exponential backoff (host is
    //               often unattended — giving up leaves it dead). iOS: stop,
    //               because the user is present and can tap Retry.
    // A short FLOOR between heals prevents a tight loop; the ESCALATION WINDOW
    // resets the ladder so a later, unrelated incident starts cheap again.

    private var lastContextHealAt: Date?
    private var healAttempts = 0
    private var healVerifyTask: Task<Void, Never>?
    private var deferredHealTask: Task<Void, Never>?
    /// Minimum gap between heals — stops a reload storm.
    private let baseHealFloor: TimeInterval = 10
    /// Maximum time between heals on macOS (5 minutes).
    private let maxHealFloor: TimeInterval = 300
    /// Heals within this window escalate; a heal after it resets the ladder.
    private let healEscalationWindow: TimeInterval = 90

    /// Gap between heals. macOS backs off exponentially after 3 attempts so an
    /// unattended host keeps retrying without hammering CPU/network/battery.
    private func healFloor(for attempt: Int) -> TimeInterval {
        #if os(macOS)
        if attempt > 3 {
            let backoff = baseHealFloor * pow(2.0, Double(min(attempt - 3, 5)))
            return min(backoff, maxHealFloor)
        }
        #endif
        return baseHealFloor
    }

    private func remainingHealFloor() -> TimeInterval {
        guard let last = lastContextHealAt else { return 0 }
        let floor = healFloor(for: healAttempts)
        let elapsed = Date().timeIntervalSince(last)
        return max(0, floor - elapsed)
    }

    /// Set by the host app (macOS) to record web-view self-heal reloads into its
    /// persistent restart log — a heal reloads the whole web app, which reads as
    /// "the host restarted". Args: (reason, attempt) where attempt 1 = plain
    /// reload, 2–3 = purge + reload, 4+ = ladder exhausted.
    public static var webViewHealRecorder: ((String, Int) -> Void)?

    /// Recover a dead/crashed JS context, escalating on repeated failures within
    /// the window. Returns true if a recovery action was triggered.
    @discardableResult
    public func healWebContext(reason: String) async -> Bool {
        // A suspended WKWebView won't reload, and probing/escalating while
        // backgrounded is pointless (and would burn through the ladder against a
        // process that can't recover until resume). Arm a deferred reload and
        // bail; notifyWebViewBecameVisible() heals for real on foreground.
        if !isAppActive {
            handleConsoleLog("WARN: [WEBVIEW_HEAL] unhealthy while backgrounded (\(reason)) — deferring reload to foreground")
            deferredRecoveryReload = { [weak self] in self?.reload() }
            return false
        }
        let now = Date()
        let nextAttempt = healAttempts + 1
        let floor = healFloor(for: nextAttempt)
        if let last = lastContextHealAt {
            let since = now.timeIntervalSince(last)
            if since < floor {
                handleConsoleLog("WARN: [WEBVIEW_HEAL] skipped, healed \(Int(since))s ago (floor \(Int(floor))s) — \(reason)")
                #if os(macOS)
                // Unattended host: don't just sit here — schedule a retry once the
                // floor has elapsed. iOS relies on the user tapping Retry instead.
                scheduleDeferredHeal(reason: reason)
                #endif
                return false
            }
            if since > healEscalationWindow { healAttempts = 0 }
        }
        lastContextHealAt = now
        healAttempts += 1
        Self.webViewHealRecorder?(reason, healAttempts)

        switch healAttempts {
        case 1:
            handleConsoleLog("ERROR: [WEBVIEW_HEAL] attempt 1 (\(reason)) — reloading web app")
            recoveryReload(label: "heal reload") { [weak self] in self?.reload() }
        case 2, 3:
            handleConsoleLog("ERROR: [WEBVIEW_HEAL] attempt \(healAttempts) (\(reason)) — reload didn't stick; purging session state + reloading")
            recoveryReload(label: "heal purge") { [weak self] in self?.purgeWebStateAndReload() }
        default:
            #if os(macOS)
            handleConsoleLog("ERROR: [WEBVIEW_HEAL] attempt \(healAttempts) (\(reason)) — macOS host, continuing purge + reload with \(Int(floor))s floor")
            recoveryReload(label: "heal purge (macOS persistent)") { [weak self] in self?.purgeWebStateAndReload() }
            #else
            handleConsoleLog("ERROR: [WEBVIEW_HEAL] attempt \(healAttempts) (\(reason)) — auto-recovery exhausted; relaunch required (device may be offline)")
            return false
            #endif
        }
        scheduleHealVerification(reason: reason)
        return true
    }

    /// macOS-only: schedule a heal retry once the current floor has elapsed.
    /// Cancels any previous deferred heal so floors don't stack.
    private func scheduleDeferredHeal(reason: String) {
        deferredHealTask?.cancel()
        deferredHealTask = Task { [weak self] in
            guard let self else { return }
            let delay = self.remainingHealFloor()
            guard delay > 0 else {
                await self.healWebContext(reason: "deferred heal floor elapsed — \(reason)")
                return
            }
            self.handleConsoleLog("LOG: [WEBVIEW_HEAL] macOS deferred heal scheduled in \(Int(delay))s")
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, self.isAppActive else { return }
            await self.healWebContext(reason: "deferred heal fired — \(reason)")
        }
    }

    /// Escalation heal: clear the persisted state that re-poisons a fresh boot
    /// (localStorage pairings/cliSessionMap, IndexedDB chat actions) plus caches,
    /// then fresh-load. PRESERVES cookies so the Clerk session survives (login
    /// also re-injects natively). This is the manual "Clear cache & reload +
    /// Clear sessions data" recovery, done automatically.
    public func purgeWebStateAndReload() {
        var types = WKWebsiteDataStore.allWebsiteDataTypes()
        types.remove(WKWebsiteDataTypeCookies) // keep auth
        let store = webView?.configuration.websiteDataStore ?? WKWebsiteDataStore.default()
        store.removeData(ofTypes: types, modifiedSince: .distantPast) { [weak self] in
            guard let self, let webView = self.webView else { return }
            self.handleConsoleLog("WARN: [WEBVIEW_HEAL] session state + caches purged (cookies kept) — fresh load")
            self.isConnected = false
            self.isThemeReady = false
            self.hasAttemptedCacheReload = false
            if let url = webView.url,
               var components = URLComponents(url: url, resolvingAgainstBaseURL: true) {
                var items = (components.queryItems ?? []).filter { $0.name != "_cb" }
                items.append(URLQueryItem(name: "_cb", value: "\(Int(Date().timeIntervalSince1970))"))
                components.queryItems = items
                var request = URLRequest(url: components.url ?? url)
                request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                webView.load(request)
            } else {
                webView.reloadFromOrigin()
            }
        }
    }

    /// After a heal, verify the context actually came back — and escalate
    /// proactively if it didn't, rather than waiting for the user's next failed
    /// tap (which the floor might defer). Healthy → reset the ladder.
    private func scheduleHealVerification(reason: String) {
        healVerifyTask?.cancel()
        healVerifyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000) // 15s — fair chance to reload on cellular
            guard let self, !Task.isCancelled else { return }
            let health = await self.probeWebContextHealth()
            switch health {
            case .healthy:
                self.handleConsoleLog("LOG: [WEBVIEW_HEAL] post-heal probe healthy — recovered after \(self.healAttempts) attempt(s)")
                self.healAttempts = 0
                self.deferredHealTask?.cancel()
                self.deferredHealTask = nil
            case .contextDead, .webCrashed, .callablesAbsent:
                // callablesAbsent post-heal means the RELOAD came back without a
                // native bridge too — escalating to the purge rung is the point.
                self.handleConsoleLog("WARN: [WEBVIEW_HEAL] post-heal probe \(health.rawValue) — escalating")
                await self.healWebContext(reason: "post-heal still \(health.rawValue)")
            case .callablesMissing, .noWebView:
                // Still booting or no view — don't escalate to a purge on a slow
                // load; the eval-failure counter remains armed as a backstop.
                self.handleConsoleLog("LOG: [WEBVIEW_HEAL] post-heal probe \(health.rawValue) — leaving to finish booting")
            }
        }
    }

    // MARK: Host-bridge unavailability backstop
    //
    // The host-status callable can report total failure in a way that LOOKS like
    // a successful call: `{available:false}` is a well-formed dictionary, so the
    // eval-failure counter never arms, `classifyJsCallFailure` is never reached,
    // and a permanently dead web boot is indistinguishable from an idle host.
    // That is precisely how the "BRIDGE NOT MOUNTED / not ready" state became
    // unrecoverable without a manual relaunch: every recovery mechanism in this
    // file keys off an *exception*, and this state produces none.
    //
    // Every caller of getHostStatus() feeds this tracker. Once the bridge has
    // been continuously unavailable for `hostBridgeUnavailableGrace`, we probe
    // the JS context and hand an unhealthy verdict to the same heal ladder the
    // callable paths use. A HEALTHY probe is deliberately left alone: the
    // callables exist and the page is accurately reporting an unregistered
    // provider, which a reload wouldn't fix.

    /// Sentinel returned by the callable-presence guards below. Distinct from
    /// every web-side error string, so "the bridge said no" and "there is no
    /// bridge at all" can never be conflated again — they have different causes
    /// and different fixes.
    public static let callableMissingError = "callable-missing"

    private var hostBridgeUnavailableSince: Date?
    private var lastHostBridgeProbeAt: Date?
    /// Continuous unavailability tolerated before probing. Comfortably longer
    /// than `callableInstallGraceMs` so an ordinary cold boot never trips it.
    private let hostBridgeUnavailableGrace: TimeInterval = 15
    /// Minimum gap between backstop probes — callers poll as fast as 1Hz.
    private let hostBridgeProbeInterval: TimeInterval = 15

    /// Record that the host bridge answered normally. Disarms the backstop.
    public func noteHostBridgeAvailable() {
        if hostBridgeUnavailableSince != nil {
            handleConsoleLog("LOG: [HOST_BRIDGE] available again — clearing unavailability backstop")
        }
        hostBridgeUnavailableSince = nil
        lastHostBridgeProbeAt = nil
    }

    /// Record that the host bridge is unavailable, and heal if it stays that
    /// way. Safe to call at any cadence, from any number of callers.
    public func noteHostBridgeUnavailable(reason: String) {
        let now = Date()
        guard let since = hostBridgeUnavailableSince else {
            hostBridgeUnavailableSince = now
            handleConsoleLog("WARN: [HOST_BRIDGE] unavailable (\(reason)) — backstop armed; probing in \(Int(hostBridgeUnavailableGrace))s if it persists")
            return
        }
        guard now.timeIntervalSince(since) >= hostBridgeUnavailableGrace else { return }
        if let last = lastHostBridgeProbeAt, now.timeIntervalSince(last) < hostBridgeProbeInterval { return }
        lastHostBridgeProbeAt = now

        Task { [weak self] in
            guard let self else { return }
            let probe = await self.probeWebContext()
            let elapsed = Int(Date().timeIntervalSince(since))
            self.handleConsoleLog("WARN: [HOST_BRIDGE] unavailable \(elapsed)s (\(reason)) — probe=\(probe.health.rawValue) \(probe.digest)")
            switch probe.health {
            case .contextDead, .webCrashed, .callablesAbsent:
                await self.healWebContext(
                    reason: "host bridge unavailable \(elapsed)s: \(reason) — \(probe.health.rawValue)"
                )
            case .callablesMissing:
                // Genuinely mid-boot (young document). The next tick re-probes.
                break
            case .healthy:
                // Callables ARE installed, so the page is answering and telling
                // us the provider isn't registered. That's a web-side mount
                // failure with its own error boundary + auto-remount; reloading
                // over the top of an accurate report doesn't help. Stay loud.
                self.handleConsoleLog("WARN: [HOST_BRIDGE] context healthy but bridge unavailable \(elapsed)s — web-side provider problem, not healing")
            case .noWebView:
                break
            }
        }
    }

    /// Fetch the web app's one-shot connection diagnostics snapshot
    /// (`__ripulDiagnostics`) as a JSON string, or nil if unreachable.
    @available(iOS 15.0, macOS 13.0, *)
    public func fetchWebDiagnostics() async -> String? {
        guard let webView else { return nil }
        let script = """
        if (!window.__ripulDiagnostics) return null;
        return JSON.stringify(await window.__ripulDiagnostics());
        """
        return (try? await webView.callAsyncJavaScript(script, arguments: [:], contentWorld: .page)) as? String
    }

    /// Turn an opaque JS-call failure (throw, or an unbridgeable/nil result)
    /// into a classified, actionable error string — probing the JS context and
    /// self-healing when that's what's actually broken. This is what stops
    /// "JavaScript execution returned a result of an unsupported type" from
    /// being both the alert text AND a permanent state.
    @available(iOS 15.0, macOS 13.0, *)
    private func classifyJsCallFailure(_ rawDescription: String, callable: String) async -> String {
        handleConsoleLog("ERROR: [CONN_DIAG] \(callable) failed: \(rawDescription) — probing web context")
        let probe = await probeWebContext()
        // Log the FULL probe every time. This failure flaps, and a flapping
        // failure is only diagnosable from a trail of snapshots — one screenshot
        // of an alert is not enough to tell a boot race from a broken boot.
        handleConsoleLog("WARN: [CONN_DIAG] \(callable) probe=\(probe.health.rawValue) \(probe.digest)")
        if let raw = probe.raw {
            handleConsoleLog("WARN: [CONN_DIAG] \(callable) probe raw: \(raw)")
        }
        let digest = probe.digest.isEmpty ? rawDescription : "\(probe.digest) | was: \(rawDescription)"

        switch probe.health {
        case .contextDead:
            let healed = await healWebContext(reason: "\(callable): \(rawDescription)")
            return healed
                ? "web-context-dead: the app's web layer stopped responding and was reloaded automatically — try again in a few seconds. (\(digest))"
                : "web-context-dead: the app's web layer is not responding; a reload was already attempted recently. (\(digest))"
        case .webCrashed:
            let healed = await healWebContext(reason: "\(callable): web app crashed")
            return healed
                ? "web-crashed: the app hit an internal error and was reloaded automatically — try again in a few seconds. (\(digest))"
                : "web-crashed: the app hit an internal error; a reload was already attempted recently. (\(digest))"
        case .callablesMissing:
            // Genuinely mid-boot: young document, boot chain still running.
            // "Try again in a moment" is honest here and only here.
            return "not-ready: the app's web layer is still starting up — try again in a moment. (\(digest))"
        case .callablesAbsent:
            // The page finished loading WITHOUT its native bridge. Retrying
            // cannot fix this, so heal rather than telling the user to wait.
            let healed = await healWebContext(reason: "\(callable): callables absent after boot — \(probe.digest)")
            return healed
                ? "callables-absent: the app's web layer loaded without its native bridge and was reloaded automatically — try again in a few seconds. (\(digest))"
                : "callables-absent: the app's web layer loaded without its native bridge; a reload was already attempted recently. (\(digest))"
        case .noWebView:
            return "no-web-view: no web view is attached. (\(digest))"
        case .healthy:
            // The context is fine — the failure is in the call itself. Attach
            // the web diagnostics snapshot to the console log for forensics.
            if let diag = await fetchWebDiagnostics() {
                handleConsoleLog("WARN: [CONN_DIAG] web context healthy; diagnostics: \(diag)")
            }
            return rawDescription
        }
    }

    // MARK: - WebView Health & Crash Diagnostics

    /// Called by AgentWebView when the web content process is terminated by the OS.
    /// Records the event, logs it to the bridge console, and reloads.
    public func recordProcessTermination() {
        sessionCrashCount += 1

        // Capture memory stats at crash time
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        var rss: Double = 0
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if kr == KERN_SUCCESS { rss = Double(info.resident_size) / 1_048_576 }

        #if os(iOS)
        let avail = Double(os_proc_available_memory()) / 1_048_576
        #else
        let avail = Double(ProcessInfo.processInfo.physicalMemory) / 1_048_576
        #endif

        let thermal: String = {
            switch ProcessInfo.processInfo.thermalState {
            case .nominal: return "Nominal"
            case .fair: return "Fair"
            case .serious: return "Serious"
            case .critical: return "Critical"
            @unknown default: return "Unknown"
            }
        }()

        let event = WebViewCrashEvent(
            id: UUID(),
            timestamp: Date(),
            appMemoryMB: rss,
            availableMemoryMB: avail,
            thermalState: thermal,
            url: webView?.url?.absoluteString,
            wasConnected: isConnected,
            crashNumber: sessionCrashCount
        )
        crashEvents.append(event)
        persistCrashEvents()

        // Log to bridge console (visible in Console Logs viewer)
        let msg = String(format:
            "ERROR: [CRASH] Web content process terminated (#%d this session). RSS=%.0fMB Avail=%.0fMB Thermal=%@ URL=%@ Bridge=%@",
            sessionCrashCount, rss, avail, thermal,
            webView?.url?.absoluteString ?? "nil",
            isConnected ? "connected" : "disconnected"
        )
        handleConsoleLog(msg)

        // Schedule a post-crash probe once the bridge reconnects
        pendingPostCrashProbe = true

        // Reload to recover — but ONLY while foregrounded. A content-process
        // termination almost always happens while backgrounded (jetsam), and a
        // WKWebView won't load while suspended, so an unconditional reload here
        // is dropped and the app returns still-dead. Defer to foreground.
        recoveryReload(label: "post-crash reload") { [weak self] in self?.reload() }
    }

    /// Probe the web view from the native side. Layer 1 (native properties) always
    /// works. Layer 2 (JS probes) only succeeds if the JS context is alive.
    /// Results are logged to the bridge console and persisted to UserDefaults.
    @discardableResult
    public func probeWebViewHealth(trigger: String = "manual") async -> WebViewHealthReport {
        // Layer 1: Native-side properties
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        var rss: Double = 0
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if kr == KERN_SUCCESS { rss = Double(info.resident_size) / 1_048_576 }

        #if os(iOS)
        let avail = Double(os_proc_available_memory()) / 1_048_576
        #else
        let avail = Double(ProcessInfo.processInfo.physicalMemory) / 1_048_576
        #endif

        let thermal: String = {
            switch ProcessInfo.processInfo.thermalState {
            case .nominal: return "Nominal"
            case .fair: return "Fair"
            case .serious: return "Serious"
            case .critical: return "Critical"
            @unknown default: return "Unknown"
            }
        }()

        let wvExists = webView != nil
        let url = webView?.url?.absoluteString
        let title = webView?.title
        let loading = webView?.isLoading ?? false
        let progress = webView?.estimatedProgress ?? 0

        // Layer 2: JS context probe
        var jsAlive = false
        var domNodes: Int?
        var readyState: String?
        var activeChat: String?
        var sessLoaded: Int?
        var sessTotal: Int?
        var sessBytes: Int?
        var cKeys: Int?

        if wvExists {
            do {
                let result = try await callAsyncJavaScript("""
                    var r = {};
                    r.canary = 1 + 1;
                    r.domNodes = document.querySelectorAll('*').length;
                    r.readyState = document.readyState;
                    try {
                        var loc = window.location.hash || window.location.pathname;
                        var m = loc.match(/chat[/=]([^&/#]+)/i);
                        r.activeChat = m ? m[1] : null;
                    } catch(e) { r.activeChat = null; }
                    try {
                        if (window.__memoryStats) {
                            var s = window.__memoryStats();
                            r.sessLoaded = s.chatsLoadedInMemory;
                            r.sessTotal = s.totalChatsInIndex;
                            r.sessBytes = s.estimatedMemoryBytes;
                            r.cacheKeys = s.totalMemoryCacheKeys;
                        }
                    } catch(e) {}
                    return r;
                """)
                if let dict = result as? [String: Any], dict["canary"] as? Int == 2 {
                    jsAlive = true
                    domNodes = dict["domNodes"] as? Int
                    readyState = dict["readyState"] as? String
                    activeChat = dict["activeChat"] as? String
                    sessLoaded = dict["sessLoaded"] as? Int
                    sessTotal = dict["sessTotal"] as? Int
                    sessBytes = dict["sessBytes"] as? Int
                    cKeys = dict["cacheKeys"] as? Int
                }
            } catch {
                // JS context is dead
                jsAlive = false
            }
        }

        let report = WebViewHealthReport(
            id: UUID(),
            timestamp: Date(),
            trigger: trigger,
            webViewExists: wvExists,
            currentURL: url,
            pageTitle: title,
            isLoading: loading,
            estimatedProgress: progress,
            bridgeConnected: isConnected,
            loadError: loadError,
            appMemoryMB: rss,
            availableMemoryMB: avail,
            thermalState: thermal,
            crashCount: sessionCrashCount,
            jsContextAlive: jsAlive,
            domNodeCount: domNodes,
            documentReadyState: readyState,
            activeSessionId: activeChat,
            sessionsInMemory: sessLoaded,
            sessionsTotal: sessTotal,
            sessionMemoryBytes: sessBytes,
            cacheKeys: cKeys
        )

        // Emit to console logs
        emitHealthReportToConsole(report)

        // Persist
        healthReports.append(report)
        persistHealthReports()

        return report
    }

    private func emitHealthReportToConsole(_ r: WebViewHealthReport) {
        var lines: [String] = []
        lines.append("[\(r.trigger.uppercased()) PROBE] WebView Health Report")
        lines.append("  JS Context: \(r.jsContextAlive ? "Alive" : "DEAD")")
        lines.append("  Bridge: \(r.bridgeConnected ? "Connected" : "Disconnected")")
        lines.append("  WebView: \(r.webViewExists ? "Exists" : "NIL")")
        lines.append(String(format: "  App RSS: %.0f MB", r.appMemoryMB))
        lines.append(String(format: "  Available: %.0f MB", r.availableMemoryMB))
        lines.append("  Thermal: \(r.thermalState)")
        if let nodes = r.domNodeCount {
            lines.append("  DOM Nodes: \(nodes)\(nodes > 20000 ? " [HIGH]" : nodes > 10000 ? " [ELEVATED]" : "")")
        }
        if let state = r.documentReadyState { lines.append("  Ready State: \(state)") }
        if let url = r.currentURL { lines.append("  URL: \(url)") }
        if let chat = r.activeSessionId { lines.append("  Active Chat: \(chat)") }
        if let loaded = r.sessionsInMemory, let total = r.sessionsTotal {
            lines.append("  Sessions: \(loaded)/\(total) loaded")
        }
        if let bytes = r.sessionMemoryBytes {
            lines.append(String(format: "  Session Memory: %.1f MB", Double(bytes) / 1_048_576))
        }
        if let keys = r.cacheKeys { lines.append("  Cache Keys: \(keys)") }
        if r.crashCount > 0 { lines.append("  Crashes (session): \(r.crashCount)") }
        if let err = r.loadError { lines.append("  Load Error: \(err)") }

        let level = r.jsContextAlive ? "LOG" : "ERROR"
        handleConsoleLog("\(level): \(lines.joined(separator: "\n"))")
    }

    /// Clear persisted crash events.
    public func clearCrashEvents() {
        crashEvents.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.crashEventsKey)
    }

    /// Clear persisted health reports.
    public func clearHealthReports() {
        healthReports.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.healthReportsKey)
    }

    // MARK: - Receive messages from web app

    public func handleMessage(_ body: Any) {
        guard let dict = body as? [String: Any],
              let type = dict["type"] as? String,
              type.hasPrefix(messagePrefix) else {
            NSLog("[AgentBridge] Received non-bridge message: %@", String(describing: body))
            return
        }

        let messageType = String(type.dropFirst(messagePrefix.count))
        if AgentBridge.verboseBridgeLog {
            NSLog("[AgentBridge] ← Received: %@", messageType)
        }

        switch messageType {
        case "handshake":
            handleHandshake(dict)
        case "host:info":
            handleHostInfo(dict)
        case "mcp:discover":
            handleMCPDiscover(dict)
        case "mcp:invoke":
            handleMCPInvoke(dict)
        case "llm:generate":
            handleLLMGenerate(dict)
        case "theme:ready":
            NSLog("[AgentBridge] Theme ready received")
            isThemeReady = true
        case "sessions:ready":
            NSLog("[AgentBridge] Sessions ready received")
            isSessionsReady = true
        case "search:click":
            handleSearchClick(dict)
        case "widget:minimize":
            wantsMinimize = true
        case "widget:restore":
            wantsMinimize = false
        case "theme:set:ack":
            break
        case "scroll:state":
            handleScrollState(dict)
        case "masthead:config":
            handleMastheadConfig(dict)
        case "chatInput:config":
            chatInputGlassStyle = dict["glassStyle"] as? String
            chatInputLayout = dict["layout"] as? String
            chatInputShowTodos = dict["showTodos"] as? Bool ?? true
            chatInputShowQuickCommands = dict["showQuickCommands"] as? Bool ?? true
        case "sessions:list:response":
            handleSessionsListResponse(dict)
        case "chat:new:ack":
            handleChatNewAck(dict)
        case "capability":
            handleCapabilityRequest(dict)
        case "capability:ping":
            handleCapabilityPing(dict)
        case "host-prefs:set":
            handleHostPrefsSet(dict)
        case "host-token:set":
            handleHostTokenSet(dict)
        case "agent:turnStarted":
            handleLifecycleEvent(.running, dict: dict)
        case "agent:turnAwaitingInput":
            handleLifecycleEvent(.awaitingInput, dict: dict)
        case "agent:turnResumed":
            handleLifecycleEvent(.running, dict: dict)
        case "agent:turnCompleted":
            handleLifecycleEvent(.completed, dict: dict)
        case "agent:turnFailed":
            handleLifecycleEvent(.failed, dict: dict)
        case "agent:stateSnapshot":
            handleLifecycleSnapshot(dict)
        case "agent:status":
            // Ignore stale pushes during web app initialization — the pull-based
            // syncAgentStatus (run after connection) is the authoritative source.
            guard initialStatusSyncComplete else {
                return
            }
            // The push carries the chatId it is ABOUT (the web's active chat,
            // which may not be ours) — apply it per-chat, never to the active
            // chat's flags directly.
            guard let chatId = dict["chatId"] as? String, !chatId.isEmpty else {
                return
            }
            let running = dict["isRunning"] as? Bool ?? false
            let paused = dict["isPaused"] as? Bool ?? false
            if sessionLifecycleSequences[chatId] != nil {
                // This chat has lifecycle-event history — events are the primary
                // source of truth, but if agent:status disagrees (e.g. web says
                // not-running while we still show running), the final lifecycle
                // message may have been lost. Arbitrate via a chat-scoped pull.
                let current = chatTurnPhases[chatId]
                let statusSaysNotRunning = !running && current == .running
                let statusSaysPaused = paused && current != .awaitingInput
                if statusSaysNotRunning || statusSaysPaused {
                    Task { await syncAgentStatus(chatId: chatId) }
                }
            } else if running || paused {
                applySessionPhase(paused ? .awaitingInput : .running, chatId: chatId, sequence: nil, timestamp: dict["timestamp"])
            } else if chatTurnPhases[chatId] == .running || chatTurnPhases[chatId] == .awaitingInput {
                // Status-only chat whose last status said running — clear it.
                applySessionPhase(.completed, chatId: chatId, sequence: nil, timestamp: dict["timestamp"])
            }
        case "agent:activity":
            if let eventDict = dict["event"] as? [String: Any],
               let event = AgentActivityEvent.from(dict: eventDict) {
                latestActivity = event
                // Track Edit tool file paths for the "Recently Edited" section on
                // the Files screen. toolFilePath is an extension field on the wire
                // event that isn't carried by the Swift enum, so read it here.
                if let toolName = eventDict["toolName"] as? String, toolName == "Edit",
                   let filePath = eventDict["toolFilePath"] as? String, !filePath.isEmpty {
                    sessionList.recordRecentlyEditedFile(filePath)
                }
                if let chatId = dict["chatId"] as? String, !chatId.isEmpty {
                    // Stamp last-active time for sort order, but only if the
                    // event is genuinely fresher than the existing value —
                    // replays/snapshots carry the original action's timestamp,
                    // so we don't bump idle sessions to the top on host
                    // restart or cross-device sync.
                    advanceLastActive(chatId: chatId, eventTimestamp: dict["timestamp"])

                    // Session-row actions are stored separately — they persist
                    // across turns and are not part of the tool-activity subtitle.
                    if case .sessionAction(let actions) = event {
                        sessionList.sessionActionsByChatId[chatId] = actions
                    } else {
                        let toolName: String?
                        switch event {
                        case .toolStart(let name, _, _, _): toolName = name
                        case .toolEnd(let name, _, _, _, _): toolName = name
                        default: toolName = nil
                        }
                        if toolName == "completion" || toolName == "TodoWrite" {
                            sessionList.latestActivityByChatId.removeValue(forKey: chatId)
                            // A "completion" activity is a strong signal the turn
                            // ended. If the lifecycle event was lost, the button is
                            // stuck on pause — pull the authoritative state now.
                            if toolName == "completion" && isAgentRunning {
                                Task { [weak self] in await self?.syncAgentStatus() }
                            }
                        } else if isFreshActivityTimestamp(dict["timestamp"]) {
                            // Latch on both `.toolStart` and `.toolEnd` — Claude
                            // CLI tool actions come through as a single `.toolEnd`
                            // with status=success (never `.toolStart`), so filtering
                            // to start-only drops every CLI tool call. Between-turn
                            // sticking is prevented by clearing on completed/failed
                            // in applySessionPhase. Replayed (old-timestamp) events
                            // are skipped so a finished-offline turn doesn't show a
                            // stale live subtitle that never clears.
                            sessionList.latestActivityByChatId[chatId] = event
                        }
                    }
                }
            }
        case "todos:update":
            handleTodoStateUpdate(dict)
        case "chat:status":
            if let message = dict["message"] as? String {
                let chatId = dict["chatId"] as? String ?? "unknown"
                let persistent = dict["persistent"] as? Bool ?? false
                let entry = ChatStatusEntry(timestamp: Date(), chatId: chatId, message: message)
                chatStatusLog.append(entry)
                if chatStatusLog.count > maxChatStatusEntries {
                    chatStatusLog.removeFirst(chatStatusLog.count - maxChatStatusEntries)
                }
                if persistent {
                    chatStatus.persistentChatStatus = message
                } else {
                    chatStatus.latestChatStatus = message
                }
            }
        case "chat:message":
            handleNativeChatMessage(dict)
        case "chat:prefill":
            pendingInputText = dict["text"] as? String
        case "chat:append":
            pendingInputAppend = dict["text"] as? String
        case "link:open":
            if let urlString = dict["url"] as? String, let url = URL(string: urlString) {
                NSLog("[AgentBridge] Link open — url: %@", urlString)
                linkOpenDelegate?.agentBridge(self, didRequestOpenLink: url)
            }
        case "file:view":
            if let filePath = dict["filePath"] as? String {
                let content = dict["content"] as? String
                let language = dict["language"] as? String
                NSLog("[AgentBridge] File view — path: %@", filePath)
                pendingFileView = FileViewRequest(
                    id: UUID().uuidString,
                    filePath: filePath,
                    content: content,
                    language: language
                )
            }
        case "fileViewer:expand":
            let title = dict["title"] as? String
            let isMarkdown = dict["isMarkdown"] as? Bool ?? false
            let filePath = dict["filePath"] as? String
            NSLog("[AgentBridge] File viewer expand — title: %@, isMarkdown: %d, path: %@", title ?? "nil", isMarkdown, filePath ?? "nil")
            fileViewerExpanded = true
            fileViewerTitle = title
            fileViewerIsMarkdown = isMarkdown
            fileViewerFilePath = filePath
        case "fileViewer:collapse":
            NSLog("[AgentBridge] File viewer collapse")
            fileViewerExpanded = false
            fileViewerTitle = nil
            fileViewerIsMarkdown = false
            fileViewerFilePath = nil
        case "page:context":
            let page = dict["page"] as? String ?? "chat"
            let showHeader = dict["showNativeHeader"] as? Bool ?? true
            let showInput = dict["showNativeChatInput"] as? Bool ?? true
            let showControls = dict["showSessionControls"] as? Bool ?? true
            let safeArea = dict["safeAreaMode"] as? String ?? "full"
            NSLog("[AgentBridge] Page context — page: %@, header: %d, input: %d, controls: %d, safeArea: %@",
                  page, showHeader, showInput, showControls, safeArea)
            currentPageContext = PageContext(
                page: page,
                showNativeHeader: showHeader,
                showNativeChatInput: showInput,
                showSessionControls: showControls,
                safeAreaMode: safeArea
            )
        case "userInteraction:multiChoice":
            handleUserInteractionMultiChoice(dict)
        case "userInteraction:text":
            handleUserInteractionText(dict)
        case "userInteraction:date":
            handleUserInteractionDate(dict)
        case "getConsoleLogs":
            let requestId = dict["requestId"] as? String ?? ""
            // Native logs live in the host-owned RipulLog buffer (so they exist from
            // launch, before this bridge did); web console lines live here. The relay's
            // device_console_logs promises both, so merge by timestamp.
            let logs = RipulLog.merged(with: consoleLogs).map { e -> [String: Any] in
                var entry: [String: Any] = [
                    "level": e.level,
                    "message": e.message,
                    "ts": Int64(e.timestamp.timeIntervalSince1970 * 1000)
                ]
                if let stack = e.stack { entry["stack"] = stack }
                return entry
            }
            if let data = try? JSONSerialization.data(withJSONObject: logs),
               let json = String(data: data, encoding: .utf8) {
                evaluateJavaScript("window.__agentBridgeReceive({type:'agent-framework:consoleLogs:response',requestId:'\(requestId)',logs:\(json)})")
            }
        case "getNetworkLogs":
            let requestId = dict["requestId"] as? String ?? ""
            let logs = networkLogs.map { e -> [String: Any] in
                var entry: [String: Any] = [
                    "method": e.method,
                    "url": e.url,
                    "status": e.status,
                    "statusText": e.statusText,
                    "durationMs": e.durationMs,
                    "requestSize": e.requestSize,
                    "responseSize": e.responseSize,
                    "reqHeaders": e.requestHeaders,
                    "resHeaders": e.responseHeaders,
                    "ts": Int64(e.timestamp.timeIntervalSince1970 * 1000)
                ]
                if let error = e.error { entry["error"] = error }
                return entry
            }
            if let data = try? JSONSerialization.data(withJSONObject: logs),
               let json = String(data: data, encoding: .utf8) {
                evaluateJavaScript("window.__agentBridgeReceive({type:'agent-framework:networkLogs:response',requestId:'\(requestId)',logs:\(json)})")
            }
        case "kill":
            let reason = dict["reason"] as? String ?? "remote_user"
            NSLog("[AgentBridge] Kill command received (reason: %@) — exiting for guardian restart", reason)
            #if os(macOS)
            // _exit() terminates immediately — no cleanup handlers, no quit file.
            // The guardian (in its own process group) detects the exit and restarts.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                _exit(0)
            }
            #endif
        default:
            if onUnhandledMessage?(messageType, dict) != true {
                NSLog("[AgentBridge] Unhandled message: %@", messageType)
            }
        }
    }

    private var jsErrorMessages: [String] = []
    private var jsErrorDebounce: DispatchWorkItem?

    /// Detailed error log for the user to copy and share with the developer.
    @Published public var loadErrorDetails: String?

    /// Rolling buffer of captured JS console messages.
    /// Not @Published — appended on every JS console.log (potentially dozens per second).
    /// Only consumed by debug views (ConsoleLogViewer, SettingsScreen error badge).
    /// ConsoleLogViewer subscribes to consoleLogsSubject for real-time updates.
    public var consoleLogs: [ConsoleLogEntry] = [] {
        didSet { consoleLogsSubject.send(()) }
    }
    /// Dedicated publisher for consoleLogs changes (replaces implicit @Published).
    public let consoleLogsSubject = PassthroughSubject<Void, Never>()
    private let maxLogEntries = 5000

    // MARK: - Persistent Console Logs

    private static let persistErrorLogsKey = "ripulPersistErrorLogs"
    private static let persistAllLogsKey = "ripulPersistAllLogs"
    private static let persistedErrorLogsKey = "ripulPersistedErrorLogs"
    private static let maxPersistedErrorLogs = 500
    private static let maxPersistedAllLogs = 2000

    /// When true, WARN and ERROR log entries are persisted to UserDefaults.
    public var isPersistErrorLogsEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.persistErrorLogsKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.persistErrorLogsKey) }
    }

    /// When true, ALL log entries are persisted to UserDefaults (for crash diagnosis).
    public var isPersistAllLogsEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.persistAllLogsKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.persistAllLogsKey) }
    }

    /// Restore persisted logs into the in-memory buffer on launch.
    /// Call once from the app's entry point after creating the bridge.
    public func loadPersistedErrorLogs() {
        guard isPersistErrorLogsEnabled || isPersistAllLogsEnabled else { return }
        guard let data = UserDefaults.standard.data(forKey: Self.persistedErrorLogsKey),
              let entries = try? JSONDecoder().decode([ConsoleLogEntry].self, from: data),
              !entries.isEmpty else { return }
        let separator = ConsoleLogEntry(
            timestamp: Date(), level: "LOG",
            message: "--- Restored \(entries.count) persisted logs from previous session ---"
        )
        consoleLogs.insert(contentsOf: entries + [separator], at: 0)
    }

    private var persistedLogsDirty = false
    private var persistDebounce: DispatchWorkItem?

    private func appendToPersistedLogs(_ entry: ConsoleLogEntry) {
        let persistAll = isPersistAllLogsEnabled
        let persistErrors = isPersistErrorLogsEnabled
        guard persistAll || persistErrors else { return }

        // In errors-only mode, skip LOG entries
        if !persistAll && entry.level == "LOG" { return }

        persistedLogsDirty = true
        persistDebounce?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.persistedLogsDirty else { return }
            self.persistedLogsDirty = false
            self.flushPersistedLogs()
        }
        persistDebounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: item)
    }

    private func flushPersistedLogs() {
        let persistAll = isPersistAllLogsEnabled
        let cap = persistAll ? Self.maxPersistedAllLogs : Self.maxPersistedErrorLogs

        var existing: [ConsoleLogEntry] = []
        if let data = UserDefaults.standard.data(forKey: Self.persistedErrorLogsKey) {
            existing = (try? JSONDecoder().decode([ConsoleLogEntry].self, from: data)) ?? []
        }
        let existingIds = Set(existing.map(\.id))
        let newEntries = consoleLogs.filter { entry in
            !existingIds.contains(entry.id) &&
            (persistAll || entry.level == "ERROR" || entry.level == "WARN")
        }
        guard !newEntries.isEmpty else { return }
        let combined = Array((existing + newEntries).suffix(cap))
        if let data = try? JSONEncoder().encode(combined) {
            UserDefaults.standard.set(data, forKey: Self.persistedErrorLogsKey)
        }
    }

    /// Clear persisted logs from UserDefaults.
    public func clearPersistedErrorLogs() {
        UserDefaults.standard.removeObject(forKey: Self.persistedErrorLogsKey)
    }

    // MARK: - Network Log Capture

    private static let networkCaptureKey = "ripulNetworkCaptureEnabled"

    /// Whether network request capture is active. Persisted in UserDefaults.
    /// Defaults to false — the user must opt in via the Network tab.
    public var isNetworkCaptureEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.networkCaptureKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.networkCaptureKey)
            // Tell the web view to start/stop intercepting
            evaluateVoidJavaScript("window.__ripulNetworkCapture && window.__ripulNetworkCapture(\(newValue))")
        }
    }

    /// Rolling buffer of captured network requests.
    public var networkLogs: [NetworkLogEntry] = [] {
        didSet { networkLogsSubject.send(()) }
    }
    public let networkLogsSubject = PassthroughSubject<Void, Never>()

    public func handleNetworkLog(_ body: Any) {
        guard let dict = body as? [String: Any] else { return }
        let method = dict["method"] as? String ?? "GET"
        let url = dict["url"] as? String ?? ""
        let status = dict["status"] as? Int ?? 0
        let statusText = dict["statusText"] as? String ?? ""
        let durationMs = dict["duration"] as? Int ?? -1
        let requestSize = dict["reqSize"] as? Int ?? -1
        let responseSize = dict["resSize"] as? Int ?? -1
        let reqHeaders = dict["reqHeaders"] as? [String: String] ?? [:]
        let resHeaders = dict["resHeaders"] as? [String: String] ?? [:]
        let error = dict["error"] as? String

        if networkLogs.count >= maxLogEntries {
            networkLogs.removeAll(keepingCapacity: true)
        }
        networkLogs.append(NetworkLogEntry(
            timestamp: Date(), method: method, url: url,
            status: status, statusText: statusText, durationMs: durationMs,
            requestSize: requestSize, responseSize: responseSize,
            requestHeaders: reqHeaders, responseHeaders: resHeaders,
            error: error
        ))
    }

    public func clearNetworkLogs() {
        networkLogs.removeAll()
    }

    /// Rolling buffer of CLI pipeline status messages for native diagnostic display.
    /// Not @Published — appended frequently and only consumed by ChatStatusLogView sheet.
    /// Views see updates whenever any other @Published property triggers a re-render,
    /// or via the dedicated subject.
    public var chatStatusLog: [ChatStatusEntry] = [] {
        didSet { chatStatusLogSubject.send(()) }
    }
    /// Dedicated publisher for chatStatusLog changes (replaces implicit @Published).
    public let chatStatusLogSubject = PassthroughSubject<Void, Never>()
    /// Chat-status line fields (latest / persistent), isolated onto their own leaf
    /// so per-pipeline-stage writes don't re-render the WKWebView host. Access as
    /// `chatStatus.latestChatStatus` / `chatStatus.persistentChatStatus`.
    public let chatStatus = ChatStatusStore()
    private let maxChatStatusEntries = 200

    /// Unified log sink for both web-view and native-originated log entries.
    ///
    /// Receives log entries from two sources:
    ///   - Web-view console.* calls, forwarded via the agentLog WKScriptMessageHandler
    ///     registered in AgentWebView (intercepts every console.log/warn/error call).
    ///   - Swift code calling this method directly to inject native log lines into the
    ///     same buffer (e.g. SessionManager startup timeline, relay listRemoteSessions).
    ///
    /// The consoleLogs array is what device_console_logs exposes — it is a single
    /// unified stream of both web and native log output.
    public func handleConsoleLog(_ message: String) {
        // Intercept the curtainLowered signal emitted by V2ChatScroller when the
        // new chat's pre-warm sweep finishes. Restore wkWebView.alpha to reveal
        // the new chat cleanly. This message is posted via agentLog so it shares
        // the existing message channel without needing a new handler registration.
        // Foundation.* so the NSLog tee shadow doesn't re-ingest what we're already
        // appending below (would double-append + recurse). Gated: this fires once
        // per bridged web console.log, which floods during streaming; NSLog is
        // synchronous main-thread I/O and invisible on-device without Xcode. The
        // in-app buffer append below is the on-device log path and stays live.
        if AgentBridge.verboseBridgeLog {
            Foundation.NSLog("[JS] %@", message)
        }

        // Split off stack trace if present (appended after __STACK__ separator)
        let mainMessage: String
        let stack: String?
        if let stackRange = message.range(of: "\n__STACK__\n") {
            mainMessage = String(message[message.startIndex..<stackRange.lowerBound])
            let rawStack = String(message[stackRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            stack = rawStack.isEmpty ? nil : rawStack
        } else {
            mainMessage = message
            stack = nil
        }

        // Parse level prefix ("LOG: ...", "WARN: ...", "ERROR: ...")
        let level: String
        let body: String
        if let colonIdx = mainMessage.firstIndex(of: ":") {
            let prefix = String(mainMessage[mainMessage.startIndex..<colonIdx])
            if ["LOG", "WARN", "ERROR"].contains(prefix) {
                level = prefix
                body = String(mainMessage[mainMessage.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
            } else {
                level = "LOG"
                body = mainMessage
            }
        } else {
            level = "LOG"
            body = mainMessage
        }

        // Hard clear at the cap rather than rolling-buffer trim. A rolling buffer
        // calls removeFirst() on every append past the cap (O(n) each time); under
        // the log floods we've seen from the native poll loop that thrashes the
        // array and pegs the main actor. Clearing outright gives one O(n) op per
        // 5000 entries instead of one per entry. Losing older history at the cap
        // is acceptable — this buffer is only for debug views.
        if consoleLogs.count >= maxLogEntries {
            consoleLogs.removeAll(keepingCapacity: true)
        }
        let entry = ConsoleLogEntry(timestamp: Date(), level: level, message: body, stack: stack)
        consoleLogs.append(entry)

        // Persist entries if a persistence setting is enabled
        appendToPersistedLogs(entry)

        // Collect JS errors that occur before the bridge connects.
        // Wait long enough for the bridge to finish its normal handshake
        // before surfacing an error — transient startup errors are common
        // and don't mean the app is broken.
        if !isConnected && level == "ERROR" {
            jsErrorMessages.append(body)

            jsErrorDebounce?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self, !self.isConnected else { return }
                self.loadError = "Something went wrong loading the app."
                self.loadErrorDetails = self.jsErrorMessages.joined(separator: "\n")
            }
            jsErrorDebounce = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: item)
        }
    }

    public func clearConsoleLogs() {
        consoleLogs.removeAll()
        // Also wipe the BlackBox crash/trail records persisted in the web app's
        // localStorage so the trash icon clears ephemeral AND persisted logs.
        // Keys must match chrome-extension/src/logging/hooks/useFlowSettings.ts.
        evaluateJavaScript("""
        try {
          localStorage.removeItem('__ripulCrashLog');
          localStorage.removeItem('__ripulLastVirtuosoOp');
          localStorage.removeItem('__ripulBlackBoxTrail');
        } catch (_) {}
        """)
    }

    public func clearChatStatusLog() {
        chatStatusLog.removeAll()
        chatStatus.latestChatStatus = nil
        chatStatus.persistentChatStatus = nil
    }

    /// Emit a `[SESSION-START]` marker into both NSLog and the unified consoleLogs
    /// buffer so it shows up in `device_console_logs` / `host_console_logs` alongside
    /// the web-side stages. Used to instrument the native side of the
    /// tap → input-ready window when investigating new-chat latency.
    public func logSessionStartMarker(_ stage: String, chatId: String? = nil, extra: String = "") {
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        let chatStr = chatId.map { " chatId=\($0)" } ?? ""
        let extraStr = extra.isEmpty ? "" : " \(extra)"
        let line = "[SESSION-START] stage=\(stage) ts=\(ts)\(chatStr)\(extraStr)"
        NSLog("%@", line)
        handleConsoleLog("WARN: \(line)")
    }

    /// Start a new chat with an optional prompt via the bridge protocol.
    /// The web app handles chat creation and prompt auto-execution.
    public func startNewChat(prompt: String? = nil) async {
        guard let webView else {
            NSLog("[AgentBridge] Cannot startNewChat — webView is nil")
            return
        }
        NSLog("[AgentBridge] → Starting new chat (prompt: %@)", prompt != nil ? "yes" : "no")
        do {
            let result = try await webView.callAsyncJavaScript(
                """
                if (!window.__ripulCreateChat) return { success: false, error: '__ripulCreateChat not defined' };
                return await window.__ripulCreateChat();
                """,
                contentWorld: .page
            )
            if let dict = result as? [String: Any],
               let chatId = dict["chatId"] as? String {
                NSLog("[AgentBridge] New chat created: %@", chatId)
                // Point the button projection at the new chat immediately —
                // without this, a running previous chat's pause button carries
                // over onto the brand-new (idle) chat until the sessions push
                // catches up.
                pendingActiveSourceChatId = chatId
                refreshActiveAgentFlags()
                if let prompt {
                    _ = try? await webView.callAsyncJavaScript(
                        "return await window.__ripulSubmitMessage?.(text) ?? { success: false }",
                        arguments: ["text": prompt],
                        contentWorld: .page
                    )
                }
                await fetchSessions()
            } else {
                NSLog("[AgentBridge] startNewChat failed: %@", String(describing: result))
            }
        } catch {
            NSLog("[AgentBridge] startNewChat error: %@", error.localizedDescription)
        }
    }

    /// Submit a message to the active chat session via the web app's
    /// global `__ripulSubmitMessage` callable.
    /// - Parameters:
    ///   - text: The message text.
    ///   - imageAttachments: Optional array of base64-encoded images.
    ///     Each element must have keys: `id`, `mediaType`, `data`, and optionally `name`.
    ///   - addressedTo: Optional array of participant IDs picked from the native
    ///     @-mention picker. Populates `addressedTo` on the resulting chat action
    ///     so LLMProxy can route the turn to the correct agent.
    @available(iOS 15.0, macOS 13.0, *)
    @discardableResult
    public func submitMessage(
        _ text: String,
        imageAttachments: [[String: String]]? = nil,
        addressedTo: [String]? = nil
    ) async -> Bool {
        guard let webView else { return false }
        do {
            var args: [String: Any] = ["text": text]
            let hasImages = (imageAttachments?.isEmpty == false)
            let hasAddressedTo = (addressedTo?.isEmpty == false)
            let script: String
            if hasImages && hasAddressedTo {
                args["images"] = imageAttachments!
                args["addressedTo"] = addressedTo!
                script = "return await window.__ripulSubmitMessage?.(text, images, addressedTo) ?? { success: false }"
            } else if hasImages {
                args["images"] = imageAttachments!
                script = "return await window.__ripulSubmitMessage?.(text, images) ?? { success: false }"
            } else if hasAddressedTo {
                args["addressedTo"] = addressedTo!
                script = "return await window.__ripulSubmitMessage?.(text, undefined, addressedTo) ?? { success: false }"
            } else {
                script = "return await window.__ripulSubmitMessage?.(text) ?? { success: false }"
            }
            let result = try await webView.callAsyncJavaScript(
                script,
                arguments: args,
                contentWorld: .page
            )
            if let dict = result as? [String: Any] {
                return dict["success"] as? Bool ?? false
            }
            return false
        } catch {
            NSLog("[AgentBridge] submitMessage error: %@", error.localizedDescription)
            return false
        }
    }

    /// Send a human note to the chat stream. Notes appear as first-class panels
    /// but are NOT sent to the agent — they are for human-to-human communication.
    @available(iOS 15.0, macOS 13.0, *)
    @discardableResult
    public func submitNote(_ text: String) async -> Bool {
        guard let webView else { return false }
        do {
            // senderDisplayName is resolved on the web side from the logged-in Clerk user
            let script = "return await window.__ripulSubmitNote?.(text) ?? { success: false }"
            let result = try await webView.callAsyncJavaScript(
                script,
                arguments: ["text": text],
                contentWorld: .page
            )
            if let dict = result as? [String: Any] {
                return dict["success"] as? Bool ?? false
            }
            return false
        } catch {
            NSLog("[AgentBridge] submitNote error: %@", error.localizedDescription)
            return false
        }
    }

    /// Set CLI plan mode (read-only analysis, no file edits).
    /// Calls the onPlanModeChanged callback (primary — direct server access)
    /// and also tries the JS bridge path as a fallback.
    @available(iOS 15.0, macOS 13.0, *)
    public func setCliPlanMode(_ enabled: Bool) async {
        // Primary path: direct native callback (no JS involved)
        onPlanModeChanged?(enabled)
        NSLog("[AgentBridge] setCliPlanMode: enabled=%@, hasCallback=%@", enabled ? "true" : "false", onPlanModeChanged != nil ? "true" : "false")

        // Secondary path: also set localStorage via JS for the web app CLI handler
        guard let webView else { return }
        do {
            _ = try await webView.callAsyncJavaScript(
                "try { localStorage.setItem('cliPlanMode', enabled ? 'true' : 'false'); } catch(e) {} return true;",
                arguments: ["enabled": enabled],
                contentWorld: .page
            )
        } catch {
            NSLog("[AgentBridge] setCliPlanMode localStorage error: %@", error.localizedDescription)
        }
    }

    /// Interrupt (pause) the currently running agent for the active session.
    @available(iOS 15.0, macOS 13.0, *)
    @discardableResult
    public func interruptAgent() async -> Bool {
        guard let webView else { return false }
        // Interrupt the chat the NATIVE UI is showing — the web's own notion of
        // "active chat" can lag ours, and interrupting whatever it happens to be
        // on is how a pause tap used to no-op against an empty chat while the
        // genuinely-running one kept going.
        let target = activeSourceChatId
        do {
            let result = try await webView.callAsyncJavaScript(
                "return await window.__ripulInterruptAgent?.(targetChatId) ?? { success: false }",
                arguments: ["targetChatId": target.map { $0 as Any } ?? NSNull()],
                contentWorld: .page
            )
            if let dict = result as? [String: Any] {
                let success = dict["success"] as? Bool ?? false
                if success, let target {
                    // Optimistically mark the turn over so the button clears
                    // immediately — the web's lifecycle event may lag, or never
                    // arrive if a remote host's connection is lost.
                    applySessionPhase(.completed, chatId: target, sequence: nil)
                }
                return success
            }
            return false
        } catch {
            NSLog("[AgentBridge] interruptAgent error: %@", error.localizedDescription)
            return false
        }
    }

    /// Fetch the current show-thinking mode from the web app.
    @available(iOS 15.0, macOS 13.0, *)
    public func syncShowThinking() async {
        guard let webView else { return }
        do {
            let result = try await webView.callAsyncJavaScript(
                "return await window.__ripulGetShowThinking?.() ?? { success: false, mode: 'none' }",
                contentWorld: .page
            )
            if let dict = result as? [String: Any],
               let mode = dict["mode"] as? String {
                await MainActor.run { showThinkingMode = mode }
            }
        } catch {
            NSLog("[AgentBridge] syncShowThinking error: %@", error.localizedDescription)
        }
    }

    /// Set inline thinking display mode in the web app ("none", "folded", or "open").
    @available(iOS 15.0, macOS 13.0, *)
    @discardableResult
    public func setShowThinking(_ mode: String) async -> Bool {
        guard let webView else { return false }
        do {
            let result = try await webView.callAsyncJavaScript(
                "return await window.__ripulSetShowThinking?.(mode) ?? { success: false }",
                arguments: ["mode": mode],
                contentWorld: .page
            )
            if let dict = result as? [String: Any],
               let success = dict["success"] as? Bool, success {
                await MainActor.run { showThinkingMode = mode }
                return true
            }
            return false
        } catch {
            NSLog("[AgentBridge] setShowThinking error: %@", error.localizedDescription)
            return false
        }
    }

    /// Resume a paused agent, optionally with additional context.
    @available(iOS 15.0, macOS 13.0, *)
    @discardableResult
    public func resumeAgent(context: String? = nil) async -> Bool {
        guard let webView else { return false }
        do {
            // Scope the resume to the native active chat (same reasoning as
            // interruptAgent — the web's active chat may differ from ours).
            var args: [String: Any] = [
                "targetChatId": activeSourceChatId.map { $0 as Any } ?? NSNull(),
            ]
            let script: String
            if let ctx = context, !ctx.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                args["ctx"] = ctx
                script = "return await window.__ripulResumeAgent?.(ctx, targetChatId) ?? { success: false }"
            } else {
                script = "return await window.__ripulResumeAgent?.(undefined, targetChatId) ?? { success: false }"
            }
            let result = try await webView.callAsyncJavaScript(
                script,
                arguments: args,
                contentWorld: .page
            )
            if let dict = result as? [String: Any] {
                let success = dict["success"] as? Bool ?? false
                if !success {
                    let error = dict["error"] as? String ?? "unknown"
                    NSLog("[AgentBridge] resumeAgent returned failure: %@", error)
                }
                return success
            }
            return false
        } catch {
            NSLog("[AgentBridge] resumeAgent error: %@", error.localizedDescription)
            return false
        }
    }

    /// Interrogate the web app for the current agent status of a chat (the
    /// native active chat by default) and apply the answer per-chat. The active
    /// chat's `isAgentRunning`/`isAgentPaused` update as a side effect when the
    /// answer concerns it. Call after session transitions to correct stale state.
    @available(iOS 15.0, macOS 13.0, *)
    @discardableResult
    public func syncAgentStatus(chatId: String? = nil) async -> (isRunning: Bool, isPaused: Bool) {
        guard let webView else {
            return (false, false)
        }
        let target = chatId ?? activeSourceChatId
        do {
            let result = try await webView.callAsyncJavaScript(
                """
                if (window.__ripulGetAgentLifecycleSnapshot) {
                    return await window.__ripulGetAgentLifecycleSnapshot(targetChatId);
                }
                return await window.__ripulGetAgentStatus?.(targetChatId) ?? { isRunning: false, isPaused: false };
                """,
                arguments: ["targetChatId": target.map { $0 as Any } ?? NSNull()],
                contentWorld: .page
            )
            if let dict = result as? [String: Any] {
                // Trust the chatId STAMPED ON THE RESPONSE, never assume it's
                // the chat we asked about — an older web build ignores the
                // argument and answers for its own active tab. Keyed application
                // makes a mismatched answer harmless: it updates that chat's
                // row, not the active chat's buttons.
                let respChatId = dict["chatId"] as? String
                if let rawPhase = dict["phase"] as? String,
                   let phase = AgentTurnPhase(rawValue: rawPhase) {
                    if let respChatId, !respChatId.isEmpty {
                        applySessionPhase(phase, chatId: respChatId, sequence: dict["sequence"] as? Int, timestamp: dict["timestamp"])
                    }
                    return (isAgentRunning, isAgentPaused)
                }
                // Legacy status shape ({ isRunning, isPaused, chatId }).
                let running = dict["isRunning"] as? Bool ?? false
                let paused = dict["isPaused"] as? Bool ?? false
                if let respChatId, !respChatId.isEmpty {
                    if running || paused {
                        applySessionPhase(paused ? .awaitingInput : .running, chatId: respChatId, sequence: nil, timestamp: dict["timestamp"])
                    } else if chatTurnPhases[respChatId] != nil {
                        applySessionPhase(.completed, chatId: respChatId, sequence: nil, timestamp: dict["timestamp"])
                    }
                }
                return (isAgentRunning, isAgentPaused)
            }
        } catch {
            NSLog("[AgentBridge] syncAgentStatus error: %@", error.localizedDescription)
        }
        return (isAgentRunning, isAgentPaused)
    }

    /// Apply the active-session id reported by a sessions-list response, but let
    /// an in-flight navigation win. focusSession sets `activeSessionId` then kicks
    /// off `fetchSessions`; the web app's list response can lag that focus and
    /// report the PREVIOUS active session, clobbering the just-tapped row and
    /// dropping its selection highlight. While `navigatingToSessionId` is set
    /// (cleared after the slide settles), it is the authoritative target.
    private func applyActiveSessionIdFromResponse(_ activeId: String?) {
        let target = navigatingToSessionId ?? activeId
        if let target, activeSessionId != target { activeSessionId = target }
        // Refresh even when the id didn't change: the sessions list content may
        // have (a just-created chat becoming resolvable), which changes what
        // `activeSourceChatId` maps to and hands off the pending override.
        refreshActiveAgentFlags()
    }

    /// Whether an `agent:activity` event is fresh enough to drive a LIVE "what's
    /// it doing now" subtitle. On startup/reconnect the web app replays historical
    /// activity events carrying their ORIGINAL (old) timestamps (same property
    /// `advanceLastActive` relies on). Latching those shows a stale tool subtitle
    /// that hides the row's age and never clears — the finished turn's `completion`
    /// was never received because the app was closed when it landed. A missing or
    /// unparseable timestamp is treated as live to avoid regressing events that
    /// don't carry one.
    private func isFreshActivityTimestamp(_ raw: Any?) -> Bool {
        let ms: TimeInterval?
        if let v = raw as? TimeInterval { ms = v }
        else if let v = raw as? Int { ms = TimeInterval(v) }
        else { ms = nil }
        guard let ms, ms > 0 else { return true }
        return Date().timeIntervalSince1970 - ms / 1000 < 60
    }

    /// Fetch the current list of chat sessions by calling the web app's
    /// global function directly. Updates `sessions` and `activeSessionId`.
    @available(iOS 15.0, macOS 13.0, *)
    private var fetchSessionsCallCount = 0
    public func fetchSessions() async {
        fetchSessionsCallCount += 1
        let fetchStart = CFAbsoluteTimeGetCurrent()
        guard let webView else {
            if fetchSessionsCallCount <= 3 {
                Self.debugLog("[AgentBridge] fetchSessions #\(fetchSessionsCallCount): webView is nil")
            }
            lastSessionsError = "webView is nil"
            return
        }
        // Log every 10th call to confirm polling is active, plus first 3
        if fetchSessionsCallCount <= 3 || fetchSessionsCallCount % 10 == 0 {
            Self.debugLog("[AgentBridge] fetchSessions #\(fetchSessionsCallCount), sessions=\(sessions.count), cliSessions=\(sessions.filter { $0.provider == "claude-cli" || $0.provider == "codex-cli" }.count)")
        }

        do {
            // callAsyncJavaScript awaits the Promise — evaluateJavaScript does not.
            let result = try await webView.callAsyncJavaScript(
                """
                if (!window.__ripulGetSessions) return {sessions:[], activeId:null, error:'__ripulGetSessions not defined'};
                return await window.__ripulGetSessions();
                """,
                contentWorld: .page
            )

            guard let dict = result as? [String: Any] else {
                lastSessionsError = "result not [String:Any]: \(String(describing: result))"
                return
            }

            // Surface any error from the JS side
            let jsError = dict["error"] as? String

            guard let sessionsArray = dict["sessions"] as? [[String: Any]] else {
                lastSessionsError = jsError ?? "no sessions key, dict keys: \(Array(dict.keys))"
                return
            }

            let activeId = dict["activeId"] as? String
            let parsed: [ChatSession] = sessionsArray.compactMap { item in
                guard let id = item["id"] as? String,
                      let sourceChatId = item["sourceChatId"] as? String,
                      let displayName = item["displayName"] as? String else { return nil }
                let createdAtMs = item["createdAt"] as? Double ?? 0
                let createdAt = Date(timeIntervalSince1970: createdAtMs / 1000)
                let remoteMachineName = item["remoteMachineName"] as? String
                let provider = item["provider"] as? String
                let providerLabel = item["providerLabel"] as? String
                let hostChatId = item["hostChatId"] as? String
                let sizeBytes = (item["sizeBytes"] as? NSNumber)?.intValue
                let displayNameSource = item["displayNameSource"] as? String
                let displayNameRenamedAt = (item["displayNameRenamedAt"] as? NSNumber)?.doubleValue
                return ChatSession(id: id, sourceChatId: sourceChatId,
                                   displayName: displayName, createdAt: createdAt,
                                   remoteMachineName: remoteMachineName,
                                   provider: provider, providerLabel: providerLabel,
                                   hostChatId: hostChatId,
                                   sizeBytes: sizeBytes,
                                   displayNameSource: displayNameSource,
                                   displayNameRenamedAt: displayNameRenamedAt)
            }

            // Filter out ephemeral commit-viewer sessions (tracked explicitly
            // by CommitsScreen via ephemeralSessionIds, persisted to UserDefaults).
            let filtered = parsed.filter { !self.ephemeralSessionIds.contains($0.id) }

            if !filtered.isEmpty {
                // Only update if changed to avoid unnecessary SwiftUI re-renders
                if self.sessions != filtered {
                    // Detect CLI session renames and propagate to JSONL files.
                    // Only fire for displayNames that came from CLI history or
                    // an explicit user rename ("cli" / "user"). Auto-generated
                    // values ("auto" — descriptor in-memory or date fallback)
                    // would write themselves back to the JSONL as a
                    // `custom-title`, locking out Claude's own ai-title.
                    let oldByID = Dictionary(self.sessions.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
                    let isInitialLoad = oldByID.isEmpty
                    var renameLog = "[AgentBridge] sessions changed (\(self.sessions.count)→\(filtered.count)):"
                    for session in filtered {
                        // claude-cli only: onCliSessionRenamed is wired to
                        // ClaudeCliServer, the sole server with a title-write
                        // endpoint. Codex sessions would misfire into the wrong
                        // store (failed lookup + pointless retry).
                        if session.provider == "claude-cli" {
                            let oldName = oldByID[session.id]?.displayName ?? "(new)"
                            // Older hosts don't send displayNameSource — treat as "user" for back-compat.
                            let source = session.displayNameSource ?? "user"
                            renameLog += " [\(session.sourceChatId): '\(oldName)'→'\(session.displayName)' src=\(source)]"
                            let isAuthoritative = source == "cli" || source == "user"
                            if !isAuthoritative {
                                renameLog += " SKIP_AUTO"
                            } else if isInitialLoad {
                                // Sync all CLI session names on first load so reconnects pick up renames
                                renameLog += " INITIAL_SYNC"
                                self.onCliSessionRenamed?(session.sourceChatId, session.displayName, session.displayNameRenamedAt)
                            } else if let old = oldByID[session.id], old.displayName != session.displayName {
                                renameLog += " RENAME_DETECTED"
                                self.onCliSessionRenamed?(session.sourceChatId, session.displayName, session.displayNameRenamedAt)
                            }
                        }
                    }
                    Self.debugLog(renameLog)
                    self.sessions = filtered
                    ChatSession.saveToCache(filtered)
                }
                applyActiveSessionIdFromResponse(activeId)
                self.lastSessionsError = nil
            } else {
                lastSessionsError = jsError ?? "0 sessions parsed from \(sessionsArray.count) items"
                applyActiveSessionIdFromResponse(activeId)
            }
        } catch {
            lastSessionsError = "callAsyncJS: \(error.localizedDescription)"
        }
    }

    /// Legacy message-based request (kept for handshake auto-request).
    public func requestSessions() {
        send([
            "type": "\(messagePrefix)sessions:list",
            "version": protocolVersion,
            "timestamp": currentTimestamp(),
            "requestId": UUID().uuidString,
        ])
    }

    /// Switch the web app to a specific chat session.
    @available(iOS 15.0, macOS 13.0, *)
    /// The window-level curtain view — added directly to UIWindow so it is
    /// part of the SAME CATransaction batch that gets committed before any
    /// transition animation frame. SwiftUI @Published changes cannot guarantee
    /// Called by the dedicated curtainLowered WKScriptMessageHandler — kept for
    /// compatibility but now a no-op since the curtain approach is removed.
    @MainActor
    public func lowerWindowCurtain() { /* no-op — curtain approach removed */ }

    // MARK: - Drag freeze (swipe-back gesture)

    /// Disable WKWebView interaction during a swipe gesture so the user can't
    /// accidentally scroll the chat while dragging. Call on first gesture .changed.
    /// Does NOT add a visual overlay — the content stays visible.
    public func beginDrag() {
        #if os(iOS)
        webView?.isUserInteractionEnabled = false
        #endif
    }

    /// Re-enable WKWebView interaction after the gesture ends.
    public func endDrag(delay: Double = 0) {
        #if os(iOS)
        if delay <= 0 {
            webView?.isUserInteractionEnabled = true
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.webView?.isUserInteractionEnabled = true
            }
        }
        #endif
    }

    /// Focus a chat session. __ripulFocusSession now awaits the V2ChatScroller
    /// sweep before returning, so this call only completes once the new chat
    /// content is fully rendered. The caller (tap handler) then triggers the
    /// native navigation — the sheet dismissal IS the slide-in transition.
    public func focusSession(id: String) async {
        guard let webView else {
            NSLog("[AgentBridge] focusSession: webView is nil")
            return
        }
        let focusStart = CFAbsoluteTimeGetCurrent()
        handleConsoleLog("LOG: [STARTUP] focusSession START id=\(id.suffix(8))")
        // Clear any new-chat override, then let the activeSessionId didSet
        // re-derive the buttons from the target chat's known phase — switching
        // into a running chat shows its pause button immediately, and a chat
        // with no phase entry shows none.
        pendingActiveSourceChatId = nil
        activeSessionId = id
        do {
            _ = try await webView.callAsyncJavaScript(
                "if (window.__ripulFocusSession) await window.__ripulFocusSession(sessionId);",
                arguments: ["sessionId": id],
                contentWorld: .page
            )
            let focusMs = Int((CFAbsoluteTimeGetCurrent() - focusStart) * 1000)
            handleConsoleLog("LOG: [STARTUP] focusSession DONE (\(focusMs)ms)")
        } catch {
            NSLog("[AgentBridge] focusSession error: %@", error.localizedDescription)
        }
        // Defer post-focus catch-up past the native open slide. fetchSessions()
        // re-publishes the session list (and syncAgentStatus/syncShowThinking poke
        // the web view), which re-renders the view DURING the slide-in and visibly
        // stutters it — this is the one thing the different-chat open does that the
        // same-chat re-entry (smooth) does not. The work is non-urgent catch-up, so
        // let the slide settle first.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            await self?.syncAgentStatus()
            await self?.syncShowThinking()
            await self?.fetchSessions()
        }
    }

    /// Fetch the list of available slash commands from the web app.
    /// Pass `showHidden: true` to get hidden debug commands (the /rr. menu).
    @available(iOS 15.0, macOS 13.0, *)
    public func getSlashCommands(showHidden: Bool = false) async -> [SlashCommandInfo] {
        guard let webView else { return [] }
        do {
            let result = try await webView.callAsyncJavaScript(
                "return await window.__ripulGetSlashCommands?.(showHidden) ?? [];",
                arguments: ["showHidden": showHidden],
                contentWorld: .page
            )
            guard let array = result as? [[String: Any]] else { return [] }
            return array.compactMap { dict in
                guard let command = dict["command"] as? String,
                      let description = dict["description"] as? String else { return nil }
                var options: [SlashCommandOption] = []
                if let rawOptions = dict["options"] as? [[String: Any]] {
                    options = rawOptions.compactMap { o in
                        guard let value = o["value"] as? String,
                              let label = o["label"] as? String else { return nil }
                        return SlashCommandOption(value: value, label: label, description: o["description"] as? String)
                    }
                }
                return SlashCommandInfo(
                    command: command,
                    description: description,
                    icon: dict["icon"] as? String,
                    type: (dict["type"] as? String) ?? "template",
                    hasVariables: (dict["hasVariables"] as? Bool) ?? false,
                    options: options
                )
            }
        } catch {
            NSLog("[AgentBridge] getSlashCommands error: %@", error.localizedDescription)
            return []
        }
    }

    /// Fetch available models from the web app's model catalog.
    /// Updates `availableModels`, `selectedModelId`, and `modelSelectionEnabled`.
    /// Waits for the JS callable to be registered before calling.
    @available(iOS 15.0, macOS 13.0, *)
    public func fetchModels() async {
        // Retry up to 3 times with 2s delays if the result is empty.
        // Models depend on auth readiness and web app initialization,
        // both of which may not be complete on the first attempt.
        for attempt in 1...3 {
            let success = await fetchModelsOnce()
            if success && !availableModels.isEmpty { return }
            if attempt < 3 {
                NSLog("[AgentBridge] fetchModels: empty on attempt %d, retrying in 2s...", attempt)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func fetchModelsOnce() async -> Bool {
        lastModelsError = nil

        guard let webView else {
            lastModelsError = "WebView not available"
            return false
        }

        do {
            // Wait for __ripulGetModels to be defined (registered by registerNativeCallables),
            // then call it with a timeout. This doesn't depend on the bridge handshake —
            // callAsyncJavaScript works as soon as the web app has registered the callable.
            let result = try await webView.callAsyncJavaScript(
                """
                // Poll for up to 10s for the callable to be registered
                for (let i = 0; i < 40; i++) {
                    if (window.__ripulGetModels) break;
                    await new Promise(r => setTimeout(r, 250));
                }
                if (!window.__ripulGetModels) return {models:[], selectedModelId:null, error:'__ripulGetModels not defined after 10s'};
                try {
                    const r = await Promise.race([
                        window.__ripulGetModels(),
                        new Promise((_, reject) => setTimeout(() => reject(new Error('__ripulGetModels timed out after 15s')), 15000))
                    ]);
                    return r;
                } catch (e) {
                    return {models:[], selectedModelId:null, error: String(e)};
                }
                """,
                contentWorld: .page
            )

            guard let dict = result as? [String: Any] else {
                lastModelsError = "Unexpected response format"
                return false
            }

            if let error = dict["error"] as? String {
                lastModelsError = error
                NSLog("[AgentBridge] fetchModels error: %@", error)
                return false
            }

            guard let modelsArray = dict["models"] as? [[String: Any]] else {
                lastModelsError = "No models array in response"
                return false
            }

            let parsed: [ModelInfo] = modelsArray.compactMap { item in
                guard let id = item["id"] as? String,
                      let name = item["name"] as? String,
                      let modelId = item["modelId"] as? String,
                      let provider = item["provider"] as? String else { return nil }
                return ModelInfo(
                    id: id,
                    name: name,
                    modelId: modelId,
                    provider: provider,
                    group: (item["group"] as? String) ?? provider,
                    description: item["description"] as? String,
                    supportsThinking: (item["supportsThinking"] as? Bool) ?? false,
                    type: item["type"] as? String,
                    url: (item["url"] as? String) ?? "",
                    enabled: (item["enabled"] as? Bool) ?? true,
                    sortOrder: item["sortOrder"] as? Int,
                    cliModelId: item["cliModelId"] as? String,
                    cliRawMode: (item["cliRawMode"] as? Bool) ?? false,
                    cliEffort: item["cliEffort"] as? String,
                    cliMode: item["cliMode"] as? String
                )
            }

            if parsed.isEmpty {
                lastModelsError = "No models available (raw count: \(modelsArray.count))"
            }

            self.availableModels = parsed
            self.selectedModelId = dict["selectedModelId"] as? String
            self.modelSelectionEnabled = (dict["modelSelectionEnabled"] as? Bool) ?? true
            NSLog("[AgentBridge] fetchModels: %d models, selected: %@",
                  parsed.count, self.selectedModelId ?? "nil")
            return !parsed.isEmpty
        } catch {
            lastModelsError = error.localizedDescription
            NSLog("[AgentBridge] fetchModels error: %@", error.localizedDescription)
            return false
        }
    }

    /// Set the user's model override. Pass nil to revert to the default model.
    @available(iOS 15.0, macOS 13.0, *)
    @discardableResult
    public func setModel(_ modelId: String?) async -> Bool {
        handleConsoleLog("LOG: [MODELSW] native.setModel (global) modelId=\(modelId ?? "default")")
        guard let webView else {
            handleConsoleLog("LOG: [MODELSW] native.setModel ABORT webView=nil")
            return false
        }
        do {
            let result = try await webView.callAsyncJavaScript(
                "return await window.__ripulSetModel?.(modelId) ?? {success:false};",
                arguments: ["modelId": modelId.map { $0 as Any } ?? NSNull()],
                contentWorld: .page
            )
            if let dict = result as? [String: Any],
               let success = dict["success"] as? Bool, success {
                self.selectedModelId = modelId
                handleConsoleLog("LOG: [MODELSW] native.setModel OK modelId=\(modelId ?? "default") readBack=\(dict["readBack"] as? String ?? "none")")
                return true
            }
            handleConsoleLog("LOG: [MODELSW] native.setModel FAILED modelId=\(modelId ?? "default") result=\(String(describing: result))")
            return false
        } catch {
            handleConsoleLog("LOG: [MODELSW] native.setModel ERROR \(error.localizedDescription)")
            return false
        }
    }

    /// Load the current reasoning-effort override from the web app.
    @available(iOS 15.0, macOS 13.0, *)
    public func fetchEffort() async {
        guard let webView else { return }
        do {
            let result = try await webView.callAsyncJavaScript(
                "return await window.__ripulGetEffort?.() ?? {effort:null};",
                contentWorld: .page
            )
            if let dict = result as? [String: Any] {
                self.selectedEffort = dict["effort"] as? String
            }
        } catch {
            NSLog("[AgentBridge] fetchEffort error: %@", error.localizedDescription)
        }
    }

    /// Set the reasoning-effort override. Pass nil for the CLI default.
    @available(iOS 15.0, macOS 13.0, *)
    @discardableResult
    public func setEffort(_ effort: String?) async -> Bool {
        guard let webView else { return false }
        do {
            let result = try await webView.callAsyncJavaScript(
                "return await window.__ripulSetEffort?.(effort) ?? {success:false};",
                arguments: ["effort": effort.map { $0 as Any } ?? NSNull()],
                contentWorld: .page
            )
            if let dict = result as? [String: Any], (dict["success"] as? Bool) == true {
                self.selectedEffort = effort
                NSLog("[AgentBridge] setEffort: %@", effort ?? "default")
                return true
            }
            return false
        } catch {
            NSLog("[AgentBridge] setEffort error: %@", error.localizedDescription)
            return false
        }
    }

    /// Whether the current principal may edit CLI models (owner/admin, not a
    /// site-key portal visitor). The backend also enforces admin on /admin/models*.
    @available(iOS 15.0, macOS 13.0, *)
    public func canEditModels() async -> Bool {
        guard let webView else { return false }
        do {
            let result = try await webView.callAsyncJavaScript(
                "return await window.__ripulCanEditModels?.() ?? {canEdit:false};",
                contentWorld: .page
            )
            if let dict = result as? [String: Any], let can = dict["canEdit"] as? Bool { return can }
            return false
        } catch {
            NSLog("[AgentBridge] canEditModels error: %@", error.localizedDescription)
            return false
        }
    }

    /// Create or update a CLI model in the catalog. `bodyJSON` is a JSON
    /// UpsertModelRequest. Refreshes `availableModels` on success.
    /// Returns (success, errorMessage?).
    @available(iOS 15.0, macOS 13.0, *)
    public func saveModel(id: String, bodyJSON: String) async -> (Bool, String?) {
        guard let webView else { return (false, "No web view") }
        do {
            let result = try await webView.callAsyncJavaScript(
                "return await window.__ripulSaveModel?.(id, body) ?? {success:false, error:'__ripulSaveModel unavailable'};",
                arguments: ["id": id, "body": bodyJSON],
                contentWorld: .page
            )
            if let dict = result as? [String: Any] {
                if (dict["success"] as? Bool) == true {
                    await fetchModels()
                    return (true, nil)
                }
                return (false, (dict["error"] as? String) ?? "Save failed")
            }
            return (false, "Unexpected response")
        } catch {
            NSLog("[AgentBridge] saveModel error: %@", error.localizedDescription)
            return (false, error.localizedDescription)
        }
    }

    /// Delete a CLI model from the catalog. Refreshes `availableModels` on success.
    /// Returns (success, errorMessage?).
    @available(iOS 15.0, macOS 13.0, *)
    public func deleteModel(id: String) async -> (Bool, String?) {
        guard let webView else { return (false, "No web view") }
        do {
            let result = try await webView.callAsyncJavaScript(
                "return await window.__ripulDeleteModel?.(id) ?? {success:false, error:'__ripulDeleteModel unavailable'};",
                arguments: ["id": id],
                contentWorld: .page
            )
            if let dict = result as? [String: Any] {
                if (dict["success"] as? Bool) == true {
                    await fetchModels()
                    return (true, nil)
                }
                return (false, (dict["error"] as? String) ?? "Delete failed")
            }
            return (false, "Unexpected response")
        } catch {
            NSLog("[AgentBridge] deleteModel error: %@", error.localizedDescription)
            return (false, error.localizedDescription)
        }
    }

    /// Set the model override for a specific chat tab (used for CLI raw sessions).
    /// Unlike setModel() which sets a global override, this targets a single chat.
    @available(iOS 15.0, macOS 13.0, *)
    @discardableResult
    public func setChatModel(chatId: String, modelId: String) async -> Bool {
        handleConsoleLog("LOG: [MODELSW] native.setChatModel enter chatId=\(chatId.suffix(12)) modelId=\(modelId)")
        guard let webView else {
            handleConsoleLog("LOG: [MODELSW] native.setChatModel ABORT webView=nil")
            return false
        }
        do {
            let result = try await webView.callAsyncJavaScript(
                "return await window.__ripulSetChatModel?.(chatId, modelId) ?? {success:false};",
                arguments: ["chatId": chatId, "modelId": modelId],
                contentWorld: .page
            )
            if let dict = result as? [String: Any],
               let success = dict["success"] as? Bool, success {
                let reason = dict["reason"] as? String ?? "unknown"
                let applied = dict["descriptorModelOverride"] as? String ?? "none"
                handleConsoleLog("LOG: [MODELSW] native.setChatModel OK chatId=\(chatId.suffix(12)) modelId=\(modelId) reason=\(reason) descriptorNowHas=\(applied)")
                return true
            }
            handleConsoleLog("LOG: [MODELSW] native.setChatModel FAILED chatId=\(chatId.suffix(12)) modelId=\(modelId) result=\(String(describing: result))")
            return false
        } catch {
            handleConsoleLog("LOG: [MODELSW] native.setChatModel ERROR \(error.localizedDescription)")
            return false
        }
    }

    /// Toggle raw mode for a CLI session. In raw mode, prompts are passed verbatim
    /// to Claude with no system prompt wrapping and all tools available.
    /// Returns `(success, errorMessage)`. When success is false and errorMessage is
    /// non-nil, the caller should display it to the user.
    @available(iOS 15.0, macOS 13.0, *)
    @discardableResult
    public func setRawMode(sessionId: String, enabled: Bool) async -> (Bool, String?) {
        guard let webView else { return (false, nil) }
        do {
            let result = try await webView.callAsyncJavaScript(
                "return await window.__ripulSetRawMode?.(sessionId, enabled) ?? {success:false};",
                arguments: ["sessionId": sessionId, "enabled": enabled],
                contentWorld: .page
            )
            if let dict = result as? [String: Any],
               let success = dict["success"] as? Bool, success {
                NSLog("[AgentBridge] setRawMode: session=%@, enabled=%@", sessionId, enabled ? "true" : "false")
                return (true, nil)
            }
            // Extract error message from the web app response
            let errorMsg = (result as? [String: Any])?["error"] as? String
            return (false, errorMsg)
        } catch {
            NSLog("[AgentBridge] setRawMode error: %@", error.localizedDescription)
            return (false, error.localizedDescription)
        }
    }

    /// Check if a session is in raw mode by reading from the web app's localStorage.
    @available(iOS 15.0, macOS 13.0, *)
    public func isRawMode(sessionId: String) async -> Bool {
        guard let webView else { return false }
        do {
            let result = try await webView.callAsyncJavaScript(
                """
                try {
                    var map = JSON.parse(localStorage.getItem('cliRawModeSessions') || '{}');
                    return !!map[sessionId];
                } catch(e) { return false; }
                """,
                arguments: ["sessionId": sessionId],
                contentWorld: .page
            )
            return result as? Bool ?? false
        } catch {
            return false
        }
    }

    /// Fork a CLI session into a new independent conversation.
    /// Returns the new chatId on success, or nil on failure.
    @available(iOS 15.0, macOS 13.0, *)
    public func forkSession(sourceChatId: String, displayName: String?) async -> (success: Bool, newChatId: String?, error: String?) {
        guard let webView else { return (false, nil, "webView is nil") }
        do {
            let result = try await webView.callAsyncJavaScript(
                "return await window.__ripulForkSession?.(sourceChatId, displayName) ?? {success:false, error:'not ready'};",
                arguments: ["sourceChatId": sourceChatId, "displayName": displayName.map { $0 as Any } ?? NSNull()],
                contentWorld: .page
            )
            if let dict = result as? [String: Any],
               let success = dict["success"] as? Bool, success {
                let newChatId = dict["newChatId"] as? String
                NSLog("[AgentBridge] forkSession: forked %@ → %@", sourceChatId, newChatId ?? "?")
                return (true, newChatId, nil)
            }
            let errorMsg = (result as? [String: Any])?["error"] as? String
            return (false, nil, errorMsg)
        } catch {
            NSLog("[AgentBridge] forkSession error: %@", error.localizedDescription)
            return (false, nil, error.localizedDescription)
        }
    }

    /// Move a CLI session from its currently-paired machine to a different
    /// target machine. The source copy is left intact (fork-and-move). Returns
    /// the new local chatId on success, the effective cwd chosen by the target
    /// (and whether that was a fallback), and the target machine's display name.
    @available(iOS 15.0, macOS 13.0, *)
    public func moveSession(
        sourceChatId: String,
        targetMachineId: String,
        displayName: String?
    ) async -> (
        success: Bool,
        newChatId: String?,
        effectiveCwd: String?,
        cwdFallback: Bool,
        targetMachineName: String?,
        error: String?
    ) {
        guard let webView else { return (false, nil, nil, false, nil, "webView is nil") }
        do {
            let result = try await webView.callAsyncJavaScript(
                "return await window.__ripulMoveSession?.(sourceChatId, targetMachineId, displayName) ?? {success:false, error:'not ready'};",
                arguments: [
                    "sourceChatId": sourceChatId,
                    "targetMachineId": targetMachineId,
                    "displayName": displayName.map { $0 as Any } ?? NSNull(),
                ],
                contentWorld: .page
            )
            if let dict = result as? [String: Any],
               let success = dict["success"] as? Bool, success {
                let newChatId = dict["newChatId"] as? String
                let effectiveCwd = dict["effectiveCwd"] as? String
                let cwdFallback = (dict["cwdFallback"] as? Bool) ?? false
                let targetName = dict["targetMachineName"] as? String
                NSLog("[AgentBridge] moveSession: moved %@ → %@ (new=%@)", sourceChatId, targetMachineId, newChatId ?? "?")
                return (true, newChatId, effectiveCwd, cwdFallback, targetName, nil)
            }
            let errorMsg = (result as? [String: Any])?["error"] as? String
            return (false, nil, nil, false, nil, errorMsg)
        } catch {
            NSLog("[AgentBridge] moveSession error: %@", error.localizedDescription)
            return (false, nil, nil, false, nil, error.localizedDescription)
        }
    }

    /// Set the working directory for a CLI session via the web app's relay.
    /// Pass nil to reset to the host's default.
    @available(iOS 15.0, macOS 13.0, *)
    @discardableResult
    public func setWorkingDirectory(sessionId: String, directory: String?) async -> Bool {
        guard let webView else { return false }
        do {
            let result = try await webView.callAsyncJavaScript(
                "return await window.__ripulSetWorkingDirectory?.(sessionId, directory) ?? {success:false};",
                arguments: ["sessionId": sessionId, "directory": directory.map { $0 as Any } ?? NSNull()],
                contentWorld: .page
            )
            if let dict = result as? [String: Any],
               let success = dict["success"] as? Bool, success {
                return true
            }
            return false
        } catch {
            NSLog("[AgentBridge] setWorkingDirectory error: %@", error.localizedDescription)
            return false
        }
    }

    /// Favourite directories and current working directory from the remote host.
    @available(iOS 15.0, macOS 13.0, *)
    public struct FavoriteDirectories {
        public let directories: [String]
        public let current: String?
        public init(directories: [String], current: String?) {
            self.directories = directories
            self.current = current
        }
    }

    /// Fetch favourite directories from the remote host via the relay.
    /// Retries up to 3 times with 1s delays if the result is empty,
    /// since the relay connection may not be established yet.
    @available(iOS 15.0, macOS 13.0, *)
    public func getFavoriteDirectories() async -> FavoriteDirectories {
        guard let webView else { return FavoriteDirectories(directories: [], current: nil) }
        for attempt in 1...3 {
            do {
                let result = try await webView.callAsyncJavaScript(
                    "return await window.__ripulGetFavoriteDirectories?.() ?? {directories:[]};",
                    contentWorld: .page
                )
                if let dict = result as? [String: Any],
                   let dirs = dict["directories"] as? [String], !dirs.isEmpty {
                    let current = dict["current"] as? String
                    return FavoriteDirectories(directories: dirs, current: current?.isEmpty == false ? current : nil)
                }
            } catch {
                NSLog("[AgentBridge] getFavoriteDirectories error (attempt %d): %@", attempt, error.localizedDescription)
            }
            if attempt < 3 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        return FavoriteDirectories(directories: [], current: nil)
    }

    /// Discover remote actions available on a specific host machine.
    /// Returns an array of action descriptor dictionaries.
    @available(iOS 15.0, macOS 13.0, *)
    public func discoverRemoteActions(machineId: String) async -> [[String: Any]] {
        guard let webView else { return [] }
        for attempt in 1...3 {
            do {
                let result = try await webView.callAsyncJavaScript(
                    "return await window.__ripulDiscoverRemoteActions?.(machineId) ?? {actions:[]};",
                    arguments: ["machineId": machineId],
                    contentWorld: .page
                )
                if let dict = result as? [String: Any],
                   let actions = dict["actions"] as? [[String: Any]] {
                    if let error = dict["error"] as? String, !error.isEmpty {
                        handleConsoleLog("[AgentBridge] discoverRemoteActions warning: \(error)")
                    }
                    return actions
                }
            } catch {
                handleConsoleLog("[AgentBridge] discoverRemoteActions error (attempt \(attempt)): \(error.localizedDescription)")
            }
            if attempt < 3 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        return []
    }

    /// Discover Codex raw models available on a specific host machine.
    /// Returns `ModelInfo` rows generated from that machine's installed Codex CLI catalog.
    @available(iOS 15.0, macOS 13.0, *)
    public func discoverCodexModels(machineId: String) async -> [ModelInfo] {
        guard let webView else { return [] }
        do {
            let result = try await webView.callAsyncJavaScript(
                "return await window.__ripulDiscoverCodexModels?.(machineId) ?? {models:[]};",
                arguments: ["machineId": machineId],
                contentWorld: .page
            )
            guard let dict = result as? [String: Any],
                  let modelsArray = dict["models"] as? [[String: Any]] else {
                return []
            }
            if let error = dict["error"] as? String, !error.isEmpty {
                handleConsoleLog("[AgentBridge] discoverCodexModels warning: \(error)")
            }
            return modelsArray.compactMap { item in
                guard let id = item["id"] as? String,
                      let name = item["name"] as? String,
                      let modelId = item["modelId"] as? String else { return nil }
                return ModelInfo(
                    id: id,
                    name: name,
                    modelId: modelId,
                    provider: (item["provider"] as? String) ?? "codex-cli",
                    group: (item["group"] as? String) ?? "Codex",
                    description: item["description"] as? String,
                    supportsThinking: (item["supportsThinking"] as? Bool) ?? true
                )
            }
        } catch {
            handleConsoleLog("[AgentBridge] discoverCodexModels error: \(error.localizedDescription)")
            return []
        }
    }

    /// Execute a remote action on a specific host machine.
    /// Returns the result dictionary from the host.
    @available(iOS 15.0, macOS 13.0, *)
    public func executeRemoteAction(machineId: String, actionId: String, params: [String: Any] = [:]) async -> [String: Any] {
        guard let webView else { return ["status": "error", "error": "webView is nil"] }
        do {
            let paramsData = try JSONSerialization.data(withJSONObject: params)
            let paramsJson = String(data: paramsData, encoding: .utf8) ?? "{}"
            let result = try await webView.callAsyncJavaScript(
                "return await window.__ripulExecuteRemoteAction?.(machineId, actionId, JSON.parse(paramsJson)) ?? {success:false, error:'not ready'};",
                arguments: ["machineId": machineId, "actionId": actionId, "paramsJson": paramsJson],
                contentWorld: .page
            )
            if let dict = result as? [String: Any] {
                // Web bridge returns an envelope {success, output?, error?}.
                // Unwrap so callers receive the provider's own result dict
                // (which carries status/outputSchema/fields for native rendering).
                if let success = dict["success"] as? Bool {
                    if success, let output = dict["output"] as? [String: Any] {
                        return output
                    }
                    let errorMsg = dict["error"] as? String ?? "Action failed"
                    return ["status": "error", "error": errorMsg]
                }
                return dict
            }
            return ["status": "error", "error": "Unexpected result type"]
        } catch {
            handleConsoleLog("[AgentBridge] executeRemoteAction error: \(error.localizedDescription)")
            return ["status": "error", "error": error.localizedDescription]
        }
    }

    /// Query the remote host for file suggestions matching a partial path/name.
    /// Used by the native @files autocomplete in NativeChatInput.
    /// Returns an array of dictionaries with `path` (String) and `isDirectory` (Bool).
    @available(iOS 15.0, macOS 13.0, *)
    public func queryRemoteFiles(query: String) async -> [[String: Any]] {
        guard let webView, !query.isEmpty else { return [] }
        do {
            let result = try await webView.callAsyncJavaScript(
                "return await window.__ripulQueryRemoteFiles?.(query) ?? { files: [] };",
                arguments: ["query": query],
                contentWorld: .page
            )
            if let dict = result as? [String: Any],
               let files = dict["files"] as? [[String: Any]] {
                return files
            }
        } catch {
            NSLog("[AgentBridge] queryRemoteFiles error: %@", error.localizedDescription)
        }
        return []
    }

    public func queryPageElements() async -> [String] {
        guard let webView else { return [] }
        do {
            let result = try await webView.callAsyncJavaScript(
                "return window.__ripulQueryPageElements?.() ?? [];",
                arguments: [:],
                contentWorld: .page
            )
            if let elements = result as? [String] {
                return elements
            }
        } catch {
            NSLog("[AgentBridge] queryPageElements error: %@", error.localizedDescription)
        }
        return []
    }

    /// Query the chat's participant catalog (agents, plus humans in the future).
    /// Used by the native @people picker in NativeChatInput.
    /// Returns an array of dictionaries with `id`, `name`, `group`, and `kind`.
    @available(iOS 15.0, macOS 13.0, *)
    public func queryParticipants() async -> [[String: Any]] {
        guard let webView else { return [] }
        do {
            let result = try await webView.callAsyncJavaScript(
                "return await window.__ripulQueryParticipants?.() ?? { participants: [] };",
                arguments: [:],
                contentWorld: .page
            )
            if let dict = result as? [String: Any],
               let participants = dict["participants"] as? [[String: Any]] {
                return participants
            }
        } catch {
            NSLog("[AgentBridge] queryParticipants error: %@", error.localizedDescription)
        }
        return []
    }

    /// Query the web view for autocomplete suggestions for a given category and query string.
    /// Used by the native @ picker in NativeChatInput.
    /// Returns an array of dictionaries representing standard suggestions.
    @available(iOS 15.0, macOS 13.0, *)
    public func queryAutocomplete(category: String, query: String) async -> [[String: Any]] {
        guard let webView else { return [] }
        do {
            let result = try await webView.callAsyncJavaScript(
                "return await window.__ripulQueryAutocomplete?.(category, query) ?? { suggestions: [] };",
                arguments: ["category": category, "query": query],
                contentWorld: .page
            )
            if let dict = result as? [String: Any],
               let suggestions = dict["suggestions"] as? [[String: Any]] {
                return suggestions
            }
        } catch {
            NSLog("[AgentBridge] queryAutocomplete error: %@", error.localizedDescription)
        }
        return []
    }

    /// Import a Claude CLI session into the web app.
    /// Creates a new chat tab populated with the session's conversation history.
    /// - Parameters:
    ///   - messages: Array of JSONL message dictionaries (user/assistant/custom-title entries)
    ///   - sessionId: The CLI session UUID (used for --resume)
    ///   - title: Display title for the chat tab
    /// - Returns: true if import succeeded
    @available(iOS 15.0, macOS 13.0, *)
    @discardableResult
    public func importCliSession(
        messages: [[String: Any]],
        sessionId: String,
        title: String,
        subAgentSessions: [(agentId: String, messages: [[String: Any]])] = []
    ) async -> Bool {
        guard let webView else { return false }
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: messages)
            let messagesJson = String(data: jsonData, encoding: .utf8) ?? "[]"

            // Build sub-agent sessions JSON array
            var subAgentsJson = "[]"
            if !subAgentSessions.isEmpty {
                let subAgentsArray: [[String: Any]] = subAgentSessions.map { session in
                    ["agentId": session.agentId, "messages": session.messages]
                }
                let subAgentsData = try JSONSerialization.data(withJSONObject: subAgentsArray)
                subAgentsJson = String(data: subAgentsData, encoding: .utf8) ?? "[]"
            }

            let result = try await webView.callAsyncJavaScript(
                """
                if (!window.__ripulImportCliSession) return { success: false, error: '__ripulImportCliSession not defined' };
                const messages = JSON.parse(messagesJson);
                const subAgentSessions = JSON.parse(subAgentsJson);
                const params = { sessionId, title, messages };
                if (subAgentSessions.length > 0) params.subAgentSessions = subAgentSessions;
                return await window.__ripulImportCliSession(params);
                """,
                arguments: [
                    "messagesJson": messagesJson,
                    "subAgentsJson": subAgentsJson,
                    "sessionId": sessionId,
                    "title": title,
                ],
                contentWorld: .page
            )

            if let dict = result as? [String: Any],
               let success = dict["success"] as? Bool, success {
                let subCount = subAgentSessions.count
                NSLog("[AgentBridge] importCliSession: imported %d messages + %d sub-agents for session %@", messages.count, subCount, sessionId)
                await fetchSessions()
                return true
            }

            let error = (result as? [String: Any])?["error"] as? String ?? "unknown"
            NSLog("[AgentBridge] importCliSession failed: %@", error)
            return false
        } catch {
            NSLog("[AgentBridge] importCliSession error: %@", error.localizedDescription)
            return false
        }
    }

    /// Close (delete) a chat session tab.
    @available(iOS 15.0, macOS 13.0, *)
    public func closeSession(id: String) async {
        guard let webView else { return }
        do {
            _ = try await webView.callAsyncJavaScript(
                "if (window.__ripulCloseSession) return await window.__ripulCloseSession(tabId);",
                arguments: ["tabId": id],
                contentWorld: .page
            )
            // Remove from local state immediately
            let closed = sessions.first(where: { $0.id == id })
            sessions.removeAll { $0.id == id }
            if let sourceChatId = closed?.sourceChatId {
                sessionList.sessionPhases.removeValue(forKey: sourceChatId)
                sessionLifecycleSequences.removeValue(forKey: sourceChatId)
            }
            if activeSessionId == id {
                activeSessionId = sessions.first?.id
            }
        } catch {
            NSLog("[AgentBridge] closeSession error: %@", error.localizedDescription)
        }
    }

    /// Truncate a chat session, keeping only the most recent `keepCount` actions.
    /// Returns the number of actions removed, or -1 on failure.
    @available(iOS 15.0, macOS 13.0, *)
    public func truncateSession(chatId: String, keepCount: Int) async -> (removed: Int, error: String?) {
        guard let webView else { return (-1, "webView is nil") }
        do {
            let result = try await webView.callAsyncJavaScript(
                "if (window.__ripulTruncateSession) return await window.__ripulTruncateSession(chatId, keepCount);",
                arguments: ["chatId": chatId, "keepCount": keepCount],
                contentWorld: .page
            )
            if let dict = result as? [String: Any], dict["success"] as? Bool == true {
                return (dict["removed"] as? Int ?? 0, nil)
            }
            let errMsg = (result as? [String: Any])?["error"] as? String ?? "Unknown error"
            return (-1, errMsg)
        } catch {
            NSLog("[AgentBridge] truncateSession error: %@", error.localizedDescription)
            return (-1, error.localizedDescription)
        }
    }

    /// Force-restart the SessionChannel DO backing the given chat. Owner-only
    /// (server stamps authorId=ownerId for Clerk JWT requests). Used from the
    /// `/rr.` debug panel when a chat's DO is stuck on a pre-deploy code
    /// version — Cloudflare keeps existing DO instances on their old code
    /// until they evict on idle, and the reconnect loop keeps them alive.
    @available(iOS 15.0, macOS 13.0, *)
    public func evictSessionChannel(chatId: String) async -> (success: Bool, error: String?) {
        guard let webView else { return (false, "webView is nil") }
        do {
            let result = try await webView.callAsyncJavaScript(
                "if (window.__ripulEvictSessionChannel) return await window.__ripulEvictSessionChannel(chatId);",
                arguments: ["chatId": chatId],
                contentWorld: .page
            )
            if let dict = result as? [String: Any], dict["success"] as? Bool == true {
                return (true, nil)
            }
            let errMsg = (result as? [String: Any])?["error"] as? String ?? "Unknown error"
            return (false, errMsg)
        } catch {
            NSLog("[AgentBridge] evictSessionChannel error: %@", error.localizedDescription)
            return (false, error.localizedDescription)
        }
    }

    /// Race an async operation against a timeout. Safe on @MainActor (serial).
    @available(iOS 15.0, macOS 13.0, *)
    private func withBridgeTimeout<T>(seconds: TimeInterval = 20, operation: @escaping @MainActor () async throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            var didResume = false
            Task { @MainActor in
                do {
                    let result = try await operation()
                    guard !didResume else { return }
                    didResume = true
                    continuation.resume(returning: result)
                } catch {
                    guard !didResume else { return }
                    didResume = true
                    continuation.resume(throwing: error)
                }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !didResume else { return }
                didResume = true
                continuation.resume(throwing: NSError(
                    domain: "AgentBridge", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Connection timed out after \(Int(seconds))s — the remote machine may be unresponsive. Try restarting the host."]
                ))
            }
        }
    }

    /// Connect to a remote machine: creates a new chat tab and pairs it.
    /// Returns the tab ID on success, or nil on failure.
    @available(iOS 15.0, macOS 13.0, *)
    public func connectToMachine(machineId: String) async -> (tabId: String?, error: String?) {
        guard let webView else {
            return (nil, "webView is nil")
        }
        do {
            let result = try await withBridgeTimeout { [webView] in
                try await webView.callAsyncJavaScript(
                    """
                    if (!window.__ripulConnectToMachine) return {success:false, error:'not ready'};
                    var r = await window.__ripulConnectToMachine(machineId);
                    return JSON.parse(JSON.stringify(r));
                    """,
                    arguments: ["machineId": machineId],
                    contentWorld: .page
                )
            }
            guard let dict = result as? [String: Any] else {
                let classified = await classifyJsCallFailure("empty/unbridgeable result", callable: "__ripulConnectToMachine")
                return (nil, classified)
            }
            if let success = dict["success"] as? Bool, success {
                let tabId = dict["tabId"] as? String
                let machineName = dict["machineName"] as? String ?? machineId
                NSLog("[AgentBridge] connectToMachine: paired to %@, tab %@", machineName, tabId ?? "?")
                // Refresh sessions so the new tab appears
                await fetchSessions()
                return (tabId, nil)
            } else {
                var error = dict["error"] as? String ?? "Unknown error"
                if let code = dict["errorCode"] as? String { error = "\(code): \(error)" }
                NSLog("[AgentBridge] connectToMachine failed: %@", error)
                handleConsoleLog("ERROR: [CONN_DIAG] connectToMachine(\(machineId)) failed: \(error)")
                if let diag = await fetchWebDiagnostics() {
                    handleConsoleLog("WARN: [CONN_DIAG] diagnostics: \(diag)")
                }
                return (nil, error)
            }
        } catch {
            NSLog("[AgentBridge] connectToMachine error: %@", error.localizedDescription)
            let classified = await classifyJsCallFailure(error.localizedDescription, callable: "__ripulConnectToMachine")
            return (nil, classified)
        }
    }

    /// Connect to a remote machine in Claude Code mode: creates a session,
    /// sets the model to claude-cli, and enables raw mode in one step.
    @available(iOS 15.0, macOS 13.0, *)
    /// Connect to a remote machine in CLI provider mode: creates a session,
    /// sets the model to the provider's default, and enables raw mode.
    /// providerKey is e.g. "claude-cli", "codex-cli", "antigravity-cli".
    public func connectToMachineWithProvider(machineId: String, providerKey: String) async -> (tabId: String?, error: String?) {
        logSessionStartMarker("ios.connect_with_provider_enter", extra: "machineId=\(machineId) provider=\(providerKey)")
        guard let webView else {
            return (nil, "webView is nil")
        }
        do {
            logSessionStartMarker("ios.connect_with_provider_js_start")
            let result = try await withBridgeTimeout { [webView] in
                try await webView.callAsyncJavaScript(
                    """
                    if (!window.__ripulConnectToMachineWithProvider) return {success:false, error:'not ready'};
                    var r = await window.__ripulConnectToMachineWithProvider(machineId, providerKey);
                    return JSON.parse(JSON.stringify(r));
                    """,
                    arguments: ["machineId": machineId, "providerKey": providerKey],
                    contentWorld: .page
                )
            }
            logSessionStartMarker("ios.connect_with_provider_js_end")
            guard let dict = result as? [String: Any] else {
                let classified = await classifyJsCallFailure("empty/unbridgeable result", callable: "__ripulConnectToMachineWithProvider")
                return (nil, classified)
            }
            if let success = dict["success"] as? Bool, success {
                let tabId = dict["tabId"] as? String
                NSLog("[AgentBridge] connectToMachineWithProvider(%@): tab %@", providerKey, tabId ?? "?")
                self.selectedModelId = "\(providerKey)-raw-default"
                logSessionStartMarker("ios.fetch_sessions_start", chatId: tabId)
                await fetchSessions()
                logSessionStartMarker("ios.fetch_sessions_end", chatId: tabId, extra: "sessionCount=\(sessions.count)")
                return (tabId, nil)
            } else {
                var error = dict["error"] as? String ?? "Unknown error"
                if let code = dict["errorCode"] as? String { error = "\(code): \(error)" }
                handleConsoleLog("ERROR: [CONN_DIAG] connectToMachineWithProvider(\(providerKey)) failed: \(error)")
                if let diag = await fetchWebDiagnostics() {
                    handleConsoleLog("WARN: [CONN_DIAG] diagnostics: \(diag)")
                }
                return (nil, error)
            }
        } catch {
            NSLog("[AgentBridge] connectToMachineWithProvider(%@) error: %@", providerKey, error.localizedDescription)
            let classified = await classifyJsCallFailure(error.localizedDescription, callable: "__ripulConnectToMachineWithProvider")
            return (nil, classified)
        }
    }

    /// Bulk-fetch the user's session tags as `{ sessionId: [tags] }`.
    /// One authed request via the web app's metadata service — used to decorate
    /// the native session list with lozenges. Returns empty on any failure.
    @available(iOS 15.0, macOS 13.0, *)
    public func getSessionTags() async -> [String: [String]] {
        guard let webView else { return [:] }
        do {
            let result = try await webView.callAsyncJavaScript(
                """
                if (!window.__ripulGetSessionTags) return {};
                return await window.__ripulGetSessionTags();
                """,
                contentWorld: .page
            )
            guard let dict = result as? [String: Any] else { return [:] }
            var out: [String: [String]] = [:]
            for (key, value) in dict {
                if let arr = value as? [String] {
                    out[key] = arr
                } else if let arr = value as? [Any] {
                    out[key] = arr.compactMap { $0 as? String }
                }
            }
            return out
        } catch {
            NSLog("[AgentBridge] getSessionTags error: %@", error.localizedDescription)
            return [:]
        }
    }

    /// Replace the tag set for a session (keyed by its metadata id / sourceChatId).
    /// Returns true on success.
    @available(iOS 15.0, macOS 13.0, *)
    @discardableResult
    public func setSessionTags(sessionId: String, tags: [String]) async -> Bool {
        guard let webView else { return false }
        do {
            let result = try await webView.callAsyncJavaScript(
                """
                if (!window.__ripulSetSessionTags) return {ok:false};
                return await window.__ripulSetSessionTags(sessionId, tags);
                """,
                arguments: ["sessionId": sessionId, "tags": tags],
                contentWorld: .page
            )
            if let dict = result as? [String: Any], let ok = dict["ok"] as? Bool {
                return ok
            }
            return false
        } catch {
            NSLog("[AgentBridge] setSessionTags error: %@", error.localizedDescription)
            return false
        }
    }

    /// List sessions available on a remote machine via the relay discovery protocol.
    @available(iOS 15.0, macOS 13.0, *)
    public func listRemoteSessions(machineId: String) async -> [RemoteSessionInfo] {
        guard let webView else {
            NSLog("[AgentBridge] listRemoteSessions: webView is nil")
            return []
        }
        do {
            let result = try await webView.callAsyncJavaScript(
                """
                if (!window.__ripulListRemoteSessions) return {sessions:[], error:'not ready'};
                const result = await window.__ripulListRemoteSessions(machineId);
                if (!result.sessions || result.sessions.length === 0) {
                    console.log('[listRemoteSessions] empty for ' + machineId +
                        ', error=' + (result.error || 'none'));
                }
                return result;
                """,
                arguments: ["machineId": machineId],
                contentWorld: .page
            )
            guard let dict = result as? [String: Any],
                  let rawSessions = dict["sessions"] as? [[String: Any]] else {
                NSLog("[AgentBridge] listRemoteSessions: unexpected result type: %@", String(describing: result))
                return []
            }
            // Log relay timeline from JS side
            if let timeline = dict["timeline"] as? [String] {
                let joined = timeline.joined(separator: " | ")
                handleConsoleLog("LOG: [relay] debug_timeline listRemoteSessions(\(machineId)): \(joined)")
            }
            if let error = dict["error"] as? String, !error.isEmpty {
                NSLog("[AgentBridge] listRemoteSessions error from JS: %@", error)
                handleConsoleLog("LOG: [AgentBridge] listRemoteSessions(\(machineId)) JS error: \(error)")
            }
            let parsed = rawSessions.compactMap { item -> RemoteSessionInfo? in
                guard let id = item["id"] as? String,
                      let sourceChatId = item["sourceChatId"] as? String,
                      let displayName = item["displayName"] as? String,
                      let createdAt = item["createdAt"] as? Double else {
                    return nil
                }
                let isRunning = item["isRunning"] as? Bool ?? false
                let lastModifiedMs = item["lastModified"] as? Double
                return RemoteSessionInfo(
                    id: id,
                    sourceChatId: sourceChatId,
                    displayName: displayName,
                    createdAt: Date(timeIntervalSince1970: createdAt / 1000),
                    lastModified: lastModifiedMs.map { Date(timeIntervalSince1970: $0 / 1000) },
                    isRunning: isRunning,
                    projectName: item["projectName"] as? String,
                    cwd: item["cwd"] as? String,
                    gitBranch: item["gitBranch"] as? String,
                    messageCount: item["messageCount"] as? Int,
                    provider: item["provider"] as? String,
                    providerLabel: item["providerLabel"] as? String,
                    model: item["model"] as? String,
                    hostChatId: item["hostChatId"] as? String,
                    machineId: machineId
                )
            }
            NSLog("[AgentBridge] listRemoteSessions: %d sessions on %@", parsed.count, machineId)
            return parsed
        } catch {
            NSLog("[AgentBridge] listRemoteSessions error: %@", error.localizedDescription)
            return []
        }
    }

    /// Fetch Claude Code CLI account info from a remote machine via the relay bridge.
    @available(iOS 15.0, macOS 13.0, *)
    public func fetchCliAccount(machineId: String) async -> CliAccountInfo? {
        guard let webView else {
            NSLog("[AgentBridge] fetchCliAccount: webView is nil")
            return nil
        }
        do {
            let result = try await webView.callAsyncJavaScript(
                """
                if (!window.__ripulGetRemoteCliAccount) return { account: null, error: 'not ready' };
                return await window.__ripulGetRemoteCliAccount(machineId);
                """,
                arguments: ["machineId": machineId],
                contentWorld: .page
            )
            guard let dict = result as? [String: Any] else {
                NSLog("[AgentBridge] fetchCliAccount: unexpected result type: %@", String(describing: result))
                return nil
            }
            return CliAccountInfo.from(dict: dict)
        } catch {
            NSLog("[AgentBridge] fetchCliAccount error: %@", error.localizedDescription)
            return nil
        }
    }

    /// Archive a remote CLI session. Moves the JSONL file into the project's
    /// `.archive/` folder on the host machine — recoverable but hidden from scans.
    /// Returns (success, error) tuple.
    @available(iOS 15.0, macOS 13.0, *)
    public func archiveRemoteSession(machineId: String, sessionId: String) async -> (success: Bool, error: String?) {
        guard let webView else {
            return (false, "webView is nil")
        }
        do {
            let result = try await webView.callAsyncJavaScript(
                """
                if (!window.__ripulArchiveRemoteSession) return {success:false, error:'not ready'};
                return await window.__ripulArchiveRemoteSession(machineId, sessionId);
                """,
                arguments: ["machineId": machineId, "sessionId": sessionId],
                contentWorld: .page
            )
            guard let dict = result as? [String: Any] else {
                return (false, "Unexpected result")
            }
            let success = dict["success"] as? Bool ?? false
            let error = dict["error"] as? String
            NSLog("[AgentBridge] archiveRemoteSession: success=%@ error=%@", success ? "true" : "false", error ?? "nil")
            return (success, error)
        } catch {
            NSLog("[AgentBridge] archiveRemoteSession error: %@", error.localizedDescription)
            return (false, error.localizedDescription)
        }
    }

    /// Restore an archived remote CLI session — moves the JSONL back from
    /// `.archive/` to the active sessions directory so the CLI can resume it.
    @available(iOS 15.0, macOS 13.0, *)
    public func restoreRemoteSession(machineId: String, sessionId: String) async -> (success: Bool, error: String?) {
        guard let webView else {
            return (false, "webView is nil")
        }
        do {
            let result = try await webView.callAsyncJavaScript(
                """
                if (!window.__ripulRestoreRemoteSession) return {success:false, error:'not ready'};
                return await window.__ripulRestoreRemoteSession(machineId, sessionId);
                """,
                arguments: ["machineId": machineId, "sessionId": sessionId],
                contentWorld: .page
            )
            guard let dict = result as? [String: Any] else {
                return (false, "Unexpected result")
            }
            let success = dict["success"] as? Bool ?? false
            let error = dict["error"] as? String
            NSLog("[AgentBridge] restoreRemoteSession: success=%@ error=%@", success ? "true" : "false", error ?? "nil")
            return (success, error)
        } catch {
            NSLog("[AgentBridge] restoreRemoteSession error: %@", error.localizedDescription)
            return (false, error.localizedDescription)
        }
    }

    // MARK: - Archived Sessions (relay to Mac)

    /// An archived CLI session found in a .archive/ directory.
    public struct ArchivedSessionInfo: Identifiable, Hashable {
        public let id: String
        public let displayName: String
        public let projectName: String?
        public let archivedAt: Date
        public let provider: String?
        /// The machine the archive was discovered on — required to route the restore
        /// call back to the correct host. Stamped client-side after the per-machine fetch.
        public let machineId: String?
    }

    /// List archived sessions across all .archive/ directories on the host.
    @available(iOS 15.0, macOS 13.0, *)
    public func listArchivedSessions(machineId: String) async -> [ArchivedSessionInfo] {
        guard let webView else {
            NSLog("[AgentBridge] listArchivedSessions: webView is nil")
            return []
        }
        do {
            let result = try await webView.callAsyncJavaScript(
                """
                if (!window.__ripulListArchivedSessions) return {sessions:[], error:'not ready'};
                return JSON.parse(JSON.stringify(await window.__ripulListArchivedSessions(machineId)));
                """,
                arguments: ["machineId": machineId],
                contentWorld: .page
            )
            guard let dict = result as? [String: Any],
                  let sessionsRaw = dict["sessions"] as? [[String: Any]] else {
                if let dict = result as? [String: Any], let error = dict["error"] as? String {
                    NSLog("[AgentBridge] listArchivedSessions error from JS: %@", error)
                }
                return []
            }
            let parsed = sessionsRaw.compactMap { s -> ArchivedSessionInfo? in
                guard let id = s["id"] as? String else { return nil }
                let displayName = s["displayName"] as? String ?? id
                let projectName = s["projectName"] as? String
                let archivedAtMs = s["archivedAt"] as? Double ?? 0
                let provider = s["provider"] as? String
                return ArchivedSessionInfo(
                    id: id,
                    displayName: displayName,
                    projectName: projectName,
                    archivedAt: Date(timeIntervalSince1970: archivedAtMs / 1000),
                    provider: provider,
                    machineId: machineId
                )
            }
            NSLog("[AgentBridge] listArchivedSessions: %d sessions on %@", parsed.count, machineId)
            return parsed
        } catch {
            NSLog("[AgentBridge] listArchivedSessions error: %@", error.localizedDescription)
            return []
        }
    }

    /// Restore an archived session (move JSONL back from .archive/ to active).
    @available(iOS 15.0, macOS 13.0, *)
    public func restoreArchivedSession(machineId: String, sessionId: String) async -> (success: Bool, error: String?) {
        guard let webView else {
            return (false, "webView is nil")
        }
        do {
            let result = try await webView.callAsyncJavaScript(
                """
                if (!window.__ripulRestoreArchivedSession) return {success:false, error:'not ready'};
                return await window.__ripulRestoreArchivedSession(machineId, sessionId);
                """,
                arguments: ["machineId": machineId, "sessionId": sessionId],
                contentWorld: .page
            )
            guard let dict = result as? [String: Any] else {
                return (false, "Unexpected result")
            }
            let success = dict["success"] as? Bool ?? false
            let error = dict["error"] as? String
            NSLog("[AgentBridge] restoreArchivedSession: success=%@ error=%@", success ? "true" : "false", error ?? "nil")
            return (success, error)
        } catch {
            NSLog("[AgentBridge] restoreArchivedSession error: %@", error.localizedDescription)
            return (false, error.localizedDescription)
        }
    }

    /// Permanently delete an archived session (remove the archived JSONL file).
    @available(iOS 15.0, macOS 13.0, *)
    public func deleteArchivedSession(machineId: String, sessionId: String) async -> (success: Bool, error: String?) {
        guard let webView else {
            return (false, "webView is nil")
        }
        do {
            let result = try await webView.callAsyncJavaScript(
                """
                if (!window.__ripulDeleteArchivedSession) return {success:false, error:'not ready'};
                return await window.__ripulDeleteArchivedSession(machineId, sessionId);
                """,
                arguments: ["machineId": machineId, "sessionId": sessionId],
                contentWorld: .page
            )
            guard let dict = result as? [String: Any] else {
                return (false, "Unexpected result")
            }
            let success = dict["success"] as? Bool ?? false
            let error = dict["error"] as? String
            NSLog("[AgentBridge] deleteArchivedSession: success=%@ error=%@", success ? "true" : "false", error ?? "nil")
            return (success, error)
        } catch {
            NSLog("[AgentBridge] deleteArchivedSession error: %@", error.localizedDescription)
            return (false, error.localizedDescription)
        }
    }

    // MARK: - Git Commits (relay to Mac)

    /// A file edited during a session.
    public struct FileEditEntry: Hashable {
        public let fileName: String
        public let filePath: String?
        public let editCount: Int
        public let lastSeenAt: String?
    }

    /// A user-authored note on a session.
    public struct NoteEntry: Hashable, Identifiable {
        public let id: String
        public let text: String
        public let createdAt: String?
        /// Legacy timestamp field (from commit metadata).
        public let timestamp: String?
    }

    /// A deployment made during a session.
    public struct DeploymentEntry: Hashable, Identifiable {
        public let id: String
        public let target: String
        public let timestamp: String?
    }

    /// A contributor to a session.
    public struct ContributorEntry: Hashable, Identifiable {
        public let clientId: String
        public let clientType: String
        public let displayName: String?
        public let lastSeenAt: String?
        public var id: String { clientId }
    }

    /// A persistent participant in a session (human or agent). Stamped on
    /// @-submit, default-respondent send, relay peerJoin, and local-user action.
    /// Survives app restart and DO eviction — the canonical "who is in this
    /// chat" list shared by the @-picker and the metadata panel.
    public struct ParticipantEntry: Hashable, Identifiable {
        public let id: String
        public let kind: String
        public let displayName: String?
        public let group: String?
        public let firstSeenAt: String?
        public let lastSeenAt: String?

        public init(
            id: String,
            kind: String,
            displayName: String? = nil,
            group: String? = nil,
            firstSeenAt: String? = nil,
            lastSeenAt: String? = nil
        ) {
            self.id = id
            self.kind = kind
            self.displayName = displayName
            self.group = group
            self.firstSeenAt = firstSeenAt
            self.lastSeenAt = lastSeenAt
        }
    }

    /// Full session metadata fetched from the API.
    public struct SessionMetadata {
        public let id: String
        public let description: String?
        public let notes: [NoteEntry]
        public let filesEdited: [FileEditEntry]
        public let deployments: [DeploymentEntry]
        public let contributors: [ContributorEntry]
        public let participants: [ParticipantEntry]
        public let model: String?
        public let modelHistory: [String]
        public let createdAt: String?
        public let updatedAt: String?
    }

    /// Commit with a captured session, as returned by listCommitsWithSessions.
    public struct CommitWithSession {
        public let sha: String
        public let shortSha: String
        public let subject: String
        public let authorName: String
        /// Unix timestamp in seconds (committer date).
        public let timestamp: Double
        /// Branch name at commit time (nil for legacy entries).
        public let branch: String?
        /// Session ID from index (nil for legacy entries).
        public let sessionId: String?
        /// Session title extracted from JSONL at capture time (nil for legacy entries).
        public let sessionTitle: String?
        /// Number of unique files edited in this session (from .meta.json).
        public let filesEditedCount: Int?
        /// Session description (from .meta.json).
        public let description: String?
        /// Deployment targets triggered during this session (from .meta.json).
        public let deploymentTargets: [String]?
        /// Full files-edited list (from .meta.json).
        public let filesEdited: [FileEditEntry]?
        /// User-authored notes (from .meta.json).
        public let notes: [NoteEntry]?
        /// All deployments (from .meta.json).
        public let deployments: [DeploymentEntry]?
    }

    /// List commits that have a captured Claude session on the remote machine.
    @available(iOS 15.0, macOS 13.0, *)
    public func listCommitsWithSessions(machineId: String) async -> (repoPath: String, commits: [CommitWithSession], error: String?) {
        guard let webView else {
            return ("", [], "webView is nil")
        }
        do {
            let result = try await webView.callAsyncJavaScript(
                """
                if (!window.__ripulListCommitsWithSessions) return { repoPath: '', commits: [], error: 'not ready' };
                return await window.__ripulListCommitsWithSessions(machineId);
                """,
                arguments: ["machineId": machineId],
                contentWorld: .page
            )
            guard let dict = result as? [String: Any] else {
                return ("", [], "Unexpected result")
            }
            let repoPath = dict["repoPath"] as? String ?? ""
            let error = dict["error"] as? String
            let rawCommits = dict["commits"] as? [[String: Any]] ?? []
            let commits = rawCommits.compactMap { item -> CommitWithSession? in
                guard let sha = item["sha"] as? String,
                      let shortSha = item["shortSha"] as? String,
                      let subject = item["subject"] as? String,
                      let authorName = item["authorName"] as? String,
                      let timestamp = item["timestamp"] as? Double else { return nil }
                let branch = item["branch"] as? String
                let sessionId = item["sessionId"] as? String
                let sessionTitle = item["sessionTitle"] as? String
                let filesEditedCount = item["filesEditedCount"] as? Int
                let description = item["description"] as? String
                let deploymentTargets = item["deploymentTargets"] as? [String]

                let filesEdited = (item["filesEdited"] as? [[String: Any]])?.compactMap { entry -> FileEditEntry? in
                    guard let name = entry["fileName"] as? String else { return nil }
                    let count = (entry["editCount"] as? Int) ?? 1
                    return FileEditEntry(fileName: name, filePath: entry["filePath"] as? String, editCount: count, lastSeenAt: entry["lastSeenAt"] as? String)
                }
                let notes = (item["notes"] as? [[String: Any]])?.compactMap { entry -> NoteEntry? in
                    guard let text = entry["text"] as? String else { return nil }
                    return NoteEntry(id: entry["id"] as? String ?? UUID().uuidString, text: text, createdAt: entry["createdAt"] as? String, timestamp: entry["timestamp"] as? String)
                }
                let deploymentsList = (item["deployments"] as? [[String: Any]])?.compactMap { entry -> DeploymentEntry? in
                    guard let target = entry["target"] as? String else { return nil }
                    return DeploymentEntry(id: entry["id"] as? String ?? UUID().uuidString, target: target, timestamp: entry["timestamp"] as? String)
                }

                return CommitWithSession(sha: sha, shortSha: shortSha, subject: subject, authorName: authorName, timestamp: timestamp, branch: branch, sessionId: sessionId, sessionTitle: sessionTitle, filesEditedCount: filesEditedCount, description: description, deploymentTargets: deploymentTargets, filesEdited: filesEdited, notes: notes, deployments: deploymentsList)
            }
            return (repoPath, commits, error)
        } catch {
            NSLog("[AgentBridge] listCommitsWithSessions error: %@", error.localizedDescription)
            return ("", [], error.localizedDescription)
        }
    }

    /// Resume a captured session from a commit SHA on a remote machine.
    @available(iOS 15.0, macOS 13.0, *)
    public func resumeFromCommit(machineId: String, sha: String) async -> (success: Bool, sessionId: String?, error: String?) {
        guard let webView else {
            return (false, nil, "webView is nil")
        }
        do {
            let result = try await webView.callAsyncJavaScript(
                """
                if (!window.__ripulResumeFromCommit) return { success: false, error: 'not ready' };
                var r = await window.__ripulResumeFromCommit(machineId, sha);
                return JSON.parse(JSON.stringify(r));
                """,
                arguments: ["machineId": machineId, "sha": sha],
                contentWorld: .page
            )
            guard let dict = result as? [String: Any] else {
                return (false, nil, "Unexpected result")
            }
            let success = dict["success"] as? Bool ?? false
            let sessionId = dict["sessionId"] as? String
            let error = dict["error"] as? String
            return (success, sessionId, error)
        } catch {
            NSLog("[AgentBridge] resumeFromCommit error: %@", error.localizedDescription)
            return (false, nil, error.localizedDescription)
        }
    }

    // MARK: - Session Metadata (API)

    /// Fetch full session metadata from the API for a live session.
    @available(iOS 15.0, macOS 13.0, *)
    public func getSessionMetadata(sessionId: String) async -> SessionMetadata? {
        guard let webView else { return nil }
        do {
            let result = try await webView.callAsyncJavaScript(
                """
                if (!window.__ripulGetSessionMetadata) return { error: 'not ready' };
                return await window.__ripulGetSessionMetadata(sessionId);
                """,
                arguments: ["sessionId": sessionId],
                contentWorld: .page
            )
            guard let dict = result as? [String: Any],
                  let raw = dict["metadata"] as? [String: Any] else { return nil }
            return Self.parseSessionMetadata(raw)
        } catch {
            NSLog("[AgentBridge] getSessionMetadata error: %@", error.localizedDescription)
            return nil
        }
    }

    /// Per-chat storage breakdown — total bytes + top buckets by tool/method.
    /// Surfaces what kinds of action are dominating a chat's persisted size,
    /// for the native session metadata debug panel.
    public struct SessionStorageBucket {
        public let name: String
        public let bytes: Int
        public let count: Int
    }
    public struct SessionStorageBreakdown {
        public let totalBytes: Int
        public let count: Int
        public let buckets: [SessionStorageBucket]
    }

    @available(iOS 15.0, macOS 13.0, *)
    public func getSessionStorageBreakdown(sessionId: String, maxBuckets: Int = 8) async -> SessionStorageBreakdown? {
        guard let webView else { return nil }
        do {
            let result = try await webView.callAsyncJavaScript(
                """
                if (!window.__ripulGetSessionStorageBreakdown) return { error: 'not ready' };
                return await window.__ripulGetSessionStorageBreakdown(sessionId, maxBuckets);
                """,
                arguments: ["sessionId": sessionId, "maxBuckets": maxBuckets],
                contentWorld: .page
            )
            guard let dict = result as? [String: Any],
                  let raw = dict["breakdown"] as? [String: Any] else { return nil }
            let totalBytes = (raw["totalBytes"] as? Int) ?? 0
            let count = (raw["count"] as? Int) ?? 0
            let bucketsRaw = (raw["buckets"] as? [[String: Any]]) ?? []
            let buckets: [SessionStorageBucket] = bucketsRaw.compactMap { entry in
                guard let name = entry["name"] as? String else { return nil }
                return SessionStorageBucket(
                    name: name,
                    bytes: (entry["bytes"] as? Int) ?? 0,
                    count: (entry["count"] as? Int) ?? 0
                )
            }
            return SessionStorageBreakdown(totalBytes: totalBytes, count: count, buckets: buckets)
        } catch {
            NSLog("[AgentBridge] getSessionStorageBreakdown error: %@", error.localizedDescription)
            return nil
        }
    }

    // MARK: - CLI Tools

    /// A single tool entry returned by `__ripulGetResolvedToolsForSession`.
    public struct CliToolEntry {
        public let name: String
        public let description: String
    }

    /// Fetch the resolved CLI tool list for a session — calls the same JS callable
    /// the MCP bridge uses on every `tools/list`, so this reflects exactly what
    /// Claude CLI sees (after interceptor chain, progressive discovery, etc.).
    @available(iOS 15.0, macOS 13.0, *)
    public func getResolvedCliTools(sessionId: String) async -> [CliToolEntry]? {
        guard let webView else { return nil }
        do {
            let result = try await webView.callAsyncJavaScript(
                """
                if (!window.__ripulGetResolvedToolsForSession) return { error: 'not ready' };
                return await window.__ripulGetResolvedToolsForSession(sessionId);
                """,
                arguments: ["sessionId": sessionId],
                contentWorld: .page
            )
            guard let dict = result as? [String: Any],
                  let toolsRaw = dict["tools"] as? [[String: Any]] else { return nil }
            return toolsRaw.compactMap { t in
                guard let name = t["name"] as? String else { return nil }
                return CliToolEntry(name: name, description: (t["description"] as? String) ?? "")
            }
        } catch {
            NSLog("[AgentBridge] getResolvedCliTools error: %@", error.localizedDescription)
            return nil
        }
    }

    /// Patch session metadata (description, notes, etc.) via the API.
    @available(iOS 15.0, macOS 13.0, *)
    public func patchSessionMetadata(sessionId: String, patch: [String: Any]) async -> SessionMetadata? {
        guard let webView else { return nil }
        do {
            let result = try await webView.callAsyncJavaScript(
                """
                if (!window.__ripulPatchSessionMetadata) return { error: 'not ready' };
                return await window.__ripulPatchSessionMetadata(sessionId, patch);
                """,
                arguments: ["sessionId": sessionId, "patch": patch],
                contentWorld: .page
            )
            guard let dict = result as? [String: Any],
                  let raw = dict["metadata"] as? [String: Any] else { return nil }
            return Self.parseSessionMetadata(raw)
        } catch {
            NSLog("[AgentBridge] patchSessionMetadata error: %@", error.localizedDescription)
            return nil
        }
    }

    /// Parse a raw JSON dictionary into a SessionMetadata.
    private static func parseSessionMetadata(_ raw: [String: Any]) -> SessionMetadata {
        let filesEdited = (raw["filesEdited"] as? [[String: Any]])?.compactMap { entry -> FileEditEntry? in
            guard let name = entry["fileName"] as? String else { return nil }
            return FileEditEntry(
                fileName: name,
                filePath: entry["filePath"] as? String,
                editCount: (entry["editCount"] as? Int) ?? 1,
                lastSeenAt: entry["lastSeenAt"] as? String
            )
        } ?? []

        let notes = (raw["notes"] as? [[String: Any]])?.compactMap { entry -> NoteEntry? in
            guard let text = entry["text"] as? String else { return nil }
            return NoteEntry(
                id: entry["id"] as? String ?? UUID().uuidString,
                text: text,
                createdAt: entry["createdAt"] as? String,
                timestamp: entry["timestamp"] as? String
            )
        } ?? []

        let deployments = (raw["deployments"] as? [[String: Any]])?.compactMap { entry -> DeploymentEntry? in
            guard let target = entry["target"] as? String else { return nil }
            return DeploymentEntry(
                id: entry["id"] as? String ?? UUID().uuidString,
                target: target,
                timestamp: entry["timestamp"] as? String
            )
        } ?? []

        let contributors = (raw["contributors"] as? [[String: Any]])?.compactMap { entry -> ContributorEntry? in
            guard let clientId = entry["clientId"] as? String,
                  let clientType = entry["clientType"] as? String else { return nil }
            return ContributorEntry(
                clientId: clientId,
                clientType: clientType,
                displayName: entry["displayName"] as? String,
                lastSeenAt: entry["lastSeenAt"] as? String
            )
        } ?? []

        let participants = (raw["participants"] as? [[String: Any]])?.compactMap { entry -> ParticipantEntry? in
            guard let id = entry["id"] as? String,
                  let kind = entry["kind"] as? String else { return nil }
            return ParticipantEntry(
                id: id,
                kind: kind,
                displayName: entry["displayName"] as? String,
                group: entry["group"] as? String,
                firstSeenAt: entry["firstSeenAt"] as? String,
                lastSeenAt: entry["lastSeenAt"] as? String
            )
        } ?? []

        return SessionMetadata(
            id: raw["id"] as? String ?? "",
            description: raw["description"] as? String,
            notes: notes,
            filesEdited: filesEdited,
            deployments: deployments,
            contributors: contributors,
            participants: participants,
            model: raw["model"] as? String,
            modelHistory: raw["modelHistory"] as? [String] ?? [],
            createdAt: raw["createdAt"] as? String,
            updatedAt: raw["updatedAt"] as? String
        )
    }

    /// Delete a session: stops thread, clears chat actions, deletes local thread
    /// data, and closes the tab. By default also archives the CLI session JSONL
    /// on the remote host, which hides it from the underlying CLI (Claude Code,
    /// Codex). Pass `keepRemote: true` to skip the remote archive so the CLI
    /// still sees the session in its own list (e.g. for a "Remove from Ripul"
    /// action that only clears Ripul-side state).
    /// Returns (success, results, errors) — local cleanup always proceeds even if
    /// remote steps fail. The caller can present the results/errors to the user.
    @available(iOS 15.0, macOS 13.0, *)
    public func deleteSession(tabId: String, machineId: String?, remoteSessionId: String?, keepRemote: Bool = false) async -> (success: Bool, results: [String], errors: [String]) {
        guard let webView else {
            return (false, [], ["webView is nil"])
        }
        do {
            let result = try await webView.callAsyncJavaScript(
                """
                if (!window.__ripulDeleteSession) return {success:false, results:[], errors:['not ready']};
                return await window.__ripulDeleteSession(tabId, machineId, remoteSessionId, keepRemote);
                """,
                arguments: [
                    "tabId": tabId,
                    // Pass NSNull (-> JS null) for nil optionals. A boxed Swift
                    // `nil as Any` is NOT a serializable argument type, so
                    // callAsyncJavaScript rejects the call with "result of an
                    // unknown type". That is why removing a LOCAL session (nil
                    // machineId / remoteSessionId) failed while removing a remote
                    // session (real strings) worked.
                    "machineId": machineId.map { $0 as Any } ?? NSNull(),
                    "remoteSessionId": remoteSessionId.map { $0 as Any } ?? NSNull(),
                    "keepRemote": keepRemote,
                ],
                contentWorld: .page
            )
            guard let dict = result as? [String: Any] else {
                return (false, [], ["Unexpected result"])
            }
            let success = dict["success"] as? Bool ?? false
            let results = dict["results"] as? [String] ?? []
            let errors = dict["errors"] as? [String] ?? []
            NSLog("[AgentBridge] deleteSession: success=%@ results=%@ errors=%@",
                  success ? "true" : "false", results.joined(separator: ", "), errors.joined(separator: ", "))

            // Remove from local state and persist so the zombie can't return from cache
            let deleted = sessions.first(where: { $0.id == tabId })
            sessions.removeAll { $0.id == tabId }
            ChatSession.saveToCache(sessions)
            if let sourceChatId = deleted?.sourceChatId {
                sessionList.sessionPhases.removeValue(forKey: sourceChatId)
                sessionLifecycleSequences.removeValue(forKey: sourceChatId)
            }
            if activeSessionId == tabId {
                activeSessionId = sessions.first?.id
            }

            return (success, results, errors)
        } catch {
            NSLog("[AgentBridge] deleteSession error: %@", error.localizedDescription)
            return (false, [], [error.localizedDescription])
        }
    }

    /// Clear the SDK's local session caches (session list, cached list on disk,
    /// per-session phases and lifecycle sequences) WITHOUT touching auth or
    /// settings. Pairs with the web-side `__ripulClearSessionData` callable —
    /// call both to give this device a provably-clean local slate; the web
    /// view's reload then repopulates everything fresh.
    @available(iOS 15.0, macOS 13.0, *)
    public func clearLocalSessionState() {
        sessions.removeAll()
        ChatSession.saveToCache(sessions)
        sessionList.sessionPhases.removeAll()
        sessionLifecycleSequences.removeAll()
        activeSessionId = nil
    }

    /// Repair the device's relay/connection state.
    ///
    /// First tries the web app's graceful reset (`__ripulRepairConnection`), which
    /// closes tabs, drops relay pairings/session-origin maps, clears persisted seq
    /// cursors and CLI bookkeeping, then reloads. If the JS context is dead, falls
    /// back to `purgeWebStateAndReload()` — a scorched-earth localStorage/IndexedDB
    /// purge that preserves cookies. Host settings and machine identity survive
    /// either path because they are mirrored natively (HostPreferences) and
    /// re-injected after the reload.
    @available(iOS 15.0, macOS 13.0, *)
    public func repairConnection() async -> (success: Bool, message: String) {
        guard let webView else {
            return (false, "webView is nil")
        }

        // User manually intervened — cancel any automatic heal retries and reset
        // the ladder so the fresh boot starts cheap.
        deferredHealTask?.cancel()
        deferredHealTask = nil
        healVerifyTask?.cancel()
        healVerifyTask = nil
        healAttempts = 0

        // Attempt 1: graceful web-side reset.
        do {
            let result = try await webView.callAsyncJavaScript(
                """
                if (!window.__ripulRepairConnection) return {success:false, error:'not ready'};
                return await window.__ripulRepairConnection();
                """,
                arguments: [:],
                contentWorld: .page
            )
            if let dict = result as? [String: Any],
               let success = dict["success"] as? Bool,
               success {
                clearLocalSessionState()
                return (true, "Connection reset requested. The web view is reloading.")
            }
            let error = (result as? [String: Any])?["error"] as? String ?? "graceful reset declined"
            handleConsoleLog("WARN: [REPAIR_CONN] graceful reset failed: \(error); escalating to purge")
        } catch {
            let classified = await classifyJsCallFailure(error.localizedDescription, callable: "__ripulRepairConnection")
            handleConsoleLog("WARN: [REPAIR_CONN] graceful reset threw: \(classified); escalating to purge")
        }

        // Attempt 2: native fallback — purge web state (cookies preserved) and reload.
        purgeWebStateAndReload()
        clearLocalSessionState()
        return (true, "Connection reset with fallback purge. The web view is reloading.")
    }

    /// Open/reconnect to an existing session on a remote machine.
    /// Returns the local tab ID and provider metadata on success, or nil + error on failure.
    @available(iOS 15.0, macOS 13.0, *)
    public func openRemoteSession(machineId: String, sessionId: String, displayName: String? = nil, forceReimport: Bool = false) async -> (tabId: String?, provider: String?, providerLabel: String?, error: String?) {
        guard let webView else {
            return (nil, nil, nil, "webView is nil")
        }
        do {
            var args: [String: Any] = ["machineId": machineId, "sessionId": sessionId, "forceReimport": forceReimport]
            if let displayName { args["displayName"] = displayName }
            let result = try await webView.callAsyncJavaScript(
                """
                if (!window.__ripulOpenRemoteSession) return {success:false, error:'not ready'};
                var opts = forceReimport ? {forceReimport: true} : undefined;
                var r = await window.__ripulOpenRemoteSession(machineId, sessionId, displayName, opts);
                return JSON.parse(JSON.stringify(r));
                """,
                arguments: args,
                contentWorld: .page
            )
            guard let dict = result as? [String: Any] else {
                let classified = await classifyJsCallFailure("empty/unbridgeable result", callable: "__ripulOpenRemoteSession")
                return (nil, nil, nil, classified)
            }
            if let success = dict["success"] as? Bool, success {
                let tabId = dict["tabId"] as? String
                let provider = dict["provider"] as? String
                let providerLabel = dict["providerLabel"] as? String
                NSLog("[AgentBridge] openRemoteSession: opened %@ on %@, tab %@, provider %@", sessionId, machineId, tabId ?? "?", provider ?? "none")
                await fetchSessions()
                return (tabId, provider, providerLabel, nil)
            } else {
                // Prefix the web app's stable errorCode so ConnectionDiagnosis can
                // classify without string-sniffing the human message.
                var error = dict["error"] as? String ?? "Unknown error"
                if let code = dict["errorCode"] as? String { error = "\(code): \(error)" }
                NSLog("[AgentBridge] openRemoteSession failed: %@", error)
                handleConsoleLog("ERROR: [CONN_DIAG] openRemoteSession(\(sessionId)) failed: \(error)")
                if let diag = await fetchWebDiagnostics() {
                    handleConsoleLog("WARN: [CONN_DIAG] diagnostics: \(diag)")
                }
                return (nil, nil, nil, error)
            }
        } catch {
            NSLog("[AgentBridge] openRemoteSession error: %@", error.localizedDescription)
            let classified = await classifyJsCallFailure(error.localizedDescription, callable: "__ripulOpenRemoteSession")
            return (nil, nil, nil, classified)
        }
    }

    /// Create a new chat tab via direct JS call.
    @available(iOS 15.0, macOS 13.0, *)
    public func createNewChat() async -> String? {
        logSessionStartMarker("ios.bridge_createNewChat_enter", extra: "isConnected=\(isConnected)")
        guard let webView else {
            NSLog("[AgentBridge] createNewChat: webView is nil")
            logSessionStartMarker("ios.bridge_createNewChat_no_webview")
            return nil
        }

        do {
            logSessionStartMarker("ios.bridge_js_call_start")
            let wdArgument: Any = pendingNewChatWorkingDirectory ?? NSNull()
            let result = try await webView.callAsyncJavaScript(
                """
                if (!window.__ripulCreateChat) return {success:false, error:'not ready'};
                return await window.__ripulCreateChat(workingDirectory);
                """,
                arguments: ["workingDirectory": wdArgument],
                contentWorld: .page
            )

            guard let dict = result as? [String: Any],
                  let success = dict["success"] as? Bool, success,
                  let chatId = dict["chatId"] as? String else {
                NSLog("[AgentBridge] createNewChat: unexpected result: %@",
                      String(describing: result))
                logSessionStartMarker("ios.bridge_js_call_end", extra: "result=unexpected")
                return nil
            }
            NSLog("[AgentBridge] createNewChat: created %@", chatId)
            // A brand-new chat has no agent turn — point the button projection
            // at it immediately (the sessions push that makes it resolvable in
            // `sessions` lags this call by hundreds of ms).
            pendingActiveSourceChatId = chatId
            refreshActiveAgentFlags()
            logSessionStartMarker("ios.bridge_js_call_end", chatId: chatId)
            return chatId
        } catch {
            NSLog("[AgentBridge] createNewChat error: %@", error.localizedDescription)
            logSessionStartMarker("ios.bridge_js_call_error", extra: "err=\(error.localizedDescription)")
            return nil
        }
    }

    /// Rename a chat session. Updates both web storage and local state.
    /// Rename a session via a direct JS round-trip call.
    /// Updates local state only after the web app confirms persistence.
    public func renameSession(id: String, sourceChatId: String, displayName: String) {
        guard let webView else { return }
        // Optimistically update local state immediately for UI responsiveness
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index].displayName = displayName
        }
        let escaped = displayName
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
        let escapedChatId = sourceChatId
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
        Task { @MainActor in
            guard #available(iOS 15.0, *) else { return }
            do {
                let escapedId = id
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "`", with: "\\`")
                let result = try await webView.callAsyncJavaScript(
                    "return await window.__ripulRenameSession?.(`\(escapedChatId)`, `\(escaped)`, `\(escapedId)`) ?? { success: false }",
                    contentWorld: .page
                )
                if let dict = result as? [String: Any],
                   let success = dict["success"] as? Bool, success,
                   let confirmedName = dict["displayName"] as? String {
                    // Web mints the rename-event stamp; carry it into the JSONL
                    // write so the CLI server's stale-stamp guard sees the true
                    // event time.
                    let confirmedRenamedAt = (dict["renamedAt"] as? NSNumber)?.doubleValue
                    if let index = sessions.firstIndex(where: { $0.id == id }) {
                        sessions[index].displayName = confirmedName
                        sessions[index].displayNameRenamedAt = confirmedRenamedAt ?? sessions[index].displayNameRenamedAt
                    }
                    NSLog("[AgentBridge] renameSession confirmed: %@", confirmedName)
                    // Propagate to CLI session file if this is a CLI-provider session
                    if let session = self.sessions.first(where: { $0.id == id }),
                       session.provider == "claude-cli" {
                        self.onCliSessionRenamed?(sourceChatId, confirmedName, confirmedRenamedAt)
                    }
                } else {
                    NSLog("[AgentBridge] renameSession: web did not confirm, result: %@", String(describing: result))
                }
            } catch {
                NSLog("[AgentBridge] renameSession error: %@", error.localizedDescription)
            }
        }
    }

    // MARK: - Server host management

    /// Enable or disable relay host mode in the web app.
    @available(iOS 15.0, macOS 13.0, *)
    public func setHostEnabled(_ enabled: Bool, machineName: String? = nil) async -> Bool {
        guard let webView else { return false }
        do {
            let result = try await webView.callAsyncJavaScript(
                """
                if (!window.__ripulSetHostEnabled) return {success:false, error:'not ready'};
                return await window.__ripulSetHostEnabled(enabled, machineName);
                """,
                arguments: [
                    "enabled": enabled,
                    "machineName": machineName.map { $0 as Any } ?? NSNull(),
                ],
                contentWorld: .page
            )
            let dict = result as? [String: Any]
            let success = dict?["success"] as? Bool ?? false
            NSLog("[AgentBridge] setHostEnabled(%@): %@", enabled ? "true" : "false", success ? "ok" : "failed")
            return success
        } catch {
            NSLog("[AgentBridge] setHostEnabled error: %@", error.localizedDescription)
            return false
        }
    }

    /// Get the current relay host status from the web app.
    @available(iOS 15.0, macOS 13.0, *)
    public func getHostStatus() async -> [String: Any]? {
        guard let webView else { return nil }
        do {
            // The guard reports `callable-missing`, NOT a generic "not ready":
            // an absent callable means the web app's boot chain never registered
            // its native bridge, which is a broken boot — categorically different
            // from a mounted bridge reporting itself unavailable, and it is the
            // one the caller must be able to act on.
            let result = try await webView.callAsyncJavaScript(
                """
                if (!window.__ripulGetHostStatus) return {available:false, error:'\(Self.callableMissingError)'};
                return await window.__ripulGetHostStatus();
                """,
                contentWorld: .page
            )
            let dict = result as? [String: Any]
            // Feed the unavailability backstop. A `{available:false}` reply is a
            // SUCCESSFUL eval, so without this nothing else in the recovery
            // system ever learns that the host bridge is dead.
            if let dict {
                if (dict["available"] as? Bool) == true {
                    noteHostBridgeAvailable()
                } else {
                    noteHostBridgeUnavailable(reason: dict["error"] as? String ?? "available=false")
                }
            }
            return dict
        } catch {
            NSLog("[AgentBridge] getHostStatus error: %@", error.localizedDescription)
            noteHostBridgeUnavailable(reason: "eval failed: \(AgentBridge.describeEvalError(error))")
            return nil
        }
    }

    /// Get per-roomId ping/pong liveness diagnostics from the web app.
    /// Pass `roomId` to scope to one room, or `nil` to get all known rooms.
    /// Returns a dictionary with `pings`, `lastUpdatedAt`, and host metrics.
    @available(iOS 15.0, macOS 13.0, *)
    public func getRelayDiagnostics(roomId: String? = nil) async -> [String: Any]? {
        guard let webView else { return nil }
        do {
            let result = try await webView.callAsyncJavaScript(
                """
                if (!window.__ripulGetRelayDiagnostics) return {available:false, error:'\(Self.callableMissingError)'};
                return await window.__ripulGetRelayDiagnostics(roomId);
                """,
                arguments: ["roomId": roomId.map { $0 as Any } ?? NSNull()],
                contentWorld: .page
            )
            return result as? [String: Any]
        } catch {
            NSLog("[AgentBridge] getRelayDiagnostics error: %@", error.localizedDescription)
            return nil
        }
    }

    /// Get the comms-only warn/error ring (queue blocks, stalls, stuck chains,
    /// ping timeouts, delivery stalls/failures). Persisted across relaunch.
    @available(iOS 15.0, macOS 13.0, *)
    public func getCommsLog() async -> [String: Any]? {
        guard let webView else { return nil }
        do {
            let result = try await webView.callAsyncJavaScript(
                """
                if (!window.__ripulGetCommsLog) return {available:false, error:'not ready'};
                return await window.__ripulGetCommsLog();
                """,
                contentWorld: .page
            )
            return result as? [String: Any]
        } catch {
            NSLog("[AgentBridge] getCommsLog error: %@", error.localizedDescription)
            return nil
        }
    }

    /// Clear the comms-only warn/error ring (also wipes its persisted copy), so
    /// the Relay Host Stats "Comms warnings & errors" list can be emptied.
    @available(iOS 15.0, macOS 13.0, *)
    @discardableResult
    public func clearCommsLog() async -> Bool {
        guard let webView else { return false }
        do {
            let result = try await webView.callAsyncJavaScript(
                """
                if (!window.__ripulClearCommsLog) return {success:false, error:'not ready'};
                return await window.__ripulClearCommsLog();
                """,
                contentWorld: .page
            )
            return ((result as? [String: Any])?["success"] as? Bool) ?? false
        } catch {
            NSLog("[AgentBridge] clearCommsLog error: %@", error.localizedDescription)
            return false
        }
    }

    /// Read the most recent new-session connect phase trace (window.__ripulConnectPhase,
    /// stamped by markConnectPhase). The connection-diagnosis sheet uses this to show
    /// WHERE a connect stalled (local IndexedDB vs the relay handshake) instead of a
    /// generic "machine unavailable".
    @available(iOS 15.0, macOS 13.0, *)
    public func getConnectPhase() async -> String? {
        guard let webView else { return nil }
        do {
            let r = try await webView.callAsyncJavaScript(
                """
                const p = window.__ripulConnectPhase;
                if (!p) return null;
                return `${p.phase} (+${p.elapsedMs ?? 0}ms${p.detail ? ' — ' + p.detail : ''})`;
                """,
                contentWorld: .page
            )
            return r as? String
        } catch {
            return nil
        }
    }

    /// Reset the host high-watermarks (peaks) after reviewing them.
    @available(iOS 15.0, macOS 13.0, *)
    @discardableResult
    public func resetHostPeaks() async -> Bool {
        guard let webView else { return false }
        do {
            let result = try await webView.callAsyncJavaScript(
                """
                if (!window.__ripulResetHostPeaks) return {ok:false, error:'not ready'};
                return await window.__ripulResetHostPeaks();
                """,
                contentWorld: .page
            )
            return (result as? [String: Any])?["ok"] as? Bool ?? false
        } catch {
            NSLog("[AgentBridge] resetHostPeaks error: %@", error.localizedDescription)
            return false
        }
    }

    /// Send a kill command to a remote machine via the relay.
    /// The controller's web view sends a `machine:kill` command through
    /// the relay WebSocket; the target machine's guardian process handles it.
    public func killMachine(machineId: String, reason: String = "remote_user") async -> (success: Bool, error: String?) {
        guard let webView else { return (false, "WebView not available") }
        do {
            let result = try await webView.callAsyncJavaScript(
                """
                if (!window.__ripulKillMachine) return {success:false, error:'not ready'};
                return await window.__ripulKillMachine(machineId, reason);
                """,
                arguments: ["machineId": machineId, "reason": reason],
                contentWorld: .page
            )
            if let dict = result as? [String: Any] {
                return (dict["success"] as? Bool ?? false, dict["error"] as? String)
            }
            return (false, "Unexpected response")
        } catch {
            NSLog("[AgentBridge] killMachine error: %@", error.localizedDescription)
            return (false, error.localizedDescription)
        }
    }

    // MARK: - Send messages to web app

    public func setTheme(_ theme: AgentTheme) {
        let requestId = UUID().uuidString
        send([
            "type": "\(messagePrefix)theme:set",
            "version": protocolVersion,
            "timestamp": currentTimestamp(),
            "requestId": requestId,
            "theme": theme.rawValue,
        ])
    }

    // MARK: - Private helpers

    private var allTools: [NativeTool] {
        builtInTools + registeredTools
    }

    private var toolDefinitions: [[String: Any]] {
        allTools.map { $0.definition }
    }

    private func tool(named name: String) -> NativeTool? {
        allTools.first { $0.name == name }
    }

    // MARK: - Private handlers

    private func handleHandshake(_ message: [String: Any]) {
        NSLog("[AgentBridge] → Sending handshake:ack")
        var caps: [String: Any] = [
            "mcp": true,
            "dom": false,
            "storage": false,
            "llm": llmProvider != nil,
            "searchClick": searchClickDelegate != nil,
        ]
        for cap in capabilityRouter.availableCapabilities { caps[cap] = true }
        for (k, v) in extraCapabilities { caps[k] = v }

        send([
            "type": "\(messagePrefix)handshake:ack",
            "version": protocolVersion,
            "timestamp": currentTimestamp(),
            "capabilities": caps,
            "hostOrigin": "ripul-native://app",
        ])
        isConnected = true
        logSessionStartMarker("ios.bridge_connected")
        connectionTimeoutTask?.cancel()
        loadError = nil
        loadErrorDetails = nil
        jsErrorMessages = []
        jsErrorDebounce?.cancel()
        // Re-push measured chat input height now that the web app is ready
        resendInputHeight()

        if !allTools.isEmpty {
            let defs = toolDefinitions
            NSLog("[AgentBridge] → Broadcasting mcp:tools (%d tools)", defs.count)
            send([
                "type": "\(messagePrefix)mcp:tools",
                "version": protocolVersion,
                "timestamp": currentTimestamp(),
                "tools": defs,
            ])
        }

        // Auto-request sessions for native UI
        requestSessions()

        // A handshake means a FRESH web page (first load, reload, or a heal
        // reload after a crash). Its lifecycle store restarts at sequence 0, so
        // sequences recorded against the previous page are meaningless — keeping
        // them makes the ordering gate in applySessionPhase drop every snapshot
        // the new page sends, freezing the pause button on pre-reload state.
        // Phases are deliberately kept so the UI doesn't blank while resyncing.
        sessionLifecycleSequences.removeAll()

        // Sync agent button state then start accepting agent:status pushes.
        // The delay allows the web app to finish initializing before we query.
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5s
            await syncAgentStatus()
            initialStatusSyncComplete = true
        }

        // Post-crash auto-probe: runs after the bridge reconnects following a process termination
        if pendingPostCrashProbe {
            pendingPostCrashProbe = false
            Task {
                // Wait for the web app to settle after reload
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3s
                await probeWebViewHealth(trigger: "post-crash")
            }
        }
    }

    private func handleHostInfo(_ message: [String: Any]) {
        let requestId = message["requestId"] as? String ?? UUID().uuidString
        NSLog("[AgentBridge] → Sending host:info:response")
        send([
            "type": "\(messagePrefix)host:info:response",
            "version": protocolVersion,
            "timestamp": currentTimestamp(),
            "requestId": requestId,
            "url": "ripul-native://app",
            "title": "Ripul Native App (iOS)",
            "origin": "ripul-native://app",
        ])
    }

    private func handleMCPDiscover(_ message: [String: Any]) {
        let requestId = message["requestId"] as? String ?? UUID().uuidString
        let defs = toolDefinitions
        send([
            "type": "\(messagePrefix)mcp:tools",
            "version": protocolVersion,
            "timestamp": currentTimestamp(),
            "requestId": requestId,
            "tools": defs,
        ])
    }

    private func handleMCPInvoke(_ message: [String: Any]) {
        let requestId = message["requestId"] as? String ?? UUID().uuidString
        let toolName = message["toolName"] as? String ?? ""
        let args = message["args"] as? [String: Any] ?? [:]

        if let argsData = try? JSONSerialization.data(withJSONObject: args, options: .fragmentsAllowed),
           let argsJSON = String(data: argsData, encoding: .utf8) {
            NSLog("[AgentBridge] → Invoking tool: %@ args: %@", toolName, argsJSON)
        } else {
            NSLog("[AgentBridge] → Invoking tool: %@ with requestId: %@", toolName, requestId)
        }

        guard let tool = tool(named: toolName) else {
            NSLog("[AgentBridge] Tool not found: %@", toolName)
            send([
                "type": "\(messagePrefix)mcp:error",
                "version": protocolVersion,
                "timestamp": currentTimestamp(),
                "requestId": requestId,
                "error": "Tool not found: \(toolName)",
            ])
            return
        }

        Task { @MainActor in
            do {
                let result = try await tool.execute(args: args)
                NSLog("[AgentBridge] Tool %@ succeeded", toolName)

                // Validate that the result is JSON-serializable before sending.
                // If the tool returns a dict with non-JSON types (Date, Decimal, etc.)
                // JSONSerialization will fail silently in send(), losing the result.
                let safeResult: Any
                if let dict = result as? [String: Any],
                   !JSONSerialization.isValidJSONObject(["test": dict]) {
                    NSLog("[AgentBridge] Tool %@ result is not JSON-serializable, converting to description", toolName)
                    safeResult = ["_raw": String(describing: dict)]
                } else {
                    safeResult = result
                }

                self.send([
                    "type": "\(messagePrefix)mcp:result",
                    "version": protocolVersion,
                    "timestamp": self.currentTimestamp(),
                    "requestId": requestId,
                    "result": safeResult,
                ])
            } catch {
                NSLog("[AgentBridge] Tool %@ failed: %@", toolName, error.localizedDescription)
                self.send([
                    "type": "\(messagePrefix)mcp:error",
                    "version": protocolVersion,
                    "timestamp": self.currentTimestamp(),
                    "requestId": requestId,
                    "error": error.localizedDescription,
                ])
            }
        }
    }

    private func handleLLMGenerate(_ message: [String: Any]) {
        let requestId = message["requestId"] as? String ?? UUID().uuidString
        let threadId = message["threadId"] as? String ?? ""
        let systemPrompt = message["systemPrompt"] as? String ?? ""
        let timeline = message["timeline"] as? [[String: Any]] ?? []
        let tools = message["tools"] as? [[String: Any]] ?? []

        NSLog("[AgentBridge] LLM generate request — thread: %@, messages: %d, tools: %d",
              threadId, timeline.count, tools.count)

        guard let llmProvider else {
            NSLog("[AgentBridge] No LLM provider configured")
            send([
                "type": "\(messagePrefix)llm:generate:error",
                "version": protocolVersion,
                "timestamp": currentTimestamp(),
                "requestId": requestId,
                "error": "No LLM provider configured on native side",
                "code": "model_unavailable",
            ])
            return
        }

        Task { @MainActor in
            do {
                let result = try await llmProvider.generate(
                    threadId: threadId,
                    systemPrompt: systemPrompt,
                    timeline: timeline,
                    tools: tools
                )
                NSLog("[AgentBridge] LLM generated tool call: %@", result.toolName)
                self.send([
                    "type": "\(messagePrefix)llm:generate:response",
                    "version": protocolVersion,
                    "timestamp": self.currentTimestamp(),
                    "requestId": requestId,
                    "toolName": result.toolName,
                    "toolArgs": result.toolArgs,
                    "inputTokens": result.inputTokens,
                    "outputTokens": result.outputTokens,
                ])
            } catch {
                NSLog("[AgentBridge] LLM generate failed: %@", error.localizedDescription)
                self.send([
                    "type": "\(messagePrefix)llm:generate:error",
                    "version": protocolVersion,
                    "timestamp": self.currentTimestamp(),
                    "requestId": requestId,
                    "error": error.localizedDescription,
                    "code": "unknown",
                ])
            }
        }
    }

    private func handleSearchClick(_ message: [String: Any]) {
        let requestId = message["requestId"] as? String ?? UUID().uuidString
        let resultType = message["resultType"] as? String ?? "unknown"
        let resultId = message["resultId"] as? String
        let title = message["title"] as? String
        let url = message["url"] as? String
        let metadata = message["metadata"] as? [String: Any] ?? [:]

        NSLog("[AgentBridge] Search click — type: %@, id: %@, title: %@",
              resultType, resultId ?? "nil", title ?? "nil")

        let context = SearchClickContext(
            resultType: resultType,
            resultId: resultId,
            title: title,
            url: url,
            metadata: metadata
        )

        let handled = searchClickDelegate?.agentBridge(self, didClickSearchResult: context) ?? false

        send([
            "type": "\(messagePrefix)search:click:ack",
            "version": protocolVersion,
            "timestamp": currentTimestamp(),
            "requestId": requestId,
            "handled": handled,
        ])
    }

    private func handleScrollState(_ message: [String: Any]) {
        let show = message["showButton"] as? Bool ?? false
        if scrollButton.show != show {
            scrollButton.show = show
        }
        let count = message["unreadCount"] as? Int ?? 0
        if scrollButton.unreadCount != count {
            scrollButton.unreadCount = count
        }
    }

    /// Native chat scroller pipe.
    ///
    /// The web app forwards raw chat actions from `ChatActionsManager` over the
    /// bridge so the chat renders natively while the WKWebView stays a comms
    /// conduit. Routes into `nativeChat` (the scroller store) and logs a one-line
    /// trace so the pipe stays observable (ordering, ids, streaming).
    /// Enable from the web side via `window.__ripulSetNativeChatForwarding(true)`.
    private func handleNativeChatMessage(_ message: [String: Any]) {
        let kind = message["kind"] as? String ?? "?"
        if kind == "reset" {
            nativeChat.clear()
            handleConsoleLog("LOG: [NativeChat] reset (backfill starting)")
            return
        }
        guard let msg = message["message"] as? [String: Any] else {
            handleConsoleLog("LOG: [NativeChat] \(kind) — malformed (no message payload)")
            return
        }
        let messageId = msg["messageId"] as? String ?? "?"
        if kind == "update" {
            nativeChat.applyUpdate(msg)
            let thinking = msg["thinking"] as? [String: Any]
            let streaming = (thinking?["isStreaming"] as? Bool).map { String($0) } ?? "-"
            let len = (thinking?["content"] as? String)?.count ?? 0
            handleConsoleLog("LOG: [NativeChat] update id=\(messageId.suffix(6)) thinkingLen=\(len) streaming=\(streaming)")
        } else {
            nativeChat.applyAdd(msg)
            let role = msg["role"] as? String ?? "?"
            let method = msg["method"] as? String ?? "?"
            let content = msg["content"] as? String ?? ""
            let preview = content.count > 60 ? String(content.prefix(60)) + "…" : content
            handleConsoleLog("LOG: [NativeChat] add id=\(messageId.suffix(6)) role=\(role) method=\(method) count=\(nativeChat.messages.count) content=\"\(preview)\"")
        }
    }

    private func handleMastheadConfig(_ message: [String: Any]) {
        let text = message["text"] as? String
        let imageUrl = message["imageUrl"] as? String

        guard text != nil || imageUrl != nil else {
            mastheadConfig = nil
            updateNativeHeaderHeight()
            return
        }

        NSLog("[AgentBridge] Masthead config — text: %@, imageUrl: %@, imageWidth: %@",
              text ?? "(nil)", imageUrl ?? "(nil)", message["imageWidth"] as? String ?? "(nil)")

        mastheadConfig = MastheadConfig(
            text: text,
            imageUrl: imageUrl,
            backgroundColor: message["backgroundColor"] as? String,
            textColor: message["textColor"] as? String,
            height: (message["height"] as? NSNumber).map { CGFloat($0.doubleValue) },
            imageWidth: message["imageWidth"] as? String,
            fontSize: (message["fontSize"] as? NSNumber).map { CGFloat($0.doubleValue) },
            topOffset: (message["topOffset"] as? NSNumber).map { CGFloat($0.doubleValue) },
            glassStyle: message["glassStyle"] as? String
        )
        updateNativeHeaderHeight()
    }

    /// Re-inject `--native-header-height` CSS variable to account for the masthead.
    private func updateNativeHeaderHeight() {
        guard let webView else { return }
        let insetTop: CGFloat
        #if os(iOS)
        if let windowScene = webView.window?.windowScene {
            insetTop = windowScene.keyWindow?.safeAreaInsets.top ?? 54
        } else {
            insetTop = 54
        }
        #else
        insetTop = 0
        #endif
        let mastheadExtra = mastheadConfig != nil ? Int(mastheadConfig?.height ?? 48) + 12 : 0
        let totalHeight = Int(insetTop) + 44 + mastheadExtra
        let js = "document.documentElement.style.setProperty('--native-header-height', '\(totalHeight)px')"
        webView.evaluateJavaScript(js) { _, error in
            if let error {
                NSLog("[AgentBridge] Failed to update native header height: %@", error.localizedDescription)
            } else {
                NSLog("[AgentBridge] Updated --native-header-height: %dpx (masthead: %d)", totalHeight, mastheadExtra)
            }
        }
    }

    /// Tell the web view to scroll the active chat to the bottom.
    ///
    /// Calls the module-level `__ripulScrollToBottom` which finds the
    /// visible Virtuoso scroller via DOM query and emits an EventBus
    /// event so the active React component resets auto-scroll state.
    public func scrollToBottom() {
        NSLog("[AgentBridge] scrollToBottom -> JS bridge")
        evaluateVoidJavaScript("window.__ripulScrollToBottom?.()")
    }

    /// Navigate to the next or previous user message in the chat.
    /// - Parameter direction: `"up"` for previous, `"down"` for next.
    public func scrollToUserMessage(direction: String = "up") {
        NSLog("[AgentBridge] scrollToUserMessage(\(direction)) -> JS bridge")
        evaluateVoidJavaScript("window.__ripulScrollToUserMessage?.('\(direction)')")
    }

    /// Toggle the on-page element debugger HUD (`ElementDebuggerOverlay`).
    /// Called from the iPhone title-lozenge double-tap.
    public func toggleElementDebugger() {
        NSLog("[AgentBridge] toggleElementDebugger -> JS bridge")
        evaluateVoidJavaScript("window.__ripulToggleElementDebugger?.()")
    }

    /// Ask the web file viewer to close (triggered by the native back button).
    public func requestFileViewerClose() {
        NSLog("[AgentBridge] requestFileViewerClose")
        // Clear native state directly so the native file-viewer panel dismisses
        // immediately. The viewer is now a native StandaloneFileViewer panel (not the
        // in-chat web viewer), so we must not depend on a web round-trip to clear it.
        fileViewerExpanded = false
        fileViewerTitle = nil
        // Also close the (web-only) in-chat viewer if one is showing; harmless on native.
        evaluateVoidJavaScript("window.__ripulCloseFileViewer?.()")
    }

    /// Zoom in the markdown file viewer.
    public func fileViewerZoomIn() {
        evaluateVoidJavaScript("window.__ripulFileViewerZoomIn?.()")
    }

    /// Zoom out the markdown file viewer.
    public func fileViewerZoomOut() {
        evaluateVoidJavaScript("window.__ripulFileViewerZoomOut?.()")
    }

    /// Reset the markdown file viewer zoom to default.
    public func fileViewerZoomReset() {
        evaluateVoidJavaScript("window.__ripulFileViewerZoomReset?.()")
    }

    /// Toggle between rendered and raw markdown in the file viewer.
    public func fileViewerToggleRaw() {
        evaluateVoidJavaScript("window.__ripulFileViewerToggleRaw?.()")
    }

    /// Toggle word wrap in the Monaco file viewer.
    public func fileViewerToggleWordWrap() {
        evaluateVoidJavaScript("window.__ripulFileViewerToggleWordWrap?.()")
    }

    /// Set the find-in-file query. Returns total matches and the 1-based
    /// index of the current match (or 0 when there are no matches).
    @available(iOS 15.0, macOS 13.0, *)
    public func fileViewerFind(query: String) async -> RipulFindResult {
        guard let data = try? JSONEncoder().encode(query),
              let jsonStr = String(data: data, encoding: .utf8) else {
            return RipulFindResult(total: 0, current: 0)
        }
        do {
            let result = try await callAsyncJavaScript(
                "return window.__ripulFileViewerFind?.(\(jsonStr)) ?? { total: 0, current: 0 }"
            )
            return RipulFindResult.parse(result)
        } catch {
            NSLog("[AgentBridge] fileViewerFind error: %@", error.localizedDescription)
            return RipulFindResult(total: 0, current: 0)
        }
    }

    /// Advance to the next find match. Wraps at the end.
    @available(iOS 15.0, macOS 13.0, *)
    public func fileViewerFindNext() async -> RipulFindResult {
        do {
            let result = try await callAsyncJavaScript(
                "return window.__ripulFileViewerFindNext?.() ?? { total: 0, current: 0 }"
            )
            return RipulFindResult.parse(result)
        } catch {
            NSLog("[AgentBridge] fileViewerFindNext error: %@", error.localizedDescription)
            return RipulFindResult(total: 0, current: 0)
        }
    }

    /// Step back to the previous find match. Wraps at the start.
    @available(iOS 15.0, macOS 13.0, *)
    public func fileViewerFindPrev() async -> RipulFindResult {
        do {
            let result = try await callAsyncJavaScript(
                "return window.__ripulFileViewerFindPrev?.() ?? { total: 0, current: 0 }"
            )
            return RipulFindResult.parse(result)
        } catch {
            NSLog("[AgentBridge] fileViewerFindPrev error: %@", error.localizedDescription)
            return RipulFindResult(total: 0, current: 0)
        }
    }

    /// Emit a TodoItemCreate event in the web app to open the "Add To Do" dialog.
    public func emitTodoItemCreate() {
        evaluateVoidJavaScript("window.__ripulCreateTodoItem?.()")
    }

    /// Fetch the signed-in user's todo items from the web app, along with the
    /// currently active chat id so the picker can group "this chat" on top.
    /// Errors are caught internally and surface as an empty result so the
    /// native picker can show "No items" rather than crash.
    @available(iOS 15.0, macOS 12.0, *)
    public func listTodoItems() async -> RipulTodoItemsResult {
        guard let webView else {
            return RipulTodoItemsResult(items: [], currentChatId: nil)
        }
        do {
            let result = try await webView.callAsyncJavaScript(
                """
                if (!window.__ripulListTodoItems) return { items: [], currentChatId: null, error: '__ripulListTodoItems not defined' };
                return await window.__ripulListTodoItems();
                """,
                contentWorld: .page
            )
            guard let dict = result as? [String: Any] else {
                return RipulTodoItemsResult(items: [], currentChatId: nil)
            }
            let currentChatId = dict["currentChatId"] as? String
            let rawItems = dict["items"] as? [[String: Any]] ?? []
            let items: [RipulTodoItem] = rawItems.compactMap { item in
                guard let id = item["id"] as? String,
                      let text = item["text"] as? String else { return nil }
                let chatId = item["chatId"] as? String
                let chatName = item["chatName"] as? String
                let completed = item["completed"] as? Bool ?? false
                return RipulTodoItem(
                    id: id,
                    chatId: chatId,
                    chatName: chatName,
                    text: text,
                    completed: completed
                )
            }
            return RipulTodoItemsResult(items: items, currentChatId: currentChatId)
        } catch {
            NSLog("[AgentBridge] listTodoItems error: %@", error.localizedDescription)
            return RipulTodoItemsResult(items: [], currentChatId: nil)
        }
    }

    /// Open a file in the web file viewer (e.g. from native Saved Files sheet).
    public func openFavoriteFile(_ path: String) {
        if let data = try? JSONEncoder().encode(path),
           let jsonStr = String(data: data, encoding: .utf8) {
            evaluateVoidJavaScript("window.__ripulOpenFileViewer?.(\(jsonStr))")
        }
    }

    /// Result of creating a new chat with a prefilled prompt. Callers need both
    /// ids: `chatId` (the sourceChatId — what the composer's pending-prefill and
    /// eventBus key off) and `tabId` (the descriptor id — what setRawMode,
    /// setChatModel, and `ChatSession.id` all use). They are often the same but
    /// can diverge for remote-paired tabs. `machineId` is non-nil when the new
    /// chat inherited a remote-machine pairing from the previously active chat.
    public struct NewChatResult {
        public let chatId: String
        public let tabId: String
        public let machineId: String?
    }

    /// Create a new chat and prefill its composer with `prompt`. Does not
    /// auto-send — the user reviews/edits before submitting. Returns both ids
    /// on success, or nil on failure.
    @available(iOS 15.0, macOS 13.0, *)
    public func startNewChatWithPrompt(_ prompt: String) async -> NewChatResult? {
        guard let data = try? JSONEncoder().encode(prompt),
              let jsonStr = String(data: data, encoding: .utf8) else { return nil }
        do {
            let result = try await callAsyncJavaScript(
                "if (!window.__ripulStartNewChatWithPrompt) return { success: false, error: '__ripulStartNewChatWithPrompt not defined' }; return await window.__ripulStartNewChatWithPrompt(\(jsonStr))"
            )
            guard let dict = result as? [String: Any] else { return nil }
            if let success = dict["success"] as? Bool, success,
               let chatId = dict["chatId"] as? String,
               let tabId = dict["tabId"] as? String {
                let machineId = dict["machineId"] as? String
                // Same new-chat handoff as createNewChat/startNewChat.
                pendingActiveSourceChatId = chatId
                refreshActiveAgentFlags()
                return NewChatResult(chatId: chatId, tabId: tabId, machineId: machineId)
            }
            if let err = dict["error"] as? String {
                NSLog("[AgentBridge] startNewChatWithPrompt: web error %@", err)
            }
            return nil
        } catch {
            NSLog("[AgentBridge] startNewChatWithPrompt error: %@", error.localizedDescription)
            return nil
        }
    }

    /// Search for files on the connected remote machine.
    /// Returns an array of `{ path, isDirectory }` dictionaries.
    /// Use `offset` for pagination (each page returns up to 25 results).
    @available(iOS 15.0, macOS 13.0, *)
    public func searchRemoteFiles(query: String, offset: Int = 0) async -> [(path: String, isDirectory: Bool)] {
        guard let data = try? JSONEncoder().encode(query),
              let jsonStr = String(data: data, encoding: .utf8) else { return [] }
        do {
            let result = try await callAsyncJavaScript(
                "return await window.__ripulSearchFiles?.(\(jsonStr), \(offset)) ?? []"
            )
            guard let arr = result as? [[String: Any]] else { return [] }
            return arr.compactMap { dict in
                guard let path = dict["path"] as? String else { return nil }
                let isDir = dict["isDirectory"] as? Bool ?? false
                return (path: path, isDirectory: isDir)
            }
        } catch {
            NSLog("[AgentBridge] searchRemoteFiles error: %@", error.localizedDescription)
            return []
        }
    }

    /// List the direct children of a specific remote directory.
    /// Accepts absolute paths, `~`-prefixed paths, or paths relative to the
    /// session's working directory. Returns the entries and an optional error
    /// string if the listing failed (path missing, not a directory, etc.).
    @available(iOS 15.0, macOS 13.0, *)
    public func listRemoteDirectory(path: String) async -> (entries: [(path: String, isDirectory: Bool)], error: String?) {
        guard let data = try? JSONEncoder().encode(path),
              let jsonStr = String(data: data, encoding: .utf8) else {
            return (entries: [], error: "Unable to encode path")
        }
        do {
            let result = try await callAsyncJavaScript(
                "return await window.__ripulListDirectory?.(\(jsonStr)) ?? { entries: [] }"
            )
            guard let dict = result as? [String: Any] else {
                return (entries: [], error: "Malformed response")
            }
            let arr = (dict["entries"] as? [[String: Any]]) ?? []
            let entries: [(path: String, isDirectory: Bool)] = arr.compactMap { d in
                guard let p = d["path"] as? String else { return nil }
                let isDir = d["isDirectory"] as? Bool ?? false
                return (path: p, isDirectory: isDir)
            }
            let err = dict["error"] as? String
            return (entries: entries, error: err)
        } catch {
            NSLog("[AgentBridge] listRemoteDirectory error: %@", error.localizedDescription)
            return (entries: [], error: error.localizedDescription)
        }
    }

    /// Grep the contents of tracked files on the connected remote machine.
    /// Returns hits with path, 1-based line number, and a snippet of the line.
    @available(iOS 15.0, macOS 13.0, *)
    public func grepRemoteFiles(query: String, maxResults: Int = 100) async -> [RipulGrepHit] {
        guard let data = try? JSONEncoder().encode(query),
              let jsonStr = String(data: data, encoding: .utf8) else { return [] }
        do {
            let result = try await callAsyncJavaScript(
                "return await window.__ripulGrepRemoteFiles?.(\(jsonStr), \(maxResults)) ?? []"
            )
            guard let arr = result as? [[String: Any]] else { return [] }
            return arr.compactMap { dict in
                guard let path = dict["path"] as? String else { return nil }
                let line = (dict["line"] as? Int) ?? Int((dict["line"] as? Double) ?? 0)
                let snippet = (dict["snippet"] as? String) ?? ""
                return RipulGrepHit(path: path, line: line, snippet: snippet)
            }
        } catch {
            NSLog("[AgentBridge] grepRemoteFiles error: %@", error.localizedDescription)
            return []
        }
    }

    /// Read a file's content from the connected remote machine. Pass `chatId` so the
    /// read targets the paired machine for that chat (matches the reliable in-chat
    /// viewer path); without it the web falls back to the active chat id.
    @available(iOS 15.0, macOS 13.0, *)
    public func readRemoteFile(path: String, chatId: String? = nil) async -> String? {
        func jsonString(_ value: String) -> String? {
            guard let data = try? JSONEncoder().encode(value) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        guard let pathStr = jsonString(path) else { return nil }
        let chatIdStr = chatId.flatMap(jsonString) ?? "null"
        do {
            let result = try await callAsyncJavaScript(
                "return await window.__ripulReadRemoteFile?.(\(pathStr), \(chatIdStr))"
            )
            guard let dict = result as? [String: Any] else { return nil }
            return dict["content"] as? String
        } catch {
            NSLog("[AgentBridge] readRemoteFile error: %@", error.localizedDescription)
            return nil
        }
    }

    /// Poll the file-viewer web view until its inject hook is registered (i.e.
    /// FileViewerManager has mounted in file-viewer bootstrap mode). The viewer
    /// loads a FULL web app, which routinely takes longer than a fixed delay —
    /// injecting before it was ready dropped the content on the floor (spinner ->
    /// "host did not respond"; it only "worked once" when the app happened to boot
    /// within the old 500ms).
    @available(iOS 15.0, macOS 13.0, *)
    public func waitForFileViewerReady(timeout: TimeInterval = 12) async {
        let start = CFAbsoluteTimeGetCurrent()
        while CFAbsoluteTimeGetCurrent() - start < timeout {
            if let ready = try? await callAsyncJavaScript(
                "return typeof window.__ripulInjectFileContent === 'function'"
            ) as? Bool, ready {
                return
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    /// Inject pre-fetched file content into a file-viewer web view. Waits for the
    /// viewer to be ready first so the content is never dropped into a web app that
    /// hasn't mounted yet.
    @available(iOS 15.0, macOS 13.0, *)
    public func injectFileContent(_ content: String) {
        guard let data = try? JSONEncoder().encode(content),
              let jsonStr = String(data: data, encoding: .utf8) else { return }
        Task { @MainActor in
            await waitForFileViewerReady()
            try? await callAsyncJavaScript("window.__ripulInjectFileContent?.(\(jsonStr))")
        }
    }

    /// Signal that file content could not be read, so the viewer stops showing a
    /// loading spinner and displays an error instead. Also waits for readiness.
    @available(iOS 15.0, macOS 13.0, *)
    public func injectFileError(_ message: String) {
        guard let data = try? JSONEncoder().encode(message),
              let jsonStr = String(data: data, encoding: .utf8) else { return }
        Task { @MainActor in
            await waitForFileViewerReady()
            try? await callAsyncJavaScript("window.__ripulInjectFileError?.(\(jsonStr))")
        }
    }

    /// Log a message to this web view's JS console (visible via device_console_logs).
    /// For native-side diagnostics that need to be visible without Xcode.
    @available(iOS 15.0, macOS 13.0, *)
    public func logToWebConsole(_ message: String) {
        guard let data = try? JSONEncoder().encode(message),
              let jsonStr = String(data: data, encoding: .utf8) else { return }
        evaluateJavaScript("console.log(\(jsonStr))")
    }

    private func handleSessionsListResponse(_ message: [String: Any]) {
        guard let sessionsArray = message["sessions"] as? [[String: Any]] else { return }
        let activeId = message["activeId"] as? String

        let parsed: [ChatSession] = sessionsArray.compactMap { dict in
            guard let id = dict["id"] as? String,
                  let sourceChatId = dict["sourceChatId"] as? String,
                  let displayName = dict["displayName"] as? String else { return nil }
            let createdAtMs = dict["createdAt"] as? Double ?? 0
            let createdAt = Date(timeIntervalSince1970: createdAtMs / 1000)
            let remoteMachineName = dict["remoteMachineName"] as? String
            let provider = dict["provider"] as? String
            let providerLabel = dict["providerLabel"] as? String
            let hostChatId = dict["hostChatId"] as? String
            let sizeBytes = (dict["sizeBytes"] as? NSNumber)?.intValue
            let displayNameSource = dict["displayNameSource"] as? String
            let displayNameRenamedAt = (dict["displayNameRenamedAt"] as? NSNumber)?.doubleValue
            return ChatSession(id: id, sourceChatId: sourceChatId, displayName: displayName, createdAt: createdAt,
                               remoteMachineName: remoteMachineName,
                               provider: provider, providerLabel: providerLabel,
                               hostChatId: hostChatId,
                               sizeBytes: sizeBytes,
                               displayNameSource: displayNameSource,
                               displayNameRenamedAt: displayNameRenamedAt)
        }

        // Filter out ephemeral commit-viewer sessions (tracked explicitly
        // by CommitsScreen via ephemeralSessionIds, persisted to UserDefaults).
        let filtered = parsed.filter { !self.ephemeralSessionIds.contains($0.id) }

        // Only update sessions when we get data. Never clear a good cached
        // list with an empty response (timing race during web app init).
        if !filtered.isEmpty {
            // Detect CLI session renames before overwriting self.sessions.
            // Only fire for displayNames sourced from CLI history or explicit
            // user renames; "auto" values (descriptor in-memory or date
            // fallback) must NOT round-trip into the JSONL.
            if self.sessions != filtered {
                let oldByID = Dictionary(self.sessions.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
                let isInitialLoad = oldByID.isEmpty
                for session in filtered {
                    // claude-cli only — see the matching gate in the
                    // sessions-changed path above.
                    if session.provider == "claude-cli" {
                        let source = session.displayNameSource ?? "user"
                        let isAuthoritative = source == "cli" || source == "user"
                        if !isAuthoritative {
                            Self.debugLog("[AgentBridge] handleSessionsListResponse: SKIP_AUTO '\(session.displayName)' (sourceChatId=\(session.sourceChatId))")
                        } else if isInitialLoad {
                            Self.debugLog("[AgentBridge] handleSessionsListResponse: INITIAL_SYNC '\(session.displayName)' src=\(source) (sourceChatId=\(session.sourceChatId))")
                            self.onCliSessionRenamed?(session.sourceChatId, session.displayName, session.displayNameRenamedAt)
                        } else if let old = oldByID[session.id], old.displayName != session.displayName {
                            Self.debugLog("[AgentBridge] handleSessionsListResponse: CLI rename detected '\(old.displayName)' → '\(session.displayName)' src=\(source) (sourceChatId=\(session.sourceChatId))")
                            self.onCliSessionRenamed?(session.sourceChatId, session.displayName, session.displayNameRenamedAt)
                        }
                    }
                }
            }
            self.sessions = filtered
            ChatSession.saveToCache(filtered)
            applyActiveSessionIdFromResponse(activeId)
            sessionsRetryCount = 0
            NSLog("[AgentBridge] Sessions updated: %d sessions (%d commit-view filtered), active: %@",
                  filtered.count, parsed.count - filtered.count, activeId ?? "nil")
        } else if sessions.isEmpty {
            // Only update active ID when we truly have no sessions yet
            applyActiveSessionIdFromResponse(activeId)
            NSLog("[AgentBridge] Empty sessions response (no cache)")
        } else {
            // Keep cached sessions, just update active ID
            applyActiveSessionIdFromResponse(activeId)
            NSLog("[AgentBridge] Empty sessions response, keeping %d cached sessions", sessions.count)
        }

        // If the web app returned empty sessions and we have no cache,
        // it may not have initialized its chat tab state yet. Retry.
        if parsed.isEmpty && sessions.isEmpty && sessionsRetryCount < Self.maxSessionsRetries {
            sessionsRetryCount += 1
            let attempt = sessionsRetryCount
            NSLog("[AgentBridge] No sessions, retrying (%d/%d)...", attempt, Self.maxSessionsRetries)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.requestSessions()
            }
        }
    }

    private func handleChatNewAck(_ message: [String: Any]) {
        let success = message["success"] as? Bool ?? false
        let chatId = message["chatId"] as? String
        NSLog("[AgentBridge] Chat new ack: success=%@, chatId=%@",
              success ? "true" : "false", chatId ?? "nil")

        if success {
            // Request updated sessions list so the native UI reflects the new tab.
            // Small delay to give the web app time to finalize the tab state.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.requestSessions()
            }
        }
    }

    // MARK: - Todo State (pinned lozenge + Dynamic Island)

    private func handleTodoStateUpdate(_ dict: [String: Any]) {
        guard let chatId = dict["chatId"] as? String,
              let version = dict["stateVersion"] as? Int,
              let itemDicts = dict["todos"] as? [[String: Any]] else {
            NSLog("[AgentBridge] todos:update — missing fields")
            return
        }

        // Ordering guard — drop out-of-order updates.
        if let existing = sessionList.todoStates[chatId], existing.version >= version {
            return
        }

        let items: [TodoItem] = itemDicts.compactMap { d in
            guard let content = d["content"] as? String,
                  let status = d["status"] as? String else { return nil }
            return TodoItem(
                content: content,
                status: status,
                activeForm: d["activeForm"] as? String
            )
        }
        let state = TodoState(version: version, todos: items, updatedAt: Date())
        sessionList.todoStates[chatId] = state
        todoStateSubject.send((chatId, state))
        NSLog("[AgentBridge] todos:update chatId=%@ version=%d items=%d",
              chatId, version, items.count)

        // If the user is already inside this chat, mark the new version as
        // viewed immediately so the session list doesn't flash the plan
        // summary row the instant they navigate back out. The title-bar
        // lozenge (which uses `sessionList.dismissedTodoVersions`) is unaffected.
        if let activeId = activeSessionId,
           let session = sessions.first(where: { $0.id == activeId }),
           session.sourceChatId == chatId {
            sessionList.listViewedTodoVersions[chatId] = version
        }
    }

    /// Called by the native lozenge's Dismiss button. Scopes the dismissal to
    /// the current version only — the next TodoWrite update (new version)
    /// re-shows the lozenge automatically.
    public func dismissTodoState(chatId: String) {
        guard let current = sessionList.todoStates[chatId] else { return }
        sessionList.dismissedTodoVersions[chatId] = current.version
        // Signal high-frequency consumers (Live Activity) to clear.
        todoStateSubject.send((chatId, nil))
    }

    /// Returns the todo state that should currently be visible for a chat,
    /// honoring any dismissal. Used by the title-bar lozenge to decide
    /// whether to render.
    // These methods delegate to SessionListStore so call sites that haven't
    // yet migrated to reading from bridge.sessionList directly keep compiling.
    public func visibleTodoState(for chatId: String) -> TodoState? {
        sessionList.visibleTodoState(for: chatId)
    }

    public func visibleTodoStateForList(for chatId: String) -> TodoState? {
        sessionList.visibleTodoStateForList(for: chatId)
    }

    public func latestToolLabelForList(for chatId: String) -> String? {
        sessionList.latestToolLabelForList(for: chatId)
    }

    public func latestToolActivityForList(for chatId: String) -> AgentActivityEvent? {
        sessionList.latestToolActivityForList(for: chatId)
    }

    /// Mark the currently-active session's todo state as viewed in the
    /// session list. Called automatically on `activeSessionId` changes and
    /// when a new todo update lands for a chat the user is already viewing.
    private func markActiveSessionTodoViewedInList() {
        guard let activeId = activeSessionId,
              let session = sessions.first(where: { $0.id == activeId }),
              let state = sessionList.todoStates[session.sourceChatId] else { return }
        sessionList.listViewedTodoVersions[session.sourceChatId] = state.version
    }

    // MARK: - Browser Capability Routing

    private func handleCapabilityRequest(_ message: [String: Any]) {
        let requestId = message["id"] as? String ?? UUID().uuidString
        let capability = message["capability"] as? String ?? ""
        let method = message["method"] as? String ?? ""
        let args = message["args"] as? [Any] ?? []

        NSLog("[AgentBridge] Capability request: %@.%@", capability, method)

        Task { @MainActor in
            do {
                let result = try await self.capabilityRouter.invoke(
                    capability: capability,
                    method: method,
                    args: args
                )
                // Validate JSON serializability before sending
                if !JSONSerialization.isValidJSONObject(["r": result]) {
                    // Wrap primitive in array for validation
                    self.send([
                        "type": "\(messagePrefix)capability:response",
                        "version": protocolVersion,
                        "timestamp": currentTimestamp(),
                        "id": requestId,
                        "success": true,
                        "result": "\(result)",
                    ])
                } else {
                    self.send([
                        "type": "\(messagePrefix)capability:response",
                        "version": protocolVersion,
                        "timestamp": currentTimestamp(),
                        "id": requestId,
                        "success": true,
                        "result": result,
                    ])
                }
            } catch {
                let capError = error as? CapabilityError
                self.send([
                    "type": "\(messagePrefix)capability:response",
                    "version": protocolVersion,
                    "timestamp": currentTimestamp(),
                    "id": requestId,
                    "success": false,
                    "error": error.localizedDescription,
                    "errorCode": capError?.errorCode ?? "EXECUTION_FAILED",
                ])
            }
        }
    }

    /// Web → native mirror of host-mode preferences (hostEnabled / machineName).
    /// Mirrored in UserDefaults so a web-data wipe or heal purge can't silently
    /// disable hosting; the values are re-injected as window.__ripulHostPrefs on
    /// the next load (AgentWebView.hostPreferencesScript) and refreshed live here.
    private func handleHostPrefsSet(_ dict: [String: Any]) {
        if let enabled = dict["hostEnabled"] as? Bool {
            HostPreferences.hostEnabled = enabled
        }
        if let name = dict["machineName"] as? String {
            HostPreferences.machineName = name
        }
        pushHostPrefsToPage()
    }

    /// Web → native mirror of the long-lived machine token. Stored in the
    /// keychain so it survives web-data purges and can keep host comms alive
    /// when the Clerk session expires.
    private func handleHostTokenSet(_ dict: [String: Any]) {
        guard let token = dict["token"] as? String,
              let userId = dict["userId"] as? String,
              let machineId = dict["machineId"] as? String else {
            NSLog("[AgentBridge] Ignoring malformed host-token:set")
            return
        }
        let expiry = (dict["expiry"] as? TimeInterval).flatMap { Date(timeIntervalSince1970: $0) }
        MachineTokenStore.setToken(token, userId: userId, machineId: machineId, expiry: expiry)
        pushHostTokenToPage()
    }

    /// Refresh the live page's host token mirror.
    private func pushHostTokenToPage() {
        if let token = MachineTokenStore.token {
            let escaped = token
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            evaluateJavaScript("window.__ripulHostToken = \"\(escaped)\";")
        } else {
            evaluateJavaScript("window.__ripulHostToken = null;")
        }
    }

    /// Refresh the live page's host-prefs mirror so reloads of THIS webview see
    /// the latest values (the documentStart script is baked at webview creation).
    private func pushHostPrefsToPage() {
        evaluateJavaScript("window.__ripulHostPrefs = \(HostPreferences.injectionJSON);")
    }

    private func handleCapabilityPing(_ message: [String: Any]) {
        let requestId = message["id"] as? String ?? UUID().uuidString
        let caps = capabilityRouter.availableCapabilities + ["mcp"]
        send([
            "type": "\(messagePrefix)capability:pong",
            "version": protocolVersion,
            "timestamp": currentTimestamp(),
            "id": requestId,
            "success": true,
            "result": caps,
        ])

        // Capability ping proves the bridge is alive — treat it like a handshake.
        // The NativeBridgedContext sends capability:ping instead of the legacy handshake.
        if !isConnected {
            isConnected = true
            connectionTimeoutTask?.cancel()
            loadError = nil
            loadErrorDetails = nil
            jsErrorMessages = []
            jsErrorDebounce?.cancel()
            NSLog("[AgentBridge] Bridge connected via capability:ping")

            // Fresh web page — drop stale per-chat sequences (see the matching
            // note in the handshake path above).
            sessionLifecycleSequences.removeAll()

            // Broadcast MCP tools if any are registered
            if !allTools.isEmpty {
                let defs = toolDefinitions
                send([
                    "type": "\(messagePrefix)mcp:tools",
                    "version": protocolVersion,
                    "timestamp": currentTimestamp(),
                    "tools": defs,
                ])
            }

            // Sync agent button state after a short delay so it overrides any stale
            // agent:status pushes the web app emits during initialization.
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5s
                await syncAgentStatus()
            }

            // Post-crash auto-probe
            if pendingPostCrashProbe {
                pendingPostCrashProbe = false
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000) // 3s
                    await probeWebViewHealth(trigger: "post-crash")
                }
            }
        }
    }

    // MARK: - Transport

    public func send(_ message: [String: Any]) {
        guard let webView else {
            NSLog("[AgentBridge] Cannot send — webView is nil")
            return
        }

        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let json = String(data: data, encoding: .utf8) else {
            NSLog("[AgentBridge] Failed to serialize message — sending fallback error")
            sendSerializationFallback(message: message, webView: webView)
            return
        }

        let js = "window.__agentBridgeReceive(\(json))"
        webView.evaluateJavaScript(js) { _, error in
            if let error {
                NSLog("[AgentBridge] JS eval error: %@", error.localizedDescription)
            }
        }
    }

    /// Last-resort fallback when `send()` can't serialize a message.
    /// Constructs a minimal mcp:error JSON string by hand so the LLM
    /// always sees *something* instead of a silent drop.
    private func sendSerializationFallback(message: [String: Any], webView: WKWebView) {
        let requestId = (message["requestId"] as? String ?? "unknown")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let messageType = message["type"] as? String ?? "unknown"

        let fallback = """
        {"type":"\(messagePrefix)mcp:error","version":"\(protocolVersion)",\
        "timestamp":\(currentTimestamp()),"requestId":"\(requestId)",\
        "error":"Native bridge failed to serialize the response for \(messageType). \
        The tool may have succeeded but returned non-JSON-safe data."}
        """
        let js = "window.__agentBridgeReceive(\(fallback))"
        webView.evaluateJavaScript(js) { _, error in
            if let error {
                NSLog("[AgentBridge] Fallback JS eval error: %@", error.localizedDescription)
            }
        }
    }

    // MARK: - User Interaction (native multichoice)

    private func handleUserInteractionMultiChoice(_ dict: [String: Any]) {
        guard let responseKey = dict["responseKey"] as? String,
              let question = dict["question"] as? String,
              let rawOptions = dict["options"] as? [[String: Any]] else {
            NSLog("[AgentBridge] Invalid userInteraction:multiChoice payload")
            return
        }

        let multiSelect = dict["multiSelect"] as? Bool ?? false
        let options = rawOptions.map { raw in
            UserInteractionQuestion.Option(
                label: raw["label"] as? String ?? "",
                value: raw["value"] ?? raw["label"] ?? "",
                description: raw["description"] as? String,
                link: raw["link"] as? String
            )
        }

        // Parse structured table rows if present
        var table: [[String: String]]?
        if let rawTable = dict["table"] as? [[String: Any]] {
            table = rawTable.map { row in
                var mapped: [String: String] = [:]
                for (key, value) in row {
                    mapped[key] = "\(value)"
                }
                return mapped
            }
        }

        pendingUserInteraction = UserInteractionQuestion(
            id: responseKey,
            question: question,
            options: options,
            multiSelect: multiSelect,
            table: table
        )
    }

    /// Send the user's selection back to the web app and clear the pending question.
    public func respondToUserInteraction(answer: Any) {
        guard let interaction = pendingUserInteraction else { return }
        send([
            "type": "\(messagePrefix)userInteraction:response",
            "version": protocolVersion,
            "timestamp": currentTimestamp(),
            "responseKey": interaction.id,
            "answer": answer,
        ])
        pendingUserInteraction = nil
    }

    /// Send the user's text response back to the web app and clear the pending question.
    public func respondToTextQuestion(answer: String) {
        guard let question = pendingTextQuestion else { return }
        send([
            "type": "\(messagePrefix)userInteraction:response",
            "version": protocolVersion,
            "timestamp": currentTimestamp(),
            "responseKey": question.id,
            "answer": answer,
        ])
        pendingTextQuestion = nil
    }

    /// Send the user's date selection back to the web app and clear the pending question.
    public func respondToDateQuestion(answer: String) {
        guard let question = pendingDateQuestion else { return }
        send([
            "type": "\(messagePrefix)userInteraction:response",
            "version": protocolVersion,
            "timestamp": currentTimestamp(),
            "responseKey": question.id,
            "answer": answer,
        ])
        pendingDateQuestion = nil
    }

    private func handleUserInteractionText(_ dict: [String: Any]) {
        guard let responseKey = dict["responseKey"] as? String,
              let question = dict["question"] as? String else {
            NSLog("[AgentBridge] Invalid userInteraction:text payload")
            return
        }
        pendingTextQuestion = UserTextQuestion(id: responseKey, question: question)
    }

    private func handleUserInteractionDate(_ dict: [String: Any]) {
        guard let responseKey = dict["responseKey"] as? String,
              let question = dict["question"] as? String else {
            NSLog("[AgentBridge] Invalid userInteraction:date payload")
            return
        }

        let includeTime = dict["includeTime"] as? Bool ?? false

        let minDate = (dict["minDate"] as? String).flatMap { Self.parseDateString($0) }
        let maxDate = (dict["maxDate"] as? String).flatMap { Self.parseDateString($0) }
        let defaultDate = (dict["defaultDate"] as? String).flatMap { Self.parseDateString($0) }

        pendingDateQuestion = UserDateQuestion(
            id: responseKey,
            question: question,
            includeTime: includeTime,
            minDate: minDate,
            maxDate: maxDate,
            defaultDate: defaultDate
        )
    }

    /// Parse a date string in either "YYYY-MM-DD" or "YYYY-MM-DDTHH:mm" format.
    private static func parseDateString(_ string: String) -> Date? {
        // Try datetime format first (YYYY-MM-DDTHH:mm)
        let dtFormatter = DateFormatter()
        dtFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        dtFormatter.locale = Locale(identifier: "en_US_POSIX")
        if let date = dtFormatter.date(from: string) { return date }

        // Fall back to date-only (YYYY-MM-DD)
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withFullDate]
        return dateFormatter.date(from: string)
    }

    private func currentTimestamp() -> Int {
        Int(Date().timeIntervalSince1970 * 1000)
    }
}
