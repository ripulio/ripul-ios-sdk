import SwiftUI
import WebKit
import ObjectiveC

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

        // Allow inline media playback
        config.allowsInlineMediaPlayback = true

        // Clear all cached web content on each launch to avoid stale
        // assets causing black screens or broken UI.
        let dataStore = WKWebsiteDataStore.default()
        let allTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        dataStore.removeData(ofTypes: allTypes, modifiedSince: .distantPast) { }
        config.websiteDataStore = dataStore

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.navigationDelegate = context.coordinator
        context.coordinator.attachWebView(webView)

        #if DEBUG
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
        #endif

        bridge.attach(to: webView)

        // Load immediately with just the siteKey in the hash.
        // The web app validates the site key itself (same path as the
        // browser embed flow), avoiding a blocking network round-trip
        // before the page even starts downloading.
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

        // Create a parent proxy that is !== window
        // with postMessage routing to native
        const parentProxy = Object.create(window);
        parentProxy.postMessage = function(message, targetOrigin) {
            window.webkit.messageHandlers.agentBridge.postMessage(message);
        };

        // Override window.parent — WKWebView has this as a non-configurable
        // property, so we need to try multiple strategies
        var parentOverridden = false;

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

        nativeLog('LOG', ['[NativeBridge] window.parent override: ' + (parentOverridden ? 'SUCCESS' : 'FAILED') + ', parent===window: ' + (window.parent === window)]);

        // Override window.top so iframe detection (window.self !== window.top) works
        var topOverridden = false;
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

        nativeLog('LOG', ['[NativeBridge] window.top override: ' + (topOverridden ? 'SUCCESS' : 'FAILED') + ', self===top: ' + (window.self === window.top)]);

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

        nativeLog('LOG', ['[NativeBridge] Bridge script initialized']);
    })();
    """

    // MARK: - Coordinator

    public final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
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
