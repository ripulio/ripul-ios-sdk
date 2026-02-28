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

/// A chat session descriptor received from the web app.
public struct ChatSession: Identifiable, Equatable {
    public let id: String
    public let sourceChatId: String
    public var displayName: String
    public let createdAt: Date
    /// Name of the remote machine this session is paired to, or nil for local sessions.
    public var remoteMachineName: String?
}

/// A slash command descriptor received from the web app.
public struct SlashCommandInfo: Identifiable {
    public let command: String
    public let description: String
    public let icon: String?
    public let type: String   // "template" or "action"
    public let hasVariables: Bool
    public var id: String { command }
}

@MainActor
public final class AgentBridge: NSObject, ObservableObject {
    @Published public var isConnected = false
    @Published public var isThemeReady = false
    @Published public var wantsMinimize = false
    @Published public var sessions: [ChatSession] = []
    @Published public var activeSessionId: String?
    @Published public var lastSessionsError: String?

    private weak var webView: WKWebView?
    private var registeredTools: [NativeTool] = []
    private var llmProvider: LLMProvider?
    private var sessionsRetryCount = 0
    private static let maxSessionsRetries = 5

    /// Set this delegate to handle search result clicks from the universal search.
    public weak var searchClickDelegate: SearchClickDelegate?

    public override init() {
        super.init()
    }

    // MARK: - Tool Registration

    /// Register native tools that the agent can discover and invoke.
    public func register(_ tools: [NativeTool]) {
        registeredTools.append(contentsOf: tools)
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
    @available(iOS 15.0, *)
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
        case "sessions:list:response":
            handleSessionsListResponse(dict)
        case "chat:new:ack":
            handleChatNewAck(dict)
        default:
            NSLog("[AgentBridge] Unhandled message: %@", messageType)
        }
    }

    public func handleConsoleLog(_ message: String) {
        NSLog("[JS] %@", message)
    }

    /// Start a new chat with an optional prompt via the bridge protocol.
    /// The web app handles chat creation and prompt auto-execution.
    public func startNewChat(prompt: String? = nil) {
        var message: [String: Any] = [
            "type": "\(messagePrefix)chat:new",
            "version": protocolVersion,
            "timestamp": currentTimestamp(),
            "requestId": UUID().uuidString,
        ]
        if let prompt {
            message["prompt"] = prompt
        }
        NSLog("[AgentBridge] → Sending chat:new (prompt: %@)", prompt != nil ? "yes" : "no")
        send(message)
    }

    /// Submit a message to the active chat session via the web app's
    /// global `__ripulSubmitMessage` callable.
    /// - Parameters:
    ///   - text: The message text.
    ///   - imageAttachments: Optional array of base64-encoded images.
    ///     Each element must have keys: `id`, `mediaType`, `data`, and optionally `name`.
    @available(iOS 15.0, *)
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
                return dict["success"] as? Bool ?? false
            }
            return false
        } catch {
            NSLog("[AgentBridge] submitMessage error: %@", error.localizedDescription)
            return false
        }
    }

    /// Fetch the current list of chat sessions by calling the web app's
    /// global function directly. Updates `sessions` and `activeSessionId`.
    @available(iOS 15.0, *)
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
                self.sessions = parsed
                self.activeSessionId = activeId
                self.lastSessionsError = nil
                NSLog("[AgentBridge] fetchSessions: %d sessions, active: %@",
                      parsed.count, activeId ?? "nil")
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
    @available(iOS 15.0, *)
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
    @available(iOS 15.0, *)
    public func getSlashCommands() async -> [SlashCommandInfo] {
        guard let webView else { return [] }
        do {
            let result = try await webView.callAsyncJavaScript(
                "return await window.__ripulGetSlashCommands?.() ?? [];",
                contentWorld: .page
            )
            guard let array = result as? [[String: Any]] else { return [] }
            return array.compactMap { dict in
                guard let command = dict["command"] as? String,
                      let description = dict["description"] as? String else { return nil }
                return SlashCommandInfo(
                    command: command,
                    description: description,
                    icon: dict["icon"] as? String,
                    type: (dict["type"] as? String) ?? "template",
                    hasVariables: (dict["hasVariables"] as? Bool) ?? false
                )
            }
        } catch {
            NSLog("[AgentBridge] getSlashCommands error: %@", error.localizedDescription)
            return []
        }
    }

    /// Close (delete) a chat session tab.
    @available(iOS 15.0, *)
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
    @available(iOS 15.0, *)
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
    @available(iOS 15.0, *)
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
        send([
            "type": "\(messagePrefix)handshake:ack",
            "version": protocolVersion,
            "timestamp": currentTimestamp(),
            "capabilities": [
                "mcp": !registeredTools.isEmpty,
                "dom": false,
                "storage": false,
                "llm": llmProvider != nil,
                "searchClick": searchClickDelegate != nil,
            ],
            "hostOrigin": "ripul-native://app",
        ])
        isConnected = true

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
        NSLog("[AgentBridge] → Sending mcp:tools (%d tools)", defs.count)
        // DEBUG — log each tool's keys to verify outputSchema presence
        for def in defs {
            let name = def["name"] as? String ?? "?"
            let keys = Array(def.keys).sorted()
            let hasOutput = def["outputSchema"] != nil
            NSLog("[AgentBridge] Tool '%@' keys: %@ outputSchema: %@", name, keys.description, hasOutput ? "YES" : "NO")
        }
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
