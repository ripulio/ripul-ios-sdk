import Foundation

// MARK: - The action contract (mirror of packages/shared-types/src/cmsActions.ts)

/// A mutation's action contract, as much of it as a form needs: the inputs a
/// person is asked for before an action button runs it.
public struct CmsActionConfigDef: Codable, Equatable {
    public var enabled: Bool?
    public var operation: String?
    public var inputs: [CmsActionInputDef]?
    /// The record form's layout, and its computed values.
    public var form: CmsFormDef?
    public var computed: [CmsComputedDef]?
    /// After a success: a countdown, a summary, a page (CmsMutationAfter).
    public var after: CmsJSON?

    private enum CodingKeys: String, CodingKey { case enabled, operation, inputs, form, computed, after }

    /// Lenient: an input that does not decode is dropped, not the contract.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try? c.decodeIfPresent(Bool.self, forKey: .enabled)
        operation = try? c.decodeIfPresent(String.self, forKey: .operation)
        if let raw = try? c.decodeIfPresent([CmsJSON].self, forKey: .inputs) {
            inputs = raw.compactMap { item in
                guard let data = try? JSONEncoder().encode(item) else { return nil }
                return try? JSONDecoder().decode(CmsActionInputDef.self, from: data)
            }
        }
        form = try? c.decodeIfPresent(CmsFormDef.self, forKey: .form)
        after = try? c.decodeIfPresent(CmsJSON.self, forKey: .after)
        if let raw = try? c.decodeIfPresent([CmsJSON].self, forKey: .computed) {
            computed = raw.compactMap { item in
                guard let o = item.objectValue, let name = o.string("name"), let expr = o.string("expr") else { return nil }
                return CmsComputedDef(name: name, expr: expr, format: o.string("format"))
            }
        }
    }

    public init(enabled: Bool? = nil, operation: String? = nil, inputs: [CmsActionInputDef]?) {
        self.enabled = enabled
        self.operation = operation
        self.inputs = inputs
    }
}

/// `CmsActionInput`: one value the action takes.
public struct CmsActionInputDef: Codable, Equatable, Identifiable {
    public var name: String
    public var label: String?
    public var description: String?
    /// string, integer, float, boolean, date, timestamp, json, blob.
    public var type: String
    public var required: Bool?
    public var nullable: Bool?
    public var defaultValue: CmsJSON?
    public var options: CmsColumnOptions?
    public var validation: CmsColumnValidation?
    public var conditional: CmsColumnConditional?
    public var optionsQuery: CmsActionOptionsQuery?
    /// This input must come after another input of the action: an end after
    /// its start (dates, timestamps, numbers; an equal value is refused).
    public var after: CmsActionAfter?
    // The record form (docs/plans/cms-record-form.md):
    /// `tile`: the value big with a detail line under it (a time over its date).
    public var look: String? = nil
    /// A tile's small line: a date pattern for a moment (default `d MMM`).
    public var detail: String? = nil
    /// Text over several lines.
    public var multiline: Bool? = nil
    /// A choice from a query: a picture beside each choice, from this column
    /// (`image: { chain }` as a list row's picture).
    public var imageColumn: String? = nil
    public var image: CmsJSON? = nil
    /// `type: 'list'`: each item's fields, how an item reads, the add button's words.
    public var fields: [CmsActionInputDef]? = nil
    public var itemLabel: String? = nil
    public var addLabel: String? = nil
    /// A list's removed items sent as `{ id, <flag>: true }` (Rails' `_destroy`).
    public var removedItems: CmsRemovedItems? = nil
    /// An integer duration: `seconds` or `minutes`, shown and edited as hours and minutes.
    public var unit: String? = nil
    /// Sent with its `defaultValue`, never shown.
    public var hidden: Bool? = nil
    /// Sends a computed value (the only way one is sent).
    public var fromComputed: String? = nil
    /// A date or timestamp's picker: `sheet`, `floating` or `inline` (wins over `form.picker`).
    public var picker: String? = nil
    // Steps, conditions and choices (docs/plans/cms-add-job.md):
    /// Shown only while another input holds a value; not shown is not required and not sent.
    public var showWhen: CmsShowWhen? = nil
    /// How a choice is offered: `menu`, a pushed `list`, or `inline` rows.
    public var choiceStyle: String? = nil
    /// A choice list with a search field.
    public var searchable: Bool? = nil
    // A set of days (docs/plans/cms-sick-holiday.md; CmsDateSets):
    /// `type: "dates"`: the two date inputs whose days, inclusive, can be chosen.
    public var range: CmsDateRange? = nil
    /// `type: "dates"`: what a new range starts with, `all` its days or `none`.
    public var defaultSelection: String? = nil
    /// `type: "dates"`: each day sent, and read from a row, as `{ <itemField>: day }`.
    public var itemField: String? = nil

    public var id: String { name }
    public var displayLabel: String { (label?.isEmpty == false ? label : nil) ?? name }
    var isRequired: Bool { required == true }

    public init(name: String, label: String? = nil, description: String? = nil, type: String,
                required: Bool? = nil, nullable: Bool? = nil, defaultValue: CmsJSON? = nil,
                options: CmsColumnOptions? = nil, validation: CmsColumnValidation? = nil,
                conditional: CmsColumnConditional? = nil, optionsQuery: CmsActionOptionsQuery? = nil,
                after: CmsActionAfter? = nil) {
        self.name = name; self.label = label; self.description = description; self.type = type
        self.required = required; self.nullable = nullable; self.defaultValue = defaultValue
        self.options = options; self.validation = validation; self.conditional = conditional
        self.optionsQuery = optionsQuery
        self.after = after
    }
}

/// A list input's `removedItems`: the flag a removed item is sent with.
public struct CmsRemovedItems: Codable, Equatable {
    public var flag: String
}

/// `CmsActionInput.after`: the other input's name, or `{ input, message }`.
public struct CmsActionAfter: Codable, Equatable {
    public var input: String
    public var message: String?

    public init(input: String, message: String? = nil) { self.input = input; self.message = message }

    private enum CodingKeys: String, CodingKey { case input, message }

    public init(from decoder: Decoder) throws {
        if let name = try? decoder.singleValueContainer().decode(String.self) {
            input = name
            message = nil
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        input = try c.decode(String.self, forKey: .input)
        message = try? c.decodeIfPresent(String.self, forKey: .message)
    }
}

/// Choices read from a saved query, run as the signed-in member.
public struct CmsActionOptionsQuery: Codable, Equatable {
    public var querySlug: String
    public var valueColumn: String
    public var labelColumn: String?
    /// A picture beside each choice: this column, through `image: { chain }`
    /// as a list row's picture.
    public var imageColumn: String? = nil
    public var image: CmsJSON? = nil
    /// A line under each choice's label.
    public var descriptionColumn: String? = nil
    /// The query's params as templates over the form's values; the list waits until each has one.
    public var params: [String: String]? = nil
    /// Choices a person can add to.
    public var create: CmsOptionsCreate? = nil
    /// `pick`: one choice is made for the person and hidden; none hides the
    /// input and sends nothing; several ask (`CmsFormSteps.whenOne`).
    public var whenOne: String? = nil
    /// `"hide"`: shown only when there is something to choose; one or more
    /// are asked, never picked (`CmsFormSteps.whenOne`).
    public var whenNone: String? = nil
    /// A cell format for `descriptionColumn`'s value ("£#,##0.00": 12.5 → £12.50).
    public var descriptionFormat: String? = nil
    /// The empty choice an optional input offers ("None" when unset): its
    /// label, and a line under it, a template over the form (WAC's "Default rate").
    public var emptyChoice: EmptyChoice? = nil
    /// Inputs one choice also sets: an input's name → a column of the chosen
    /// row (`job_id: "id"`, `hourly_pay: "role.base_rate"`); an empty column clears it.
    public var fills: [String: String]? = nil
    /// Each choice's subtitle, a template over its row, when every slot has a value.
    public var description: String? = nil

    public struct EmptyChoice: Codable, Equatable {
        public var label: String
        public var description: String?
    }

    /// An option's subtitle (the web's `choiceDescription`): `description` filled
    /// from the row when every slot has a value, else `descriptionColumn`'s value,
    /// in `descriptionFormat`. A slot's or the column's format is a number
    /// pattern (`£#,##0.00`) or a date pattern (`HH:mm`, in the viewer's zone).
    public func describe(_ row: [String: CmsJSON]) -> String? {
        if let template = description, !template.isEmpty {
            var blank = false
            let text = CmsFormText.fill(template) { name, format in
                guard let v = row[name], v != .null, !CmsCards.text(v).isEmpty else { blank = true; return "" }
                if let format { return Self.formatted(v, format) }
                return CmsCards.text(v)
            }
            if !blank, !text.trimmingCharacters(in: .whitespaces).isEmpty { return text }
        }
        guard let column = descriptionColumn, let value = row[column] else { return nil }
        let text = descriptionFormat.map { Self.formatted(value, $0) } ?? CmsCards.text(value)
        return text.isEmpty ? nil : text
    }

    /// A value in a format, as the web's `applyFormatPattern`: a date pattern on
    /// a moment (`2026-11-01T17:36:00.000Z` with `HH:mm` is 17:36 in London), a
    /// number pattern on a number, anything else as written.
    static func formatted(_ value: CmsJSON, _ format: String) -> String {
        if !CmsFormatValue.isDatePattern(format), let n = CmsFormScope.number(value) {
            return CmsFormText.show(number: n, format: format)
        }
        return CmsFormatValue.apply(CmsCards.text(value), pattern: format)
    }

    /// The values a chosen row gives the inputs `fills` names (nil clears one), or all cleared with no row.
    public func fillValues(_ row: [String: CmsJSON]?) -> [String: String?] {
        var out: [String: String?] = [:]
        for (input, column) in fills ?? [:] {
            let text = row?[column].flatMap { $0 == .null ? nil : CmsCards.text($0) }
            out[input] = (text?.isEmpty ?? true) ? nil : text
        }
        return out
    }

    private static func same(_ a: String?, _ b: String?) -> Bool {
        let x = a.flatMap { $0.isEmpty ? nil : $0 }, y = b.flatMap { $0.isEmpty ? nil : $0 }
        guard let x, let y else { return x == nil && y == nil }
        if let p = Double(x), let q = Double(y) { return p == q }
        return x == y
    }

    /// Which choice the form's values already describe (the web's `choiceForFills`).
    public func choice(forValues values: [String: String], rows: [[String: CmsJSON]]) -> String? {
        let entries = (fills ?? [:]).sorted { $0.key < $1.key }
        let filled = entries.filter { !Self.same(values[$0.key], nil) }
        guard !filled.isEmpty else { return nil }
        func text(_ row: [String: CmsJSON], _ column: String) -> String? { row[column].flatMap { $0 == .null ? nil : CmsCards.text($0) } }
        var matches = rows.filter { row in filled.allSatisfy { Self.same(text(row, $0.value), values[$0.key]) } }
        // None: match on the inputs whose column every row has (a job's, not its role's).
        if matches.isEmpty {
            let shared = filled.filter { entry in rows.allSatisfy { !Self.same(text($0, entry.value), nil) } }
            if !shared.isEmpty { matches = rows.filter { row in shared.allSatisfy { Self.same(text(row, $0.value), values[$0.key]) } } }
        }
        let best = matches.first { row in entries.allSatisfy { Self.same(text(row, $0.value), values[$0.key]) } } ?? matches.first
        return best.flatMap { text($0, valueColumn) }
    }

    public init(querySlug: String, valueColumn: String, labelColumn: String? = nil) {
        self.querySlug = querySlug; self.valueColumn = valueColumn; self.labelColumn = labelColumn
    }
}

public struct CmsColumnChoice: Codable, Equatable {
    public var value: String
    public var label: String?
    /// A line under the choice's label (a record form's choice list).
    public var description: String? = nil
    public init(value: String, label: String? = nil) { self.value = value; self.label = label }
}

public struct CmsColumnOptions: Codable, Equatable {
    public var choices: [CmsColumnChoice]
    public var strict: Bool
    public init(choices: [CmsColumnChoice], strict: Bool) { self.choices = choices; self.strict = strict }

    private enum CodingKeys: String, CodingKey { case choices, strict }

    /// `strict` left out is false, as the web reads it. Required, an input
    /// whose choices didn't say (most written for a form) failed to decode and
    /// was dropped from the form, so the iPhone never asked for it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        choices = try c.decode([CmsColumnChoice].self, forKey: .choices)
        strict = try c.decodeIfPresent(Bool.self, forKey: .strict) ?? false
    }
}

public struct CmsColumnValidation: Codable, Equatable {
    public var format: String?
    public var pattern: String?
    public var min: Double?
    public var max: Double?
    public var minLength: Int?
    public var maxLength: Int?
    public var message: String?
    public init(format: String? = nil, pattern: String? = nil, min: Double? = nil, max: Double? = nil,
                minLength: Int? = nil, maxLength: Int? = nil, message: String? = nil) {
        self.format = format; self.pattern = pattern; self.min = min; self.max = max
        self.minLength = minLength; self.maxLength = maxLength; self.message = message
    }
}

public struct CmsColumnConditional: Codable, Equatable {
    public struct Case: Codable, Equatable {
        public var `in`: [String]
        public var options: CmsColumnOptions?
        public var validation: CmsColumnValidation?
    }
    public var on: String
    public var cases: [Case]
}

// MARK: - The form's logic (mirror of src/cms/actions/actionInputForm.ts)

/// What an action button asks for before it runs a mutation, and the values
/// it sends: the native twin of the web's `actionInputForm.ts`, judged by the
/// same rules as `validateActionValues`.
public enum CmsActionForm {
    /// The choice styles an input can name.
    static let choiceStyles: Set<String> = ["menu", "list", "inline", "dropdown"]

    /// How a choice input is offered: its own `choiceStyle`, else the site's default
    /// (`theme.inputs.choiceStyle`), else nil (the renderer's own). Only an input
    /// with choices takes one. The web's `choiceStyleFor`, held to `cmsFormSteps.cases.json`.
    static func choiceStyle(_ input: CmsActionInputDef, themeInputs: CmsJSON?) -> String? {
        guard input.options != nil || input.optionsQuery != nil else { return nil }
        if let own = input.choiceStyle, choiceStyles.contains(own) { return own }
        if let site = themeInputs?.objectValue?.string("choiceStyle"), choiceStyles.contains(site) { return site }
        return nil
    }

    /// The empty row an optional choice offers, first in every style (an inline
    /// list's first row, so a choice made can be taken back): its
    /// `optionsQuery.emptyChoice` (the line a template the form fills), else
    /// "None". A required input offers none. The web's `emptyChoiceFor`, held to
    /// `cmsFormSteps.cases.json`.
    static func emptyChoice(_ input: CmsActionInputDef) -> CmsActionOptionsQuery.EmptyChoice? {
        guard !input.isRequired else { return nil }
        if let own = input.optionsQuery?.emptyChoice, !own.label.isEmpty { return own }
        return CmsActionOptionsQuery.EmptyChoice(label: "None", description: nil)
    }

    public enum Control: Equatable { case text, multiline, number, toggle, date, dateTime, choice, unsupported, list, duration, dates, time }

    /// What a control holds while the person edits.
    public enum Draft: Equatable {
        case text(String)
        case bool(Bool)
        case date(Date?)
        /// A list input's items (each keeping its own keys), and the items
        /// removed that came with the record.
        case list([[String: CmsJSON]], removed: [[String: CmsJSON]])
    }

    public struct Issue: Equatable {
        public var field: String
        public var message: String
    }

    public struct Validation: Equatable {
        /// The values in the contract's formats: dates `YYYY-MM-DD`,
        /// timestamps ISO 8601 with the zone offset, numbers as numbers.
        public var values: [String: CmsJSON]
        /// Required inputs still blank.
        public var missing: [String]
        public var errors: [Issue]
        public var ready: Bool { missing.isEmpty && errors.isEmpty }
    }

    public static func control(for input: CmsActionInputDef) -> Control {
        if input.type == "list" { return .list }
        // A set of days: its draft is the days joined with commas.
        if input.type == "dates" { return .dates }
        if input.type == "integer", ["seconds", "minutes"].contains(input.unit ?? "") { return .duration }
        if input.multiline == true, input.type == "string" { return .multiline }
        if input.optionsQuery != nil || (!(input.options?.choices.isEmpty ?? true) && input.type != "boolean") { return .choice }
        switch input.type {
        case "integer", "float": return .number
        case "boolean": return .toggle
        case "date": return .date
        case "timestamp": return .dateTime
        case "time": return .time
        case "json": return .multiline
        case "blob": return .unsupported
        default: return .text
        }
    }

    /// The mutation's declared inputs that neither its `paramSources` nor the
    /// button's `paramMap` supply. Empty without a contract: the mutation
    /// runs exactly as before.
    public static func askedInputs(_ mutation: CmsMutationDef?, paramMap: [String: CmsJSON]?) -> [CmsActionInputDef] {
        guard let inputs = mutation?.action?.inputs, !inputs.isEmpty else { return [] }
        let supplied = Set((mutation?.paramSources ?? [:]).keys).union((paramMap ?? [:]).keys)
        return inputs.filter { !supplied.contains($0.name) }
    }

    /// The draft a form opens with: each input's default; a required date or
    /// time starts at today or the next whole hour (a picker always shows a
    /// value), an optional one starts unset.
    public static func initialDraft(_ inputs: [CmsActionInputDef], now: Date = Date(),
                                    calendar: Calendar = .current) -> [String: Draft] {
        var draft: [String: Draft] = [:]
        for input in inputs {
            let text: String? = {
                switch input.defaultValue {
                case .string(let s): return s
                case .number(let n): return numberString(n)
                case .bool(let b): return b ? "true" : "false"
                default: return nil
                }
            }()
            switch control(for: input) {
            case .list:
                draft[input.name] = .list(input.defaultValue.map(listValue) ?? [], removed: [])
            case .dates:
                draft[input.name] = .text(CmsDateSets.value(itemField: input.itemField, input.defaultValue).joined(separator: ","))
            case .toggle:
                draft[input.name] = .bool(["true", "1", "yes"].contains((text ?? "").lowercased()))
            case .date:
                let parsed = text.flatMap { parseDate($0, calendar: calendar) }
                draft[input.name] = .date(parsed ?? (input.isRequired ? calendar.startOfDay(for: now) : nil))
            case .dateTime:
                let parsed = text.flatMap(parseTimestamp)
                draft[input.name] = .date(parsed ?? (input.isRequired ? nextHour(after: now, calendar: calendar) : nil))
            case .time:
                let parsed = text.flatMap { parseTime($0, on: now, calendar: calendar) }
                draft[input.name] = .date(parsed ?? (input.isRequired ? nextHour(after: now, calendar: calendar) : nil))
            default:
                draft[input.name] = .text(text ?? "")
            }
        }
        // A set of days with no value of its own whose range opens filled (a
        // required date starts today) starts with its default selection, as
        // it would once the range is chosen.
        for input in inputs where input.type == "dates" && input.defaultValue == nil {
            guard let range = input.range, case .date(let from?)? = draft[range.from], case .date(let to?)? = draft[range.to] else { continue }
            let days = CmsDateSets.forRange(defaultSelection: input.defaultSelection,
                                            .string(dateString(from, timeZone: calendar.timeZone)), .string(dateString(to, timeZone: calendar.timeZone)))
            draft[input.name] = .text(days.joined(separator: ","))
        }
        // A required end that opened by default starts after its start, as a
        // new event in Calendar ends an hour after it begins.
        for input in inputs where input.isRequired && input.defaultValue == nil {
            guard let rule = input.after, let start = inputs.first(where: { $0.name == rule.input }),
                  case .date(let from?)? = draft[start.name] else { continue }
            switch control(for: input) {
            case .dateTime:
                draft[input.name] = .date(calendar.date(byAdding: .hour, value: 1, to: from) ?? from)
            case .date:
                draft[input.name] = .date(earliest(after: from, control: .date, calendar: calendar))
            default:
                break
            }
        }
        return draft
    }

    // MARK: Formats

    /// `YYYY-MM-DD` for the day `date` falls on in `timeZone`.
    public static func dateString(_ date: Date, timeZone: TimeZone = .current) -> String {
        formatter("yyyy-MM-dd", timeZone).string(from: date)
    }

    /// ISO 8601 with the zone's offset at that moment, e.g.
    /// `2026-10-27T09:00:00+00:00`.
    public static func timestampString(_ date: Date, timeZone: TimeZone = .current) -> String {
        formatter("yyyy-MM-dd'T'HH:mm:ssxxx", timeZone).string(from: date)
    }

    static func parseDate(_ text: String, calendar: Calendar) -> Date? {
        guard isValidDate(text) else { return nil }
        let f = formatter("yyyy-MM-dd", calendar.timeZone)
        return f.date(from: text)
    }

    /// `HH:mm` (or a timestamp's time) as that time on `day`'s date.
    static func parseTime(_ text: String, on day: Date = Date(), calendar: Calendar = .current) -> Date? {
        let t = text.trimmingCharacters(in: .whitespaces)
        let hm: [Int]
        if t.count == 5, t[t.index(t.startIndex, offsetBy: 2)] == ":" {
            hm = t.split(separator: ":").compactMap { Int($0) }
        } else if let moment = parseTimestamp(t) {
            let c = calendar.dateComponents([.hour, .minute], from: moment)
            hm = [c.hour ?? 0, c.minute ?? 0]
        } else { return nil }
        guard hm.count == 2, (0..<24).contains(hm[0]), (0..<60).contains(hm[1]) else { return nil }
        return calendar.date(bySettingHour: hm[0], minute: hm[1], second: 0, of: day)
    }

    /// A time of day as `HH:mm` in `timeZone`.
    public static func timeString(_ date: Date, timeZone: TimeZone = .current) -> String {
        formatter("HH:mm", timeZone).string(from: date)
    }

    static func parseTimestamp(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: text)
    }

    private static func formatter(_ format: String, _ timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = format
        return f
    }

    private static func nextHour(after now: Date, calendar: Calendar) -> Date {
        let hour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        return calendar.date(byAdding: .hour, value: 1, to: hour) ?? now
    }

    /// A number as JavaScript's `String(n)` writes it: `5`, `7.5`.
    static func numberString(_ n: Double) -> String {
        if n.rounded() == n, abs(n) < 9_007_199_254_740_992 { return String(Int64(n)) }
        return String(n)
    }

    /// A date, timestamp or time as the contract writes it.
    static func wireMoment(_ d: Date, control: Control, timeZone: TimeZone) -> String {
        switch control {
        case .date: return dateString(d, timeZone: timeZone)
        case .time: return timeString(d, timeZone: timeZone)
        default: return timestampString(d, timeZone: timeZone)
        }
    }

    // MARK: Validation

    /// The draft in the contract's formats, judged by the shared rules. A blank
    /// required input is missing; a blank optional one is sent as null.
    public static func validate(_ inputs: [CmsActionInputDef], draft: [String: Draft],
                                timeZone: TimeZone = .current,
                                computedStates: [String: CmsFormEvalState]? = nil) -> Validation {
        var supplied: [String: CmsJSON] = [:]
        var missing: [String] = []
        var computedIssues: [Issue] = []
        // An input its `showWhen` keeps out is neither required nor sent.
        let hiddenNow = CmsFormSteps.hidden(inputs, values: showValues(inputs, draft: draft, timeZone: timeZone))
        for input in inputs where !hiddenNow.contains(input.name) {
            if let fromComputed = input.fromComputed, let st = computedStates?[fromComputed] {
                switch st {
                case .pending:
                    computedIssues.append(Issue(field: input.name, message: "\"\(input.displayLabel)\" is still being calculated."))
                    continue
                case .error(let msg):
                    computedIssues.append(Issue(field: input.name, message: "\"\(input.displayLabel)\" could not be calculated: \(msg)"))
                    continue
                case .value(let formVal):
                    if !formVal.isBlank {
                        if input.type == "integer", let n = formVal.number {
                            supplied[input.name] = .number(n.rounded())
                        } else if input.type == "float", let n = formVal.number {
                            supplied[input.name] = .number(n)
                        } else if let t = formVal.text {
                            supplied[input.name] = .string(t)
                        }
                    } else if input.isRequired {
                        missing.append(input.name)
                    } else {
                        supplied[input.name] = .null
                    }
                    continue
                }
            }
            let value: CmsJSON?
            switch draft[input.name] {
            case .bool(let b):
                value = .bool(b)
            case .date(let d):
                if let d { value = .string(wireMoment(d, control: control(for: input), timeZone: timeZone)) }
                else { value = nil }
            case .list(let items, let removed):
                value = items.isEmpty && removed.isEmpty && input.isRequired ? nil : listWire(input, items: items, removed: removed)
            case .text(let t) where control(for: input) == .dates:
                let days = CmsDateSets.value(itemField: nil, .string(t))
                value = days.isEmpty && input.isRequired ? nil : .array(days.map(CmsJSON.string))
            case .text(let t):
                let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { value = nil }
                else if [.number, .duration].contains(control(for: input)) {
                    let normal = trimmed.replacingOccurrences(of: ",", with: ".")
                    value = Double(normal).map(CmsJSON.number) ?? .string(t)
                } else { value = .string(t) }
            case .none:
                value = nil
            }
            if let value { supplied[input.name] = value }
            else if input.isRequired { missing.append(input.name) }
            else if control(for: input) == .toggle { supplied[input.name] = .bool(false) }
            else { supplied[input.name] = .null }
        }
        let checked = validateValues(inputs, supplied)
        return Validation(values: checked.values, missing: missing, errors: computedIssues + checked.errors)
    }

    /// The draft as `showWhen` reads it: text, toggles, dates as their text; a
    /// list reads as nothing. An input without a draft reads its default.
    public static func showValues(_ inputs: [CmsActionInputDef], draft: [String: Draft],
                                  timeZone: TimeZone = .current) -> [String: CmsJSON] {
        var out: [String: CmsJSON] = [:]
        for input in inputs {
            switch draft[input.name] {
            case .text(let t)?: out[input.name] = .string(t)
            case .bool(let b)?: out[input.name] = .bool(b)
            case .date(let d?)?:
                out[input.name] = .string(wireMoment(d, control: control(for: input), timeZone: timeZone))
            case .date(nil)?, .list?: break
            case nil: if let d = input.defaultValue { out[input.name] = d }
            }
        }
        return out
    }

    /// `validateActionValues` over supplied values: an input its `showWhen`
    /// keeps out is skipped; a required one with no value is missing.
    public static func check(_ inputs: [CmsActionInputDef], supplied: [String: CmsJSON]) -> Validation {
        var offered: [String: CmsJSON] = [:]
        for input in inputs { if let v = supplied[input.name] ?? input.defaultValue { offered[input.name] = v } }
        let hiddenNow = CmsFormSteps.hidden(inputs, values: offered)
        let shown = inputs.filter { !hiddenNow.contains($0.name) }
        var missing: [String] = []
        var given: [String: CmsJSON] = [:]
        for input in shown {
            if let v = offered[input.name] { given[input.name] = v } else if input.isRequired { missing.append(input.name) }
        }
        let checked = validateValues(shown, given)
        return Validation(values: checked.values, missing: missing, errors: checked.errors)
    }

    /// `validateActionValues` for values already in hand.
    static func validateValues(_ inputs: [CmsActionInputDef], _ supplied: [String: CmsJSON]) -> (values: [String: CmsJSON], errors: [Issue]) {
        var values: [String: CmsJSON] = [:]
        var errors: [Issue] = []
        for input in inputs {
            guard let raw = supplied[input.name] else { continue }
            let label = input.displayLabel
            if raw == .null { values[input.name] = .null; continue }
            if input.type == "list" {
                if case .array = raw { values[input.name] = raw }
                else { errors.append(Issue(field: input.name, message: "\(label) requires a list.")) }
                continue
            }
            if input.type == "dates" {
                if let issue = CmsDateSets.issue(input, raw, values: supplied) { errors.append(Issue(field: input.name, message: issue)) }
                else { values[input.name] = .array(CmsDateSets.value(itemField: input.itemField, raw).map(CmsJSON.string)) }
                continue
            }
            let text: String
            switch raw {
            case .string(let s): text = s
            case .number(let n): text = numberString(n)
            case .bool(let b): text = b ? "true" : "false"
            default:
                errors.append(Issue(field: input.name, message: "\(label) requires a \(input.type) value."))
                continue
            }
            var value = raw
            var invalid: String?
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch input.type {
            case "integer", "float":
                if let n = Double(trimmed), n.isFinite,
                   input.type == "float" || (n.rounded() == n && abs(n) <= 9_007_199_254_740_991) {
                    value = .number(n)
                } else {
                    invalid = "\(label) must be a valid \(input.type == "integer" ? "integer" : "number")."
                }
            case "boolean":
                let options = resolvedRules(input, supplied).options
                if options?.choices.contains(where: { $0.value == text }) == true { value = .string(text) }
                else if ["true", "1", "yes", "y"].contains(trimmed.lowercased()) { value = .bool(true) }
                else if ["false", "0", "no", "n"].contains(trimmed.lowercased()) { value = .bool(false) }
                else { invalid = "\(label) must be true or false." }
            case "date":
                if !isValidDate(text) { invalid = "\(label) must be a valid date (YYYY-MM-DD)." }
            case "time":
                if trimmed.range(of: #"^([01]\d|2[0-3]):[0-5]\d$"#, options: .regularExpression) == nil {
                    invalid = "\(label) must be a time of day (HH:mm)."
                }
            case "timestamp":
                if text.range(of: #"^\d{4}-\d{2}-\d{2}T.*(?:Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) == nil
                    || parseTimestamp(text) == nil {
                    invalid = "\(label) must include a date, time and timezone."
                }
            case "json":
                if (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)) == nil {
                    invalid = "\(label) must be valid JSON."
                }
            default:
                break
            }
            if let invalid { errors.append(Issue(field: input.name, message: invalid)) }
            else { values[input.name] = value }
        }
        for input in inputs {
            guard let value = values[input.name],
                  let message = columnError(input, value: value, row: values) else { continue }
            errors.append(Issue(field: input.name, message: message))
        }
        // Only between values that passed their own rules.
        let valid = values.filter { name, _ in !errors.contains { $0.field == name } }
        errors.append(contentsOf: orderIssues(inputs, valid))
        return (values, errors)
    }

    // MARK: Order (`after`, mirror of actionOrderIssues)

    /// A value as a number to order by: a date as its UTC midnight, a timestamp
    /// as its instant, a number as itself. Nil for anything else.
    static func orderKey(type: String, _ value: CmsJSON?) -> Double? {
        switch (type, value) {
        case ("integer", .number(let n)?), ("float", .number(let n)?):
            return n.isFinite ? n : nil
        case ("integer", .string(let s)?), ("float", .string(let s)?):
            return Double(s.trimmingCharacters(in: .whitespaces)).flatMap { $0.isFinite ? $0 : nil }
        case ("date", .string(let s)?):
            guard isValidDate(s) else { return nil }
            return formatter("yyyy-MM-dd", TimeZone(identifier: "UTC")!).date(from: s)?.timeIntervalSince1970
        case ("timestamp", .string(let s)?):
            return parseTimestamp(s)?.timeIntervalSince1970
        case ("time", .string(let s)?):
            // A time of day: its minutes since midnight.
            guard s.range(of: #"^([01]\d|2[0-3]):[0-5]\d$"#, options: .regularExpression) != nil else { return nil }
            return Double(Int(s.prefix(2))! * 60 + Int(s.suffix(2))!)
        default:
            return nil
        }
    }

    /// Each input that must come after another and does not. Values not given,
    /// or not readable as their type, are left to the other rules.
    public static func orderIssues(_ inputs: [CmsActionInputDef], _ values: [String: CmsJSON]) -> [Issue] {
        inputs.compactMap { input in
            guard let rule = input.after, !rule.input.isEmpty,
                  let other = inputs.first(where: { $0.name == rule.input }),
                  let later = orderKey(type: input.type, values[input.name]),
                  let earlier = orderKey(type: other.type, values[other.name]),
                  later <= earlier else { return nil }
            let message = (rule.message?.isEmpty == false ? rule.message : nil)
                ?? "\(input.label?.isEmpty == false ? input.label! : input.name) must be after \(other.label?.isEmpty == false ? other.label! : other.name)."
            return Issue(field: input.name, message: message)
        }
    }

    /// The earliest a later date or time may be, given its earlier one: a
    /// minute after a time, a day after a date.
    public static func earliest(after start: Date, control: Control, calendar: Calendar = .current) -> Date {
        control == .date
            ? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: start)) ?? start
            : start.addingTimeInterval(60)
    }

    static func isValidDate(_ text: String) -> Bool {
        guard text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return false }
        let utc = TimeZone(identifier: "UTC")!
        guard let d = formatter("yyyy-MM-dd", utc).date(from: text) else { return false }
        return formatter("yyyy-MM-dd", utc).string(from: d) == text
    }

    /// `resolveColumnRules`: a conditional case chosen by a sibling's value.
    static func resolvedRules(_ input: CmsActionInputDef, _ row: [String: CmsJSON]) -> (options: CmsColumnOptions?, validation: CmsColumnValidation?) {
        guard let cond = input.conditional, !cond.cases.isEmpty else { return (input.options, input.validation) }
        let key: String = {
            switch row[cond.on] {
            case .none, .some(.null): return ""
            case .some(.string(let s)): return s
            case .some(.number(let n)): return numberString(n)
            case .some(.bool(let b)): return b ? "true" : "false"
            case .some(let other): return other.displayString
            }
        }()
        guard let hit = cond.cases.first(where: { $0.in.contains(key) }) else { return (input.options, input.validation) }
        return (hit.options ?? input.options, hit.validation ?? input.validation)
    }

    /// `validateColumnValue`. Choices from a query are offered, never
    /// enforced: only the backend knows which values it accepts.
    static func columnError(_ input: CmsActionInputDef, value: CmsJSON, row: [String: CmsJSON]) -> String? {
        let name = input.label ?? input.name
        let s: String
        switch value {
        case .null: return nil
        case .string(let t): s = t
        case .number(let n): s = numberString(n)
        case .bool(let b): s = b ? "true" : "false"
        default: s = value.displayString
        }
        if s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        var (options, validation) = resolvedRules(input, row)
        if input.optionsQuery != nil { options = nil }
        if let options, options.strict, !options.choices.isEmpty, !options.choices.contains(where: { $0.value == s }) {
            let labels = options.choices.map { ($0.label?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? $0.value }
            return validation?.message ?? "\(name) must be one of: \(labels.joined(separator: ", "))."
        }
        guard let v = validation else { return nil }
        if let format = v.format, let rule = formatRules[format], s.range(of: rule.pattern, options: rule.options) == nil {
            return v.message ?? "\(name) must be \(rule.expects)."
        }
        if let pattern = v.pattern, let re = try? NSRegularExpression(pattern: pattern),
           re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) == nil {
            return v.message ?? "\(name) is not in the required format."
        }
        // JavaScript counts UTF-16 code units.
        if let minLength = v.minLength, s.utf16.count < minLength { return v.message ?? "\(name) must be at least \(minLength) characters." }
        if let maxLength = v.maxLength, s.utf16.count > maxLength { return v.message ?? "\(name) must be at most \(maxLength) characters." }
        if v.min != nil || v.max != nil, let n = Double(s), n.isFinite {
            if let min = v.min, n < min { return v.message ?? "\(name) must be at least \(numberString(min))." }
            if let max = v.max, n > max { return v.message ?? "\(name) must be at most \(numberString(max))." }
        }
        return nil
    }

    private static let formatRules: [String: (pattern: String, options: String.CompareOptions, expects: String)] = [
        "email": (#"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, .regularExpression, "a valid email address"),
        "url": (#"^https?://\S+$"#, [.regularExpression, .caseInsensitive], "a valid URL (https://…)"),
        "phone": (#"^[+]?[\d\s().-]{7,}$"#, .regularExpression, "a valid phone number"),
        "uuid": (#"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#, [.regularExpression, .caseInsensitive], "a valid UUID"),
    ]

    // MARK: Params

    /// The values as typed mutation params, as `actionTypedParams` writes them:
    /// `{ value: String | null, type }`.
    public static func typedParams(_ inputs: [CmsActionInputDef], values: [String: CmsJSON]) -> [String: CmsJSON] {
        var out: [String: CmsJSON] = [:]
        for (name, value) in values {
            let input = inputs.first { $0.name == name }
            var type = input?.type ?? "string"
            if type == "boolean", case .string(let s) = value,
               let input, resolvedRules(input, values).options?.choices.contains(where: { $0.value == s }) == true {
                type = "string"
            }
            if !["integer", "float", "boolean", "date", "timestamp"].contains(type) { type = "string" }
            let wire: CmsJSON
            switch value {
            case .null: wire = .null
            case .string(let s): wire = .string(s)
            case .number(let n): wire = .string(numberString(n))
            case .bool(let b): wire = .string(b ? "true" : "false")
            case .array, .object:
                // A list goes as its JSON text, as a json input does.
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let data = (try? encoder.encode(value)) ?? Data("[]".utf8)
                wire = .string(String(decoding: data, as: UTF8.self))
            default: wire = .string(value.displayString)
            }
            out[name] = .object(["value": wire, "type": .string(type)])
        }
        return out
    }

    /// Choices a query's rows offer: distinct non-blank values, labelled by
    /// `labelColumn` when it is named and present.
    public static func options(from rows: [[String: CmsJSON]], query: CmsActionOptionsQuery) -> [(value: String, label: String)] {
        var seen = Set<String>()
        var out: [(value: String, label: String)] = []
        for row in rows {
            guard let raw = row[query.valueColumn], raw != .null else { continue }
            let value = raw.displayString
            guard !value.isEmpty, seen.insert(value).inserted else { continue }
            var label = value
            if let column = query.labelColumn, let l = row[column], l != .null, !l.displayString.isEmpty { label = l.displayString }
            out.append((value, label))
        }
        return out
    }
}
