import SwiftUI

/// The native property inspector: walks a block type's `CmsInspectorSchema`
/// and renders a native Form — the Swift twin of the web's
/// SchemaPropertyEditor + BlockPropertyPanel. Presented as a sheet when a
/// block is selected in design mode. All edits flow through the
/// `CmsDesignController` (optimistic raw-tree mutation + debounced save),
/// so the rendered page behind the sheet updates live.
///
/// GROUP ZOOM: each section header carries a zoom button — the native twin
/// of the web's OpenInFull group affordance (which opens a dialog of just
/// that group's fields). Natively that's a navigation push into a
/// full-height editor for the group: complex sub-editors (columns) get the
/// whole sheet; Back returns to the full inspector.
public struct CmsPropertyInspectorView: View {
    public let blockId: String
    @ObservedObject var controller: CmsDesignController
    @EnvironmentObject var runtime: CmsRuntime

    /// Group currently zoomed (navigation-pushed). Reset when the selected
    /// block changes so a stale group can't trap the push on an EmptyView.
    @State private var zoomedGroupId: String?

    public init(blockId: String, controller: CmsDesignController) {
        self.blockId = blockId
        self.controller = controller
    }

    public var body: some View {
        NavigationView {
            content
                .navigationTitle("")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { saveStateBadge }
                    ToolbarItem(placement: .principal) { blockPickerMenu }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { runtime.selectedBlockId = nil }
                            .cmsInspectorID("Cms.inspector.doneButton")
                    }
                }
                .onChange(of: blockId) { _ in zoomedGroupId = nil }
        }
        #if os(iOS)
        .navigationViewStyle(.stack)
        #endif
    }

    private var blockPickerMenu: some View {
        let current = controller.block(blockId)
        let label = current.flatMap { $0.name ?? $0.slug } ?? current?.type ?? "Inspector"
        return Menu {
            ForEach(controller.allBlocks(), id: \.block.id) { entry in
                Button {
                    runtime.selectedBlockId = entry.block.id
                } label: {
                    let indent = String(repeating: "  ", count: entry.depth)
                    let name = entry.block.name ?? entry.block.slug ?? entry.block.type
                    Text("\(indent)\(name)")
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(label)
                    .font(.headline)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .cmsInspectorID("Cms.inspector.blockPicker")
    }

    @ViewBuilder private var content: some View {
        if let block = controller.block(blockId) {
            formContent(block)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "square.dashed")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text("This block no longer exists")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func formContent(_ block: CmsBlock) -> some View {
        let schema = CmsInspectorSchemas.schema(for: block.type)
        // Use effective props (base + active view state) for display so the
        // inspector reflects exactly what the renderer sees. Writes still go
        // to the base block via controller.setProp.
        let displayProps = runtime.effectiveDisplayProps(for: block)
        let viewActive = runtime.hasActiveViewState(for: block)
        return Form {
            Section("Identity") {
                Toggle("Hidden", isOn: hiddenBinding(block))
                Picker("Visible on", selection: visibleOnBinding(block)) {
                    Text("All").tag(VisibleOnOption.all)
                    Text("Mobile").tag(VisibleOnOption.mobile)
                    Text("Desktop").tag(VisibleOnOption.desktop)
                }
            }
            Section {
                infoRow("Type", value: block.type)
                if let name = block.name, !name.isEmpty {
                    infoRow("Name", value: name)
                }
                infoRow("Slug", value: block.slug ?? block.id)
            }
            if viewActive {
                Section {
                    Label("A saved view is active — showing view's columns. Edits apply to the base block.", systemImage: "square.3.layers.3d")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            if let schema {
                ForEach(schema.groups, id: \.id) { group in
                    let fields = schema.fields(in: group.id, props: displayProps)
                    if !fields.isEmpty {
                        Section(header: groupHeader(group, canZoom: Self.canZoom(fields: fields))) {
                            ForEach(fields, id: \.key) { field in
                                CmsInspectorFieldRow(
                                    field: field,
                                    props: displayProps,
                                    onSet: { set(field, $0) }
                                )
                            }
                        }
                    }
                }
            } else {
                Section {
                    Text("No native-editable properties for this block yet.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        }
        .background(
            NavigationLink(
                destination: zoomDestination(block: block),
                isActive: Binding(
                    get: { zoomedGroupId != nil },
                    set: { if !$0 { zoomedGroupId = nil } }
                ),
                label: { EmptyView() }
            )
        )
    }

    /// Whether zooming a group into its own full-height editor buys the user
    /// anything. Groups with a complex sub-editor (columns) always benefit;
    /// scalar groups only once they're tall enough that the compact sheet
    /// feels cramped — small groups just get the affordance hidden.
    private static func canZoom(fields: [CmsPropertyField]) -> Bool {
        if fields.contains(where: { $0.kind.isComplexEditor }) { return true }
        return fields.count >= 5
    }

    /// Section header with the group-zoom affordance — twin of the web
    /// accordion's OpenInFull button (hidden for small groups, see canZoom).
    private func groupHeader(_ group: CmsPropertyGroup, canZoom: Bool) -> some View {
        HStack {
            Text(group.label)
            Spacer()
            if canZoom {
                Button {
                    zoomedGroupId = group.id
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Zoom \(group.label)")
                .cmsInspectorID("Cms.inspector.\(group.id).zoomButton")
            }
        }
    }

    @ViewBuilder
    private func zoomDestination(block: CmsBlock) -> some View {
        if let schema = CmsInspectorSchemas.schema(for: block.type),
           let groupId = zoomedGroupId,
           let group = schema.groups.first(where: { $0.id == groupId }) {
            CmsInspectorGroupView(
                blockId: block.id,
                group: group,
                schema: schema,
                onClose: { zoomedGroupId = nil },
                controller: controller
            )
        } else {
            EmptyView()
        }
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundColor(.secondary)
            Spacer()
            Text(value).lineLimit(1).truncationMode(.middle)
        }
    }

    private func set(_ field: CmsPropertyField, _ value: CmsJSON?) {
        // Update view state FIRST so effectiveDisplayProps returns the new
        // value in any re-render triggered by setProp (which calls
        // onPagesDidChange synchronously). Without this the view state still
        // holds the old value during the first render after setProp fires,
        // and the merge overwrites the just-written base value → snap back.
        if let block = controller.block(blockId),
           runtime.hasActiveViewState(for: block) {
            let slug = block.slug ?? block.id
            runtime.updateViewStateProp(slug, key: field.key, value: value)
            // Also write into the PERSISTED view definition so the change
            // survives when the user switches views (apply() re-applies the
            // saved snapshot, which would otherwise overwrite in-memory edits).
            if let activeViewId = runtime.gridViewActiveIds[slug] {
                controller.setPropInActiveViewState(
                    gridSlug: slug, activeViewId: activeViewId, key: field.key, value: value
                )
                return
            }
        }
        controller.setProp(blockId: blockId, key: field.key, value: value)
    }

    // MARK: - Block-level metadata (Identity)

    private enum VisibleOnOption: String, Equatable {
        case all, mobile, desktop
    }

    private func visibleOnOption(for block: CmsBlock) -> VisibleOnOption {
        guard let visibleOn = block.visibleOn, visibleOn.count == 1 else { return .all }
        switch visibleOn[0] {
        case "mobile": return .mobile
        case "desktop": return .desktop
        default: return .all
        }
    }

    private func visibleOnBinding(_ block: CmsBlock) -> Binding<VisibleOnOption> {
        Binding(
            get: { visibleOnOption(for: block) },
            set: { option in
                let value: CmsJSON?
                switch option {
                case .all:
                    value = nil
                case .mobile:
                    value = .array([.string("mobile")])
                case .desktop:
                    value = .array([.string("desktop")])
                }
                controller.setBlockMeta(blockId: blockId, visibleOn: value)
            }
        )
    }

    private func hiddenBinding(_ block: CmsBlock) -> Binding<Bool> {
        Binding(
            get: { block.hidden == true },
            set: { isHidden in
                controller.setBlockMeta(blockId: blockId, hidden: isHidden ? .bool(true) : nil)
            }
        )
    }

    // MARK: - Save state

    @ViewBuilder private var saveStateBadge: some View {
        switch controller.saveState {
        case .idle:
            EmptyView()
        case .dirty:
            Text("Unsaved")
                .font(.caption)
                .foregroundColor(.secondary)
        case .saving:
            ProgressView()
        case .saved:
            Label("Saved", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundColor(.green)
        case .failed:
            Button {
                Task { await controller.saveNow() }
            } label: {
                Label("Save failed — retry", systemImage: "exclamationmark.arrow.circlepath")
                    .font(.caption)
                    .foregroundColor(.red)
            }
            .cmsInspectorID("Cms.inspector.saveRetryButton")
        }
    }
}

/// The zoomed group editor: one group's fields at full sheet height — the
/// native reading of the web's PropertyEditorDialog (which renders a single
/// group's rows in a modal). Reads the block live off the controller so
/// edits made here are visible when navigating back.
private struct CmsInspectorGroupView: View {
    let blockId: String
    let group: CmsPropertyGroup
    let schema: CmsInspectorSchema
    let onClose: () -> Void
    @ObservedObject var controller: CmsDesignController
    @EnvironmentObject var runtime: CmsRuntime

    var body: some View {
        let block = controller.block(blockId)
        let props = block.map { runtime.effectiveDisplayProps(for: $0) } ?? [:]
        let fields = schema.fields(in: group.id, props: props)
        let complex = fields.filter { $0.kind.isComplexEditor }
        let scalars = fields.filter { !$0.kind.isComplexEditor }
        Group {
            if complex.isEmpty {
                Form {
                    Section {
                        fieldRows(scalars, expanded: false)
                    }
                }
            } else {
                // A complex editor (columns) gets the full sheet: the group's
                // scalar props stay in a compact Form on top and the editor
                // fills everything below — this is where the zoom's extra
                // space actually lands.
                VStack(spacing: 0) {
                    if !scalars.isEmpty {
                        Form {
                            Section {
                                fieldRows(scalars, expanded: false)
                            }
                        }
                        .frame(maxHeight: Self.scalarPaneHeight(rowCount: scalars.count))
                    }
                    VStack {
                        fieldRows(complex, expanded: true)
                    }
                    .padding(.horizontal)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background(Self.sheetBackground)
            }
        }
        .navigationTitle(group.label)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #else
        // macOS sheets render no navigation bar / back button for the push —
        // provide the way back explicitly.
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(action: onClose) {
                    Label("Back", systemImage: "chevron.left")
                }
                .cmsInspectorID("Cms.inspector.backButton")
            }
        }
        #endif
    }

    @ViewBuilder
    private func fieldRows(_ fields: [CmsPropertyField], expanded: Bool) -> some View {
        let props = controller.block(blockId).map { runtime.effectiveDisplayProps(for: $0) } ?? [:]
        ForEach(fields, id: \.key) { field in
            CmsInspectorFieldRow(
                field: field,
                props: props,
                expanded: expanded,
                onSet: { value in
                    if let block = controller.block(blockId),
                       runtime.hasActiveViewState(for: block) {
                        let slug = block.slug ?? block.id
                        runtime.updateViewStateProp(slug, key: field.key, value: value)
                        if let activeViewId = runtime.gridViewActiveIds[slug] {
                            controller.setPropInActiveViewState(
                                gridSlug: slug, activeViewId: activeViewId,
                                key: field.key, value: value
                            )
                            return
                        }
                    }
                    controller.setProp(blockId: blockId, key: field.key, value: value)
                }
            )
        }
    }

    /// Content-hugging height for the scalar pane above a zoomed complex
    /// editor (~58pt/row, capped so a large scalar set scrolls instead of
    /// squeezing the editor out).
    private static func scalarPaneHeight(rowCount: Int) -> CGFloat {
        min(CGFloat(rowCount) * 58 + 20, 280)
    }

    private static var sheetBackground: Color {
        #if canImport(UIKit)
        Color(uiColor: .systemGroupedBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }
}

/// One property row — shared by the full inspector form and the zoomed
/// group editor so both render identical controls. `expanded` is passed to
/// complex sub-editors (columns) so they fill the zoom view instead of
/// keeping their compact inline height cap.
private struct CmsInspectorFieldRow: View {
    let field: CmsPropertyField
    let props: [String: CmsJSON]
    var expanded: Bool = false
    let onSet: (CmsJSON?) -> Void
    @EnvironmentObject var runtime: CmsRuntime

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            control
            if let helper = field.helperText, !helper.isEmpty {
                Text(helper)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        // Per-row View Explorer identity — a plain a11y id, NOT a stamper:
        // Form rows are lazy, and the stamper is a real UIView per instance
        // (see CmsInspectorID). The audit + tap tree-read recover this.
        .accessibilityIdentifier("Cms.inspector.field.\(field.key)")
    }

    @ViewBuilder private var control: some View {
        switch field.kind {
        case .boolean:
            Toggle(field.label, isOn: Binding(
                get: { field.value(in: props)?.boolValue ?? false },
                set: { onSet(.bool($0)) }
            ))

        case .string(let placeholder):
            TextField(field.label, text: Binding(
                get: { field.value(in: props)?.stringValue ?? "" },
                set: { onSet(.string($0)) }
            ), prompt: Text(placeholder ?? ""))

        case .number(let min, let max, let step, let unit):
            numberStepper(min: min, max: max, step: step, unit: unit) { .number($0) }

        case .numberString(let min, let max, let step, let unit):
            numberStepper(min: min, max: max, step: step, unit: unit) {
                .string(Self.formatNumber($0))
            }

        case .select(let options):
            selectControl(options: options)

        case .queryRef(let emptyLabel):
            refPicker(emptyLabel: emptyLabel ?? "None",
                      options: runtime.queryDefs.keys.sorted())

        case .cardViewRef(let emptyLabel):
            refPicker(emptyLabel: emptyLabel ?? "None",
                      options: runtime.cardViews.keys.sorted())

        case .color:
            CmsColorField(
                label: field.label,
                value: props.string(field.key),
                resolve: { runtime.color($0) },
                onChange: onSet
            )

        case .columns(let querySlugKey):
            CmsColumnsField(
                querySlugKey: querySlugKey,
                props: props,
                onChange: { onSet(.array($0.map(\.json))) },
                expanded: expanded
            )
        }
    }

    private func numberStepper(
        min: Double?, max: Double?, step: Double?, unit: String?,
        wrap: @escaping (Double) -> CmsJSON
    ) -> some View {
        let lower = min ?? 0
        let upper = max ?? 10_000
        let current = field.value(in: props)?.doubleValue
            ?? field.value(in: props)?.stringValue.flatMap { Double($0) }
            ?? lower
        return Stepper(value: Binding(
            get: { current },
            set: { onSet(wrap($0)) }
        ), in: lower...upper, step: step ?? 1) {
            HStack {
                Text(field.label)
                Spacer()
                Text(Self.formatNumber(current) + (unit.map { " \($0)" } ?? ""))
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private func selectControl(options: [CmsPropertyOption]) -> some View {
        let binding = Binding<String>(
            get: { field.value(in: props)?.stringValue ?? "" },
            set: { onSet(.string($0)) }
        )
        if options.count <= 3 {
            // The web's `appearance: 'toggle'` — natively, a segmented control.
            VStack(alignment: .leading, spacing: 6) {
                Text(field.label)
                    .font(.subheadline)
                Picker(field.label, selection: binding) {
                    ForEach(options, id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        } else {
            Picker(field.label, selection: binding) {
                ForEach(options, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
        }
    }

    private func refPicker(emptyLabel: String, options: [String]) -> some View {
        Picker(field.label, selection: Binding<String>(
            get: { field.value(in: props)?.stringValue ?? "" },
            set: { onSet(.string($0)) }
        )) {
            Text(emptyLabel).tag("")
            ForEach(options, id: \.self) { slug in
                Text(slug).tag(slug)
            }
        }
    }

    static func formatNumber(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15
            ? String(Int64(value))
            : String(value)
    }
}

/// Colour prop editor: mirrors the web's `TokenColorInput`.
/// Shows theme-token swatches, a custom colour picker, and an editable raw
/// value so users can author `color.primary` or a hex literal.
private struct CmsColorField: View {
    let label: String
    let value: String?
    let resolve: (String?) -> Color?
    let onChange: (CmsJSON?) -> Void

    @State private var picked: Color = .black

    /// The semantic token swatches surfaced in the web colour picker.
    private let tokens: [TokenSwatch] = [
        TokenSwatch(token: "color.primary", label: "Primary"),
        TokenSwatch(token: "color.secondary", label: "Secondary"),
        TokenSwatch(token: "color.text.primary", label: "Text"),
        TokenSwatch(token: "color.text.secondary", label: "Muted"),
        TokenSwatch(token: "color.background", label: "Background"),
        TokenSwatch(token: "color.paper", label: "Paper"),
        TokenSwatch(token: "color.divider", label: "Divider"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(label)
                Spacer(minLength: 0)
                tokenSwatches
                customColorPicker
            }

            if value != nil {
                HStack(spacing: 6) {
                    TextField("#hex or color.token", text: textBinding)
                        .font(.caption)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                    Button("Clear") { onChange(nil) }
                        .font(.caption)
                }
            }
        }
        .onAppear { syncPicked() }
        .onChange(of: value) { _ in syncPicked() }
    }

    private var tokenSwatches: some View {
        let primary = resolve("color.primary") ?? .primary
        let divider = resolve("color.divider") ?? Color.secondary.opacity(0.3)
        return HStack(spacing: 6) {
            ForEach(tokens) { swatch in
                Button {
                    onChange(.string(swatch.token))
                } label: {
                    let selected = value == swatch.token
                    Circle()
                        .fill(resolve(swatch.token) ?? .clear)
                        .frame(width: 20, height: 20)
                        .overlay(
                            Circle()
                                .stroke(selected ? primary : divider, lineWidth: selected ? 2 : 1)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(swatch.label)
            }
        }
    }

    private var customColorPicker: some View {
        ColorPicker("", selection: Binding(
            get: { picked },
            set: { new in
                picked = new
                onChange(.string(Self.hexString(new)))
            }
        ), supportsOpacity: true)
        .labelsHidden()
        .frame(width: 28, height: 28)
    }

    private var textBinding: Binding<String> {
        Binding(
            get: { value ?? "" },
            set: { new in
                let trimmed = new.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    onChange(nil)
                } else {
                    onChange(.string(trimmed))
                }
            }
        )
    }

    /// Follow external value changes (e.g. undo of a Clear) — CSS literals
    /// only; theme tokens leave the picker untouched.
    private func syncPicked() {
        if let value, let parsed = CmsCss.color(value) {
            picked = parsed
        }
    }

    static func hexString(_ color: Color) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if canImport(UIKit)
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        #else
        (NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color))
            .getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        let ri = Int((r * 255).rounded()), gi = Int((g * 255).rounded())
        let bi = Int((b * 255).rounded()), ai = Int((a * 255).rounded())
        return a < 0.999
            ? String(format: "#%02X%02X%02X%02X", ri, gi, bi, ai)
            : String(format: "#%02X%02X%02X", ri, gi, bi)
    }
}

private struct TokenSwatch: Identifiable {
    let token: String
    let label: String
    var id: String { token }
}
