import SwiftUI

/// What a tap on a Calendar Strip's day does (`onDayTap`) and the day's
/// details it can open (`dayDetails`): the native twin of
/// `cmsCalendarDayDetails.ts`, tested against its cases. The calendar shows
/// them in the system popover anchored to the day (`CmsCalendarDayDetailsView`).
/// docs/plans/cms-calendar-day-popover.md.
enum CmsCalendarDayDetails {
    /// `select` the day (as before) · `details` open its details · `both`.
    enum TapAction: String { case select, details, both }
    /// A day with no rows: nothing opens, or just the add button.
    enum Empty: String { case none, add }

    /// What tapping one of the day's rows does.
    enum RowTap: Equatable {
        /// Its record's form (`openRowForm`'s shape, variants included).
        case form(CmsRowFormSpec)
        /// A page, with the row (and these `{column}` params) as its query's selection.
        case page(String, params: [String: String])
    }

    struct Config {
        var title: String
        var row: CmsListRowLayout
        /// The columns' looks by key, as a cards block's `columns`.
        var columns: [String: [String: CmsJSON]]
        var max: Int
        var listStyle: String?
        var rowTap: RowTap?
        var add: (label: String, form: CmsRowFormSpec)?
        var empty: Empty
        var querySlug: String?
        var dateColumn: String?
        /// A column holding each row's colour, behind its initial when its leading picture is missing.
        var colorColumn: String?

        static let defaultTitle = "{day|EEE d MMM}"
        static let defaultMax = 6

        /// Lenient, as the web's `resolveDayDetails`: no row layout with a title is no details.
        init?(_ json: CmsJSON?) {
            guard let o = json?.objectValue, let row = CmsListRowLayout(o["row"]) else { return nil }
            self.row = row
            if let written = o.string("title"), !written.trimmingCharacters(in: .whitespaces).isEmpty {
                title = written
            } else {
                title = Self.defaultTitle
            }
            var columns: [String: [String: CmsJSON]] = [:]
            for entry in o["columns"]?.arrayValue ?? [] {
                if let c = entry.objectValue, let key = c.string("key"), !key.isEmpty { columns[key] = c }
            }
            self.columns = columns
            if let m = o["max"]?.doubleValue, m.isFinite, m >= 1 { max = Int(m) } else { max = Self.defaultMax }
            listStyle = Self.text(o["listStyle"])
            if let tap = o.object("rowTap") {
                if let form = CmsRowFormSpec(tap["form"]) {
                    rowTap = .form(form)
                } else if let page = Self.text(tap["page"]) {
                    rowTap = .page(page, params: (tap.object("params") ?? [:]).compactMapValues(\.stringValue))
                } else {
                    rowTap = nil
                }
            } else {
                rowTap = nil
            }
            if let a = o.object("add"), let form = CmsRowFormSpec(a["form"]) {
                add = (Self.text(a["label"]) ?? "Add", form)
            } else {
                add = nil
            }
            empty = o.string("empty") == "add" ? .add : .none
            querySlug = Self.text(o["querySlug"])
            dateColumn = Self.text(o["dateColumn"])
            colorColumn = Self.text(o["colorColumn"])
        }

        private static func text(_ v: CmsJSON?) -> String? {
            guard let s = v?.stringValue?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
            return s
        }
    }

    /// The block's `onDayTap`; unset, `details` when it has details to open, else `select`.
    static func tapAction(_ props: [String: CmsJSON]) -> TapAction {
        if let written = props["onDayTap"]?.stringValue.flatMap(TapAction.init(rawValue:)) { return written }
        return Config(props["dayDetails"]) == nil ? .select : .details
    }

    /// Whether a tap on a day with `rows` rows selects it and opens its details
    /// (an empty day opens only with `empty: add` and an add button).
    static func outcome(_ tap: TapAction, details: Config?, rows: Int) -> (select: Bool, open: Bool) {
        let select = tap == .select || tap == .both
        let wants = tap == .details || tap == .both
        guard wants, let details else { return (select, false) }
        return (select, rows > 0 || (details.empty == .add && details.add != nil))
    }

    /// The title: each `{day|pattern}` the day in that pattern (`{day}` in
    /// "EEE d MMM"), `{count}` the number of rows.
    static func title(_ template: String, count: Int, formatDay: (String) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\\{(day|count)(?:\\|([^{}]*))?\\}") else { return template }
        let ns = template as NSString
        var out = ""
        var at = 0
        for match in regex.matches(in: template, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: at, length: match.range.location - at))
            let name = ns.substring(with: match.range(at: 1))
            if name == "count" {
                out += String(count)
            } else {
                let pattern = match.range(at: 2).location == NSNotFound ? "" : ns.substring(with: match.range(at: 2))
                out += formatDay(pattern.trimmingCharacters(in: .whitespaces).isEmpty ? "EEE d MMM" : pattern)
            }
            at = match.range.location + match.range.length
        }
        return out + ns.substring(from: at)
    }

    /// What follows the rows shown: "and n more", or nothing.
    static func moreText(total: Int, max: Int) -> String? {
        let more = total - Swift.min(total, max)
        return more > 0 ? "and \(more) more" : nil
    }

    /// The initial for a row whose leading picture is missing, as a marker's
    /// `initial` fallback draws it (the web's `dayRowInitial`): the first letter
    /// of the picture column's text, or of the row's title when that column
    /// holds an address; on the row's own colour (`colorColumn`'s value), else
    /// the palette's colour for that text. Nil with no text to take a letter from.
    static func initial(pictureText: String, title: String, ownColor: CmsJSON?) -> (letter: String, color: String)? {
        let picture = pictureText.trimmingCharacters(in: .whitespacesAndNewlines)
        let isAddress = picture.range(of: #"^(?:https?:|data:|/)"#, options: [.regularExpression, .caseInsensitive]) != nil
        let label = !picture.isEmpty && !isAddress ? picture : title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return nil }
        let own = ownColor?.stringValue?.trimmingCharacters(in: .whitespaces)
        let color = CmsCalendarDecorations.isColor(own) ? own! : CmsCalendarDecorations.paletteColor(label)
        return (CmsCalendarDecorations.markerInitial(label), color)
    }
}

/// A day's details in the popover: the title, the day's rows as list rows in
/// the list style (a row's tap opens what `rowTap` says), "and n more", and
/// the add button. Its size is its content's, as a popover's is.
struct CmsCalendarDayDetailsView: View {
    let title: String
    let rows: [[String: CmsJSON]]
    let config: CmsCalendarDayDetails.Config
    let style: CmsResolvedListStyle
    let tint: Color
    var onRow: (([String: CmsJSON]) -> Void)?
    var onAdd: (() -> Void)?
    /// The content's own height: the popover's ideal height, so a short day
    /// fits exactly and a long one is held to the room there is and scrolls.
    @State private var contentHeight: CGFloat = 0
    @EnvironmentObject private var runtime: CmsRuntime

    var body: some View {
        ScrollView {
            content
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        // As wide as a phone allows a popover (370 points), narrower where it must.
        .frame(minWidth: 300, idealWidth: 370, maxWidth: 370, idealHeight: contentHeight > 0 ? contentHeight : nil)
    }

    private var content: some View {
        let shown = Array(rows.prefix(config.max))
        return VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.ripul(.subheadline, weight: .semibold))
                .foregroundStyle(.ripul(.textSecondary))
                .accessibilityAddTraits(.isHeader)
            if !shown.isEmpty {
                CmsStyledRows(style: style, items: shown) { row in
                    // A row that opens nothing is drawn as it is, not as a dimmed, disabled button.
                    if let onRow {
                        Button {
                            onRow(row)
                        } label: {
                            rowContent(row, navigates: true)
                        }
                        .buttonStyle(.plain)
                        .cmsInspectorID("Cms.simpleCalendar.dayDetails.row")
                    } else {
                        rowContent(row, navigates: false)
                            .cmsInspectorID("Cms.simpleCalendar.dayDetails.row")
                    }
                }
            }
            if let more = CmsCalendarDayDetails.moreText(total: rows.count, max: config.max) {
                Text(more)
                    .font(.ripul(.footnote))
                    .foregroundStyle(.ripul(.textSecondary))
            }
            if let onAdd, let add = config.add {
                Button {
                    onAdd()
                } label: {
                    Label(add.label, systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .tint(tint)
                .cmsInspectorID("Cms.simpleCalendar.dayDetails.add")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rowContent(_ row: [String: CmsJSON], navigates: Bool) -> some View {
        CmsLayoutRowContent(style: style, layout: config.row, row: row,
                            column: presentation, navigates: navigates, leadingInitial: initial) { EmptyView() }
    }

    /// A row without its leading picture keeps the place with its initial, so every row lines up.
    private func initial(_ row: [String: CmsJSON]) -> (letter: String, color: Color)? {
        guard case .image(let name)? = config.row.leading else { return nil }
        let title = CmsListRowLayout.fill(config.row.title.text, row: row, column: presentation) ?? ""
        guard let initial = CmsCalendarDayDetails.initial(pictureText: presentation(name).text(row), title: title,
                                                          ownColor: config.colorColumn.flatMap { row[$0] }) else { return nil }
        guard let color = runtime.color(initial.color) ?? CmsCss.color(initial.color) else { return nil }
        return (initial.letter, color)
    }

    /// A slot's column: its look from `columns` (by key, else valueFrom), with
    /// the slot's own format when it has one (`{total|£#,##0}`), as the web's.
    private func presentation(_ slot: String) -> CmsColumnPresentation {
        let (key, format) = CmsCards.splitSlot(slot)
        var json = config.columns[key] ?? config.columns.values.first { $0.string("valueFrom") == key } ?? [:]
        if let format { json["format"] = .string(format) }
        return CmsColumnPresentation(key: key, json: json)
    }
}
