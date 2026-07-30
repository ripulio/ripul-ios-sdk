import SwiftUI
import WebKit
#if os(iOS)
import ObjectiveC
#endif

/// Map NSError codes to user-facing messages that explain what actually went wrong.
private func userFacingErrorMessage(_ error: NSError) -> String {
    guard error.domain == NSURLErrorDomain else {
        return error.localizedDescription
    }
    switch error.code {
    case NSURLErrorNotConnectedToInternet:
        return "No internet connection"
    case NSURLErrorTimedOut:
        return "Connection timed out"
    case NSURLErrorCannotFindHost:
        return "Server not found"
    case NSURLErrorCannotConnectToHost:
        return "Could not connect to server"
    case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
         NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateNotYetValid,
         NSURLErrorServerCertificateHasUnknownRoot:
        return "SSL/Security error"
    case NSURLErrorNetworkConnectionLost:
        return "Connection lost"
    case NSURLErrorDNSLookupFailed:
        return "DNS lookup failed"
    default:
        return error.localizedDescription
    }
}

#if os(macOS)

@available(macOS 13.0, *)
@MainActor
public struct AgentWebView: NSViewRepresentable {
    public let configuration: AgentConfiguration
    public let bridge: AgentBridge

    public init(configuration: AgentConfiguration, bridge: AgentBridge) {
        self.configuration = configuration
        self.bridge = bridge
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(bridge: bridge, baseHost: configuration.baseURL.host)
    }

    public func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()

        let bridgeScript = WKUserScript(
            source: Self.bridgeJavaScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(bridgeScript)
        config.userContentController.addUserScript(Self.installationIdentityScript)
        config.userContentController.addUserScript(Self.hostPreferencesScript())
        config.userContentController.add(context.coordinator, name: "agentBridge")
        config.userContentController.add(context.coordinator, name: "agentLog")
        config.userContentController.add(context.coordinator, name: "agentNetwork")
        config.userContentController.add(context.coordinator, name: "curtainLowered")

        // Inject font-face declarations for any requested font families
        if let families = configuration.fontFamilies, !families.isEmpty {
            let css = Self.buildFontCSS(families: families, bundle: .main)
            if !css.isEmpty {
                let escaped = css
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "`", with: "\\`")
                let source = """
                (function() {
                    var s = document.createElement('style');
                    s.textContent = `\(escaped)`;
                    (document.head || document.documentElement).appendChild(s);
                })();
                """
                let fontScript = WKUserScript(
                    source: source,
                    injectionTime: .atDocumentEnd,
                    forMainFrameOnly: true
                )
                config.userContentController.addUserScript(fontScript)
            }
        }

        // Mac-appropriate user agent — include Version/ and Safari/ tokens so OAuth
        // providers (Google, etc.) don't detect an embedded web view and block sign-in.
        config.applicationNameForUserAgent = "Version/17.0 RipulNative/1.0 Safari/604.1"

        config.websiteDataStore = configuration.websiteDataStore ?? WKWebsiteDataStore.default()

        // Allow the host app to customize the configuration (e.g., register URL scheme handlers)
        configuration.configureWebView?(config)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.attachWebView(webView)

        #if DEBUG
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        #endif

        bridge.attach(to: webView)

        // _cb makes the HTML URL unique per launch so WKWebView always fetches
        // the latest HTML (which references the current content-hashed bundle
        // URLs). JS bundles are cached by their content-hashed URL, so they are
        // only re-downloaded when they actually change — dramatically reducing
        // launch time and CPU load vs nuking the entire cache on every launch.
        var urlComponents = URLComponents(url: configuration.embeddedURL, resolvingAgainstBaseURL: false)!
        var queryItems = urlComponents.queryItems ?? []
        queryItems.append(URLQueryItem(name: "_cb", value: String(Int(Date().timeIntervalSince1970))))
        urlComponents.queryItems = queryItems
        let url = urlComponents.url!
        NSLog("[AgentWebView] Loading URL: %@", url.absoluteString)
        webView.load(URLRequest(url: url))

        return webView
    }

    public func updateNSView(_ webView: WKWebView, context: Context) {}

    public static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "agentBridge")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "agentLog")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "agentNetwork")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "curtainLowered")
        webView.configuration.userContentController.removeAllUserScripts()
    }

    // MARK: - Coordinator

    public final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        let bridge: AgentBridge
        let baseHost: String?
        private weak var observedWebView: WKWebView?

        init(bridge: AgentBridge, baseHost: String?) {
            self.bridge = bridge
            self.baseHost = baseHost
            super.init()
        }

        func attachWebView(_ webView: WKWebView) {
            observedWebView = webView
        }

        /// Returns true when the URL points to a different host than the app's base URL
        /// and should be opened externally (in the default browser / Safari).
        private func isExternalURL(_ url: URL) -> Bool {
            guard let scheme = url.scheme, ["http", "https"].contains(scheme) else { return false }
            guard let host = url.host else { return false }
            guard let baseHost else { return false }
            return host != baseHost
        }

        public func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            Task { @MainActor in
                if message.name == "agentLog" {
                    bridge.handleConsoleLog(message.body as? String ?? "")
                } else if message.name == "agentNetwork" {
                    bridge.handleNetworkLog(message.body)
                } else if message.name == "curtainLowered" {
                    bridge.lowerWindowCurtain()
                } else {
                    bridge.handleMessage(message.body)
                }
            }
        }

        public func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            if let url = navigationAction.request.url {
                NSLog("[AgentWebView] Navigation: %@", url.absoluteString)
                if navigationAction.navigationType == .linkActivated && isExternalURL(url) {
                    NSLog("[AgentWebView] Opening external URL in browser: %@", url.absoluteString)
                    NSWorkspace.shared.open(url)
                    return .cancel
                }
            }
            return .allow
        }

        /// Handle window.open / target="_blank" — open external URLs in the default browser.
        public func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url {
                NSLog("[AgentWebView] Popup request: %@", url.absoluteString)
                if isExternalURL(url) {
                    NSLog("[AgentWebView] Opening external popup URL in browser: %@", url.absoluteString)
                    NSWorkspace.shared.open(url)
                } else {
                    webView.load(navigationAction.request)
                }
            }
            return nil
        }

        public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            guard let url = webView.url else { return }
            if isExternalURL(url) {
                NSLog("[AgentWebView] External navigation committed — hiding native chrome for: %@", url.host ?? "unknown")
                Task { @MainActor in
                    bridge.currentPageContext = .externalNavigation
                }
            }
        }

        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            NSLog("[AgentWebView] Page finished loading: %@", webView.url?.absoluteString ?? "nil")
            Task { @MainActor in
                bridge.pageDidFinishLoading()
            }
        }

        public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            NSLog("[AgentWebView] Navigation failed: %@", error.localizedDescription)
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
            Task { @MainActor in
                bridge.loadError = userFacingErrorMessage(nsError)
                bridge.loadErrorDetails = error.localizedDescription
            }
        }

        public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            NSLog("[AgentWebView] Provisional navigation failed: %@", error.localizedDescription)
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
            Task { @MainActor in
                bridge.loadError = userFacingErrorMessage(nsError)
                bridge.loadErrorDetails = error.localizedDescription
            }
        }

        /// Called when the WKWebView's web content process crashes or is terminated by the OS.
        /// The web view shows a blank white page after this — record the crash and reload.
        public func webView(_ webView: WKWebView, webContentProcessDidTerminate: WKWebView) {
            Task { @MainActor in
                bridge.recordProcessTermination()
            }
        }

        // MARK: - JavaScript Dialog Handlers (WKUIDelegate)

        public func webView(
            _ webView: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping () -> Void
        ) {
            guard let window = webView.window else { completionHandler(); return }
            let alert = NSAlert()
            alert.messageText = message
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: window) { _ in completionHandler() }
        }

        public func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (Bool) -> Void
        ) {
            guard let window = webView.window else { completionHandler(false); return }
            let alert = NSAlert()
            alert.messageText = message
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { response in
                completionHandler(response == .alertFirstButtonReturn)
            }
        }

        public func webView(
            _ webView: WKWebView,
            runJavaScriptTextInputPanelWithPrompt prompt: String,
            defaultText: String?,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (String?) -> Void
        ) {
            guard let window = webView.window else { completionHandler(nil); return }
            let alert = NSAlert()
            alert.messageText = prompt
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            input.stringValue = defaultText ?? ""
            alert.accessoryView = input
            alert.beginSheetModal(for: window) { response in
                completionHandler(response == .alertFirstButtonReturn ? input.stringValue : nil)
            }
        }
    }
}

#elseif os(iOS)

/// WKWebView subclass that zeroes-out bottom safe area insets so web content
/// (100vh, 100%) fills the entire frame including the home indicator region.
/// The native chat input overlay handles bottom spacing instead.
private class FullBleedWebView: WKWebView {
    override var safeAreaInsets: UIEdgeInsets {
        var insets = super.safeAreaInsets
        insets.bottom = 0
        return insets
    }
}

@available(iOS 15.0, *)
@MainActor
public struct AgentWebView: View {
    public let configuration: AgentConfiguration
    @ObservedObject public var bridge: AgentBridge

    public init(configuration: AgentConfiguration, bridge: AgentBridge) {
        self.configuration = configuration
        self.bridge = bridge
    }

    private var safeAreaTop: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.keyWindow?.safeAreaInsets.top ?? 54
    }

    public var body: some View {
        AgentWebViewRepresentable(configuration: configuration, bridge: bridge)
            .overlay(alignment: .top) {
                if let config = bridge.mastheadConfig {
                    GlassMastheadView(config: config)
                        .contentShape(Capsule())
                        .onLongPressGesture(minimumDuration: 0.6) {
                            bridge.wantsShowConsoleLogs = true
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, safeAreaTop + (config.topOffset ?? 4))
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.spring(duration: 0.3), value: bridge.mastheadConfig != nil)
    }
}

@available(iOS 15.0, *)
@MainActor
private struct AgentWebViewRepresentable: UIViewRepresentable {
    let configuration: AgentConfiguration
    let bridge: AgentBridge

    func makeCoordinator() -> AgentWebView.Coordinator {
        AgentWebView.Coordinator(bridge: bridge, baseHost: configuration.baseURL.host)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()

        // Inject the bridge script before any page JS runs
        let bridgeScript = WKUserScript(
            source: AgentWebView.bridgeJavaScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(bridgeScript)
        config.userContentController.addUserScript(AgentWebView.installationIdentityScript)
        config.userContentController.addUserScript(AgentWebView.hostPreferencesScript())

        config.userContentController.add(context.coordinator, name: "agentBridge")
        config.userContentController.add(context.coordinator, name: "agentLog")
        config.userContentController.add(context.coordinator, name: "agentNetwork")
        config.userContentController.add(context.coordinator, name: "curtainLowered")

        // Inject font-face declarations for any requested font families
        if let families = configuration.fontFamilies, !families.isEmpty {
            let css = AgentWebView.buildFontCSS(families: families, bundle: .main)
            if !css.isEmpty {
                let escaped = css
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "`", with: "\\`")
                let source = """
                (function() {
                    var s = document.createElement('style');
                    s.textContent = `\(escaped)`;
                    (document.head || document.documentElement).appendChild(s);
                })();
                """
                let fontScript = WKUserScript(
                    source: source,
                    injectionTime: .atDocumentEnd,
                    forMainFrameOnly: true
                )
                config.userContentController.addUserScript(fontScript)
            }
        }

        // Allow inline media playback
        config.allowsInlineMediaPlayback = true

        // Build a user agent that matches Mobile Safari closely so OAuth
        // providers (Google, etc.) don't reject sign-in with "disallowed_useragent".
        // WKWebView's default UA omits "Version/..." and "Safari/..." — Google
        // specifically checks for the "Version/" token to distinguish real Safari
        // from embedded web views and blocks OAuth when it's absent.
        // "RipulNative" lets the web app detect native mode via navigator.userAgent.
        config.applicationNameForUserAgent = "Version/17.0 RipulNative/1.0 Mobile/15E148 Safari/604.1"

        // Content-hashed JS bundles + no-cache HTML headers on the server
        // handle cache invalidation correctly. No need to nuke the WKWebView
        // cache on every launch — that just hurts performance.
        config.websiteDataStore = configuration.websiteDataStore ?? WKWebsiteDataStore.default()

        // Allow the host app to customize the configuration (e.g., register URL scheme handlers)
        configuration.configureWebView?(config)

        // Tell the browser engine the virtual keyboard overlays content instead of
        // resizing the viewport.  This prevents WKWebView from shrinking the visual
        // viewport (and by extension any CSS vh / dvh units) when the keyboard opens,
        // which would cause Virtuoso to detect a container resize and re-scroll.
        // Also snapshot the initial viewport height into a CSS custom property so
        // the #tabs container can use a stable value instead of 100vh.
        let viewportFixScript = WKUserScript(
            source: """
            (function() {
                var done = false;
                function patch(meta) {
                    if (done) return;
                    if (meta && meta.content.indexOf('interactive-widget') === -1) {
                        meta.content += ', interactive-widget=overlays-content';
                    }
                    done = true;
                }
                // Try immediately (meta may already be in the parser stream)
                var meta = document.querySelector('meta[name="viewport"]');
                if (meta) { patch(meta); return; }
                // Otherwise watch for it
                var obs = new MutationObserver(function() {
                    var m = document.querySelector('meta[name="viewport"]');
                    if (m) { patch(m); obs.disconnect(); }
                });
                obs.observe(document.documentElement, { childList: true, subtree: true });
            })();
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(viewportFixScript)

        let webView = FullBleedWebView(frame: .zero, configuration: config)
        // Thermal A/B (AgentBridge.opaqueWebView): a transparent web view must blend
        // every repaint against the layers behind it; opaque is a cheap copy. Default
        // false keeps the current transparent behaviour so glass shows through.
        let opaqueWeb = AgentBridge.opaqueWebView
        webView.isOpaque = opaqueWeb
        let webBg: UIColor = opaqueWeb ? .systemBackground : .clear
        webView.backgroundColor = webBg
        webView.scrollView.backgroundColor = webBg
        // Under-page layer, FILE-VIEWER WEB VIEW ONLY. nil defaults to white for
        // not-yet-loaded content, visible as a white edge flash while the panel
        // slides in mid-load. Must NOT be set on the main chat web views: doing it
        // globally promotes them to eager opaque compositing over the glass/panel
        // stack and enlarges the flash (0d1f440bb, reverted in abb7dd403). The
        // file viewer always passes an explicit .dark/.light theme.
        if configuration.fileViewerPath != nil {
            switch configuration.theme {
            case .dark:
                webView.underPageBackgroundColor = .black
            case .light:
                webView.underPageBackgroundColor = .white
            case .system:
                webView.underPageBackgroundColor = .systemBackground
            }
        }
        // Prevent the scroll view from adding automatic content insets for
        // safe areas.  The embedding SwiftUI view already controls the frame
        // placement, so the web content should fill the provided frame exactly.
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        // Prevent document-level bounce/overscroll while keeping touch
        // events enabled (isScrollEnabled must stay true or WKWebView stops
        // forwarding pan gestures to CSS overflow containers).
        webView.scrollView.bounces = false
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.attachWebView(webView)

        #if DEBUG
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
        #endif

        bridge.attach(to: webView)

        // Load the URL with the full site key config in the hash.
        // AgentView validates the site key natively before creating this
        // view, so the config (including theme) is available synchronously
        // on the web side — matching the browser EmbedManager flow.
        //
        // _cb makes the HTML URL unique per launch so WKWebView always fetches
        // the latest HTML (which references the current content-hashed bundle
        // URLs). JS bundles are cached by their content-hashed URL and only
        // re-downloaded when they change. Do NOT set .reloadIgnoringLocalAndRemoteCacheData
        // here — that forces a full JS bundle re-download + recompile on every
        // launch, causing sustained CPU and thermal spikes on mobile.
        var urlComponents = URLComponents(url: configuration.embeddedURL, resolvingAgainstBaseURL: false)!
        var queryItems = urlComponents.queryItems ?? []
        queryItems.append(URLQueryItem(name: "_cb", value: String(Int(Date().timeIntervalSince1970))))
        urlComponents.queryItems = queryItems
        let url = urlComponents.url!
        NSLog("[AgentWebView] Loading URL: %@", url.absoluteString)
        webView.load(URLRequest(url: url))

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // FullBleedWebView zeroes bottom safe area so web content fills the frame.
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: AgentWebView.Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "agentBridge")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "agentLog")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "agentNetwork")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "curtainLowered")
        webView.configuration.userContentController.removeAllUserScripts()
    }
}

// MARK: - Coordinator (iOS)

extension AgentWebView {
    public final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        let bridge: AgentBridge
        let baseHost: String?
        private weak var observedWebView: WKWebView?

        init(bridge: AgentBridge, baseHost: String?) {
            self.bridge = bridge
            self.baseHost = baseHost
            super.init()
            // iOS re-adds input assistant bar button groups each time the
            // keyboard appears, so we must clear them on every show.
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(keyboardWillShow),
                name: UIResponder.keyboardWillShowNotification,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(keyboardWillHide),
                name: UIResponder.keyboardWillHideNotification,
                object: nil
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func attachWebView(_ webView: WKWebView) {
            observedWebView = webView
        }

        /// Returns true when the URL points to a different host than the app's base URL
        /// and should be opened externally (in Safari).
        private func isExternalURL(_ url: URL) -> Bool {
            guard let scheme = url.scheme, ["http", "https"].contains(scheme) else { return false }
            guard let host = url.host else { return false }
            guard let baseHost else { return false }
            return host != baseHost
        }

        /// JS snippet that freezes the Virtuoso scroller's scrollTop for a
        /// duration, preventing any keyboard-triggered web scroll from firing.
        private static let scrollLockJS = """
            (function() {
                var s = document.querySelector('[data-virtuoso-scroller]');
                if (!s) return;
                var saved = s.scrollTop;
                // Remove any previous lock first
                if (s.__kbScrollLock) s.removeEventListener('scroll', s.__kbScrollLock);
                var handler = function() { s.scrollTop = saved; };
                s.__kbScrollLock = handler;
                s.addEventListener('scroll', handler);
                clearTimeout(window.__kbScrollLockTimer);
                window.__kbScrollLockTimer = setTimeout(function() {
                    s.removeEventListener('scroll', handler);
                    delete s.__kbScrollLock;
                }, 1500);
            })();
            """

        @objc private func keyboardWillShow() {
            guard let webView = observedWebView else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                Self.removeInputAccessoryView(from: webView)
            }
            // Tell the web app to suppress smooth-scroll during the keyboard
            // transition — the native .offset() handles avoidance.
            webView.evaluateJavaScript("window.__ripulKeyboardTransitioning = true")
            webView.evaluateJavaScript(Self.scrollLockJS)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                webView.evaluateJavaScript("window.__ripulKeyboardTransitioning = false")
            }
            // WKWebView's UIScrollView auto-scrolls to reveal focused web inputs,
            // but miscalculates the position when the input is inside a CSS-
            // transformed container (e.g. the metadata swipe panel). The viewport
            // meta tag declares interactive-widget=overlays-content so the web app
            // handles keyboard avoidance itself — reset the scroll view to prevent
            // the native scroll-to-reveal from pushing content offscreen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                webView.scrollView.contentOffset = .zero
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                webView.scrollView.contentOffset = .zero
            }
        }

        @objc private func keyboardWillHide() {
            // No scroll lock on hide — let auto-follow work naturally so new
            // content (user message) scrolls into view during the native
            // .offset() animation instead of snapping after a 1.5s freeze.
            guard let webView = observedWebView else { return }
            // Reset any residual scroll view offset from the keyboard show.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if webView.scrollView.contentOffset != .zero {
                    webView.scrollView.contentOffset = .zero
                }
            }
        }

        public func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            Task { @MainActor in
                if message.name == "agentLog" {
                    bridge.handleConsoleLog(message.body as? String ?? "")
                } else if message.name == "agentNetwork" {
                    bridge.handleNetworkLog(message.body)
                } else if message.name == "curtainLowered" {
                    bridge.lowerWindowCurtain()
                } else {
                    bridge.handleMessage(message.body)
                }
            }
        }

        public func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            if let url = navigationAction.request.url {
                NSLog("[AgentWebView] Navigation: %@", url.absoluteString)
                if navigationAction.navigationType == .linkActivated && isExternalURL(url) {
                    NSLog("[AgentWebView] Opening external URL in Safari: %@", url.absoluteString)
                    await UIApplication.shared.open(url)
                    return .cancel
                }
            }
            return .allow
        }

        /// Handle window.open / target="_blank" — open external URLs in Safari.
        public func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url {
                NSLog("[AgentWebView] Popup request: %@", url.absoluteString)
                if isExternalURL(url) {
                    NSLog("[AgentWebView] Opening external popup URL in Safari: %@", url.absoluteString)
                    UIApplication.shared.open(url)
                } else {
                    webView.load(navigationAction.request)
                }
            }
            return nil
        }

        /// Fires when the web view commits a navigation (content starts rendering).
        /// Detects external navigations (OAuth redirects to Google, etc.) and switches
        /// to minimal page context so the native glass header doesn't occlude the
        /// third-party UI. When the web view returns to the app domain, didFinish
        /// fires and the web app re-sends its own page:context message.
        public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            guard let url = webView.url else { return }
            if isExternalURL(url) {
                NSLog("[AgentWebView] External navigation committed — hiding native chrome for: %@", url.host ?? "unknown")
                Task { @MainActor in
                    bridge.currentPageContext = .externalNavigation
                }
            }
        }

        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Self.removeInputAccessoryView(from: webView)
            Self.injectSafeAreaInset(into: webView)
            Self.lockTabsHeight(in: webView)
            Task { @MainActor in
                bridge.pageDidFinishLoading()
                bridge.didFinishFirstNavigation = true
            }
        }

        /// Pin the #tabs container to the WKWebView frame height so that
        /// keyboard-driven visual viewport changes can't resize it (and
        /// therefore can't trigger Virtuoso's internal scroll adjustment).
        private static func lockTabsHeight(in webView: WKWebView) {
            let height = Int(webView.frame.height)
            let js = """
                var t = document.getElementById('tabs');
                if (t) t.style.height = '\(height)px';
            """
            webView.evaluateJavaScript(js) { _, error in
                if let error {
                    NSLog("[AgentWebView] Failed to lock #tabs height: %@", error.localizedDescription)
                } else {
                    NSLog("[AgentWebView] Locked #tabs height to %dpx", height)
                }
            }
        }

        private static func injectSafeAreaInset(into webView: WKWebView) {
            let insetTop: CGFloat
            if let windowScene = webView.window?.windowScene {
                insetTop = windowScene.keyWindow?.safeAreaInsets.top ?? 54
            } else {
                insetTop = 54
            }
            let totalHeight = Int(insetTop) + 44
            let js = "document.documentElement.style.setProperty('--native-header-height', '\(totalHeight)px')"
            webView.evaluateJavaScript(js) { _, error in
                if let error {
                    NSLog("[AgentWebView] Failed to inject safe area inset: %@", error.localizedDescription)
                } else {
                    NSLog("[AgentWebView] Injected --native-header-height: %dpx (safe area: %d + bar: 44)", totalHeight, Int(insetTop))
                }
            }
        }

        static func removeInputAccessoryView(from webView: WKWebView) {
            guard let contentView = webView.scrollView.subviews.first(where: {
                String(describing: type(of: $0)).hasPrefix("WKContent")
            }) else { return }

            let subclassName = "NoAccessory_WKContentView"
            var subclass: AnyClass? = objc_getClass(subclassName) as? AnyClass

            if subclass == nil {
                guard let baseClass: AnyClass = object_getClass(contentView) else { return }
                subclass = objc_allocateClassPair(baseClass, subclassName, 0)
                guard let subclass = subclass else { return }

                let selector = #selector(getter: UIResponder.inputAccessoryView)
                guard let method = class_getInstanceMethod(UIView.self, selector) else { return }
                let nilIMP = imp_implementationWithBlock({ (_: AnyObject) -> AnyObject? in nil }
                    as @convention(block) (AnyObject) -> AnyObject?)
                class_addMethod(subclass, selector, nilIMP, method_getTypeEncoding(method))
                objc_registerClassPair(subclass)
            }

            object_setClass(contentView, subclass!)
        }

        public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            NSLog("[AgentWebView] Navigation failed: %@", error.localizedDescription)
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
            Task { @MainActor in
                bridge.loadError = userFacingErrorMessage(nsError)
                bridge.loadErrorDetails = error.localizedDescription
            }
        }

        public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            NSLog("[AgentWebView] Provisional navigation failed: %@", error.localizedDescription)
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
            Task { @MainActor in
                bridge.loadError = userFacingErrorMessage(nsError)
                bridge.loadErrorDetails = error.localizedDescription
            }
        }

        /// Called when the WKWebView's web content process crashes or is terminated by the OS.
        /// The web view shows a blank white page after this — record the crash and reload.
        public func webView(_ webView: WKWebView, webContentProcessDidTerminate: WKWebView) {
            Task { @MainActor in
                bridge.recordProcessTermination()
            }
        }

        // MARK: - JavaScript Dialog Helpers

        /// Find the topmost VC that can present a UIAlertController.
        /// Uses the responder chain first (most reliable in SwiftUI hosts),
        /// then falls back to window-scene strategies.
        private func topPresentableVC(for webView: WKWebView) -> UIViewController? {
            // Strategy 1: Walk the responder chain from the webView itself.
            // This always works when the webView is in the view hierarchy,
            // regardless of SwiftUI's internal VC nesting.
            var responder: UIResponder? = webView.next
            while let r = responder {
                if let vc = r as? UIViewController {
                    // Walk to topmost presented VC
                    var top = vc
                    while let presented = top.presentedViewController {
                        top = presented
                    }
                    return top
                }
                responder = r.next
            }

            // Strategy 2: Window scene fallback
            let scene = webView.window?.windowScene
                ?? UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .first { $0.activationState == .foregroundActive }
            guard let windowScene = scene else {
                bridge.handleConsoleLog("[AgentWebView] JS dialog: no window scene found")
                return nil
            }

            let rootVC = windowScene.keyWindow?.rootViewController
                ?? windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController
                ?? windowScene.windows.first?.rootViewController
            guard var vc = rootVC else {
                bridge.handleConsoleLog("[AgentWebView] JS dialog: no rootViewController found")
                return nil
            }

            while let presented = vc.presentedViewController {
                vc = presented
            }
            return vc
        }

        // MARK: - JavaScript Dialog Handlers (WKUIDelegate)

        // OAuth providers (Google, GitHub) may present JavaScript alerts, confirms, or
        // prompts during the sign-in flow. WKWebView suppresses these by default unless
        // the delegate implements the corresponding methods, causing the flow to hang.

        public func webView(
            _ webView: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping () -> Void
        ) {
            guard let vc = topPresentableVC(for: webView) else {
                completionHandler()
                return
            }
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
            vc.present(alert, animated: true)
        }

        public func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (Bool) -> Void
        ) {
            guard let vc = topPresentableVC(for: webView) else {
                completionHandler(false)
                return
            }
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
            vc.present(alert, animated: true)
        }

        public func webView(
            _ webView: WKWebView,
            runJavaScriptTextInputPanelWithPrompt prompt: String,
            defaultText: String?,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (String?) -> Void
        ) {
            guard let vc = topPresentableVC(for: webView) else {
                completionHandler(nil)
                return
            }
            let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
            alert.addTextField { $0.text = defaultText }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
                completionHandler(alert.textFields?.first?.text)
            })
            vc.present(alert, animated: true)
        }
    }
}

#endif // os(iOS)

// MARK: - Shared Bridge JavaScript & Font CSS (cross-platform)

extension AgentWebView {
    /// Exposes the stable per-install identity to the web layer before any page
    /// JS runs. The web relay client uses it as its clientId suffix so an
    /// install-over reconnects as the SAME relay client (see InstallationIdentity).
    public static let installationIdentityScript = WKUserScript(
        source: "window.__ripulInstallationId = \"\(InstallationIdentity.clientIdSegment)\";",
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true
    )

    /// Exposes the native mirror of host-mode prefs (hostEnabled / machineName)
    /// and the long-lived machine token so the web layer can keep host comms
    /// alive when the Clerk session is unavailable. Values are refreshed into
    /// the live page on pageDidFinish and after every `host-prefs:set` write.
    public static func hostPreferencesScript() -> WKUserScript {
        let token = MachineTokenStore.token
        let tokenLiteral: String
        if let token {
            let escaped = token
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            tokenLiteral = "\"\(escaped)\""
        } else {
            tokenLiteral = "null"
        }
        return WKUserScript(
            source: "window.__ripulHostPrefs = \(HostPreferences.injectionJSON); window.__ripulHostToken = \(tokenLiteral);",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
    }

    public static let bridgeJavaScript = """
    (function() {
        // Clear stale host-render-suspended flag before any web JS runs.
        // If a previous crash left ripul:host-render-suspended='1' in localStorage
        // the web app would start with its content tree unmounted, causing a
        // ResizeObserver loop that crashes WKWebView before onAppear can correct it.
        try { localStorage.removeItem('ripul:host-render-suspended'); } catch(e) {}

        // Capture uncaught JS exceptions and unhandled promise rejections and
        // forward them to the native log BEFORE any web JS runs. This is the
        // diagnostic for "web view goes blank / self-heal reloads in a loop"
        // crashes that do NOT trigger webViewWebContentProcessDidTerminate
        // (i.e. not jetsam — the process is alive but the JS context is dead).
        window.addEventListener('error', function(evt) {
            var msg = 'UNCAUGHT_ERROR: ' + (evt.message || '?')
                + ' | file: ' + (evt.filename || '?')
                + ':' + (evt.lineno || '?')
                + (evt.error && evt.error.stack ? ' | stack: ' + evt.error.stack.slice(0, 400) : '');
            try { window.webkit.messageHandlers.agentLog.postMessage(msg); } catch(e) {}
        });
        window.addEventListener('unhandledrejection', function(evt) {
            var reason = evt.reason;
            var msg = 'UNHANDLED_REJECTION: '
                + (reason instanceof Error
                    ? reason.message + (reason.stack ? ' | stack: ' + reason.stack.slice(0, 400) : '')
                    : String(reason));
            try { window.webkit.messageHandlers.agentLog.postMessage(msg); } catch(e) {}
        });

        // Intercept console.log/warn/error and forward every call to the native
        // agentLog message handler (→ AgentBridge.handleConsoleLog → consoleLogs buffer).
        // origLog/Warn/Error are also called so the web inspector still receives them.
        //
        // This means ALL console.* output from the web view is captured natively, making
        // device_console_logs a unified view of both Swift logs (sent via
        // handleConsoleLog directly) and web-view logs (sent via this interception).
        //
        // Note: web code that calls window.webkit.messageHandlers.agentLog.postMessage()
        // directly (e.g. nativeLog() in RemotePairingsContext.tsx) AND also calls
        // console.log() will produce two entries in the native buffer — one from the direct
        // postMessage and one from this override. That duplication is intentional: it keeps
        // the log visible regardless of whether ConsoleWrapper has suppressed console output.
        const origLog = console.log;
        const origWarn = console.warn;
        const origError = console.error;
        const origInfo = console.info;
        const origDebug = console.debug;

        // Serialize one console arg. Errors are typeof 'object' but their
        // name/message/stack are non-enumerable, so a naïve JSON.stringify
        // returns '{}' and the host log loses all useful detail. Render Error
        // (and Error-likes that expose `name`+`message`) inline as
        // "Name: message\\nstack", and use a JSON.stringify replacer to do
        // the same for errors nested inside plain objects (the common
        // `console.error('foo:', { err })` shape).
        function isErrorLike(a) {
            if (!a || typeof a !== 'object') return false;
            if (a instanceof Error) return true;
            return typeof a.message === 'string' && typeof a.name === 'string';
        }
        function renderError(a) {
            var name = a.name || 'Error';
            var message = a.message || String(a);
            var stack = a.stack ? '\\n' + a.stack : '';
            return name + ': ' + message + stack;
        }
        function errorReplacer(_key, value) {
            if (isErrorLike(value)) {
                var out = { name: value.name, message: value.message };
                if (value.stack) out.stack = value.stack;
                if (value.code !== undefined) out.code = value.code;
                if (value.cause !== undefined) {
                    try { out.cause = isErrorLike(value.cause) ? errorReplacer('cause', value.cause) : value.cause; } catch(_) {}
                }
                return out;
            }
            return value;
        }
        function serializeArg(a) {
            if (a === undefined) return 'undefined';
            if (a === null) return 'null';
            if (typeof a !== 'object') return String(a);
            if (isErrorLike(a)) return renderError(a);
            try {
                return JSON.stringify(a, errorReplacer);
            } catch (_) {
                return String(a);
            }
        }

        function nativeLog(level, args, stack) {
            try {
                const msg = Array.from(args).map(serializeArg).join(' ');
                var payload = level + ': ' + msg;
                if (stack) {
                    payload += '\\n__STACK__\\n' + stack;
                }
                window.webkit.messageHandlers.agentLog.postMessage(payload);
            } catch(e) {}
        }

        function captureStack() {
            try {
                var s = new Error().stack || '';
                // Filter out our own internal frames — works across engines
                // (Safari omits the "Error" line that Chrome/Firefox include)
                return s.split('\\n').filter(function(l) {
                    return l && l.indexOf('captureStack') === -1 && l.indexOf('nativeLog') === -1;
                }).join('\\n');
            } catch(e) { return ''; }
        }

        // Master gate. When window.__ripulNativeLog is false (the on-device
        // default), NO console.* output crosses the bridge: no serialize, no IPC,
        // no native handleConsoleLog. The web app logs heavily on streaming hot
        // paths and each teed line was cross-process + native-parse work the PWA
        // never pays, so this is the default so streaming stays cool. Native flips
        // it on via the "Native Console Logging" toggle (pushed in
        // pageDidFinishLoading + on toggle change). origX.apply always runs, so the
        // browser console / Web Inspector still show everything. Uncaught errors
        // (window.onerror / unhandledrejection below) call nativeLog directly and
        // bypass this gate, so crash diagnostics survive with logging off.
        if (typeof window.__ripulNativeLog === 'undefined') window.__ripulNativeLog = false;
        console.log = function() { if (window.__ripulNativeLog) nativeLog('LOG', arguments); origLog.apply(console, arguments); };
        console.warn = function() { if (window.__ripulNativeLog) nativeLog('WARN', arguments, captureStack()); origWarn.apply(console, arguments); };
        console.error = function() { if (window.__ripulNativeLog) nativeLog('ERROR', arguments, captureStack()); origError.apply(console, arguments); };
        // console.info/debug were previously NOT captured — web code using them
        // appeared in DevTools but never in the native console buffer, which made
        // legit diagnostics look "missing". Capture them too (as LOG).
        console.info = function() { if (window.__ripulNativeLog) nativeLog('LOG', arguments); origInfo.apply(console, arguments); };
        console.debug = function() { if (window.__ripulNativeLog) nativeLog('LOG', arguments); origDebug.apply(console, arguments); };

        window.addEventListener('error', function(e) {
            var detail = 'Uncaught: ' + e.message + ' at ' + e.filename + ':' + e.lineno;
            if (e.error && e.error.stack) detail += '\\n' + e.error.stack;
            nativeLog('ERROR', [detail]);
        });

        window.addEventListener('unhandledrejection', function(e) {
            var reason = e.reason;
            var msg = 'Unhandled rejection: ';
            if (reason instanceof Error) {
                msg += reason.message;
                if (reason.stack) msg += '\\n' + reason.stack;
            } else {
                try { msg += JSON.stringify(reason); } catch(_) { msg += String(reason); }
            }
            nativeLog('ERROR', [msg]);
        });

        // Only override window.parent / window.top on the app's own pages.
        // Third-party pages (Google OAuth, etc.) check top === self as an
        // anti-phishing measure — our overrides would break their sign-in flow.
        //
        // IMPORTANT: Defer overrides until after window.load so they don't
        // interfere with ES module loading. WebKit's module loader checks
        // browsing context properties (window.parent/top) and if parent !== window
        // it may apply cross-origin iframe restrictions that block modules.
        var hash = window.location.hash || '';
        var isAppPage = hash.includes('embedded=true') || hash.includes('native=true') || hash.includes('siteKey=');

        function applyParentTopOverrides() {
            var parentOverridden = false;
            var topOverridden = false;

            // Create a parent proxy that is !== window
            // with postMessage routing to native
            const parentProxy = Object.create(window);
            parentProxy.postMessage = function(message, targetOrigin) {
                window.webkit.messageHandlers.agentBridge.postMessage(message);
            };

            // Override window.parent — WKWebView has this as a non-configurable
            // property, so we need to try multiple strategies

            // Strategy 1: Define on window instance (works if prototype allows it)
            try {
                Object.defineProperty(window, 'parent', {
                    get: function() { return parentProxy; },
                    configurable: true
                });
                if (window.parent !== window) parentOverridden = true;
            } catch(e) {}

            // Strategy 2: Redefine on Window.prototype
            if (!parentOverridden) {
                try {
                    Object.defineProperty(Window.prototype, 'parent', {
                        get: function() { return parentProxy; },
                        configurable: true
                    });
                    if (window.parent !== window) parentOverridden = true;
                } catch(e) {}
            }

            // Strategy 3: Delete prototype property and set own property
            if (!parentOverridden) {
                try {
                    delete Window.prototype.parent;
                    Object.defineProperty(window, 'parent', {
                        get: function() { return parentProxy; },
                        configurable: true
                    });
                    if (window.parent !== window) parentOverridden = true;
                } catch(e) {}
            }

            // Override window.top so iframe detection (window.self !== window.top) works
            try {
                Object.defineProperty(window, 'top', {
                    get: function() { return parentProxy; },
                    configurable: true
                });
                if (window.self !== window.top) topOverridden = true;
            } catch(e) {}

            if (!topOverridden) {
                try {
                    Object.defineProperty(Window.prototype, 'top', {
                        get: function() { return parentProxy; },
                        configurable: true
                    });
                    if (window.self !== window.top) topOverridden = true;
                } catch(e) {}
            }

            if (!topOverridden) {
                try {
                    delete Window.prototype.top;
                    Object.defineProperty(window, 'top', {
                        get: function() { return parentProxy; },
                        configurable: true
                    });
                    if (window.self !== window.top) topOverridden = true;
                } catch(e) {}
            }

        }

        if (isAppPage) {
            // Defer until after modules have loaded to avoid breaking ES module loader
            window.addEventListener('load', function() {
                applyParentTopOverrides();
            });
        }


        // ── Error monitoring ──

        // Capture module-level errors with detail
        window.addEventListener('error', function(e) {
            if (e.target && e.target.tagName === 'SCRIPT') {
                nativeLog('ERROR', ['[NativeBridge:diag] Script load FAILED — src: ' + (e.target.src || '(inline)') + ', type: ' + (e.target.type || 'classic')]);
            }
        }, true); // capture phase to catch resource errors

        // Network request capture — controlled by native toggle (off by default).
        // When enabled, every fetch() call is logged to the agentNetwork message handler
        // with method, URL, status, duration, and approximate sizes.
        var __netCaptureEnabled = false;
        window.__ripulNetworkCapture = function(enabled) { __netCaptureEnabled = !!enabled; };
        var origFetch = window.fetch;
        function collectHeaders(h) {
            var obj = {};
            try { h.forEach(function(v, k) { obj[k] = v; }); } catch(e) {}
            return obj;
        }
        window.fetch = function() {
            var url = typeof arguments[0] === 'string' ? arguments[0] : (arguments[0] && arguments[0].url ? arguments[0].url : String(arguments[0]));
            var opts = arguments[1] || {};
            var method = (opts.method || 'GET').toUpperCase();
            var reqSize = opts.body ? (typeof opts.body === 'string' ? opts.body.length : -1) : 0;
            var reqHeaders = {};
            try {
                if (opts.headers) {
                    if (opts.headers instanceof Headers) { opts.headers.forEach(function(v,k){ reqHeaders[k]=v; }); }
                    else if (typeof opts.headers === 'object') { reqHeaders = Object.assign({}, opts.headers); }
                }
            } catch(e) {}
            var t0 = Date.now();

            // Always log resource load failures (original behavior)
            var p = origFetch.apply(this, arguments);
            if (!__netCaptureEnabled) {
                return p.then(function(r) {
                    if (typeof url === 'string' && (url.endsWith('.js') || url.endsWith('.css')) && !r.ok) {
                        nativeLog('ERROR', ['[NativeBridge:diag] fetch FAILED: ' + url + ' status=' + r.status]);
                    }
                    return r;
                });
            }

            return p.then(function(r) {
                var duration = Date.now() - t0;
                var resSize = -1;
                var cl = r.headers.get('content-length');
                if (cl) resSize = parseInt(cl, 10);
                try {
                    window.webkit.messageHandlers.agentNetwork.postMessage({
                        method: method, url: url, status: r.status, statusText: r.statusText,
                        duration: duration, reqSize: reqSize, resSize: resSize,
                        reqHeaders: reqHeaders, resHeaders: collectHeaders(r.headers)
                    });
                } catch(e) {}
                if (typeof url === 'string' && (url.endsWith('.js') || url.endsWith('.css')) && !r.ok) {
                    nativeLog('ERROR', ['[NativeBridge:diag] fetch FAILED: ' + url + ' status=' + r.status]);
                }
                return r;
            }).catch(function(err) {
                var duration = Date.now() - t0;
                try {
                    window.webkit.messageHandlers.agentNetwork.postMessage({
                        method: method, url: url, status: 0, statusText: '',
                        duration: duration, reqSize: reqSize, resSize: -1,
                        reqHeaders: reqHeaders, resHeaders: {},
                        error: err.message || String(err)
                    });
                } catch(e) {}
                throw err;
            });
        };

        // Native → Web: dispatch as MessageEvent on window
        window.__agentBridgeReceive = function(message) {
            window.dispatchEvent(new MessageEvent('message', {
                data: message,
                origin: 'ripul-native://app'
            }));
        };

        // Disable iOS autofill suggestions bar (passwords, contacts, etc.)
        // without affecting keyboard autocorrect.
        // iOS ignores autocomplete="off", so we use multiple strategies:
        // 1. Set autocomplete to a value iOS doesn't map to a content type
        // 2. Remove name/id patterns that trigger autofill heuristics
        // 3. Mark as non-form with role and aria attributes
        function disableAutofill(el) {
            el.setAttribute('autocomplete', 'off');
            el.setAttribute('autocorrect', 'on');
            el.setAttribute('autocapitalize', 'sentences');
            el.setAttribute('spellcheck', 'true');
            el.setAttribute('role', 'textbox');
            el.setAttribute('aria-autocomplete', 'none');
            el.setAttribute('data-form-type', 'other');
            el.setAttribute('data-lpignore', 'true');
            el.setAttribute('data-1p-ignore', 'true');
        }
        // Apply to any existing and future input/textarea elements.
        // Uses both DOMContentLoaded + polling to handle React re-renders.
        function scanAndPatch() {
            document.querySelectorAll('input, textarea').forEach(disableAutofill);
        }
        document.addEventListener('DOMContentLoaded', function() {
            scanAndPatch();
            new MutationObserver(function() { scanAndPatch(); })
                .observe(document.body, { childList: true, subtree: true });
        });

        // Set a default header height. The native side will override this
        // with the actual safe area inset (in pixels) once the view is laid out.
        document.documentElement.style.setProperty('--native-header-height', '98px');

        // Ensure viewport-fit=cover so web content extends into safe areas.
        var existingVP = document.querySelector('meta[name="viewport"]');
        if (existingVP) {
            var c = existingVP.getAttribute('content') || '';
            if (c.indexOf('viewport-fit') === -1) {
                existingVP.setAttribute('content', c + ', viewport-fit=cover');
            }
        } else {
            var vpMeta = document.createElement('meta');
            vpMeta.name = 'viewport';
            vpMeta.content = 'width=device-width, initial-scale=1.0, maximum-scale=1.0, viewport-fit=cover';
            document.head.appendChild(vpMeta);
        }

        // Prevent document-level scrolling so only inner CSS overflow
        // containers scroll. This eliminates the dual-scroll problem where
        // both WKWebView's native scrollView and the web app's containers
        // compete for touch gestures.
        var lockStyle = document.createElement('style');
        lockStyle.textContent = 'html, body { height: 100vh !important; overflow: hidden; }';
        (document.head || document.documentElement).appendChild(lockStyle);

    })();
    """

    // MARK: - Font CSS Builder

    /// Scans `bundle` for font files whose names start with any of `families`,
    /// infers CSS weight and style from the filename suffix, and returns
    /// `@font-face` declarations that base64-embed each file.
    static func buildFontCSS(families: [String], bundle: Bundle) -> String {
        // Tuples ordered longest-suffix-first so specific names match before
        // shorter ones (e.g. "BoldItalic" before "Bold" before "Italic").
        let weightMap: [(suffix: String, weight: Int, italic: Bool)] = [
            ("UltraLightItalic", 200, true),  ("UltraLight-Italic", 200, true),
            ("UltraLight",       200, false),
            ("ThinItalic",       100, true),  ("Thin-Italic",       100, true),
            ("Thin",             100, false),
            ("LightItalic",      300, true),  ("Light-Italic",      300, true),
            ("Light",            300, false),
            ("MediumItalic",     500, true),  ("Medium-Italic",     500, true),
            ("Medium",           500, false),
            ("DemiBoldItalic",   600, true),  ("DemiBold-Italic",   600, true),
            ("DemiBold",         600, false),
            ("SemiBoldItalic",   600, true),  ("SemiBold-Italic",   600, true),
            ("SemiBold",         600, false),
            ("BoldItalic",       700, true),  ("Bold-Italic",       700, true),
            ("Bold",             700, false),
            ("HeavyItalic",      800, true),  ("Heavy-Italic",      800, true),
            ("Heavy",            800, false),
            ("ExtraBoldItalic",  800, true),  ("ExtraBold-Italic",  800, true),
            ("ExtraBold",        800, false),
            ("BlackItalic",      900, true),  ("Black-Italic",      900, true),
            ("Black",            900, false),
            ("Italic",           400, true),
            ("Regular",          400, false),
            ("",                 400, false),  // bare family name with no suffix
        ]

        var declarations: [String] = []

        for family in families {
            for ext in ["ttf", "otf"] {
                guard let urls = bundle.urls(forResourcesWithExtension: ext, subdirectory: nil) else { continue }
                for url in urls {
                    let stem = url.deletingPathExtension().lastPathComponent
                    guard stem.hasPrefix(family) else { continue }

                    // Strip family prefix and any leading hyphen separator
                    var suffix = String(stem.dropFirst(family.count))
                    if suffix.hasPrefix("-") { suffix = String(suffix.dropFirst()) }

                    guard let entry = weightMap.first(where: { $0.suffix == suffix }) else { continue }
                    guard let data = try? Data(contentsOf: url) else { continue }

                    let b64    = data.base64EncodedString()
                    let mime   = ext == "otf" ? "font/opentype"  : "font/truetype"
                    let format = ext == "otf" ? "opentype"       : "truetype"

                    declarations.append("""
                    @font-face {
                        font-family: '\(family)';
                        font-weight: \(entry.weight);
                        font-style: \(entry.italic ? "italic" : "normal");
                        src: url('data:\(mime);base64,\(b64)') format('\(format)');
                    }
                    """)
                }
            }
        }

        return declarations.joined(separator: "\n")
    }
}
