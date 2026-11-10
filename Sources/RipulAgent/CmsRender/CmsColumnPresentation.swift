import SwiftUI

// MARK: - A column's own presentation (columnDef.ts, agGridStyleRules.ts)
//
// What a grid column says about how its value looks, wherever it is drawn:
// its transform and format, its style rules (colours, words and an icon by
// value), its chip (`lozenge`) and its picture (`image`, an address or an
// image chain). Twins of the web's evaluators, decoded leniently: a bad rule
// drops itself.

/// A style rule's condition (`StyleCondition`).
enum CmsStyleCondition: Equatable {
    case compare(op: String, value: CmsJSON, valueFrom: String?)
    case between(min: Double, max: Double, negated: Bool)
    case member(values: [CmsJSON], negated: Bool)
    case isNull
    case isNotNull

    init?(_ json: CmsJSON?) {
        guard let o = json?.objectValue, let op = o.string("op") else { return nil }
        switch op {
        case "<", "<=", ">", ">=", "==", "!=":
            self = .compare(op: op, value: o["value"] ?? .null, valueFrom: o.string("valueFrom"))
        case "between", "notBetween":
            guard let min = o["min"]?.doubleValue, let max = o["max"]?.doubleValue else { return nil }
            self = .between(min: min, max: max, negated: op == "notBetween")
        case "in", "notIn":
            self = .member(values: o["values"]?.arrayValue ?? [], negated: op == "notIn")
        case "isNull": self = .isNull
        case "isNotNull": self = .isNotNull
        default: return nil
        }
    }

    /// Twin of `evaluateCondition`: loose equality, numbers for ranges.
    func holds(_ value: CmsJSON?, row: [String: CmsJSON]) -> Bool {
        let isNull = value == nil || value == .null
        switch self {
        case .isNull: return isNull
        case .isNotNull: return !isNull
        case .member(let values, let negated):
            let found = values.contains { CmsStyleCondition.looseEqual($0, value) }
            return negated ? !found : found
        case .between(let min, let max, let negated):
            guard let n = CmsStyleCondition.number(value) else { return false }
            let inside = n >= min && n <= max
            return negated ? !inside : inside
        case .compare(let op, var target, let valueFrom):
            if let valueFrom {
                let other = CmsColumnPresentation.field(row, valueFrom)
                if other == nil || other == .null || other?.displayString == "" { return false }
                target = other!
            }
            switch op {
            case "==": return CmsStyleCondition.looseEqual(value, target)
            case "!=": return !CmsStyleCondition.looseEqual(value, target)
            default:
                guard let n = CmsStyleCondition.number(value), let t = CmsStyleCondition.number(target) else { return false }
                switch op {
                case "<": return n < t
                case "<=": return n <= t
                case ">": return n > t
                default: return n >= t
                }
            }
        }
    }

    static func number(_ v: CmsJSON?) -> Double? {
        switch v {
        case .number(let n)?: return n.isFinite ? n : nil
        case .string(let s)?:
            let t = s.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : Double(t)
        case .bool(let b)?: return b ? 1 : 0
        default: return nil
        }
    }

    /// JavaScript's `==` for the scalars a rule compares: numbers against
    /// numeric strings, null only with null.
    static func looseEqual(_ a: CmsJSON?, _ b: CmsJSON?) -> Bool {
        let aNull = a == nil || a == .null, bNull = b == nil || b == .null
        if aNull || bNull { return aNull && bNull }
        if let x = number(a), let y = number(b), isNumeric(a) || isNumeric(b) { return x == y }
        return a!.displayString == b!.displayString
    }

    private static func isNumeric(_ v: CmsJSON?) -> Bool {
        if case .number? = v { return true }
        if case .bool? = v { return true }
        return false
    }
}

/// One style rule (`StyleRule`): a condition, maybe on another column, and its effect.
struct CmsStyleRule: Equatable {
    var when: CmsStyleCondition
    var column: String?
    var also: [(column: String?, when: CmsStyleCondition)]
    var bg: String?
    var fg: String?
    var bold: Bool
    var rowWide: Bool
    var text: String?
    var icon: String?

    static func == (a: CmsStyleRule, b: CmsStyleRule) -> Bool {
        a.when == b.when && a.column == b.column && a.bg == b.bg && a.fg == b.fg && a.text == b.text
            && a.icon == b.icon && a.bold == b.bold && a.rowWide == b.rowWide && a.also.count == b.also.count
    }

    init?(_ json: CmsJSON) {
        guard let o = json.objectValue, let when = CmsStyleCondition(o["when"]) else { return nil }
        let style = o.object("style") ?? [:]
        self.when = when
        column = o.string("column")
        also = (o["also"]?.arrayValue ?? []).compactMap { entry in
            guard let e = entry.objectValue, let c = CmsStyleCondition(e["when"]) else { return nil }
            return (e.string("column"), c)
        }
        bg = style.string("bg")
        fg = style.string("fg")
        bold = style.bool("bold") ?? false
        rowWide = style.bool("rowWide") ?? false
        text = style.string("text").flatMap { $0.isEmpty ? nil : $0 }
        icon = style.string("icon").flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Twin of `ruleHolds`.
    func holds(_ value: CmsJSON?, row: [String: CmsJSON]) -> Bool {
        let tested = column.map { CmsColumnPresentation.field(row, $0) } ?? value
        guard when.holds(tested, row: row) else { return false }
        return also.allSatisfy { c in
            c.when.holds(c.column.map { CmsColumnPresentation.field(row, $0) } ?? value, row: row)
        }
    }
}

/// A column's presentation, decoded from its definition.
struct CmsColumnPresentation {
    var key: String
    var valueFrom: String
    var format: String?
    var transform: String?
    var styleRules: [CmsStyleRule]
    /// `lozenge`: present = the value draws as a chip.
    var lozenge: Lozenge?
    /// `image`: present = the value draws as a picture.
    var image: Picture?
    /// `timezone: "local"`: a naive datetime is local time; else UTC (the web's grid).
    var naiveIsLocal: Bool

    struct Lozenge: Equatable {
        var bg: String?
        var fg: String?
        /// `filled` | `outlined` | `tinted`; nil = the list style's default.
        var variant: String?
        var icon: String?
    }

    struct Picture: Equatable {
        var shape: String?
        /// The calendar's image chain; empty = the value is the picture's address.
        var chain: [CmsCalendarDecorations.ImageEntry]
    }

    init(key: String, valueFrom: String? = nil, json: [String: CmsJSON]?) {
        let o = json ?? [:]
        self.key = key
        self.valueFrom = valueFrom ?? o.string("valueFrom") ?? key
        format = o.string("format").flatMap { $0.isEmpty ? nil : $0 }
        transform = o.string("transform").flatMap { $0.isEmpty ? nil : $0 }
        styleRules = (o["styleRules"]?.arrayValue ?? []).compactMap(CmsStyleRule.init)
        naiveIsLocal = o.string("timezone") == "local"
        lozenge = o.object("lozenge").map { l in
            Lozenge(bg: l.string("bg"), fg: l.string("fg"),
                    variant: l.string("variant").flatMap { ["filled", "outlined", "tinted"].contains($0) ? $0 : nil },
                    icon: l.string("icon").flatMap { $0.isEmpty ? nil : $0 })
        }
        image = o.object("image").map { i in
            Picture(shape: i.string("shape"), chain: CmsCalendarDecorations.imageChain(i["chain"]))
        }
    }

    /// A row's field, by key or dotted path (`readField`).
    static func field(_ row: [String: CmsJSON], _ path: String) -> CmsJSON? {
        if let v = row[path] { return v }
        guard path.contains(".") else { return nil }
        var current: CmsJSON? = .object(row)
        for part in path.split(separator: ".") {
            current = current?.objectValue?[String(part)]
        }
        return current
    }

    func value(_ row: [String: CmsJSON]) -> CmsJSON? { Self.field(row, valueFrom) }

    /// The first rule that holds for this row, not row-wide, and sets `keyPath`.
    private func rule<T>(_ row: [String: CmsJSON], _ keyPath: KeyPath<CmsStyleRule, T?>) -> T? {
        let v = value(row)
        for r in styleRules where !r.rowWide {
            if let found = r[keyPath: keyPath], r.holds(v, row: row) { return found }
        }
        return nil
    }

    /// The value as words: a matching rule's `text` ({column} filled), else
    /// the value through the column's transform and format. Empty for none.
    func text(_ row: [String: CmsJSON]) -> String {
        if let words = rule(row, \.text) { return Self.fillRuleText(words, row: row) }
        return plainText(row)
    }

    /// The value through the column's transform and format, no rule words.
    func plainText(_ row: [String: CmsJSON]) -> String {
        guard let v = value(row), v != .null else { return "" }
        let raw = v.displayString
        guard !raw.isEmpty else { return "" }
        let transformed = transform.map { CmsFormatValue.applyTransform(raw, transform: $0) } ?? raw
        return format.map { CmsFormatValue.apply(transformed, pattern: $0) } ?? transformed
    }

    /// Twin of `fillRuleText`: {column} and {column|distance} from the row.
    static func fillRuleText(_ text: String, row: [String: CmsJSON]) -> String {
        let pattern = #"\{([\w.]+)(?:\|(\w+))?\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var out = ""
        var last = text.startIndex
        for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(m.range, in: text), let col = Range(m.range(at: 1), in: text) else { continue }
            out += text[last..<whole.lowerBound]
            let v = field(row, String(text[col]))
            if let f = Range(m.range(at: 2), in: text), text[f] == "distance" {
                if let metres = CmsStyleCondition.number(v) {
                    out += metres < 1000 ? "\(Int(metres.rounded())) m" : String(format: "%.1f km", metres / 1000)
                }
            } else if let v, v != .null {
                out += v.displayString
            }
            last = whole.upperBound
        }
        out += text[last...]
        return out
    }

    /// The first rule that holds for this row and isn't row-wide, whatever
    /// it sets (the web's `matchRuleEffect`): later rules are never read.
    func matchingRule(_ row: [String: CmsJSON]) -> CmsStyleRule? {
        let v = value(row)
        return styleRules.first { !$0.rowWide && $0.holds(v, row: row) }
    }

    /// A chip for this row, when it has words. Twin of the web's `chipLook`:
    /// everything comes from the one matching rule. Its `text`, else the value;
    /// its `icon`, else the lozenge's; its colours as a pair when it sets
    /// either (an unset one stays unset), else the lozenge's pair.
    func chip(_ row: [String: CmsJSON]) -> Chip? {
        let matched = matchingRule(row)
        let words = matched?.text.map { Self.fillRuleText($0, row: row) } ?? plainText(row)
        guard !words.isEmpty else { return nil }
        let ruleColours = matched.map { $0.fg != nil || $0.bg != nil } ?? false
        return Chip(text: words,
                    icon: matched?.icon ?? lozenge?.icon,
                    fg: ruleColours ? matched?.fg : lozenge?.fg,
                    bg: ruleColours ? matched?.bg : lozenge?.bg,
                    variant: lozenge?.variant)
    }

    /// What a row's picture loads, in order: the chain, else the value as an address.
    func pictureCandidates(_ row: [String: CmsJSON]) -> [CmsCalendarDecorations.ImageCandidate] {
        guard let image else { return [] }
        if !image.chain.isEmpty { return CmsCalendarDecorations.imageCandidates(row, image.chain) }
        guard let address = value(row)?.stringValue?.trimmingCharacters(in: .whitespaces),
              address.lowercased().hasPrefix("https://") else { return [] }
        return [.url(address)]
    }

    struct Chip: Equatable {
        var text: String
        var icon: String?
        /// CSS colours or `color.*` tokens, from a rule or the lozenge; nil = the style's colour.
        var fg: String?
        var bg: String?
        var variant: String?
    }
}
