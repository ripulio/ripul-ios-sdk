import Foundation
import SwiftUI

/// Page-scoped runtime state for the native CMS renderer — the Swift twin of
/// the web's BlockDataContext (query cache + paramSources resolution) +
/// QuerySelectionContext (row selection) + ParameterContext (named typed
/// filter variables). One instance per rendered page.
///
/// Reactive model: control blocks write selections / parameters; the runtime
/// walks the query definitions' `paramSources`, re-resolves bind params for
/// affected queries, and re-runs them after the source-configured debounce
/// (default 300 ms, mirroring the web). Old rows stay visible while a refetch
/// is in flight.
@MainActor
public final class CmsRuntime: ObservableObject {
    public enum QueryState {
        case idle
        case loading
        /// Blocked on an unresolved param — carries the human-readable reason.
        case waiting(String)
        case ok(CmsQueryResult)
        case error(String)
    }

    public let cmsId: String
    public let client: CmsClient

    /// What the host app does for a card's `open: { host: <name> }` (`CmsAppView(hostActions:)`).
    public var hostActions: [String: @MainActor () -> Void] = [:]

    /// Query metadata (paramSources) — set by the page loader from the
    /// fetched definition before any block renders.
    public var queryDefs: [String: CmsQueryDef] = [:]
    /// The site's views (`CmsDefinition.views`), by slug. A view's slug works
    /// wherever a query's does (CmsViews.swift).
    public var viewDefs: [String: CmsViewDef] = [:]
    /// Each loaded view's rows and per-row source statuses, as they stream in.
    @Published private(set) var viewResults: [String: CmsViewResult] = [:]
    /// Shared column views (columnViewRef target), keyed by slug — set by the
    /// loader from the definition; blocks resolve their `columnViewRef`.
    public var columnViews: [String: CmsColumnView] = [:]
    /// Shared card views (cardViewRef target), keyed by slug — set by the
    /// loader; the grid's cards projection resolves its `cardViewRef`.
    public var cardViews: [String: CmsCardView] = [:]
    /// The signed-in member (role, email), when known — nav visibility, the
    /// account menu and the bell's read records read it.
    @Published public var membership: CmsPortalMembership?
    /// The owner path (admin fetch) or a member allowed to design: sees every
    /// nav item, as a designer does on the web.
    public var canDesign = false
    /// Title of every page the visitor can open, by slug — links that name a
    /// page (a notification's, an account menu entry) read and check it here.
    public var pageTitles: [String: String] = [:]
    /// An `agentChat` with `fab` on this page: the page draws its floating
    /// button. Registered by the block while it is on screen.
    @Published public var floatingChat: CmsBlock?
    /// The shell's floating chat, which an app with no shell (CmsAppView)
    /// keeps on every tab, as the web's pill is on every page. A page's own
    /// floating chat comes first.
    @Published public var shellChat: CmsBlock?
    /// The shell's chat is in the tab bar's bottom accessory (iOS 26): the
    /// floating button is not drawn for it.
    @Published public var shellChatInAccessory = false
    /// The accessory's tap: CmsAppView presents the shell's chat.
    @Published public var shellChatOpen = false
    /// Blocks each Page tabs block hides (closed tabs) and floats (a chat as
    /// the floating button), by block id or slug — pageTabsStore.ts. Hidden
    /// blocks stay mounted, so they keep what they loaded.
    @Published public private(set) var tabsHidden: [String: Set<String>] = [:]
    @Published public private(set) var tabsFloating: [String: Set<String>] = [:]

    public func setTabsHidden(_ owner: String, _ refs: Set<String>) {
        if tabsHidden[owner] != refs { tabsHidden[owner] = refs.isEmpty ? nil : refs }
    }

    public func setTabsFloating(_ owner: String, _ refs: Set<String>) {
        if tabsFloating[owner] != refs { tabsFloating[owner] = refs.isEmpty ? nil : refs }
    }

    func isTabHidden(_ block: CmsBlock) -> Bool {
        tabsHidden.values.contains { $0.contains(block.id) || (block.slug.map($0.contains) ?? false) }
    }

    func isTabFloating(_ block: CmsBlock) -> Bool {
        tabsFloating.values.contains { $0.contains(block.id) || (block.slug.map($0.contains) ?? false) }
    }

    /// The page's chat blocks by slug, registered while on screen, so a block
    /// can ask one (askChat) wherever it sits.
    public var chatBlocks: [String: CmsBlock] = [:]

    /// A question for one of the page's chats: it opens in a fresh
    /// conversation that sends the prompt at once (the web's askChat).
    public struct ChatAsk: Identifiable {
        public let id = UUID()
        public let block: CmsBlock
        public let prompt: String
    }
    @Published public var chatAsk: ChatAsk?

    /// Ask the chat block `slug` a question. False when no such chat is on the page.
    @discardableResult
    public func ask(chat slug: String, prompt: String) -> Bool {
        guard let block = chatBlocks[slug], !prompt.isEmpty else { return false }
        chatAsk = ChatAsk(block: block, prompt: prompt)
        return true
    }

    /// A top bar with `menuButton` is hosting the shell sidebar's drawer.
    @Published public var barHostsMenu = false
    /// Host hook for the account menu's Sign out; nil hides the item.
    public var onSignOut: (() -> Void)?
    /// The site's own sign-in by an emailed code, when its site key's
    /// `portalAuth` is 'email' (CmsSiteSignIn.swift): made by the loader.
    @Published public internal(set) var siteSignIn: CmsSiteSignIn?
    /// Ask for the sign-in sheet (CmsSiteSignInViews.swift), then open
    /// `returnTo` once signed in: a page that needs a signed-in member.
    @Published public var signInRequest: CmsSignInRequest?
    /// Counts sign-ins and sign-outs that changed who the person is, once the
    /// loader has read their pages again: the app's tabs and stacks follow it.
    @Published public internal(set) var signInGeneration = 0

    /// The booking routes for this site, as the signed-in person.
    public var bookings: CmsBookingsClient? {
        guard let signIn = siteSignIn else { return nil }
        return CmsBookingsClient(site: cmsId, token: { await MainActor.run { signIn.token() } })
    }
    /// Saved mutations, keyed by slug — set by the loader; action blocks run them.
    public var mutationDefs: [String: CmsMutationDef] = [:]
    /// Site calculation functions (`CmsDefinition.functions`), keyed by slug —
    /// record forms evaluate `fn.<slug>(...)` against them off the main thread.
    public var functionDefs: [String: CmsFunctionDef] = [:]
    /// Page-scoped shared column definitions (columnDefsRef target), keyed by
    /// block slug — populated at page-display time from the page's columnDefs
    /// blocks. Native twin of the web's GridApiRegistry pub-sub at render time.
    public var columnDefs: [String: [CmsJSON]] = [:]
    /// Portal theme — `color.*` tokens resolve against it. Set by the loader.
    /// Published, so a colour-scheme change redraws every block that reads it
    /// (before it was, only views that happened to redraw for another reason
    /// followed, and a screen was left half light, half dark).
    @Published public var theme = CmsPortalTheme(config: nil)
    /// Raw portal theme config, kept so the runtime can recompute `theme`
    /// when the OS color scheme changes (system mode follows `effectiveDark`).
    @Published public internal(set) var themeConfig: CmsPortalThemeConfig?
    /// Current effective dark-mode flag (OS color scheme) for system-mode themes.
    public private(set) var effectiveDark: Bool = false

    /// Recompute the portal theme with the current OS color-scheme.
    @MainActor
    public func updateEffectiveDark(_ effectiveDark: Bool) {
        self.effectiveDark = effectiveDark
        theme = CmsPortalTheme(config: themeConfig, effectiveDark: effectiveDark)
    }

    /// Resolve a colour value: theme token or CSS literal.
    public func color(_ value: String?) -> Color? {
        theme.resolve(value)
    }

    /// Text's colour: the value, else the site's text colour (never the system's black).
    public func textColor(_ value: String?) -> Color {
        theme.textColor(value)
    }

    /// Resolve a background fill: `color.gradient` → brand gradient, else a colour.
    public func fill(_ value: String?) -> AnyShapeStyle? {
        theme.fill(value)
    }

    /// Resolve a corner radius: `radius.*` token or CSS length.
    public func radius(_ value: String?) -> CGFloat? {
        theme.radius(value)
    }

    @Published public private(set) var queries: [String: QueryState] = [:]
    /// A choice list's rows for one set of its params (`optionsQuery.params`),
    /// keyed by `optionListKey`: run once and shared, so a form row that SwiftUI
    /// rebuilds while the request is out joins it rather than sending another.
    /// (A Form row on iPhone restarted its task every frame and sent 120 a
    /// second, each cancelled before it came back, 30 October 2026.)
    @Published public private(set) var optionLists: [String: QueryState] = [:]
    /// Selected rows per query slug. Control blocks also publish their output
    /// rows here under their block slug (calendar bounds, etc.).
    @Published public private(set) var selections: [String: [[String: CmsJSON]]] = [:]
    /// Named shared parameters — open JSON values shaped by their kind.
    @Published public private(set) var parameters: [String: CmsJSON] = [:]
    /// Active grid-view state per target grid slug — the native twin of the
    /// GridApiRegistry channel: a gridViewSwitcher writes a saved view's
    /// state snapshot; the grid block reads and honours what it can.
    @Published public private(set) var gridViewStates: [String: CmsJSON] = [:]
    /// Active view ID per target grid slug — set by the view switcher when a
    /// view is applied. The inspector uses this to route edits into the correct
    /// view definition (so changes persist across view switches).
    @Published public private(set) var gridViewActiveIds: [String: String] = [:]

    public func setGridViewActiveId(_ gridSlug: String, id: String) {
        gridViewActiveIds[gridSlug] = id
    }

    // MARK: - Design mode

    /// Edit/design mode — when true, every block renders selection chrome
    /// and taps select instead of interacting (the runtime IS the canvas —
    /// no forked designer surface). Toggled from `CmsPageView` and only
    /// offered when the loader produced a `CmsDesignController` (the caller
    /// may design: owner, or a portal member with `canDesign`).
    @Published public var isDesignMode = false
    /// The block selected for inspection — drives the inspector sheet.
    @Published public var selectedBlockId: String?

    /// Page-level slide-in drawer request — a sidebar layout's burger opens
    /// its column here; CmsPageView owns the overlay so the drawer covers
    /// the viewport (a block-scoped overlay would scroll with the page).
    public struct DrawerRequest {
        public enum Edge { case leading, trailing }
        public let edge: Edge
        public let slot: CmsPageBlocks
        /// Optional header title (modal drawers show title + close).
        public let title: String?
        /// Authored panel width; the overlay caps it to the viewport.
        public let width: CGFloat?
        /// Fired on ANY close route (scrim, drag, navigation) — the modal
        /// block clears its watched selection here.
        public let onDismiss: (() -> Void)?

        public init(edge: Edge, slot: CmsPageBlocks, title: String? = nil,
                    width: CGFloat? = nil, onDismiss: (() -> Void)? = nil) {
            self.edge = edge
            self.slot = slot
            self.title = title
            self.width = width
            self.onDismiss = onDismiss
        }
    }
    @Published public var openDrawer: DrawerRequest?

    /// A choice list's choice, kept here by its slug so every copy of the
    /// list (the page's offstage one that publishes at load, the drawer's)
    /// shows and keeps the same choice.
    public struct ChoiceState: Equatable {
        public var selection: [String]
        public var range: [String]?
    }
    @Published public var listChoices: [String: ChoiceState] = [:]

    /// A short note at the foot of the page: a form's `successMessage`, and
    /// a run's `warning` (a follow-up call that failed) beside it.
    public struct Notice: Equatable {
        public var message: String?
        public var warning: String?
    }
    @Published public var notice: Notice?
    private var noticeStamp = 0

    /// The success message; a warning already showing stays beside it.
    /// Set by `CmsAppView`: pushes a record form opened as a page onto the
    /// selected tab's stack (CmsMasthead.swift); false where it can't (a host
    /// tab), and the form opens as a sheet instead.
    var pushFormPage: ((UUID, @escaping () -> AnyView) -> Bool)?
    /// Pops a pushed record form, and the steps pushed after it.
    var closeFormPage: ((UUID) -> Void)?
    /// The pushed forms' views, by their route's id.
    var formPages: [UUID: () -> AnyView] = [:]

    public func showNotice(_ text: String) {
        guard !text.isEmpty else { return }
        DispatchQueue.main.async {
            withAnimation { self.notice = Notice(message: text, warning: self.notice?.warning) }
            self.scheduleNoticeEnd()
        }
    }

    /// A run's warning: shown at once, beside any message, and longer (6 s).
    public func showWarning(_ text: String) {
        guard !text.isEmpty else { return }
        DispatchQueue.main.async {
            withAnimation { self.notice = Notice(message: self.notice?.message, warning: text) }
            self.scheduleNoticeEnd()
        }
    }

    private func scheduleNoticeEnd() {
        noticeStamp += 1
        let stamp = noticeStamp
        let seconds: Double = notice?.warning != nil ? 6 : 3
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            if self.noticeStamp == stamp { withAnimation { self.notice = nil } }
        }
    }

    /// `openSidebar`: the current page's side region on that edge (`left`,
    /// the default, or `right`) as a drawer, as the edge swipe opens it.
    /// Nothing when the page has no region there.
    public func openSidebar(edge: String?) {
        let leading = edge != "right"
        guard let slot = leading ? edgeSwipeLeftSlot : edgeSwipeRightSlot else { return }
        openDrawer = .init(edge: leading ? .leading : .trailing, slot: slot)
    }

    /// Close the drawer through the one path that honours its dismiss hook:
    /// it springs to its edge (from wherever it is, mid-drag included), then
    /// goes.
    public func closeDrawer() {
        guard openDrawer != nil else { return }
        #if os(iOS)
        if let controller = drawerTrack.controller {
            drawerTrack.grab()
            drawerTrack.settle(open: false, width: controller.width) { [weak self] in self?.finishClosingDrawer() }
            return
        }
        #endif
        finishClosingDrawer()
    }

    /// The drawer has reached its edge: SwiftUI removes it.
    func finishClosingDrawer() {
        guard let dismissed = openDrawer else { return }
        openDrawer = nil
        drawerTrack.progress = 0
        dismissed.onDismiss?()
    }

    /// Where the drawer is. Not published: a finger moves it in UIKit, and
    /// SwiftUI hears only that it opened (`openDrawer`) and that it closed.
    public let drawerTrack = CmsDrawerTrack()

    /// An edge pan has taken hold: the drawer appears at its edge, placed by
    /// the finger from here on (`dragDrawer`, `releaseDrawer`).
    func beginInteractiveDrawer(edge: DrawerRequest.Edge, slot: CmsPageBlocks) {
        drawerTrack.grab()
        drawerTrack.progress = 0
        drawerTrack.startsInteractive = true
        openDrawer = .init(edge: edge, slot: slot)
    }

    /// How far the drawer is pulled, in points along its width.
    func dragDrawer(pulled: CGFloat, edge: DrawerRequest.Edge) {
        drawerTrack.drag(to: pulled / drawerWidth(edge))
    }

    /// The opening finger lifts, `velocity` points a second toward open.
    func releaseDrawer(velocity: CGFloat, edge: DrawerRequest.Edge) {
        drawerTrack.release(velocity: velocity, width: drawerWidth(edge)) { [weak self] in self?.finishClosingDrawer() }
    }

    /// The drawer's width: its view's once made, else its region's.
    func drawerWidth(_ edge: DrawerRequest.Edge) -> CGFloat {
        #if os(iOS)
        if let width = drawerTrack.controller?.width { return width }
        #endif
        return (edge == .leading ? edgeSwipeLeftWidth : edgeSwipeRightWidth) ?? CmsDrawerOverlay.panelWidth
    }

    // MARK: - Page navigation (native routing)

    /// In-portal navigation request — nav blocks publish, `CmsPageView`
    /// consumes (swaps the rendered page; the runtime and its
    /// selections/parameters survive, the web's SPA reading).
    public struct PageNavigation: Equatable {
        public let pageSlug: String
    }
    @Published public var pendingNavigation: PageNavigation?

    /// A run whose mutation has an `action.after` (a countdown, a summary, a
    /// page): CmsAppView draws it (CmsMutationAfterOverlay) and clears it.
    public struct PendingAfter: Identifiable, Equatable {
        public let id = UUID()
        public let after: CmsMutationAfter
        public let result: CmsJSON?
    }
    @Published public var pendingAfter: PendingAfter?

    private func announceAfter(_ slug: String, result: CmsJSON?) {
        if let after = CmsMutationAfter(mutationDefs[slug]?.action?.after) {
            pendingAfter = PendingAfter(after: after, result: result)
        }
    }
    /// Slug of the page currently rendered — drives nav active states.
    @Published public var currentPageSlug: String?
    /// Shell pattern: the routed page rendered inside the shell page's
    /// `pageOutlet` block. nil = no shell active (page renders standalone)
    /// or the shell itself is the active page.
    @Published public var outletPage: CmsPage?
    /// Current page's native sidebar affordances (page settings). Set with
    /// currentPageSlug before the page renders.
    public var pageSidebarIcon = false
    public var pageSidebarEdgeSwipe = true
    /// Sidebar slots registered for edge swipe — the sidebar layout
    /// publishes them as it renders; CmsPageView overlays screen-edge
    /// strips (content-level gestures lose the touch competition against
    /// nested scroll views). Cleared on page swap.
    @Published public var edgeSwipeLeftSlot: CmsPageBlocks?
    @Published public var edgeSwipeRightSlot: CmsPageBlocks?
    /// Which sidebar layout registered each slot: a layout releases only
    /// its own registration (a copy replaced as a page first loads used to
    /// clear its successor's equal slot as it disappeared).
    public var edgeSwipeLeftOwner: UUID?
    public var edgeSwipeRightOwner: UUID?
    /// The registered regions' drawer widths (the sidebar layout's
    /// `sidebarWidth`s); nil = the drawer's default.
    public var edgeSwipeLeftWidth: CGFloat?
    public var edgeSwipeRightWidth: CGFloat?
    /// Left-edge recognizer status for the runtime inspector.
    @Published public var leftEdgeDebug: String = "not installed"

    /// Grid-view request (`<gridSlug>` + view id) — the native reading of
    /// the `?view=` deep-link param and the `switchGridView` nav action.
    /// The matching gridViewSwitcher consumes and clears it.
    public struct GridViewRequest: Equatable {
        public let gridId: String
        public let viewId: String
    }
    @Published public var gridViewRequest: GridViewRequest?

    /// Navigate to a portal page, optionally carrying a `<gridSlug>:<viewId>`
    /// view ref (the web's grid-view deep link).
    public func navigate(toPage slug: String, viewRef: String? = nil) {
        if let viewRef {
            let parts = viewRef.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                gridViewRequest = GridViewRequest(gridId: parts[0], viewId: parts[1])
            }
        }
        closeDrawer()
        pendingNavigation = PageNavigation(pageSlug: slug)
    }

    public func setGridViewState(_ gridSlug: String, state: CmsJSON?) {
        if let state {
            gridViewStates[gridSlug] = state
        } else {
            gridViewStates.removeValue(forKey: gridSlug)
        }
    }

    /// View-state keys that are applied separately (sort, filter, query override)
    /// and are NOT merged into the block's visual props — mirrors
    /// CmsAgGridBlock.viewExcludedKeys.
    private static let agGridViewExcludedKeys: Set<String> = [
        "tableSlug", "querySlug", "editMutationSlug", "insertMutationSlug",
        "deleteMutationSlug", "filterModel", "sortModel", "columnOrder",
    ]

    /// Effective display props for a block: base props with the active view
    /// state merged on top, exactly as the renderer sees them. Only agGrid
    /// blocks carry view state; all others return base props unchanged.
    public func effectiveDisplayProps(for block: CmsBlock) -> [String: CmsJSON] {
        guard block.type == "agGrid" else { return block.props }
        let outputSlug = block.slug ?? block.id
        guard let viewState = gridViewStates[outputSlug]?.objectValue else { return block.props }
        var merged = block.props
        for (key, value) in viewState where !Self.agGridViewExcludedKeys.contains(key) {
            merged[key] = value
        }
        return merged
    }

    /// True when an agGrid block has an active saved-view override — used by
    /// the inspector to signal that displayed props reflect the view, not just
    /// the base block.
    public func hasActiveViewState(for block: CmsBlock) -> Bool {
        guard block.type == "agGrid" else { return false }
        return gridViewStates[block.slug ?? block.id] != nil
    }

    /// Patch one key in the active view state for the given grid slug — used
    /// by the inspector to make edits visible immediately when a view is active
    /// (the view state overrides the base block's prop; without this the edit
    /// snaps back because the view's old value wins the merge).
    public func updateViewStateProp(_ slug: String, key: String, value: CmsJSON?) {
        guard var state = gridViewStates[slug]?.objectValue else { return }
        if let value { state[key] = value } else { state.removeValue(forKey: key) }
        gridViewStates[slug] = .object(state)
    }

    /// Active read-query override per target grid slug — the native twin of the
    /// gridViewSwitcher's `queryOverride` channel. Kept separate from
    /// `gridViewStates` so it never leaks into the captured view-state blob;
    /// blank/absent = the grid keeps its authored base `querySlug`.
    @Published public private(set) var gridQueryOverrides: [String: String] = [:]

    /// Re-bind (or clear) a grid's read query — set by a gridViewSwitcher when
    /// a view carries its own `querySlug` and `switchesQuery` is on. The grid's
    /// editing (table / mutations) stays on its base binding, like the web.
    public func setGridQueryOverride(_ gridSlug: String, querySlug: String?) {
        if let querySlug, !querySlug.isEmpty {
            gridQueryOverrides[gridSlug] = querySlug
        } else {
            gridQueryOverrides.removeValue(forKey: gridSlug)
        }
    }

    /// Last successfully-applied param hash per query, to skip no-op refetches.
    private var appliedParamsHash: [String: String] = [:]
    private var debounceTasks: [String: Task<Void, Never>] = [:]
    /// Last seen result schema per slug — types selection-sourced params.
    private var schemas: [String: [CmsQueryResultColumn]] = [:]

    public init(cmsId: String, client: CmsClient) {
        self.cmsId = cmsId
        self.client = client
        // Restore persisted parameter values (the user's last filter
        // settings) — the runtime is rebuilt per page entry, so without this
        // every visit resets controls like the calendar predicate.
        if let data = UserDefaults.standard.data(forKey: Self.parametersKey(cmsId)),
           let restored = try? JSONDecoder().decode([String: CmsJSON].self, from: data) {
            parameters = restored
        }
    }

    private static func parametersKey(_ cmsId: String) -> String {
        "io.ripul.cms.parameters.\(cmsId)"
    }

    public func schema(for querySlug: String) -> [CmsQueryResultColumn]? {
        schemas[querySlug]
    }

    public func state(for querySlug: String) -> QueryState {
        queries[querySlug] ?? .idle
    }

    // MARK: - Loading

    public func optionList(_ querySlug: String, params: [String: CmsJSON]) -> QueryState {
        optionLists[Self.optionListKey(querySlug, params: params)] ?? .idle
    }

    /// Runs a choice list's query for these params unless it has run or is
    /// running (a failure stays until `reload`, so a rebuilt row can't retry
    /// in a loop); `reload` runs it again, e.g. after a choice is added.
    public func ensureOptionList(_ querySlug: String, params: [String: CmsJSON], reload: Bool = false) {
        guard !querySlug.isEmpty else { return }
        let key = Self.optionListKey(querySlug, params: params)
        if !reload, optionLists[key] != nil { return }
        optionLists[key] = .loading
        let typed = Self.textParams(params)
        Task {
            do {
                let result = try await client.runSavedQuery(cmsId: cmsId, querySlug: querySlug, params: typed)
                optionLists[key] = .ok(result)
            } catch {
                optionLists[key] = .error(error.localizedDescription)
            }
        }
    }

    /// A choice list's params (and its create mutation's) as the web sends
    /// them: each `{ type: 'string', value }`, the value as text or null. The
    /// query and mutation routes drop a bare value.
    public static func textParams(_ params: [String: CmsJSON]) -> [String: CmsJSON] {
        params.mapValues { value in
            if case .null = value { return .object(["type": .string("string"), "value": .null]) }
            return .object(["type": .string("string"), "value": .string(CmsCards.text(value))])
        }
    }

    public static func optionListKey(_ querySlug: String, params: [String: CmsJSON]) -> String {
        querySlug + "?" + params.sorted { $0.key < $1.key }
            .map { "\($0.key)=\(CmsCards.text($0.value))" }.joined(separator: "&")
    }

    /// Lazy fetch — first caller triggers the run, others observe.
    public func ensureLoaded(_ querySlug: String) {
        guard !querySlug.isEmpty else { return }
        if case .idle = state(for: querySlug) {} else { return }
        runQuery(querySlug)
    }

    private func runQuery(_ querySlug: String) {
        if let view = viewDefs[querySlug] {
            // A view's params are its base query's.
            switch resolveParams(for: view.base) {
            case .waiting(let reason): queries[querySlug] = .waiting(reason)
            case .static: startViewRun(view, params: nil)
            case .ready(let params): startViewRun(view, params: params)
            }
            return
        }
        let resolution = resolveParams(for: querySlug)
        switch resolution {
        case .waiting(let reason):
            queries[querySlug] = .waiting(reason)
            return
        case .static:
            startRun(querySlug, params: nil, hash: "")
        case .ready(let params):
            startRun(querySlug, params: params, hash: Self.stableHash(params))
        }
    }

    /// Each query's or view's latest run. Only the latest run's answer is
    /// applied: an older one arriving last would put back rows from before a
    /// save (Multi-add refreshes seven queries at once; WAC Next's calendar
    /// lost the two new days that way on Android, 3 November 2026).
    private var runNumbers: [String: Int] = [:]

    private func nextRun(_ slug: String) -> Int {
        let n = (runNumbers[slug] ?? 0) + 1
        runNumbers[slug] = n
        return n
    }

    private func isLatestRun(_ slug: String, _ n: Int) -> Bool { runNumbers[slug] == n }

    private func startRun(_ querySlug: String, params: [String: CmsJSON]?, hash: String) {
        // Keep old rows visible during a param-driven refetch; only show the
        // spinner on first load.
        if case .ok = state(for: querySlug) {} else { queries[querySlug] = .loading }
        let run = nextRun(querySlug)
        Task {
            do {
                let result = try await client.runSavedQuery(cmsId: cmsId, querySlug: querySlug, params: params)
                guard self.isLatestRun(querySlug, run) else { return }
                self.schemas[querySlug] = result.schema
                self.appliedParamsHash[querySlug] = hash
                self.queries[querySlug] = .ok(result)
            } catch {
                guard self.isLatestRun(querySlug, run) else { return }
                self.queries[querySlug] = .error(error.localizedDescription)
            }
        }
    }

    // MARK: - Views

    /// Run a view, reading its answer as it streams: the base rows are the
    /// view's rows at once, and each source's columns join them as they come.
    private func startViewRun(_ view: CmsViewDef, params: [String: CmsJSON]?) {
        let slug = view.slug
        if case .ok = state(for: slug) {} else { queries[slug] = .loading }
        let run = nextRun(slug)
        Task {
            var result = CmsViewResult(key: view.key)
            do {
                for try await json in client.runView(cmsId: cmsId, viewSlug: slug, params: params) {
                    // A newer run of this view has started: this one's answer is stale.
                    guard self.isLatestRun(slug, run) else { return }
                    for event in Self.viewEvents(json) {
                        result.apply(event, view: view)
                        if case .error(let message) = event, result.rows.isEmpty {
                            self.viewResults[slug] = result
                            self.queries[slug] = .error(message)
                            return
                        }
                    }
                    self.publishView(slug, result)
                }
                guard self.isLatestRun(slug, run) else { return }
                result.failRemainingPending("Couldn't load this")
                self.publishView(slug, result)
            } catch {
                guard self.isLatestRun(slug, run) else { return }
                if result.rows.isEmpty {
                    self.queries[slug] = .error(error.localizedDescription)
                } else {
                    result.failRemainingPending(error.localizedDescription)
                    self.publishView(slug, result)
                }
            }
        }
    }

    /// Ask for these rows' per-row sources: rows that came back `later` as
    /// their cards come into view, or a failed row's Try again. The rows
    /// already shown stay; only those sources' columns arrive.
    public func requestViewRows(_ slug: String, keys: [String]) {
        guard let view = viewDefs[slug], var result = viewResults[slug], !keys.isEmpty else { return }
        let perRow = Set((view.sources ?? []).filter(\.isPerRow).map(\.alias))
        var asked: [String] = []
        for key in keys {
            guard var statuses = result.status[key] else { continue }
            var changed = false
            for (alias, status) in statuses where perRow.contains(alias) {
                switch status {
                case .later, .failed: statuses[alias] = .pending; changed = true
                default: break
                }
            }
            if changed { result.status[key] = statuses; asked.append(key) }
        }
        guard !asked.isEmpty else { return }
        publishView(slug, result)
        let params: [String: CmsJSON]?
        if case .ready(let p) = resolveParams(for: view.base) { params = p } else { params = nil }
        Task {
            do {
                for try await json in client.runView(cmsId: cmsId, viewSlug: slug, params: params, keys: asked) {
                    for event in Self.viewEvents(json) {
                        guard case .source(let alias, let results) = event, var current = self.viewResults[slug] else { continue }
                        current.merge(alias: alias, results: results)
                        self.publishView(slug, current)
                    }
                }
            } catch {}
            if var current = self.viewResults[slug] {
                current.failRemainingPending("Couldn't load this", keys: Set(asked))
                self.publishView(slug, current)
            }
        }
    }

    /// Try again for one row: its per-row sources again, or the whole view
    /// when a matched source failed.
    public func retryViewRow(_ slug: String, key: String) {
        guard let view = viewDefs[slug], let statuses = viewResults[slug]?.status[key] else { return }
        let failedMatched = (view.sources ?? []).contains { source in
            if case .failed? = statuses[source.alias] { return !source.isPerRow }
            return false
        }
        if failedMatched { invalidate(slug) } else { requestViewRows(slug, keys: [key]) }
    }

    /// A source's status for a row of a view; `ready` for anything that isn't one.
    public func viewSourceStatus(_ slug: String, row: [String: CmsJSON], alias: String) -> CmsViewSourceStatus {
        viewResults[slug]?.status(row: row, alias: alias) ?? .ready
    }

    private func publishView(_ slug: String, _ result: CmsViewResult) {
        viewResults[slug] = result
        schemas[slug] = result.schema
        queries[slug] = .ok(CmsQueryResult(rows: result.rows, schema: result.schema))
    }

    private static func viewEvents(_ json: CmsJSON) -> [CmsViewEvent] {
        if json.objectValue?["type"] == nil { return CmsViewEvent.events(fromWhole: json) }
        return CmsViewEvent.parse(json).map { [$0] } ?? []
    }

    // MARK: - Mutations

    /// `invalidateByQuerySlug`: a query some block has loaded runs again with
    /// its current params; one nobody has asked for stays idle. A loaded view
    /// that reads the query (as its base or a source) runs again too.
    public func invalidate(_ querySlug: String) {
        if case .idle = state(for: querySlug) {} else { runQuery(querySlug) }
        for (slug, view) in viewDefs where slug != querySlug && view.queries.contains(querySlug) {
            if case .idle = state(for: slug) { continue }
            runQuery(slug)
        }
    }

    public enum MutationOutcome {
        case done(affectedRows: Int, message: String)
        case failed(String)
    }

    /// Params for a mutation, as `useBlockActionRunner` resolves them: the
    /// mutation's own paramSources from selected rows, then the caller's
    /// paramMap over them. nil = still waiting on a selection.
    public func mutationParams(_ slug: String, paramMap: [String: CmsJSON]?) -> [String: CmsJSON]?? {
        var params: [String: CmsJSON] = [:]
        var waiting = false
        for (name, source) in mutationDefs[slug]?.paramSources ?? [:] {
            guard let sourceSlug = source.sourceQuerySlug, let column = source.column,
                  let value = selectedRow(sourceSlug)?[column], value != .null else {
                waiting = true
                continue
            }
            params[name] = Self.typedString(value)
        }
        for (name, binding) in paramMap ?? [:] {
            guard case .object(let b) = binding else { continue }
            switch b.string("source") {
            case "static":
                if let value = b.string("value") { params[name] = .object(["value": .string(value), "type": .string("string")]) }
            case "context":
                if b.string("key") == "siteKeyId", let id = client.siteKeyId {
                    params[name] = .object(["value": .string(id), "type": .string("string")])
                }
            case "selectedRow":
                if let sourceSlug = b.string("querySlug"), let column = b.string("column"),
                   let value = selectedRow(sourceSlug)?[column], value != .null {
                    params[name] = Self.typedString(value)
                } else {
                    waiting = true
                }
            default:
                break
            }
        }
        if waiting && params.isEmpty { return .some(nil) }
        return params.isEmpty ? .none : .some(params)
    }

    private static func typedString(_ value: CmsJSON) -> CmsJSON {
        .object(["value": .string(value.displayString), "type": .string("string")])
    }

    /// Run a saved mutation and refresh the queries it names.
    public func runMutation(_ slug: String, params: [String: CmsJSON]?) async -> MutationOutcome {
        let def = mutationDefs[slug]
        do {
            let result = try await client.runSavedMutationResult(cmsId: cmsId, mutationSlug: slug, params: params)
            let affected = result.affectedRows
            // A follow-up call that failed: the run still succeeded, so the
            // warning shows beside the success message, for longer.
            if let warning = result.warning { showWarning(warning) }
            for querySlug in def?.invalidateQueries ?? [] { invalidate(querySlug) }
            announceAfter(slug, result: result.result)
            let message = def?.successMessage.flatMap { $0.isEmpty ? nil : $0 }
                ?? "Done — \(affected) row(s) affected"
            return .done(affectedRows: affected, message: message)
        } catch CmsClientError.http(_, let body) {
            // The worker answers a refusal as JSON with an `error`.
            let message = (try? JSONDecoder().decode([String: CmsJSON].self, from: Data(body.utf8)))?
                .string("error") ?? body
            return .failed(message)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Runs a mutation and hands back its run's `result` (a creatable
    /// choice reads the new value from it); its invalidations run as usual.
    public func runMutationResult(_ slug: String, params: [String: CmsJSON]?) async -> Result<CmsJSON?, CmsMutationRefusal> {
        do {
            let run = try await client.runSavedMutationResult(cmsId: cmsId, mutationSlug: slug, params: params)
            if let warning = run.warning { showWarning(warning) }
            for querySlug in mutationDefs[slug]?.invalidateQueries ?? [] { invalidate(querySlug) }
            announceAfter(slug, result: run.result)
            return .success(run.result)
        } catch CmsClientError.http(_, let body) {
            let message = (try? JSONDecoder().decode([String: CmsJSON].self, from: Data(body.utf8)))?.string("error") ?? body
            return .failure(CmsMutationRefusal(message: message))
        } catch {
            return .failure(CmsMutationRefusal(message: error.localizedDescription))
        }
    }

    // MARK: - Writes (control blocks)

    public func setSelectedRows(_ querySlug: String, rows: [[String: CmsJSON]]) {
        selections[querySlug] = rows
        refetchQueriesDepending { source in
            source.sourceQuerySlug == querySlug
                || source.datePredicate?.operatorSource?.sourceQuerySlug == querySlug
        }
    }

    public func selectedRow(_ querySlug: String) -> [String: CmsJSON]? {
        selections[querySlug]?.first
    }

    public func setParameter(_ id: String, value: CmsJSON) {
        parameters[id] = value
        if let data = try? JSONEncoder().encode(parameters) {
            UserDefaults.standard.set(data, forKey: Self.parametersKey(cmsId))
        }
        refetchQueriesDepending { $0.parameter?.id == id }
    }

    public func parameterValue(_ id: String, kind: String) -> CmsJSON {
        parameters[id] ?? CmsParameterKinds.defaultValue(kind: kind)
    }

    // MARK: - Reactive refetch

    /// Re-resolve and re-run every non-idle parameterized query with a source
    /// matching `affected`, after that query's debounce window.
    private func refetchQueriesDepending(_ affected: (CmsQueryParamSource) -> Bool) {
        for (slug, def) in queryDefs {
            guard case .idle = state(for: slug) else {
                let sources = effectiveParamSources(def)
                guard !sources.isEmpty, sources.values.contains(where: affected) else { continue }
                // autoRefresh: false on any source pins the query until a
                // manual re-run — mirror of the web's all-must-allow rule.
                guard sources.values.allSatisfy({ $0.autoRefresh != false }) else { continue }
                scheduleRefetch(slug, sources: sources)
                continue
            }
        }
    }

    private func scheduleRefetch(_ querySlug: String, sources: [String: CmsQueryParamSource]) {
        let debounceMs = sources.values.map { $0.debounceMs ?? 300 }.max() ?? 300
        debounceTasks[querySlug]?.cancel()
        debounceTasks[querySlug] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(debounceMs * 1_000_000))
            guard !Task.isCancelled, let self else { return }
            switch self.resolveParams(for: querySlug) {
            case .waiting(let reason):
                self.queries[querySlug] = .waiting(reason)
            case .static:
                break // selection change can't affect a static query
            case .ready(let params):
                let hash = Self.stableHash(params)
                guard hash != self.appliedParamsHash[querySlug] else { return }
                self.startRun(querySlug, params: params, hash: hash)
            }
        }
    }

    // MARK: - Param resolution (twin of resolvedParams in BlockDataContext)

    enum ParamResolution {
        case `static`
        case waiting(String)
        case ready([String: CmsJSON])
    }

    /// paramSources filtered to params actually referenced in the SQL —
    /// mirrors the web's stale-entry guard.
    private func effectiveParamSources(_ def: CmsQueryDef) -> [String: CmsQueryParamSource] {
        guard let raw = def.paramSources, !raw.isEmpty else { return [:] }
        guard let sql = def.sql, !sql.isEmpty else { return raw }
        return raw.filter { sql.contains("@\($0.key)") }
    }

    func resolveParams(for querySlug: String) -> ParamResolution {
        guard let def = queryDefs[querySlug] else { return .static }
        let sources = effectiveParamSources(def)
        guard !sources.isEmpty else { return .static }

        var params: [String: CmsJSON] = [:]

        // Companion upper-bound params are driven by their owning `from`
        // param — skip them in the main loop so a stray standalone entry
        // can't double-resolve.
        var claimedToParams = Set<String>()
        for source in sources.values {
            if let to = source.datePredicate?.toParam { claimedToParams.insert(to) }
            if let to = source.parameter?.toParam { claimedToParams.insert(to) }
        }

        for (name, source) in sources {
            if claimedToParams.contains(name) { continue }

            // ── Shared Parameter ────────────────────────────────────────
            if let binding = source.parameter {
                let value = parameterValue(binding.id, kind: binding.kind)
                switch CmsParameterKinds.project(kind: binding.kind, projection: binding.projection, value: value) {
                case .waiting(let reason):
                    return .waiting("@\(name): parameter \"\(binding.id)\" — \(reason)")
                case .single(let param):
                    params[name] = param
                case .range(let from, let to):
                    params[name] = from
                    if let toParam = binding.toParam { params[toParam] = to }
                }
                continue
            }

            // ── Date-predicate range-fold ───────────────────────────────
            if let predicate = source.datePredicate {
                var op = CmsRangePredicateOperator(rawValue: predicate.operator) ?? .any
                if let opSource = predicate.operatorSource,
                   let picked = selectedRow(opSource.sourceQuerySlug)?[opSource.column]?.stringValue,
                   let pickedOp = CmsRangePredicateOperator(rawValue: picked),
                   !pickedOp.isPeriod, pickedOp != .between {
                    op = pickedOp
                }
                var date = CmsDatePredicate.dateMin // unused for 'any'
                if op != .any {
                    guard let row = selectedRow(source.sourceQuerySlug ?? ""),
                          let value = row[source.column ?? ""], value != .null else {
                        return .waiting("@\(name): date predicate needs a date from \"\(source.sourceQuerySlug ?? "(no source)")\"")
                    }
                    date = value.displayString
                }
                let bounds = CmsDatePredicate.bounds(for: op, date: date)
                params[name] = CmsParameterKinds.typedParam(bounds.from, type: "date")
                params[predicate.toParam] = CmsParameterKinds.typedParam(bounds.to, type: "date")
                continue
            }

            // ── Plain selection source ──────────────────────────────────
            let sourceSlug = source.sourceQuerySlug ?? ""
            let column = source.column ?? ""
            let paramType = selectionParamType(sourceSlug: sourceSlug, column: column)

            if source.mode == "multi" {
                let rows = selections[sourceSlug] ?? []
                let values = rows.compactMap { row -> String? in
                    guard let v = row[column], v != .null else { return nil }
                    return v.displayString
                }
                if values.isEmpty && source.optional != true {
                    return .waiting("@\(name): no rows selected in \"\(sourceSlug)\" (multi)")
                }
                params[name] = CmsParameterKinds.typedMultiParam(values, type: paramType)
            } else {
                let value = selectedRow(sourceSlug)?[column]
                if value == nil || value == .null {
                    if source.optional != true {
                        return .waiting("@\(name): no row selected in \"\(sourceSlug)\"")
                    }
                    params[name] = CmsParameterKinds.typedParam(nil, type: paramType)
                } else {
                    params[name] = CmsParameterKinds.typedParam(value!.displayString, type: paramType)
                }
            }
        }
        return .ready(params)
    }

    /// Type a selection-sourced param from the source query's last result
    /// schema, so admin SQL doesn't need CAST(@x AS …).
    private func selectionParamType(sourceSlug: String, column: String) -> String {
        guard let col = schemas[sourceSlug]?.first(where: { $0.name == column }),
              let raw = col.type?.lowercased() else { return "string" }
        if raw.contains("timestamp") || raw.contains("datetime") { return "timestamp" }
        if raw.contains("date") { return "date" }
        if raw.contains("int") { return "integer" }
        if raw.contains("float") || raw.contains("double") || raw.contains("numeric") || raw.contains("decimal") { return "float" }
        if raw.contains("bool") { return "boolean" }
        return "string"
    }

    /// Canonical serialization for change detection — sorted keys, recursive.
    nonisolated static func stableHash(_ value: CmsJSON) -> String {
        switch value {
        case .string(let s): return "\"\(s)\""
        case .number(let n): return String(n)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .array(let a): return "[" + a.map(stableHash).joined(separator: ",") + "]"
        case .object(let o):
            return "{" + o.keys.sorted().map { "\($0):\(stableHash(o[$0]!))" }.joined(separator: ",") + "}"
        }
    }

    nonisolated static func stableHash(_ params: [String: CmsJSON]) -> String {
        stableHash(.object(params))
    }

    // MARK: - Binding resolution
    // Swift twin of resolveBindings.ts. Two mechanisms, same semantics:
    //  1. Direct bindings: props[key] replaced by selectedRow[column] of the
    //     source query; falls back to the static prop when nothing selected.
    //  2. Inline `@querySlug.column` tokens in string props, resolved against
    //     that query's selected row. `\@` escapes a literal `@`.

    /// Apply ALL of a block's direct bindings onto its props, including
    /// dot-path keys into composite/array props (`items.0.value`) — the twin
    /// of resolveBlockProps. Each resolved binding replaces the whole property
    /// value with `selectedRow[column]` of the source (a query selection or a
    /// block's published output row); no row → the static value stays. A
    /// declared `format` opts the binding into formatted-string output.
    public func resolvedProps(for block: CmsBlock) -> [String: CmsJSON] {
        guard let bindings = block.bindings, !bindings.isEmpty else { return block.props }
        var root = CmsJSON.object(block.props)
        for (path, binding) in bindings {
            guard let row = selectedRow(binding.querySlug),
                  let value = row[binding.column], value != .null else { continue }
            let resolved: CmsJSON
            if let format = binding.format, !format.isEmpty {
                resolved = .string(CmsFormatValue.apply(value.displayString, pattern: format))
            } else {
                resolved = value
            }
            root = Self.setting(root, path: path.split(separator: ".").map(String.init), to: resolved)
        }
        return root.objectValue ?? block.props
    }

    /// Immutable dot-path set — walks objects by key and arrays by integer
    /// index; a missing/mistyped segment leaves the tree unchanged.
    static func setting(_ node: CmsJSON, path: [String], to value: CmsJSON) -> CmsJSON {
        guard let head = path.first else { return value }
        let rest = Array(path.dropFirst())
        switch node {
        case .object(var obj):
            guard let child = obj[head] else { return node }
            obj[head] = setting(child, path: rest, to: value)
            return .object(obj)
        case .array(var arr):
            guard let index = Int(head), arr.indices.contains(index) else { return node }
            arr[index] = setting(arr[index], path: rest, to: value)
            return .array(arr)
        default:
            return node
        }
    }

    /// Resolve a block's string prop through direct bindings + inline tokens.
    /// `rowContext` supplies per-item resolution (`@column` against the card's
    /// own row inside repeater blocks like recordCards).
    public func resolveString(
        block: CmsBlock,
        propKey: String,
        rowContext: [String: CmsJSON]? = nil
    ) -> String? {
        if let binding = block.bindings?[propKey],
           let row = selectedRow(binding.querySlug),
           let value = row[binding.column] {
            return value.displayString
        }
        guard let raw = block.props.string(propKey) else { return nil }
        return resolveTemplate(raw, rowContext: rowContext)
    }

    /// Interpolate `@slug.column` / `@column` tokens in a template string.
    public func resolveTemplate(_ template: String, rowContext: [String: CmsJSON]? = nil) -> String {
        guard template.contains("@") else { return template }
        var result = ""
        var index = template.startIndex
        while index < template.endIndex {
            let char = template[index]
            if char == "\\", template.index(after: index) < template.endIndex,
               template[template.index(after: index)] == "@" {
                result.append("@")
                index = template.index(index, offsetBy: 2)
                continue
            }
            guard char == "@" else {
                result.append(char)
                index = template.index(after: index)
                continue
            }
            // Parse @identifier(.identifier)?
            var cursor = template.index(after: index)
            func readIdentifier() -> String {
                var name = ""
                while cursor < template.endIndex {
                    let c = template[cursor]
                    if c.isLetter || c.isNumber || c == "_" {
                        name.append(c)
                        cursor = template.index(after: cursor)
                    } else { break }
                }
                return name
            }
            let first = readIdentifier()
            guard !first.isEmpty else {
                result.append(char)
                index = template.index(after: index)
                continue
            }
            var second: String? = nil
            if cursor < template.endIndex, template[cursor] == "." {
                let dotIndex = cursor
                cursor = template.index(after: cursor)
                let name = readIdentifier()
                if name.isEmpty { cursor = dotIndex } else { second = name }
            }
            // Optional `|{formatPattern}` suffix (two-part tokens only) —
            // brace-terminated so date patterns with spaces parse.
            var format: String? = nil
            if second != nil, cursor < template.endIndex, template[cursor] == "|",
               template.index(after: cursor) < template.endIndex,
               template[template.index(after: cursor)] == "{",
               let close = template[cursor...].firstIndex(of: "}") {
                let patternStart = template.index(cursor, offsetBy: 2)
                format = String(template[patternStart..<close])
                cursor = template.index(after: close)
            }
            if let column = second, let row = selectedRow(first) {
                // @querySlug.column against that query's selection / a block's
                // published output row. A resolved row with a missing/null
                // column renders blank (a real row simply lacks the value).
                if let value = row[column], value != .null {
                    let s = value.displayString
                    result.append(format.map { CmsFormatValue.apply(s, pattern: $0) } ?? s)
                }
            } else if second == nil, let row = rowContext, let value = row[first] {
                // @column against the local row context (repeater item)
                result.append(value.displayString)
            } else {
                // Unresolved token stays literal (incl. any format suffix) so
                // the unbound reference is visible — mirror of the web rule.
                result.append(contentsOf: template[index..<cursor])
            }
            index = cursor
        }
        return result
    }
}

/// Why a mutation was refused, in words for the person.
public struct CmsMutationRefusal: Error, Equatable {
    public var message: String
}
