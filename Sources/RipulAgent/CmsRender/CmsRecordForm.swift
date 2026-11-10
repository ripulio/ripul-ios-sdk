import Foundation

// MARK: - A record's form (docs/plans/cms-record-form.md)
//
// One form for adding and editing a record, described once on the mutation
// (`action.form`, `action.computed`) and opened the same way from a button, a
// list row or a card. The layout (sections, rows of tiles, a summary), the
// computed values and their small expression language, list inputs, and a
// draft filled from a row live here; the sheet is CmsRecordFormSheet.

/// `action.form`: the sheet's title and its sections.
public struct CmsFormDef: Codable, Equatable {
    public struct Section: Equatable {
        public var heading: String?
        public var collapsible: Bool
        public var collapsed: Bool
        public var items: [Item]
    }

    /// A summary's line: a label, an optional detail, an amount (templates);
    /// `input` makes it tappable, to edit that input.
    public struct Line: Codable, Equatable {
        public var label: String
        public var detail: String?
        public var amount: String
        public var input: String?
    }

    public enum Item: Equatable {
        case input(String)
        case row([String])
        case summary(lines: [Line], total: Line?)
    }

    public var title: String?
    /// The default picker for the form's date and timestamp inputs; an input's own wins.
    public var picker: String?
    public var sections: [Section]
    /// `form.steps`: the form one step at a time (docs/plans/cms-add-job.md).
    public var steps: [CmsFormStep] = []
    /// How the steps' progress shows: `bar` (the default), `count` or `none`.
    public var progress: String?
    /// The last step's button; "Save" when unset.
    public var submitLabel: String?
    /// `sheet` | `page`: how this form opens; unset follows the theme (CmsMasthead.swift).
    public var presentation: String?
    /// As a page: the masthead style it opens under (nil = the theme's default).
    public var masthead: String?
    /// As a page: `masthead: false`, no band (a plain bar with back).
    public var mastheadOff = false
    /// As a page: a template under the title in its masthead.
    public var subtitle: String?
    /// As a page: `over` or `under` its masthead (nil = the style's).
    public var mastheadScroll: String?
    /// As a page going under: `rounded` or `straight` (nil = the style's).
    public var mastheadCut: String?
    /// `form.computed: { name: expression }`.
    public var computed: [CmsComputedDef]

    public init(title: String? = nil, picker: String? = nil, sections: [Section], computed: [CmsComputedDef] = []) {
        self.title = title
        self.picker = picker
        self.sections = sections
        self.computed = computed
    }

    public init(from decoder: Decoder) throws {
        let raw = try CmsJSON(from: decoder)
        guard let o = raw.objectValue else { throw DecodingError.typeMismatch(CmsFormDef.self, .init(codingPath: decoder.codingPath, debugDescription: "a form is an object")) }
        title = o.string("title")
        picker = o.string("picker")
        computed = (o.object("computed") ?? [:]).compactMap { name, expr in
            expr.stringValue.map { CmsComputedDef(name: name, expr: $0, format: nil) }
        }.sorted { $0.name < $1.name }
        sections = Self.sections(o["sections"])
        if case .array(let list)? = o["steps"] {
            steps = list.compactMap { raw in
                guard let st = raw.objectValue else { return nil }
                let rule = st["showWhen"].flatMap { try? JSONDecoder().decode(CmsShowWhen.self, from: JSONEncoder().encode($0)) }
                return CmsFormStep(title: st.string("title"), question: st.string("question"),
                                   description: st.string("description"), sections: Self.sections(st["sections"]),
                                   nextLabel: st.string("nextLabel"), showWhen: rule)
            }
        }
        progress = o.string("progress")
        submitLabel = o.string("submitLabel")
        presentation = o.string("presentation")
        if case .bool(false)? = o["masthead"] { mastheadOff = true } else { masthead = o.string("masthead") }
        subtitle = o.string("subtitle")
        mastheadScroll = o.string("mastheadScroll")
        mastheadCut = o.string("mastheadCut")
    }

    /// A list of sections: items (names, rows, summaries), headings, collapsing.
    static func sections(_ raw: CmsJSON?) -> [Section] {
        var sections: [Section] = []
        if case .array(let list)? = raw {
            for entry in list {
                guard let s = entry.objectValue else { continue }
                var items: [Item] = []
                if case .array(let rawItems)? = s["items"] {
                    for item in rawItems {
                        if case .string(let name) = item, !name.isEmpty { items.append(.input(name)); continue }
                        guard let io = item.objectValue else { continue }
                        if case .array(let names)? = io["row"] {
                            let row = names.compactMap(\.stringValue).filter { !$0.isEmpty }
                            if !row.isEmpty { items.append(.row(row)) }
                        } else if case .array(let lines)? = io["summary"] {
                            items.append(.summary(lines: lines.compactMap(Self.line), total: Self.line(io["total"])))
                        }
                    }
                }
                // `summary: { lines, total }` on the section (the settled shape).
                if let summary = s.object("summary"), case .array(let lines)? = summary["lines"] {
                    items.append(.summary(lines: lines.compactMap(Self.line), total: Self.line(summary["total"])))
                }
                // `collapsible`: starts closed, opened from its heading.
                let collapsible = s.bool("collapsible") ?? false
                sections.append(Section(heading: s.string("heading").flatMap { $0.isEmpty ? nil : $0 },
                                        collapsible: collapsible,
                                        collapsed: s.bool("collapsed") ?? collapsible,
                                        items: items))
            }
        }
        return sections
    }

    private static func line(_ json: CmsJSON?) -> Line? {
        guard let o = json?.objectValue, let label = o.string("label"), let amount = o.string("amount") else { return nil }
        return Line(label: label, detail: o.string("detail"), amount: amount, input: o.string("input"))
    }

    public func encode(to encoder: Encoder) throws {
        var out: [String: CmsJSON] = [:]
        if let title { out["title"] = .string(title) }
        if let picker { out["picker"] = .string(picker) }
        out["sections"] = Self.sectionsJSON(sections)
        if !steps.isEmpty {
            out["steps"] = .array(steps.map { step in
                var o: [String: CmsJSON] = ["sections": Self.sectionsJSON(step.sections)]
                if let t = step.title { o["title"] = .string(t) }
                if let q = step.question { o["question"] = .string(q) }
                if let d = step.description { o["description"] = .string(d) }
                if let n = step.nextLabel { o["nextLabel"] = .string(n) }
                if let rule = step.showWhen, let data = try? JSONEncoder().encode(rule),
                   let json = try? JSONDecoder().decode(CmsJSON.self, from: data) { o["showWhen"] = json }
                return .object(o)
            })
        }
        if let progress { out["progress"] = .string(progress) }
        if let submitLabel { out["submitLabel"] = .string(submitLabel) }
        if let presentation { out["presentation"] = .string(presentation) }
        if mastheadOff { out["masthead"] = .bool(false) } else if let masthead { out["masthead"] = .string(masthead) }
        if let subtitle { out["subtitle"] = .string(subtitle) }
        if let mastheadScroll { out["mastheadScroll"] = .string(mastheadScroll) }
        if let mastheadCut { out["mastheadCut"] = .string(mastheadCut) }
        try CmsJSON.object(out).encode(to: encoder)
    }

    private static func sectionsJSON(_ sections: [Section]) -> CmsJSON {
        .array(sections.map { section in
            var s: [String: CmsJSON] = ["collapsible": .bool(section.collapsible), "collapsed": .bool(section.collapsed)]
            if let heading = section.heading { s["heading"] = .string(heading) }
            s["items"] = .array(section.items.map { item in
                switch item {
                case .input(let name): return .string(name)
                case .row(let names): return .object(["row": .array(names.map(CmsJSON.string))])
                case .summary(let lines, let total):
                    var o: [String: CmsJSON] = ["summary": .array(lines.map(Self.lineJSON))]
                    if let total { o["total"] = Self.lineJSON(total) }
                    return .object(o)
                }
            })
            return .object(s)
        })
    }

    private static func lineJSON(_ line: Line) -> CmsJSON {
        var o: [String: CmsJSON] = ["label": .string(line.label), "amount": .string(line.amount)]
        if let detail = line.detail { o["detail"] = .string(detail) }
        if let input = line.input { o["input"] = .string(input) }
        return .object(o)
    }

    /// Every input or computed name the layout reads (for checks and tests).
    public var namesUsed: [String] {
        (sections + steps.flatMap(\.sections)).flatMap { section in
            section.items.flatMap { item -> [String] in
                switch item {
                case .input(let name): return [name]
                case .row(let names): return names
                case .summary(let lines, let total): return (lines + [total].compactMap { $0 }).compactMap(\.input)
                }
            }
        }
    }
}

/// `action.computed`: a named read-only value worked out from the inputs.
public struct CmsComputedDef: Codable, Equatable {
    public var name: String
    public var expr: String
    public var format: String?
}

/// `openRowForm` (a grid's phone list), a card's `open: { form }`: the
/// mutation whose form opens, the values it opens with (`{column}`
/// templates over the row), the delete mutation, and an optional query that
/// loads the whole record first.
public struct CmsRowFormSpec: Equatable {
    public struct Load: Equatable {
        public var querySlug: String
        public var params: [String: String]
    }

    public var mutationSlug: String
    public var values: [String: String]
    public var deleteMutationSlug: String?
    /// The delete button's word, on the form and its confirm ("Archive"); nil reads "Delete".
    public var deleteLabel: String?
    public var load: Load?
    /// `actions`: more buttons, each running another mutation with the
    /// form's record (the web's `CmsRowFormAction`).
    public var actions: [Action] = []
    public struct Action: Equatable {
        public var label: String
        public var mutationSlug: String
        public var values: [String: String]
    }
    /// Forms for some rows: the first whose `when` holds for the tapped row
    /// opens instead (`variants`, the web's `rowFormFor`).
    public var variants: [Variant] = []

    /// A row form for the rows whose condition holds.
    public struct Variant: Equatable {
        public var when: CmsRowCondition
        public var form: CmsRowFormSpec
    }

    /// A form with no row: an action button's own.
    public init(mutationSlug: String) {
        self.mutationSlug = mutationSlug
        self.values = [:]
    }

    public init?(_ json: CmsJSON?) {
        guard let o = json?.objectValue, let slug = o.string("mutationSlug"), !slug.isEmpty else { return nil }
        mutationSlug = slug
        values = (o.object("values") ?? [:]).compactMapValues(\.stringValue)
        deleteMutationSlug = o.string("deleteMutationSlug").flatMap { $0.isEmpty ? nil : $0 }
        deleteLabel = o.string("deleteLabel").flatMap { $0.isEmpty ? nil : $0 }
        if case .array(let raw)? = o["actions"] {
            actions = raw.compactMap { entry in
                guard let a = entry.objectValue, let label = a.string("label"), !label.isEmpty,
                      let slug = a.string("mutationSlug"), !slug.isEmpty else { return nil }
                return Action(label: label, mutationSlug: slug, values: (a.object("values") ?? [:]).compactMapValues(\.stringValue))
            }
        }
        if let l = o.object("load"), let q = l.string("querySlug"), !q.isEmpty {
            load = Load(querySlug: q, params: (l.object("params") ?? [:]).compactMapValues(\.stringValue))
        }
        if case .array(let raw)? = o["variants"] {
            variants = raw.compactMap { entry in
                guard let v = entry.objectValue, let when = CmsRowCondition(v["when"]),
                      var form = CmsRowFormSpec(entry) else { return nil }
                form.variants = []
                return Variant(when: when, form: form)
            }
        }
    }

    /// An action's inputs from the form's record (the web's `rowFormActionParams`):
    /// each input named in `values` from its template, else the record's column
    /// of the same name; blanks left out.
    public static func actionParams(_ action: Action, inputNames: [String], record: [String: CmsJSON]) -> [String: CmsJSON] {
        var out: [String: CmsJSON] = [:]
        for name in inputNames.isEmpty ? Array(action.values.keys) : inputNames {
            let value: CmsJSON?
            if let template = action.values[name] {
                let t = template.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("{"), t.hasSuffix("}"), !t.dropFirst().dropLast().contains("{") {
                    value = record[String(t.dropFirst().dropLast())]
                } else {
                    value = .string(CmsFormText.fill(template) { col, _ in record[col].map { CmsCards.text($0) } ?? "" })
                }
            } else {
                value = record[name]
            }
            if let value, value != .null, CmsCards.text(value) != "" { out[name] = value }
        }
        return out
    }

    /// The form a row opens: its first variant whose `when` holds, else this one.
    public func form(for row: [String: CmsJSON]) -> CmsRowFormSpec {
        if let v = variants.first(where: { $0.when.holds(row) }) { return v.form }
        var plain = self
        plain.variants = []
        return plain
    }
}

/// A condition on a row's column (the web's `CmsRowCondition`, the cards'
/// column condition): every part given must hold; values compare as text;
/// `empty` is a missing value, null or blank text.
public struct CmsRowCondition: Equatable {
    public var column: String
    public var equals: CmsJSON?
    public var `in`: [CmsJSON]?
    public var empty: Bool?

    public init?(_ json: CmsJSON?) {
        guard let o = json?.objectValue, let column = o.string("column"), !column.isEmpty else { return nil }
        self.column = column
        equals = o["equals"]
        if case .array(let list)? = o["in"] { self.in = list }
        if case .bool(let b)? = o["empty"] { empty = b }
    }

    private static func text(_ v: CmsJSON?) -> String {
        switch v {
        case nil, .null?: return ""
        case .string(let s)?: return s
        case .number(let n)?: return CmsActionForm.numberString(n)
        case .bool(let b)?: return b ? "true" : "false"
        case let other?: return other.displayString
        }
    }

    public func holds(_ row: [String: CmsJSON]) -> Bool {
        let v = Self.text(row[column])
        if let empty, (v.trimmingCharacters(in: .whitespaces).isEmpty) != empty { return false }
        if let equals, v != Self.text(equals) { return false }
        if let list = self.in, !list.contains(where: { Self.text($0) == v }) { return false }
        return true
    }
}

// MARK: - Expressions

/// The small expression language of computed values: numbers, names
/// (`hours`, `job.rate`), `+ - * /`, parentheses, and `minutes(a, b)`,
/// `sum(list.field)`, `sum(list, expr)` (per item, an item's field first),
/// `count(list)`, `round(x[, d])`, `min`, `max`, `coalesce(a, b, …)`, text in
/// quotes (`'fixed'`), comparisons (`== != < <= > >=`, 1 or 0) and
/// `if(c, a, b)`, `uuid()` and `timezone()`: the web's `cmsFormExpr.ts`, to the same rules (both test
/// against `cmsFormExpr.cases.json`). A blank name makes arithmetic over it
/// blank (as on the web); a truth counts as 1 or 0; division by 0 is blank.
/// A value is a number or text, so a form can send a choice it works out.
public indirect enum CmsFormExpr: Equatable {
    case number(Double)
    case text(String)
    case name(String)
    case unary(Character, CmsFormExpr)
    case binary(Character, CmsFormExpr, CmsFormExpr)
    case compare(String, CmsFormExpr, CmsFormExpr)
    case call(String, [CmsFormExpr])
    case siteFunction(String, [CmsFormExpr])
    case bool(Bool)

    /// Parses an expression; nil when it doesn't read.
    public static func parse(_ text: String) -> CmsFormExpr? {
        var p = Parser(text)
        guard let e = p.comparison(), p.atEnd, p.valid else { return nil }
        return e
    }

    private static let arity: [String: ClosedRange<Int>] = [
        "minutes": 2...2, "sum": 1...2, "count": 1...1, "round": 1...2, "min": 2...2, "max": 2...2,
        "coalesce": 2...Int.max, "if": 3...3, "uuid": 0...0, "timezone": 0...0,
    ]

    private struct Parser {
        let chars: [Character]
        var i = 0
        var valid = true
        init(_ s: String) { chars = Array(s) }

        var atEnd: Bool { peekChar() == nil }

        func peekChar() -> Character? {
            var j = i
            while j < chars.count, chars[j].isWhitespace { j += 1 }
            return j < chars.count ? chars[j] : nil
        }

        mutating func skip() { while i < chars.count, chars[i].isWhitespace { i += 1 } }

        mutating func eat(_ c: Character) -> Bool {
            skip()
            guard i < chars.count, chars[i] == c else { return false }
            i += 1
            return true
        }

        /// A comparison operator here, consumed; nil when there is none.
        mutating func compareOp() -> String? {
            skip()
            guard i < chars.count else { return nil }
            let two = i + 1 < chars.count ? String(chars[i...(i + 1)]) : ""
            if ["==", "!=", "<=", ">="].contains(two) { i += 2; return two }
            if chars[i] == "<" || chars[i] == ">" { let op = String(chars[i]); i += 1; return op }
            return nil
        }

        mutating func comparison() -> CmsFormExpr? {
            guard let left = expression() else { return nil }
            if let op = compareOp() {
                guard let right = expression() else { return nil }
                return .compare(op, left, right)
            }
            return left
        }

        mutating func expression() -> CmsFormExpr? {
            guard var left = term() else { return nil }
            while let c = peekChar(), c == "+" || c == "-" || c == "−" {
                _ = eat(c)
                guard let right = term() else { return nil }
                left = .binary(c == "−" ? "-" : c, left, right)
            }
            return left
        }

        mutating func term() -> CmsFormExpr? {
            guard var left = factor() else { return nil }
            while let c = peekChar(), c == "*" || c == "/" || c == "×" || c == "÷" {
                _ = eat(c)
                guard let right = factor() else { return nil }
                left = .binary(c == "×" ? "*" : c == "÷" ? "/" : c, left, right)
            }
            return left
        }

        mutating func factor() -> CmsFormExpr? {
            skip()
            guard i < chars.count else { return nil }
            let c = chars[i]
            if c == "-" || c == "−" { i += 1; return factor().map { .unary("-", $0) } }
            if c == "'" || c == "\"" {
                i += 1
                var s = ""
                while i < chars.count, chars[i] != c { s.append(chars[i]); i += 1 }
                guard i < chars.count else { valid = false; return nil }
                i += 1
                return .text(s)
            }
            if c == "(" {
                i += 1
                let e = comparison()
                return eat(")") ? e : nil
            }
            if c.isNumber || c == "." {
                var s = ""
                while i < chars.count, chars[i].isNumber || chars[i] == "." { s.append(chars[i]); i += 1 }
                return Double(s).map(CmsFormExpr.number)
            }
            if c.isLetter || c == "_" {
                var s = ""
                while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" || chars[i] == "." {
                    s.append(chars[i]); i += 1
                }
                if s == "true" { return .bool(true) }
                if s == "false" { return .bool(false) }
                if s == "fn" { valid = false; return nil }
                if s.hasPrefix("fn.") {
                    let slug = String(s.dropFirst(3))
                    guard !slug.isEmpty, !slug.contains("."), eat("(") else { valid = false; return nil }
                    var args: [CmsFormExpr] = []
                    if !eat(")") {
                        repeat {
                            guard let a = comparison() else { return nil }
                            args.append(a)
                        } while eat(",")
                        guard eat(")") else { return nil }
                    }
                    return .siteFunction(slug, args)
                }
                if eat("(") {
                    var args: [CmsFormExpr] = []
                    if !eat(")") {
                        repeat {
                            guard let a = comparison() else { return nil }
                            args.append(a)
                        } while eat(",")
                        guard eat(")") else { return nil }
                    }
                    let fn = s.lowercased()
                    guard let range = CmsFormExpr.arity[fn], range.contains(args.count) else { valid = false; return nil }
                    if (fn == "sum" || fn == "count"), case .name = args.first {} else if fn == "sum" || fn == "count" { valid = false; return nil }
                    return .call(fn, args)
                }
                return .name(s)
            }
            return nil
        }
    }

    /// Every name the expression reads (`job.rate`, `breaks.minutes`, …).
    public var names: [String] {
        switch self {
        case .number, .bool, .text: return []
        case .name(let n): return [n]
        case .unary(_, let e): return e.names
        case .binary(_, let a, let b), .compare(_, let a, let b): return a.names + b.names
        case .call(_, let args), .siteFunction(_, let args): return args.flatMap(\.names)
        }
    }

    /// Every `fn.<slug>(...)` call in the expression, in evaluation order.
    public var functionCalls: [(slug: String, args: [CmsFormExpr])] {
        switch self {
        case .number, .bool, .text, .name: return []
        case .unary(_, let e): return e.functionCalls
        case .binary(_, let a, let b), .compare(_, let a, let b): return a.functionCalls + b.functionCalls
        case .call(_, let args): return args.flatMap(\.functionCalls)
        case .siteFunction(let slug, let args): return args.flatMap(\.functionCalls) + [(slug: slug, args: args)]
        }
    }

    public var usesFunctions: Bool {
        !functionCalls.isEmpty
    }
}

/// Tri-state evaluation result so `pending` and `error` propagate distinctly from `.value(.blank)`.
public enum CmsFormEvalState: Equatable, Error {
    case value(CmsFormValue)
    case pending
    case error(String)

    public var formValue: CmsFormValue {
        if case .value(let v) = self { return v }
        return .blank
    }
}

/// A computed value: a number, text, or blank.
public enum CmsFormValue: Equatable {
    case number(Double)
    case text(String)
    case blank

    public var number: Double? {
        switch self {
        case .number(let n): return n
        case .text(let t): return Double(t.trimmingCharacters(in: .whitespaces))
        case .blank: return nil
        }
    }

    var isBlank: Bool {
        switch self {
        case .blank: return true
        case .text(let t): return t.isEmpty
        case .number: return false
        }
    }

    /// A condition holds: not blank, not 0, not empty text.
    var holds: Bool { !isBlank && self != .number(0) }

    /// As text: a number as JavaScript's `String(n)` writes it.
    public var text: String? {
        switch self {
        case .number(let n): return CmsActionForm.numberString(n)
        case .text(let t): return t
        case .blank: return nil
        }
    }
}

/// What an expression reads: a name's number, a name's moment (for
/// `minutes`), a list's items, and a name's text (when it isn't a number).
public struct CmsFormScope {
    public var number: (String) -> Double?
    public var moment: (String) -> Date?
    public var items: (String) -> [[String: CmsJSON]]
    public var value: (String) -> CmsFormValue
    public var state: ((String) -> CmsFormEvalState)?
    public var rawJSON: ((String) -> CmsJSON?)?
    public var siteFunction: ((String, [CmsJSON]) -> CmsFormEvalState)?

    public init(number: @escaping (String) -> Double?, moment: @escaping (String) -> Date?,
                items: @escaping (String) -> [[String: CmsJSON]],
                value: ((String) -> CmsFormValue)? = nil,
                state: ((String) -> CmsFormEvalState)? = nil,
                rawJSON: ((String) -> CmsJSON?)? = nil,
                siteFunction: ((String, [CmsJSON]) -> CmsFormEvalState)? = nil) {
        self.number = number
        self.moment = moment
        self.items = items
        self.value = value ?? { name in number(name).map(CmsFormValue.number) ?? .blank }
        self.state = state
        self.rawJSON = rawJSON
        self.siteFunction = siteFunction
    }

    /// The expression's number, or nil when it's blank: a blank name (an
    /// optional input left empty) makes the arithmetic over it blank, as on
    /// the web; `coalesce` gives the first that isn't. A truth counts as 1
    /// or 0. Division by 0 is blank. Text reads as its number, if any.
    public func evaluate(_ e: CmsFormExpr) -> Double? {
        value(e, item: nil).number
    }

    /// The expression's value: a number, text, or blank.
    public func value(_ e: CmsFormExpr) -> CmsFormValue {
        value(e, item: nil)
    }

    /// The expression's tri-state (`value` / `pending` / `error`).
    public func evaluateState(_ e: CmsFormExpr) -> CmsFormEvalState {
        evalState(e, item: nil)
    }

    private func value(_ e: CmsFormExpr, item: [String: CmsJSON]?) -> CmsFormValue {
        evalState(e, item: item).formValue
    }

    private func evalNum(_ e: CmsFormExpr, item: [String: CmsJSON]?) -> Result<Double?, CmsFormEvalState> {
        switch evalState(e, item: item) {
        case .pending: return .failure(.pending)
        case .error(let msg): return .failure(.error(msg))
        case .value(let v): return .success(v.number)
        }
    }

    private func evalState(_ e: CmsFormExpr, item: [String: CmsJSON]?) -> CmsFormEvalState {
        switch e {
        case .number(let n): return .value(.number(n))
        case .text(let t): return .value(.text(t))
        case .bool(let b): return .value(.number(b ? 1 : 0))
        case .name(let n):
            // Inside `sum(list, expr)`, an item's own field comes first.
            if let item, let v = item[n] { return .value(Self.number(v).map(CmsFormValue.number) ?? .blank) }
            if let state { return state(n) }
            return .value(value(n))
        case .unary(_, let a):
            switch evalNum(a, item: item) {
            case .failure(let st): return st
            case .success(let n): return .value(n.map { .number(-$0) } ?? .blank)
            }
        case .binary(let op, let a, let b):
            let xOpt: Double?
            switch evalNum(a, item: item) {
            case .failure(let st): return st
            case .success(let n): xOpt = n
            }
            let yOpt: Double?
            switch evalNum(b, item: item) {
            case .failure(let st): return st
            case .success(let n): yOpt = n
            }
            guard let x = xOpt, let y = yOpt else { return .value(.blank) }
            switch op {
            case "+": return .value(.number(x + y))
            case "-": return .value(.number(x - y))
            case "*": return .value(.number(x * y))
            default: return .value(y == 0 ? .blank : .number(x / y))
            }
        case .compare(let op, let a, let b):
            let xState = evalState(a, item: item)
            guard case .value(let x) = xState else { return xState }
            let yState = evalState(b, item: item)
            guard case .value(let y) = yState else { return yState }
            // A blank side: equal only to another blank.
            if x.isBlank || y.isBlank {
                switch op {
                case "==": return .value(.number(x.isBlank && y.isBlank ? 1 : 0))
                case "!=": return .value(.number(x.isBlank && y.isBlank ? 0 : 1))
                default: return .value(.blank)
                }
            }
            let order: Int
            if case .number(let p) = x, case .number(let q) = y { order = p < q ? -1 : p > q ? 1 : 0 }
            else { let p = x.text ?? "", q = y.text ?? ""; order = p < q ? -1 : p > q ? 1 : 0 }
            let ok: Bool
            switch op {
            case "==": ok = order == 0
            case "!=": ok = order != 0
            case "<": ok = order < 0
            case "<=": ok = order <= 0
            case ">": ok = order > 0
            default: ok = order >= 0
            }
            return .value(.number(ok ? 1 : 0))
        case .call(let fn, let args):
            switch fn {
            case "minutes":
                guard args.count == 2, case .name(let a) = args[0], case .name(let b) = args[1] else { return .value(.blank) }
                if let state {
                    let sa = state(a)
                    if case .pending = sa { return .pending }
                    if case .error = sa { return sa }
                    let sb = state(b)
                    if case .pending = sb { return .pending }
                    if case .error = sb { return sb }
                }
                guard let from = moment(a), let to = moment(b) else { return .value(.blank) }
                return .value(.number((to.timeIntervalSince(from) / 60).rounded()))
            case "uuid":
                // A new random id, for a backend where the client names the record.
                return .value(.text(UUID().uuidString.lowercased()))
            case "timezone":
                // The viewer's IANA time zone.
                return .value(.text(TimeZone.current.identifier))
            case "if":
                guard args.count == 3 else { return .value(.blank) }
                let condState = evalState(args[0], item: item)
                guard case .value(let condVal) = condState else { return condState }
                return condVal.holds ? evalState(args[1], item: item) : evalState(args[2], item: item)
            case "sum", "count":
                guard let first = args.first, case .name(let path) = first else { return .value(.blank) }
                // `sum(list, expr)`: the expression per item (an item's field
                // first), totalled; one item's blank makes the total blank.
                if fn == "sum", args.count == 2, !path.contains(".") {
                    var total = 0.0
                    for row in items(path) {
                        switch evalNum(args[1], item: row) {
                        case .failure(let st): return st
                        case .success(let v):
                            guard let v else { return .value(.blank) }
                            total += v
                        }
                    }
                    return .value(.number(total))
                }
                let dot = path.firstIndex(of: ".")
                let list = dot.map { String(path[..<$0]) } ?? path
                if fn == "count" { return .value(.number(Double(items(list).count))) }
                guard let dot else { return .value(.blank) }
                let field = String(path[path.index(after: dot)...])
                return .value(.number(items(list).reduce(0) { $0 + (Self.number($1[field]) ?? 0) }))
            case "round":
                guard let first = args.first else { return .value(.blank) }
                let xOpt: Double?
                switch evalNum(first, item: item) {
                case .failure(let st): return st
                case .success(let n): xOpt = n
                }
                var digits = 0.0
                if args.count > 1 {
                    switch evalNum(args[1], item: item) {
                    case .failure(let st): return st
                    case .success(let dOpt):
                        guard let d = dOpt else { return .value(.blank) }
                        digits = max(0, min(10, d.rounded(.towardZero)))
                    }
                }
                guard let x = xOpt else { return .value(.blank) }
                let p = pow(10, digits)
                return .value(.number((x * p).rounded() / p))
            case "min", "max":
                var numbers: [Double] = []
                var hasBlank = false
                for a in args {
                    switch evalNum(a, item: item) {
                    case .failure(let st): return st
                    case .success(let n):
                        if let n { numbers.append(n) } else { hasBlank = true }
                    }
                }
                guard !args.isEmpty, !hasBlank else { return .value(.blank) }
                return .value((fn == "min" ? numbers.min() : numbers.max()).map(CmsFormValue.number) ?? .blank)
            case "coalesce":
                for a in args {
                    let st = evalState(a, item: item)
                    switch st {
                    case .pending, .error: return st
                    case .value(let v):
                        if !v.isBlank { return .value(v) }
                    }
                }
                return .value(.blank)
            default: return .value(.blank)
            }
        case .siteFunction(let slug, let args):
            var argJSON: [CmsJSON] = []
            for arg in args {
                if case .name(let path) = arg, let rawJSON, let direct = rawJSON(path) {
                    switch direct {
                    case .array, .object, .bool:
                        argJSON.append(direct)
                        continue
                    default:
                        break
                    }
                }
                let st = evalState(arg, item: item)
                switch st {
                case .pending, .error: return st
                case .value(.number(let n)): argJSON.append(.number(n))
                case .value(.text(let s)): argJSON.append(.string(s))
                case .value(.blank): argJSON.append(.null)
                }
            }
            guard let siteFunction else {
                return .error("Function \"fn.\(slug)\" is not available.")
            }
            return siteFunction(slug, argJSON)
        }
    }

    static func number(_ v: CmsJSON?) -> Double? {
        switch v {
        case .number(let n)?: return n
        case .string(let s)?: return Double(s.trimmingCharacters(in: .whitespaces))
        case .bool(let b)?: return b ? 1 : 0
        default: return nil
        }
    }

    static func truth(_ v: CmsJSON?) -> Bool {
        switch v {
        case .bool(let b)?: return b
        case .number(let n)?: return n != 0
        case .string(let s)?: return ["true", "1", "yes"].contains(s.lowercased())
        default: return false
        }
    }
}

// MARK: - Formats and templates

public enum CmsFormText {
    /// `duration`: minutes as "8h", "7h 30m", "45m", "0m".
    public static func duration(_ minutes: Double) -> String {
        let total = Int(minutes.rounded())
        let sign = total < 0 ? "-" : ""
        let h = abs(total) / 60, m = abs(total) % 60
        if h == 0 { return "\(sign)\(m)m" }
        return m == 0 ? "\(sign)\(h)h" : "\(sign)\(h)h \(m)m"
    }

    /// A duration in words, as a tile or a list item reads it: "1 h 15 min",
    /// "30 min", "2 h".
    public static func durationWords(_ minutes: Double) -> String {
        let total = Int(minutes.rounded())
        let h = abs(total) / 60, m = abs(total) % 60
        if h == 0 { return "\(m) min" }
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    /// A value shown with a slot's format: `duration`, a two-way `Yes;No` for
    /// a truth, a number format (`0.00`, `"£"0.00`), or a date pattern for a
    /// moment. Unset: a number as written, a moment as `d MMM, HH:mm`.
    public static func show(number: Double?, moment: Date? = nil, truth: Bool? = nil,
                            text: String? = nil, format: String?) -> String {
        if let format, format.contains(";"), let truth {
            let parts = format.split(separator: ";", omittingEmptySubsequences: false)
            return String(truth ? parts[0] : parts.count > 1 ? parts[1] : "")
        }
        if let moment {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_GB")
            f.dateFormat = format ?? "d MMM, HH:mm"
            return f.string(from: moment)
        }
        if let number {
            if format == "duration" { return duration(number) }
            if let format, !format.isEmpty { return CmsFormatValue.apply(CmsActionForm.numberString(number), pattern: format) }
            let rounded = (number * 100).rounded() / 100
            return CmsActionForm.numberString(rounded)
        }
        return text ?? ""
    }

    /// Fills `{name}` and `{name|format}` slots through `value`.
    public static func fill(_ template: String, value: (String, String?) -> String) -> String {
        var out = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            out += rest[..<open]
            let slot = rest[rest.index(after: open)..<close]
            let parts = slot.split(separator: "|", maxSplits: 1)
            let name = parts.first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            out += value(name, parts.count > 1 ? String(parts[1]) : nil)
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }
}

// MARK: - The form's values: draft, computed, filled from a row

extension CmsActionForm {
    /// A list input's items as they stand, keeping each item's own keys
    /// (an `id` it came with) through edits.
    public static func listItems(_ draft: Draft?) -> [[String: CmsJSON]] {
        if case .list(let items, _)? = draft { return items }
        return []
    }

    /// The draft opened from a row: each input's value from `values` (already
    /// filled from the row), over the empty form's draft. A list reads an
    /// array or its JSON text.
    public static func draft(_ inputs: [CmsActionInputDef], values: [String: CmsJSON],
                             now: Date = Date(), calendar: Calendar = .current) -> [String: Draft] {
        var draft = initialDraft(inputs, now: now, calendar: calendar)
        for input in inputs {
            guard let raw = values[input.name], raw != .null else { continue }
            if input.type == "list" {
                draft[input.name] = .list(listValue(raw), removed: [])
                continue
            }
            if input.type == "dates" {
                draft[input.name] = .text(CmsDateSets.value(itemField: input.itemField, raw).joined(separator: ","))
                continue
            }
            let text: String
            switch raw {
            case .string(let s): text = s
            case .number(let n): text = numberString(n)
            case .bool(let b): text = b ? "true" : "false"
            default: text = raw.displayString
            }
            switch control(for: input) {
            case .toggle: draft[input.name] = .bool(["true", "1", "yes"].contains(text.lowercased()))
            case .date: draft[input.name] = .date(parseDate(String(text.prefix(10)), calendar: calendar))
            case .dateTime: draft[input.name] = .date(parseTimestamp(text) ?? parseLooseTimestamp(text))
            case .time: draft[input.name] = .date(parseTime(text, on: now, calendar: calendar))
            default: draft[input.name] = .text(text)
            }
        }
        return draft
    }

    static func listValue(_ raw: CmsJSON) -> [[String: CmsJSON]] {
        switch raw {
        case .array(let items): return items.compactMap(\.objectValue)
        case .string(let s):
            guard let data = s.data(using: .utf8), let decoded = try? JSONDecoder().decode(CmsJSON.self, from: data),
                  case .array(let items) = decoded else { return [] }
            return items.compactMap(\.objectValue)
        default: return []
        }
    }

    /// A timestamp a database writes without a zone (`2026-10-29 09:00:00`),
    /// read on the viewer's clock.
    static func parseLooseTimestamp(_ text: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for pattern in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            f.dateFormat = pattern
            if let d = f.date(from: String(text.prefix(19))) { return d }
        }
        return nil
    }

    /// A list input's value as sent: its items, then, with `removedItems`,
    /// each removed item that came with the record as `{ id, <flag>: true }`.
    public static func listWire(_ input: CmsActionInputDef, items: [[String: CmsJSON]],
                                removed: [[String: CmsJSON]]) -> CmsJSON {
        var out = items.map(CmsJSON.object)
        if let flag = input.removedItems?.flag, !flag.isEmpty {
            for item in removed {
                guard let id = item["id"], id != .null else { continue }
                out.append(.object(["id": id, flag: .bool(true)]))
            }
        }
        return .array(out)
    }
}

/// The form's live values for its title, summary and expressions.
public struct CmsFormValues {
    public struct PendingFunctionCall {
        public var cacheKey: String
        public var fn: CmsFunctionDef
        public var input: [String: CmsJSON]
    }

    public let inputs: [CmsActionInputDef]
    public let computed: [CmsComputedDef]
    public let draft: [String: CmsActionForm.Draft]
    /// The chosen option's row of a choice input from a query, by input name.
    public let chosenRow: (String) -> [String: CmsJSON]?
    public let functions: [String: CmsFunctionDef]
    public let siteRevision: String
    public let functionCache: CmsFunctionResultCache?
    public let onMissingFunctionCall: ((PendingFunctionCall) -> Void)?

    public init(inputs: [CmsActionInputDef], computed: [CmsComputedDef],
                draft: [String: CmsActionForm.Draft],
                chosenRow: @escaping (String) -> [String: CmsJSON]? = { _ in nil },
                functions: [String: CmsFunctionDef] = [:],
                siteRevision: String = "",
                functionCache: CmsFunctionResultCache? = nil,
                onMissingFunctionCall: ((PendingFunctionCall) -> Void)? = nil) {
        self.inputs = inputs
        self.computed = computed
        self.draft = draft
        self.chosenRow = chosenRow
        self.functions = functions
        self.siteRevision = siteRevision
        self.functionCache = functionCache
        self.onMissingFunctionCall = onMissingFunctionCall
    }

    private func input(_ name: String) -> CmsActionInputDef? { inputs.first { $0.name == name } }

    public var scope: CmsFormScope { scope(depth: 0) }

    private func scope(depth: Int) -> CmsFormScope {
        CmsFormScope(
            number: { name in self.number(name, depth: depth) },
            moment: { name in self.moment(name) },
            items: { name in self.items(name) },
            value: { name in self.value(name, depth: depth) },
            state: { name in self.state(name, depth: depth) },
            rawJSON: { name in self.rawJSON(name) },
            siteFunction: { slug, args in self.invokeSiteFunction(slug: slug, args: args) }
        )
    }

    private func rawJSON(_ name: String) -> CmsJSON? {
        if computed.contains(where: { $0.name == name }) { return nil }
        if let dot = name.firstIndex(of: "."), input(String(name[..<dot])) != nil {
            return chosenRow(String(name[..<dot]))?[String(name[name.index(after: dot)...])]
        }
        guard let d = draft[name] else { return nil }
        switch d {
        case .bool(let b): return .bool(b)
        case .list(let list, _): return .array(list.map(CmsJSON.object))
        case .text(let t) where input(name)?.type == "dates":
            return .array(CmsDateSets.value(itemField: nil, .string(t)).map(CmsJSON.string))
        default: return nil
        }
    }

    private func invokeSiteFunction(slug: String, args: [CmsJSON]) -> CmsFormEvalState {
        guard let fn = functions[slug] else {
            return .error("Function \"fn.\(slug)\" is not defined on this site.")
        }
        let bound: [String: CmsJSON]
        switch CmsFunctionRunner.bindPositionalInputs(fn, args: args) {
        case .failure(let err): return .error(err.message)
        case .success(let b): bound = b
        }
        guard let functionCache else {
            return .pending
        }
        let key = CmsFunctionRunner.cacheKey(siteRevision: siteRevision, fn: fn, boundInput: bound)
        if let cached = functionCache.get(key) {
            return cached
        }
        onMissingFunctionCall?(PendingFunctionCall(cacheKey: key, fn: fn, input: bound))
        return .pending
    }

    /// A list input's items; a set of days' days, one item each (so `count` counts them).
    private func items(_ name: String) -> [[String: CmsJSON]] {
        if input(name)?.type == "dates", case .text(let t)? = draft[name] {
            return CmsDateSets.value(itemField: nil, .string(t)).map { ["day": .string($0)] }
        }
        return CmsActionForm.listItems(draft[name])
    }

    /// A name's tri-state (`value` / `pending` / `error`).
    public func state(_ name: String, depth: Int = 0) -> CmsFormEvalState {
        if let def = computed.first(where: { $0.name == name }) {
            guard depth < 16 else { return .value(.blank) }
            guard let expr = CmsFormExpr.parse(def.expr) else {
                if def.expr.contains("fn.") {
                    return .error("Invalid expression in \"\(name)\".")
                }
                return .value(.blank)
            }
            return scope(depth: depth + 1).evaluateState(expr)
        }
        if let n = number(name, depth: depth) { return .value(.number(n)) }
        if let dot = name.firstIndex(of: "."), input(String(name[..<dot])) != nil {
            let v = chosenRow(String(name[..<dot]))?[String(name[name.index(after: dot)...])]
            return .value(v.map { CmsCards.text($0) }.map { $0.isEmpty ? CmsFormValue.blank : .text($0) } ?? .blank)
        }
        if case .text(let t)? = draft[name], !t.isEmpty, input(name)?.type != "dates" { return .value(.text(t)) }
        return .value(.blank)
    }

    /// Every computed name's tri-state (`value` / `pending` / `error`).
    public var computedStates: [String: CmsFormEvalState] {
        var out: [String: CmsFormEvalState] = [:]
        for def in computed {
            out[def.name] = state(def.name)
        }
        return out
    }

    /// Collects any uncached `fn.<slug>(...)` calls across all computed expressions.
    public func pendingFunctionCalls() -> [PendingFunctionCall] {
        var missingByKey: [String: PendingFunctionCall] = [:]
        var order: [String] = []
        let probe = CmsFormValues(
            inputs: inputs,
            computed: computed,
            draft: draft,
            chosenRow: chosenRow,
            functions: functions,
            siteRevision: siteRevision,
            functionCache: functionCache,
            onMissingFunctionCall: { call in
                if missingByKey[call.cacheKey] == nil {
                    missingByKey[call.cacheKey] = call
                    order.append(call.cacheKey)
                }
            }
        )
        for def in computed {
            _ = probe.state(def.name)
        }
        return order.compactMap { missingByKey[$0] }
    }

    /// Resolves all reachable `fn.<slug>(...)` calls off the main thread into `functionCache`.
    @discardableResult
    public func resolveAllFunctions() async -> [String: CmsFormEvalState] {
        guard let functionCache else { return computedStates }
        for _ in 0..<16 {
            let missing = pendingFunctionCalls()
            if missing.isEmpty { break }
            for call in missing {
                let outcome = await CmsFunctionRunner.evaluate(call.fn, namedInputs: call.input)
                functionCache.set(call.cacheKey, outcome)
            }
        }
        return computedStates
    }

    /// A name's value: a computed value's (a number or text), else its number, else its text.
    public func value(_ name: String, depth: Int = 0) -> CmsFormValue {
        state(name, depth: depth).formValue
    }

    public func moment(_ name: String) -> Date? {
        if case .date(let d)? = draft[name] { return d }
        return nil
    }

    /// A name's number: an input's, a computed value's, or a chosen option's column.
    public func number(_ name: String, depth: Int = 0) -> Double? {
        if let def = computed.first(where: { $0.name == name }) {
            guard depth < 16, let expr = CmsFormExpr.parse(def.expr) else { return nil }
            return scope(depth: depth + 1).value(expr).number
        }
        if let dot = name.firstIndex(of: "."), input(String(name[..<dot])) != nil {
            let column = String(name[name.index(after: dot)...])
            return CmsFormScope.number(chosenRow(String(name[..<dot]))?[column])
        }
        switch draft[name] {
        case .text(let t)?: return Double(t.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
        case .bool(let b)?: return b ? 1 : 0
        case .list(let items, _)?: return Double(items.count)
        default: return nil
        }
    }

    /// A slot's text: a computed value or number in its format, a moment, a
    /// truth, a chosen option's column, or an input's own text.
    public func text(_ name: String, format: String?) -> String {
        if let def = computed.first(where: { $0.name == name }) {
            // A computed value that is text shows as it is.
            if case .text(let t) = value(name), Double(t) == nil { return t }
            return CmsFormText.show(number: number(name), format: format ?? def.format)
        }
        if let dot = name.firstIndex(of: "."), input(String(name[..<dot])) != nil {
            let value = chosenRow(String(name[..<dot]))?[String(name[name.index(after: dot)...])]
            if let n = CmsFormScope.number(value), format != nil { return CmsFormText.show(number: n, format: format) }
            return value.map { CmsCards.text($0) } ?? ""
        }
        switch draft[name] {
        case .date(let d)?: return d.map { CmsFormText.show(number: nil, moment: $0, format: format) } ?? ""
        case .bool(let b)?: return CmsFormText.show(number: nil, truth: b, text: b ? "Yes" : "No", format: format)
        case .text(let t)?:
            if let format, let n = Double(t) { return CmsFormText.show(number: n, format: format) }
            return t
        case .list(let items, _)?: return "\(items.count)"
        default: return ""
        }
    }

    public func fill(_ template: String) -> String {
        CmsFormText.fill(template) { text($0, format: $1) }
    }

    /// The template filled, or nil while any of its slots fills blank (a
    /// summary line's detail is hidden then, as on the web).
    public func fillComplete(_ template: String) -> String? {
        var blank = false
        let text = CmsFormText.fill(template) { name, format in
            let t = self.text(name, format: format)
            if t.isEmpty { blank = true }
            return t
        }
        return blank ? nil : text
    }

    /// An item of a list input as its `itemLabel` reads it.
    public static func itemText(_ template: String?, item: [String: CmsJSON], fields: [CmsActionInputDef]) -> String {
        guard let template, !template.isEmpty else {
            // The web's reading: the visible fields joined with " · ", a
            // duration in words, a true truth as its label (a false one left out).
            return fields.filter { $0.hidden != true }.compactMap { f -> String? in
                guard let v = item[f.name], v != .null else { return nil }
                if f.type == "boolean" { return CmsFormScope.truth(v) ? f.displayLabel : nil }
                if f.type == "integer", let unit = f.unit, let n = CmsFormScope.number(v) {
                    return CmsFormText.durationWords(unit == "seconds" ? n / 60 : n)
                }
                let text = CmsCards.text(v)
                return text.isEmpty ? nil : text
            }.joined(separator: " · ")
        }
        return CmsFormText.fill(template) { name, format in
            let v = item[name]
            // A duration in seconds reads as minutes for the `duration` format.
            let perMinute: Double = fields.first { $0.name == name }?.unit == "seconds" ? 60 : 1
            switch v {
            case .bool(let b)?: return CmsFormText.show(number: nil, truth: b, text: b ? "Yes" : "No", format: format)
            case .number(let n)?: return CmsFormText.show(number: format == "duration" ? n / perMinute : n, format: format)
            default:
                if let format, let n = CmsFormScope.number(v) { return CmsFormText.show(number: n, format: format) }
                if let format, format.contains(";") { return CmsFormText.show(number: nil, truth: CmsFormScope.truth(v), format: format) }
                return v.map { CmsCards.text($0) } ?? ""
            }
        }
    }
}
