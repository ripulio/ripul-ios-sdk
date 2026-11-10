import SwiftUI

/// Native twin of `dropdown` (DropdownBlock.tsx): a choice whose value is a
/// parameter source for other blocks, drawn as the system's menu picker. Its
/// options are a written list (one per line, or comma-separated) or a query's
/// rows (`valueColumn`, `labelColumn`). The output is the web's exactly:
/// `{ value }` once something is chosen, nothing before. Bound to a row
/// (`bindQuerySlug`, `bindColumn`), it starts from that row's value, follows
/// another row being selected, and always publishes its value, as the web's
/// bound dropdown does.
struct CmsDropdownBlockView: View {
    let block: CmsBlock
    @EnvironmentObject private var runtime: CmsRuntime
    /// The value chosen here, or nil to read the bound row's.
    @State private var chosen: String?

    private struct Option: Hashable { let value: String; let label: String }

    private var props: [String: CmsJSON] { runtime.resolvedProps(for: block) }
    private var slug: String { block.slug ?? block.id }
    private var label: String { props.string("label") ?? "" }
    private var placeholder: String {
        let text = props.string("placeholder") ?? ""
        return text.isEmpty ? "Select…" : text
    }
    private var fromQuery: Bool { props.string("optionsSource") == "query" }
    private var querySlug: String? { props.string("querySlug").flatMap { $0.isEmpty ? nil : $0 } }
    private var bindQuery: String? { props.string("bindQuerySlug").flatMap { $0.isEmpty ? nil : $0 } }
    private var bindColumn: String? { props.string("bindColumn").flatMap { $0.isEmpty ? nil : $0 } }
    private var isBound: Bool { bindQuery != nil && bindColumn != nil }

    /// The bound row's value, when bound and a row is selected.
    private var boundValue: String? {
        guard let bindQuery, let bindColumn,
              let value = runtime.selectedRow(bindQuery)?[bindColumn], value != .null else { return nil }
        return value.displayString
    }

    private var selected: String { chosen ?? boundValue ?? "" }

    private var options: [Option] {
        if fromQuery {
            guard let querySlug, let valueColumn = props.string("valueColumn"), !valueColumn.isEmpty,
                  case .ok(let result) = runtime.state(for: querySlug) else { return [] }
            let labelColumn = props.string("labelColumn").flatMap { $0.isEmpty ? nil : $0 }
            var seen = Set<String>()
            return result.rows.compactMap { row in
                let value = row[valueColumn]?.displayString ?? ""
                guard !value.isEmpty, seen.insert(value).inserted else { return nil }
                return Option(value: value, label: labelColumn.flatMap { row[$0]?.displayString } ?? value)
            }
        }
        return (props.string("manualOptions") ?? "")
            .split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { Option(value: $0, label: $0) }
    }

    private var loading: Bool {
        guard fromQuery, let querySlug else { return false }
        if case .loading = runtime.state(for: querySlug) { return true }
        return false
    }

    var body: some View {
        let options = options
        LabeledContent {
            Menu {
                Picker(label.isEmpty ? placeholder : label, selection: selection) {
                    ForEach(options, id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                if !selected.isEmpty {
                    Divider()
                    Button("Clear selection", role: .destructive) { choose("") }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(options.first { $0.value == selected }?.label ?? (selected.isEmpty ? placeholder : selected))
                        .foregroundStyle(selected.isEmpty ? runtime.theme.color(role: .mutedText) : runtime.theme.color(role: .primary))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(runtime.theme.color(role: .mutedText))
                }
            }
            .disabled(loading || runtime.isDesignMode)
        } label: {
            if !label.isEmpty {
                Text(label).foregroundStyle(runtime.theme.color(role: .text))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            if fromQuery, let querySlug { runtime.ensureLoaded(querySlug) }
            publish()
        }
        // A different row selected: the bound value is that row's again.
        .onChange(of: boundValue) { _, _ in
            guard isBound else { return }
            chosen = nil
            publish()
        }
        // Another source of options: an old choice would no longer be one of them.
        .onChange(of: querySlug) { _, _ in
            guard !isBound else { return }
            choose("")
        }
    }

    private var selection: Binding<String> {
        Binding(get: { selected }, set: { choose($0) })
    }

    private func choose(_ value: String) {
        chosen = value
        publish()
    }

    /// Bound (edit) dropdowns publish even an empty value so a save can clear
    /// the field; a filter publishes nothing until something is chosen.
    private func publish() {
        let value = selected
        if isBound || !value.isEmpty {
            runtime.setSelectedRows(slug, rows: [["value": .string(value)]])
        } else {
            runtime.setSelectedRows(slug, rows: [])
        }
    }
}
