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

    /// Query metadata (paramSources) — set by the page loader from the
    /// fetched definition before any block renders.
    public var queryDefs: [String: CmsQueryDef] = [:]
    /// Shared column views (columnViewRef target), keyed by slug — set by the
    /// loader from the definition; blocks resolve their `columnViewRef`.
    public var columnViews: [String: CmsColumnView] = [:]
    /// Shared card views (cardViewRef target), keyed by slug — set by the
    /// loader; the grid's cards projection resolves its `cardViewRef`.
    public var cardViews: [String: CmsCardView] = [:]
    /// Portal theme — `color.*` tokens resolve against it. Set by the loader.
    public var theme = CmsPortalTheme(config: nil)

    /// Resolve a colour value: theme token or CSS literal.
    public func color(_ value: String?) -> Color? {
        theme.resolve(value)
    }

    @Published public private(set) var queries: [String: QueryState] = [:]
    /// Selected rows per query slug. Control blocks also publish their output
    /// rows here under their block slug (calendar bounds, etc.).
    @Published public private(set) var selections: [String: [[String: CmsJSON]]] = [:]
    /// Named shared parameters — open JSON values shaped by their kind.
    @Published public private(set) var parameters: [String: CmsJSON] = [:]
    /// Active grid-view state per target grid slug — the native twin of the
    /// GridApiRegistry channel: a gridViewSwitcher writes a saved view's
    /// state snapshot; the grid block reads and honours what it can.
    @Published public private(set) var gridViewStates: [String: CmsJSON] = [:]

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

    /// Close the drawer through the one path that honours its dismiss hook.
    /// Slides the panel out via `drawerOpenOffset` (a guaranteed animation)
    /// then removes it — a plain `openDrawer = nil` relies on the removal
    /// transition, which a Liquid Glass panel doesn't animate reliably, so it
    /// looked like the drawer never slid back on scrim tap / item select.
    public func closeDrawer() {
        guard let dismissed = openDrawer else { return }
        let hidden: CGFloat = dismissed.edge == .leading
            ? -CmsDrawerOverlay.panelWidth
            : CmsDrawerOverlay.panelWidth
        // Removal uses the identity transition (no second slide) since the
        // panel is already off-screen by the time we clear it.
        drawerInteractiveOpen = true
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            drawerOpenOffset = hidden
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            self.openDrawer = nil
            self.drawerInteractiveOpen = false
            self.drawerOpenOffset = 0
            dismissed.onDismiss?()
        }
    }
    /// Interactive-open state: while an edge swipe is in flight the panel
    /// tracks the finger via this offset (0 = fully open; ±panelWidth =
    /// hidden at its edge). The edge strip drives it; the overlay applies it.
    @Published public var drawerOpenOffset: CGFloat = 0
    /// True while an edge swipe is opening the drawer — the overlay skips
    /// its edge-slide insertion transition (the finger IS the animation).
    public var drawerInteractiveOpen = false

    // MARK: - Page navigation (native routing)

    /// In-portal navigation request — nav blocks publish, `CmsPageView`
    /// consumes (swaps the rendered page; the runtime and its
    /// selections/parameters survive, the web's SPA reading).
    public struct PageNavigation: Equatable {
        public let pageSlug: String
    }
    @Published public var pendingNavigation: PageNavigation?
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

    public func state(for querySlug: String) -> QueryState {
        queries[querySlug] ?? .idle
    }

    // MARK: - Loading

    /// Lazy fetch — first caller triggers the run, others observe.
    public func ensureLoaded(_ querySlug: String) {
        guard !querySlug.isEmpty else { return }
        if case .idle = state(for: querySlug) {} else { return }
        runQuery(querySlug)
    }

    private func runQuery(_ querySlug: String) {
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

    private func startRun(_ querySlug: String, params: [String: CmsJSON]?, hash: String) {
        // Keep old rows visible during a param-driven refetch; only show the
        // spinner on first load.
        if case .ok = state(for: querySlug) {} else { queries[querySlug] = .loading }
        Task {
            do {
                let result = try await client.runSavedQuery(cmsId: cmsId, querySlug: querySlug, params: params)
                self.schemas[querySlug] = result.schema
                self.appliedParamsHash[querySlug] = hash
                self.queries[querySlug] = .ok(result)
            } catch {
                self.queries[querySlug] = .error(error.localizedDescription)
            }
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
