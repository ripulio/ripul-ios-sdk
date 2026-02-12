import Foundation
import WebKit

private let protocolVersion = "1.0.0"
private let messagePrefix = "agent-framework:"

@MainActor
final class AgentBridge: NSObject, ObservableObject {
    @Published var isConnected = false
    @Published var isThemeReady = false
    @Published var wantsMinimize = false

    private weak var webView: WKWebView?
    private let toolRegistry = NativeToolRegistry()

    func attach(to webView: WKWebView) {
        self.webView = webView
        NSLog("[AgentBridge] Attached to WKWebView")
    }

    // MARK: - Receive messages from web app

    func handleMessage(_ body: Any) {
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
        case "theme:ready":
            NSLog("[AgentBridge] Theme ready received")
            isThemeReady = true
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

    func handleConsoleLog(_ message: String) {
        NSLog("[JS] %@", message)
    }

    // MARK: - Send messages to web app

    func setTheme(_ theme: AgentTheme) {
        let requestId = UUID().uuidString
        send([
            "type": "\(messagePrefix)theme:set",
            "version": protocolVersion,
            "timestamp": currentTimestamp(),
            "requestId": requestId,
            "theme": theme.rawValue,
        ])
    }

    // MARK: - Private handlers

    private func handleHandshake(_ message: [String: Any]) {
        NSLog("[AgentBridge] → Sending handshake:ack")
        send([
            "type": "\(messagePrefix)handshake:ack",
            "version": protocolVersion,
            "timestamp": currentTimestamp(),
            "capabilities": [
                "mcp": true,
                "dom": false,
                "storage": false,
            ],
            "hostOrigin": "testapp://native",
        ])
        isConnected = true

        // Proactively broadcast tools so the web app's FrameMCPBridge caches them
        // (the web app may not explicitly send mcp:discover)
        let toolDefs = toolRegistry.definitions
        NSLog("[AgentBridge] → Broadcasting mcp:tools (%d tools)", toolDefs.count)
        send([
            "type": "\(messagePrefix)mcp:tools",
            "version": protocolVersion,
            "timestamp": currentTimestamp(),
            "tools": toolDefs,
        ])
    }

    private func handleHostInfo(_ message: [String: Any]) {
        let requestId = message["requestId"] as? String ?? UUID().uuidString
        NSLog("[AgentBridge] → Sending host:info:response")
        send([
            "type": "\(messagePrefix)host:info:response",
            "version": protocolVersion,
            "timestamp": currentTimestamp(),
            "requestId": requestId,
            "url": "testapp://native",
            "title": "TestApp (iOS)",
            "origin": "testapp://native",
        ])
    }

    private func handleMCPDiscover(_ message: [String: Any]) {
        let requestId = message["requestId"] as? String ?? UUID().uuidString
        let toolDefs = toolRegistry.definitions
        NSLog("[AgentBridge] → Sending mcp:tools (%d tools)", toolDefs.count)
        send([
            "type": "\(messagePrefix)mcp:tools",
            "version": protocolVersion,
            "timestamp": currentTimestamp(),
            "requestId": requestId,
            "tools": toolDefs,
        ])
    }

    private func handleMCPInvoke(_ message: [String: Any]) {
        let requestId = message["requestId"] as? String ?? UUID().uuidString
        let toolName = message["toolName"] as? String ?? ""
        let args = message["args"] as? [String: Any] ?? [:]

        NSLog("[AgentBridge] → Invoking tool: %@ with requestId: %@", toolName, requestId)

        guard let tool = toolRegistry.tool(named: toolName) else {
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
                self.send([
                    "type": "\(messagePrefix)mcp:result",
                    "version": protocolVersion,
                    "timestamp": self.currentTimestamp(),
                    "requestId": requestId,
                    "result": result,
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

    // MARK: - Transport

    private func send(_ message: [String: Any]) {
        guard let webView else {
            NSLog("[AgentBridge] Cannot send — webView is nil")
            return
        }

        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let json = String(data: data, encoding: .utf8) else {
            NSLog("[AgentBridge] Failed to serialize message")
            return
        }

        let js = "window.__agentBridgeReceive(\(json))"
        webView.evaluateJavaScript(js) { _, error in
            if let error {
                NSLog("[AgentBridge] JS eval error: %@", error.localizedDescription)
            }
        }
    }

    private func currentTimestamp() -> Int {
        Int(Date().timeIntervalSince1970 * 1000)
    }
}
