#if os(macOS)
import SwiftUI
import WebKit

/// A page the app owns.
///
/// `AgentWebView` builds its page when SwiftUI makes the view and shuts it
/// down when SwiftUI takes the view away, so anything that changes the view's
/// identity starts the page again. On a host that restarts the relay, every
/// session's web state and the route tool calls take: on 2026-09-28 a Mac host
/// built a second page mid-session and tool calls went to the first.
///
/// An `AgentPage` is built once, by the app, and runs until the app retires
/// it. `AgentPageView` shows it. Taking that view away, or never showing one,
/// leaves the page running.
@MainActor
public final class AgentPage {
    /// The size a page is laid out at while nothing shows it. A web view made
    /// at `.zero` and never displayed keeps a 0x0 viewport.
    public nonisolated static let defaultFrame = CGRect(x: 0, y: 0, width: 1280, height: 800)

    public let configuration: AgentConfiguration
    public let webView: WKWebView
    public private(set) var isRetired = false

    // WKWebView holds its delegates and message handlers' owner weakly or not
    // at all across page loads; this is what keeps the coordinator alive.
    private let coordinator: AgentWebView.Coordinator
    private let bridge: AgentBridge

    /// The container showing the page, if any. The newest one made wins.
    weak var container: AgentPageContainer?

    /// - Parameter reason: why this page is being built, for the page log.
    public init(
        configuration: AgentConfiguration,
        bridge: AgentBridge,
        reason: String,
        frame: CGRect = AgentPage.defaultFrame
    ) {
        self.configuration = configuration
        self.bridge = bridge
        coordinator = AgentWebView.Coordinator(
            bridge: bridge, baseHost: configuration.baseURL.host, standalone: configuration.standalone)
        AgentPageLifecycle.expectNextPage(reason: reason)
        webView = AgentWebView.makePage(
            configuration: configuration, bridge: bridge, coordinator: coordinator,
            frame: frame, keepsRunningOutsideWindow: true)
    }

    /// Shut the page down for good. Only the owner calls this.
    public func retire() {
        guard !isRetired else { return }
        isRetired = true
        webView.removeFromSuperview()
        AgentWebView.retire(webView)
        AgentPageLifecycle.retired(webView, bridge: bridge)
    }
}

/// Shows an `AgentPage`. The page belongs to the app, not to this view: the
/// view going away takes the page off screen and nothing more.
@MainActor
public struct AgentPageView: NSViewRepresentable {
    public let page: AgentPage

    public init(page: AgentPage) {
        self.page = page
    }

    public func makeNSView(context: Context) -> AgentPageContainer {
        let container = AgentPageContainer()
        container.show(page)
        return container
    }

    public func updateNSView(_ container: AgentPageContainer, context: Context) {
        // SwiftUI can make the replacement before it takes the old view down,
        // and keeps updating the old one meanwhile. Only the newest container
        // may take the page, or the two pass it back and forth.
        if page.container === container { container.show(page) }
    }

    public static func dismantleNSView(_ container: AgentPageContainer, coordinator: ()) {
        container.letGo()
    }
}

/// The view a page sits in while it is shown.
public final class AgentPageContainer: NSView {
    /// Below this the container is a placeholder, not a place to read a page:
    /// the Mac host keeps its Agent screen 1pt wide while another tab is up.
    /// The page keeps the last real size it had, and is clipped.
    static let smallestRealSize: CGFloat = 50

    private weak var page: AgentPage?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @MainActor
    func show(_ page: AgentPage) {
        guard !page.isRetired else { return }
        self.page = page
        page.container = self
        let webView = page.webView
        if webView.superview !== self {
            webView.removeFromSuperview()
            webView.autoresizingMask = []
            addSubview(webView)
        }
        fit()
    }

    /// Takes the page off screen if this container still has it.
    @MainActor
    func letGo() {
        guard let page, page.container === self else { return }
        page.container = nil
        if page.webView.superview === self { page.webView.removeFromSuperview() }
        self.page = nil
    }

    public override func layout() {
        super.layout()
        MainActor.assumeIsolated { fit() }
    }

    // SwiftUI sizes the container by setting its frame, which does not always
    // bring a layout pass with it.
    public override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        MainActor.assumeIsolated { fit() }
    }

    @MainActor
    private func fit() {
        guard let webView = page?.webView, webView.superview === self else { return }
        guard bounds.width >= Self.smallestRealSize, bounds.height >= Self.smallestRealSize else { return }
        if webView.frame != bounds { webView.frame = bounds }
    }
}
#endif
