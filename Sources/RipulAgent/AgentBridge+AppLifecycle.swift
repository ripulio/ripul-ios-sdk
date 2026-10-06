import Foundation
import Network
#if canImport(UIKit)
import UIKit
#endif

/// What happens around the page rather than in it: the app leaving and
/// returning to the foreground, memory warnings, and the network changing
/// under an open socket.
extension AgentBridge {
    /// Called by the host when the app leaves the foreground. The matching
    /// "became active" edge is `notifyWebViewBecameVisible()`.
    public func notifyAppBackgrounded() {
        appIsForeground = false
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
        appIsForeground = true
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
    func fireForegroundSyncEvals() {
        evaluateJavaScript("""
            document.dispatchEvent(new Event('visibilitychange'));
            if (window.__ripulForegrounded) { window.__ripulForegrounded(); }
            true;
        """)
    }

    /// Observe app lifecycle + memory-pressure so a wedge's context (was it
    /// backgrounded? was there a memory warning just before?) is in the log,
    /// turning the next incident into a root-cause-grade timeline.
    func startProcessLifecycleMonitoring() {
        #if os(iOS)
        let nc = NotificationCenter.default
        // Account at lifecycle boundaries so a suspended task cannot charge
        // hours in the background to the startup deadline on resume.
        nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.startupBudget.sample(at: ProcessInfo.processInfo.systemUptime, isActive: false)
            }
        }
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.startupBudget.sample(at: ProcessInfo.processInfo.systemUptime, isActive: true)
            }
        }
        // Geometry backstop for the "came back mid-rotation" report: every window
        // re-lays out against its current bounds on foreground, so a size change
        // that landed while suspended is measured. See ForegroundLayoutNudge.
        ForegroundLayoutNudge.install()
        // Main-thread stall detection. Called straight through rather than from
        // a `Task { @MainActor }`: this class is already @MainActor, so the hop
        // bought nothing and added a way for the start to silently not happen —
        // which is one of the two reasons this monitor shipped twice without
        // emitting a single line. It logs via the NSLog tee itself.
        MainThreadStallMonitor.shared.start()
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
    func startNetworkPathMonitoring() {
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
}
