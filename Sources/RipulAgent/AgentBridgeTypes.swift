import Foundation
#if canImport(UIKit)
import UIKit
#endif

// What AgentBridge hands to the app: the sessions, models, accounts, log
// entries and events it reads from the web app, as Swift values.

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
    /// Catalog model id pinned to this session (e.g. "backend-claude-fable-5"),
    /// or nil when the session runs the global default. Feeds ModelIdentity so
    /// non-CLI API chats get a model-aligned row icon.
    public var model: String?
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
    /// Repo / project folder the session is working in, published over
    /// SessionChannel (`session.facts`). Only carries a value on a tab that
    /// can't discover it locally — a share-link guest, whose synthetic pairing
    /// is never scanned. On a machine that can scan for itself, the remote row
    /// supplies this and the field stays nil.
    public var projectName: String?
    /// Git branch, from the same publish. No absolute path travels with it.
    public var gitBranch: String?
    /// True for a chat reached only through someone else's accepted share
    /// invitation. Such a chat has no host machine of its own to archive or
    /// delete against — it drives Remove-chat/Leave-chat instead of
    /// Archive/Delete in the session list. Optional (not Bool with a
    /// property default) so a cache written before this field existed
    /// decodes as nil rather than throwing — see displayNameSource above.
    public var isSharedGuest: Bool?

    public init(
        id: String,
        sourceChatId: String,
        displayName: String,
        createdAt: Date,
        remoteMachineName: String? = nil,
        provider: String? = nil,
        providerLabel: String? = nil,
        model: String? = nil,
        hostChatId: String? = nil,
        sizeBytes: Int? = nil,
        displayNameSource: String? = nil,
        displayNameRenamedAt: Double? = nil,
        projectName: String? = nil,
        gitBranch: String? = nil,
        isSharedGuest: Bool? = nil
    ) {
        self.id = id
        self.sourceChatId = sourceChatId
        self.displayName = displayName
        self.createdAt = createdAt
        self.remoteMachineName = remoteMachineName
        self.provider = provider
        self.providerLabel = providerLabel
        self.model = model
        self.hostChatId = hostChatId
        self.sizeBytes = sizeBytes
        self.displayNameSource = displayNameSource
        self.displayNameRenamedAt = displayNameRenamedAt
        self.projectName = projectName
        self.gitBranch = gitBranch
        self.isSharedGuest = isSharedGuest
    }

    /// Navigation seed from a successful creation reply. Keep tab identity and
    /// source identity separate; neither implies the host's handshake identity.
    static func creationSeed(
        from result: [String: Any],
        providerKey: String? = nil,
        modelId: String? = nil
    ) -> ChatSession? {
        guard result["success"] as? Bool == true,
              let tabId = result["tabId"] as? String, !tabId.isEmpty,
              let chatId = result["chatId"] as? String, !chatId.isEmpty else { return nil }
        return ChatSession(
            id: tabId, sourceChatId: chatId,
            displayName: "New Chat", createdAt: Date(),
            remoteMachineName: result["machineName"] as? String,
            provider: providerKey,
            providerLabel: providerKey.flatMap { ProviderConstants.byProviderKey($0)?.displayLabel },
            model: modelId,
            hostChatId: result["hostChatId"] as? String,
            displayNameSource: "auto"
        )
    }

    /// One decoder for the session wire shape, shared by the pull path
    /// (`__ripulGetSessions`) and the push path (`sessions:list:response`).
    /// They used to be two hand-copied parsers, and the push one had silently
    /// dropped `modelId` — so every push, which fires exactly when the web
    /// learns a session's model, erased the model the pull had just read.
    static func fromWire(_ item: [String: Any]) -> ChatSession? {
        guard let id = item["id"] as? String,
              let sourceChatId = item["sourceChatId"] as? String,
              let displayName = item["displayName"] as? String else { return nil }
        let createdAtMs = item["createdAt"] as? Double ?? 0
        return ChatSession(
            id: id, sourceChatId: sourceChatId,
            displayName: displayName,
            createdAt: Date(timeIntervalSince1970: createdAtMs / 1000),
            remoteMachineName: item["remoteMachineName"] as? String,
            provider: item["provider"] as? String,
            providerLabel: item["providerLabel"] as? String,
            model: item["modelId"] as? String,
            hostChatId: item["hostChatId"] as? String,
            sizeBytes: (item["sizeBytes"] as? NSNumber)?.intValue,
            displayNameSource: item["displayNameSource"] as? String,
            displayNameRenamedAt: (item["displayNameRenamedAt"] as? NSNumber)?.doubleValue,
            projectName: item["projectName"] as? String,
            gitBranch: item["gitBranch"] as? String,
            isSharedGuest: item["isSharedGuest"] as? Bool
        )
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
public struct ModelInfo: Identifiable, Equatable, Codable {
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
    public let cliEffort: String?   // low | medium | high | xhigh | max | ultra
    public let cliMode: String?     // session | stateless

    /// Reasoning levels THIS model accepts, as its CLI reported them. Effort
    /// menus must offer this rather than a hardcoded list: the range is
    /// per-model and grows (GPT-6-Astra added `ultra`, which no menu could
    /// reach while the levels were literals). Nil = the CLI doesn't report a
    /// range; fall back to ModelPickerEffort.fallbackLevels.
    public let cliSupportedEfforts: [String]?
    /// The level the CLI uses when none is chosen, for labelling "Default".
    public let cliDefaultEffort: String?

    // ── Billing metadata (populated from the D1 catalog; nil on older webs) ──
    public let perMInput: Double?   // $ per million input tokens (0 for CLI rows)
    public let perMOutput: Double?  // $ per million output tokens
    public let tier: String?        // standard | premium

    /// False = known (an existing chat still resolves its name, menus and
    /// launch through it) but not offered as a choice in the iOS apps. The web
    /// decides; nil (older webs, cached rows) means offered.
    public let pickable: Bool?

    /// Whether pickers on this device offer the model. iPhone, iPad and
    /// Catalyst honour `pickable`; the Mac host offers everything.
    public var isOfferedOnThisDevice: Bool {
        #if os(iOS)
        return pickable != false
        #else
        return true
        #endif
    }

    /// True when this is a CLI model (Claude Code / Codex / Antigravity).
    public var isCli: Bool { (type ?? "").hasSuffix("-cli") }

    /// True when this is an axis-2 "your subscription" Anthropic model — billed
    /// to the host's own Claude plan via the host's local subscription proxy.
    /// Like CLI, it REQUIRES a host (the credential + proxy live there), so the
    /// picker gates it on a machine rather than offering it machine-free.
    public var isSubscription: Bool { type == "anthropic-subscription" }

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
        cliMode: String? = nil,
        cliSupportedEfforts: [String]? = nil,
        cliDefaultEffort: String? = nil,
        perMInput: Double? = nil,
        perMOutput: Double? = nil,
        tier: String? = nil,
        pickable: Bool? = nil
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
        self.cliSupportedEfforts = cliSupportedEfforts
        self.cliDefaultEffort = cliDefaultEffort
        self.perMInput = perMInput
        self.perMOutput = perMOutput
        self.tier = tier
        self.pickable = pickable
    }
}

/// A session descriptor from a remote machine, returned by the remote discovery protocol.
///
/// Codable because the session list persists the per-machine scan results, not
/// just the rows it derived from them — a machine that hasn't answered yet on
/// this launch keeps its last-known sessions instead of having them vanish.
public struct RemoteSessionInfo: Identifiable, Equatable, Codable {
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

/// Auth state of a host machine's `claude` CLI, plus any in-flight
/// phone-driven sign-in. Mirrors `AgentHostAuthStatusResponse` (relayProtocol).
public struct HostAuthStatusInfo {
    public let loggedIn: Bool
    public let authMethod: String?
    public let apiProvider: String?
    public let email: String?
    public let orgName: String?
    /// e.g. "max" / "pro" — which plan backs CLI sessions on this host.
    public let subscriptionType: String?
    /// Present while a sign-in started by `beginHostAuth` is awaiting a code.
    public let pendingSessionId: String?
    public let error: String?

    static func from(dict: [String: Any]) -> HostAuthStatusInfo {
        HostAuthStatusInfo(
            loggedIn: dict["loggedIn"] as? Bool ?? false,
            authMethod: dict["authMethod"] as? String,
            apiProvider: dict["apiProvider"] as? String,
            email: dict["email"] as? String,
            orgName: dict["orgName"] as? String,
            subscriptionType: dict["subscriptionType"] as? String,
            pendingSessionId: dict["pendingSessionId"] as? String,
            error: dict["error"] as? String
        )
    }
}

/// Result of starting a sign-in on a host: the authorize URL to open on THIS
/// device, and the host-side session the pasted code must be returned to.
/// No credential ever crosses the relay — the code is PKCE-bound to the
/// host process and the token lands in the host's Keychain.
public struct HostAuthBeginInfo {
    public let sessionId: String?
    public let authUrl: String?
    public let error: String?
}

/// One switchable Claude account profile on a host machine. Mirrors
/// `ClaudeAccountProfileInfo` (relayProtocol) — see ClaudeAccountStore on the
/// host for what a profile physically is (a CLAUDE_CONFIG_DIR with its own
/// namespaced Keychain credential and a symlink into the shared session store).
public struct ClaudeAccountProfile: Identifiable, Equatable {
    public let slug: String
    public let name: String
    public let email: String?
    public let loggedIn: Bool
    public let isDefault: Bool
    public var plan: String? = nil
    public var usage: CodingAccountUsage? = nil

    public var id: String { slug }

    static func from(dict: [String: Any]) -> ClaudeAccountProfile {
        ClaudeAccountProfile(
            slug: dict["slug"] as? String ?? "",
            name: dict["name"] as? String ?? "",
            email: dict["email"] as? String,
            loggedIn: dict["loggedIn"] as? Bool ?? false,
            isDefault: dict["isDefault"] as? Bool ?? false,
            plan: dict["plan"] as? String,
            usage: (dict["usage"] as? [String: Any]).flatMap { value in
                guard let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
                return try? JSONDecoder().decode(CodingAccountUsage.self, from: data)
            }
        )
    }
}

/// Result of listing a host's account profiles.
public struct ClaudeAccountsListInfo {
    public let accounts: [ClaudeAccountProfile]
    /// Slug of the machine-global active profile.
    public let active: String
    public let error: String?
}

/// Result of a hot swap: which sessions recycled immediately and which switch
/// after their in-flight turn completes.
public struct ClaudeAccountSwitchInfo {
    public let ok: Bool
    public let active: String?
    public let recycledSessions: [String]
    public let deferredBusySessions: [String]
    public let error: String?
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

    /// The sentence-case display name shared by session rows, title lozenges and voice progress.
    public var displayName: String? {
        switch self {
        case .toolStart(let toolName, _, let toolLabel, _):
            return ToolDisplayName.activity(toolName: toolName, label: toolLabel)
        case .toolEnd(let toolName, _, _, let toolLabel, _):
            return ToolDisplayName.activity(toolName: toolName, label: toolLabel)
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

/// A file view request from the web app, presented natively as a sheet.
public struct FileViewRequest: Identifiable {
    public let id: String
    public let filePath: String
    public let content: String?
    public let language: String?
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
    /// Current URL of the mirrored tab (page "tabMirror" only) — feeds the
    /// native remote-browser address bar; updated on every navigation.
    public let mirrorUrl: String?

    public init(
        page: String,
        showNativeHeader: Bool,
        showNativeChatInput: Bool,
        showSessionControls: Bool,
        safeAreaMode: String,
        mirrorUrl: String? = nil
    ) {
        self.page = page
        self.showNativeHeader = showNativeHeader
        self.showNativeChatInput = showNativeChatInput
        self.showSessionControls = showSessionControls
        self.safeAreaMode = safeAreaMode
        self.mirrorUrl = mirrorUrl
    }

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
