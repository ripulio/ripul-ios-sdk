import Foundation
import WebKit

/// Telling whether the page's JavaScript context is alive, and bringing it
/// back when it is not: the probe, the self-heal, and the backstop for a host
/// bridge that keeps saying it is unavailable.
///
/// Which rung of the ladder comes next, and when the backstop should probe,
/// are decided in `WebContextRecovery.swift`. This file does what they decide.
extension AgentBridge {
    /// True only when the app is actively foregrounded — the only state in which
    /// a WKWebView will actually perform a network load. Always true on macOS
    /// (no content-process suspension on background).
    var isAppActive: Bool {
        #if os(iOS)
        return UIApplication.shared.applicationState == .active
        #else
        return true
        #endif
    }

    /// Run a recovery reload now if foregrounded, else defer it to the next
    /// foreground. This is the fix for "reload() dropped while backgrounded →
    /// still dead on resume". User-initiated reloads do NOT go through here.
    func recoveryReload(label: String, _ action: @escaping () -> Void) {
        if isAppActive {
            action()
        } else {
            handleConsoleLog("WARN: [WEBVIEW_HEAL] \(label) deferred — app backgrounded (WKWebView can't load while suspended); will run on foreground")
            deferredRecoveryReload = action
        }
    }

    /// If a recovery reload was deferred while backgrounded, perform it now.
    @discardableResult
    func consumeDeferredRecoveryReload() -> Bool {
        guard let action = deferredRecoveryReload else { return false }
        deferredRecoveryReload = nil
        handleConsoleLog("LOG: [WEBVIEW_HEAL] performing deferred recovery reload on foreground")
        action()
        return true
    }

    /// Result of probing the web view's JS context with a canary eval.
    public enum WebContextHealth: String {
        /// Canary round-tripped and the remote-session callables are installed.
        case healthy
        /// JS runs, but the React tree crashed (window.__ripulWebAppCrashed set) —
        /// remote-session providers are gone until the page reloads.
        case webCrashed
        /// JS runs, but the __ripul* callables aren't installed YET and the page
        /// is plausibly still booting (young document / not `complete`).
        /// Retrying genuinely can succeed.
        case callablesMissing
        /// JS runs, the page has SETTLED (or its boot beacon says the boot chain
        /// finished or failed), and the callables still aren't there. Retrying will
        /// never fix this — the web boot chain broke. Distinct from
        /// `callablesMissing` so we stop telling the user to "try again in a
        /// moment" about a page that is done trying.
        case callablesAbsent

        /// Even a string-literal eval fails — the context is wedged or the
        /// content process is gone. Only a reload recovers this.
        case contextDead
        case noWebView
    }

    /// Human description of a WKWebView eval error incl. domain + code + name.
    /// The code is the single most diagnostic datum for the JS-context wedge.
    public static func describeEvalError(_ error: Error) -> String {
        let ns = error as NSError
        let name: String
        switch (ns.domain, ns.code) {
        case ("WKErrorDomain", 2): name = "WebContentProcessTerminated"
        case ("WKErrorDomain", 4): name = "JavaScriptExceptionOccurred"
        case ("WKErrorDomain", 5): name = "JavaScriptResultTypeIsUnsupported"
        case ("WKErrorDomain", 9): name = "ContentRuleListStoreLookUpFailed"
        default: name = ns.localizedDescription
        }
        return "\(ns.domain)#\(ns.code) \(name)"
    }

    /// Everything the probe canary could see, gathered from PLAIN BROWSER APIs.
    ///
    /// Deliberately does not touch `window.__ripulDiagnostics`: that callable is
    /// installed by `registerNativeCallables()`, the very thing that is missing
    /// in the state we most need to explain — so the old forensic path went dark
    /// exactly when it mattered and every report came back empty.
    public struct WebContextProbe {
        public var health: WebContextHealth
        /// `document.readyState` at probe time.
        public var readyState: String?
        /// Age of the current document — separates a boot race from a dead boot.
        public var docAgeMs: Int?
        /// Which page is actually loaded (a non-app shell has no callables by design).
        public var path: String?
        /// `navigation` timing type: navigate / reload / back_forward.
        public var navType: String?
        /// Does the UA carry `RipulNative`? If false, `isNativeAppMode()` said no
        /// and the callables were never even attempted.
        public var uaNative: Bool?
        /// How many `__ripul*` globals exist. 0 = the boot chain never got there;
        /// many-but-not-ours = partial/foreign registration.
        public var ripulGlobals: Int?
        /// Last phase recorded by the web boot beacon, plus its error if it threw.
        public var bootPhase: String?
        public var bootError: String?
        public var build: String?
        /// The canary's raw JSON, for the copyable technical details.
        public var raw: String?

        /// One-line digest for logs and the user-visible error string. This is
        /// what turns "it flapped again" into a diagnosable event.
        public var digest: String {
            var parts: [String] = []
            if let path { parts.append("path=\(path)") }
            if let readyState { parts.append("ready=\(readyState)") }
            if let docAgeMs { parts.append("age=\(docAgeMs / 1000)s") }
            if let navType { parts.append("nav=\(navType)") }
            if let ripulGlobals { parts.append("globals=\(ripulGlobals)") }
            if let uaNative { parts.append("uaNative=\(uaNative)") }
            if let bootPhase { parts.append("boot=\(bootPhase)") }
            if let bootError { parts.append("bootErr=\(bootError.prefix(120))") }
            if let build { parts.append("build=\(build)") }
            return parts.joined(separator: " ")
        }
    }

    /// How long a navigation may be in flight before a heal will interrupt it.
    /// Above WebKit's own 60s request timeout, so a stalled load fails honestly
    /// (and heals on that) instead of being cancelled and restarted forever.
    private static let inFlightLoadCeiling: TimeInterval = 75

    /// Back-compat shim for call sites that only need the verdict.
    public func probeWebContextHealth() async -> WebContextHealth {
        await probeWebContext().health
    }

    /// Probe the JS context with a canary that returns a plain string (always
    /// bridgeable — a probe must never itself fail with "unsupported type").
    /// A canary failure is captured with its WKError code so `.contextDead`
    /// carries WHY (process gone vs suspended vs unbridgeable).
    public func probeWebContext() async -> WebContextProbe {
        guard let webView = attachedWebView else { return WebContextProbe(health: .noWebView) }
        let canary = """
        (function () {
          try {
            var w = window, keys = [];
            try { keys = Object.keys(w).filter(function (k) { return k.indexOf('__ripul') === 0; }); } catch (e) {}
            var nav = null;
            try { var n = performance.getEntriesByType('navigation')[0]; if (n) nav = n.type; } catch (e) {}
            var boot = null;
            try { boot = w.__ripulBoot || null; } catch (e) {}
            return JSON.stringify({
              callables: !!w.__ripulOpenRemoteSession,
              crashed: !!w.__ripulWebAppCrashed,
              globals: keys.length,
              globalNames: keys.slice(0, 12),
              readyState: document.readyState,
              docAgeMs: Math.round(performance.now()),
              path: location.pathname,
              nav: nav,
              uaNative: (navigator.userAgent || '').indexOf('RipulNative') >= 0,
              bootPhase: boot ? boot.phase : null,
              bootError: boot ? (boot.error || null) : null,
              bootHistory: boot ? boot.history : null,
              build: boot ? boot.build : null
            });
          } catch (e) { return JSON.stringify({ probeError: String(e) }); }
        })();
        """
        let raw: String? = await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            webView.evaluateJavaScript(canary) { [weak self] value, error in
                if let error {
                    Task { @MainActor in
                        self?.handleConsoleLog("WARN: [CONN_DIAG] context probe canary failed: \(AgentBridge.describeEvalError(error)) — active=\(self?.isAppActive ?? false) url=\(self?.attachedWebView?.url?.absoluteString ?? "nil")")
                    }
                    cont.resume(returning: nil)
                } else {
                    cont.resume(returning: value as? String)
                }
            }
        }
        return WebContextProbe.read(raw)
    }

    /// Set by the host app (macOS) to record web-view self-heal reloads into its
    /// persistent restart log — a heal reloads the whole web app, which reads as
    /// "the host restarted". Args: (reason, attempt) where attempt 1 = plain
    /// reload, 2–3 = purge + reload, 4+ = ladder exhausted.
    public static var webViewHealRecorder: ((String, Int) -> Void)?

    /// Recover a dead/crashed JS context, escalating on repeated failures within
    /// the window. Returns true if a recovery action was triggered.
    @discardableResult
    public func healWebContext(reason: String, force: Bool = false) async -> Bool {
        // A load that is still in flight is not a context to heal — it is one
        // that has not finished yet. Reloading over it CANCELS it (-999) rather
        // than retrying it, and the fresh load is cancelled by the next heal in
        // turn, so on a slow network no attempt ever completes or reaches its
        // own timeout to report an honest error. Let WebKit's 60s request
        // timeout do its job; past the ceiling the load really has hung.
        if !force, attachedWebView?.isLoading == true,
           Date().timeIntervalSince(navigationBeganAt ?? .distantPast) < Self.inFlightLoadCeiling {
            handleConsoleLog("LOG: [WEBVIEW_HEAL] load still in flight — leaving it alone (\(reason))")
            if healLadder.persistent { scheduleInFlightRecheck(reason: reason) }
            return false
        }
        // A suspended WKWebView won't reload, and probing/escalating while
        // backgrounded is pointless (and would burn through the ladder against a
        // process that can't recover until resume). Arm a deferred reload and
        // bail; notifyWebViewBecameVisible() heals for real on foreground.
        if !isAppActive {
            handleConsoleLog("WARN: [WEBVIEW_HEAL] unhealthy while backgrounded (\(reason)) — deferring reload to foreground")
            deferredRecoveryReload = { [weak self] in self?.reload() }
            return false
        }
        switch healLadder.next(at: recoveryClock()) {
        case .tooSoon(let since, let floor):
            handleConsoleLog("WARN: [WEBVIEW_HEAL] skipped, healed \(Int(since))s ago (floor \(Int(floor))s) — \(reason)")
            // Unattended host: don't just sit here — schedule a retry once the
            // floor has elapsed. iOS relies on the user tapping Retry instead.
            if healLadder.persistent { scheduleDeferredHeal(reason: reason) }
            return false
        case .heal(let attempt, let rung, let floor):
            Self.webViewHealRecorder?(reason, attempt)
            switch rung {
            case .reload:
                handleConsoleLog("ERROR: [WEBVIEW_HEAL] attempt 1 (\(reason)) — reloading web app")
                recoveryReload(label: "heal reload") { [weak self] in self?.reload() }
            case .purge:
                handleConsoleLog("ERROR: [WEBVIEW_HEAL] attempt \(attempt) (\(reason)) — reload didn't stick; purging session state + reloading")
                recoveryReload(label: "heal purge") { [weak self] in self?.purgeWebStateAndReload() }
            case .persistentPurge:
                handleConsoleLog("ERROR: [WEBVIEW_HEAL] attempt \(attempt) (\(reason)) — macOS host, continuing purge + reload with \(Int(floor))s floor")
                recoveryReload(label: "heal purge (macOS persistent)") { [weak self] in self?.purgeWebStateAndReload() }
            case .exhausted:
                handleConsoleLog("ERROR: [WEBVIEW_HEAL] attempt \(attempt) (\(reason)) — auto-recovery exhausted; relaunch required (device may be offline)")
                return false
            }
            scheduleHealVerification(reason: reason)
            return true
        }
    }

    /// macOS-only: look again once a load that was in flight has had time to
    /// settle.
    ///
    /// Deliberately NOT `scheduleDeferredHeal`: that one re-enters
    /// `healWebContext` immediately when its floor has already elapsed, so
    /// calling it from the in-flight guard would spin on the CPU rather than
    /// wait. The fixed sleep makes this a bounded poll, and `reason` is passed
    /// through unchanged so a retry does not grow the string each round.
    private func scheduleInFlightRecheck(reason: String) {
        deferredHealTask?.cancel()
        deferredHealTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self, !Task.isCancelled, self.isAppActive else { return }
            await self.healWebContext(reason: reason)
        }
    }

    /// macOS-only: schedule a heal retry once the current floor has elapsed.
    /// Cancels any previous deferred heal so floors don't stack.
    private func scheduleDeferredHeal(reason: String) {
        deferredHealTask?.cancel()
        deferredHealTask = Task { [weak self] in
            guard let self else { return }
            let delay = self.healLadder.remainingFloor(at: self.recoveryClock())
            guard delay > 0 else {
                await self.healWebContext(reason: "deferred heal floor elapsed — \(reason)")
                return
            }
            self.handleConsoleLog("LOG: [WEBVIEW_HEAL] macOS deferred heal scheduled in \(Int(delay))s")
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, self.isAppActive else { return }
            await self.healWebContext(reason: "deferred heal fired — \(reason)")
        }
    }

    /// Escalation heal: clear the persisted state that re-poisons a fresh boot
    /// (localStorage pairings/cliSessionMap, IndexedDB chat actions) plus caches,
    /// then fresh-load. PRESERVES cookies so the Clerk session survives (login
    /// also re-injects natively). This is the manual "Clear cache & reload +
    /// Clear sessions data" recovery, done automatically.
    public func purgeWebStateAndReload() {
        var types = WKWebsiteDataStore.allWebsiteDataTypes()
        types.remove(WKWebsiteDataTypeCookies) // keep auth
        let store = attachedWebView?.configuration.websiteDataStore ?? WKWebsiteDataStore.default()
        store.removeData(ofTypes: types, modifiedSince: .distantPast) { [weak self] in
            guard let self, let webView = self.attachedWebView else { return }
            self.handleConsoleLog("WARN: [WEBVIEW_HEAL] session state + caches purged (cookies kept) — fresh load")
            self.isConnected = false
            self.isThemeReady = false
            if let url = webView.url,
               var components = URLComponents(url: url, resolvingAgainstBaseURL: true) {
                var items = (components.queryItems ?? []).filter { $0.name != "_cb" }
                items.append(URLQueryItem(name: "_cb", value: "\(Int(Date().timeIntervalSince1970))"))
                components.queryItems = items
                var request = URLRequest(url: components.url ?? url)
                request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                webView.load(request)
            } else {
                webView.reloadFromOrigin()
            }
        }
    }

    /// After a heal, verify the context actually came back — and escalate
    /// proactively if it didn't, rather than waiting for the user's next failed
    /// tap (which the floor might defer). Healthy → reset the ladder.
    private func scheduleHealVerification(reason: String) {
        healVerifyTask?.cancel()
        healVerifyTask = Task { [weak self] in
            for round in 1...Self.healVerifyMaxRounds {
                try? await Task.sleep(nanoseconds: 15_000_000_000) // 15s — fair chance to reload on cellular
                guard let self, !Task.isCancelled else { return }
                let health = await self.probeWebContextHealth()
                switch health {
                case .healthy:
                    // The canary only proves `registerNativeCallables()` ran — and
                    // that happens PRE-React, so a page whose React tree died still
                    // probes `.healthy`. Demand a functional answer too:
                    // `__ripulDiagnostics` is served by the app layer, so a shell
                    // returns nil here. Observed 2026-08-10 12:42:35 — the heal
                    // fired, the bridge re-handshaked, verification passed, and the
                    // host stayed dead for another 8 minutes.
                    if await self.fetchWebDiagnostics() == nil {
                        self.handleConsoleLog("WARN: [WEBVIEW_HEAL] post-heal canary healthy but diagnostics unreachable — shell context; escalating")
                        await self.healWebContext(reason: "post-heal shell (canary healthy, no diagnostics)")
                        return
                    }
                    self.handleConsoleLog("LOG: [WEBVIEW_HEAL] post-heal probe healthy — recovered after \(self.healLadder.attempts) attempt(s)")
                    self.healLadder.reset()
                    self.deferredHealTask?.cancel()
                    self.deferredHealTask = nil
                    return
                case .contextDead, .webCrashed, .callablesAbsent:
                    // callablesAbsent post-heal means the RELOAD came back without a
                    // native bridge too — escalating to the purge rung is the point.
                    self.handleConsoleLog("WARN: [WEBVIEW_HEAL] post-heal probe \(health.rawValue) — escalating")
                    await self.healWebContext(reason: "post-heal still \(health.rawValue)")
                    return
                case .callablesMissing, .noWebView:
                    // Still booting or no view — don't escalate to a purge on a slow
                    // load. But "still booting" forever IS the wedge, and a single
                    // look then walking away left it unhealed; keep re-checking on a
                    // bounded schedule and escalate once the rounds are spent.
                    if round == Self.healVerifyMaxRounds {
                        self.handleConsoleLog("WARN: [WEBVIEW_HEAL] post-heal probe \(health.rawValue) after \(round) rounds — never finished booting; escalating")
                        await self.healWebContext(reason: "post-heal stuck \(health.rawValue)")
                        return
                    }
                    self.handleConsoleLog("LOG: [WEBVIEW_HEAL] post-heal probe \(health.rawValue) — still booting, re-checking (round \(round + 1)/\(Self.healVerifyMaxRounds))")
                }
            }
        }
    }

    /// Post-heal verification rounds (15s apart) before a context that never
    /// finishes booting is treated as wedged rather than merely slow.
    private static let healVerifyMaxRounds = 4

    /// Sentinel returned by the callable-presence guards below. Distinct from
    /// every web-side error string, so "the bridge said no" and "there is no
    /// bridge at all" can never be conflated again — they have different causes
    /// and different fixes.
    public static let callableMissingError = "callable-missing"

    /// Record that the host bridge answered normally. Disarms the backstop.
    public func noteHostBridgeAvailable() {
        if hostBridgeBackstop.noteAvailable() {
            handleConsoleLog("LOG: [HOST_BRIDGE] available again — clearing unavailability backstop")
        }
    }

    /// Record that the host bridge is unavailable, and heal if it stays that
    /// way. Safe to call at any cadence, from any number of callers.
    public func noteHostBridgeUnavailable(reason: String) {
        switch hostBridgeBackstop.noteUnavailable(at: recoveryClock()) {
        case .armed:
            handleConsoleLog("WARN: [HOST_BRIDGE] unavailable (\(reason)) — backstop armed; probing in \(Int(HostBridgeBackstop.grace))s if it persists")
        case .waiting:
            break
        case .probe(let since):
            Task { [weak self] in
                guard let self else { return }
                let probe = await self.probeWebContext()
                let elapsed = Int(self.recoveryClock().timeIntervalSince(since))
                self.handleConsoleLog("WARN: [HOST_BRIDGE] unavailable \(elapsed)s (\(reason)) — probe=\(probe.health.rawValue) \(probe.digest)")
                switch probe.health {
                case .contextDead, .webCrashed, .callablesAbsent:
                    await self.healWebContext(
                        reason: "host bridge unavailable \(elapsed)s: \(reason) — \(probe.health.rawValue)"
                    )
                case .callablesMissing:
                    // Genuinely mid-boot (young document). The next tick re-probes.
                    break
                case .healthy:
                    // Callables ARE installed, so the page is answering and telling
                    // us the provider isn't registered. That's a web-side mount
                    // failure with its own error boundary + auto-remount; reloading
                    // over the top of an accurate report doesn't help. Stay loud.
                    self.handleConsoleLog("WARN: [HOST_BRIDGE] context healthy but bridge unavailable \(elapsed)s — web-side provider problem, not healing")
                case .noWebView:
                    break
                }
            }
        }
    }

    /// Fetch the web app's one-shot connection diagnostics snapshot
    /// (`__ripulDiagnostics`) as a JSON string, or nil if unreachable.
    /// `focusChatId` names the chat a failure was about, and `action` what was
    /// being done to it: the snapshot then leads with that chat's own facts.
    public func fetchWebDiagnostics(focusChatId: String? = nil, action: String? = nil) async -> String? {
        let script = """
        if (!window.__ripulDiagnostics) return null;
        return JSON.stringify(await window.__ripulDiagnostics(focusChatId ? { chatId: focusChatId, action } : undefined));
        """
        let arguments: [String: Any] = [
            "focusChatId": focusChatId.map { $0 as Any } ?? NSNull(),
            "action": action.map { $0 as Any } ?? NSNull(),
        ]
        return await runPage(script, arguments: arguments, log: .none).value as? String
    }

    /// Turn an opaque JS-call failure (throw, or an unbridgeable/nil result)
    /// into a classified, actionable error string — probing the JS context and
    /// self-healing when that's what's actually broken. This is what stops
    /// "JavaScript execution returned a result of an unsupported type" from
    /// being both the alert text AND a permanent state.
    func classifyJsCallFailure(_ rawDescription: String, callable: String) async -> String {
        handleConsoleLog("ERROR: [CONN_DIAG] \(callable) failed: \(rawDescription) — probing web context")
        let probe = await probeWebContext()
        // Log the FULL probe every time. This failure flaps, and a flapping
        // failure is only diagnosable from a trail of snapshots — one screenshot
        // of an alert is not enough to tell a boot race from a broken boot.
        handleConsoleLog("WARN: [CONN_DIAG] \(callable) probe=\(probe.health.rawValue) \(probe.digest)")
        if let raw = probe.raw {
            handleConsoleLog("WARN: [CONN_DIAG] \(callable) probe raw: \(raw)")
        }
        let digest = probe.digest.isEmpty ? rawDescription : "\(probe.digest) | was: \(rawDescription)"

        switch probe.health {
        case .contextDead:
            let healed = await healWebContext(reason: "\(callable): \(rawDescription)")
            return healed
                ? "web-context-dead: the app's web layer stopped responding and was reloaded automatically — try again in a few seconds. (\(digest))"
                : "web-context-dead: the app's web layer is not responding; a reload was already attempted recently. (\(digest))"
        case .webCrashed:
            let healed = await healWebContext(reason: "\(callable): web app crashed")
            return healed
                ? "web-crashed: the app hit an internal error and was reloaded automatically — try again in a few seconds. (\(digest))"
                : "web-crashed: the app hit an internal error; a reload was already attempted recently. (\(digest))"
        case .callablesMissing:
            // Genuinely mid-boot: young document, boot chain still running.
            // "Try again in a moment" is honest here and only here.
            return "not-ready: the app's web layer is still starting up — try again in a moment. (\(digest))"
        case .callablesAbsent:
            // The page finished loading WITHOUT its native bridge. Retrying
            // cannot fix this, so heal rather than telling the user to wait.
            let healed = await healWebContext(reason: "\(callable): callables absent after boot — \(probe.digest)")
            return healed
                ? "callables-absent: the app's web layer loaded without its native bridge and was reloaded automatically — try again in a few seconds. (\(digest))"
                : "callables-absent: the app's web layer loaded without its native bridge; a reload was already attempted recently. (\(digest))"
        case .noWebView:
            return "no-web-view: no web view is attached. (\(digest))"
        case .healthy:
            // The context is fine — the failure is in the call itself. Attach
            // the web diagnostics snapshot to the console log for forensics.
            if let diag = await fetchWebDiagnostics() {
                handleConsoleLog("WARN: [CONN_DIAG] web context healthy; diagnostics: \(diag)")
            }
            return rawDescription
        }
    }
}

extension AgentBridge.WebContextProbe {
    /// A document younger than this is given the benefit of the doubt as a boot
    /// race; past it, absent callables are treated as a broken boot, not a slow one.
    static let callableInstallGraceMs = 8_000

    /// The verdict on what the canary returned. Nothing, or anything that is
    /// not the canary's own JSON, means the context is dead.
    static func read(_ raw: String?) -> AgentBridge.WebContextProbe {
        guard let raw,
              let data = raw.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return AgentBridge.WebContextProbe(health: .contextDead, raw: raw)
        }

        var probe = AgentBridge.WebContextProbe(health: .healthy)
        probe.readyState = dict["readyState"] as? String
        probe.docAgeMs = dict["docAgeMs"] as? Int
        probe.path = dict["path"] as? String
        probe.navType = dict["nav"] as? String
        probe.uaNative = dict["uaNative"] as? Bool
        probe.ripulGlobals = dict["globals"] as? Int
        probe.bootPhase = dict["bootPhase"] as? String
        probe.bootError = dict["bootError"] as? String
        probe.build = dict["build"] as? String
        probe.raw = raw

        if (dict["crashed"] as? Bool) == true {
            probe.health = .webCrashed
        } else if (dict["callables"] as? Bool) != true {
            // Booting, or broken? The boot beacon answers directly when present:
            // a terminal phase means the chain ran to its end WITHOUT registering.
            // Without a beacon (old bundle, or a shell that never loads the app),
            // fall back to document age + readyState.
            let terminalPhases = ["boot-complete", "boot-failed", "native-mode-false", "sidepanel-initialized"]
            let bootSettled = probe.bootPhase.map { terminalPhases.contains($0) } ?? false
            let ageSettled = (probe.docAgeMs ?? 0) >= callableInstallGraceMs
                && (probe.readyState ?? "") == "complete"
            probe.health = (bootSettled || ageSettled) ? .callablesAbsent : .callablesMissing
        }
        return probe
    }
}
