import SwiftUI

/// Native twin of `recordNavigator` (RecordNavigatorBlock.tsx).
///
/// Loads a multi-row query, auto-selects the first row when
/// `autoSelectFirst` is true (the default), and renders a stepper /
/// dropdown toolbar so the user can browse records. Every block on the
/// page that contains `@querySlug.column` tokens resolves them against
/// whichever row is currently selected — so WITHOUT this block, those
/// templates show as literal text.
///
/// Presentation mirrors the web:
///  - `stepper` — prev/next chevron buttons (+ first/last edges)
///  - `dropdown` — a native Menu picker
///  - `both` (default) — stepper controls flanking the picker
///
/// `dirtyGuard` is skipped (native forms are read-only for now).
struct CmsRecordNavigatorBlockView: View {
    let block: CmsBlock
    @EnvironmentObject var runtime: CmsRuntime

    // MARK: - Props

    private var querySlug: String { block.props.string("querySlug") ?? "" }
    private var labelProp: String { block.props.string("label") ?? "" }
    private var presentation: String { block.props.string("presentation") ?? "both" }
    private var keyColumn: String { block.props.string("keyColumn") ?? "" }
    private var labelColumn: String { block.props.string("labelColumn") ?? "" }
    private var autoSelectFirst: Bool { block.props.bool("autoSelectFirst") ?? true }
    private var wrap: Bool { block.props.bool("wrap") ?? false }
    private var showCount: Bool { block.props.bool("showCount") ?? true }
    private var showEdges: Bool { block.props.bool("showEdges") ?? true }
    private var emptyLabel: String { block.props.string("emptyLabel") ?? "No records." }
    private var hideWhenTrivial: Bool { block.props.bool("hideWhenTrivial") ?? false }

    // MARK: - Body

    var body: some View {
        content
            .onAppear { runtime.ensureLoaded(querySlug) }
            .onChange(of: resultFingerprint) { _ in seedSelectionIfNeeded() }
    }

    private var resultFingerprint: String {
        guard case .ok(let result) = runtime.state(for: querySlug) else { return "-" }
        return "\(result.rows.count)|\((runtime.selections[querySlug] ?? []).count)"
    }

    /// Seed the shared selection with the first row as soon as the query
    /// lands — mirrors the web's `autoSelectFirst: true` default. All
    /// `@querySlug.column` tokens on the page resolve immediately after.
    private func seedSelectionIfNeeded() {
        guard autoSelectFirst,
              (runtime.selections[querySlug] ?? []).isEmpty,
              case .ok(let result) = runtime.state(for: querySlug),
              let first = result.rows.first else { return }
        runtime.setSelectedRows(querySlug, rows: [first])
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch runtime.state(for: querySlug) {
        case .idle, .loading:
            if !hideWhenTrivial {
                Text("Loading…")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
        case .waiting:
            EmptyView()
        case .error:
            if !hideWhenTrivial {
                Label("Couldn't load records.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        case .ok(let result):
            let rows = result.rows
            if rows.isEmpty {
                if !hideWhenTrivial {
                    Text(emptyLabel)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                }
            } else if hideWhenTrivial && rows.count <= 1 {
                EmptyView()
            } else {
                toolbar(rows: rows)
            }
        }
    }

    // MARK: - Toolbar

    @ViewBuilder
    private func toolbar(rows: [[String: CmsJSON]]) -> some View {
        let total = rows.count
        let selection = runtime.selections[querySlug] ?? []
        let idx = currentIndex(rows: rows, selection: selection)
        let typo = block.props.object("typography")
        let navFont = Font.system(
            size: CmsTypography.size(typo) ?? 14,
            weight: CmsTypography.weight(typo) ?? .regular
        )
        let showStepper = presentation == "stepper" || presentation == "both"
        let showDropdown = presentation == "dropdown" || presentation == "both"
        let lc = effectiveLabelColumn(rows: rows)

        HStack(spacing: 4) {
            if !labelProp.isEmpty {
                Text(labelProp)
                    .font(navFont)
                    .foregroundColor(.secondary)
            }

            if showStepper {
                if showEdges {
                    Button { goTo(index: 0, rows: rows) } label: {
                        Image(systemName: "chevron.backward.to.line")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!wrap && idx == 0)
                }
                Button { goTo(index: idx - 1, rows: rows) } label: {
                    Image(systemName: "chevron.backward")
                }
                .buttonStyle(.borderless)
                .disabled(!wrap && idx == 0)
            }

            if showDropdown {
                Picker("", selection: Binding(
                    get: { idx >= 0 ? idx : 0 },
                    set: { goTo(index: $0, rows: rows) }
                )) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                        let v = lc.isEmpty ? "" : (row[lc]?.displayString ?? "")
                        Text(v.isEmpty ? "Record \(i + 1)" : v).tag(i)
                    }
                }
                .pickerStyle(.menu)
                .font(navFont)
            }

            if showCount {
                Text(idx >= 0 ? "\(idx + 1) / \(total)" : "— / \(total)")
                    .font(navFont)
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                    .fixedSize()
            }

            if showStepper {
                Button { goTo(index: idx + 1, rows: rows) } label: {
                    Image(systemName: "chevron.forward")
                }
                .buttonStyle(.borderless)
                .disabled(!wrap && idx == total - 1)

                if showEdges {
                    Button { goTo(index: total - 1, rows: rows) } label: {
                        Image(systemName: "chevron.forward.to.line")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!wrap && idx == total - 1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Navigation

    private func goTo(index: Int, rows: [[String: CmsJSON]]) {
        guard !rows.isEmpty else { return }
        let total = rows.count
        let i: Int
        if wrap {
            i = ((index % total) + total) % total
        } else {
            i = max(0, min(index, total - 1))
        }
        runtime.setSelectedRows(querySlug, rows: [rows[i]])
    }

    /// Match the current selection back to its row index using the key
    /// column for stable cross-refetch identity, falling back to equality.
    private func currentIndex(rows: [[String: CmsJSON]], selection: [[String: CmsJSON]]) -> Int {
        guard let selected = selection.first else { return -1 }
        let kc = effectiveKeyColumn(rows: rows)
        if !kc.isEmpty, let keyVal = selected[kc] {
            return rows.firstIndex { $0[kc] == keyVal } ?? -1
        }
        return rows.firstIndex { $0 == selected } ?? -1
    }

    /// Infer key column: authored `keyColumn` prop → column named "id" →
    /// first column whose name ends in "_id". Mirrors the web's primary-key
    /// inference via `inferTableForQuery`.
    private func effectiveKeyColumn(rows: [[String: CmsJSON]]) -> String {
        if !keyColumn.isEmpty { return keyColumn }
        guard let first = rows.first else { return "" }
        if first["id"] != nil { return "id" }
        return first.keys.sorted().first { $0.hasSuffix("_id") } ?? ""
    }

    /// Infer label column: authored `labelColumn` prop → first non-key
    /// string column — mirrors the web's `inferLabelColumn`.
    private func effectiveLabelColumn(rows: [[String: CmsJSON]]) -> String {
        if !labelColumn.isEmpty { return labelColumn }
        guard let first = rows.first else { return "" }
        let kc = effectiveKeyColumn(rows: rows)
        return first.keys.sorted().first { key in
            key != kc && (first[key]?.stringValue != nil)
        } ?? ""
    }
}
