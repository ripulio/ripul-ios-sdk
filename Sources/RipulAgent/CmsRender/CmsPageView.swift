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
    @Environment(\.colorScheme) private var colorScheme

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

    /// Whether the portal owns the SCREEN EDGES for its own drawer / edge
    /// navigation. Default true (standalone portal). Set false when the page
    /// is pushed inside a host that owns navigation (e.g. WAC opening a page
    /// from its own slide-out sidebar): the CMS then leaves both screen edges
    /// alone, so the host's edge-swipe and the nav-controller back-swipe keep
    /// working instead of the CMS drawer hijacking the left edge.
    public var edgeSwipeEnabled: Bool

    /// - Parameters:
    ///   - cmsId: The CMS definition id.
    ///   - pageSlug: Page to render; nil renders the definition's first page.
    ///   - clientConfig: Auth + base URL, following the SDK's injected-token pattern.
    public init(cmsId: String, pageSlug: String? = nil, clientConfig: CmsClientConfig, visitorSiteKey: String? = nil, onEdgeExit: (() -> Void)? = nil, edgeSwipeEnabled: Bool = true) {
        self.cmsId = cmsId
        self.pageSlug = pageSlug
        self.visitorSiteKey = visitorSiteKey
        self.onEdgeExit = onEdgeExit
        self.edgeSwipeEnabled = edgeSwipeEnabled
        _loader = StateObject(wrappedValue: CmsPageLoader(cmsId: cmsId, clientConfig: clientConfig, visitorSiteKey: visitorSiteKey))
    }

    public var body: some View {
        Group {
            switch loader.state {
            case .idle, .loading, .error, .noAccess:
                CmsPageLoadStatusView(state: loader.state) { loader.load(pageSlug: pageSlug) }
            case .loaded(let page):
                CmsPageBody(
                    page: page,
                    runtime: loader.runtime,
                    designController: loader.designController,
                    edgeSwipeEnabled: edgeSwipeEnabled,
                    onEdgeExit: onEdgeExit
                )
            }
        }
        // A site that forces light or dark: its content and the chrome agree.
        .modifier(CmsSiteColorScheme(runtime: loader.runtime, ownsWindow: false))
        .onAppear {
            loader.runtime.updateEffectiveDark(colorScheme == .dark)
            loader.load(pageSlug: pageSlug)
        }
        .onChange(of: colorScheme) { newScheme in
            loader.runtime.updateEffectiveDark(newScheme == .dark)
        }
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

/// Every state but `.loaded`: the spinner, a failure with Retry, or the
/// access message. Shared by `CmsPageView` and `CmsAppView`.
struct CmsPageLoadStatusView: View {
    let state: CmsPageLoader.State
    let retry: () -> Void

    var body: some View {
        Group {
            switch state {
            case .idle, .loading, .loaded:
                ProgressView("Loading page…")
            case .error(let message):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text(message)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry", action: retry)
                }
                .padding()
            case .noAccess(let message):
                VStack(spacing: 12) {
                    Image(systemName: "lock.circle")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("No access")
                        .font(.headline)
                    Text(message)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A loaded page: its blocks in a scroll view, with the page-level overlays
/// (design pill, floating chat, drawer, edge strips). `CmsPageView` draws the
/// loader's current page with it; `CmsAppView` draws each tab's pages with it,
/// leaving the screen edges to the navigation stack and drawing the drawer and
/// floating chat once per tab (`hostsPageOverlays: false`).
struct CmsPageBody: View {
    /// The page as it is viewed: its masthead (CmsMasthead.swift) put first.
    private let page: CmsPage
    let runtime: CmsRuntime
    let designController: CmsDesignController?
    var edgeSwipeEnabled: Bool
    var onEdgeExit: (() -> Void)?
    var hostsPageOverlays = true
    var showsDesignTools = true
    /// Bumped to scroll the page back to its top (a re-tap of its tab).
    var scrollToTopSignal = 0

    @State private var showDiagnostics = false
    @StateObject private var scrollTracker = CmsScrollTracker()

    init(page: CmsPage, runtime: CmsRuntime, designController: CmsDesignController?, edgeSwipeEnabled: Bool,
         onEdgeExit: (() -> Void)? = nil, hostsPageOverlays: Bool = true, showsDesignTools: Bool = true,
         scrollToTopSignal: Int = 0) {
        // Viewed with its masthead first. The designer edits the raw page JSON
        // (CmsDesignController), so the band never reaches a save.
        self.page = CmsMasthead.applied(page, theme: runtime.themeConfig)
        self.runtime = runtime
        self.designController = designController
        self.edgeSwipeEnabled = edgeSwipeEnabled
        self.onEdgeExit = onEdgeExit
        self.hostsPageOverlays = hostsPageOverlays
        self.showsDesignTools = showsDesignTools
        self.scrollToTopSignal = scrollToTopSignal
    }

    /// `titleDisplay: 'hidden'`: no navigation title (CmsLevers.swift).
    private var titleHidden: Bool { page.titleDisplay == "hidden" }

    var body: some View {
        let floating = CmsLevers.floatingButton(page.blocks)
        // The first block of a title-hidden page that bleeds runs under the status bar.
        let topBleedId = titleHidden ? CmsLevers.firstBlock(page.blocks).flatMap { $0.frame?.bleed == true ? $0.id : nil } : nil
        // `pin: 'behind'`: the first block stays where it is while the page
        // scrolls up over it (CmsPinnedLayers).
        let pinned = CmsLevers.pinnedBlock(page.blocks)
        // The page's own frame (the web's page container): its padding is the
        // page's margin in place of the default 16, and its background fills the
        // whole page, edge to edge and under the bars, as it fills the browser.
        let rootFrame = page.blocks?.containerFrame
        let rootInsets = CmsCss.insets(rootFrame?.padding, width: CmsSiteText.viewportWidth)
        let margin: CGFloat = rootInsets == nil ? 16 : 0
        GeometryReader { geometry in
            CmsTopScrollingView(signal: scrollToTopSignal) {
                if let blocks = page.blocks {
                    if let pinned {
                        CmsPinnedLayers(frame: pinned.frame,
                                        viewportHeight: geometry.size.height, tracker: scrollTracker,
                                        cutRadius: runtime.theme.cardRadius, cutInset: 16) {
                            CmsBlockView(block: pinned, axis: .vertical)
                                // The gap of the list it holds a place in: its overlap
                                // gives back that gap too, so its measured height is
                                // the place's and what follows starts exactly N up.
                                .environment(\.cmsStackGap, blocks.containerFrame?.gapPoints ?? 16)
                                // Its height, whenever it changes, for its place in the list.
                                .modifier(CmsPinnedHeightReport())
                                .padding(margin)
                                .frame(maxWidth: .infinity, alignment: .top)
                        } list: {
                            CmsBlockContainerView(container: blocks)
                                .padding(margin)
                                .environment(\.cmsPinnedFlowId, pinned.id)
                        }
                        #if os(iOS)
                        .background(CmsScrollTrackerProbe(tracker: scrollTracker))
                        #endif
                    } else {
                        CmsBlockContainerView(container: blocks)
                            .padding(margin)
                    }
                } else {
                    Text("Page '\(page.slug)' has no blocks body")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .padding()
                }
            }
            // What a bleeding block gives back: the page's own side padding when it sets one.
            .environment(\.cmsPageMargin, rootInsets?.leading ?? 16)
            .environment(\.cmsTopBleed, topBleedId.map { CmsTopBleed(blockId: $0, inset: geometry.safeAreaInsets.top) })
            // The floating button never covers the last row.
            .contentMargins(.bottom, floating == nil ? 0 : 72, for: .scrollContent)
            .overlay(alignment: .bottomTrailing) {
                if let floating {
                    // Drawn directly, not through a block frame, whose clip would cut its shadow.
                    CmsActionButtonBlockView(block: floating)
                        .environment(\.cmsFloatingHost, true)
                        .padding(16)
                }
            }
        }
        .environmentObject(runtime)
        // The site palette's page background, when it names one.
        .modifier(CmsPageBackground(runtime: runtime, pageFill: rootFrame?.background))
        .navigationTitle(titleHidden ? "" : page.title)
        .modifier(CmsPageTitleDisplay(hidden: titleHidden))
        .overlay {
            if showsDesignTools {
                CmsDesignFloatingToolbar(
                    runtime: runtime,
                    controller: designController,
                    showDiagnostics: $showDiagnostics
                )
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if hostsPageOverlays {
                CmsFloatingChatHost(runtime: runtime)
            }
        }
        // The runtime's notice (a form's success message), above the tab bar.
        .overlay(alignment: .bottom) { CmsNoticeView(runtime: runtime) }
        .ripulSheet(isPresented: $showDiagnostics) {
            CmsRuntimeDiagnosticsView(runtime: runtime)
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
        //
        // When embedded in a host that owns navigation
        // (edgeSwipeEnabled == false) the CMS claims NEITHER edge, so
        // the host's slide-out and the nav back-swipe keep the left
        // edge. The drawer overlay stays — it only shows when opened
        // by a burger tap, never by an edge grab.
        .overlay(alignment: .trailing) {
            if edgeSwipeEnabled {
                CmsEdgeSwipeStrip(runtime: runtime, edge: .trailing, onExit: nil)
            }
        }
        .overlay {
            if hostsPageOverlays {
                CmsDrawerOverlay(runtime: runtime)
            }
        }
        .overlay(alignment: .leading) {
            if edgeSwipeEnabled {
                CmsEdgeSwipeStrip(runtime: runtime, edge: .leading, onExit: onEdgeExit)
            }
        }
    }
}

/// A page's scroll view that goes back to its very top when `signal`
/// changes (a re-tap of its tab), as Apple's apps do: the large title open
/// again, not the first row tucked under an inline title. `ScrollPosition`'s
/// top edge and a top anchor both stop at the inline title (the bar measured
/// 54 pt against 105 pt open), so on iOS a probe finds the `UIScrollView` and
/// scrolls it to minus its top inset with the title open.
struct CmsTopScrollingView<Content: View>: View {
    let signal: Int
    @ViewBuilder let content: () -> Content

    var body: some View {
        #if os(iOS)
        ScrollView {
            content()
                .background(CmsScrollToTopProbe(signal: signal))
        }
        #else
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 0).id("cms.page.top")
                    content()
                }
            }
            .onChange(of: signal) { _ in
                withAnimation(.snappy) { proxy.scrollTo("cms.page.top", anchor: .top) }
            }
        }
        #endif
    }
}

#if os(iOS)
/// Finds the scroll view it sits in and keeps the largest top inset seen for
/// the current width: the inset while the large title is open (the inset
/// shrinks as the title collapses). A new `signal` scrolls to minus it.
private struct CmsScrollToTopProbe: UIViewRepresentable {
    let signal: Int

    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.isUserInteractionEnabled = false
        probe.isAccessibilityElement = false
        return probe
    }

    func updateUIView(_ probe: Probe, context: Context) {
        probe.receive(signal)
    }

    final class Probe: UIView {
        private weak var scrollView: UIScrollView?
        private var observation: NSKeyValueObservation?
        private var lastSignal: Int?
        private var openTopInset: CGFloat = 0
        private var measuredWidth: CGFloat = 0

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            var view = superview
            while let current = view, !(current is UIScrollView) { view = current.superview }
            guard let found = view as? UIScrollView, found !== scrollView else { return }
            scrollView = found
            observation = found.observe(\.contentOffset, options: [.initial]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.measure() }
            }
        }

        private func measure() {
            guard let scrollView else { return }
            if scrollView.bounds.width != measuredWidth {
                measuredWidth = scrollView.bounds.width
                openTopInset = 0
            }
            openTopInset = max(openTopInset, scrollView.adjustedContentInset.top)
        }

        func receive(_ signal: Int) {
            defer { lastSignal = signal }
            guard let last = lastSignal, last != signal, let scrollView else { return }
            measure()
            scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: -openTopInset), animated: true)
        }
    }
}
#endif

@MainActor
final class CmsPageLoader: ObservableObject {
    enum State {
        case idle
        case loading
        case loaded(CmsPage)
        case error(String)
        /// Authenticated fine upstream but not a member of this portal (or
        /// blocked / uninvited on an invite-only portal). Distinct from
        /// `.error` so hosts show an access message, not a failure.
        case noAccess(String)
    }

    @Published var state: State = .idle
    /// Pages navigable in this session (visitor mode: public pages only).
    private(set) var availablePages: [CmsPage] = [] {
        didSet {
            runtime.pageTitles = Dictionary(availablePages.map { ($0.slug, $0.title) }, uniquingKeysWith: { first, _ in first })
        }
    }
    /// The portal shell page (cms.shellPageId), when designated and visible.
    private(set) var shellPage: CmsPage?
    let runtime: CmsRuntime

    /// Design-mode store — non-nil when the caller may design (owner fetch,
    /// or a portal member with `canDesign`). Drives the edit toggle.
    private(set) var designController: CmsDesignController?
    /// Definition's designated shell id — kept so design edits can
    /// re-resolve the shell from the mutated pages tree. `CmsAppView` reads
    /// the site's tab bar from this page.
    private(set) var shellPageId: String?
    /// The site's landing page, after its design is applied.
    private(set) var landingPageId: String?
    /// Every page, auth-hidden ones included: a page's own shell may be one
    /// the visitor can't route to (the shell is chrome, not content).
    private(set) var allPages: [CmsPage] = []
    /// The visitor's design and the site's own shell, kept so design edits
    /// (which work on the stored pages, as the web designer does) re-apply it.
    private var activeDesign: CmsPortalDesign?
    private var storedShellPageId: String?
    /// Visitor mode membership — kept so design edits re-filter page
    /// visibility with the same role context.
    private var membership: CmsPortalMembership?

    private let cmsId: String
    private let client: CmsClient
    private let visitorSiteKey: String?

    init(cmsId: String, clientConfig: CmsClientConfig, visitorSiteKey: String? = nil) {
        self.cmsId = cmsId
        self.visitorSiteKey = visitorSiteKey
        self.client = CmsClient(config: clientConfig)
        self.runtime = CmsRuntime(cmsId: cmsId, client: self.client)
    }

    func load(pageSlug requested: String?) {
        // An empty slug opens the site at its landing page.
        let pageSlug = requested?.isEmpty == true ? nil : requested
        if case .loading = state { return }
        if case .loaded = state { return }
        state = .loading
        Task {
            if let publishableKey = visitorSiteKey {
                await loadAsVisitor(publishableKey: publishableKey, pageSlug: pageSlug)
                return
            }
            do {
                let fetched = try await client.fetchDefinitionRaw(cmsId: cmsId)
                let definition = fetched.definition
                self.runtime.themeConfig = definition.theme
                self.runtime.theme = CmsPortalTheme(config: definition.theme, effectiveDark: self.runtime.effectiveDark)
                // Resolve the RLS site-key context: queries run with the site
                // key linked to this CMS, matching how the portal runs them.
                if client.siteKeyId == nil,
                   let keys = try? await client.listSiteKeys(),
                   let linked = keys.first(where: { $0.cmsDefinitionId == cmsId }) {
                    client.siteKeyId = linked.id
                    client.siteKeyPublishable = linked.publishableKey
                }
                // The admin fetch worked: the caller owns the site and sees
                // it as its designer does. Their member row, when they have
                // one, gives the email the bell and account menu use.
                self.runtime.canDesign = true
                if let publishable = client.siteKeyPublishable {
                    self.runtime.membership = try? await client.fetchPortalMembership(siteKey: publishable)
                }
                self.runtime.queryDefs = Dictionary(
                    (definition.queries ?? []).map { ($0.slug, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                self.runtime.viewDefs = Dictionary(
                    (definition.views ?? []).filter(\.isUsable).map { ($0.slug, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                self.runtime.columnViews = Dictionary(
                    (definition.columnViews ?? []).map { ($0.slug, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                self.runtime.cardViews = Dictionary(
                    (definition.cardViews ?? []).map { ($0.slug, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                self.runtime.mutationDefs = Dictionary(
                    (definition.mutations ?? []).map { ($0.slug, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                self.runtime.functionDefs = Dictionary(
                    (definition.functions ?? []).map { ($0.slug, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                self.activeDesign = CmsPortalDesigns.chosen(cmsId: cmsId, designs: definition.portalConfig?.designs ?? [])
                self.storedShellPageId = definition.shellPageId
                let designed = CmsPortalDesigns.apply(
                    pages: definition.pages ?? [],
                    shellPageId: definition.shellPageId,
                    landingPageId: definition.landingPageId,
                    design: activeDesign
                )
                let pages = designed.pages
                self.availablePages = pages
                self.allPages = pages
                self.shellPageId = designed.shellPageId
                self.landingPageId = designed.landingPageId
                self.shellPage = designed.shellPageId.flatMap { id in pages.first { $0.id == id } }
                // Design controller: the admin fetch succeeded, so the
                // caller is the owner — wire the owner save path.
                self.wireDesignController(CmsDesignController(
                    cmsId: cmsId, client: client, rawPages: fetched.rawPages
                ))
                let landing = designed.landingPageId.flatMap { id in pages.first { $0.id == id } }
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
        let result = await SiteKeyValidator.validate(siteKey: publishableKey, baseURL: baseURL, origin: client.origin)
        guard let token = result.sessionToken, let configJSON = result.configJSON,
              let configData = configJSON.data(using: .utf8) else {
            state = .error("Site key validation failed")
            return
        }
        client.siteKeyPublishable = publishableKey

        // Member mode: the host app's credentials (e.g. WAC's secret/secret-id)
        // or a token from the site's own sign-in (`portalTokenProvider`)
        // identify the user. Queries carry those — NOT the anonymous session
        // token — so the worker authenticates the member and applies their row
        // rules; the publishable key travels in the body for owner-context
        // hydration. Anonymous visitor mode keeps the session-token path
        // unchanged.
        var membership: CmsPortalMembership?
        // A site that signs people in by an emailed code (portalAuth 'email'):
        // its own sign-in, kept in the Keychain. Signed out, the person is a
        // visitor; signed in, a member or a guest (resolveSiteSignIn).
        visitorToken = token
        if !client.signsInAsMember, runtime.siteSignIn == nil,
           CmsSiteSignInConfig.signsInByEmail(configJSON: configData) {
            let signIn = CmsSiteSignIn(siteKey: publishableKey, origin: client.origin ?? RipulDomain.demoURL)
            signIn.onChange = { [weak self] _ in
                Task { @MainActor in await self?.siteSignInChanged() }
            }
            runtime.siteSignIn = signIn
            if runtime.onSignOut == nil {
                runtime.onSignOut = { [weak signIn] in Task { await signIn?.signOut() } }
            }
        }
        if let signIn = runtime.siteSignIn {
            membership = await resolveSiteSignIn(signIn, publishableKey: publishableKey)
        } else if client.signsInAsMember {
            client.visitorSessionToken = nil
            client.siteKeyId = publishableKey
            do {
                let me = try await client.fetchPortalMembership(siteKey: publishableKey)
                guard me.isMember else {
                    state = .noAccess("You don't have access to this portal yet. Ask an administrator to invite you.")
                    return
                }
                membership = me
            } catch let CmsClientError.http(code, _) where code == 401 || code == 403 {
                // Invite-only portals refuse non-members and blocked members
                // at the auth gate — a definitive access verdict.
                state = .noAccess("You don't have access to this portal. Ask an administrator to invite you.")
                return
            } catch {
                // Anything else (offline, 5xx, missing credentials) is a
                // FAILURE, surfaced as an error with its cause — it must
                // never masquerade as an access verdict.
                state = .error("Membership check failed: \(error.localizedDescription)")
                return
            }
        } else if client.visitorSendsSiteKey {
            // The publishable key as X-Site-Key: the worker's site-key routes
            // run exposed queries with RLS held to that key.
            client.visitorSessionToken = nil
            client.visitorSiteKeyHeader = publishableKey
            client.siteKeyId = nil
        } else {
            client.visitorSessionToken = token
            // Body siteKeyId is unnecessary: the server derives the RLS site
            // key from the session token's auth context.
            client.siteKeyId = nil
        }
        self.membership = membership
        runtime.membership = membership
        runtime.canDesign = membership?.canDesign ?? false

        struct VisitorConfig: Codable {
            struct Cms: Codable {
                var pages: [CmsPage]?
                var queries: [CmsQueryDef]?
                var views: [CmsViewDef]?
                var theme: CmsPortalThemeConfig?
                var shellPageId: String?
                var landingPageId: String?
                var columnViews: [CmsColumnView]?
                var cardViews: [CmsCardView]?
                var mutations: [CmsMutationDef]?
                var functions: [CmsFunctionDef]?
            }
            var cmsDefinitionId: String?
            var cms: Cms?
            var portalConfig: CmsPortalConfig?
        }
        guard let config = try? JSONDecoder().decode(VisitorConfig.self, from: configData),
              let cms = config.cms else {
            state = .error("Site key has no embedded CMS config")
            return
        }
        runtime.themeConfig = cms.theme
        runtime.theme = CmsPortalTheme(config: cms.theme, effectiveDark: runtime.effectiveDark)
        runtime.queryDefs = Dictionary(
            (cms.queries ?? []).map { ($0.slug, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        runtime.viewDefs = Dictionary(
            (cms.views ?? []).filter(\.isUsable).map { ($0.slug, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        runtime.columnViews = Dictionary(
            (cms.columnViews ?? []).map { ($0.slug, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        runtime.cardViews = Dictionary(
            (cms.cardViews ?? []).map { ($0.slug, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        runtime.mutationDefs = Dictionary(
            (cms.mutations ?? []).map { ($0.slug, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        runtime.functionDefs = Dictionary(
            (cms.functions ?? []).map { ($0.slug, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        activeDesign = CmsPortalDesigns.chosen(cmsId: cmsId, designs: config.portalConfig?.designs ?? [])
        storedShellPageId = cms.shellPageId
        let designed = CmsPortalDesigns.apply(
            pages: cms.pages ?? [],
            shellPageId: cms.shellPageId,
            landingPageId: cms.landingPageId,
            design: activeDesign
        )
        let allPages = designed.pages
        let visible = allPages.filter { CmsPageVisibility.canView($0, membership: membership) }
        availablePages = visible
        self.allPages = allPages
        shellPageId = designed.shellPageId
        landingPageId = designed.landingPageId
        // The shell is CHROME, not routable content — resolve it from ALL
        // pages. Its own auth flag doesn't gate it (the web router renders
        // the shell for every visitor and gates only the routed pages;
        // WAC's shell page is auth-defaulted and was silently dropped here).
        shellPage = designed.shellPageId.flatMap { id in allPages.first { $0.id == id } }
        // Delegated design: a member with canDesign edits through the
        // per-site design endpoint. The pages go to the controller RAW (the
        // embedded config is the complete pages array — the save replaces
        // it wholesale, so nothing the renderer can't see may be dropped).
        if membership?.canDesign == true {
            struct RawConfig: Codable {
                struct Cms: Codable { var pages: [CmsJSON]? }
                var cms: Cms?
            }
            let rawPages = (try? JSONDecoder().decode(RawConfig.self, from: configData))?.cms?.pages ?? []
            wireDesignController(CmsDesignController(
                cmsId: cmsId, client: client, rawPages: rawPages,
                delegatedSiteKey: publishableKey
            ))
        }
        let landing = designed.landingPageId.flatMap { id in visible.first { $0.id == id } }
        if let pageSlug {
            if let page = visible.first(where: { $0.slug == pageSlug }) {
                present(page, animated: false)
            } else if allPages.contains(where: { $0.slug == pageSlug }) {
                state = .error(
                    membership == nil
                        ? "Page requires sign-in — not visible to anonymous visitors"
                        : "Page not visible to your role"
                )
            } else {
                state = .error("No page with slug '\(pageSlug)'")
            }
        } else if let entry = landing ?? visible.first {
            present(entry, animated: false)
        } else {
            state = .error(membership == nil ? "No public pages on this portal" : "No pages visible to your role")
        }
    }

    /// The visitor's site-key session token, kept for a site whose own
    /// sign-in can come and go (an emailed-code site).
    private var visitorToken: String?

    /// Who the person is on an emailed-code site, and how its queries run:
    /// signed in as one of its members, as that member (the session as the
    /// Bearer); signed in as a guest (not a member: a guest who signed in to
    /// see a booking), or signed out, as a visitor. A session the server no
    /// longer knows is forgotten. A failed lookup leaves them a visitor, as the
    /// web's portal treats it (`isMember: false`).
    private func resolveSiteSignIn(_ signIn: CmsSiteSignIn, publishableKey: String) async -> CmsPortalMembership? {
        client.visitorSiteKeyHeader = nil
        client.siteSessionToken = nil
        client.visitorSessionToken = visitorToken
        client.siteKeyId = nil
        guard signIn.isSignedIn else { return nil }
        client.siteSessionToken = { await MainActor.run { signIn.token() } }
        client.visitorSessionToken = nil
        client.siteKeyId = publishableKey
        let me: CmsPortalMembership
        do {
            me = try await client.fetchPortalMembership(siteKey: publishableKey)
        } catch CmsClientError.http(401, _) {
            signIn.forget()
            me = CmsPortalMembership(isMember: false)
        } catch {
            me = CmsPortalMembership(isMember: false, email: signIn.email)
        }
        if !me.isMember {
            client.siteSessionToken = nil
            client.visitorSessionToken = visitorToken
            client.siteKeyId = nil
        }
        var known = me
        if known.email == nil { known.email = signIn.email }
        return signIn.isSignedIn ? known : nil
    }

    /// Signed in or out: read who the person is again and which pages they
    /// can open, keeping the pages on screen (no reload).
    func siteSignInChanged() async {
        guard let signIn = runtime.siteSignIn, let publishableKey = visitorSiteKey else { return }
        let membership = await resolveSiteSignIn(signIn, publishableKey: publishableKey)
        self.membership = membership
        runtime.membership = membership
        runtime.canDesign = membership?.canDesign ?? false
        availablePages = allPages.filter { CmsPageVisibility.canView($0, membership: membership) }
        runtime.pageTitles = Dictionary(availablePages.map { ($0.slug, $0.title) }, uniquingKeysWith: { first, _ in first })
        runtime.signInGeneration += 1
    }

    /// Swap the rendered page (native routing). Unknown or auth-hidden
    /// slugs are ignored — same outcome as a dead link on the web.
    func show(pageSlug: String) {
        guard let page = availablePages.first(where: { $0.slug == pageSlug }) else { return }
        present(page, animated: true)
    }

    // MARK: - Design mode

    private func wireDesignController(_ controller: CmsDesignController) {
        controller.onPagesDidChange = { [weak self] in self?.designPagesDidChange() }
        designController = controller
    }

    /// Re-present the rendered page(s) after a design edit: decode the
    /// mutated tree, refresh shell + visibility, and swap the loaded page /
    /// outlet for their updated values so blocks re-render with the new
    /// props. Identity is stable (same page ids), so scroll position and
    /// runtime state survive — the web's optimistic local update reading.
    private func designPagesDidChange() {
        guard let controller = designController else { return }
        let designed = CmsPortalDesigns.apply(
            pages: controller.typedPages, shellPageId: storedShellPageId,
            landingPageId: nil, design: activeDesign
        )
        let typed = designed.pages
        allPages = typed
        if let current = shellPage?.id {
            shellPage = typed.first { $0.id == current }
        }
        if visitorSiteKey != nil {
            availablePages = typed.filter { CmsPageVisibility.canView($0, membership: membership) }
        } else {
            availablePages = typed
        }
        if let outlet = runtime.outletPage {
            if let updated = typed.first(where: { $0.id == outlet.id }) {
                runtime.outletPage = updated
            }
            if case .loaded(let shell) = state,
               let updatedShell = typed.first(where: { $0.id == shell.id }) {
                state = .loaded(updatedShell)
            }
        } else if case .loaded(let current) = state,
                  let updated = typed.first(where: { $0.id == current.id }) {
            state = .loaded(updated)
        }
    }

    /// Present a page — the shell pattern's fork. With a designated shell,
    /// the SHELL renders as persistent chrome and the target page renders
    /// inside its pageOutlet (an outlet-only swap when the shell is already
    /// up, so nav drawers and their edge-swipe registrations persist). The
    /// shell itself (or no shell) renders standalone.
    private func present(_ page: CmsPage, animated: Bool) {
        // PortalPageView's layoutShell: none when the page hides it, else the
        // page's own shell, else the site's.
        let shell: CmsPage? = page.hideShell == true ? nil
            : page.shellPageId.flatMap { id in allPages.first { $0.id == id } }
                ?? shellPageId.flatMap { id in allPages.first { $0.id == id } }
        if shell?.id != shellPage?.id {
            shellPage = shell
            runtime.outletPage = nil
        }
        if let shell, page.id != shell.id {
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
    func applyPageContext(_ page: CmsPage) {
        runtime.currentPageSlug = page.slug
        runtime.pageSidebarIcon = page.mobileBurgers == "none" ? false : (page.nativeSidebarIcon ?? false)
        runtime.pageSidebarEdgeSwipe = page.nativeSidebarEdgeSwipe ?? true
        // Populate columnDefs registry from this page's columnDefs blocks —
        // native twin of the web's GridApiRegistry (blocks register at render time).
        if let blocks = page.blocks {
            runtime.columnDefs = Dictionary(
                blocks.allBlocks()
                    .filter { $0.type == "columnDefs" }
                    .compactMap { block -> (String, [CmsJSON])? in
                        guard let slug = block.slug,
                              case .array(let cols) = block.props["columns"] ?? .null
                        else { return nil }
                        return (slug, cols)
                    },
                uniquingKeysWith: { first, _ in first }
            )
        } else {
            runtime.columnDefs = [:]
        }
    }
}

/// Outer positioning layer — owns the drag gesture and persisted offset.
/// Intentionally NOT @ObservedObject on runtime: runtime @Published changes
/// (selectedBlockId, isDesignMode, etc.) must not re-render this view or
/// they interfere with @GestureState and cause the pill to flicker during drag.
private struct CmsDesignFloatingToolbar: View {
    let runtime: CmsRuntime
    let controller: CmsDesignController?
    @Binding var showDiagnostics: Bool

    @AppStorage("io.ripul.cms.toolbar.dx") private var savedDX: Double = 0
    @AppStorage("io.ripul.cms.toolbar.dy") private var savedDY: Double = 0
    @GestureState private var liveTranslation: CGSize = .zero

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            HStack(spacing: 0) {
                Spacer()
                CmsDesignPill(runtime: runtime, controller: controller, showDiagnostics: $showDiagnostics)
                    .padding(16)
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 4)
                            .updating($liveTranslation) { val, state, _ in state = val.translation }
                            .onEnded { val in
                                savedDX += Double(val.translation.width)
                                savedDY += Double(val.translation.height)
                            }
                    )
            }
        }
        .offset(x: CGFloat(savedDX) + liveTranslation.width, y: CGFloat(savedDY) + liveTranslation.height)
    }
}

/// Inner pill — observes runtime for button state and sheet presentation.
/// Re-renders here are fine; they don't touch the gesture layer above.
private struct CmsDesignPill: View {
    @ObservedObject var runtime: CmsRuntime
    let controller: CmsDesignController?
    @Binding var showDiagnostics: Bool

    var body: some View {
        pillContent
            .ripulSheet(isPresented: inspectorOpen) {
                if let blockId = runtime.selectedBlockId, let ctrl = controller {
                    CmsPropertyInspectorView(blockId: blockId, controller: ctrl)
                        .environmentObject(runtime)
                        .inspectorDetents()
                }
            }
    }

    private var inspectorOpen: Binding<Bool> {
        Binding(
            get: { controller != nil && runtime.isDesignMode && runtime.selectedBlockId != nil },
            set: { open in
                if !open {
                    runtime.selectedBlockId = nil
                    Task { await controller?.saveNow() }
                }
            }
        )
    }

    @ViewBuilder
    private var pillContent: some View {
        HStack(spacing: 2) {
            if controller != nil {
                pillButton(icon: "pencil", label: "Edit", active: runtime.isDesignMode) {
                    runtime.isDesignMode = true
                }
                pillButton(icon: "eye", label: "Preview", active: !runtime.isDesignMode) {
                    guard runtime.isDesignMode else { return }
                    runtime.isDesignMode = false
                    runtime.selectedBlockId = nil
                    Task { await controller?.saveNow() }
                }
                pillDivider
            }
            pillButton(icon: "ladybug", label: nil, active: false) {
                showDiagnostics = true
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background { pillBackground }
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
        .cmsInspectorID("Cms.designToolbar")
    }

    @ViewBuilder
    private var pillBackground: some View {
        if #available(iOS 26, macOS 26, *) {
            Capsule().glassEffect(.clear)
        } else {
            Capsule().fill(.ultraThinMaterial)
        }
    }

    private func pillButton(icon: String, label: String?, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                if let label {
                    Text(label)
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .foregroundStyle(active ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(active ? Color.accentColor.opacity(0.15) : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var pillDivider: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.25))
            .frame(width: 1, height: 16)
            .padding(.horizontal, 2)
    }
}

private extension View {
    /// Inspector sheet sizing — medium/large detents where available, with
    /// background interaction so tapping another block swaps the sheet's
    /// subject without dismissing (the web's click-around-the-panel loop).
    @ViewBuilder
    func inspectorDetents() -> some View {
        self
            .ripulSheet(.page, detents: [.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
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
                        .onChanged { changed($0.translation.width) }
                        .onEnded { ended($0.translation.width, predicted: $0.predictedEndTranslation.width) }
                )
        }
    }

    private func changed(_ dx: CGFloat) {
        if mode == .idle {
            if claims, let slot {
                mode = .opening
                runtime.beginInteractiveDrawer(edge: edge, slot: slot)
            } else if onExit != nil {
                mode = .exiting
            } else {
                return
            }
        }
        if mode == .opening {
            // UIKit moves it (`CmsDrawerTrack`); nothing here re-renders.
            runtime.dragDrawer(pulled: travel(dx), edge: edge)
        }
    }

    private func ended(_ dx: CGFloat, predicted: CGFloat) {
        defer { mode = .idle }
        let pulled = travel(dx)
        let predicted = travel(predicted)
        switch mode {
        case .idle:
            break
        case .exiting:
            if pulled > 60 || predicted > 120 {
                onExit?()
            }
        case .opening:
            // The predicted end over the drag's last stretch stands in for a velocity.
            runtime.releaseDrawer(velocity: (predicted - pulled) * 4, edge: edge)
        }
    }
}



/// Where an edge drag may start: within 22 points of the screen's edge.
enum CmsEdgeDrag {
    static let width: CGFloat = 22

    static func startsAtEdge(_ x: CGFloat, width screen: CGFloat, leading: Bool) -> Bool {
        leading ? x <= width : x >= screen - width
    }
}

/// `titleDisplay: 'hidden'`: no large title, and the bar stays hidden at the
/// top of the scroll. A pushed page keeps its bar for its back button, with
/// no title.
struct CmsPageTitleDisplay: ViewModifier {
    let hidden: Bool
    @Environment(\.isPresented) private var pushed

    func body(content: Content) -> some View {
        #if os(iOS)
        if hidden {
            if pushed {
                content.navigationBarTitleDisplayMode(.inline)
            } else {
                content.toolbar(.hidden, for: .navigationBar)
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// The runtime's notice: a capsule at the foot of the page, the success
/// message with a run's warning beside it.
struct CmsNoticeView: View {
    @ObservedObject var runtime: CmsRuntime

    var body: some View {
        if let notice = runtime.notice {
            VStack(alignment: .leading, spacing: 6) {
                if let message = notice.message {
                    Label(message, systemImage: "checkmark.circle.fill")
                }
                if let warning = notice.warning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.ripul(.warning))
                        .cmsInspectorID("Cms.notice.warning")
                }
            }
            .font(.ripul(.subheadline))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .combine)
            .cmsInspectorID("Cms.notice")
        }
    }
}


/// Reports the pinned block's height for its place in the list: measured with
/// `onGeometryChange` and written straight into the object the place observes
/// (`CmsPinnedLayers` hands it down). A `GeometryReader` preference set during
/// layout kept its first value on iOS 27 when the block was first laid out
/// narrow (117 points, as a tab appears). A preference fed from state was no
/// better: it changed in the frame that read it ("Bound preference
/// CmsPinnedHeightKey tried to update multiple times per frame"), SwiftUI
/// dropped the later values, and WAC Next's Home kept the 926-point height its
/// header had while the page first laid out, so every card sat below the
/// screen until something laid the page out again (3 November 2026).
struct CmsPinnedHeightReport: ViewModifier {
    @Environment(\.cmsPinnedHeight) private var place
    @Environment(\.cmsPinnedLiveResize) private var liveResize

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                guard let place, place.value != height else { return }
                // Once known, a change eases with the block (a calendar switching
                // to its slim row), so what follows moves with it; a height
                // following a gesture is taken at once, frame by frame.
                if place.value == nil || liveResize?.active == true {
                    place.value = height
                } else {
                    withAnimation(.snappy) { place.value = height }
                }
            }
    }
}
