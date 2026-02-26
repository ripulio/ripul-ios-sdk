import SwiftUI
import WebKit
import ObjectiveC

@available(iOS 15.0, *)
@MainActor
public struct AgentWebView: UIViewRepresentable {
    public let configuration: AgentConfiguration
    public let bridge: AgentBridge

    public init(configuration: AgentConfiguration, bridge: AgentBridge) {
        self.configuration = configuration
        self.bridge = bridge
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(bridge: bridge)
    }

    public func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()

        // Inject the bridge script before any page JS runs
        let bridgeScript = WKUserScript(
            source: Self.bridgeJavaScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(bridgeScript)

        config.userContentController.add(context.coordinator, name: "agentBridge")
        config.userContentController.add(context.coordinator, name: "agentLog")

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

        // Allow inline media playback
        config.allowsInlineMediaPlayback = true

        // Append Safari-like tokens to the user agent so OAuth providers
        // (Google, etc.) don't reject sign-in with "disallowed_useragent".
        // WKWebView's default UA omits "Safari/..." which triggers the block.
        // RipulNative lets the web app detect native mode via navigator.userAgent.
        config.applicationNameForUserAgent = "RipulNative/1.0 Mobile/15E148 Safari/605.1.15"

        // In embedded/site-key mode, clear all cached web content on each
        // launch to avoid stale assets causing black screens or broken UI.
        // In native app mode, preserve cookies and localStorage so the
        // Clerk auth session survives app relaunches.
        let dataStore = WKWebsiteDataStore.default()
        if !configuration.nativeApp {
            let allTypes = WKWebsiteDataStore.allWebsiteDataTypes()
            dataStore.removeData(ofTypes: allTypes, modifiedSince: .distantPast) { }
        }
        config.websiteDataStore = dataStore

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        // Prevent the scroll view from adding automatic content insets for
        // safe areas.  The embedding SwiftUI view already controls the frame
        // placement, so the web content should fill the provided frame exactly.
        webView.scrollView.contentInsetAdjustmentBehavior = .never
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
        let url = configuration.embeddedURL
        NSLog("[AgentWebView] Loading URL: %@", url.absoluteString)
        webView.load(URLRequest(url: url))

        return webView
    }

    public func updateUIView(_ webView: WKWebView, context: Context) {}

    public static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "agentBridge")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "agentLog")
        webView.configuration.userContentController.removeAllUserScripts()
    }

    // MARK: - Bridge JavaScript

    private static let bridgeJavaScript = """
    (function() {
        // Capture console.log/warn/error and forward to native
        const origLog = console.log;
        const origWarn = console.warn;
        const origError = console.error;

        function nativeLog(level, args) {
            try {
                const msg = Array.from(args).map(a => {
                    if (typeof a === 'object') {
                        try { return JSON.stringify(a); } catch { return String(a); }
                    }
                    return String(a);
                }).join(' ');
                window.webkit.messageHandlers.agentLog.postMessage(level + ': ' + msg);
            } catch(e) {}
        }

        console.log = function() { nativeLog('LOG', arguments); origLog.apply(console, arguments); };
        console.warn = function() { nativeLog('WARN', arguments); origWarn.apply(console, arguments); };
        console.error = function() { nativeLog('ERROR', arguments); origError.apply(console, arguments); };

        window.addEventListener('error', function(e) {
            nativeLog('ERROR', ['Uncaught: ' + e.message + ' at ' + e.filename + ':' + e.lineno]);
        });

        // Only override window.parent / window.top on the app's own pages.
        // Third-party pages (Google OAuth, etc.) check top === self as an
        // anti-phishing measure — our overrides would break their sign-in flow.
        var hash = window.location.hash || '';
        var isAppPage = hash.includes('embedded=true') || hash.includes('native=true') || hash.includes('siteKey=');

        var parentOverridden = false;
        var topOverridden = false;

        if (isAppPage) {
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

        nativeLog('LOG', ['[NativeBridge] isAppPage: ' + isAppPage + ', parent override: ' + (parentOverridden ? 'SUCCESS' : 'SKIPPED') + ', top override: ' + (topOverridden ? 'SUCCESS' : 'SKIPPED')]);

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

        // Expose native header height so the web app can pad its content
        document.documentElement.style.setProperty('--native-header-height', '44px');

        nativeLog('LOG', ['[NativeBridge] Bridge script initialized']);
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

    // MARK: - Coordinator

    public final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        let bridge: AgentBridge
        private weak var observedWebView: WKWebView?

        init(bridge: AgentBridge) {
            self.bridge = bridge
            super.init()
            // iOS re-adds input assistant bar button groups each time the
            // keyboard appears, so we must clear them on every show.
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(keyboardWillShow),
                name: UIResponder.keyboardWillShowNotification,
                object: nil
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func attachWebView(_ webView: WKWebView) {
            observedWebView = webView
        }

        @objc private func keyboardWillShow() {
            guard let webView = observedWebView else { return }
            // Small delay so WKContentView is first responder before we clear
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                Self.removeInputAccessoryView(from: webView)
            }
        }

        public func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            Task { @MainActor in
                if message.name == "agentLog" {
                    bridge.handleConsoleLog(message.body as? String ?? "")
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
            }
            return .allow
        }

        // MARK: - WKUIDelegate

        /// Handle window.open / target="_blank" by loading in the same web view.
        /// OAuth flows (Google, GitHub, etc.) often open a popup; without this
        /// the navigation is silently dropped.
        public func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url {
                NSLog("[AgentWebView] Popup request: %@", url.absoluteString)
                webView.load(navigationAction.request)
            }
            return nil // Don't create a new web view; load in the existing one
        }

        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            NSLog("[AgentWebView] Page finished loading: %@", webView.url?.absoluteString ?? "nil")
            Self.removeInputAccessoryView(from: webView)
        }

        /// Remove the form-filling input accessory view (< > arrows + Done bar)
        /// by creating a runtime subclass of WKContentView that overrides
        /// `inputAccessoryView` to return nil. This is the same technique used
        /// in ripul-browser's RipulAgentSheetViewController.
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
        }

        public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            NSLog("[AgentWebView] Provisional navigation failed: %@", error.localizedDescription)
        }
    }
}
