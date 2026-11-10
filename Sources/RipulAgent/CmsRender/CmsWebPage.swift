#if os(iOS)
import SwiftUI
import WebKit

/// A web page shown inside the app (`open: { web, title }` on a card, swipe or
/// list row action), the way WAC's own app shows its FAQs, legal pages and
/// support articles (`CustomWebViewVC`): pushed on the tab's stack with the
/// system back and swipe back, the site's masthead with the title, the page in
/// one card that cuts into it, a progress bar while it loads.
///
/// What it never does: run a script bridge to the app (no message handlers,
/// no injected scripts), send the app's or the site's credentials (its own
/// non-persistent website data, no headers added), or open anything but
/// https. Links inside stay inside, as in WAC; a link to another kind of
/// address (mailto:, tel:, the App Store) goes to the system.
struct CmsWebPageView: View {
    let url: URL
    let title: String
    @EnvironmentObject private var runtime: CmsRuntime
    @StateObject private var model = CmsWebPageModel()
    @State private var bandHeight: CGFloat = 0

    var body: some View {
        let style = CmsMasthead.style(runtime.themeConfig, named: nil)
        let overlap = CGFloat(style.overlap)
        let radius = runtime.theme.cardRadius
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                runtime.theme.color(role: .background).ignoresSafeArea()
                VStack(spacing: 0) {
                    CmsMastheadBand(style: style, theme: runtime.theme, title: title, subtitle: nil,
                                    topInset: geometry.safeAreaInsets.top, extraBottom: overlap)
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height - geometry.safeAreaInsets.top }) { bandHeight = $0 }
                    Spacer(minLength: 0)
                }
                .ignoresSafeArea(edges: .top)
                card
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: 0,
                                                      bottomTrailingRadius: 0, topTrailingRadius: radius, style: .continuous))
                    .padding(.horizontal, 16)
                    .padding(.top, max(0, bandHeight - overlap))
                    .ignoresSafeArea(edges: .bottom)
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .task { model.load(url) }
        .cmsInspectorID("Cms.webPage")
    }

    @ViewBuilder private var card: some View {
        ZStack(alignment: .top) {
            runtime.theme.color(role: .paper)
            CmsWebView(model: model)
                .opacity(model.failure == nil ? 1 : 0)
            if let failure = model.failure {
                failureView(failure)
            }
            if model.loading {
                ProgressView(value: max(0.05, model.progress))
                    .progressViewStyle(.linear)
                    .tint(runtime.theme.color(role: .primary))
                    .accessibilityLabel("Loading")
            }
        }
    }

    private func failureView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Couldn't load", systemImage: "icloud.slash")
        } description: {
            Text(message)
        } actions: {
            Button("Try again") { model.reload() }
        }
        .cmsInspectorID("Cms.webPage.error")
    }
}

/// The web view's state: progress, loading, a failure to show.
@MainActor
final class CmsWebPageModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published var progress: Double = 0
    @Published var loading = false
    @Published var failure: String?
    private(set) lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        // Its own website data: nothing the app or another web view holds reaches the page.
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = false
        progressObservation = view.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
            Task { @MainActor in self?.progress = view.estimatedProgress }
        }
        return view
    }()
    private var progressObservation: NSKeyValueObservation?
    private var first: URL?

    func load(_ url: URL) {
        guard first == nil else { return }
        first = url
        failure = nil
        webView.load(URLRequest(url: url))
    }

    func reload() {
        failure = nil
        if webView.url != nil { webView.reload() } else if let first { webView.load(URLRequest(url: first)) }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        switch CmsWebPage.route(url) {
        case .inside:
            decisionHandler(.allow)
        case .system:
            decisionHandler(.cancel)
            UIApplication.shared.open(url)
        case .refuse:
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        if response.isForMainFrame, let http = response.response as? HTTPURLResponse, http.statusCode >= 400 {
            failure = "The page answered \(http.statusCode)."
            loading = false
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loading = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(error)
    }

    private func finish(_ error: Error) {
        loading = false
        let ns = error as NSError
        // A navigation the page or this view replaced is not a failure.
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && ns.code == 102 { return }  // frame load interrupted (a cancelled policy)
        failure = ns.localizedDescription
    }

    // MARK: WKUIDelegate

    /// A link that asks for a new window (`target="_blank"`) opens here, in place.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil, let url = action.request.url, CmsWebPage.route(url) == .inside {
            webView.load(URLRequest(url: url))
        }
        return nil
    }
}

private struct CmsWebView: UIViewRepresentable {
    @ObservedObject var model: CmsWebPageModel
    func makeUIView(context: Context) -> WKWebView { model.webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#endif
