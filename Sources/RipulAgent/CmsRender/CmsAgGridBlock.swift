import SwiftUI

/// Native `agGrid` twin. The projection is an AUTHORED decision
/// (`nativePresentation`: auto/list/cards/grid + `nativeColumns` reduced
/// set) — the designer knows whether readers need columnar alignment or
/// entity browsing; the renderer supplies the default (`auto` → list) and
/// renders whichever projection natively. The data role is projection-
/// invariant: the query, params, shared selection and the aggregate output
/// row (`${key}_${aggFunc}` + row_count) behave identically in all three.
struct CmsAgGridBlockView: View {
    let block: CmsBlock
    @EnvironmentObject var runtime: CmsRuntime

    @State private var searchText = ""
    @State private var sortKey: String?
    @State private var sortAscending = true
    /// Expanded group keys. Groups start COLLAPSED — AG Grid's
    /// groupDefaultExpanded defaults to 0, so the web shows summary rows too.
    @State private var expandedGroups: Set<String> = []
    /// Reader's presentation pick when the designer enabled the view toggle.
    /// Stored as an abstract intent ("browse"/"grid") — not a concrete
    /// presentation — so a saved view that redefines what browse means
    /// (list vs cards) is still honoured.
    @State private var userViewIntent: String?
    /// Natural height of the grid body's rows — caps the vertical scroll
    /// area so the pinned total row packs up under the last row when rows
    /// are sparse instead of sitting at the bottom of the block height.
    @State private var gridBodyHeight: CGFloat = 0

    private var outputSlug: String { block.slug ?? block.id }
    /// The grid's READ query. A gridViewSwitcher view can re-bind it via the
    /// runtime query-override channel (web parity); a blank/absent override
    /// keeps the authored base `querySlug`. Editing (table/mutations) is
    /// unaffected — it stays on the base binding.
    private var querySlug: String {
        if let override = runtime.gridQueryOverrides[outputSlug], !override.isEmpty {
            return override
        }
        return props.string("querySlug") ?? ""
    }

    /// Active saved-view state applied by a gridViewSwitcher (runtime channel).
    private var viewState: [String: CmsJSON]? {
        runtime.gridViewStates[outputSlug]?.objectValue
    }

    /// Twin of the web's VIEW_STATE_EXCLUDED_KEYS plus the runtime-state keys
    /// that are applied separately (sortModel/columnOrder) or degraded
    /// (filterModel).
    private static let viewExcludedKeys: Set<String> = [
        "tableSlug", "querySlug", "editMutationSlug", "insertMutationSlug",
        "deleteMutationSlug", "filterModel", "sortModel", "columnOrder",
    ]

    /// Effective props: the base block props with the active view's prop
    /// overrides merged on top — the exact semantics of the web's
    /// setState(viewOverride) merge. No view -> base props.
    private var props: [String: CmsJSON] {
        guard let viewState else { return block.props }
        var merged = block.props
        for (key, value) in viewState where !Self.viewExcludedKeys.contains(key) {
            merged[key] = value
        }
        return merged
    }

    private var viewFingerprint: String {
        runtime.gridViewStates[outputSlug].map { CmsRuntime.stableHash($0) } ?? ""
    }

    /// Seed the sort state from the view's sortModel (first entry) — the twin
    /// of applyViewRuntimeState. No sortModel in the view -> clear the sort.
    private func seedSortFromView() {
        guard let viewState else { return }
        if case .array(let model) = viewState["sortModel"] ?? .null,
           let first = model.first?.objectValue,
           let colId = first.string("colId") {
            sortKey = colId
            sortAscending = (first.string("sort") ?? "asc") == "asc"
        } else {
            sortKey = nil
        }
    }
    private var authoredPresentation: String {
        let p = props.string("nativePresentation") ?? "auto"
        return p == "auto" ? "list" : p
    }
    /// The non-grid segment of the reader toggle: the authored browse
    /// presentation, falling back to list when the author picked grid itself.
    private var browsePresentation: String {
        authoredPresentation == "grid" ? "list" : authoredPresentation
    }
    private var viewToggleEnabled: Bool { props.bool("nativeViewToggle") ?? false }
    private var presentation: String {
        guard viewToggleEnabled, let userViewIntent else { return authoredPresentation }
        return userViewIntent == "grid" ? "grid" : browsePresentation
    }
    private var viewIntentPersistenceKey: String {
        "io.ripul.cms.gridPresentation.\(runtime.cmsId).\(outputSlug)"
    }
    private var viewIntentBinding: Binding<String> {
        Binding(
            get: { presentation == "grid" ? "grid" : "browse" },
            set: { intent in
                userViewIntent = intent
                UserDefaults.standard.set(intent, forKey: viewIntentPersistenceKey)
            }
        )
    }
    /// `contained` (default) scrolls records inside the block's height —
    /// parity with the web grid; `page` flows rows with the page scroll.
    private var scrollContained: Bool { (props.string("nativeScroll") ?? "contained") != "page" }
    private var blockHeight: CGFloat { CmsCss.points(props.string("height")) ?? 400 }
    private var searchEnabled: Bool { props.bool("enableFiltering") ?? true }
    private var sortEnabled: Bool { props.bool("enableSorting") ?? true }
    private var showGrandTotal: Bool { (props.string("grandTotalRow") ?? "none") != "none" }
    /// Locked groups: fixed summary labels, no expand chevron.
    private var groupsLocked: Bool { props.bool("suppressGroupExpand") ?? false }
    private var selectionMode: String {
        switch props.string("rowSelectionMode") ?? "none" {
        case "multiRow": return "multi"
        case "singleRow": return "single"
        default: return "none"
        }
    }

    // MARK: - Column model

    struct Column: Identifiable {
        var key: String
        var valueFrom: String
        var label: String
        var format: String?
        var width: CGFloat?
        var rowGroup: Bool
        var aggFunc: String?
        var excludeFromTotals: Bool
        var hideDetailValue: Bool
        /// Frozen columns ('left'/'right') — the author's row-identity signal.
        var pinned: String?
        /// Explicit per-column image config — the cards projection renders it.
        var image: [String: CmsJSON]?
        /// Render the cell as a link that drills — publishes the row to the
        /// shared selection so a modal/drawer watching this query opens.
        /// Independent of `rowSelectionMode` (a drill grid needn't be selectable).
        var drillLink: Bool
        var id: String { key }
    }

    /// The columns explicitly configured on the block (`props.columns`), in the
    /// author's order (a view `columnOrder` re-sorts them). This is the
    /// CUSTOMISED subset — NOT necessarily every result column. The web only
    /// stores the columns it needs to customise; `resolvedColumns(schema:)`
    /// appends the rest of the query's schema on top (see there).
    private var configuredColumns: [Column] {
        guard case .array(let raw) = props["columns"] ?? .null else { return [] }
        var all: [Column] = raw.compactMap { entry in
            guard let obj = entry.objectValue, let key = obj.string("key") else { return nil }
            guard obj.bool("visible") != false else { return nil }
            return Column(
                key: key,
                valueFrom: obj.string("valueFrom") ?? key,
                label: obj.string("label") ?? CmsRecordCardsBlockView.humanize(key),
                format: obj.string("format"),
                width: obj.double("width").map { CGFloat($0) },
                rowGroup: obj.bool("rowGroup") ?? false,
                aggFunc: obj.string("aggFunc"),
                excludeFromTotals: obj.bool("excludeFromTotals") ?? false,
                hideDetailValue: obj.bool("hideDetailValue") ?? false,
                pinned: obj.string("pinned"),
                image: obj.object("image"),
                drillLink: obj.bool("drillLink") ?? false
            )
        }
        // View columnOrder (runtime state) orders columns; unknown keys keep
        // their relative position at the end.
        if let viewState, case .array(let order) = viewState["columnOrder"] ?? .null {
            let ids = order.compactMap { $0.stringValue }
            if !ids.isEmpty {
                let index = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
                all = all.enumerated().sorted { a, b in
                    let ia = index[a.element.key] ?? (order.count + a.offset)
                    let ib = index[b.element.key] ?? (order.count + b.offset)
                    return ia < ib
                }.map { $0.element }
            }
        }
        return all
    }

    /// The rendered column set. Twin of the web's `resolveColumns`: the
    /// configured columns first, then EVERY result-schema column that wasn't
    /// configured, appended in schema order — so a grid that customises only a
    /// few columns still shows the full row, exactly like the web grid. Without
    /// this append the native grid would show only the handful of columns that
    /// happened to be customised (the missing-columns bug). A configured column
    /// is matched by its slot `key`, mirroring the web's `seen.add(cfg.key)`.
    ///
    /// The native-only `nativeColumns` knob still wins when authored: it
    /// whitelists/reorders the final set (its comma order is the column order),
    /// letting a designer deliberately reduce the native grid to a subset.
    private func resolvedColumns(schema: [CmsQueryResultColumn]) -> [Column] {
        var out = configuredColumns
        let seen = Set(out.map { $0.key })
        for col in schema where !seen.contains(col.name) {
            out.append(Column(
                key: col.name,
                valueFrom: col.name,
                label: CmsRecordCardsBlockView.humanize(col.name),
                format: nil, width: nil, rowGroup: false, aggFunc: nil,
                excludeFromTotals: false, hideDetailValue: false,
                pinned: nil, image: nil, drillLink: false
            ))
        }
        let reduced = (props.string("nativeColumns") ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !reduced.isEmpty {
            // uniquingKeysWith (not uniqueKeysWithValues) — duplicate keys would
            // otherwise TRAP; keep the first slot for a given key.
            let byKey = Dictionary(out.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
            return reduced.compactMap { byKey[$0] }
        }
        return out
    }

    // MARK: - Body

    var body: some View {
        content
            .onAppear {
                runtime.ensureLoaded(querySlug)
                userViewIntent = UserDefaults.standard.string(forKey: viewIntentPersistenceKey)
            }
            .onChange(of: stateFingerprint) { _ in publishAggregates() }
            .onAppear { publishAggregates() }
            .onChange(of: viewFingerprint) { _ in
                seedSortFromView()
                publishAggregates()
            }
            .onAppear { seedSortFromView() }
            // A view re-bind swaps the read query — load the new one (the
            // switch itself is reactive; onAppear won't fire again).
            .onChange(of: querySlug) { newSlug in runtime.ensureLoaded(newSlug) }
    }

    @ViewBuilder
    private var content: some View {
        switch runtime.state(for: querySlug) {
        case .idle, .loading:
            HStack { Spacer(); ProgressView(); Spacer() }
                .padding(.vertical, 24)
        case .waiting(let reason):
            Label(reason, systemImage: "hourglass")
                .font(.footnote)
                .foregroundColor(.secondary)
                .padding(12)
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundColor(.red)
                .padding(12)
        case .ok(let result):
            // Configured columns + every unconfigured schema column appended
            // (web parity — see resolvedColumns). No columns configured at all
            // → the full schema, unchanged from before.
            let cols = resolvedColumns(schema: result.schema)
            let rows = displayRows(result.rows, columns: cols)
            VStack(alignment: .leading, spacing: 8) {
                toolbar(columns: cols)
                switch presentation {
                case "cards":
                    contained { cardsProjection(columns: cols) }
                case "grid":
                    gridProjection(rows: rows, columns: cols)
                default:
                    contained { listProjection(rows: rows, columns: cols) }
                }
                // Grid renders its own column-aligned pinned total row.
                if showGrandTotal && presentation != "grid" {
                    grandTotalRow(columns: cols)
                }
            }
        }
    }

    /// Contained mode: records scroll inside the block's authored height
    /// instead of flowing with the page.
    @ViewBuilder
    private func contained<V: View>(@ViewBuilder _ inner: () -> V) -> some View {
        if scrollContained {
            ScrollView(.vertical, showsIndicators: true) {
                inner()
            }
            .frame(height: blockHeight)
        } else {
            inner()
        }
    }

    // MARK: - Shared toolbar (search + sort)

    @ViewBuilder
    private func toolbar(columns: [Column]) -> some View {
        if searchEnabled || sortEnabled || viewToggleEnabled {
            HStack(spacing: 10) {
                if searchEnabled {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("Search", text: $searchText)
                            .font(.subheadline)
                            .textFieldStyle(.plain)
                        if !searchText.isEmpty {
                            Button { searchText = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.secondary.opacity(0.1)))
                }
                if sortEnabled {
                    Menu {
                        ForEach(columns) { column in
                            Button {
                                if sortKey == column.key { sortAscending.toggle() } else { sortKey = column.key; sortAscending = true }
                            } label: {
                                if sortKey == column.key {
                                    Label(column.label, systemImage: sortAscending ? "arrow.up" : "arrow.down")
                                } else {
                                    Text(column.label)
                                }
                            }
                        }
                        if sortKey != nil {
                            Divider()
                            Button("Clear sort") { sortKey = nil }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.subheadline)
                            .foregroundColor(sortKey == nil ? .secondary : .accentColor)
                    }
                }
                if viewToggleEnabled {
                    if !searchEnabled { Spacer(minLength: 0) }
                    Picker("View", selection: viewIntentBinding) {
                        Image(systemName: browsePresentation == "cards" ? "square.grid.2x2" : "list.bullet")
                            .tag("browse")
                        Image(systemName: "tablecells")
                            .tag("grid")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 96)
                }
            }
        }
    }

    // MARK: - Row pipeline (filter + sort — shared by list and grid)

    private func displayRows(_ rows: [[String: CmsJSON]], columns: [Column]) -> [[String: CmsJSON]] {
        var out = rows
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            out = out.filter { row in
                columns.contains { row[$0.valueFrom]?.displayString.lowercased().contains(query) == true }
            }
        }
        if let sortKey, let column = columns.first(where: { $0.key == sortKey }) {
            out.sort { a, b in
                let va = a[column.valueFrom]?.displayString ?? ""
                let vb = b[column.valueFrom]?.displayString ?? ""
                let result: Bool
                if let na = Double(va), let nb = Double(vb) {
                    result = na < nb
                } else {
                    result = va.localizedCaseInsensitiveCompare(vb) == .orderedAscending
                }
                return sortAscending ? result : !result
            }
        }
        return out
    }

    // MARK: - List projection

    private func listProjection(rows: [[String: CmsJSON]], columns: [Column]) -> some View {
        // Row composition: first non-group column = title; first numeric/
        // formatted column = trailing value; next two = subtitle line.
        let bodyCols = columns.filter { !$0.rowGroup }
        let titleCol = bodyCols.first
        let trailingCol = bodyCols.dropFirst().first { $0.aggFunc != nil || $0.format != nil }
            ?? bodyCols.dropFirst().first { col in
                if case .ok(let r) = runtime.state(for: querySlug), let first = r.rows.first {
                    return first[col.valueFrom]?.doubleValue != nil
                }
                return false
            }
        let subtitleCols = bodyCols.dropFirst().filter { $0.key != trailingCol?.key }.prefix(2)
        let groupCol = columns.first { $0.rowGroup }

        return VStack(spacing: 0) {
            if let groupCol {
                ForEach(groupedKeys(rows, by: groupCol), id: \.self) { groupValue in
                    let groupRows = rows.filter { $0[groupCol.valueFrom]?.displayString == groupValue }
                    let expanded = expandedGroups.contains(groupValue)
                    groupHeader(groupValue, rows: groupRows, columns: columns, expanded: expanded)
                    if expanded {
                        rowList(groupRows, title: titleCol, trailing: trailingCol, subtitle: Array(subtitleCols))
                    }
                }
            } else {
                rowList(rows, title: titleCol, trailing: trailingCol, subtitle: Array(subtitleCols))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.05))
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func groupedKeys(_ rows: [[String: CmsJSON]], by column: Column) -> [String] {
        var seen = Set<String>()
        var keys: [String] = []
        for row in rows {
            let v = row[column.valueFrom]?.displayString ?? ""
            if seen.insert(v).inserted { keys.append(v) }
        }
        return keys
    }

    /// Collapsed-group summary row: chevron (unless locked), group value,
    /// count, and the group's aggregates — the web's group row reading.
    private func groupHeader(_ value: String, rows: [[String: CmsJSON]], columns: [Column], expanded: Bool) -> some View {
        let aggCols = columns.filter { $0.aggFunc != nil }
        let totals = Self.computeTotals(rows: rows, columns: aggCols.map {
            AggColumn(key: $0.key, valueFrom: $0.valueFrom, fn: $0.aggFunc ?? "")
        })
        return Button {
            guard !groupsLocked else { return }
            withAnimation(.snappy) {
                if expanded { expandedGroups.remove(value) } else { expandedGroups.insert(value) }
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if !groupsLocked {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .foregroundColor(.secondary)
                    }
                    // Pinned (frozen) fields lead in bold — the author's
                    // row identity — then the group-by value.
                    if let pinned = pinnedSummary(rows: rows, columns: columns) {
                        Text(pinned)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        Text(value.isEmpty ? "—" : value)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(value.isEmpty ? "—" : value)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.primary)
                    }
                    Spacer(minLength: 8)
                    Text("\(rows.count)")
                        .font(.caption2.weight(.medium))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
                if !aggCols.isEmpty {
                    Text(aggCols.map { col -> String in
                        let raw = totals["\(col.key)_\(col.aggFunc ?? "")"]?.displayString ?? ""
                        let shown = col.format.map { CmsFormatValue.apply(raw, pattern: $0) } ?? raw
                        return "\(col.label) \(shown)"
                    }.joined(separator: "  ·  "))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Frozen (pinned) columns surface in the folded title row — but only
    /// values UNIFORM across the group; a varying value would misrepresent
    /// the group as a whole.
    private func pinnedSummary(rows: [[String: CmsJSON]], columns: [Column]) -> String? {
        let pinnedCols = columns.filter { $0.pinned != nil && !$0.rowGroup }
        guard !pinnedCols.isEmpty else { return nil }
        let parts: [String] = pinnedCols.compactMap { col in
            let values = Set(rows.map { cellTextIgnoringDetailFlag($0, col) })
            guard values.count == 1, let only = values.first, !only.isEmpty else { return nil }
            return only
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Group-level read of a cell — hideDetailValue blanks LEAF rows only,
    /// so the group header ignores it.
    private func cellTextIgnoringDetailFlag(_ row: [String: CmsJSON], _ column: Column) -> String {
        guard let value = row[column.valueFrom], value != .null else { return "" }
        let s = value.displayString
        if let format = column.format, !format.isEmpty {
            return CmsFormatValue.apply(s, pattern: format)
        }
        return s
    }

    private func rowList(_ rows: [[String: CmsJSON]], title: Column?, trailing: Column?, subtitle: [Column]) -> some View {
        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
            listRow(row, title: title, trailing: trailing, subtitle: subtitle)
            if index < rows.count - 1 {
                Divider().padding(.leading, 12)
            }
        }
    }

    private func listRow(_ row: [String: CmsJSON], title: Column?, trailing: Column?, subtitle: [Column]) -> some View {
        let selected = isSelected(row)
        return Button {
            // A drill column makes the row a link to the detail — publish the
            // selection unconditionally so a watching modal/drawer opens. With
            // no drill column, the tap publishes selection (single/multi) and a
            // no-selection grid is inert — the web reading, where detail is
            // driven by an authored modal/drawer watching this query.
            if hasDrillLink { drill(row) } else { toggle(row) }
        } label: {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    if let title {
                        Text(cellText(row, title))
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(hasDrillLink ? drillLinkColor : .primary)
                    }
                    if !subtitle.isEmpty {
                        Text(subtitle.map { "\($0.label): \(cellText(row, $0))" }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if let trailing {
                    Text(cellText(row, trailing))
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                }
                // Drill takes the row's tap target — show a disclosure chevron.
                // Otherwise a selectable grid shows its checkmark.
                if hasDrillLink {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary.opacity(0.5))
                } else if selectionMode != "none" {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.subheadline)
                        .foregroundColor(selected ? .accentColor : .secondary.opacity(0.4))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Cards projection (reuse the Record Cards presentation)

    /// A `cardViewRef` designs the cards distinctly from the grid columns — a
    /// schema-wide Card View (own field set + card chrome). Resolved from the
    /// runtime; a blank/absent ref falls back to the auto-synth from columns.
    private var cardView: CmsCardView? {
        guard let ref = props.string("cardViewRef"), !ref.isEmpty else { return nil }
        return runtime.cardViews[ref]
    }

    private func cardsProjection(columns: [Column]) -> some View {
        // Synthesize a recordCards block for the cards presentation — the
        // projection is presentation-only, so the shared machinery (selection
        // publishing, formats, theme) behaves identically.
        var props: [String: CmsJSON] = [
            "querySlug": .string(querySlug),
            "rowSelectionMode": .string(selectionMode),
            "cardVariant": .string("outlined"),
        ]

        if let cardView, let cardFields = cardView.columns, !cardFields.isEmpty {
            // Designed cards: the Card View owns the field set (its own
            // visibility/order/labels/format/image) and the card chrome.
            props["fields"] = .array(cardFields)
            // Spread the chrome (recordCards-compatible props: title,
            // imageColumn, imageShape, imageHeight, cardVariant, showImageInCard)
            // straight onto the synthesized card.
            if case .object(let chrome)? = cardView.card {
                for (key, value) in chrome { props[key] = value }
            }
        } else {
            // Auto: derive the cards from the grid's own columns.
            props["fields"] = .array(columns.map { col in
                var field: [String: CmsJSON] = [
                    "key": .string(col.key),
                    "valueFrom": .string(col.valueFrom),
                    "label": .string(col.label),
                    "format": col.format.map { .string($0) } ?? .null,
                ]
                if let image = col.image { field["image"] = .object(image) }
                return .object(field)
            })
        }

        let synthetic = CmsBlock(
            id: block.id, slug: block.slug, name: block.name,
            hidden: nil, visibleOn: nil, type: "recordCards",
            props: props, frame: nil, position: nil, children: nil, bindings: nil
        )
        return CmsRecordCardsBlockView(block: synthetic)
    }

    // MARK: - Grid projection (true two-axis, read-only v1)

    /// Auto group column width. Like AG Grid, grouping hides the grouped
    /// column and adds a leading group column; leaf cells under it stay
    /// blank (the indent).
    private static let autoGroupColumnWidth: CGFloat = 180

    private func gridProjection(rows: [[String: CmsJSON]], columns: [Column]) -> some View {
        let height = CmsCss.points(props.string("height")) ?? 400
        let stripes = props.bool("enableRowStripes") ?? true
        let groupCol = columns.first { $0.rowGroup }
        let bodyColumns = groupCol == nil ? columns : columns.filter { !$0.rowGroup }
        return ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                gridHeader(bodyColumns: bodyColumns, groupCol: groupCol)
                Divider()
                ScrollView(.vertical, showsIndicators: true) {
                    // One FLATTENED displayed-row list (AG Grid's own model)
                    // with globally unique stable ids. Nested per-group
                    // ForEach keyed by offset gave duplicate row identities
                    // across expanded groups, and the lazy stack painted
                    // leaf rows outside their group.
                    LazyVStack(spacing: 0) {
                        ForEach(gridRowItems(rows: rows, groupCol: groupCol, stripes: stripes)) { item in
                            switch item {
                            case .group(_, let value, let groupRows, let expanded):
                                gridGroupRow(value, rows: groupRows, bodyColumns: bodyColumns, expanded: expanded)
                            case .leaf(_, let row, let stripe, let grouped):
                                gridLeafRow(row, bodyColumns: bodyColumns, grouped: grouped, stripe: stripe)
                            }
                            Divider()
                        }
                    }
                    .background(GeometryReader { g in
                        Color.clear.preference(key: GridBodyHeightKey.self, value: g.size.height)
                    })
                }
                // Cap the scroll area at the rows' natural height: sparse
                // rows pull the total row up under the last row; overflowing
                // rows still leave it pinned on screen (the stack gives the
                // scroll only the space left over after the fixed total row).
                .frame(maxHeight: gridBodyHeight > 0 ? gridBodyHeight : nil, alignment: .top)
                .onPreferenceChange(GridBodyHeightKey.self) { new in
                    if abs(new - gridBodyHeight) > 0.5 { gridBodyHeight = new }
                }
                if showGrandTotal {
                    Divider()
                    gridTotalRow(bodyColumns: bodyColumns, grouped: groupCol != nil)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: height)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.2))
        )
    }

    // Authored header styling — twin of the web's `header` inspector group
    // (headerBgColor / headerTextColor / headerFontSize / headerFontWeight).
    private var headerFont: Font {
        .system(size: props.double("headerFontSize").map { CGFloat($0) } ?? 12,
                weight: rowWeight(props.string("headerFontWeight")) ?? .semibold)
    }
    private var headerTextColor: Color {
        runtime.theme.resolve(props.string("headerTextColor")) ?? Color.secondary
    }
    private var headerBackground: Color {
        runtime.theme.resolve(props.string("headerBgColor")) ?? Color.secondary.opacity(0.1)
    }

    /// Header — tap a column to sort (native header idiom).
    private func gridHeader(bodyColumns: [Column], groupCol: Column?) -> some View {
        HStack(spacing: 0) {
            if let groupCol {
                Text(groupCol.label)
                    .font(headerFont)
                    .lineLimit(1)
                    .foregroundColor(headerTextColor)
                    .frame(width: Self.autoGroupColumnWidth, alignment: .leading)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 6)
            }
            ForEach(bodyColumns) { column in
                Button {
                    guard sortEnabled else { return }
                    if sortKey == column.key { sortAscending.toggle() } else { sortKey = column.key; sortAscending = true }
                } label: {
                    HStack(spacing: 3) {
                        Text(column.label)
                            .font(headerFont)
                            .lineLimit(1)
                        if sortKey == column.key {
                            Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                                .font(.caption2)
                        }
                    }
                    .foregroundColor(headerTextColor)
                    .frame(width: columnWidth(column), alignment: .leading)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 6)
                }
                .buttonStyle(.plain)
            }
        }
        .background(headerBackground)
    }

    /// One displayed row of the flattened grid body — a group summary or a
    /// leaf record. Ids are group-qualified so every item stays unique no
    /// matter how many groups are expanded.
    private enum GridRowItem: Identifiable {
        case group(id: String, value: String, rows: [[String: CmsJSON]], expanded: Bool)
        case leaf(id: String, row: [String: CmsJSON], stripe: Bool, grouped: Bool)
        var id: String {
            switch self {
            case .group(let id, _, _, _): return id
            case .leaf(let id, _, _, _): return id
            }
        }
    }

    /// Flatten (filtered+sorted) rows into the displayed-row list: group
    /// summaries in first-appearance order, each expanded group's leaves
    /// directly beneath it. Stripes restart per group.
    private func gridRowItems(rows: [[String: CmsJSON]], groupCol: Column?, stripes: Bool) -> [GridRowItem] {
        guard let groupCol else {
            return rows.enumerated().map { index, row in
                .leaf(id: "r|\(index)", row: row, stripe: stripes && index % 2 == 1, grouped: false)
            }
        }
        var items: [GridRowItem] = []
        for value in groupedKeys(rows, by: groupCol) {
            let groupRows = rows.filter { $0[groupCol.valueFrom]?.displayString == value }
            let expanded = expandedGroups.contains(value)
            items.append(.group(id: "g|\(value)", value: value, rows: groupRows, expanded: expanded))
            guard expanded else { continue }
            for (index, row) in groupRows.enumerated() {
                items.append(.leaf(id: "r|\(value)|\(index)", row: row,
                                   stripe: stripes && index % 2 == 1, grouped: true))
            }
        }
        return items
    }

    private func gridLeafRow(_ row: [String: CmsJSON], bodyColumns: [Column], grouped: Bool, stripe: Bool) -> some View {
        let selected = isSelected(row)
        return HStack(spacing: 0) {
            if grouped {
                Color.clear
                    .frame(width: Self.autoGroupColumnWidth, height: 1)
                    .padding(.horizontal, 6)
            }
            ForEach(bodyColumns) { column in
                let text = cellText(row, column)
                if column.drillLink && !text.isEmpty {
                    // A drill cell is its own tap target: the Button consumes
                    // the tap so the row's selection gesture doesn't also fire,
                    // scoping the click-through to this cell (web parity).
                    Button { drill(row) } label: {
                        Text(text)
                            .font(.caption)
                            .underline()
                            .lineLimit(1)
                            .foregroundColor(drillLinkColor)
                            .frame(width: columnWidth(column), alignment: .leading)
                            .padding(.vertical, 7)
                            .padding(.horizontal, 6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(text)
                        .font(.caption)
                        .lineLimit(1)
                        .frame(width: columnWidth(column), alignment: .leading)
                        .padding(.vertical, 7)
                        .padding(.horizontal, 6)
                }
            }
        }
        .background(
            selected ? Color.accentColor.opacity(0.15)
                : stripe ? Color.secondary.opacity(0.05)
                : Color.clear
        )
        .contentShape(Rectangle())
        .onTapGesture { toggle(row) }
    }

    // MARK: - Group/total row styling (authored — twin of the web's
    // groupRowStyle/grandTotalStyle getRowStyle lever). Native default:
    // bold group rows so summaries read heavier than their leaves; the
    // grand total inherits the group style, its own props override.

    private func rowWeight(_ raw: String?) -> Font.Weight? {
        switch raw {
        case "normal": return .regular
        case "medium": return .medium
        case "bold": return .bold
        default: return nil
        }
    }

    private var groupRowFont: Font {
        let size = props.double("groupRowFontSize").map { CGFloat($0) } ?? 12
        let weight = rowWeight(props.string("groupRowFontWeight")) ?? .bold
        return .system(size: size, weight: weight)
    }
    private var groupRowTextColor: Color? {
        runtime.theme.resolve(props.string("groupRowTextColor"))
    }
    private var groupRowBackground: Color {
        runtime.theme.resolve(props.string("groupRowBgColor")) ?? Color.secondary.opacity(0.08)
    }

    private var grandTotalFont: Font {
        let size = props.double("grandTotalFontSize").map { CGFloat($0) }
            ?? props.double("groupRowFontSize").map { CGFloat($0) } ?? 12
        let weight = rowWeight(props.string("grandTotalFontWeight"))
            ?? rowWeight(props.string("groupRowFontWeight")) ?? .bold
        return .system(size: size, weight: weight)
    }
    private var grandTotalTextColor: Color? {
        runtime.theme.resolve(props.string("grandTotalTextColor"))
            ?? runtime.theme.resolve(props.string("groupRowTextColor"))
    }
    private var grandTotalBackground: Color {
        runtime.theme.resolve(props.string("grandTotalBgColor"))
            ?? runtime.theme.resolve(props.string("groupRowBgColor"))
            ?? Color.secondary.opacity(0.08)
    }

    /// Column-aligned group summary row: chevron + value + count in the auto
    /// group column, the group's aggregates under their own columns — the
    /// aligned reading a table exists for. excludeFromTotals only affects
    /// the grand total; group rows keep every aggregate.
    private func gridGroupRow(_ value: String, rows: [[String: CmsJSON]], bodyColumns: [Column], expanded: Bool) -> some View {
        let totals = Self.computeTotals(rows: rows, columns: bodyColumns.filter { $0.aggFunc != nil }.map {
            AggColumn(key: $0.key, valueFrom: $0.valueFrom, fn: $0.aggFunc ?? "")
        })
        return Button {
            guard !groupsLocked else { return }
            withAnimation(.snappy) {
                if expanded { expandedGroups.remove(value) } else { expandedGroups.insert(value) }
            }
        } label: {
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    if !groupsLocked {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .foregroundColor(.secondary)
                    }
                    Text(value.isEmpty ? "—" : value)
                        .font(groupRowFont)
                        .foregroundColor(groupRowTextColor ?? .primary)
                        .lineLimit(1)
                    Text("\(rows.count)")
                        .font(.caption2.weight(.medium))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
                .frame(width: Self.autoGroupColumnWidth, alignment: .leading)
                .padding(.vertical, 7)
                .padding(.horizontal, 6)
                ForEach(bodyColumns) { column in
                    Text(aggregateText(column, totals: totals))
                        .font(groupRowFont)
                        .foregroundColor(groupRowTextColor ?? .primary)
                        .lineLimit(1)
                        .frame(width: columnWidth(column), alignment: .leading)
                        .padding(.vertical, 7)
                        .padding(.horizontal, 6)
                }
            }
            .background(groupRowBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Pinned bottom grand-total row — column-aligned, reading the published
    /// aggregate row (same source as the tile version) and respecting
    /// excludeFromTotals. Sits below the vertical scroll so it stays visible.
    @ViewBuilder
    private func gridTotalRow(bodyColumns: [Column], grouped: Bool) -> some View {
        if let totals = runtime.selections[outputSlug]?.first {
            HStack(spacing: 0) {
                if grouped {
                    Text("Total")
                        .font(grandTotalFont)
                        .foregroundColor(grandTotalTextColor ?? .secondary)
                        .frame(width: Self.autoGroupColumnWidth, alignment: .leading)
                        .padding(.vertical, 7)
                        .padding(.horizontal, 6)
                }
                ForEach(Array(bodyColumns.enumerated()), id: \.element.key) { index, column in
                    let value = column.excludeFromTotals ? "" : aggregateText(column, totals: totals)
                    // Without an auto group column the Total label rides the
                    // first column, unless that column carries an aggregate.
                    Text(!value.isEmpty ? value : (!grouped && index == 0 ? "Total" : ""))
                        .font(grandTotalFont)
                        .foregroundColor(!value.isEmpty ? (grandTotalTextColor ?? .primary)
                                                        : (grandTotalTextColor ?? .secondary))
                        .lineLimit(1)
                        .frame(width: columnWidth(column), alignment: .leading)
                        .padding(.vertical, 7)
                        .padding(.horizontal, 6)
                }
            }
            .background(grandTotalBackground)
        }
    }

    private func aggregateText(_ column: Column, totals: [String: CmsJSON]) -> String {
        guard let fn = column.aggFunc else { return "" }
        let raw = totals["\(column.key)_\(fn)"]?.displayString ?? ""
        if raw.isEmpty { return "" }
        return column.format.map { CmsFormatValue.apply(raw, pattern: $0) } ?? raw
    }

    private func columnWidth(_ column: Column) -> CGFloat {
        min(max(column.width ?? 120, 64), 320)
    }

    // MARK: - Grand total (from the published aggregate row)

    @ViewBuilder
    private func grandTotalRow(columns: [Column]) -> some View {
        if let totals = runtime.selections[outputSlug]?.first {
            // excludeFromTotals hides a column's aggregate in THIS row only —
            // still computed and published for group rows / KPI bindings.
            let aggCols = columns.filter { $0.aggFunc != nil && !$0.excludeFromTotals }
            if !aggCols.isEmpty {
                // No columns to align under — break summaries across rows
                // as wrapping label/value tiles.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12, alignment: .leading)],
                          alignment: .leading, spacing: 10) {
                    ForEach(aggCols) { column in
                        totalTile(column, totals: totals)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.secondary.opacity(0.08))
                )
            }
        }
    }

    private func totalTile(_ column: Column, totals: [String: CmsJSON]) -> some View {
        let value = totals["\(column.key)_\(column.aggFunc ?? "")"]?.displayString ?? ""
        return VStack(alignment: .leading, spacing: 1) {
            Text(column.label)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
            Text(column.format.map { CmsFormatValue.apply(value, pattern: $0) } ?? value)
                .font(.subheadline.weight(.semibold))
        }
    }

    // MARK: - Cells / selection helpers

    private func cellText(_ row: [String: CmsJSON], _ column: Column) -> String {
        // hideDetailValue: the column's meaning lives at group/total level —
        // leaf rows render blank (aggregation still uses the value).
        if column.hideDetailValue { return "" }
        guard let value = row[column.valueFrom], value != .null else { return "" }
        let s = value.displayString
        if let format = column.format, !format.isEmpty {
            return CmsFormatValue.apply(s, pattern: format)
        }
        return s
    }

    private func isSelected(_ row: [String: CmsJSON]) -> Bool {
        (runtime.selections[querySlug] ?? []).contains(row)
    }

    private func toggle(_ row: [String: CmsJSON]) {
        guard selectionMode != "none" else { return }
        let current = runtime.selections[querySlug] ?? []
        let already = current.contains(row)
        if selectionMode == "single" {
            runtime.setSelectedRows(querySlug, rows: already ? [] : [row])
        } else {
            runtime.setSelectedRows(querySlug, rows: already ? current.filter { $0 != row } : current + [row])
        }
    }

    /// Does any visible column drive a drill? Then a row/cell tap opens the
    /// detail (a modal/drawer watching this query), not multi-select.
    private var hasDrillLink: Bool { configuredColumns.contains { $0.drillLink } }

    /// Authored link tint (the web `accentColor` fed to DrillLinkCellRenderer),
    /// falling back to the native accent.
    private var drillLinkColor: Color {
        runtime.theme.resolve(props.string("accentColor")) ?? .accentColor
    }

    /// Drill: publish this row as the query's selection — regardless of
    /// `rowSelectionMode` — so an authored modal/drawer watching `querySlug`
    /// opens. Twin of the web drillLink handler (setSelectedRows(querySlug,[row])).
    private func drill(_ row: [String: CmsJSON]) {
        runtime.setSelectedRows(querySlug, rows: [row])
    }

    // MARK: - Aggregation output (unchanged data role)

    private var stateFingerprint: String {
        guard case .ok(let result) = runtime.state(for: querySlug) else { return "-" }
        let first = result.rows.first.map { CmsRuntime.stableHash($0) } ?? ""
        let last = result.rows.last.map { CmsRuntime.stableHash($0) } ?? ""
        return "\(result.rows.count):\(first.hashValue):\(last.hashValue)"
    }

    struct AggColumn {
        var key: String
        var valueFrom: String
        var fn: String
    }

    private var aggColumns: [AggColumn] {
        guard case .array(let raw) = props["columns"] ?? .null else { return [] }
        return raw.compactMap { entry in
            guard let obj = entry.objectValue,
                  let key = obj.string("key"),
                  let fn = obj.string("aggFunc"), !fn.isEmpty else { return nil }
            return AggColumn(key: key, valueFrom: obj.string("valueFrom") ?? key, fn: fn)
        }
    }

    private func publishAggregates() {
        guard case .ok(let result) = runtime.state(for: querySlug) else { return }
        let columns = aggColumns
        guard !columns.isEmpty else { return }
        var totals = Self.computeTotals(rows: result.rows, columns: columns)
        totals["row_count"] = .number(Double(result.rows.count))

        if let current = runtime.selections[outputSlug]?.first, current == totals { return }
        runtime.setSelectedRows(outputSlug, rows: [totals])
    }

    /// The aggregation fold (twin of computeAggTotals) — shared by the
    /// published output row and per-group summary headers.
    static func computeTotals(rows: [[String: CmsJSON]], columns: [AggColumn]) -> [String: CmsJSON] {
        var totals: [String: CmsJSON] = [:]
        for column in columns {
            var vals: [Double] = []
            var raws: [String] = []
            for row in rows {
                guard let v = row[column.valueFrom], v != .null else { continue }
                let s = v.displayString
                if s.isEmpty { continue }
                raws.append(s)
                if let n = v.doubleValue ?? Double(s) { vals.append(n) }
            }
            let key = "\(column.key)_\(column.fn)"
            switch column.fn {
            case "sum":
                totals[key] = vals.isEmpty ? .null : .number(vals.reduce(0, +))
            case "avg":
                totals[key] = vals.isEmpty ? .null : .number(vals.reduce(0, +) / Double(vals.count))
            case "min":
                totals[key] = vals.min().map { .number($0) } ?? .null
            case "max":
                totals[key] = vals.max().map { .number($0) } ?? .null
            case "count":
                totals[key] = .number(Double(raws.count))
            case "distinctCount":
                totals[key] = .number(Double(Set(raws).count))
            case "first":
                totals[key] = raws.first.map { .string($0) } ?? .null
            case "last":
                totals[key] = raws.last.map { .string($0) } ?? .null
            case "mode":
                var counts: [String: Int] = [:]
                var best: String? = nil
                var bestN = 0
                for r in raws {
                    let n = (counts[r] ?? 0) + 1
                    counts[r] = n
                    if n > bestN { bestN = n; best = r }
                }
                totals[key] = best.map { .string($0) } ?? .null
            default:
                break
            }
        }
        return totals
    }
}

/// Reports the grid body's natural content height (see gridBodyHeight).
private struct GridBodyHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
