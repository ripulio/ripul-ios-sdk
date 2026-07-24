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
                .overlay {
                    CmsDesignFloatingToolbar(
                        runtime: loader.runtime,
                        controller: loader.designController,
                        showDiagnostics: $showDiagnostics
                    )
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
                //
                // When embedded in a host that owns navigation
                // (edgeSwipeEnabled == false) the CMS claims NEITHER edge, so
                // the host's slide-out and the nav back-swipe keep the left
                // edge. The drawer overlay stays — it only shows when opened
                // by a burger tap, never by an edge grab.
                .overlay(alignment: .trailing) {
                    if edgeSwipeEnabled {
                        CmsEdgeSwipeStrip(runtime: loader.runtime, edge: .trailing, onExit: nil)
                    }
                }
                .overlay {
                    CmsDrawerOverlay(runtime: loader.runtime)
                }
                .overlay(alignment: .leading) {
                    if edgeSwipeEnabled {
                        CmsEdgeSwipeStrip(runtime: loader.runtime, edge: .leading, onExit: onEdgeExit)
                    }
                }
            }
        }
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
    private(set) var availablePages: [CmsPage] = []
    /// The portal shell page (cms.shellPageId), when designated and visible.
    private(set) var shellPage: CmsPage?
    let runtime: CmsRuntime

    /// Design-mode store — non-nil when the caller may design (owner fetch,
    /// or a portal member with `canDesign`). Drives the edit toggle.
    private(set) var designController: CmsDesignController?
    /// Definition's designated shell id — kept so design edits can
    /// re-resolve the shell from the mutated pages tree.
    private var shellPageId: String?
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
                self.runtime.queryDefs = Dictionary(
                    uniqueKeysWithValues: (definition.queries ?? []).map { ($0.slug, $0) }
                )
                self.runtime.columnViews = Dictionary(
                    (definition.columnViews ?? []).map { ($0.slug, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                self.runtime.cardViews = Dictionary(
                    (definition.cardViews ?? []).map { ($0.slug, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                let pages = definition.pages ?? []
                self.availablePages = pages
                self.shellPageId = definition.shellPageId
                self.shellPage = definition.shellPageId.flatMap { id in pages.first { $0.id == id } }
                // Design controller: the admin fetch succeeded, so the
                // caller is the owner — wire the owner save path.
                self.wireDesignController(CmsDesignController(
                    cmsId: cmsId, client: client, rawPages: fetched.rawPages
                ))
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
        client.siteKeyPublishable = publishableKey

        // Opaque member mode: the host app's credentials (e.g. WAC's
        // secret/secret-id) identify the user. Queries carry those headers —
        // NOT the anonymous session token — so the worker authenticates the
        // member and binds @principalId for RLS; the publishable key travels
        // in the body for owner-context hydration. Anonymous visitor mode
        // keeps the session-token path unchanged.
        var membership: CmsPortalMembership?
        if client.hasPortalCredentials {
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
        } else {
            client.visitorSessionToken = token
            // Body siteKeyId is unnecessary: the server derives the RLS site
            // key from the session token's auth context.
            client.siteKeyId = nil
        }
        self.membership = membership

        struct VisitorConfig: Codable {
            struct Cms: Codable {
                var pages: [CmsPage]?
                var queries: [CmsQueryDef]?
                var theme: CmsPortalThemeConfig?
                var shellPageId: String?
                var landingPageId: String?
                var columnViews: [CmsColumnView]?
                var cardViews: [CmsCardView]?
            }
            var cmsDefinitionId: String?
            var cms: Cms?
        }
        guard let config = try? JSONDecoder().decode(VisitorConfig.self, from: configData),
              let cms = config.cms else {
            state = .error("Site key has no embedded CMS config")
            return
        }
        runtime.themeConfig = cms.theme
        runtime.theme = CmsPortalTheme(config: cms.theme, effectiveDark: runtime.effectiveDark)
        runtime.queryDefs = Dictionary(
            uniqueKeysWithValues: (cms.queries ?? []).map { ($0.slug, $0) }
        )
        runtime.columnViews = Dictionary(
            (cms.columnViews ?? []).map { ($0.slug, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        runtime.cardViews = Dictionary(
            (cms.cardViews ?? []).map { ($0.slug, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let allPages = cms.pages ?? []
        let visible = allPages.filter { CmsPageVisibility.canView($0, membership: membership) }
        availablePages = visible
        shellPageId = cms.shellPageId
        // The shell is CHROME, not routable content — resolve it from ALL
        // pages. Its own auth flag doesn't gate it (the web router renders
        // the shell for every visitor and gates only the routed pages;
        // WAC's shell page is auth-defaulted and was silently dropped here).
        shellPage = cms.shellPageId.flatMap { id in allPages.first { $0.id == id } }
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
        let landing = cms.landingPageId.flatMap { id in visible.first { $0.id == id } }
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
        let typed = controller.typedPages
        shellPage = shellPageId.flatMap { id in typed.first { $0.id == id } }
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
            .sheet(isPresented: inspectorOpen) {
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
            .presentationDetents([.medium, .large])
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
