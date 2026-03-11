import Foundation
import WebKit

/// Delegate that receives automation runtime messages from a browser tab's WKWebView.
/// The implementing class fulfills each request and calls `sendResponse` on the bridge.
@MainActor
public protocol AutomationRuntimeDelegate: AnyObject {
    func automationRuntime(_ bridge: AutomationRuntimeBridge, promptAsync guid: String, prompt: String, schema: Any?)
    func automationRuntime(_ bridge: AutomationRuntimeBridge, basicFetch guid: String, input: String, options: [String: Any]?)
    func automationRuntime(_ bridge: AutomationRuntimeBridge, openTab guid: String, url: String)
    func automationRuntime(_ bridge: AutomationRuntimeBridge, openAutomationTab guid: String, url: String, state: [String: Any], automationId: String?, runId: String?)
    func automationRuntime(_ bridge: AutomationRuntimeBridge, setState guid: String, state: [String: Any], automationId: String?, runId: String?)
    func automationRuntime(_ bridge: AutomationRuntimeBridge, getState guid: String, automationId: String?, runId: String?)
    func automationRuntime(_ bridge: AutomationRuntimeBridge, invokeWebMcpTool guid: String, toolName: String, toolArgs: [String: Any], automationId: String?, runId: String?)
    func automationRuntimeFinished(_ bridge: AutomationRuntimeBridge, automationId: String?, runId: String?)
    func automationRuntimeError(_ bridge: AutomationRuntimeBridge, error: [String: Any])
}

/// Bridges automation runtime messages from a browser tab's WKWebView to native Swift.
///
/// Automation code running on a page uses `window.postMessage()` to request services
/// (LLM calls, fetch, tab management). This bridge injects a small JS listener that
/// forwards those messages to `window.webkit.messageHandlers.automationRuntime`,
/// then routes them to the delegate. Responses are injected back via `evaluateJavaScript`.
///
/// This is the native equivalent of the Chrome extension's `discovery.ts` content script.
@MainActor
public final class AutomationRuntimeBridge: NSObject, WKScriptMessageHandler {
    public weak var delegate: AutomationRuntimeDelegate?
    private weak var webView: WKWebView?
    private static let handlerName = "automationRuntime"

    /// The JS bridge script injected into the browser tab.
    /// Mirrors the message types handled by `discovery.ts` in the Chrome extension.
    private static let bridgeScript = """
    (function() {
        if (window.__ripulAutomationBridge) return; // already installed
        window.__ripulAutomationBridge = true;
        const bridgedTypes = [
            'promptAsync', 'basicFetch', 'openTab', 'openAutomationTab',
            'setAutomationState', 'getAutomationState', 'automationFinish',
            'automationError', 'invokeWebMcpTool'
        ];
        window.addEventListener('message', (event) => {
            if (event.source !== window) return;
            const data = event.data;
            if (!data || !data.type) return;
            if (bridgedTypes.includes(data.type)) {
                window.webkit.messageHandlers.automationRuntime.postMessage(data);
            }
        });
    })();
    """

    public override init() {
        super.init()
    }

    /// Install the automation bridge on a browser tab's WKWebView.
    /// Adds the WKScriptMessageHandler and injects the JS bridge script.
    public func install(on webView: WKWebView) {
        uninstall() // clean up any previous installation
        self.webView = webView
        webView.configuration.userContentController.add(self, name: Self.handlerName)
        webView.evaluateJavaScript(Self.bridgeScript) { _, error in
            if let error {
                NSLog("[AutomationRuntimeBridge] Failed to inject bridge script: %@", error.localizedDescription)
            }
        }
    }

    /// Remove the bridge from the current WKWebView.
    public func uninstall() {
        guard let webView else { return }
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName)
        self.webView = nil
    }

    // MARK: - WKScriptMessageHandler

    nonisolated public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.handlerName,
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        let guid = body["guid"] as? String ?? ""
        let automationId = body["automationId"] as? String
        let runId = body["runId"] as? String ?? body["automationRunId"] as? String

        Task { @MainActor [weak self] in
            guard let self, let delegate = self.delegate else { return }

            switch type {
            case "promptAsync":
                let prompt = body["prompt"] as? String ?? ""
                let schema = body["schema"]
                delegate.automationRuntime(self, promptAsync: guid, prompt: prompt, schema: schema)

            case "basicFetch":
                let input = body["input"] as? String ?? ""
                let options = body["init"] as? [String: Any]
                delegate.automationRuntime(self, basicFetch: guid, input: input, options: options)

            case "openTab":
                let url = body["url"] as? String ?? ""
                delegate.automationRuntime(self, openTab: guid, url: url)

            case "openAutomationTab":
                let url = body["url"] as? String ?? ""
                let state = body["state"] as? [String: Any] ?? [:]
                delegate.automationRuntime(self, openAutomationTab: guid, url: url, state: state, automationId: automationId, runId: runId)

            case "setAutomationState":
                let state = body["state"] as? [String: Any] ?? [:]
                delegate.automationRuntime(self, setState: guid, state: state, automationId: automationId, runId: runId)

            case "getAutomationState":
                delegate.automationRuntime(self, getState: guid, automationId: automationId, runId: runId)

            case "invokeWebMcpTool":
                let toolName = body["toolName"] as? String ?? ""
                let toolArgs = body["toolArgs"] as? [String: Any] ?? [:]
                delegate.automationRuntime(self, invokeWebMcpTool: guid, toolName: toolName, toolArgs: toolArgs, automationId: automationId, runId: runId)

            case "automationFinish":
                delegate.automationRuntimeFinished(self, automationId: automationId, runId: runId)

            case "automationError":
                delegate.automationRuntimeError(self, error: body)

            default:
                NSLog("[AutomationRuntimeBridge] Unknown message type: %@", type)
            }
        }
    }

    // MARK: - Response Injection

    /// Send a response back to the automation code running on the page.
    /// The response is injected as a `window.postMessage()` call matching the
    /// guid-based response pattern used by `ExtensionTemplates.ts`.
    public func sendResponse(type: String, guid: String, payload: [String: Any] = [:]) {
        guard let webView else {
            NSLog("[AutomationRuntimeBridge] Cannot send response — webView is nil")
            return
        }

        var msg: [String: Any] = ["type": type, "guid": guid]
        for (key, value) in payload { msg[key] = value }

        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let json = String(data: data, encoding: .utf8) else {
            NSLog("[AutomationRuntimeBridge] Failed to serialize response for %@", type)
            return
        }

        let script = "window.postMessage(\(json), '*');"
        webView.evaluateJavaScript(script) { _, error in
            if let error {
                NSLog("[AutomationRuntimeBridge] Failed to inject response: %@", error.localizedDescription)
            }
        }
    }
}
