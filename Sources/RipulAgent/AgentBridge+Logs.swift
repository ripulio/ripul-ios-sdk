import Combine
import Foundation

/// The bridge's log buffers as the rest of the app reaches them. The buffers
/// themselves, and how they fill, empty and are saved, are `BridgeLogStore`.
extension AgentBridge {
    // MARK: - Console

    /// Rolling buffer of captured JS console messages, and native lines sent
    /// through `handleConsoleLog`. Not observed: read it when
    /// `consoleLogsSubject` fires.
    public var consoleLogs: [ConsoleLogEntry] {
        get { logs.console }
        set { logs.console = newValue }
    }

    /// Fires on every change to `consoleLogs`.
    public var consoleLogsSubject: PassthroughSubject<Void, Never> { logs.consoleChanged }

    public func clearConsoleLogs() {
        logs.console.removeAll()
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

    /// Emit a `[SESSION-START]` marker into both NSLog and the unified consoleLogs
    /// buffer so it shows up in `device_console_logs` / `host_console_logs` alongside
    /// the web-side stages. Used to instrument the native side of the
    /// tap → input-ready window when investigating new-chat latency.
    public func logSessionStartMarker(_ stage: String, chatId: String? = nil, extra: String = "") {
        // Native creation/navigation markers are low-volume and must survive
        // with debug timing off, so a slow launch can be diagnosed afterwards.
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        let chatStr = chatId.map { " chatId=\($0)" } ?? ""
        let extraStr = extra.isEmpty ? "" : " \(extra)"
        let line = "[SESSION-START] stage=\(stage) ts=\(ts)\(chatStr)\(extraStr)"
        // Foundation.NSLog, NOT the module's tee shadow: the tee would ALSO
        // append to RipulLog, so every marker landed in the buffer twice —
        // once as `[native] [SESSION-START] …` and once as the line below.
        Foundation.NSLog("%@", line)
        handleConsoleLog("LOG: \(line)")
    }

    // MARK: - Saved across launches

    /// When true, WARN and ERROR log entries are persisted to UserDefaults.
    public var isPersistErrorLogsEnabled: Bool {
        get { logs.savesErrors }
        set { logs.savesErrors = newValue }
    }

    /// When true, ALL log entries are persisted to UserDefaults (for crash diagnosis).
    public var isPersistAllLogsEnabled: Bool {
        get { logs.savesAll }
        set { logs.savesAll = newValue }
    }

    /// Restore persisted logs into the in-memory buffer on launch.
    /// Call once from the app's entry point after creating the bridge.
    public func loadPersistedErrorLogs() {
        logs.restoreSaved()
    }

    /// Clear persisted logs from UserDefaults.
    public func clearPersistedErrorLogs() {
        logs.clearSaved()
    }

    // MARK: - Network

    /// Whether network request capture is active. Persisted in UserDefaults.
    /// Defaults to false — the user must opt in via the Network tab.
    public var isNetworkCaptureEnabled: Bool {
        get { logs.capturesNetwork }
        set {
            logs.capturesNetwork = newValue
            // Tell the web view to start/stop intercepting
            evaluateVoidJavaScript("window.__ripulNetworkCapture && window.__ripulNetworkCapture(\(newValue))")
        }
    }

    /// Rolling buffer of captured network requests.
    public var networkLogs: [NetworkLogEntry] {
        get { logs.network }
        set { logs.network = newValue }
    }

    /// Fires on every change to `networkLogs`.
    public var networkLogsSubject: PassthroughSubject<Void, Never> { logs.networkChanged }

    public func handleNetworkLog(_ body: Any) {
        logs.appendNetwork(body)
    }

    public func clearNetworkLogs() {
        logs.network.removeAll()
    }
}
