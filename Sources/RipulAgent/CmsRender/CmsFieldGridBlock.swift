import SwiftUI

/// Native twin of `fieldGrid` (FieldGridBlock.tsx) — a record FORM bound to
/// a query's shared selection cursor: fields read the SELECTED row only
/// (the web's `useSelectedRow` — no local fallback). In recordPicker title
/// mode the cursor auto-selects the first row INTO the shared selection
/// (the web's `autoSelectFirst`), so the first record propagates to every
/// block bound to the query (detail headers, sibling forms) — a local
/// display fallback would show a record no one else can see. Plain-title
/// forms keep the web's "follow whoever selected" behaviour.
///
/// READ-ONLY v1: value editing, Edit/Save/Delete and the mutation wiring
/// wait for the mutations client — the form renders every field as styled
/// static text (the web's `readOnly` presentation). Mirrored semantics:
/// title / recordPicker title mode (native Menu driving the shared
/// selection, `hidePickerWhenSingle`), collapsible header, title divider,
/// flow layout (auto/fixed columns, min width, gap/padding in theme units),
/// value styles outlined/plain/underline, label placements, formats.
/// Degradations: `layoutMode: grid` renders as flow; `fieldGroups`,
/// `columnDefsRef`/`columnViewRef` indirection deferred (inline fields or
/// every column).
struct CmsFieldGridBlockView: View {
    let block: CmsBlock
    @EnvironmentObject var runtime: CmsRuntime
    @State private var expanded = true
    @State private var configured = false

    private var querySlug: String { block.props.string("bindQuerySlug") ?? "" }

    private struct Field {
        var key: String
        var valueFrom: String
        var label: String
        var format: String?
        /// ImageCellConfig — PRESENCE is the render-as-image switch (the
        /// value is a URL shown as a card); `fit`/`shape` configure it.
        var image: [String: CmsJSON]?
    }

    var body: some View {
        content
            .onAppear {
                runtime.ensureLoaded(querySlug)
                if !configured {
                    configured = true
                    if block.props.bool("collapsible") ?? false,
                       block.props.bool("startCollapsed") ?? false {
                        expanded = false
                    }
                }
                seedSelectionIfNeeded()
            }
            .onChange(of: resultFingerprint) { _ in
                seedSelectionIfNeeded()
            }
    }

    private var resultFingerprint: String {
        guard case .ok(let result) = runtime.state(for: querySlug) else { return "-" }
        return "\(result.rows.count)|\((runtime.selections[querySlug] ?? []).count)"
    }

    /// recordPicker mode's autoSelectFirst: when nothing is selected, select
    /// the first row into the SHARED store so it propagates page-wide.
    private func seedSelectionIfNeeded() {
        guard (block.props.string("titleMode") ?? "text") == "recordPicker" else { return }
        guard (runtime.selections[querySlug] ?? []).isEmpty,
              case .ok(let result) = runtime.state(for: querySlug),
              let first = result.rows.first else { return }
        runtime.setSelectedRows(querySlug, rows: [first])
    }

    @ViewBuilder
    private var content: some View {
        switch runtime.state(for: querySlug) {
        case .idle, .loading:
            HStack { Spacer(); ProgressView(); Spacer() }
                .padding(.vertical, 20)
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
            // The form's cursor: the SHARED selection only (web parity —
            // picker mode seeds it; plain mode follows whoever selected).
            let row = (runtime.selections[querySlug] ?? []).first
            let fields = fields(schema: result.schema)
            VStack(alignment: .leading, spacing: 10) {
                header(rows: result.rows, row: row)
                if block.props.bool("titleDivider") ?? false {
                    Divider()
                }
                if expanded {
                    fieldFlow(row: row, fields: fields)
                        .padding(CGFloat(block.props.double("padding") ?? 0) * 8)
                }
            }
        }
    }

    // MARK: - Header (title / record picker / collapse chevron)

    @ViewBuilder
    private func header(rows: [[String: CmsJSON]], row: [String: CmsJSON]?) -> some View {
        let title = block.props.string("title") ?? ""
        let collapsible = block.props.bool("collapsible") ?? false
        let pickerMode = (block.props.string("titleMode") ?? "text") == "recordPicker"
        let hideSingle = (block.props.bool("hidePickerWhenSingle") ?? false) && rows.count <= 1
        if !title.isEmpty || collapsible || (pickerMode && !hideSingle) {
            HStack(spacing: 8) {
                if !title.isEmpty {
                    let typo = block.props.object("titleTypography")
                    Text(runtime.resolveTemplate(title))
                        .font(.system(size: CmsTypography.size(typo) ?? 15,
                                      weight: CmsTypography.weight(typo) ?? .semibold))
                        .foregroundColor(runtime.color(typo?.string("color")) ?? .primary)
                }
                if pickerMode && !hideSingle {
                    recordPicker(rows: rows, current: row)
                }
                Spacer(minLength: 0)
                if collapsible {
                    Button {
                        withAnimation(.snappy) { expanded.toggle() }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(expanded ? 0 : -90))
                            .foregroundColor(.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Record picker title mode — a native Menu whose pick drives the
    /// query's SHARED selection (the Record Navigator cursor model).
    private func recordPicker(rows: [[String: CmsJSON]], current: [String: CmsJSON]?) -> some View {
        Menu {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                Button {
                    runtime.setSelectedRows(querySlug, rows: [row])
                } label: {
                    if let current, current == row {
                        Label(recordLabel(row), systemImage: "checkmark")
                    } else {
                        Text(recordLabel(row))
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(current.map(recordLabel) ?? "Pick a record")
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10))
            }
            .foregroundColor(.primary)
        }
    }

    private func recordLabel(_ row: [String: CmsJSON]) -> String {
        let column = block.props.string("titleLabelColumn") ?? ""
        if !column.isEmpty, let v = row[column], v != .null { return v.displayString }
        if case .ok(let result) = runtime.state(for: querySlug),
           let first = result.schema.first?.name, let v = row[first] {
            return v.displayString
        }
        return "Record"
    }

    // MARK: - Field flow

    private func fields(schema: [CmsQueryResultColumn]) -> [Field] {
        // Shared column view (columnViewRef) wins over inline fields — the
        // web's `columnViewColumns ?? sharedColumns ?? props.fields`
        // (columnDefsRef deferred). Carries labels/order/format/image config.
        var source: [CmsJSON]?
        if let ref = block.props.string("columnViewRef"), !ref.isEmpty,
           let cols = runtime.columnViews[ref]?.columns, !cols.isEmpty {
            source = cols
        } else if case .array(let raw) = block.props["fields"] ?? .null, !raw.isEmpty {
            source = raw
        }
        if let source {
            return source.compactMap { entry in
                guard let obj = entry.objectValue, let key = obj.string("key") else { return nil }
                guard obj.bool("visible") != false else { return nil }
                return Field(
                    key: key,
                    valueFrom: obj.string("valueFrom") ?? key,
                    label: obj.string("label") ?? CmsRecordCardsBlockView.humanize(key),
                    format: obj.string("format"),
                    image: obj.object("image")
                )
            }
        }
        return schema.map {
            Field(key: $0.name, valueFrom: $0.name,
                  label: CmsRecordCardsBlockView.humanize($0.name), format: nil, image: nil)
        }
    }

    private func fieldFlow(row: [String: CmsJSON]?, fields: [Field]) -> some View {
        let gap = CGFloat(block.props.double("gap") ?? 2) * 8
        let columns: [GridItem]
        if (block.props.string("columnMode") ?? "auto") == "fixed" {
            let count = max(1, Int(block.props.double("fixedCols") ?? 2))
            columns = Array(repeating: GridItem(.flexible(), spacing: gap, alignment: .topLeading), count: count)
        } else {
            // Auto: fit by min field width (maxCols degrades away — adaptive
            // grids have no column cap; phone widths rarely exceed it).
            let minWidth = CGFloat(block.props.double("minColWidth") ?? 200)
            columns = [GridItem(.adaptive(minimum: minWidth), spacing: gap, alignment: .topLeading)]
        }
        return LazyVGrid(columns: columns, alignment: .leading, spacing: gap) {
            ForEach(fields, id: \.key) { field in
                fieldCell(field, row: row)
            }
        }
    }

    private func value(_ field: Field, row: [String: CmsJSON]?) -> String {
        guard let row, let v = row[field.valueFrom], v != .null else { return "" }
        let s = v.displayString
        if let format = field.format, !format.isEmpty {
            return CmsFormatValue.apply(s, pattern: format)
        }
        return s
    }

    @ViewBuilder
    private func fieldCell(_ field: Field, row: [String: CmsJSON]?) -> some View {
        let placement = block.props.string("labelPlacement") ?? "inset"
        if field.image != nil {
            // Image fields always show their label (even in inset mode) —
            // the card has no outline to float it in. Web rule.
            VStack(alignment: .leading, spacing: 3) {
                labelText(field)
                imageCard(field, row: row)
            }
        } else {
            textFieldCell(field, row: row, placement: placement)
        }
    }

    @ViewBuilder
    private func textFieldCell(_ field: Field, row: [String: CmsJSON]?, placement: String) -> some View {
        switch placement {
        case "left":
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                labelText(field)
                    .frame(minWidth: 80, alignment: .leading)
                valueView(field, row: row)
            }
        case "above":
            VStack(alignment: labelAlignment, spacing: 3) {
                labelText(field)
                    .frame(maxWidth: .infinity, alignment: labelFrameAlignment)
                valueView(field, row: row)
            }
        default: // inset — the floating outline label, drawn inside the box.
            valueView(field, row: row, insetLabel: field.label)
        }
    }

    /// The web's card-style image field: full-width card (min-height 80 —
    /// 120pt here for a phone-sized read), `fit` cover/contain, `shape`
    /// square/rounded/circle (circle = avatar), dashed placeholder when the
    /// row has no URL.
    @ViewBuilder
    private func imageCard(_ field: Field, row: [String: CmsJSON]?) -> some View {
        let cfg = field.image ?? [:]
        let fit = cfg.string("fit") ?? "cover"
        let shape = cfg.string("shape") ?? "rounded"
        let urlString = (row?[field.valueFrom]?.stringValue ?? "").trimmingCharacters(in: .whitespaces)
        if shape == "circle" {
            imageContent(urlString: urlString, fit: fit)
                .frame(width: 120, height: 120)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(runtime.theme.divider))
        } else {
            imageContent(urlString: urlString, fit: fit)
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
    private func imageContent(urlString: String, fit: String) -> some View {
        if let url = URL(string: urlString), !urlString.isEmpty {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    if fit == "contain" {
                        image.resizable().scaledToFit()
                    } else {
                        image.resizable().scaledToFill()
                    }
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

    private func labelText(_ field: Field) -> some View {
        let typo = block.props.object("labelTypography")
        return Text(field.label)
            .font(.system(size: CmsTypography.size(typo) ?? 12,
                          weight: CmsTypography.weight(typo) ?? .regular))
            .foregroundColor(runtime.color(typo?.string("color")) ?? .secondary)
    }

    private var labelAlignment: HorizontalAlignment {
        switch block.props.string("labelAlign") ?? "left" {
        case "center": return .center
        case "right": return .trailing
        default: return .leading
        }
    }
    private var labelFrameAlignment: Alignment {
        switch block.props.string("labelAlign") ?? "left" {
        case "center": return .center
        case "right": return .trailing
        default: return .leading
        }
    }
    private var valueFrameAlignment: Alignment {
        switch block.props.string("valueAlign") ?? "left" {
        case "center": return .center
        case "right": return .trailing
        default: return .leading
        }
    }

    @ViewBuilder
    private func valueView(_ field: Field, row: [String: CmsJSON]?, insetLabel: String? = nil) -> some View {
        let text = value(field, row: row)
        let style = block.props.string("valueStyle") ?? "outlined"
        let body = VStack(alignment: .leading, spacing: 2) {
            if let insetLabel {
                labelText(Field(key: field.key, valueFrom: field.valueFrom, label: insetLabel, format: nil, image: nil))
                    .font(.system(size: 11))
            }
            Text(text.isEmpty ? " " : text)
                .font(.system(size: 14))
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: valueFrameAlignment)
        }
        switch style {
        case "plain":
            body
        case "underline":
            body
                .padding(.bottom, 6)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(runtime.theme.divider).frame(height: 1)
                }
        default: // outlined
            body
                .padding(.horizontal, 10)
                .padding(.vertical, insetLabel != nil ? 7 : 10)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(runtime.theme.divider)
                )
        }
    }
}
