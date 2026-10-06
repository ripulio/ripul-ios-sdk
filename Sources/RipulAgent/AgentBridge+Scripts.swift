import Foundation
import WebKit

/// Running a script in the page directly. Calls to a `window.__ripul…`
/// callable go through `callPage` instead; these are for everything else.
extension AgentBridge {
    /// Run an async JS callable in the page world and hand back its raw result.
    ///
    /// `webView` is private to this file, so features living in their own files
    /// (PlanReview, …) reach the page through here rather than widening the
    /// property's access. Returns nil when the web view is not attached yet —
    /// callers surface that as "still starting up" rather than treating it as
    /// a failure of whatever they were asking for.
    func callPageFunction(_ script: String, arguments: [String: Any]) async throws -> Any? {
        guard let webView = attachedWebView else { return nil }
        return try await webView.callAsyncJavaScript(
            script, arguments: arguments, contentWorld: .page)
    }

    /// Evaluate arbitrary JavaScript in the attached web view.
    /// Use for extracting data (e.g. auth tokens) from the web app context.
    public func evaluateJavaScript(_ script: String, completion: ((Any?) -> Void)? = nil) {
        guard let webView = attachedWebView else {
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

    func noteJsEvalFailure() {
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
    public func callAsyncJavaScript(_ script: String) async throws -> Any? {
        guard let webView = attachedWebView else {
            throw NSError(domain: "AgentBridge", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "webView is nil"])
        }
        return try await webView.callAsyncJavaScript(script, contentWorld: .page)
    }
}
