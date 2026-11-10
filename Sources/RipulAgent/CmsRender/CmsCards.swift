import SwiftUI

// MARK: - The `cards` block: model and rules (docs/plans/cms-cards.md §4–§7)
//
// Cards the site wrote and cards per row of a query or view, in one block,
// shown as a stack, a carousel or only the first. Each card is a fixed set of
// parts whose text lines are list-row lines (`{column}` slots in each
// column's format), with variants picked by the row's state, buttons that act
// on the card's row, and closing. Twin of `packages/shared-types/src/cmsCards.ts`;
// nothing here knows paydays or WAC. Decoding is lenient: a bad entry drops itself.

typealias CmsCardLine = CmsListRowLayout.Line

/// A condition on a card's row, or on whether a query has rows.
enum CmsCardCondition: Equatable {
    case column(String, equals: CmsJSON?, oneOf: [CmsJSON]?, empty: Bool?)
    case rows(String, empty: Bool)

    init?(_ json: CmsJSON?) {
        guard let o = json?.objectValue else { return nil }
        if let column = o.string("column"), !column.isEmpty {
            self = .column(column, equals: o["equals"], oneOf: o["in"]?.arrayValue, empty: o.bool("empty"))
        } else if let query = o.string("rows"), !query.isEmpty {
            self = .rows(query, empty: o.bool("empty") ?? false)
        } else {
            return nil
        }
    }

    /// The column it reads, if any (to wait for a pending source).
    var column: String? {
        if case .column(let c, _, _, _) = self { return c }
        return nil
    }

    /// Values compare as text; `empty` is a missing value, null or blank text.
    /// Several tests on one column must all hold; none means "not empty".
    func holds(row: [String: CmsJSON]?, rowCount: (String) -> Int?) -> Bool {
        switch self {
        case .rows(let query, let empty):
            let count = rowCount(query) ?? 0
            return empty ? count == 0 : count > 0
        case .column(let column, let equals, let oneOf, let empty):
            let value = row.flatMap { CmsColumnPresentation.field($0, column) }
            let text = CmsCards.text(value)
            var tested = false
            if let empty {
                tested = true
                if empty != text.isEmpty { return false }
            }
            if let equals {
                tested = true
                if text != CmsCards.text(equals) { return false }
            }
            if let oneOf {
                tested = true
                if !oneOf.contains(where: { CmsCards.text($0) == text }) { return false }
            }
            return tested || !text.isEmpty
        }
    }
}

/// What a card or button does.
enum CmsCardAction: Equatable {
    case openPage(String, params: [String: CmsJSON])
    case openURL(String)
    case openTab(String)
    /// `open: { sidebar: 'left' | 'right' }`: the page's side drawer.
    case openSidebar(String)
    /// `open: { form: { mutationSlug, values, deleteMutationSlug, load } }`:
    /// the record form, filled from the card's row.
    case openForm(CmsRowFormSpec)
    /// `open: { host: name }`: something only the app does (sign out), from `CmsRuntime.hostActions`.
    case openHost(String)
    /// `open: { web: address, title }`: a web page inside the app (CmsWebPage).
    case openWeb(String, title: String?)
    case run(String, inputs: [String: CmsJSON], pending: String?)
    case show(String)
    case close

    init?(_ json: CmsJSON?) {
        guard let o = json?.objectValue else { return nil }
        if let open = o.object("open") {
            if let page = open.string("page") { self = .openPage(page, params: open.object("params") ?? [:]) }
            else if let url = open.string("url") { self = .openURL(url) }
            else if let tab = open.string("tab") { self = .openTab(tab) }
            else if let edge = open.string("sidebar") { self = .openSidebar(edge == "right" ? "right" : "left") }
            else if let form = CmsRowFormSpec(open["form"]) { self = .openForm(form) }
            else if let host = open.string("host"), !host.isEmpty { self = .openHost(host) }
            else if let web = open.string("web"), !web.isEmpty { self = .openWeb(web, title: open.string("title")) }
            else { return nil }
        } else if let run = o.string("run"), !run.isEmpty {
            self = .run(run, inputs: o.object("inputs") ?? [:], pending: o.string("pending"))
        } else if let show = o.string("show"), !show.isEmpty {
            self = .show(show)
        } else if o.bool("close") == true {
            self = .close
        } else {
            return nil
        }
    }
}

struct CmsCardButton: Equatable {
    var action: CmsCardAction
    var label: String
    var icon: String?
    /// A picture (an address) in place of the icon, drawn as a glyph in the button's colour.
    var image: String?
    /// `filled` | `outlined` | `tinted` | `plain`.
    var look: String

    init?(_ json: CmsJSON) {
        guard let o = json.objectValue, let action = CmsCardAction(json), let label = o.string("label") else { return nil }
        self.action = action
        self.label = label
        icon = o.string("icon")
        image = o.string("image")
        look = o.string("look").flatMap { ["filled", "outlined", "tinted", "plain", "icon"].contains($0) ? $0 : nil } ?? "filled"
    }
}

extension CmsCardAction {
    /// Whether this can be done here: a host action only when the app handles its name.
    func available(hostActions: Set<String>) -> Bool {
        if case .openHost(let name) = self { return hostActions.contains(name) }
        return true
    }
}

/// A round button at the card's top trailing corner (`accessory`): a picture, the
/// initials of a name, or a symbol, that acts (a profile button). The web's
/// `CardAccessory` in cmsCards.ts; both test against cmsCardAccessory.cases.json.
struct CmsCardAccessory: Equatable {
    var action: CmsCardAction
    var label: String
    var initials: String?
    var image: String?
    var symbol: String?
    var size: CGFloat

    static let defaultSize: CGFloat = 40

    init?(_ json: CmsJSON?) {
        guard let o = json?.objectValue, let action = CmsCardAction(json), let label = o.string("label"), !label.isEmpty else { return nil }
        self.action = action
        self.label = label
        initials = o.string("initials")
        image = o.string("image")
        symbol = o.string("symbol")
        size = Self.size(o["size"])
    }

    /// The size, kept to 24–64 (default 40).
    static func size(_ json: CmsJSON?) -> CGFloat {
        guard case .number(let n)? = json, n.isFinite else { return defaultSize }
        return CGFloat(min(64, max(24, n.rounded(.toNearestOrAwayFromZero))))
    }

    /// The first letter or digit of the first and last words, upper-cased.
    static func initials(_ name: String?) -> String {
        let words = (name ?? "").split(whereSeparator: { $0.isWhitespace }).compactMap { word in
            word.first { $0.isLetter || $0.isNumber }
        }
        guard let first = words.first else { return "" }
        let picked = words.count == 1 ? [first] : [first, words[words.count - 1]]
        return String(picked).uppercased()
    }
}

enum CmsCardMedia: Equatable {
    case symbol(String)
    /// A column's picture: its value as an address, or through an image chain.
    case image(String, chain: [CmsCalendarDecorations.ImageEntry])
    /// `{ image, template: true }`: a picture drawn as a glyph in the style's media tint.
    case glyph(String)
    case date(String)

    init?(_ json: CmsJSON?) {
        guard let o = json?.objectValue else { return nil }
        if let s = o.string("symbol") { self = .symbol(s) }
        else if let c = o.string("image"), o.bool("template") == true { self = .glyph(c) }
        else if let c = o.string("image") { self = .image(c, chain: CmsCalendarDecorations.imageChain(o["chain"])) }
        else if let d = o.string("date") { self = .date(d) }
        else { return nil }
    }
}

enum CmsCardClose: Equatable {
    case device
    case run(String, inputs: [String: CmsJSON])

    init?(_ json: CmsJSON?) {
        guard let o = json?.objectValue else { return nil }
        if o.string("remember") == "device" { self = .device }
        else if let run = o.string("run"), !run.isEmpty { self = .run(run, inputs: o.object("inputs") ?? [:]) }
        else { return nil }
    }
}

/// A card's parts. Every part is optional; in a variant, a part it sets
/// replaces the card's and one it leaves out keeps the card's.
struct CmsCardParts: Equatable {
    var tone: String?
    var media: CmsCardMedia?
    var mediaPlacement: String?
    var eyebrow: CmsCardLine?
    var title: CmsCardLine?
    var body: CmsCardLine?
    var value: CmsCardLine?
    var figures: [Figure]?
    var lines: [CmsCardLine]?
    var chip: String?
    var buttons: [CmsCardButton]?
    var tap: CmsCardAction?
    var close: CmsCardClose?
    /// Swipe actions (CmsSwipe): resolved against the card's row when drawn.
    var swipe: CmsJSON?
    var accessory: CmsCardAccessory?
    /// A primitives tree (CmsPrimitives) drawn in place of the interior parts.
    var layout: CmsJSON?

    struct Figure: Equatable {
        var label: String
        var value: CmsCardLine
    }

    static let maxFigures = 4, maxLines = 3, maxButtons = 3
    /// Icon-only buttons (a row of social links) count apart from the others, up to six (the web's `cardButtonsShown`).
    static let maxIconButtons = 6

    static func buttonsShown(_ all: [CmsCardButton]) -> [CmsCardButton] {
        var labelled = 0, icons = 0
        return all.filter { b in
            if b.look == "icon" { icons += 1; return icons <= maxIconButtons }
            labelled += 1
            return labelled <= maxButtons
        }
    }

    init() {}

    init(_ o: [String: CmsJSON]) {
        tone = o.string("tone")
        media = CmsCardMedia(o["media"])
        mediaPlacement = o.string("mediaPlacement")
        eyebrow = CmsListRowLayout.line(o["eyebrow"])
        title = CmsListRowLayout.line(o["title"])
        body = CmsListRowLayout.line(o["body"])
        value = CmsListRowLayout.line(o["value"])
        figures = o["figures"]?.arrayValue.map { list in
            Array(list.compactMap { f -> Figure? in
                guard let fo = f.objectValue, let value = CmsListRowLayout.line(fo["value"]) else { return nil }
                return Figure(label: fo.string("label") ?? "", value: value)
            }.prefix(Self.maxFigures))
        }
        lines = o["lines"]?.arrayValue.map { Array($0.compactMap(CmsListRowLayout.line).prefix(Self.maxLines)) }
        chip = o.string("chip").flatMap { $0.isEmpty ? nil : $0 }
        buttons = o["buttons"]?.arrayValue.map { Self.buttonsShown($0.compactMap(CmsCardButton.init)) }
        tap = CmsCardAction(o["tap"])
        close = CmsCardClose(o["close"])
        swipe = o["swipe"].flatMap { $0.objectValue == nil ? nil : $0 }
        accessory = CmsCardAccessory(o["accessory"])
        layout = o["layout"].flatMap { $0.objectValue == nil ? nil : $0 }
    }

    /// `self` with every part `over` sets.
    func applying(_ over: CmsCardParts) -> CmsCardParts {
        var out = self
        out.tone = over.tone ?? tone
        out.media = over.media ?? media
        out.mediaPlacement = over.mediaPlacement ?? mediaPlacement
        out.eyebrow = over.eyebrow ?? eyebrow
        out.title = over.title ?? title
        out.body = over.body ?? body
        out.value = over.value ?? value
        out.figures = over.figures ?? figures
        out.lines = over.lines ?? lines
        out.chip = over.chip ?? chip
        out.buttons = over.buttons ?? buttons
        out.tap = over.tap ?? tap
        out.close = over.close ?? close
        out.swipe = over.swipe ?? swipe
        out.accessory = over.accessory ?? accessory
        out.layout = over.layout ?? layout
        return out
    }

    /// Every line of text the card draws, for slots and their sources.
    var allLines: [CmsCardLine] {
        [eyebrow, title, body, value].compactMap { $0 } + (figures ?? []).map(\.value) + (lines ?? [])
    }
}

struct CmsCardVariant: Equatable {
    var name: String
    var when: CmsCardCondition?
    var parts: CmsCardParts
}

struct CmsCard: Equatable {
    var id: String?
    var query: String?
    var when: CmsCardCondition?
    var from: String?
    var until: String?
    var parts: CmsCardParts
    var variants: [CmsCardVariant]

    init?(_ json: CmsJSON?) {
        guard let o = json?.objectValue else { return nil }
        id = o.string("id").flatMap { $0.isEmpty ? nil : $0 }
        query = o.string("query").flatMap { $0.isEmpty ? nil : $0 }
        when = CmsCardCondition(o["when"])
        from = o.string("from")
        until = o.string("until")
        parts = CmsCardParts(o)
        variants = (o["variants"]?.arrayValue ?? []).compactMap { v in
            guard let vo = v.objectValue, let name = vo.string("name"), !name.isEmpty else { return nil }
            return CmsCardVariant(name: name, when: CmsCardCondition(vo["when"]), parts: CmsCardParts(vo))
        }
    }

    /// The parts drawn: a requested variant (`show`), else the first whose
    /// `when` holds, else the card's own. A variant without `when` shows
    /// only on request.
    func resolvedParts(row: [String: CmsJSON]?, requested: String?, rowCount: (String) -> Int?) -> (parts: CmsCardParts, variant: String?) {
        if let requested, let v = variants.first(where: { $0.name == requested }) {
            return (parts.applying(v.parts), v.name)
        }
        for v in variants {
            guard let when = v.when else { continue }
            if when.holds(row: row, rowCount: rowCount) { return (parts.applying(v.parts), v.name) }
        }
        return (parts, nil)
    }

    /// Today within `from` and `until` (yyyy-MM-dd, inclusive, the viewer's calendar).
    func inWindow(today: Date = Date(), calendar: Calendar = .current) -> Bool {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let day = f.string(from: today)
        if let from, !from.isEmpty, day < from { return false }
        if let until, !until.isEmpty, day > until { return false }
        return true
    }

    /// Every column the card might read for its `when` and its variants'.
    var conditionColumns: [String] {
        ([when] + variants.map(\.when)).compactMap { $0?.column }
    }
}

struct CmsCardsRows: Equatable {
    var query: String
    var key: String
    var card: CmsCard?
    var cardsBy: (column: String, cards: [String: CmsCard])?
    var columns: [CmsJSON]?
    var group: Group?
    var max: Int?

    struct Group: Equatable {
        var by: String?
        /// `carousel` | `stack` | `first`.
        var display: String
        var header: CmsCardLine?
    }

    static func == (a: CmsCardsRows, b: CmsCardsRows) -> Bool {
        a.query == b.query && a.key == b.key && a.card == b.card && a.cardsBy?.column == b.cardsBy?.column
            && a.cardsBy?.cards == b.cardsBy?.cards && a.columns == b.columns && a.group == b.group && a.max == b.max
    }

    /// A rows item has `card` or `cardsBy`, never both.
    init?(_ json: CmsJSON?) {
        guard let o = json?.objectValue, let query = o.string("query"), !query.isEmpty,
              let key = o.string("key"), !key.isEmpty else { return nil }
        self.query = query
        self.key = key
        card = CmsCard(o["card"])
        if let by = o.object("cardsBy"), let column = by.string("column") {
            var cards: [String: CmsCard] = [:]
            for (value, raw) in by.object("cards") ?? [:] { cards[value] = CmsCard(raw) }
            cardsBy = (column, cards)
        }
        guard (card == nil) != (cardsBy == nil) else { return nil }
        columns = o["columns"]?.arrayValue
        if let g = o.object("group") {
            group = Group(by: g.string("by").flatMap { $0.isEmpty ? nil : $0 },
                          display: g.string("display").flatMap { ["carousel", "stack", "first"].contains($0) ? $0 : nil } ?? "carousel",
                          header: CmsListRowLayout.line(g["header"]))
        }
        max = o.double("max").map { Int($0) }
    }

    /// The template a row draws with: the one card, or the one its kind names.
    func template(for row: [String: CmsJSON]) -> CmsCard? {
        if let card { return card }
        guard let by = cardsBy else { return nil }
        return by.cards[CmsCards.text(CmsColumnPresentation.field(row, by.column))]
    }
}

enum CmsCardsItem: Equatable {
    case card(CmsCard)
    case rows(CmsCardsRows)

    init?(_ json: CmsJSON) {
        guard let o = json.objectValue else { return nil }
        if let card = CmsCard(o["card"]) {
            guard card.id != nil else { return nil } // a written card needs its id
            self = .card(card)
        } else if let rows = CmsCardsRows(o["rows"]) {
            self = .rows(rows)
        } else {
            return nil
        }
    }
}

/// The block's props.
struct CmsCardsProps: Equatable {
    var items: [CmsCardsItem]
    /// `stack` | `carousel` | `first`.
    var display: String
    var carousel: Carousel
    var cardStyle: String?

    struct Carousel: Equatable {
        /// `dots` | `count` | `both` | `none`.
        var indicator: String = "both"
        /// `card` | `tallest`.
        var height: String = "card"
        var peek: CGFloat = 0
        var autoplayMs: Int?
        var loop: Bool = false
    }

    init(_ props: [String: CmsJSON]) {
        items = (props["items"]?.arrayValue ?? []).compactMap(CmsCardsItem.init)
        display = props.string("display").flatMap { ["stack", "carousel", "first"].contains($0) ? $0 : nil } ?? "stack"
        let c = props.object("carousel") ?? [:]
        carousel = Carousel(
            indicator: c.string("indicator").flatMap { ["dots", "count", "both", "none"].contains($0) ? $0 : nil } ?? "both",
            height: c.string("height") == "tallest" ? "tallest" : "card",
            peek: CGFloat(c.double("peek") ?? 0),
            autoplayMs: c.double("autoplayMs").map { Int($0) },
            loop: c.bool("loop") ?? false)
        cardStyle = props.string("cardStyle")
    }
}

// MARK: - Arranging a block's cards

/// One card to draw: its template, the row it reads (if any), and where that row came from.
struct CmsCardInstance: Identifiable, Equatable {
    /// The card's key, unique in the block (the web's): `card:<id>` for a
    /// written card, `row:<item index>:<row key>` for a row's card.
    var id: String
    /// What closing remembers: the written card's id, or the row's key as text.
    var closeKey: String
    var card: CmsCard
    var row: [String: CmsJSON]?
    /// The query or view the row is from.
    var source: String?
    var rowKey: String?
    /// The rows item's column definitions.
    var columns: [CmsJSON]?
    /// A written card whose `query` is still loading: it holds its place, the
    /// query's slots drawn as placeholders.
    var queryWaiting = false
    /// A written card whose `query` failed: "Couldn't load this" with Try again.
    var queryFailed: String?
}

/// One place in the block: a card, a group of cards with an optional
/// header, or a query still loading (held as a loading card by `first`).
enum CmsCardsPlace: Identifiable, Equatable {
    case card(CmsCardInstance)
    case group(id: String, header: String?, display: String, cards: [CmsCardInstance])
    case loading(id: String)

    var id: String {
        switch self {
        case .card(let c): return c.id
        case .group(let id, _, _, _): return id
        case .loading(let id): return id
        }
    }

    var cards: [CmsCardInstance] {
        switch self {
        case .card(let c): return [c]
        case .group(_, _, _, let cards): return cards
        case .loading: return []
        }
    }
}

enum CmsCards {
    /// Stands in for a slot still waiting on its query while a line is filled.
    static let waitingMark = "\u{E000}"

    /// While a written card's query loads: the row to fill a line from, the
    /// query's slots holding `waitingMark`, so the line's own words and
    /// built-in slots fill around them. nil when no slot waits.
    static func waitingRow(for text: String, row: [String: CmsJSON]?) -> [String: CmsJSON]? {
        let waiting = CmsListRowLayout.slots(text).filter(slotWaitsOnQuery)
        guard !waiting.isEmpty else { return nil }
        var out = row ?? [:]
        for slot in waiting { out[splitSlot(slot).column] = .string(waitingMark) }
        return out
    }

    /// A filled line cut at each `waitingMark`: (words, false) and ("", true)
    /// for each placeholder, in order.
    static func waitingSegments(_ filled: String) -> [(text: String, placeholder: Bool)] {
        var out: [(text: String, placeholder: Bool)] = []
        let parts = filled.components(separatedBy: waitingMark)
        for (i, part) in parts.enumerated() {
            if !part.isEmpty { out.append((part, false)) }
            if i < parts.count - 1 { out.append(("", true)) }
        }
        return out
    }

    /// While a written card's query loads: whether a slot reads the query's
    /// row (not a built-in like `{today}`, nor an `@query.column` token).
    static func slotWaitsOnQuery(_ slot: String) -> Bool {
        let name = splitSlot(slot).column
        if name.hasPrefix("@") { return false }
        return CmsLevers.builtIn(name, format: nil) == nil
    }

    /// A value as text, for comparing: numbers without a trailing `.0`, empty for none.
    static func text(_ value: CmsJSON?) -> String {
        guard let value, value != .null else { return "" }
        return value.displayString.trimmingCharacters(in: .whitespaces)
    }

    /// The block's places, in its items' order. `rows(query)` gives a query's
    /// or view's rows when loaded; `visible` says whether a card shows (its
    /// `when`, dates and closing). A group whose cards are all hidden doesn't
    /// show, header included.
    /// `loading(query)` says a query is still loading (not failed): a rows
    /// item holds its place as `.loading` (drawn by `first` as a loading
    /// card); a written card holds it as itself, `queryWaiting`, and with
    /// `failure(query)` as itself, `queryFailed`.
    static func places(items: [CmsCardsItem], rows: (String) -> [[String: CmsJSON]]?,
                       loading: (String) -> Bool = { _ in false },
                       failure: (String) -> String? = { _ in nil },
                       visible: (CmsCardInstance) -> Bool,
                       header: (CmsCardsRows, _ value: String, _ rows: [[String: CmsJSON]]) -> String?) -> [CmsCardsPlace] {
        var out: [CmsCardsPlace] = []
        for (index, item) in items.enumerated() {
            switch item {
            case .card(let card):
                let id = card.id ?? ""
                var instance = CmsCardInstance(id: "card:\(id)", closeKey: id, card: card)
                if let query = card.query {
                    // A written card reading a query: its first row fills the slots;
                    // no rows, no card.
                    instance.source = query
                    if let all = rows(query) {
                        guard let first = all.first else { continue }
                        instance.row = first
                    } else if loading(query) {
                        instance.queryWaiting = true
                    } else if let message = failure(query) {
                        instance.queryFailed = message
                    } else {
                        continue
                    }
                }
                if visible(instance) { out.append(.card(instance)) }
            case .rows(let spec):
                guard let all = rows(spec.query) else {
                    if loading(spec.query) { out.append(.loading(id: "row:\(index)")) }
                    continue
                }
                let instances: [(row: [String: CmsJSON], card: CmsCardInstance)] = all.compactMap { row in
                    guard let template = spec.template(for: row) else { return nil }
                    let key = text(CmsColumnPresentation.field(row, spec.key))
                    return (row, CmsCardInstance(id: "row:\(index):\(key)", closeKey: key, card: template, row: row,
                                                 source: spec.query, rowKey: key, columns: spec.columns))
                }
                guard let group = spec.group else {
                    let shown = instances.map(\.card).filter(visible)
                    out += (spec.max.map { Array(shown.prefix($0)) } ?? shown).map(CmsCardsPlace.card)
                    continue
                }
                var order: [String] = []
                var members: [String: [(row: [String: CmsJSON], card: CmsCardInstance)]] = [:]
                for entry in instances {
                    let value = group.by.map { text(CmsColumnPresentation.field(entry.row, $0)) } ?? ""
                    if members[value] == nil { order.append(value) }
                    members[value, default: []].append(entry)
                }
                for value in order {
                    let entries = members[value] ?? []
                    var shown = entries.map(\.card).filter(visible)
                    if let max = spec.max { shown = Array(shown.prefix(max)) }
                    guard !shown.isEmpty else { continue }
                    // A group of exactly one row is a card on its own, with no
                    // header; several rows stay a group even when one card shows.
                    if entries.count == 1 {
                        out.append(.card(shown[0]))
                    } else {
                        out.append(.group(id: "row:\(index)#\(value)", header: header(spec, value, entries.map(\.row)),
                                          display: group.display, cards: shown))
                    }
                }
            }
        }
        return out
    }

    /// A group header's slots: the group column gives the group's value,
    /// `{<column>_<aggFunc>}` a total in that column's format, `{row_count}`
    /// the number of rows (the grid's totals-row names).
    static func headerText(_ line: CmsCardLine, groupColumn: String?, value: String,
                           rows: [[String: CmsJSON]], columns: [CmsJSON]) -> String? {
        let defs = columns.compactMap(\.objectValue)
        let aggs = defs.compactMap { d -> CmsAgGridBlockView.AggColumn? in
            guard let key = d.string("key"), let fn = d.string("aggFunc"), !fn.isEmpty else { return nil }
            return CmsAgGridBlockView.AggColumn(key: key, valueFrom: d.string("valueFrom") ?? key, fn: fn)
        }
        let totals = CmsAgGridBlockView.computeTotals(rows: rows, columns: aggs)
        var context: [String: CmsJSON] = ["row_count": .number(Double(rows.count))]
        if let groupColumn { context[groupColumn] = .string(value) }
        for (k, v) in totals { context[k] = v }
        return CmsListRowLayout.fill(line.text, row: context) { name in
            // A total takes its column's format.
            for agg in aggs where "\(agg.key)_\(agg.fn)" == name {
                let def = defs.first { $0.string("key") == agg.key } ?? [:]
                var json = def
                json["valueFrom"] = .string(name)
                json["styleRules"] = nil
                return CmsColumnPresentation(key: name, json: json)
            }
            return CmsColumnPresentation(key: name, json: nil)
        }
    }

    /// What a card's `media: { image }` loads: a `{column}` template filled
    /// from the row (an address with slots in it included), an `http(s)://`
    /// address as it is (with or without a row), or else a column name holding
    /// an address (or with a picture of its own). `chain`, with a row, comes first.
    static func mediaCandidates(_ source: String, chain: [CmsCalendarDecorations.ImageEntry],
                                row: [String: CmsJSON]?,
                                column: (String) -> CmsColumnPresentation) -> [CmsCalendarDecorations.ImageCandidate] {
        var out: [CmsCalendarDecorations.ImageCandidate] = []
        if let row, !chain.isEmpty { out += CmsCalendarDecorations.imageCandidates(row, chain) }
        let trimmed = source.trimmingCharacters(in: .whitespaces)
        func isAddress(_ s: String) -> Bool {
            let lower = s.lowercased()
            return (lower.hasPrefix("https://") || lower.hasPrefix("http://")) && !s.contains(where: \.isWhitespace)
        }
        let filled: String?
        if trimmed.contains("{") {
            // A template first, so an address with slots in it fills too.
            filled = CmsListRowLayout.fill(trimmed, row: row ?? [:], column: column)
        } else if isAddress(trimmed) {
            filled = trimmed
        } else if let row {
            let own = column(trimmed).pictureCandidates(row)
            if !own.isEmpty { return out + own }
            filled = CmsColumnPresentation.field(row, trimmed)?.stringValue
        } else {
            filled = nil
        }
        if let filled = filled?.trimmingCharacters(in: .whitespaces), isAddress(filled), !out.contains(.url(filled)) {
            out.append(.url(filled))
        }
        return out
    }

    /// A slot's name and its own format (`{pay|£#,##0.00}`).
    static func splitSlot(_ slot: String) -> (column: String, format: String?) {
        guard let bar = slot.firstIndex(of: "|") else { return (slot, nil) }
        let format = String(slot[slot.index(after: bar)...])
        return (String(slot[..<bar]).trimmingCharacters(in: .whitespaces), format.isEmpty ? nil : format)
    }

    /// The source aliases a card's drawn parts read (`alias.column`), and
    /// its conditions too when `conditions` is true.
    static func aliases(of parts: CmsCardParts, card: CmsCard, view: CmsViewDef?, conditions: Bool = true) -> Set<String> {
        guard let view else { return [] }
        let known = Set((view.sources ?? []).map(\.alias))
        var names: [String] = []
        for line in parts.allLines {
            names += CmsListRowLayout.slots(line.text).map { splitSlot($0).column }
            if let image = line.image { names.append(image) }
        }
        if conditions { names += card.conditionColumns }
        if let chip = parts.chip { names.append(chip) }
        if case .image(let column, _)? = parts.media { names.append(column) }
        if case .date(let column)? = parts.media { names.append(column) }
        return Set(names.compactMap { name in
            guard let dot = name.firstIndex(of: ".") else { return nil }
            let alias = String(name[..<dot])
            return known.contains(alias) ? alias : nil
        })
    }

    /// A mutation's input values from a card's row. A value that is only
    /// one slot keeps the column's type (`"{id}"` gives the id as a number);
    /// other text is filled in as text.
    static func inputs(_ inputs: [String: CmsJSON], row: [String: CmsJSON]?) -> [String: CmsJSON] {
        var out: [String: CmsJSON] = [:]
        for (name, raw) in inputs {
            let value: CmsJSON
            if case .string(let s) = raw {
                let slots = CmsListRowLayout.slots(s)
                if slots.count == 1, s.trimmingCharacters(in: .whitespaces) == "{\(slots[0])}" {
                    value = row.flatMap { CmsColumnPresentation.field($0, splitSlot(slots[0]).column) } ?? .null
                } else if !slots.isEmpty {
                    var filled = s
                    for slot in slots {
                        filled = filled.replacingOccurrences(of: "{\(slot)}",
                            with: text(row.flatMap { CmsColumnPresentation.field($0, splitSlot(slot).column) }))
                    }
                    value = .string(filled)
                } else {
                    value = raw
                }
            } else {
                value = raw
            }
            out[name] = typed(value)
        }
        return out
    }

    /// A value as the mutation route takes it: `{ value, type }`, the value
    /// as text, as the web sends it. The worker binds only a string or null
    /// (`coerceQueryParam`): a number sent as a number was dropped, so a SQL
    /// mutation run from a card or the tab bar's hold failed with a missing
    /// param (the Playground's gym check-out, 30 October 2026).
    static func typed(_ value: CmsJSON) -> CmsJSON {
        switch value {
        case .number(let n):
            let integer = n == n.rounded() && abs(n) < 1e15
            return .object(["value": .string(integer ? String(Int64(n)) : String(n)), "type": .string(integer ? "integer" : "float")])
        case .bool(let b):
            return .object(["value": .string(b ? "true" : "false"), "type": .string("boolean")])
        case .null:
            return .object(["value": .null, "type": .string("string")])
        default:
            return .object(["value": .string(value.displayString), "type": .string("string")])
        }
    }
}

/// Closed cards remembered on the device, per site and block (the block's
/// slug, as the web keys it): written cards by id, rows' cards by row key.
enum CmsCardsClosedStore {
    static func key(cmsId: String, blockId: String) -> String { "io.ripul.cms.cards.closed.\(cmsId).\(blockId)" }

    static func closed(cmsId: String, blockId: String, defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: key(cmsId: cmsId, blockId: blockId)) ?? [])
    }

    static func close(_ cardId: String, cmsId: String, blockId: String, defaults: UserDefaults = .standard) {
        var set = closed(cmsId: cmsId, blockId: blockId, defaults: defaults)
        set.insert(cardId)
        defaults.set(Array(set).sorted(), forKey: key(cmsId: cmsId, blockId: blockId))
    }
}
