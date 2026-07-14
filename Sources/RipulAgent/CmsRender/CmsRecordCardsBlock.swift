import SwiftUI

/// Native twin of the web `recordCards` block (RecordCardsBlock.tsx),
/// scoped to the MOBILE responsive presentation (the sub-`sm` /
/// `forceMobileView` behavior): a single phone-width column of cards, fields
/// stacked in flow (never the placed grid), and dropdown mode opening a
/// full-screen list sheet instead of the card popover.
///
/// Mirrored semantics: column config from `fields` (key/valueFrom/label/
/// visible/format/checkbox) with schema fallback, per-card `title` text with
/// `@column` tokens, banner/avatar image, selection modes (none/single/multi,
/// checkbox selection, suppressRowClickSelection, selectAllByDefault) all
/// publishing to the shared querySlug selection.
///
/// Fields resolve from a shared column view (`columnViewRef`) when set —
/// so a curated/ordered/labelled set with per-field `image` config drives
/// the card (e.g. carddemo's `headshot`) — else inline `fields`, else
/// schema. Not in this v: editing/mutations (cards are read-only),
/// `columnDefsRef` (a columnDefs BLOCK, ranks below columnViewRef),
/// foreign-relationship enrichment, mobileRowTemplate, style rules/lozenges.
struct CmsRecordCardsBlockView: View {
    let block: CmsBlock
    @EnvironmentObject var runtime: CmsRuntime
    @State private var seededSelectAll = false
    @State private var showPickerSheet = false

    // MARK: - Props

    private var querySlug: String { block.props.string("querySlug") ?? "" }
    private var isDropdown: Bool { block.props.string("displayMode") == "dropdown" }
    private var selectionMode: String { block.props.string("rowSelectionMode") ?? "none" }
    private var showCheckbox: Bool { block.props.bool("enableCheckboxSelection") ?? false }
    private var clickSelects: Bool { !(block.props.bool("suppressRowClickSelection") ?? false) }
    private var gap: CGFloat { CGFloat(block.props.double("gap") ?? 2) * 8 }
    private var cardVariant: String { block.props.string("cardVariant") ?? "outlined" }
    private var imageColumn: String { block.props.string("imageColumn") ?? "" }
    private var imageHeight: CGFloat { CGFloat(block.props.double("imageHeight") ?? 140) }
    private var isBannerImage: Bool { (block.props.string("imageShape") ?? "banner") == "banner" }
    private var showImageInCard: Bool { block.props.bool("showImageInCard") ?? true }

    private struct Field {
        var key: String
        var valueFrom: String
        var label: String
        var format: String?
        var checkbox: Bool
        /// Explicit per-field `image` config (ImageCellConfig) — presence
        /// renders the URL value as an image, like the web's `image={...}`.
        /// (The web's name-heuristic `isImage` only fires for FOREIGN lookup
        /// columns, which native doesn't resolve yet — so plain columns stay
        /// text, matching the web.)
        var image: [String: CmsJSON]?
    }

    /// Field source, in the web's precedence: a shared column view
    /// (`columnViewRef`) wins over inline `fields`; then schema fallback.
    /// (`columnDefsRef` — a columnDefs BLOCK by slug — is still deferred; it
    /// ranks below columnViewRef which is what the shared cards use.) The
    /// column view carries labels/visibility/order/format/`image` config, so
    /// e.g. carddemo's `headshot` gets `image: {}` and renders as a photo.
    private func resolvedFields(schema: [CmsQueryResultColumn]) -> [Field] {
        var source: [CmsJSON]?
        if let ref = block.props.string("columnViewRef"), !ref.isEmpty,
           let cols = runtime.columnViews[ref]?.columns, !cols.isEmpty {
            source = cols
        } else if case .array(let raw) = block.props["fields"] ?? .null, !raw.isEmpty {
            source = raw
        }
        if let source {
            let fields = source.compactMap { entry -> Field? in
                guard let obj = entry.objectValue, let key = obj.string("key") else { return nil }
                guard obj.bool("visible") != false else { return nil }
                return Field(
                    key: key,
                    valueFrom: obj.string("valueFrom") ?? key,
                    label: obj.string("label") ?? Self.humanize(key),
                    format: obj.string("format"),
                    checkbox: obj.bool("checkbox") ?? false,
                    image: obj.object("image")
                )
            }
            if !fields.isEmpty { return fields }
        }
        return schema.map { Field(key: $0.name, valueFrom: $0.name, label: Self.humanize($0.name), format: nil, checkbox: false, image: nil) }
    }

    static func humanize(_ key: String) -> String {
        key.replacingOccurrences(of: "_", with: " ").capitalized
    }

    // MARK: - Body

    var body: some View {
        content
            .onAppear { runtime.ensureLoaded(querySlug) }
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
            if result.rows.isEmpty {
                Text("No records")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(12)
            } else if isDropdown {
                // selectAllByDefault applies in dropdown mode too — the web
                // seeds before its display-mode branch.
                dropdownControl(rows: result.rows, schema: result.schema)
                    .onAppear { seedSelectAllIfNeeded(rows: result.rows) }
            } else {
                cardColumn(rows: result.rows, schema: result.schema)
                    .onAppear { seedSelectAllIfNeeded(rows: result.rows) }
            }
        }
    }

    // MARK: - Cards mode (mobile: one phone-width column)

    private func cardColumn(rows: [[String: CmsJSON]], schema: [CmsQueryResultColumn]) -> some View {
        let fields = resolvedFields(schema: schema)
        return LazyVStack(spacing: gap) {
            if selectionMode == "multi" {
                selectAllHeader(rows: rows)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                card(row: row, fields: fields)
            }
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity) // centre the column in wider hosts
    }

    /// Multi-select header: selected count + Select all / Clear — parity with
    /// the web dropdown's select-all toggle, surfaced on the card list too.
    private func selectAllHeader(rows: [[String: CmsJSON]]) -> some View {
        let selectedCount = (runtime.selections[querySlug] ?? []).count
        let allSelected = selectedCount >= rows.count && !rows.isEmpty
        return HStack {
            Text("\(selectedCount) selected")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Button(allSelected ? "Clear" : "Select all") {
                runtime.setSelectedRows(querySlug, rows: allSelected ? [] : rows)
            }
            .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 4)
    }

    private func card(row: [String: CmsJSON], fields: [Field]) -> some View {
        let selected = isSelected(row)
        return VStack(alignment: .leading, spacing: 0) {
            if showImageInCard, isBannerImage, let url = imageURL(row) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.secondary.opacity(0.1)
                    }
                }
                .frame(height: imageHeight)
                .frame(maxWidth: .infinity)
                .clipped()
            }
            VStack(alignment: .leading, spacing: 10) {
                cardHeader(row: row)
                fieldFlow(row: row, fields: fields)
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .strokeBorder(
                    selected ? Color.accentColor : cardBorderColor,
                    lineWidth: selected ? 2 : cardBorderWidth
                )
        )
        .shadow(color: cardShadow.color, radius: cardShadow.radius, y: cardShadow.y)
        .contentShape(Rectangle())
        .onTapGesture {
            guard selectionMode != "none", clickSelects else { return }
            toggle(row)
        }
        .cmsInspectorID("Cms.recordCards.card")
    }

    @ViewBuilder
    private func cardHeader(row: [String: CmsJSON]) -> some View {
        let title = cardTitle(row: row)
        if title != nil || (showImageInCard && !isBannerImage && imageURL(row) != nil) || checkboxVisible {
            HStack(alignment: .center, spacing: 10) {
                if showImageInCard, !isBannerImage, let url = imageURL(row) {
                    AsyncImage(url: url) { phase in
                        if case .success(let image) = phase {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Color.secondary.opacity(0.15)
                        }
                    }
                    .frame(width: 44, height: 44)
                    .clipShape(Circle())
                }
                if let title {
                    Text(title)
                        .font(.headline)
                        .foregroundColor(titleColor)
                }
                Spacer(minLength: 0)
                if checkboxVisible {
                    let selected = isSelected(row)
                    Button { toggle(row) } label: {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundColor(selected ? .accentColor : .secondary.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var checkboxVisible: Bool {
        selectionMode != "none" && (showCheckbox || selectionMode == "multi")
    }

    /// `title` is a TextElement `{ text, typography }` with per-card @column tokens.
    private func cardTitle(row: [String: CmsJSON]) -> String? {
        guard let obj = block.props.object("title"),
              let text = obj.string("text"), !text.isEmpty else { return nil }
        let resolved = runtime.resolveTemplate(text, rowContext: row)
        return resolved.isEmpty ? nil : resolved
    }

    private var titleColor: Color {
        runtime.color(block.props.object("title")?.object("typography")?.string("color")) ?? .primary
    }

    /// Mobile card body: fields stacked in flow, label above value.
    private func fieldFlow(row: [String: CmsJSON], fields: [Field]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(fields, id: \.key) { field in
                if field.valueFrom != imageColumn {
                    VStack(alignment: .leading, spacing: 2) {
                        // An image field's label often blank (rota-edit uses
                        // " ") — skip it when empty so the card isn't padded.
                        if !(field.image != nil && field.label.trimmingCharacters(in: .whitespaces).isEmpty) {
                            Text(field.label)
                                .font(.caption)
                                .foregroundColor(labelColor)
                        }
                        fieldValue(row: row, field: field)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func fieldValue(row: [String: CmsJSON], field: Field) -> some View {
        let raw = row[field.valueFrom]
        if field.image != nil {
            imageFieldCard(row: row, field: field)
        } else if field.checkbox {
            let truthy = raw?.boolValue ?? (raw?.displayString == "1" || raw?.displayString.lowercased() == "true")
            Image(systemName: truthy ? "checkmark.square.fill" : "square")
                .foregroundColor(truthy ? .accentColor : .secondary)
        } else {
            let text = raw.map { value -> String in
                let s = value.displayString
                if let format = field.format, !format.isEmpty {
                    return CmsFormatValue.apply(s, pattern: format)
                }
                return s
            } ?? ""
            Text(text.isEmpty ? "—" : text)
                .font(.subheadline)
                .foregroundColor(valueColor)
        }
    }

    /// Card-style image field — the web's `imageStyle="card"`: full-width
    /// (120pt), `fit` cover/contain, `shape` square/rounded/circle, dashed
    /// placeholder when the row has no URL.
    @ViewBuilder
    private func imageFieldCard(row: [String: CmsJSON], field: Field) -> some View {
        let cfg = field.image ?? [:]
        let fit = cfg.string("fit") ?? "cover"
        let shape = cfg.string("shape") ?? "rounded"
        let urlString = (row[field.valueFrom]?.stringValue ?? "").trimmingCharacters(in: .whitespaces)
        if shape == "circle" {
            imageFieldContent(urlString: urlString, fit: fit)
                .frame(width: 120, height: 120)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(runtime.theme.divider))
        } else {
            imageFieldContent(urlString: urlString, fit: fit)
                .frame(maxWidth: .infinity)
                .frame(height: 120)
                .clipShape(RoundedRectangle(cornerRadius: shape == "square" ? 0 : 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: shape == "square" ? 0 : 8, style: .continuous)
                        .strokeBorder(urlString.isEmpty ? runtime.theme.divider : Color.clear)
                )
        }
    }

    @ViewBuilder
    private func imageFieldContent(urlString: String, fit: String) -> some View {
        if let url = URL(string: urlString), !urlString.isEmpty {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    if fit == "contain" { image.resizable().scaledToFit() }
                    else { image.resizable().scaledToFill() }
                } else {
                    Color.secondary.opacity(0.08)
                }
            }
        } else {
            ZStack {
                Color.secondary.opacity(0.06)
                Image(systemName: "photo")
                    .font(.system(size: 18))
                    .foregroundColor(.secondary.opacity(0.5))
            }
        }
    }

    private var labelColor: Color {
        runtime.color(block.props.object("labelTypography")?.string("color")) ?? .secondary
    }

    private var valueColor: Color {
        runtime.color(block.props.object("valueTypography")?.string("color")) ?? .primary
    }

    /// Card surface: outlined/elevated fill with the portal PAPER colour
    /// (the web's `Paper` `background.paper`) so cards read as cards; `flat`
    /// is transparent (web: `bgcolor: transparent`); an authored
    /// `cardFrame.background` (token-aware) overrides.
    @ViewBuilder
    private var cardBackground: some View {
        if let frameBg = runtime.color(block.props.object("cardFrame")?.string("background")) {
            frameBg
        } else if cardVariant == "flat" {
            Color.clear
        } else {
            runtime.theme.paper
        }
    }

    // MARK: - Authored card frame (cardFrame: radius / border / shadow)

    private var cardFrame: [String: CmsJSON]? { block.props.object("cardFrame") }

    private var cardCornerRadius: CGFloat {
        CmsCss.points(cardFrame?.string("borderRadius")) ?? 14
    }

    /// Authored border wins; else the variant default (outlined = hairline).
    private var cardBorderColor: Color {
        if let frame = cardFrame, CmsCss.points(frame.string("borderWidth")) ?? 0 > 0 {
            return runtime.color(frame.string("borderColor")) ?? runtime.theme.divider
        }
        return cardVariant == "outlined" ? Color.secondary.opacity(0.25) : Color.clear
    }
    private var cardBorderWidth: CGFloat {
        CmsCss.points(cardFrame?.string("borderWidth")) ?? (cardVariant == "outlined" ? 1 : 0)
    }

    /// Shadow token → approximate SwiftUI shadow (light-mode box-shadow of
    /// shadowTokens.ts; radius ≈ blur/2). Falls back to the `elevated`
    /// variant's own shadow.
    private var cardShadow: (color: Color, radius: CGFloat, y: CGFloat) {
        switch cardFrame?.string("shadow") {
        case "shadow.halo": return (.black.opacity(0.10), 9, 2)
        case "shadow.soft": return (.black.opacity(0.10), 4, 2)
        case "shadow.medium": return (.black.opacity(0.14), 9, 6)
        case "shadow.strong": return (.black.opacity(0.20), 16, 12)
        default:
            return cardVariant == "elevated" ? (.black.opacity(0.12), 6, 2) : (.clear, 0, 0)
        }
    }

    private func imageURL(_ row: [String: CmsJSON]) -> URL? {
        guard !imageColumn.isEmpty, let src = row[imageColumn]?.stringValue, !src.isEmpty else { return nil }
        return URL(string: src)
    }

    // MARK: - Dropdown mode (mobile: full-screen list sheet)

    private func dropdownControl(rows: [[String: CmsJSON]], schema: [CmsQueryResultColumn]) -> some View {
        let selected = runtime.selections[querySlug] ?? []
        let label = block.props.string("dropdownLabel") ?? ""
        return VStack(alignment: .leading, spacing: 4) {
            if !label.isEmpty {
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Button {
                showPickerSheet = true
            } label: {
                HStack {
                    collapsedSummaryView(selected: selected, schema: schema)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.3))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .sheet(isPresented: $showPickerSheet) {
            pickerSheet(rows: rows, schema: schema)
        }
    }

    /// Resting (collapsed) selection summary — the web's `dropdownDisplay`
    /// vocabulary: `count` = "N records selected"; `avatars` = overlapping
    /// 28pt thumbnails (image column, initial fallback, "+N" surplus — the
    /// AvatarGroup reading) + count caption; `chips` (default) = label
    /// chips with a "+N" overflow. `card` degrades to chips in this compact
    /// one-row control.
    @ViewBuilder
    private func collapsedSummaryView(selected: [[String: CmsJSON]], schema: [CmsQueryResultColumn]) -> some View {
        if selected.isEmpty {
            Text("Select…")
                .font(.subheadline)
                .foregroundColor(.secondary)
        } else {
            switch block.props.string("dropdownDisplay") ?? "chips" {
            case "count":
                Text("\(selected.count) record\(selected.count == 1 ? "" : "s") selected")
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .lineLimit(1)
            case "avatars":
                avatarSummary(selected: selected, schema: schema)
            default:
                chipSummary(selected: selected, schema: schema)
            }
        }
    }

    private func avatarSummary(selected: [[String: CmsJSON]], schema: [CmsQueryResultColumn]) -> some View {
        // MUI AvatarGroup(max: 6): all six fit, above that five + "+N".
        let shown = selected.count > 6 ? 5 : selected.count
        return HStack(spacing: 8) {
            HStack(spacing: -8) {
                ForEach(0..<shown, id: \.self) { index in
                    avatarCircle(row: selected[index],
                                 label: recordLabel(selected[index], schema: schema))
                }
                if selected.count > shown {
                    Text("+\(selected.count - shown)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.primary)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.secondary.opacity(0.2)))
                        .overlay(Circle().strokeBorder(runtime.theme.paper, lineWidth: 1.5))
                }
            }
            Text("\(selected.count) selected")
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }

    private func avatarCircle(row: [String: CmsJSON], label: String) -> some View {
        ZStack {
            Circle().fill(Color.secondary.opacity(0.25))
            if let url = imageURL(row) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        avatarInitial(label)
                    }
                }
            } else {
                avatarInitial(label)
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(Circle())
        // The AvatarGroup ring that separates overlapping thumbnails.
        .overlay(Circle().strokeBorder(runtime.theme.paper, lineWidth: 1.5))
    }

    private func avatarInitial(_ label: String) -> some View {
        Text(String(label.prefix(1)).uppercased())
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.primary)
    }

    private func chipSummary(selected: [[String: CmsJSON]], schema: [CmsQueryResultColumn]) -> some View {
        let labels = selected.map { recordLabel($0, schema: schema) }.filter { !$0.isEmpty }
        let shown = Array(labels.prefix(3))
        return HStack(spacing: 6) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, label in
                Text(label)
                    .font(.caption)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
            }
            if labels.count > shown.count {
                Text("+\(labels.count - shown.count)")
                    .font(.caption.weight(.medium))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func recordLabel(_ row: [String: CmsJSON], schema: [CmsQueryResultColumn]) -> String {
        let labelColumn = block.props.string("labelColumn") ?? ""
        if !labelColumn.isEmpty, let v = row[labelColumn], v != .null {
            return v.displayString
        }
        if let first = schema.first(where: { $0.name != imageColumn })?.name, let v = row[first] {
            return v.displayString
        }
        return ""
    }

    private func pickerSheet(rows: [[String: CmsJSON]], schema: [CmsQueryResultColumn]) -> some View {
        NavigationView {
            List {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    let selected = isSelected(row)
                    Button {
                        toggle(row)
                        if selectionMode != "multi" { showPickerSheet = false }
                    } label: {
                        HStack(spacing: 12) {
                            if let url = imageURL(row) {
                                AsyncImage(url: url) { phase in
                                    if case .success(let image) = phase {
                                        image.resizable().aspectRatio(contentMode: .fill)
                                    } else {
                                        Color.secondary.opacity(0.15)
                                    }
                                }
                                .frame(width: 36, height: 36)
                                .clipShape(Circle())
                            }
                            Text(recordLabel(row, schema: schema))
                                .foregroundColor(.primary)
                            Spacer()
                            if selected {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                }
            }
            .navigationTitle(block.props.string("dropdownLabel") ?? "Select")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                // Conditional TOOLBAR ITEMS need iOS 16 (ToolbarContentBuilder
                // buildIf); the package floor is iOS 15, so the condition
                // lives inside the item's ViewBuilder instead.
                ToolbarItem(placement: .cancellationAction) {
                    if selectionMode == "multi" {
                        let selected = (runtime.selections[querySlug] ?? []).count
                        let all = selected >= rows.count && !rows.isEmpty
                        Button(all ? "Clear" : "Select all") {
                            runtime.setSelectedRows(querySlug, rows: all ? [] : rows)
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showPickerSheet = false }
                }
            }
        }
    }

    // MARK: - Selection (publishes to the shared querySlug selection)

    private func isSelected(_ row: [String: CmsJSON]) -> Bool {
        (runtime.selections[querySlug] ?? []).contains(row)
    }

    private func toggle(_ row: [String: CmsJSON]) {
        let current = runtime.selections[querySlug] ?? []
        let already = current.contains(row)
        switch selectionMode {
        case "single":
            runtime.setSelectedRows(querySlug, rows: already ? [] : [row])
        case "multi":
            runtime.setSelectedRows(querySlug, rows: already ? current.filter { $0 != row } : current + [row])
        default:
            break
        }
    }

    /// Multi-select only: seed the shared selection with every row ONCE on
    /// first load; never stomp an existing (restored/parent) selection.
    private func seedSelectAllIfNeeded(rows: [[String: CmsJSON]]) {
        guard !seededSelectAll,
              selectionMode == "multi",
              block.props.bool("selectAllByDefault") == true,
              (runtime.selections[querySlug] ?? []).isEmpty else { return }
        seededSelectAll = true
        runtime.setSelectedRows(querySlug, rows: rows)
    }
}
