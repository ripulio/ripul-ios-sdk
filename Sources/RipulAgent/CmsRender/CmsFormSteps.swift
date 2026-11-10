import Foundation

/// A record form shown one step at a time, inputs shown only when another
/// holds a value, choices that wait on other inputs and choices a person can
/// add to. The web's rules (`packages/shared-types/src/cmsFormSteps.ts` and
/// `cmsActions.ts`), held to the same cases (`cmsFormSteps.cases.json`,
/// `CmsFormStepsTests`). docs/plans/cms-add-job.md; docs/cms-record-form.md.

/// `showWhen`: while `input` has one of `in`'s values (compared as text, a
/// toggle as "true" or "false"), or with `filled`, while it has a value or none.
public struct CmsShowWhen: Codable, Equatable {
    public var input: String
    public var `in`: [String]?
    public var filled: Bool?

    public init(input: String, in values: [String]? = nil, filled: Bool? = nil) {
        self.input = input; self.in = values; self.filled = filled
    }

    private enum CodingKeys: String, CodingKey { case input, `in`, filled }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        input = try c.decode(String.self, forKey: .input)
        // Values compare as text: a number listed in `in` is its text.
        if let raw = try? c.decodeIfPresent([CmsJSON].self, forKey: .in) {
            self.in = raw.map { CmsFormSteps.text($0) }
        }
        filled = try? c.decodeIfPresent(Bool.self, forKey: .filled)
    }
}

/// `optionsQuery.create`: a searched text that matches no choice runs
/// `mutationSlug` with it as `input`, then chooses the value at `valuePath`
/// of the run's result.
public struct CmsOptionsCreate: Codable, Equatable {
    public var mutationSlug: String
    public var input: String
    public var valuePath: String
    public var labelPath: String?
    public var label: String?
}

/// One step of `form.steps`.
public struct CmsFormStep: Equatable {
    /// The progress line, a short name for the step.
    public var title: String?
    /// The step's question, big.
    public var question: String?
    public var description: String?
    public var sections: [CmsFormDef.Section]
    /// The step's button; "Continue" when unset.
    public var nextLabel: String?
    public var showWhen: CmsShowWhen?
}

public enum CmsFormSteps {
    /// What `optionsQuery.whenOne: 'pick'` does with the choices as they
    /// stand (the web's `whenOneOutcome`, held to `cmsFormSteps.cases.json`):
    /// hidden while loading or waiting; none hides and clears (`value` is
    /// `.some(nil)`); one hides and picks it; several, or an error, show.
    /// `value` nil leaves the input as it is.
    public struct WhenOne: Equatable {
        public var hide: Bool
        public var value: String??
    }

    public enum ChoiceRows: Equatable {
        case loading
        case error
        case rows([[String: CmsJSON]])
    }

    public static func whenOne(_ query: CmsActionOptionsQuery?, _ rows: ChoiceRows) -> WhenOne {
        if query?.whenOne != "pick", query?.whenNone == "hide" {
            switch rows {
            case .loading: return WhenOne(hide: true, value: nil)
            case .error: return WhenOne(hide: false, value: nil)
            case .rows(let list): return list.isEmpty ? WhenOne(hide: true, value: .some(nil)) : WhenOne(hide: false, value: nil)
            }
        }
        guard query?.whenOne == "pick", let query else { return WhenOne(hide: false, value: nil) }
        switch rows {
        case .loading: return WhenOne(hide: true, value: nil)
        case .error: return WhenOne(hide: false, value: nil)
        case .rows(let list):
            if list.isEmpty { return WhenOne(hide: true, value: .some(nil)) }
            if list.count == 1 {
                let v = list[0][query.valueColumn]
                if v == nil || v == .null { return WhenOne(hide: true, value: .some(nil)) }
                return WhenOne(hide: true, value: .some(CmsCards.text(v)))
            }
            return WhenOne(hide: false, value: nil)
        }
    }

    public static func choiceRows(_ state: CmsRuntime.QueryState?) -> ChoiceRows {
        switch state {
        case .ok(let result)?: return .rows(result.rows)
        case .error?: return .error
        default: return .loading
        }
    }

    // MARK: showWhen

    /// A value as `showWhen` compares it: text, a toggle as "true" or "false", blank as "".
    static func text(_ value: CmsJSON?) -> String {
        switch value {
        case nil, .null?: return ""
        case .bool(let b)?: return b ? "true" : "false"
        case .number(let n)?: return CmsActionForm.numberString(n)
        case .string(let s)?: return s.trimmingCharacters(in: .whitespacesAndNewlines)
        case let other?: return CmsCards.text(other).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Whether a rule holds for a value of the input it names.
    public static func holds(_ rule: CmsShowWhen?, _ value: CmsJSON?) -> Bool {
        guard let rule else { return true }
        let t = text(value)
        if let values = rule.in, !values.contains(t) { return false }
        if rule.filled == true, t.isEmpty { return false }
        if rule.filled == false, !t.isEmpty { return false }
        return true
    }

    /// The inputs a `showWhen` keeps out, following the chain: an input that
    /// depends on one not shown is not shown either. A loop leaves it shown.
    public static func hidden(_ inputs: [CmsActionInputDef], values: [String: CmsJSON]) -> Set<String> {
        let byName = Dictionary(inputs.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var memo: [String: Bool] = [:]
        func isHidden(_ name: String, _ seen: inout Set<String>) -> Bool {
            if let known = memo[name] { return known }
            guard let input = byName[name], let rule = input.showWhen else { memo[name] = false; return false }
            if seen.contains(name) { return false }
            seen.insert(name)
            let out = (byName[rule.input] != nil && isHidden(rule.input, &seen)) || !holds(rule, values[rule.input])
            memo[name] = out
            return out
        }
        return Set(inputs.filter { var seen = Set<String>(); return isHidden($0.name, &seen) }.map(\.name))
    }

    // MARK: Steps

    /// The form's steps: its own, or the whole form as one step.
    public static func steps(_ form: CmsFormDef?) -> [CmsFormStep] {
        if let steps = form?.steps, !steps.isEmpty { return steps }
        return [CmsFormStep(sections: form?.sections ?? [])]
    }

    /// The input names a step lays out, in order: items, rows, summary lines' inputs.
    public static func inputNames(_ step: CmsFormStep) -> [String] {
        var out: [String] = []
        func add(_ name: String?) { if let name, !out.contains(name) { out.append(name) } }
        for section in step.sections {
            for item in section.items {
                switch item {
                case .input(let n): add(n)
                case .row(let names): names.forEach(add)
                case .summary(let lines, _): lines.forEach { add($0.input) }
                }
            }
        }
        return out
    }

    public struct VisibleStep: Equatable {
        /// The step's place in `form.steps`.
        public var index: Int
        public var step: CmsFormStep
        /// The inputs it asks for now.
        public var inputs: [String]
    }

    /// The steps to show for these values, each with the inputs it asks for:
    /// laid out (or left over, on the last step shown), not hidden, not
    /// computed, not fixed and not kept out by a `showWhen`.
    public static func visible(_ inputs: [CmsActionInputDef], form: CmsFormDef?, values: [String: CmsJSON],
                               fixed: Set<String> = []) -> [VisibleStep] {
        let hiddenNow = hidden(inputs, values: values)
        let known = Set(inputs.map(\.name))
        func asked(_ name: String) -> Bool {
            guard let input = inputs.first(where: { $0.name == name }) else { return false }
            return input.hidden != true && input.fromComputed == nil && !fixed.contains(name) && !hiddenNow.contains(name)
        }
        let all = steps(form)
        let placed = Set(all.flatMap(inputNames))
        var out: [VisibleStep] = []
        for (index, step) in all.enumerated() {
            if let rule = step.showWhen,
               (known.contains(rule.input) && hiddenNow.contains(rule.input)) || !holds(rule, values[rule.input]) { continue }
            out.append(VisibleStep(index: index, step: step, inputs: inputNames(step).filter(asked)))
        }
        let rest = inputs.map(\.name).filter { !placed.contains($0) && asked($0) }
        if !out.isEmpty, !rest.isEmpty { out[out.count - 1].inputs += rest }
        else if out.isEmpty, !rest.isEmpty { out.append(VisibleStep(index: all.count, step: CmsFormStep(sections: []), inputs: rest)) }
        return out
    }

    /// "Step 2 of 4", and the bar's fraction.
    public static func progress(_ position: Int, of count: Int) -> (fraction: Double, text: String) {
        let n = max(1, count)
        let at = min(max(1, position), n)
        return (Double(at) / Double(n), "Step \(at) of \(n)")
    }

    // MARK: Choices that wait on other inputs

    private static let slot = try! NSRegularExpression(pattern: #"\{([a-zA-Z_]\w*)\}"#)

    private static func isBlank(_ v: CmsJSON?) -> Bool {
        switch v {
        case nil, .null?: return true
        case .string(let s)?: return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default: return false
        }
    }

    /// A template over the form's values; a one-slot template keeps the value's type.
    public static func fill(_ template: String, values: [String: CmsJSON]) -> (value: CmsJSON, missing: [String]) {
        let ns = template as NSString
        let matches = slot.matches(in: template, range: NSRange(location: 0, length: ns.length))
        if matches.count == 1, matches[0].range == NSRange(location: 0, length: ns.length) {
            let name = ns.substring(with: matches[0].range(at: 1))
            let v = values[name]
            return isBlank(v) ? (.null, [name]) : (v!, [])
        }
        var missing: [String] = []
        var out = ""
        var at = 0
        for m in matches {
            out += ns.substring(with: NSRange(location: at, length: m.range.location - at))
            let name = ns.substring(with: m.range(at: 1))
            let v = values[name]
            if isBlank(v) { if !missing.contains(name) { missing.append(name) } }
            else { out += CmsCards.text(v!) }
            at = m.range.location + m.range.length
        }
        out += ns.substring(from: at)
        return (.string(out), missing)
    }

    public enum OptionsParams: Equatable {
        case ready([String: CmsJSON])
        case waiting([String])
    }

    /// A choice list's query params for these values, or the inputs it waits on.
    public static func optionsParams(_ params: [String: String]?, values: [String: CmsJSON]) -> OptionsParams {
        var out: [String: CmsJSON] = [:]
        var waiting: [String] = []
        for (name, template) in (params ?? [:]).sorted(by: { $0.key < $1.key }) {
            let filled = fill(template, values: values)
            if filled.missing.isEmpty { out[name] = filled.value }
            else { filled.missing.forEach { if !waiting.contains($0) { waiting.append($0) } } }
        }
        return waiting.isEmpty ? .ready(out) : .waiting(waiting)
    }

    /// The inputs a list's params name: changing one clears its choice.
    public static func dependsOn(_ params: [String: String]?) -> [String] {
        var out: [String] = []
        for (_, template) in (params ?? [:]).sorted(by: { $0.key < $1.key }) {
            let ns = template as NSString
            for m in slot.matches(in: template, range: NSRange(location: 0, length: ns.length)) {
                let name = ns.substring(with: m.range(at: 1))
                if !out.contains(name) { out.append(name) }
            }
        }
        return out
    }

    // MARK: Choices a person adds to

    /// The "Add …" row's text.
    public static func createLabel(_ create: CmsOptionsCreate, text: String) -> String {
        let template = (create.label?.isEmpty == false ? create.label! : "Add \"{text}\"")
        return template.replacingOccurrences(of: "{text}", with: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Whether a searched text offers "Add …": not blank, and no choice is labelled it.
    public static func offersCreate(_ text: String, labels: [String]) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !t.isEmpty && !labels.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == t }
    }

    /// The create mutation's params: the list's own, then the text as `input`.
    public static func createParams(_ create: CmsOptionsCreate, listParams: [String: CmsJSON], text: String) -> [String: CmsJSON] {
        var out = listParams
        out[create.input] = .string(text.trimmingCharacters(in: .whitespacesAndNewlines))
        return out
    }

    /// The chosen value and label from the create run's result, or nil.
    public static func createdChoice(_ create: CmsOptionsCreate, result: CmsJSON?, text: String) -> (value: String, label: String)? {
        func scalar(_ v: CmsJSON?) -> String? {
            switch v {
            case .string(let s)?: return s.isEmpty ? nil : s
            case .number(let n)?: return CmsActionForm.numberString(n)
            case .bool(let b)?: return b ? "true" : "false"
            default: return nil
            }
        }
        guard let value = scalar(readPath(result, create.valuePath)) else { return nil }
        let label = create.labelPath.flatMap { scalar(readPath(result, $0)) }
        return (value, label ?? text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `readResultPath`: a dotted path into an object.
    static func readPath(_ value: CmsJSON?, _ path: String) -> CmsJSON? {
        var cur = value
        for seg in path.split(separator: ".", omittingEmptySubsequences: false).map(String.init) {
            guard let o = cur?.objectValue, let next = o[seg] else { return nil }
            cur = next
        }
        return cur
    }
}
