import Foundation
import WebKit

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
public struct ChatSession: Identifiable, Equatable {
    public let id: String
    public let sourceChatId: String
    public var displayName: String
    public let createdAt: Date
    /// Name of the remote machine this session is paired to, or nil for local sessions.
    public var remoteMachineName: String?
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
}

public struct ConsoleLogEntry: Identifiable {
    public let id = UUID()
    public let timestamp: Date
    public let level: String   // "LOG", "WARN", "ERROR"
    public let message: String
    public let stack: String?

    public init(timestamp: Date, level: String, message: String, stack: String? = nil) {
        self.timestamp = timestamp
        self.level = level
        self.message = message
        self.stack = stack
    }
}

/// Masthead configuration received from the web app's ViewContext features.
public struct MastheadConfig: Equatable {
    public var text: String?
    public var imageUrl: String?
    public var backgroundColor: String?  // CSS color string (e.g. "#FF6600")
    public var textColor: String?        // CSS color string
    public var height: CGFloat?
    public var imageWidth: String?       // CSS value (e.g. "120px", "50%")
}

@MainActor
public final class AgentBridge: NSObject, ObservableObject {
    @Published public var isConnected = false
    @Published public var isThemeReady = false
    @Published public var wantsMinimize = false
    @Published public var sessions: [ChatSession] = []
    @Published public var activeSessionId: String?
    @Published public var lastSessionsError: String?
    @Published public var showScrollToBottom = false
    /// Text to prefill in the native chat input (set by welcome card / prompt suggestion clicks).
    @Published public var pendingInputText: String?
    @Published public var availableModels: [ModelInfo] = []
    @Published public var selectedModelId: String?
    @Published public var modelSelectionEnabled: Bool = true
    @Published public var lastModelsError: String?
    /// Whether the agent is currently running (processing) for the active session.
    @Published public var isAgentRunning = false
    /// Whether the agent is paused (awaiting user input) for the active session.
    @Published public var isAgentPaused = false
    /// Set when the web view fails to load. Cleared on successful connection.
    @Published public var loadError: String?
    /// Masthead configuration from the web app (text, image, colors for native glass lozenge).
    @Published public var mastheadConfig: MastheadConfig?

    private weak var webView: WKWebView?
    private var registeredTools: [NativeTool] = []
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

    public override init() {
        super.init()
    }

    // MARK: - Tool Registration

    /// Register native tools that the agent can discover and invoke.
    public func register(_ tools: [NativeTool]) {
        registeredTools.append(contentsOf: tools)
    }

    /// Replace all registered tools and re-broadcast to the web app.
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

    /// Called by the web view coordinator when the page finishes loading.
    /// Starts a timeout — if the bridge doesn't connect within 10 seconds,
    /// clears the cache and reloads once to evict stale web app bundles.
    public func pageDidFinishLoading() {
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000) // 10s
            guard let self, !Task.isCancelled else { return }
            if !self.isConnected && !self.hasAttemptedCacheReload {
                self.hasAttemptedCacheReload = true
                NSLog("[AgentBridge] Bridge did not connect within 10s — clearing cache and reloading (one-time)")
                self.clearCacheAndReload()
            } else if !self.isConnected {
                NSLog("[AgentBridge] Bridge did not connect after cache reload — giving up. User can retry manually.")
                self.loadError = "The app failed to connect. Try restarting the app."
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
        WKWebsiteDataStore.default().removeData(ofTypes: cacheTypes, modifiedSince: .distantPast) { [weak self] in
            guard let webView = self?.webView else {
                NSLog("[AgentBridge] Cannot reload — webView is nil")
                return
            }
            NSLog("[AgentBridge] Cache cleared, reloading")
            self?.isConnected = false
            self?.isThemeReady = false
            webView.reload()
        }
    }

    /// Clear ALL website data (cache, cookies, localStorage, IndexedDB, etc.) and reload.
    /// This is a full reset — the user will need to log in again.
    public func clearAllDataAndReload() {
        let allTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        WKWebsiteDataStore.default().removeData(ofTypes: allTypes, modifiedSince: .distantPast) { [weak self] in
            guard let webView = self?.webView else { return }
            NSLog("[AgentBridge] All website data cleared, reloading")
            self?.isConnected = false
            self?.isThemeReady = false
            webView.reload()
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
        webView.load(URLRequest(url: url))
    }

    /// Evaluate arbitrary JavaScript in the attached web view.
    /// Use for extracting data (e.g. auth tokens) from the web app context.
    public func evaluateJavaScript(_ script: String, completion: ((Any?) -> Void)? = nil) {
        guard let webView else {
            NSLog("[AgentBridge] Cannot evaluate JS — webView is nil")
            completion?(nil)
            return
        }
        webView.evaluateJavaScript(script) { result, error in
            if let error {
                NSLog("[AgentBridge] JS eval error: %@", error.localizedDescription)
                completion?(nil)
            } else {
                completion?(result)
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

    // MARK: - Receive messages from web app

    public func handleMessage(_ body: Any) {
        guard let dict = body as? [String: Any],
              let type = dict["type"] as? String,
              type.hasPrefix(messagePrefix) else {
            NSLog("[AgentBridge] Received non-bridge message: %@", String(describing: body))
            return
        }

        let messageType = String(type.dropFirst(messagePrefix.count))
        NSLog("[AgentBridge] ← Received: %@", messageType)

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
        case "sessions:list:response":
            handleSessionsListResponse(dict)
        case "chat:new:ack":
            handleChatNewAck(dict)
        case "capability":
            handleCapabilityRequest(dict)
        case "capability:ping":
            handleCapabilityPing(dict)
        case "agent:status":
            if let running = dict["isRunning"] as? Bool {
                isAgentRunning = running
            }
            if let paused = dict["isPaused"] as? Bool {
                isAgentPaused = paused
            }
        case "chat:prefill":
            pendingInputText = dict["text"] as? String
        case "link:open":
            if let urlString = dict["url"] as? String, let url = URL(string: urlString) {
                NSLog("[AgentBridge] Link open — url: %@", urlString)
                linkOpenDelegate?.agentBridge(self, didRequestOpenLink: url)
            }
        default:
            NSLog("[AgentBridge] Unhandled message: %@", messageType)
        }
    }

    private var jsErrorMessages: [String] = []
    private var jsErrorDebounce: DispatchWorkItem?

    /// Detailed error log for the user to copy and share with the developer.
    @Published public var loadErrorDetails: String?

    /// Rolling buffer of captured JS console messages.
    @Published public var consoleLogs: [ConsoleLogEntry] = []
    private let maxLogEntries = 2000

    public func handleConsoleLog(_ message: String) {
        NSLog("[JS] %@", message)

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

        consoleLogs.append(ConsoleLogEntry(timestamp: Date(), level: level, message: body, stack: stack))
        if consoleLogs.count > maxLogEntries {
            consoleLogs.removeFirst(consoleLogs.count - maxLogEntries)
        }

        // If we see JS errors before the bridge connects, the app is broken.
        // Debounce briefly to collect errors, then surface a user-friendly message.
        if !isConnected && level == "ERROR" {
            jsErrorMessages.append(body)

            jsErrorDebounce?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self, !self.isConnected else { return }
                self.loadError = "Something went wrong loading the app."
                self.loadErrorDetails = self.jsErrorMessages.joined(separator: "\n")
            }
            jsErrorDebounce = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: item)
        }
    }

    public func clearConsoleLogs() {
        consoleLogs.removeAll()
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
    @available(iOS 15.0, macOS 13.0, *)
    @discardableResult
    public func submitMessage(_ text: String, imageAttachments: [[String: String]]? = nil) async -> Bool {
        guard let webView else { return false }
        do {
            var args: [String: Any] = ["text": text]
            let script: String
            if let images = imageAttachments, !images.isEmpty {
                args["images"] = images
                script = "return await window.__ripulSubmitMessage?.(text, images) ?? { success: false }"
            } else {
                script = "return await window.__ripulSubmitMessage?.(text) ?? { success: false }"
            }
            let result = try await webView.callAsyncJavaScript(
                script,
                arguments: args,
                contentWorld: .page
            )
            if let dict = result as? [String: Any] {
                let success = dict["success"] as? Bool ?? false
                if success {
                    // Optimistically mark agent as running — the web app will
                    // push the real status via agent:status messages.
                    isAgentRunning = true
                    isAgentPaused = false
                }
                return success
            }
            return false
        } catch {
            NSLog("[AgentBridge] submitMessage error: %@", error.localizedDescription)
            return false
        }
    }

    /// Interrupt (pause) the currently running agent for the active session.
    @available(iOS 15.0, macOS 13.0, *)
    @discardableResult
    public func interruptAgent() async -> Bool {
        guard let webView else { return false }
        do {
            let result = try await webView.callAsyncJavaScript(
                "return await window.__ripulInterruptAgent?.() ?? { success: false }",
                contentWorld: .page
            )
            if let dict = result as? [String: Any] {
                let success = dict["success"] as? Bool ?? false
                if success {
                    isAgentRunning = false
                    isAgentPaused = true
                }
                return success
            }
            return false
        } catch {
            NSLog("[AgentBridge] interruptAgent error: %@", error.localizedDescription)
            return false
        }
    }

    /// Resume a paused agent, optionally with additional context.
    @available(iOS 15.0, macOS 13.0, *)
    @discardableResult
    public func resumeAgent(context: String? = nil) async -> Bool {
        guard let webView else { return false }
        // Always clear paused state so the user isn't permanently stuck
        // if the resume call fails. The agent:status push will correct
        // the state if needed.
        isAgentPaused = false
        do {
            let script: String
            var args: [String: Any] = [:]
            if let ctx = context, !ctx.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                args["ctx"] = ctx
                script = "return await window.__ripulResumeAgent?.(ctx) ?? { success: false }"
            } else {
                script = "return await window.__ripulResumeAgent?.() ?? { success: false }"
            }
            let result = try await webView.callAsyncJavaScript(
                script,
                arguments: args,
                contentWorld: .page
            )
            if let dict = result as? [String: Any] {
                let success = dict["success"] as? Bool ?? false
                if success {
                    isAgentRunning = true
                } else {
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

    /// Fetch the current list of chat sessions by calling the web app's
    /// global function directly. Updates `sessions` and `activeSessionId`.
    @available(iOS 15.0, macOS 13.0, *)
    public func fetchSessions() async {
        guard let webView else {
            lastSessionsError = "webView is nil"
            return
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
                return ChatSession(id: id, sourceChatId: sourceChatId,
                                   displayName: displayName, createdAt: createdAt,
                                   remoteMachineName: remoteMachineName)
            }

            if !parsed.isEmpty {
                // Only update if changed to avoid unnecessary SwiftUI re-renders
                if self.sessions != parsed {
                    self.sessions = parsed
                }
                if self.activeSessionId != activeId {
                    self.activeSessionId = activeId
                }
                self.lastSessionsError = nil
            } else {
                lastSessionsError = jsError ?? "0 sessions parsed from \(sessionsArray.count) items"
                if let activeId { self.activeSessionId = activeId }
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
    public func focusSession(id: String) async {
        guard let webView else {
            NSLog("[AgentBridge] focusSession: webView is nil")
            return
        }
        // Optimistically update so the UI reflects the switch immediately
        activeSessionId = id
        do {
            _ = try await webView.callAsyncJavaScript(
                "if (window.__ripulFocusSession) await window.__ripulFocusSession(sessionId);",
                arguments: ["sessionId": id],
                contentWorld: .page
            )
        } catch {
            NSLog("[AgentBridge] focusSession error: %@", error.localizedDescription)
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
        lastModelsError = nil

        guard let webView else {
            lastModelsError = "WebView not available"
            return
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
                return
            }

            if let error = dict["error"] as? String {
                lastModelsError = error
                NSLog("[AgentBridge] fetchModels error: %@", error)
                return
            }

            guard let modelsArray = dict["models"] as? [[String: Any]] else {
                lastModelsError = "No models array in response"
                return
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
                    supportsThinking: (item["supportsThinking"] as? Bool) ?? false
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
        } catch {
            lastModelsError = error.localizedDescription
            NSLog("[AgentBridge] fetchModels error: %@", error.localizedDescription)
        }
    }

    /// Set the user's model override. Pass nil to revert to the default model.
    @available(iOS 15.0, macOS 13.0, *)
    @discardableResult
    public func setModel(_ modelId: String?) async -> Bool {
        guard let webView else { return false }
        do {
            let result = try await webView.callAsyncJavaScript(
                "return await window.__ripulSetModel?.(modelId) ?? {success:false};",
                arguments: ["modelId": modelId as Any],
                contentWorld: .page
            )
            if let dict = result as? [String: Any],
               let success = dict["success"] as? Bool, success {
                self.selectedModelId = modelId
                NSLog("[AgentBridge] setModel: %@", modelId ?? "default")
                return true
            }
            return false
        } catch {
            NSLog("[AgentBridge] setModel error: %@", error.localizedDescription)
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
            sessions.removeAll { $0.id == id }
            if activeSessionId == id {
                activeSessionId = sessions.first?.id
            }
        } catch {
            NSLog("[AgentBridge] closeSession error: %@", error.localizedDescription)
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
            let result = try await webView.callAsyncJavaScript(
                """
                if (!window.__ripulConnectToMachine) return {success:false, error:'not ready'};
                return await window.__ripulConnectToMachine(machineId);
                """,
                arguments: ["machineId": machineId],
                contentWorld: .page
            )
            guard let dict = result as? [String: Any] else {
                return (nil, "Unexpected result")
            }
            if let success = dict["success"] as? Bool, success {
                let tabId = dict["tabId"] as? String
                let machineName = dict["machineName"] as? String ?? machineId
                NSLog("[AgentBridge] connectToMachine: paired to %@, tab %@", machineName, tabId ?? "?")
                // Refresh sessions so the new tab appears
                await fetchSessions()
                return (tabId, nil)
            } else {
                let error = dict["error"] as? String ?? "Unknown error"
                NSLog("[AgentBridge] connectToMachine failed: %@", error)
                return (nil, error)
            }
        } catch {
            NSLog("[AgentBridge] connectToMachine error: %@", error.localizedDescription)
            return (nil, error.localizedDescription)
        }
    }

    /// Create a new chat tab via direct JS call.
    @available(iOS 15.0, macOS 13.0, *)
    public func createNewChat() async -> String? {
        guard let webView else {
            NSLog("[AgentBridge] createNewChat: webView is nil")
            return nil
        }

        do {
            let result = try await webView.callAsyncJavaScript(
                """
                if (!window.__ripulCreateChat) return {success:false, error:'not ready'};
                return await window.__ripulCreateChat();
                """,
                contentWorld: .page
            )

            guard let dict = result as? [String: Any],
                  let success = dict["success"] as? Bool, success,
                  let chatId = dict["chatId"] as? String else {
                NSLog("[AgentBridge] createNewChat: unexpected result: %@",
                      String(describing: result))
                return nil
            }
            NSLog("[AgentBridge] createNewChat: created %@", chatId)
            return chatId
        } catch {
            NSLog("[AgentBridge] createNewChat error: %@", error.localizedDescription)
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
                let result = try await webView.callAsyncJavaScript(
                    "return await window.__ripulRenameSession?.(`\(escapedChatId)`, `\(escaped)`) ?? { success: false }",
                    contentWorld: .page
                )
                if let dict = result as? [String: Any],
                   let success = dict["success"] as? Bool, success,
                   let confirmedName = dict["displayName"] as? String {
                    if let index = sessions.firstIndex(where: { $0.id == id }) {
                        sessions[index].displayName = confirmedName
                    }
                    NSLog("[AgentBridge] renameSession confirmed: %@", confirmedName)
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
                    "machineName": machineName as Any,
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
            let result = try await webView.callAsyncJavaScript(
                """
                if (!window.__ripulGetHostStatus) return {available:false, error:'not ready'};
                return await window.__ripulGetHostStatus();
                """,
                contentWorld: .page
            )
            return result as? [String: Any]
        } catch {
            NSLog("[AgentBridge] getHostStatus error: %@", error.localizedDescription)
            return nil
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

    private var toolDefinitions: [[String: Any]] {
        registeredTools.map { $0.definition }
    }

    private func tool(named name: String) -> NativeTool? {
        registeredTools.first { $0.name == name }
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
        connectionTimeoutTask?.cancel()
        loadError = nil
        loadErrorDetails = nil
        jsErrorMessages = []
        jsErrorDebounce?.cancel()

        if !registeredTools.isEmpty {
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
        if showScrollToBottom != show {
            showScrollToBottom = show
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

        mastheadConfig = MastheadConfig(
            text: text,
            imageUrl: imageUrl,
            backgroundColor: message["backgroundColor"] as? String,
            textColor: message["textColor"] as? String,
            height: (message["height"] as? NSNumber).map { CGFloat($0.doubleValue) },
            imageWidth: message["imageWidth"] as? String
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
        let mastheadExtra = mastheadConfig != nil ? Int(mastheadConfig?.height ?? 44) + 12 : 0
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

    /// Tell the web view to scroll the chat to the bottom.
    public func scrollToBottom() {
        evaluateJavaScript("window.__ripulScrollToBottom?.()")
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
            return ChatSession(id: id, sourceChatId: sourceChatId, displayName: displayName, createdAt: createdAt)
        }

        // Only update sessions when we get data. Never clear a good cached
        // list with an empty response (timing race during web app init).
        if !parsed.isEmpty {
            self.sessions = parsed
            self.activeSessionId = activeId
            sessionsRetryCount = 0
            NSLog("[AgentBridge] Sessions updated: %d sessions, active: %@",
                  parsed.count, activeId ?? "nil")
        } else if sessions.isEmpty {
            // Only update active ID when we truly have no sessions yet
            self.activeSessionId = activeId
            NSLog("[AgentBridge] Empty sessions response (no cache)")
        } else {
            // Keep cached sessions, just update active ID
            if let activeId { self.activeSessionId = activeId }
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

            // Broadcast MCP tools if any are registered
            if !registeredTools.isEmpty {
                let defs = toolDefinitions
                send([
                    "type": "\(messagePrefix)mcp:tools",
                    "version": protocolVersion,
                    "timestamp": currentTimestamp(),
                    "tools": defs,
                ])
            }
        }
    }

    // MARK: - Transport

    private func send(_ message: [String: Any]) {
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

    private func currentTimestamp() -> Int {
        Int(Date().timeIntervalSince1970 * 1000)
    }
}
