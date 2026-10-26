import SwiftUI
import WebKit

// MARK: - Claude sign-in in Ripul's own browser

/// Claude's sign-in page shown in Ripul's own browser, finishing by itself.
///
/// Claude Code's login is Anthropic's OAuth client, and its return addresses
/// are Anthropic's. When the browser is not on the machine being signed in, the
/// login's `redirect_uri` is Anthropic's page
/// `https://platform.claude.com/oauth/code/callback`, which shows
/// `<code>#<state>` for the person to paste. Nothing can register a return to
/// this app for that client, so the browser here is the callback: the
/// navigation to that address is stopped before it loads, its `code` and
/// `state` are read, the `state` is checked against the one the waiting machine
/// put in the authorize address, and `code#state` goes back the way a pasted
/// code does. The person taps Authorize and copies nothing.
///
/// The code is never shown, logged or kept: it is handed to `onFinish` once and
/// the page is unloaded.
public enum ClaudeSignInBrowser {
    /// Set by an app with a browser of its own, so the page has the Browser's
    /// cookies and the same engine settings that pass claude.ai's checks (the
    /// Ripul app: its tab manager's default context). Nil: a plain WebKit
    /// configuration with the default store.
    @MainActor public static var makeConfiguration: (() -> WKWebViewConfiguration)?

    /// Anthropic's page for a login whose browser is elsewhere. Used when the
    /// authorize address does not say (every one seen so far does).
    static let defaultCallback = URL(string: "https://platform.claude.com/oauth/code/callback")!

    enum Outcome: Equatable {
        /// `code#state`, exactly as the callback page would have shown it.
        case code(String)
        /// The page came back for a different sign-in, or without a code.
        case refused(String)
        /// The person declined on Claude's page.
        case denied(String)
    }

    /// What an address the page reached means for the sign-in begun with
    /// `authUrl`: nil while it is anything other than that sign-in's callback.
    static func outcome(for url: URL, authUrl: URL) -> Outcome? {
        let auth = URLComponents(url: authUrl, resolvingAgainstBaseURL: false)
        let authItems = auth?.queryItems ?? []
        let expected = authItems.first { $0.name == "redirect_uri" }?.value.flatMap(URL.init(string:)) ?? defaultCallback
        guard url.scheme?.lowercased() == "https", expected.scheme?.lowercased() == "https",
              url.host?.lowercased() == expected.host?.lowercased(),
              trimmedPath(url) == trimmedPath(expected) else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let expectedState = authItems.first(where: { $0.name == "state" })?.value, !expectedState.isEmpty,
              let state = value("state"), state == expectedState else {
            return .refused("Claude's page answered a different sign-in from the one this Mac is waiting for, so nothing was sent. Start over for a new page.")
        }
        if let error = value("error") {
            let detail = value("error_description") ?? error
            return .denied(error == "access_denied" ? "The sign-in was not authorized." : "Claude's page reported: \(detail)")
        }
        guard let code = value("code") else {
            return .refused("Claude's page came back without a code. Start over for a new page.")
        }
        return .code("\(code)#\(state)")
    }

    private static func trimmedPath(_ url: URL) -> String {
        var path = url.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    @MainActor static func configuration() -> WKWebViewConfiguration {
        if let make = makeConfiguration { return make() }
        let config = WKWebViewConfiguration()
        #if os(iOS)
        config.applicationNameForUserAgent = "Mobile/15E148 Safari/605.1.15"
        #else
        config.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        #endif
        return config
    }
}

/// The page and any window it opens (Google's sign-in is a popup), watched for
/// the callback.
@MainActor
final class ClaudeSignInBrowserModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    /// The sign-in page first, then each window it opened, newest last.
    @Published private(set) var pages: [WKWebView] = []
    @Published private(set) var loading = true
    /// Where the page on top is, host only, for the address line.
    @Published private(set) var host = ""

    let authUrl: URL
    private let onFinish: (ClaudeSignInBrowser.Outcome) -> Void
    private var finished = false
    private var observations: [ObjectIdentifier: NSKeyValueObservation] = [:]

    init(authUrl: URL, onFinish: @escaping (ClaudeSignInBrowser.Outcome) -> Void) {
        self.authUrl = authUrl
        self.onFinish = onFinish
        super.init()
    }

    func start() {
        guard pages.isEmpty, !finished else { return }
        let webView = WKWebView(frame: .zero, configuration: ClaudeSignInBrowser.configuration())
        adopt(webView)
        host = authUrl.host ?? ""
        webView.load(URLRequest(url: authUrl))
        NSLog("[ClaudeSignIn] opened %@%@ in Ripul's browser", authUrl.host ?? "", authUrl.path)
    }

    /// Stops every page and lets it go. Called when the sign-in ends either way.
    func close() {
        for page in pages {
            page.stopLoading()
            page.navigationDelegate = nil
            page.uiDelegate = nil
        }
        observations.removeAll()
        pages.removeAll()
    }

    private func adopt(_ webView: WKWebView) {
        webView.navigationDelegate = self
        webView.uiDelegate = self
        #if DEBUG
        if #available(macOS 13.3, iOS 16.4, *) { webView.isInspectable = true }
        #endif
        // A backstop for addresses that arrive without a navigation action to
        // decide (a script's history change): the URL itself is watched too.
        observations[ObjectIdentifier(webView)] = webView.observe(\.url, options: [.new]) { [weak self] view, _ in
            Task { @MainActor [weak self] in
                guard let self, let url = view.url else { return }
                if self.check(url) { view.stopLoading() }
            }
        }
        pages.append(webView)
    }

    /// True when `url` was this sign-in's callback, which ends the sign-in.
    @discardableResult
    private func check(_ url: URL) -> Bool {
        guard !finished, let outcome = ClaudeSignInBrowser.outcome(for: url, authUrl: authUrl) else { return false }
        finished = true
        switch outcome {
        case .code: NSLog("[ClaudeSignIn] callback caught, state matches: sending it to the waiting machine")
        case .refused: NSLog("[ClaudeSignIn] callback refused: its state is not this sign-in's")
        case .denied: NSLog("[ClaudeSignIn] callback says the sign-in was declined")
        }
        close()
        onFinish(outcome)
        return true
    }

    private func refresh() {
        loading = pages.contains { $0.isLoading }
        host = pages.last?.url?.host ?? host
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        // Stopped before it loads, so the code never renders or reaches history.
        if let url = navigationAction.request.url, check(url) { return (.cancel, preferences) }
        return (.allow, preferences)
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        if let url = webView.url, check(url) { webView.stopLoading() }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { refresh() }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refresh()
        // Host and path only: the query can carry the sign-in's state.
        if let url = webView.url { NSLog("[ClaudeSignIn] page loaded: %@%@", url.host ?? "", url.path) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { refresh() }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        refresh()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.reload() }

    // MARK: WKUIDelegate

    /// A window the page opens is shown over it. WebKit navigates the returned
    /// view itself; loading the address here as well would cut the popup off
    /// from its opener (the browser's fix of 23 October 2026).
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard !finished else { return nil }
        let popup = WKWebView(frame: webView.bounds, configuration: configuration)
        adopt(popup)
        refresh()
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        // The sign-in page itself closing leaves nothing to show; only popups go.
        guard let index = pages.firstIndex(of: webView), index > 0 else { return }
        observations[ObjectIdentifier(webView)] = nil
        pages.remove(at: index)
        refresh()
    }
}

/// Claude's page in Ripul's browser, over the sign-in sheet. `onFinish` is
/// called once, with the outcome or nil when the person closed it.
struct ClaudeSignInBrowserSheet: View {
    let machineName: String
    let onOpenElsewhere: () -> Void
    let onFinish: (ClaudeSignInBrowser.Outcome?) -> Void
    @StateObject private var model: ClaudeSignInBrowserModel

    /// `model` is given only by the lab, which drives the page itself.
    init(authUrl: URL, machineName: String, onOpenElsewhere: @escaping () -> Void,
         onFinish: @escaping (ClaudeSignInBrowser.Outcome?) -> Void, model: ClaudeSignInBrowserModel? = nil) {
        self.machineName = machineName
        self.onOpenElsewhere = onOpenElsewhere
        self.onFinish = onFinish
        _model = StateObject(wrappedValue: model ?? ClaudeSignInBrowserModel(authUrl: authUrl) { onFinish($0) })
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                if let page = model.pages.last {
                    SignInPageView(webView: page)
                        .id(ObjectIdentifier(page))
                        .ignoresSafeArea(.container, edges: .bottom)
                        .uiKitIdentifier("ClaudeSignInBrowser.page")
                }
                if model.loading {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .uiKitIdentifier("ClaudeSignInBrowser.loading")
                }
            }
            .navigationTitle("Sign in for \(machineName)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        model.close()
                        onFinish(nil)
                    }
                    .uiKitIdentifier("ClaudeSignInBrowser.cancel")
                }
                ToolbarItem(placement: .principal) {
                    Label(model.host, systemImage: "lock.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.ripul(.caption))
                        .foregroundStyle(.ripul(.textSecondary))
                        .uiKitIdentifier("ClaudeSignInBrowser.address")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.close()
                        onOpenElsewhere()
                    } label: {
                        Label("Open in Safari", systemImage: "safari")
                    }
                    .uiKitIdentifier("ClaudeSignInBrowser.openElsewhere")
                }
            }
        }
        .ripulSheet(.page, detents: [.large])
        .interactiveDismissDisabled()
        .onAppear { model.start() }
        .onDisappear { model.close() }
    }
}

#if os(iOS)
private struct SignInPageView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#else
private struct SignInPageView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#endif

/// The address a sheet's sign-in is open at, as an item for `.ripulSheet(item:)`.
struct ClaudeSignInPage: Identifiable, Equatable {
    let url: URL
    var id: String { url.absoluteString }
}
