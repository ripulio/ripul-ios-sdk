import Foundation
import WebKit

/// The page loading: watching a start that is taking too long, and the ways
/// to load it again (reload, reload past the cache, reload from nothing).
extension AgentBridge {
    /// One monitor owns download, bridge and optional host authentication waits.
    /// Also starts before WKWebView creation, so validation cannot spin forever.
    public func beginStartupMonitoring() {
        connectionTimeoutTask?.cancel()
        startupBudget = StartupLoadBudget()
        startupBudget.sample(at: ProcessInfo.processInfo.systemUptime, isActive: isAppActive)
        startupMonitoring = true
        startupNavigationFinished = false
        startupLastStage = ""
        startupTimeoutError = nil
        setIfChanged(\.loadError, nil)
        setIfChanged(\.loadErrorDetails, nil)
        startupLoadState.message = "Preparing app…"
        startupLoadState.isTakingLonger = false
        connectionTimeoutTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self else { return }
                self.updateStartupMonitoring(at: ProcessInfo.processInfo.systemUptime, isActive: self.isAppActive)
                if !self.startupMonitoring { return }
            }
        }
    }

    public func pageDidStartLoading() {
        toolStrip.clear()
        #if os(iOS)
        toolStripRows?.clear()
        nativeEmbeds?.clear()
        #endif
        setIfChanged(\.isConnected, false)
        // Preserve the overall budget across initial validation and navigation,
        // including redirects. Explicit Retry starts a new attempt in reload().
        if !startupMonitoring { beginStartupMonitoring() }
        startupNavigationFinished = false
        navigationBeganAt = Date()
        recordStartupProgress()
    }

    func recordStartupProgress() {
        guard startupMonitoring else { return }
        startupBudget.madeProgress()
    }

    // Clock input is explicit so deadline/late-success behavior can be tested
    // without sleeping or depending on network speed.
    func updateStartupMonitoring(at now: TimeInterval, isActive: Bool) {
        guard startupMonitoring else { return }
        startupBudget.sample(at: now, isActive: isActive)
        guard isActive else { return }
        checkStartupProgress()
    }

    func checkStartupProgress() {
        let auth = startupAuthenticationState?()
        if isConnected && auth == nil {
            startupMonitoring = false
            startupLoadState.message = "Ready"
            startupLoadState.isTakingLonger = false
            stopStartupResourceObservation()
            if loadError == startupTimeoutError {
                loadError = nil
                loadErrorDetails = nil
            }
            return
        }
        let stage: String
        if isConnected {
            stage = auth == "alive" ? "Restoring your session…" : "Signing in…"
        } else if attachedWebView == nil {
            stage = "Preparing app…"
        } else if startupNavigationFinished {
            stage = "Starting app…"
        } else {
            stage = "Loading app…"
        }
        if stage != startupLastStage {
            startupLastStage = stage
            startupLoadState.message = stage
            startupBudget.reachedMilestone(stage)
            handleConsoleLog("LOG: [STARTUP_LOAD] " + stage)
        }
        let slow = startupBudget.elapsed >= 15
        if startupLoadState.isTakingLonger != slow { startupLoadState.isTakingLonger = slow }
        guard loadError == nil, let failure = startupBudget.failure else { return }
        let error = isConnected ? "Signing in didn’t complete" : "Startup is taking too long"
        startupTimeoutError = error
        stopStartupResourceObservation()
        loadError = error
        let reason = failure == .overallLimit
            ? "Startup reached the 2-minute foreground limit."
            : "No startup progress was detected for 30 seconds."
        loadErrorDetails = "\(reason) Stage: \(stage) Retry to try again; your cached downloads and sign-in are preserved."
        handleConsoleLog("WARN: [STARTUP_LOAD] \(reason) stage=\(stage) progress=\(attachedWebView?.estimatedProgress ?? 0) auth=\(auth ?? "not-required")")
        // Keep observing: late completion can still dismiss the error. Never
        // interrupt a potentially active download or clear its cache here.
    }

    func stopStartupResourceObservation() {
        attachedWebView?.evaluateJavaScript("window.__ripulStopStartupObservation?.()", completionHandler: nil)
    }

    /// Called by the coordinator when navigation completes. Dynamic imports and
    /// authentication may still be loading; completion is only one milestone.
    public func pageDidFinishLoading() {
        navigationBeganAt = nil
        // Push persisted network capture state into the web view
        if isNetworkCaptureEnabled {
            evaluateJavaScript("window.__ripulNetworkCapture && window.__ripulNetworkCapture(true)")
        }
        // Push the native-console-logging master flag. Default false => console.*
        // does not cross the bridge (quiet/cool). Re-pushed on every load so a
        // self-heal reload keeps the setting.
        evaluateJavaScript("window.__ripulNativeLog = \(AgentBridge.verboseBridgeLog)")
        // Same for the [SESSION-START] latency gate — default false => the web
        // sessionStartTimer helpers no-op, matching the native emitters.
        evaluateJavaScript("window.__ripulSessionStartTimer = \(AgentBridge.sessionStartInstrumentation)")
        // Refresh the host-prefs mirror with CURRENT UserDefaults values — the
        // documentStart script is baked at webview creation, so this is what
        // keeps reloads of the same webview accurate after host-prefs:set writes.
        pushHostPrefsToPage()
        pushHostTokenToPage()
        startupNavigationFinished = true
        recordStartupProgress()
    }

    /// Reload the web view, clearing any load error.
    public func reload() {
        guard let webView = attachedWebView else {
            NSLog("[AgentBridge] Cannot reload — webView is nil")
            return
        }
        beginStartupMonitoring()
        isConnected = false
        isThemeReady = false
        initialStatusSyncComplete = false
        composerActions.clear()
        resetLifecycleState()
        jsErrorMessages = []
        jsErrorDebounce?.cancel()
        webView.reload()
    }

    /// Clear cached resources (JS, CSS, images) and reload the web view.
    /// Preserves cookies, localStorage, and session data so the user stays logged in.
    ///
    /// - Parameter target: the address to load instead of the current one, for
    ///   a reload that changes how the page boots. The cache-busting query
    ///   makes it a real load even when only the fragment differs, which a web
    ///   view otherwise treats as a move within the same document.
    public func clearCacheAndReload(to target: URL? = nil) {
        beginStartupMonitoring()
        let cacheTypes: Set<String> = [
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache,
            WKWebsiteDataTypeOfflineWebApplicationCache,
            WKWebsiteDataTypeFetchCache,
        ]
        let store = attachedWebView?.configuration.websiteDataStore ?? WKWebsiteDataStore.default()
        store.removeData(ofTypes: cacheTypes, modifiedSince: .distantPast) { [weak self] in
            guard let self, let webView = self.attachedWebView else {
                NSLog("[AgentBridge] Cannot reload — webView is nil")
                return
            }
            NSLog("[AgentBridge] Cache cleared, performing fresh load (not reloadFromOrigin)")
            self.isConnected = false
            self.isThemeReady = false
            // Use a fresh URLRequest with a cache-busting query parameter.
            // WKWebView's removeData() is unreliable — it often doesn't actually
            // clear the HTTP cache. A unique URL forces a real network fetch.
            // Once the HTML loads fresh, it references new content-hashed JS
            // filenames, so the entire bundle chain is guaranteed fresh.
            if let url = target ?? webView.url,
               var components = URLComponents(url: url, resolvingAgainstBaseURL: true) {
                var items = components.queryItems ?? []
                items.removeAll { $0.name == "_cb" }
                items.append(URLQueryItem(name: "_cb", value: "\(Int(Date().timeIntervalSince1970))"))
                components.queryItems = items
                if let bustURL = components.url {
                    var request = URLRequest(url: bustURL)
                    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                    webView.load(request)
                } else {
                    webView.reloadFromOrigin()
                }
            } else {
                webView.reloadFromOrigin()
            }
        }
    }

    /// Clear ALL website data (cache, cookies, localStorage, IndexedDB, etc.) and reload.
    /// This is a full reset — the user will need to log in again.
    public func clearAllDataAndReload() {
        beginStartupMonitoring()
        let allTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        let store = attachedWebView?.configuration.websiteDataStore ?? WKWebsiteDataStore.default()
        store.removeData(ofTypes: allTypes, modifiedSince: .distantPast) { [weak self] in
            guard let webView = self?.attachedWebView else {
                return
            }
            NSLog("[AgentBridge] All website data cleared, performing fresh load")
            self?.isConnected = false
            self?.isThemeReady = false
            // Use a fresh URLRequest to bypass WKWebView's ES module cache
            if let url = webView.url {
                var request = URLRequest(url: url)
                request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                webView.load(request)
            } else {
                webView.reloadFromOrigin()
            }
        }
    }

    /// Navigate the attached web view to a new URL (e.g. to start a new chat with a prompt).
    public func navigate(to url: URL) {
        guard let webView = attachedWebView else {
            NSLog("[AgentBridge] Cannot navigate — webView is nil")
            return
        }
        isConnected = false
        isThemeReady = false
        wantsMinimize = false
        NSLog("[AgentBridge] Navigating to: %@", url.absoluteString)
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        webView.load(request)
    }
}
