import SwiftUI

// MARK: - listSelector, natively (docs/plans/cms-sidebar.md)
//
// A choice list: options written or from a query, pick one or several. Its
// choice is the block's output, the web's exactly (`value`, comma-joined for
// several; `count`), so the queries bound to it work alike. Drawn in the
// sidebar's idiom (clean rows, the chosen one on a glass lozenge, tick boxes
// tinted with each option's colour), the filter panel WAC's RecordMenu is.

/// One option of a choice list.
struct CmsChoiceOption: Equatable, Identifiable {
    var value: String?
    var label: String
    var symbol: String?
    var image: String?
    /// A palette role or a CSS colour: the tick box's tint.
    var color: String?
    /// A date-period option: writes a date predicate instead of a value.
    var predicate: String?
    var placeholder: Bool
    /// The row it came from (a query's), or `{ value, label }` for a written
    /// one: what `{column}` slots in a row action fill from.
    var row: [String: CmsJSON]

    /// A value option's value; a period option's `predicate:<operator>`.
    var id: String { value ?? "predicate:\(predicate ?? "")" }
}

/// The list's settings, decoded leniently.
struct CmsChoiceList: Equatable {
    var multi: Bool
    /// `highlight` (pick one on a lozenge), `check` (tick boxes), or nil.
    var look: String?
    var showCheckboxes: Bool
    var minSelected: Int
    /// `all`, `first`, or the values (or period operators) chosen at first.
    var defaultSelection: [String]?
    var defaultAll: Bool
    var defaultFirst: Bool

    init(_ props: [String: CmsJSON]) {
        multi = props.string("selectionMode") == "multi"
        let look = props.string("look")
        self.look = ["highlight", "check"].contains(look ?? "") ? look : nil
        showCheckboxes = props.bool("showCheckboxes") ?? true
        minSelected = max(0, Int(props.double("minSelected") ?? 0))
        switch props["defaultSelection"] {
        case .string(let s)?:
            defaultAll = s == "all"
            defaultFirst = s == "first"
            defaultSelection = (defaultAll || defaultFirst) ? nil : [s]
        case .array(let values)?:
            defaultAll = false
            defaultFirst = false
            defaultSelection = values.compactMap { $0.stringValue ?? ($0 == .null ? nil : $0.displayString) }
        default:
            defaultAll = false
            defaultFirst = false
            defaultSelection = nil
        }
    }

    /// Written options: `options` (with media, colours, periods), else the
    /// older `manualOptions` text (comma or line separated).
    static func writtenOptions(_ props: [String: CmsJSON]) -> [CmsChoiceOption] {
        if case .array(let raw)? = props["options"] {
            return raw.compactMap { entry in
                guard let o = entry.objectValue else { return nil }
                let predicate = o.object("predicate")?.string("operator")
                    .flatMap { CmsRangePredicateOperator(rawValue: $0) != nil ? $0 : nil }
                let value = predicate == nil ? (o.string("value") ?? o.string("label")) : nil
                guard let label = o.string("label") ?? value, !label.isEmpty else { return nil }
                let media = o.object("media")
                return CmsChoiceOption(value: value, label: label,
                                       symbol: media?.string("symbol"), image: media?.string("image"),
                                       color: o.string("color"), predicate: predicate,
                                       placeholder: o.bool("placeholder") ?? false,
                                       row: ["value": .string(value ?? ""), "label": .string(label)])
            }
        }
        let text = props.string("manualOptions") ?? ""
        return text.components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { CmsChoiceOption(value: $0, label: $0, placeholder: false, row: ["value": .string($0), "label": .string($0)]) }
    }

    /// A query's rows as options: `valueColumn`, `labelColumn`,
    /// `imageColumn`, `colorColumn`; a value seen before is left out.
    static func queryOptions(_ rows: [[String: CmsJSON]], props: [String: CmsJSON]) -> [CmsChoiceOption] {
        guard let valueColumn = props.string("valueColumn"), !valueColumn.isEmpty else { return [] }
        var seen = Set<String>()
        return rows.compactMap { row in
            let value = row[valueColumn].map { CmsCards.text($0) } ?? ""
            guard !value.isEmpty, seen.insert(value).inserted else { return nil }
            let label = props.string("labelColumn").flatMap { row[$0] }.map { CmsCards.text($0) } ?? value
            return CmsChoiceOption(value: value, label: label.isEmpty ? value : label,
                                   color: props.string("colorColumn").flatMap { row[$0] }.map { CmsCards.text($0) },
                                   placeholder: false, row: row)
        }
    }

    /// The choice the list starts with, once its options are known.
    func initialSelection(_ options: [CmsChoiceOption]) -> [String] {
        // Never a placeholder or a period (a period follows the date parameter).
        let live = options.filter { !$0.placeholder && $0.predicate == nil }
        if defaultAll { return multi ? live.map(\.id) : Array(live.prefix(1).map(\.id)) }
        if defaultFirst { return Array(live.prefix(1).map(\.id)) }
        if let wanted = defaultSelection {
            let picked = live.filter { wanted.contains($0.value ?? "") }.map(\.id)
            return multi ? picked : Array(picked.prefix(1))
        }
        return []
    }

    /// The choice after a tap on a value option: one list picks one (a
    /// second tap clears it, as on the web, unless at least one must stay
    /// chosen); several toggle; never below `minSelected`.
    func toggled(_ selection: [String], option: CmsChoiceOption) -> [String] {
        let id = option.id
        let chosen = selection.contains(id)
        if !multi {
            if chosen { return (minSelected >= 1 || look == "highlight") ? selection : [] }
            return [id]
        }
        if chosen {
            guard selection.count > minSelected else { return selection }
            return selection.filter { $0 != id }
        }
        return selection + [id]
    }

    /// The block's output for a choice, the web's: `value` (comma-joined),
    /// `count`, of the real values only; nil when none is chosen. A period
    /// isn't a value: it writes the date parameter instead (`parameterValue`).
    static func output(_ selection: [String], options: [CmsChoiceOption]) -> [String: CmsJSON]? {
        let values = selection.compactMap { id in options.first { $0.id == id && $0.predicate == nil }?.value }
        guard !values.isEmpty else { return nil }
        return ["value": .string(values.joined(separator: ",")), "count": .number(Double(values.count))]
    }

    /// What a period option writes into the list's `parameterId`, the
    /// shared date parameter the calendar writes: `{ operator, start, end }`,
    /// with the dates (ISO) only for `between`.
    static func parameterValue(_ op: String, range: (String, String)? = nil) -> CmsJSON {
        .object([
            "operator": .string(op),
            "start": op == "between" ? range.map { .string($0.0) } ?? .null : .null,
            "end": op == "between" ? range.map { .string($0.1) } ?? .null : .null,
        ])
    }

    /// The period the date parameter holds, for the list's highlight.
    static func period(of parameter: CmsJSON?) -> String? {
        parameter?.objectValue?.string("operator")
    }
}

struct CmsListSelectorBlockView: View {
    let block: CmsBlock
    @EnvironmentObject private var runtime: CmsRuntime
    @State private var note: String?
    @State private var askingRange = false
    @State private var rangeStart = Date()
    @State private var rangeEnd = Date()

    /// The choice, kept in the runtime (`listChoices`) so every copy of the
    /// list shares it.
    private var selection: [String] { runtime.listChoices[slug]?.selection ?? [] }

    private func setChoice(_ selection: [String]) {
        runtime.listChoices[slug] = .init(selection: selection, range: nil)
    }

    private var parameterId: String? { props.string("parameterId").flatMap { $0.isEmpty ? nil : $0 } }

    /// Whether an option is chosen: a value in the choice, a period in the
    /// date parameter (so a period picked on the calendar shows here too).
    private func isChosen(_ option: CmsChoiceOption) -> Bool {
        if let op = option.predicate {
            return parameterId.flatMap { CmsChoiceList.period(of: runtime.parameters[$0]) } == op
        }
        return selection.contains(option.id)
    }

    private var props: [String: CmsJSON] { runtime.resolvedProps(for: block) }
    private var list: CmsChoiceList { CmsChoiceList(props) }
    private var slug: String { block.slug ?? block.id }
    private var querySlug: String? {
        props.string("optionsSource") == "query" ? props.string("querySlug").flatMap { $0.isEmpty ? nil : $0 } : nil
    }

    private var options: [CmsChoiceOption] {
        if let querySlug {
            guard case .ok(let result) = runtime.state(for: querySlug) else { return [] }
            return CmsChoiceList.queryOptions(result.rows, props: props)
        }
        return CmsChoiceList.writtenOptions(props)
    }

    private var loading: Bool {
        guard let querySlug else { return false }
        switch runtime.state(for: querySlug) {
        case .idle, .loading, .waiting: return true
        default: return false
        }
    }

    var body: some View {
        let options = self.options
        VStack(alignment: .leading, spacing: 2) {
            if let label = props.string("label"), !label.isEmpty {
                Text(label)
                    .font(runtime.theme.font(size: 17, weight: .semibold))
                    .foregroundStyle(runtime.theme.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 4)
                    .accessibilityAddTraits(.isHeader)
            }
            if loading && options.isEmpty {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            ForEach(options) { option in
                row(option)
            }
            if let add = props.object("addRow") {
                CmsActionButtonBlockView(block: .action(id: block.id + ".addRow", props: add), chrome: .row)
            }
            if let note {
                Label(note, systemImage: "clock")
                    .font(runtime.theme.font(size: 13, weight: .regular))
                    .foregroundStyle(runtime.theme.textSecondary)
                    .padding(.horizontal, 14)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            if let querySlug { runtime.ensureLoaded(querySlug) }
            seed(options)
        }
        .onChange(of: options.map(\.id)) { _, ids in seed(self.options) }
        .ripulSheet(isPresented: $askingRange, size: .form) { rangeSheet }
        .cmsInspectorID("Cms.listSelector")
    }

    // MARK: Choosing

    /// The default choice, once per list on the runtime (a second copy, or
    /// the drawer opened again, keeps the choice made).
    private func seed(_ options: [CmsChoiceOption]) {
        guard runtime.listChoices[slug] == nil, !options.isEmpty else { return }
        setChoice(list.initialSelection(options))
        publish(options)
    }

    private func choose(_ option: CmsChoiceOption) {
        if option.placeholder {
            Task { await showNote("\(option.label) is coming soon") }
            return
        }
        if let op = option.predicate {
            // A period writes the shared date parameter; `between` asks for its dates first.
            if op == CmsRangePredicateOperator.between.rawValue {
                askingRange = true
            } else if let parameterId {
                runtime.setParameter(parameterId, value: CmsChoiceList.parameterValue(op))
            }
            return
        }
        // At once, no animation: the tick or lozenge must change as the finger lifts.
        setChoice(list.toggled(selection, option: option))
        publish(options)
    }

    private func publish(_ options: [CmsChoiceOption]) {
        let row = CmsChoiceList.output(selection, options: options)
        runtime.setSelectedRows(slug, rows: row.map { [$0] } ?? [])
    }

    private func showNote(_ message: String) async {
        withAnimation { note = message }
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        withAnimation { if note == message { note = nil } }
    }

    /// `between`: a date range, then the period is chosen.
    private var rangeSheet: some View {
        NavigationStack {
            Form {
                DatePicker("From", selection: $rangeStart, displayedComponents: .date)
                DatePicker("To", selection: $rangeEnd, in: rangeStart..., displayedComponents: .date)
            }
            .navigationTitle(options.first { $0.predicate == "between" }?.label ?? "Custom")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { askingRange = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        let picked = (CmsDatePredicate.iso(rangeStart), CmsDatePredicate.iso(max(rangeStart, rangeEnd)))
                        if let parameterId {
                            runtime.setParameter(parameterId, value: CmsChoiceList.parameterValue("between", range: picked))
                        }
                        askingRange = false
                    }
                }
            }
        }
    }

    // MARK: A row

    private func row(_ option: CmsChoiceOption) -> some View {
        let chosen = isChosen(option)
        let highlight = list.look == "highlight"
        let ticks = list.look == "check" || (list.look == nil && list.multi && list.showCheckboxes)
        let tint = optionColor(option)
        return HStack(spacing: 10) {
            Button { choose(option) } label: {
                HStack(spacing: 12) {
                    if ticks { tickBox(chosen: chosen, tint: tint) }
                    media(option)
                    Text(option.label)
                        .font(runtime.theme.font(size: 16, weight: highlight && chosen ? .semibold : .medium))
                        .foregroundStyle(option.placeholder ? runtime.theme.textSecondary : runtime.theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if list.look == nil && !ticks && chosen {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(runtime.theme.color(role: .primary))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(chosen ? .isSelected : [])
            if let action = props.object("rowAction") {
                // `form` keeps its templates; the presenter fills them from the row.
                CmsActionButtonBlockView(block: .action(id: "\(block.id).rowAction.\(option.id)",
                                                        props: filled(action, row: option.row)
                                                            .merging(["_formRow": .object(option.row)]) { a, _ in a }),
                                         chrome: .icon)
                    .foregroundStyle(runtime.theme.color(role: .primary))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background {
            if highlight && chosen {
                Color.clear.modifier(GlassLozengeModifier(tint: runtime.theme.color(role: .primary)))
            }
        }
        .cmsInspectorID("Cms.listSelector.option")
    }

    /// A tick box tinted with the option's colour: filled with a white tick
    /// when chosen, an outline when not.
    private func tickBox(chosen: Bool, tint: Color) -> some View {
        let box = RoundedRectangle(cornerRadius: 5, style: .continuous)
        return ZStack {
            if chosen {
                box.fill(tint)
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(runtime.theme.color(role: .paper))
            } else {
                box.strokeBorder(tint, lineWidth: 1.6)
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }

    /// The option's icon: a symbol (nav icon key or SF Symbol), an image
    /// address, or a query row's picture through `imageColumn` (and its
    /// image chain, as a list row's).
    @ViewBuilder
    private func media(_ option: CmsChoiceOption) -> some View {
        if let imageColumn = props.string("imageColumn"), !imageColumn.isEmpty, querySlug != nil {
            // `image: { chain }`, a list row picture's chain; else the column holds an address.
            let chain = props.object("image")?["chain"] ?? .array([])
            let picture = CmsColumnPresentation(key: imageColumn, json: ["image": .object(["chain": chain])])
            let candidates = picture.pictureCandidates(option.row)
            if !candidates.isEmpty {
                CmsColumnPicture(candidates: candidates, size: 26, cornerRadius: 13)
                    .accessibilityHidden(true)
            }
        } else if let image = option.image, let url = URL(string: image) {
            AsyncImage(url: url) { $0.resizable().scaledToFit() } placeholder: { Color.clear }
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
        } else if let symbol = CmsButtonMenu.symbolName(option.symbol) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(option.placeholder ? runtime.theme.textSecondary : runtime.theme.textPrimary.opacity(0.85))
                .frame(width: 26)
                .accessibilityHidden(true)
        }
    }

    /// An option's colour: a palette role, a CSS colour, else `primary`.
    private func optionColor(_ option: CmsChoiceOption) -> Color {
        if let raw = option.color, !raw.isEmpty {
            if let role = CmsPaletteRole(rawValue: raw) { return runtime.theme.color(role: role) }
            if let css = runtime.color(raw) { return css }
        }
        return runtime.theme.color(role: .primary)
    }

    /// A row action's text fields with `{column}` slots filled from the option's row.
    private func filled(_ action: [String: CmsJSON], row: [String: CmsJSON]) -> [String: CmsJSON] {
        action.mapValues { value in
            guard case .string(let text) = value, text.contains("{") else { return value }
            return .string(CmsListRowLayout.fill(text, row: row) { CmsColumnPresentation(key: $0, json: nil) } ?? text)
        }
    }
}
