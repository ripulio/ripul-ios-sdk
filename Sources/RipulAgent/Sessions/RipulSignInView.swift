import SwiftUI
import WebKit
import os

// MARK: - Embedded Sign-In Web View

/// A lightweight WKWebView that loads the dedicated `/popup#/sign-in` page.
/// Uses the injected ``WKWebsiteDataStore`` so Clerk cookies propagate to the
/// console's main chat web view. The web page posts a `signInComplete` message
/// via `webkit.messageHandlers` when auth succeeds — no polling needed.
#if os(macOS)
public struct RipulSignInView: NSViewRepresentable {
    @ObservedObject var authToken: RipulClerkAuthStore
    var bridge: AgentBridge
    /// The website data store to share with the main chat web view so Clerk's
    /// session cookies + token cache propagate once sign-in completes.
    let dataStore: WKWebsiteDataStore
    /// Base URL the `/popup#/sign-in` page is loaded from.
    var baseURL: URL
    /// Called once sign-in is detected, so a host presenting this view (e.g. a
    /// sheet) can dismiss itself. The main web view is reloaded regardless.
    var onSignedIn: () -> Void

    public init(
        authToken: RipulClerkAuthStore,
        bridge: AgentBridge,
        dataStore: WKWebsiteDataStore,
        baseURL: URL = AgentConfiguration.defaultBaseURL,
        onSignedIn: @escaping () -> Void = {}
    ) {
        self.authToken = authToken
        self.bridge = bridge
        self.dataStore = dataStore
        self.baseURL = baseURL
        self.onSignedIn = onSignedIn
    }

    public func makeCoordinator() -> RipulSignInViewCoordinator {
        RipulSignInViewCoordinator(authToken: authToken, bridge: bridge, dataStore: dataStore, baseURL: baseURL, onSignedIn: onSignedIn)
    }

    public func makeNSView(context: Context) -> WKWebView {
        context.coordinator.createWebView()
    }

    public func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#else
public struct RipulSignInView: UIViewRepresentable {
    @ObservedObject var authToken: RipulClerkAuthStore
    var bridge: AgentBridge
    /// The website data store to share with the main chat web view so Clerk's
    /// session cookies + token cache propagate once sign-in completes.
    let dataStore: WKWebsiteDataStore
    /// Base URL the `/popup#/sign-in` page is loaded from.
    var baseURL: URL
    /// Called once sign-in is detected, so a host presenting this view (e.g. a
    /// sheet) can dismiss itself. The main web view is reloaded regardless.
    var onSignedIn: () -> Void

    public init(
        authToken: RipulClerkAuthStore,
        bridge: AgentBridge,
        dataStore: WKWebsiteDataStore,
        baseURL: URL = AgentConfiguration.defaultBaseURL,
        onSignedIn: @escaping () -> Void = {}
    ) {
        self.authToken = authToken
        self.bridge = bridge
        self.dataStore = dataStore
        self.baseURL = baseURL
        self.onSignedIn = onSignedIn
    }

    public func makeCoordinator() -> RipulSignInViewCoordinator {
        RipulSignInViewCoordinator(authToken: authToken, bridge: bridge, dataStore: dataStore, baseURL: baseURL, onSignedIn: onSignedIn)
    }

    public func makeUIView(context: Context) -> WKWebView {
        context.coordinator.createWebView()
    }

    public func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif

private let signInLog = Logger(subsystem: "io.ripul.mac", category: "SignInWebView")

public class RipulSignInViewCoordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private let authToken: RipulClerkAuthStore
    private let bridge: AgentBridge
    private let dataStore: WKWebsiteDataStore
    private let baseURL: URL
    private let onSignedIn: () -> Void
    private weak var webView: WKWebView?
    private var hasLoadedSignInPage = false
    private var signInHandled = false

    init(authToken: RipulClerkAuthStore, bridge: AgentBridge, dataStore: WKWebsiteDataStore, baseURL: URL, onSignedIn: @escaping () -> Void = {}) {
        self.authToken = authToken
        self.bridge = bridge
        self.dataStore = dataStore
        self.baseURL = baseURL
        self.onSignedIn = onSignedIn
    }

    func createWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        // Share the injected data store so Clerk's session cookies + token
        // cache propagate to the main chat web view once sign-in completes.
        config.websiteDataStore = dataStore

        // Match the chat web view's user agent so OAuth providers (Google,
        // GitHub) don't reject the embedded flow with "disallowed_useragent",
        // and so the web app detects native mode (which preserves the OAuth
        // redirect hash params). The bridge gracefully no-ops here because we
        // don't register the `agentBridge` handler — NativeBridge.connect()
        // bails when the handler is absent.
        #if os(macOS)
        config.applicationNameForUserAgent = "Version/17.0 RipulNative/1.0 Safari/604.1"
        #else
        config.applicationNameForUserAgent = "Version/17.0 RipulNative/1.0 Mobile/15E148 Safari/604.1"
        #endif

        // The web sign-in page posts `signInComplete` via webkit.messageHandlers
        // the moment Clerk auth succeeds — an instant signal. We keep the
        // post-redirect poll below as a fallback for flows that don't land back
        // on the /sign-in route.
        config.userContentController.add(self, name: "signInComplete")

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
        self.webView = wv
        #if DEBUG
        if #available(iOS 16.4, macOS 13.3, *) { wv.isInspectable = true }
        #endif

        // Load the dedicated sign-in page
        var components = URLComponents(url: baseURL.appendingPathComponent("popup"), resolvingAgainstBaseURL: false)!
        components.fragment = "/sign-in"
        if let url = components.url {
            signInLog.warning("Loading sign-in page: \(url.absoluteString)")
            wv.load(URLRequest(url: url))
        }
        return wv
    }

    // MARK: - WKScriptMessageHandler

    public func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "signInComplete" else { return }
        signInLog.warning("signInComplete message received")
        Task { @MainActor in self.handleSignInSuccess(reason: "message") }
    }

    // MARK: - WKNavigationDelegate

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let url = webView.url?.absoluteString ?? "nil"
        signInLog.warning("didFinish: \(url) (hasLoadedSignInPage=\(self.hasLoadedSignInPage))")

        if !hasLoadedSignInPage {
            hasLoadedSignInPage = true
            return
        }

        // After the initial load, any subsequent navigation completion means
        // OAuth redirect finished — check if Clerk now has a user.
        Task { @MainActor in
            // Small delay to let Clerk initialize after redirect
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self.checkForSignIn(webView: webView)
        }
    }

    private func checkForSignIn(webView: WKWebView) {
        guard !signInHandled else { return }
        Task { @MainActor in
            for attempt in 1...20 {
                guard !self.signInHandled else { return }
                do {
                    let result = try await webView.evaluateJavaScript(
                        "window.Clerk?.user?.id || ''"
                    )
                    if let userId = result as? String, !userId.isEmpty {
                        self.handleSignInSuccess(reason: "poll attempt \(attempt)")
                        return
                    }
                } catch {}
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            signInLog.warning("User check timed out after 10s")
        }
    }

    /// Single convergence point for both the `signInComplete` message and the
    /// post-redirect poll. Idempotent via `signInHandled`.
    @MainActor
    private func handleSignInSuccess(reason: String) {
        guard !signInHandled else { return }
        signInHandled = true
        signInLog.warning("Sign-in detected (\(reason)) — reloading main web view")

        // Mark as previously signed in — this switches the overlay to
        // ConnectingOverlay instead of showing sign-in again during the reload.
        authToken.wasPreviouslySignedIn = true

        // Reload the main web view so it starts with the auth cookie already
        // present. RipulClerkAuthStore picks up the Clerk token on its first poll.
        bridge.clearCacheAndReload()

        // Let the presenter dismiss (e.g. the native sign-in sheet).
        onSignedIn()
    }
}
