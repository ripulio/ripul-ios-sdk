import SwiftUI

/// Public entry point: renders a CMS page natively from its JSON definition —
/// the same definition the web renderer interprets, no web views involved.
///
/// ```swift
/// CmsPageView(
///     cmsId: "cms_abc",
///     pageSlug: "home",
///     clientConfig: CmsClientConfig(getToken: { authToken.token })
/// )
/// ```
public struct CmsPageView: View {
    public let cmsId: String
    public let pageSlug: String?

    @StateObject private var loader: CmsPageLoader
    @State private var showDiagnostics = false

    /// Visitor mode: a site key's PUBLISHABLE key. When set, the page loads
    /// as an anonymous portal visitor — the definition comes from the site-key
    /// validate response's embedded config (never /admin), queries run with
    /// the site-key session token, and requiresAuth pages are hidden.
    public var visitorSiteKey: String?

    /// Host exit hook: called when the reader swipes in from the LEFT edge
    /// and the portal has no use for it (no left panel, or its drawer is
    /// already open) — the "delegate up" of edge ownership. Hosts presenting
    /// the portal full screen dismiss here. nil = unclaimed swipes no-op.
    public var onEdgeExit: (() -> Void)?

    /// - Parameters:
    ///   - cmsId: The CMS definition id.
    ///   - pageSlug: Page to render; nil renders the definition's first page.
    ///   - clientConfig: Auth + base URL, following the SDK's injected-token pattern.
    public init(cmsId: String, pageSlug: String? = nil, clientConfig: CmsClientConfig, visitorSiteKey: String? = nil, onEdgeExit: (() -> Void)? = nil) {
        self.cmsId = cmsId
        self.pageSlug = pageSlug
        self.visitorSiteKey = visitorSiteKey
        self.onEdgeExit = onEdgeExit
        _loader = StateObject(wrappedValue: CmsPageLoader(cmsId: cmsId, clientConfig: clientConfig, visitorSiteKey: visitorSiteKey))
    }

    public var body: some View {
        Group {
            switch loader.state {
            case .idle, .loading:
                ProgressView("Loading page…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .error(let message):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text(message)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry") { loader.load(pageSlug: pageSlug) }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let page):
                ScrollView {
                    if let blocks = page.blocks {
                        CmsBlockContainerView(container: blocks)
                            .padding(16)
                    } else {
                        Text("Page '\(page.slug)' has no blocks body")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .padding()
                    }
                }
                .environmentObject(loader.runtime)
                .navigationTitle(page.title)
                .overlay(alignment: .bottomTrailing) {
                    Button {
                        showDiagnostics.toggle()
                    } label: {
                        Image(systemName: "ladybug")
                            .font(.footnote)
                            .padding(8)
                            .background(Circle().fill(Color.secondary.opacity(0.15)))
                    }
                    .buttonStyle(.plain)
                    .padding(12)
                }
                .sheet(isPresented: $showDiagnostics) {
                    CmsRuntimeDiagnosticsView(runtime: loader.runtime)
                }
                // Screen-edge swipe zones (page setting, default on): thin
                // strips OVER the content, so nested scroll views can't
                // claim the touch first — the native reading of
                // UIScreenEdgePanGestureRecognizer. The trailing strip sits
                // under the drawer overlay (an open drawer's own gestures
                // win); the LEADING strip sits ABOVE it, because an
                // unclaimed left-edge swipe — no left panel, or the drawer
                // already open — delegates up to the host via onEdgeExit
                // (first swipe = hamburger, second = exit).
                .overlay(alignment: .trailing) {
                    CmsEdgeSwipeStrip(runtime: loader.runtime, edge: .trailing, onExit: nil)
                }
                .overlay {
                    CmsDrawerOverlay(runtime: loader.runtime)
                }
                .overlay(alignment: .leading) {
                    CmsEdgeSwipeStrip(runtime: loader.runtime, edge: .leading, onExit: onEdgeExit)
                }
            }
        }
        .onAppear { loader.load(pageSlug: pageSlug) }
        // Native routing: nav blocks publish a page slug; the loader swaps
        // the rendered page in place. The runtime (queries, selections,
        // parameters) survives the swap — the web's SPA navigation reading.
        .onReceive(loader.runtime.$pendingNavigation) { navigation in
            guard let navigation else { return }
            loader.runtime.pendingNavigation = nil
            loader.show(pageSlug: navigation.pageSlug)
        }
    }
}

@MainActor
final class CmsPageLoader: ObservableObject {
    enum State {
        case idle
        case loading
        case loaded(CmsPage)
        case error(String)
    }

    @Published var state: State = .idle
    /// Pages navigable in this session (visitor mode: public pages only).
    private(set) var availablePages: [CmsPage] = []
    /// The portal shell page (cms.shellPageId), when designated and visible.
    private(set) var shellPage: CmsPage?
    let runtime: CmsRuntime

    private let cmsId: String
    private let client: CmsClient
    private let visitorSiteKey: String?

    init(cmsId: String, clientConfig: CmsClientConfig, visitorSiteKey: String? = nil) {
        self.cmsId = cmsId
        self.visitorSiteKey = visitorSiteKey
        self.client = CmsClient(config: clientConfig)
        self.runtime = CmsRuntime(cmsId: cmsId, client: self.client)
    }

    func load(pageSlug: String?) {
        if case .loading = state { return }
        if case .loaded = state { return }
        state = .loading
        Task {
            if let publishableKey = visitorSiteKey {
                await loadAsVisitor(publishableKey: publishableKey, pageSlug: pageSlug)
                return
            }
            do {
                let definition = try await client.fetchDefinition(cmsId: cmsId)
                self.runtime.theme = CmsPortalTheme(config: definition.theme)
                // Resolve the RLS site-key context: queries run with the site
                // key linked to this CMS, matching how the portal runs them.
                if client.siteKeyId == nil,
                   let keys = try? await client.listSiteKeys(),
                   let linked = keys.first(where: { $0.cmsDefinitionId == cmsId }) {
                    client.siteKeyId = linked.id
                    client.siteKeyPublishable = linked.publishableKey
                }
                self.runtime.queryDefs = Dictionary(
                    uniqueKeysWithValues: (definition.queries ?? []).map { ($0.slug, $0) }
                )
                self.runtime.columnViews = Dictionary(
                    (definition.columnViews ?? []).map { ($0.slug, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                let pages = definition.pages ?? []
                self.availablePages = pages
                self.shellPage = definition.shellPageId.flatMap { id in pages.first { $0.id == id } }
                let landing = definition.landingPageId.flatMap { id in pages.first { $0.id == id } }
                let page = pageSlug.flatMap { slug in pages.first { $0.slug == slug } } ?? landing ?? pages.first
                if let page {
                    self.present(page, animated: false)
                } else {
                    self.state = .error(
                        pageSlug.map { "No page with slug '\($0)'" } ?? "Definition has no pages"
                    )
                }
            } catch {
                self.state = .error(error.localizedDescription)
            }
        }
    }

    /// Visitor path: validate the site key, adopt its session token for all
    /// query runs, and read the definition from the validate response's
    /// embedded config — the same source a real portal visitor uses. Pages
    /// requiring auth are hidden (anonymous visitor, public role only).
    private func loadAsVisitor(publishableKey: String, pageSlug: String?) async {
        guard let baseURL = URL(string: RipulDomain.demoURL) else {
            state = .error("Bad base URL")
            return
        }
        let result = await SiteKeyValidator.validate(siteKey: publishableKey, baseURL: baseURL)
        guard let token = result.sessionToken, let configJSON = result.configJSON,
              let configData = configJSON.data(using: .utf8) else {
            state = .error("Site key validation failed")
            return
        }
        client.visitorSessionToken = token
        client.siteKeyPublishable = publishableKey
        // Body siteKeyId is unnecessary: the server derives the RLS site key
        // from the session token's auth context.
        client.siteKeyId = nil

        struct VisitorConfig: Codable {
            struct Cms: Codable {
                var pages: [CmsPage]?
                var queries: [CmsQueryDef]?
                var theme: CmsPortalThemeConfig?
                var shellPageId: String?
                var landingPageId: String?
                var columnViews: [CmsColumnView]?
            }
            var cmsDefinitionId: String?
            var cms: Cms?
        }
        guard let config = try? JSONDecoder().decode(VisitorConfig.self, from: configData),
              let cms = config.cms else {
            state = .error("Site key has no embedded CMS config")
            return
        }
        runtime.theme = CmsPortalTheme(config: cms.theme)
        runtime.queryDefs = Dictionary(
            uniqueKeysWithValues: (cms.queries ?? []).map { ($0.slug, $0) }
        )
        runtime.columnViews = Dictionary(
            (cms.columnViews ?? []).map { ($0.slug, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let allPages = cms.pages ?? []
        let visible = allPages.filter { $0.requiresAuth == false }
        availablePages = visible
        // The shell is CHROME, not routable content — resolve it from ALL
        // pages. Its own auth flag doesn't gate it (the web router renders
        // the shell for every visitor and gates only the routed pages;
        // WAC's shell page is auth-defaulted and was silently dropped here).
        shellPage = cms.shellPageId.flatMap { id in allPages.first { $0.id == id } }
        let landing = cms.landingPageId.flatMap { id in visible.first { $0.id == id } }
        if let pageSlug {
            if let page = visible.first(where: { $0.slug == pageSlug }) {
                present(page, animated: false)
            } else if allPages.contains(where: { $0.slug == pageSlug }) {
                state = .error("Page requires sign-in — not visible to anonymous visitors")
            } else {
                state = .error("No page with slug '\(pageSlug)'")
            }
        } else if let entry = landing ?? visible.first {
            present(entry, animated: false)
        } else {
            state = .error("No public pages on this portal")
        }
    }

    /// Swap the rendered page (native routing). Unknown or auth-hidden
    /// slugs are ignored — same outcome as a dead link on the web.
    func show(pageSlug: String) {
        guard let page = availablePages.first(where: { $0.slug == pageSlug }) else { return }
        present(page, animated: true)
    }

    /// Present a page — the shell pattern's fork. With a designated shell,
    /// the SHELL renders as persistent chrome and the target page renders
    /// inside its pageOutlet (an outlet-only swap when the shell is already
    /// up, so nav drawers and their edge-swipe registrations persist). The
    /// shell itself (or no shell) renders standalone.
    private func present(_ page: CmsPage, animated: Bool) {
        if let shell = shellPage, page.id != shell.id {
            applyPageContext(page)
            if isShowingShell {
                if animated {
                    withAnimation(.snappy) { runtime.outletPage = page }
                } else {
                    runtime.outletPage = page
                }
            } else {
                runtime.outletPage = page
                setState(.loaded(shell), animated: animated)
            }
        } else {
            runtime.outletPage = nil
            applyPageContext(page)
            setState(.loaded(page), animated: animated)
        }
    }

    private var isShowingShell: Bool {
        guard case .loaded(let current) = state, let shell = shellPage else { return false }
        return current.id == shell.id
    }

    private func setState(_ new: State, animated: Bool) {
        if animated {
            withAnimation(.snappy) { state = new }
        } else {
            state = new
        }
    }

    /// Page-scoped runtime context: nav active-state slug + the page's
    /// native sidebar affordances. Swipe-slot registrations are NOT
    /// cleared here — registering views own their lifecycle (register on
    /// appear, unregister on disappear), so the shell's nav survives
    /// outlet swaps while a departing page's panels clean up after
    /// themselves.
    private func applyPageContext(_ page: CmsPage) {
        runtime.currentPageSlug = page.slug
        runtime.pageSidebarIcon = page.nativeSidebarIcon ?? false
        runtime.pageSidebarEdgeSwipe = page.nativeSidebarEdgeSwipe ?? true
    }
}

/// Invisible screen-edge swipe zone — sits OVER the page content (nested
/// scroll views can't steal the touch). When the page CLAIMS the edge (a
/// registered panel, drawer closed, edge swipe on), the swipe slides the
/// panel in TRACKING the finger, committing or settling back on release
/// with flick prediction. When it can't claim and an `onExit` handler is
/// set (leading edge only), the swipe DELEGATES UP: a decisive inward pull
/// exits the portal — first swipe = hamburger, second = exit. 22pt wide:
/// the intended edge affordance without blocking content interaction.
private struct CmsEdgeSwipeStrip: View {
    @ObservedObject var runtime: CmsRuntime
    let edge: CmsRuntime.DrawerRequest.Edge
    let onExit: (() -> Void)?

    private enum Mode { case idle, opening, exiting }
    @State private var mode: Mode = .idle

    private let spring = Animation.spring(response: 0.32, dampingFraction: 0.86)
    private var width: CGFloat { CmsDrawerOverlay.panelWidth }
    /// Hidden-at-edge offset for this edge.
    private var hiddenOffset: CGFloat { edge == .leading ? -width : width }

    private var slot: CmsPageBlocks? {
        edge == .leading ? runtime.edgeSwipeLeftSlot : runtime.edgeSwipeRightSlot
    }
    private var claims: Bool {
        runtime.pageSidebarEdgeSwipe && slot != nil && runtime.openDrawer == nil
    }

    private func travel(_ dx: CGFloat) -> CGFloat {
        max(0, edge == .leading ? dx : -dx)
    }

    var body: some View {
        if (runtime.pageSidebarEdgeSwipe && slot != nil) || onExit != nil {
            Color.clear
                .frame(width: 22)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .highPriorityGesture(
                    DragGesture(minimumDistance: 10)
                        .onChanged { value in
                            if mode == .idle {
                                if claims, let slot {
                                    mode = .opening
                                    runtime.drawerInteractiveOpen = true
                                    runtime.drawerOpenOffset = hiddenOffset
                                    runtime.openDrawer = .init(edge: edge, slot: slot)
                                } else if onExit != nil {
                                    mode = .exiting
                                } else {
                                    return
                                }
                            }
                            if mode == .opening {
                                let pulled = min(travel(value.translation.width), width)
                                runtime.drawerOpenOffset = hiddenOffset * (1 - pulled / width)
                            }
                        }
                        .onEnded { value in
                            defer { mode = .idle }
                            let pulled = travel(value.translation.width)
                            let predicted = travel(value.predictedEndTranslation.width)
                            switch mode {
                            case .idle:
                                break
                            case .exiting:
                                if pulled > 60 || predicted > 120 {
                                    onExit?()
                                }
                            case .opening:
                                if pulled > width * 0.33 || predicted > width * 0.66 {
                                    withAnimation(spring) { runtime.drawerOpenOffset = 0 }
                                    runtime.drawerInteractiveOpen = false
                                } else {
                                    withAnimation(spring) { runtime.drawerOpenOffset = hiddenOffset }
                                    // Remove once it has settled off-screen; the
                                    // identity transition makes removal invisible.
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
                                        if runtime.drawerInteractiveOpen {
                                            runtime.openDrawer = nil
                                            runtime.drawerInteractiveOpen = false
                                            runtime.drawerOpenOffset = 0
                                        }
                                    }
                                }
                            }
                        }
                )
        }
    }
}
