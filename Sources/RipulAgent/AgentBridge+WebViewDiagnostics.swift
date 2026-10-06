import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The record of what went wrong with the web view: each time its content
/// process was terminated, and each health report taken of it. Both are kept
/// across launches so a crash can be looked at after the fact.
extension AgentBridge {
    private func persistCrashEvents() {
        // Keep only last 20 events
        let trimmed = Array(crashEvents.suffix(20))
        if let data = try? JSONEncoder().encode(trimmed) {
            UserDefaults.standard.set(data, forKey: Self.crashEventsKey)
        }
    }

    private func persistHealthReports() {
        let trimmed = Array(healthReports.suffix(30))
        if let data = try? JSONEncoder().encode(trimmed) {
            UserDefaults.standard.set(data, forKey: Self.healthReportsKey)
        }
    }

    /// Called by AgentWebView when the web content process is terminated by the OS.
    /// Records the event, logs it to the bridge console, and reloads.
    public func recordProcessTermination() {
        sessionCrashCount += 1

        // Capture memory stats at crash time
        let (rss, avail, thermal) = ProcessVitals.now().values

        let event = WebViewCrashEvent(
            id: UUID(),
            timestamp: Date(),
            appMemoryMB: rss,
            availableMemoryMB: avail,
            thermalState: thermal,
            url: attachedWebView?.url?.absoluteString,
            wasConnected: isConnected,
            crashNumber: sessionCrashCount
        )
        crashEvents.append(event)
        persistCrashEvents()

        // Log to bridge console (visible in Console Logs viewer)
        let msg = String(format:
            "ERROR: [CRASH] Web content process terminated (#%d this session). RSS=%.0fMB Avail=%.0fMB Thermal=%@ URL=%@ Bridge=%@",
            sessionCrashCount, rss, avail, thermal,
            attachedWebView?.url?.absoluteString ?? "nil",
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
        let (rss, avail, thermal) = ProcessVitals.now().values

        let wvExists = attachedWebView != nil
        let url = attachedWebView?.url?.absoluteString
        let title = attachedWebView?.title
        let loading = attachedWebView?.isLoading ?? false
        let progress = attachedWebView?.estimatedProgress ?? 0

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
}

/// What this process looked like at one moment: the memory it holds, what
/// the system has left to give it, and how hot the device is.
private struct ProcessVitals {
    let residentMB: Double
    let availableMB: Double
    let thermal: String

    var values: (Double, Double, String) { (residentMB, availableMB, thermal) }

    static func now() -> ProcessVitals {
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

        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "Nominal"
        case .fair: thermal = "Fair"
        case .serious: thermal = "Serious"
        case .critical: thermal = "Critical"
        @unknown default: thermal = "Unknown"
        }
        return ProcessVitals(residentMB: rss, availableMB: avail, thermal: thermal)
    }
}
