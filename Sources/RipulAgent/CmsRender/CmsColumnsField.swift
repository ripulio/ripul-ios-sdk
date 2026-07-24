import SwiftUI

/// One configured column slot — the native twin of the web's `ColumnDef`.
/// Stored in `props.columns` as an array of objects; this struct round-trips
/// the fields the native AG Grid renderer consumes.
struct CmsColumnConfig: Identifiable, Equatable {
    var id: String { key }
    var key: String
    var valueFrom: String
    var label: String
    var visible: Bool
    var width: Double?
    var pinned: String?   // "left" | "right"
    var rowGroup: Bool
    var aggFunc: String?
    var excludeFromTotals: Bool
    var hideDetailValue: Bool
    var format: String?
    var transform: String?
    var drillLink: Bool
    var image: [String: CmsJSON]?

    init(key: String, valueFrom: String? = nil, label: String? = nil, visible: Bool = true,
         width: Double? = nil, pinned: String? = nil, rowGroup: Bool = false,
         aggFunc: String? = nil, excludeFromTotals: Bool = false, hideDetailValue: Bool = false,
         format: String? = nil, transform: String? = nil, drillLink: Bool = false, image: [String: CmsJSON]? = nil) {
        self.key = key
        self.valueFrom = valueFrom ?? key
        self.label = label ?? CmsRecordCardsBlockView.humanize(key)
        self.visible = visible
        self.width = width
        self.pinned = pinned
        self.rowGroup = rowGroup
        self.aggFunc = aggFunc
        self.excludeFromTotals = excludeFromTotals
        self.hideDetailValue = hideDetailValue
        self.format = format
        self.transform = transform
        self.drillLink = drillLink
        self.image = image
    }

    init?(json: CmsJSON) {
        guard let obj = json.objectValue, let key = obj.string("key") else { return nil }
        self.key = key
        self.valueFrom = obj.string("valueFrom") ?? key
        self.label = obj.string("label") ?? CmsRecordCardsBlockView.humanize(key)
        self.visible = obj.bool("visible") ?? true
        self.width = obj.double("width")
        self.pinned = obj.string("pinned")
        self.rowGroup = obj.bool("rowGroup") ?? false
        self.aggFunc = obj.string("aggFunc")
        self.excludeFromTotals = obj.bool("excludeFromTotals") ?? false
        self.hideDetailValue = obj.bool("hideDetailValue") ?? false
        self.format = obj.string("format")
        self.transform = obj.string("transform")
        self.drillLink = obj.bool("drillLink") ?? false
        self.image = obj.object("image")
    }

    var json: CmsJSON {
        var obj: [String: CmsJSON] = ["key": .string(key)]
        if valueFrom != key { obj["valueFrom"] = .string(valueFrom) }
        if label != CmsRecordCardsBlockView.humanize(key) { obj["label"] = .string(label) }
        if visible == false { obj["visible"] = .bool(false) }
        if let width { obj["width"] = .number(width) }
        if let pinned { obj["pinned"] = .string(pinned) }
        if rowGroup { obj["rowGroup"] = .bool(true) }
        if let aggFunc { obj["aggFunc"] = .string(aggFunc) }
        if excludeFromTotals { obj["excludeFromTotals"] = .bool(true) }
        if hideDetailValue { obj["hideDetailValue"] = .bool(true) }
        if let format { obj["format"] = .string(format) }
        if let transform { obj["transform"] = .string(transform) }
        if drillLink { obj["drillLink"] = .bool(true) }
        if let image { obj["image"] = .object(image) }
        return .object(obj)
    }
}

/// Native column-config editor for data-bound grids. Shows the union of the
/// saved `columns` array and the query schema, lets the author reorder, hide,
/// relabel, and edit per-column properties. Functional parity with the web's
/// `ColumnsConfigEditor`; presentation is native-first (SwiftUI List, sheets,
/// toggles).
struct CmsColumnsField: View {
    let querySlugKey: String
    let props: [String: CmsJSON]
    let onChange: ([CmsColumnConfig]) -> Void
    /// Compact (default) renders inside an inspector Form row with a capped
    /// list height; expanded renders in the zoomed group view where the list
    /// fills the sheet. The two modes are the native answer to the web
    /// editor's inline box vs. OpenInFull dialog.
    var expanded: Bool = false
    @EnvironmentObject var runtime: CmsRuntime

    private var querySlug: String { props.string(querySlugKey) ?? "" }
    private var schema: [CmsQueryResultColumn] { runtime.schema(for: querySlug) ?? [] }

    @State private var searchText = ""
    @State private var expandedKey: String?
    @State private var showAddSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if schema.isEmpty {
                Label(querySlug.isEmpty ? "Pick a query above to configure columns."
                                        : "Run the query once to load the column schema.",
                      systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else {
                searchBar
                columnList
                footer
            }
        }
    }

    // MARK: - Resolved columns

    private var configuredColumns: [CmsColumnConfig] {
        guard case .array(let raw) = props["columns"] ?? .null else { return [] }
        return raw.compactMap { CmsColumnConfig(json: $0) }
    }

    private var resolvedColumns: [CmsColumnConfig] {
        var out = configuredColumns
        let seen = Set(out.map(\.key))
        for col in schema where !seen.contains(col.name) {
            out.append(CmsColumnConfig(key: col.name))
        }
        return out
    }

    private var filteredColumns: [CmsColumnConfig] {
        if searchText.isEmpty { return resolvedColumns }
        return resolvedColumns.filter {
            $0.key.localizedCaseInsensitiveContains(searchText)
                || $0.label.localizedCaseInsensitiveContains(searchText)
        }
    }

    // MARK: - Subviews

    @ViewBuilder private var header: some View {
        HStack {
            Text("Columns")
                .font(.subheadline.weight(.semibold))
            Spacer()
            Text("\(resolvedColumns.count)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundColor(.secondary)
            TextField("Filter columns…", text: $searchText)
                .font(.subheadline)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.secondary.opacity(0.1)))
        .cmsInspectorID("Cms.inspector.columns.search")
    }

    @ViewBuilder private var columnList: some View {
        List {
            ForEach(filteredColumns) { column in
                ColumnRow(
                    column: column,
                    isExpanded: expandedKey == column.key,
                    schema: schema,
                    onToggleExpand: { expandedKey = (expandedKey == column.key) ? nil : column.key },
                    onUpdate: { updated in
                        let next = resolvedColumns.map { $0.key == updated.key ? updated : $0 }
                        onChange(next)
                    }
                )
            }
            .onMove { indices, destination in
                guard searchText.isEmpty else { return }
                var next = resolvedColumns
                next.move(fromOffsets: indices, toOffset: destination)
                onChange(next)
            }
            .deleteDisabled(true)
        }
        .listStyle(.plain)
        .frame(minHeight: expanded ? 320 : 180,
               maxHeight: expanded ? .infinity : 360)
        #if os(iOS)
        .environment(\.editMode, .constant(.active))
        #endif
    }

    @ViewBuilder private var footer: some View {
        HStack {
            Text(searchText.isEmpty ? "Drag to reorder. Tap a column for options." : "Clear search to reorder.")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Button {
                onChange(resetToSchemaOrder(configured: configuredColumns, schemaNames: schema.map(\.name)))
            } label: {
                Label("Reset to schema order", systemImage: "arrow.counterclockwise")
                    .font(.caption)
            }
            .disabled(!canReset)
            .buttonStyle(.borderless)
            .cmsInspectorID("Cms.inspector.columns.reset")
        }
    }

    private var canReset: Bool {
        guard !schema.isEmpty else { return false }
        let configuredKeys = configuredColumns.map(\.key)
        let schemaNames = schema.map(\.name)
        return configuredKeys != schemaNames
    }

    private func resetToSchemaOrder(configured: [CmsColumnConfig], schemaNames: [String]) -> [CmsColumnConfig] {
        let byKey = Dictionary(configured.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var out: [CmsColumnConfig] = schemaNames.compactMap { byKey[$0] }
        let seen = Set(schemaNames)
        out.append(contentsOf: configured.filter { !seen.contains($0.key) })
        return out
    }
}

// MARK: - Per-column row

private struct ColumnRow: View {
    let column: CmsColumnConfig
    let isExpanded: Bool
    let schema: [CmsQueryResultColumn]
    let onToggleExpand: () -> Void
    let onUpdate: (CmsColumnConfig) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "line.horizontal.3")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button {
                    var next = column
                    next.visible.toggle()
                    onUpdate(next)
                } label: {
                    Image(systemName: column.visible ? "eye" : "eye.slash")
                        .font(.caption)
                        .foregroundColor(column.visible ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("Cms.inspector.columns.row.\(column.key).visibility")

                VStack(alignment: .leading, spacing: 2) {
                    TextField("Label", text: Binding(
                        get: { column.label },
                        set: { next in
                            var c = column
                            c.label = next
                            onUpdate(c)
                        }
                    ))
                    .font(.subheadline)
                    Text(column.key)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text(typeLabel)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))

                Button(action: onToggleExpand) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("Cms.inspector.columns.row.\(column.key).expand")
            }
            .padding(.vertical, 6)

            if isExpanded {
                detailForm
                    .padding(.leading, 28)
                    .padding(.bottom, 8)
            }
        }
        // Per-row View Explorer identity — plain a11y ids, NOT stampers: this
        // List is lazy and the stamper is a real UIView per instance (see
        // CmsInspectorID). The audit + tap tree-read recover these.
        .accessibilityIdentifier("Cms.inspector.columns.row.\(column.key)")
    }

    private var typeLabel: String {
        schema.first { $0.name == column.valueFrom }?.type
            ?? schema.first { $0.name == column.key }?.type
            ?? ""
    }

    @ViewBuilder private var detailForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            if schema.count > 1 {
                Picker("Source column", selection: Binding<String>(
                    get: { column.valueFrom },
                    set: { next in
                        var c = column
                        c.valueFrom = next
                        onUpdate(c)
                    }
                )) {
                    ForEach(schema, id: \.name) { col in
                        Text("\(col.name) \(col.type.map { "(\($0))" } ?? "")").tag(col.name)
                    }
                }
                .pickerStyle(.menu)
            }

            HStack {
                Stepper(value: Binding<Double>(
                    get: { column.width ?? 0 },
                    set: { next in
                        var c = column
                        c.width = next > 0 ? next : nil
                        onUpdate(c)
                    }
                ), in: 0...600, step: 10) {
                    HStack {
                        Text("Width")
                        Spacer()
                        Text(column.width.map { "\(Int($0)) px" } ?? "Auto")
                            .foregroundColor(.secondary)
                    }
                }
            }

            Picker("Pinned", selection: Binding<String>(
                get: { column.pinned ?? "" },
                set: { next in
                    var c = column
                    c.pinned = next.isEmpty ? nil : next
                    onUpdate(c)
                }
            )) {
                Text("None").tag("")
                Text("Left").tag("left")
                Text("Right").tag("right")
            }
            .pickerStyle(.segmented)

            Picker("Aggregate", selection: Binding<String>(
                get: { column.aggFunc ?? "" },
                set: { next in
                    var c = column
                    c.aggFunc = next.isEmpty ? nil : next
                    onUpdate(c)
                }
            )) {
                Text("None").tag("")
                Text("Sum").tag("sum")
                Text("Average").tag("avg")
                Text("Min").tag("min")
                Text("Max").tag("max")
                Text("Count").tag("count")
                Text("Distinct").tag("distinctCount")
            }

            Toggle("Row group", isOn: Binding(
                get: { column.rowGroup },
                set: { next in
                    var c = column
                    c.rowGroup = next
                    onUpdate(c)
                }
            ))

            Toggle("Exclude from totals", isOn: Binding(
                get: { column.excludeFromTotals },
                set: { next in
                    var c = column
                    c.excludeFromTotals = next
                    onUpdate(c)
                }
            ))

            Toggle("Hide detail value", isOn: Binding(
                get: { column.hideDetailValue },
                set: { next in
                    var c = column
                    c.hideDetailValue = next
                    onUpdate(c)
                }
            ))

            Toggle("Drill link", isOn: Binding(
                get: { column.drillLink },
                set: { next in
                    var c = column
                    c.drillLink = next
                    onUpdate(c)
                }
            ))

            CmsFormatPatternField(
                value: column.format,
                transform: column.transform,
                onChange: { next in
                    var c = column
                    c.format = next
                    onUpdate(c)
                },
                onTransformChange: { next in
                    var c = column
                    c.transform = next
                    onUpdate(c)
                }
            )
        }
    }
}

// MARK: - Format pattern picker

private struct FormatPreset: Identifiable {
    let id = UUID()
    let label: String
    let pattern: String
    let preview: String
}

private struct FormatGroup: Identifiable {
    let id = UUID()
    let title: String
    let presets: [FormatPreset]
}

private struct TransformPresetItem {
    let label: String
    let value: String
    let description: String
}

private let transformPresets: [TransformPresetItem] = [
    TransformPresetItem(label: "Seconds → Minutes",  value: "seconds_to_minutes",      description: "÷ 60"),
    TransformPresetItem(label: "Seconds → Hours",    value: "seconds_to_hours",         description: "÷ 3,600"),
    TransformPresetItem(label: "ms → Seconds",       value: "milliseconds_to_seconds",  description: "÷ 1,000"),
    TransformPresetItem(label: "ms → Minutes",       value: "milliseconds_to_minutes",  description: "÷ 60,000"),
]

/// Native twin of the web's FormatPatternFieldInput — shows preset groups
/// (Number, Duration, Date, etc.) plus a free-text field for custom patterns.
private struct CmsFormatPatternField: View {
    let value: String?
    let transform: String?
    let onChange: (String?) -> Void
    let onTransformChange: (String?) -> Void

    @State private var showPicker = false

    private static let groups: [FormatGroup] = [
        FormatGroup(title: "Number", presets: [
            FormatPreset(label: "Integer",       pattern: "#,##0",      preview: "1,235"),
            FormatPreset(label: "Decimal (2dp)", pattern: "#,##0.00",   preview: "1,234.50"),
            FormatPreset(label: "Plain integer", pattern: "0",          preview: "42"),
        ]),
        FormatGroup(title: "Currency", presets: [
            FormatPreset(label: "USD ($)",       pattern: "$#,##0.00",  preview: "$1,234.56"),
            FormatPreset(label: "EUR (\u{20AC})", pattern: "\u{20AC}#,##0.00", preview: "\u{20AC}1,234.56"),
            FormatPreset(label: "GBP (\u{00A3})", pattern: "\u{00A3}#,##0.00", preview: "\u{00A3}1,234.56"),
        ]),
        FormatGroup(title: "Percent", presets: [
            FormatPreset(label: "Percent (0dp)", pattern: "0%",         preview: "86%"),
            FormatPreset(label: "Percent (2dp)", pattern: "0.00%",      preview: "85.64%"),
        ]),
        FormatGroup(title: "Duration", presets: [
            FormatPreset(label: "mm:ss",         pattern: "mm:ss",      preview: "01:02"),
            FormatPreset(label: "hh:mm:ss",      pattern: "hh:mm:ss",   preview: "01:02:05"),
        ]),
        FormatGroup(title: "Date", presets: [
            FormatPreset(label: "DD/MM/YYYY",    pattern: "dd/MM/yyyy", preview: "15/05/2026"),
            FormatPreset(label: "15 May 2026",   pattern: "d MMM yyyy", preview: "15 May 2026"),
            FormatPreset(label: "YYYY-MM-DD",    pattern: "yyyy-MM-dd", preview: "2026-05-15"),
        ]),
        FormatGroup(title: "Date & Time", presets: [
            FormatPreset(label: "Short",         pattern: "dd/MM/yyyy HH:mm", preview: "15/05/2026 14:30"),
            FormatPreset(label: "Medium",        pattern: "d MMM yyyy HH:mm", preview: "15 May 2026 14:30"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Transform picker — applied before the format pattern
            VStack(alignment: .leading, spacing: 4) {
                Text("Transform")
                    .font(.subheadline)
                Picker("Transform", selection: Binding(
                    get: { transform ?? "" },
                    set: { onTransformChange($0.isEmpty ? nil : $0) }
                )) {
                    Text("None").tag("")
                    ForEach(transformPresets, id: \.value) { preset in
                        Text("\(preset.label)  \(preset.description)").tag(preset.value)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            // Format pattern field
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Format")
                        .font(.subheadline)
                    Spacer()
                    Button {
                        showPicker = true
                    } label: {
                        Label("Presets", systemImage: "list.bullet")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    if value != nil {
                        Button("Clear") { onChange(nil) }
                            .font(.caption)
                            .buttonStyle(.borderless)
                            .foregroundColor(.secondary)
                    }
                }
                TextField("e.g. mm:ss or #,##0.00", text: Binding(
                    get: { value ?? "" },
                    set: { onChange($0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0.trimmingCharacters(in: .whitespaces)) }
                ))
                .font(.subheadline)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            }
        }
        .sheet(isPresented: $showPicker) {
            FormatPresetPicker(groups: Self.groups, current: value) { picked in
                onChange(picked)
                showPicker = false
            }
        }
    }
}

private struct FormatPresetPicker: View {
    let groups: [FormatGroup]
    let current: String?
    let onSelect: (String) -> Void

    var body: some View {
        NavigationView {
            List {
                ForEach(groups) { group in
                    Section(group.title) {
                        ForEach(group.presets) { preset in
                            Button {
                                onSelect(preset.pattern)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(preset.label)
                                            .foregroundColor(.primary)
                                        Text(preset.pattern)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .monospaced()
                                    }
                                    Spacer()
                                    Text(preset.preview)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    if current == preset.pattern {
                                        Image(systemName: "checkmark")
                                            .font(.caption.weight(.semibold))
                                            .foregroundColor(.accentColor)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Format preset")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        #if os(iOS)
        .navigationViewStyle(.stack)
        #endif
    }
}
