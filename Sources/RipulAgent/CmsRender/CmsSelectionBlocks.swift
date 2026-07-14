import SwiftUI

/// Native twin of the web `selectionMenu` block (SelectionMenuBlock.tsx).
/// A query's rows become selectable options; toggling writes the SAME
/// selection key the query exposes (the source querySlug), so downstream
/// queries bound to that selection re-run via the runtime's reactive refetch.
///
/// Presentation is a native checklist (rows with trailing checkmarks), not a
/// web checkbox mimic. `menuSlot` projection has no native Top Nav to land in
/// yet, so options render inline either way — the selection semantics are
/// identical; only the placement differs.
struct CmsSelectionMenuBlockView: View {
    let block: CmsBlock
    @EnvironmentObject var runtime: CmsRuntime

    private var querySlug: String { block.props.string("querySlug") ?? "" }
    private var labelColumn: String { block.props.string("labelColumn") ?? "" }
    private var isSingle: Bool { block.props.string("selectionMode") == "single" }
    private var emptyLabel: String { block.props.string("emptyLabel") ?? "No options." }

    var body: some View {
        content
            .onAppear { runtime.ensureLoaded(querySlug) }
    }

    @ViewBuilder
    private var content: some View {
        switch runtime.state(for: querySlug) {
        case .idle, .loading:
            Text("Loading…")
                .font(.caption)
                .foregroundColor(.secondary)
        case .waiting(let reason):
            Text(reason)
                .font(.caption)
                .foregroundColor(.secondary)
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundColor(.orange)
        case .ok(let result):
            if result.rows.isEmpty {
                Text(emptyLabel)
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                options(rows: result.rows)
            }
        }
    }

    private func options(rows: [[String: CmsJSON]]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                optionRow(row, label: label(for: row))
                if index < rows.count - 1 {
                    Divider().padding(.leading, 12)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    private func optionRow(_ row: [String: CmsJSON], label: String) -> some View {
        let selected = isSelected(row)
        return Button {
            toggle(row)
        } label: {
            HStack {
                Text(label)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.subheadline)
                    .foregroundColor(selected ? .accentColor : .secondary.opacity(0.5))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Label column value, falling back to the row's first value — twin of
    /// the web's `row[labelCol] ?? Object.values(row)[0]`.
    private func label(for row: [String: CmsJSON]) -> String {
        if !labelColumn.isEmpty, let v = row[labelColumn], v != .null {
            return v.displayString
        }
        // Schema order isn't preserved in a Swift dictionary; use the result
        // schema's first column for a stable fallback.
        if case .ok(let result) = runtime.state(for: querySlug),
           let first = result.schema.first?.name, let v = row[first] {
            return v.displayString
        }
        return row.values.first?.displayString ?? ""
    }

    private func isSelected(_ row: [String: CmsJSON]) -> Bool {
        (runtime.selections[querySlug] ?? []).contains(row)
    }

    /// Single: toggle → [row] or []. Multi: add/remove from the current set.
    /// Writes drive the shared selection, so bound queries re-run.
    private func toggle(_ row: [String: CmsJSON]) {
        let current = runtime.selections[querySlug] ?? []
        let already = current.contains(row)
        if isSingle {
            runtime.setSelectedRows(querySlug, rows: already ? [] : [row])
        } else {
            runtime.setSelectedRows(
                querySlug,
                rows: already ? current.filter { $0 != row } : current + [row]
            )
        }
    }
}
