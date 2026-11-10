import SwiftUI

/// The `textEntry` block's rules: the web's TextEntryBlock.tsx. Its value is a
/// block output (`value`) that queries read as a source, by the block's slug
/// (`paramSources: { q: { sourceQuerySlug: "<slug>", column: "value" } }`), as
/// they read a selected row. The query's own `debounceMs` paces the refetch.
enum CmsTextEntry {
    struct Props: Equatable {
        var label: String
        var placeholder: String
        /// Bound: the field edits this query's selected row's column.
        var bindQuerySlug: String?
        var bindColumn: String?

        var isBound: Bool { bindQuerySlug != nil && bindColumn != nil }

        init(_ props: [String: CmsJSON]) {
            label = props.string("label") ?? ""
            placeholder = props.string("placeholder") ?? "Type to filter…"
            bindQuerySlug = props.string("bindQuerySlug").flatMap { $0.isEmpty ? nil : $0 }
            bindColumn = props.string("bindColumn").flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    /// What the block publishes: a bound field its value as typed, even empty,
    /// so Save can write a cleared field; a filter its value trimmed, or no row
    /// at all when blank (no filter).
    static func output(_ value: String, bound: Bool) -> [[String: CmsJSON]] {
        if bound { return [["value": .string(value)]] }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? [] : [["value": .string(trimmed)]]
    }

    /// A bound field's value from the selected row: the column as text, else empty.
    static func prefill(_ row: [String: CmsJSON]?, column: String) -> String {
        guard let value = row?[column], value != .null else { return "" }
        return value.displayString
    }
}

/// The `textEntry` block natively: the system's text field, its value published
/// as the block's output for the queries that read it. Unbound it is a filter
/// (a search key on the keyboard); bound, it prefills from the selected row's
/// column and follows a newly selected row, keeping edits to the same row.
struct CmsTextEntryBlockView: View {
    let block: CmsBlock
    @EnvironmentObject private var runtime: CmsRuntime
    @State private var value = ""
    @FocusState private var focused: Bool

    private var props: CmsTextEntry.Props { CmsTextEntry.Props(runtime.resolvedProps(for: block)) }
    private var outputSlug: String { block.slug.flatMap { $0.isEmpty ? nil : $0 } ?? block.id }
    private var boundRow: [String: CmsJSON]? { props.bindQuerySlug.flatMap { runtime.selectedRow($0) } }

    var body: some View {
        let props = self.props
        VStack(alignment: .leading, spacing: 6) {
            if !props.label.isEmpty {
                Text(props.label)
                    .font(.ripul(.footnote))
                    .foregroundStyle(.ripul(.textSecondary))
                    .accessibilityHidden(true)
            }
            HStack(spacing: 8) {
                if !props.isBound {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.ripul(.textSecondary))
                        .accessibilityHidden(true)
                }
                TextField(props.placeholder, text: $value)
                    .font(.ripul(.body))
                    .foregroundStyle(runtime.theme.textPrimary)
                    .focused($focused)
                    .submitLabel(props.isBound ? .done : .search)
                    .autocorrectionDisabled(!props.isBound)
                    .onSubmit { focused = false }
                    .accessibilityLabel(props.label.isEmpty ? props.placeholder : props.label)
                if !value.isEmpty && focused {
                    Button { value = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.ripul(.textTertiary))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.ripul(system: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: runtime.theme.inputRadius, style: .continuous))
            #if os(iOS)
            .keyboardDoneButton(when: focused) { focused = false }
            #endif
        }
        .onChange(of: value) { _, now in publish(now) }
        .onAppear {
            if let column = props.bindColumn, props.isBound { value = CmsTextEntry.prefill(boundRow, column: column) }
            publish(value)
        }
        // Bound: a newly selected row (or its refetch) reloads the field.
        .onChange(of: boundRow) { _, row in
            guard let column = props.bindColumn, props.isBound else { return }
            value = CmsTextEntry.prefill(row, column: column)
        }
        .cmsInspectorID("Cms.textEntry")
    }

    private func publish(_ value: String) {
        let rows = CmsTextEntry.output(value, bound: props.isBound)
        guard (runtime.selections[outputSlug] ?? []) != rows else { return }
        runtime.setSelectedRows(outputSlug, rows: rows)
    }
}
