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

@MainActor
public final class AgentBridge: NSObject, ObservableObject {
    @Published public var isConnected = false
    @Published public var isThemeReady = false
    @Published public var wantsMinimize = false

    private weak var webView: WKWebView?
    private var registeredTools: [NativeTool] = []
    private var llmProvider: LLMProvider?

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
