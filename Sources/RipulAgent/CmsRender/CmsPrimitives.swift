import Foundation

// MARK: - Primitives: the resolver (docs/plans/cms-native-primitives.md)
//
// General-purpose layout and content nodes a site composes into a card's
// interior (`card.layout`) or a `layout` block. A tree is resolved here, once:
// `when` applied, `repeat` expanded into its parent, `{column}` slots and
// expressions filled, tokens turned into points, and a node this renderer
// can't draw replaced by its `fallback` (or left out). CmsPrimitiveView then
// draws the resolved tree onto SwiftUI stacks and grids.
//
// Twin of `packages/shared-types/src/cmsPrimitives.ts`; both test against
// `cmsPrimitives.cases.json`. Change the rules there and here together.

/// One node as drawn: `when` held, slots filled, tokens in points, fallbacks taken.
public struct CmsPrimitive: Equatable, Identifiable {
    public enum Size: Equatable {
        case fill, fit
        case points(Double)
    }

    public struct Insets: Equatable {
        public var top: Double, trailing: Double, bottom: Double, leading: Double
    }

    public var kind: String
    /// Unique in the tree: the path of ids or places, a repeated row's key in brackets.
    public var key: String
    public var id: String { key }
    public var width: Size
    public var height: Size
    public var padding: Insets?
    public var background: CmsPaletteRole?
    public var border: CmsPaletteRole?
    public var radius: Double?
    public var place: String?
    public var tap: CmsJSON?
    public var longPress: CmsJSON?
    public var label: String?
    public var hidden = false
    public var testId: String?
    /// The row this node reads (a tap's inputs fill from it).
    public var row: [String: CmsJSON]?
    public var children: [CmsPrimitive]?
    // Containers
    public var gap: Double?
    public var align: String?
    public var columns: Int?
    public var minWidth: Double?
    public var paging = false
    public var stackAtLargeText = false
    public var min: Double?
    // Content
    public var text: String?
    public var style: String?
    public var color: CmsPaletteRole?
    public var weight: String?
    public var lines: Int?
    public var src: String?
    public var chain: [CmsJSON]?
    public var fit: String?
    public var aspect: Double?
    public var shape: String?
    public var template = false
    public var name: String?
    public var sf: String?
    public var material: String?
    public var size: Double?
    public var fill: CmsPaletteRole?
    public var look: String?

    init(kind: String, key: String, width: Size, height: Size) {
        self.kind = kind
        self.key = key
        self.width = width
        self.height = height
    }
}

/// A query's rows as the renderer has them.
public enum CmsPrimitiveRows {
    case loading
    case error
    case ready([[String: CmsJSON]])
}

public enum CmsPrimitives {
    // MARK: Tokens

    public static let space: [String: Double] = ["none": 0, "xxs": 2, "xs": 4, "sm": 8, "md": 12, "lg": 16, "xl": 24, "xxl": 32]
    /// `full` is a capsule.
    public static let radii: [String: Double] = ["none": 0, "sm": 6, "md": 10, "lg": 16, "xl": 24, "full": 9999]
    /// Dynamic Type's names, with the size each has at the default text size
    /// (the web's table). iPhone scales each relative to its own style.
    public static let textStyles: [String: Double] = [
        "largeTitle": 34, "title": 28, "title2": 22, "title3": 20, "headline": 17, "body": 17,
        "callout": 16, "subheadline": 15, "footnote": 13, "caption": 12, "caption2": 11,
    ]
    public static let weights = ["regular", "medium", "semibold", "bold"]
    public static let places = ["topLeading", "top", "topTrailing", "leading", "center", "trailing", "bottomLeading", "bottom", "bottomTrailing"]

    public static let kinds = ["stack", "row", "grid", "overlay", "scroll", "spacer",
                               "text", "image", "icon", "shape", "badge", "divider", "repeat"]
    static let containers: Set<String> = ["stack", "row", "grid", "overlay", "scroll"]

    // MARK: Capabilities

    /// The container (the `layout` block and `card.layout`), version 1.
    public static let capability = "layout@1"
    /// Every capability this renderer has: the container and each kind it draws.
    public static let capabilities: [String] = [capability] + kinds.map { "node.\($0)" }
    /// The header a native renderer sends its capabilities in, comma-separated.
    public static let capabilitiesHeader = "X-Ripul-Cms-Capabilities"

    // MARK: Limits

    public static let maxDepth = 8
    public static let maxNodes = 200
    public static let repeatDefault = 20
    public static let repeatMax = 50

    // MARK: Values

    /// A value as text, as JavaScript's `String(v)` writes it; objects and null are empty.
    static func text(_ v: CmsJSON?) -> String {
        switch v {
        case .string(let s)?: return s
        case .number(let n)?: return CmsActionForm.numberString(n)
        case .bool(let b)?: return b ? "true" : "false"
        default: return ""
        }
    }

    /// A dotted column (a view's `alias.column`) as the row has it: the whole key first, then the path.
    static func rowValue(_ row: [String: CmsJSON]?, _ column: String) -> CmsJSON? {
        guard let row else { return nil }
        if let v = row[column] { return v }
        var at: CmsJSON? = .object(row)
        for part in column.split(separator: ".", omittingEmptySubsequences: false) {
            guard let o = at?.objectValue else { return nil }
            at = o[String(part)]
        }
        return at
    }

    private static let slotPattern = try! NSRegularExpression(pattern: #"\{([A-Za-z_][\w.]*)(?:\|([^}]*))?\}"#)

    /// A template's text, by the list rows' rule (fillLine): joining words drop
    /// beside an empty value, and a template whose slots are all empty is nil.
    static func fill(_ text: String, valueOf: (String, String?) -> String) -> String? {
        let ns = text as NSString
        let matches = slotPattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return text.isEmpty ? nil : text }
        var pieces: [String] = []
        var at = 0
        var values: [String] = []
        for m in matches {
            pieces.append(ns.substring(with: NSRange(location: at, length: m.range.location - at)))
            at = m.range.location + m.range.length
            let column = ns.substring(with: m.range(at: 1))
            let formatRange = m.range(at: 2)
            let format = formatRange.location == NSNotFound ? nil : ns.substring(with: formatRange)
            values.append(valueOf(column, format?.isEmpty == false ? format : nil))
        }
        pieces.append(ns.substring(from: at))
        let shown = values.indices.filter { !values[$0].isEmpty }
        if shown.isEmpty { return nil }
        var out = values[0].isEmpty ? "" : pieces[0]
        for (k, i) in shown.enumerated() {
            out += values[i]
            if k < shown.count - 1 { out += pieces[i + 1] }
        }
        if !values[values.count - 1].isEmpty { out += pieces[values.count] }
        return out.isEmpty ? nil : out
    }

    /// An expression's scope over a row's columns.
    static func scope(_ row: [String: CmsJSON]) -> CmsFormScope {
        CmsFormScope(
            number: { CmsFormScope.number(rowValue(row, $0)) },
            moment: { name in
                rowValue(row, name)?.stringValue.flatMap { CmsFormatValue.toDate($0, naiveUTC: true, localZone: .current) }
            },
            items: { name in rowValue(row, name)?.arrayValue?.compactMap(\.objectValue) ?? [] },
            value: { name in
                let v = rowValue(row, name)
                if let n = CmsFormScope.number(v) { return .number(n) }
                if let s = v?.stringValue, !s.isEmpty { return .text(s) }
                return .blank
            }
        )
    }

    /// An expression's value over a row; nil when it doesn't parse or is blank.
    static func evaluate(_ expr: String, row: [String: CmsJSON]?) -> CmsFormValue? {
        guard let parsed = CmsFormExpr.parse(expr) else { return nil }
        return scope(row ?? [:]).value(parsed)
    }

    /// Whether a condition holds for a row. Values compare as text, as cards' do.
    static func holds(_ cond: CmsJSON?, row: [String: CmsJSON]?, rows: (String) -> CmsPrimitiveRows) -> Bool {
        guard let c = cond?.objectValue else { return true }
        if let expr = c.string("expr") {
            switch evaluate(expr, row: row) {
            case .number(let n)?: return n != 0
            case .text(let t)?: return !t.isEmpty
            default: return false
            }
        }
        if let query = c.string("rows") {
            guard case .ready(let list) = rows(query) else { return false }
            let empty = list.isEmpty
            if let want = c.bool("empty") { return want == empty }
            return !empty
        }
        if let column = c.string("column") {
            let value = text(rowValue(row, column))
            if let empty = c.bool("empty") { return empty == value.isEmpty }
            if let list = c["in"]?.arrayValue { return list.map { text($0) }.contains(value) }
            if let equals = c["equals"] { return text(equals) == value }
            return !value.isEmpty
        }
        return true
    }

    static func insets(_ p: CmsJSON?) -> CmsPrimitive.Insets? {
        guard let p else { return nil }
        if let token = p.stringValue {
            guard let n = space[token] else { return nil }
            return .init(top: n, trailing: n, bottom: n, leading: n)
        }
        guard let o = p.objectValue else { return nil }
        let pt: (String) -> Double? = { o.string($0).flatMap { space[$0] } }
        let x = pt("x") ?? 0, y = pt("y") ?? 0
        return .init(top: pt("top") ?? y, trailing: pt("trailing") ?? x, bottom: pt("bottom") ?? y, leading: pt("leading") ?? x)
    }

    static func size(_ v: CmsJSON?, _ fallback: CmsPrimitive.Size) -> CmsPrimitive.Size {
        if let s = v?.stringValue { return s == "fill" ? .fill : s == "fit" ? .fit : fallback }
        if let n = v?.doubleValue, n.isFinite, n >= 0 { return .points(n) }
        return fallback
    }

    static func role(_ v: CmsJSON?) -> CmsPaletteRole? { v?.stringValue.flatMap(CmsPaletteRole.init(rawValue:)) }
    static func oneOf(_ v: CmsJSON?, _ list: [String]) -> String? { v?.stringValue.flatMap { list.contains($0) ? $0 : nil } }

    // MARK: Resolving

    public struct Result {
        public var root: CmsPrimitive?
        /// Nodes left out at the depth or node limit.
        public var cut: Int
    }

    /// Resolves a tree for drawing. A node is left out when its `when` fails,
    /// its text has no value, or it can't be drawn and has no fallback;
    /// `repeat` puts one child per row in its parent's place. Past `maxDepth`
    /// or `maxNodes` the rest is left out and counted in `cut`.
    ///
    /// - `rows`: a query's or view's rows, for `repeat` and `{ rows }` conditions.
    /// - `supports`: whether this renderer has a capability (default: `capabilities`).
    /// - `slot`: a slot's text, the column's value in the format (default: the value as text).
    /// - `format`: an expression's value in a format (default: as text).
    public static func resolve(_ tree: CmsJSON?, row: [String: CmsJSON]? = nil,
                               rows: @escaping (String) -> CmsPrimitiveRows = { _ in .loading },
                               supports: ((String) -> Bool)? = nil,
                               slot: ((String, String?, [String: CmsJSON]) -> String)? = nil,
                               format: ((CmsFormValue, String) -> String)? = nil) -> Result {
        let resolver = Resolver(rows: rows, supports: supports ?? { capabilities.contains($0) }, slot: slot, format: format)
        let out = resolver.resolve(tree, key: "root", row: row, depth: 1)
        let root: CmsPrimitive?
        if out.isEmpty {
            root = nil
        } else if out.count == 1 {
            root = out[0]
        } else {
            // A repeat at the root resolves to several: they stand in a stack.
            var stack = CmsPrimitive(kind: "stack", key: "root+", width: .fill, height: .fit)
            stack.gap = 0
            stack.align = "leading"
            stack.children = out
            root = stack
        }
        return Result(root: root, cut: resolver.cut)
    }

    /// Every query or view a tree reads: repeats and `{ rows }` conditions, fallbacks included.
    public static func querySlugs(_ tree: CmsJSON?) -> [String] {
        var out: [String] = []
        func walk(_ n: CmsJSON?) {
            guard let o = n?.objectValue else { return }
            if o.string("kind") == "repeat", let q = o.string("rows"), !out.contains(q) { out.append(q) }
            if let q = o.object("when")?.string("rows"), !out.contains(q) { out.append(q) }
            o["children"]?.arrayValue?.forEach(walk)
            walk(o["child"]); walk(o["empty"]); walk(o["fallback"])
        }
        walk(tree)
        return out
    }

    private final class Resolver {
        let rows: (String) -> CmsPrimitiveRows
        let supports: (String) -> Bool
        let slot: ((String, String?, [String: CmsJSON]) -> String)?
        let format: ((CmsFormValue, String) -> String)?
        var count = 0
        var cut = 0

        init(rows: @escaping (String) -> CmsPrimitiveRows, supports: @escaping (String) -> Bool,
             slot: ((String, String?, [String: CmsJSON]) -> String)?, format: ((CmsFormValue, String) -> String)?) {
            self.rows = rows
            self.supports = supports
            self.slot = slot
            self.format = format
        }

        func valueOf(_ row: [String: CmsJSON]?) -> (String, String?) -> String {
            { column, fmt in
                let r = row ?? [:]
                if let slot = self.slot { return slot(column, fmt, r) }
                return CmsPrimitives.text(CmsPrimitives.rowValue(r, column))
            }
        }

        func drawable(_ n: [String: CmsJSON]) -> Bool {
            guard let kind = n.string("kind"), CmsPrimitives.kinds.contains(kind), supports("node.\(kind)") else { return false }
            let req = n["requires"]?.arrayValue ?? []
            return req.allSatisfy { $0.stringValue.map(supports) ?? false }
        }

        /// One node (or, for a repeat, several) in its parent's place.
        func resolve(_ raw: CmsJSON?, key: String, row: [String: CmsJSON]?, depth: Int) -> [CmsPrimitive] {
            guard let n = raw?.objectValue else { return [] }
            if depth > CmsPrimitives.maxDepth { cut += 1; return [] }
            if !drawable(n) { return n["fallback"] != nil ? resolve(n["fallback"], key: "\(key)~", row: row, depth: depth) : [] }
            if !CmsPrimitives.holds(n["when"], row: row, rows: rows) { return [] }
            let kind = n.string("kind")!

            if kind == "repeat" {
                switch n.string("rows").map(rows) ?? .loading {
                case .loading:
                    if count >= CmsPrimitives.maxNodes { cut += 1; return [] }
                    count += 1
                    return [CmsPrimitive(kind: "loading", key: key, width: .fill, height: .fit)]
                case .error:
                    return []
                case .ready(let list):
                    if list.isEmpty { return n["empty"] != nil ? resolve(n["empty"], key: "\(key).empty", row: row, depth: depth) : [] }
                    let max = Swift.min(CmsPrimitives.repeatMax, Swift.max(1, Int(n.double("max") ?? Double(CmsPrimitives.repeatDefault))))
                    var out: [CmsPrimitive] = []
                    for (i, each) in list.prefix(max).enumerated() {
                        let id = n.string("key").map { CmsPrimitives.text(CmsPrimitives.rowValue(each, $0)) } ?? ""
                        out += resolve(n["child"], key: "\(key)[\(id.isEmpty ? String(i) : id)]", row: each, depth: depth)
                    }
                    return out
                }
            }

            if count >= CmsPrimitives.maxNodes { cut += 1; return [] }
            count += 1

            let containerKind = CmsPrimitives.containers.contains(kind) || kind == "divider"
            var node = CmsPrimitive(kind: kind, key: key,
                                    width: CmsPrimitives.size(n["width"], containerKind ? .fill : .fit),
                                    height: CmsPrimitives.size(n["height"], kind == "spacer" ? .fill : .fit))
            node.padding = CmsPrimitives.insets(n["padding"])
            node.background = CmsPrimitives.role(n["background"])
            node.border = CmsPrimitives.role(n["border"])
            node.radius = n.string("radius").flatMap { CmsPrimitives.radii[$0] }
            node.place = CmsPrimitives.oneOf(n["place"], CmsPrimitives.places)
            node.tap = n["tap"]?.objectValue != nil ? n["tap"] : nil
            node.longPress = n["longPress"]?.objectValue != nil ? n["longPress"] : nil
            node.label = n.string("label").flatMap { CmsPrimitives.fill($0, valueOf: valueOf(row)) }
            node.hidden = n.bool("hidden") == true
            node.testId = n.string("testId")
            node.row = row

            func kids() -> [CmsPrimitive] {
                var out: [CmsPrimitive] = []
                for (i, c) in (n["children"]?.arrayValue ?? []).enumerated() {
                    let id = c.objectValue?.string("id").flatMap { $0.isEmpty ? nil : $0 } ?? String(i)
                    out += resolve(c, key: "\(key).\(id)", row: row, depth: depth + 1)
                }
                return out
            }
            let gap = n.string("gap").flatMap { CmsPrimitives.space[$0] } ?? 0

            switch kind {
            case "stack":
                node.gap = gap
                node.align = CmsPrimitives.oneOf(n["align"], ["leading", "center", "trailing"]) ?? "leading"
                node.children = kids()
            case "row":
                node.gap = gap
                node.align = CmsPrimitives.oneOf(n["align"], ["top", "center", "bottom", "baseline"]) ?? "center"
                node.stackAtLargeText = n.bool("stackAtLargeText") == true
                node.children = kids()
            case "grid":
                node.gap = gap
                if let w = n.double("minWidth"), w > 0 {
                    node.minWidth = w
                } else {
                    node.columns = Swift.min(6, Swift.max(1, Int(n.double("columns") ?? 2)))
                }
                node.children = kids()
            case "overlay":
                node.align = CmsPrimitives.oneOf(n["align"], CmsPrimitives.places) ?? "center"
                node.children = kids()
            case "scroll":
                node.gap = gap
                node.paging = n.bool("paging") == true
                node.children = kids()
            case "spacer":
                node.min = n.double("min").flatMap { $0 >= 0 ? $0 : nil } ?? 0
            case "text":
                var text: String?
                if let expr = n.string("expr") {
                    switch CmsPrimitives.evaluate(expr, row: row) {
                    case .number(let v)?:
                        text = n.string("format").flatMap { f in format.map { $0(.number(v), f) } } ?? CmsActionForm.numberString(v)
                    case .text(let t)? where !t.isEmpty:
                        text = n.string("format").flatMap { f in format.map { $0(.text(t), f) } } ?? t
                    default:
                        text = nil
                    }
                } else if let template = n.string("text") {
                    text = CmsPrimitives.fill(template, valueOf: valueOf(row))
                }
                guard let text else { count -= 1; return [] }
                node.text = text
                node.style = n.string("style").flatMap { CmsPrimitives.textStyles[$0] != nil ? $0 : nil } ?? "body"
                node.color = CmsPrimitives.role(n["color"]) ?? .text
                node.weight = CmsPrimitives.oneOf(n["weight"], CmsPrimitives.weights)
                node.lines = n.double("lines").flatMap { $0 >= 1 ? Int($0) : nil }
                node.align = CmsPrimitives.oneOf(n["align"], ["leading", "center", "trailing"]) ?? "leading"
            case "image":
                var src: String?
                if let s = n.string("src"), !s.isEmpty {
                    if s.contains("{") { src = CmsPrimitives.fill(s, valueOf: valueOf(row)) }
                    else if s.hasPrefix("https://") || s.hasPrefix("http://") { src = s }
                    else { src = CmsPrimitives.text(CmsPrimitives.rowValue(row, s)).nilIfEmpty }
                }
                let chain = n["chain"]?.arrayValue.flatMap { $0.isEmpty ? nil : $0 }
                if src == nil && chain == nil { count -= 1; return [] }
                node.src = src
                node.chain = chain
                node.fit = n.string("fit") == "fit" ? "fit" : "fill"
                node.aspect = n.double("aspect").flatMap { $0 > 0 ? $0 : nil }
                node.shape = n.string("shape") == "circle" ? "circle" : "rect"
                node.template = n.bool("template") == true
                node.color = CmsPrimitives.role(n["color"])
            case "icon":
                let name = n.string("name"), sf = n.string("sf"), material = n.string("material")
                if (name ?? "").isEmpty && (sf ?? "").isEmpty && (material ?? "").isEmpty { count -= 1; return [] }
                node.name = name
                node.sf = sf
                node.material = material
                node.size = n.double("size").flatMap { $0 > 0 ? $0 : nil } ?? 20
                node.color = CmsPrimitives.role(n["color"]) ?? .text
            case "shape":
                node.shape = CmsPrimitives.oneOf(n["shape"], ["rect", "capsule", "circle"]) ?? "rect"
                node.fill = CmsPrimitives.role(n["fill"]) ?? .surfaceMuted
            case "badge":
                guard let text = n.string("text").flatMap({ CmsPrimitives.fill($0, valueOf: valueOf(row)) }) else { count -= 1; return [] }
                node.text = text
                node.color = CmsPrimitives.role(n["color"]) ?? .primary
                node.look = n.string("look") == "filled" ? "filled" : "tinted"
            case "divider":
                node.color = CmsPrimitives.role(n["color"]) ?? .divider
            default:
                return []
            }
            return [node]
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - The shared cases' shape

extension CmsPrimitive {
    /// The node as the shared cases write it (each node's `row` left out).
    var caseJSON: [String: Any] {
        func size(_ s: Size) -> Any {
            switch s {
            case .fill: return "fill"
            case .fit: return "fit"
            case .points(let n): return n
            }
        }
        func plain(_ j: CmsJSON) -> Any {
            switch j {
            case .string(let s): return s
            case .number(let n): return n
            case .bool(let b): return b
            case .null: return NSNull()
            case .array(let a): return a.map(plain)
            case .object(let o): return o.mapValues(plain)
            }
        }
        var o: [String: Any] = ["kind": kind, "key": key, "width": size(width), "height": size(height)]
        if let p = padding { o["padding"] = ["top": p.top, "trailing": p.trailing, "bottom": p.bottom, "leading": p.leading] }
        if let v = background { o["background"] = v.rawValue }
        if let v = border { o["border"] = v.rawValue }
        if let v = radius { o["radius"] = v }
        if let v = place { o["place"] = v }
        if let v = tap { o["tap"] = plain(v) }
        if let v = longPress { o["longPress"] = plain(v) }
        if let v = label { o["label"] = v }
        if hidden { o["hidden"] = true }
        if let v = testId { o["testId"] = v }
        if let v = children { o["children"] = v.map(\.caseJSON) }
        if let v = gap { o["gap"] = v }
        if let v = align { o["align"] = v }
        if let v = columns { o["columns"] = v }
        if let v = minWidth { o["minWidth"] = v }
        if paging { o["paging"] = true }
        if stackAtLargeText { o["stackAtLargeText"] = true }
        if let v = min { o["min"] = v }
        if let v = text { o["text"] = v }
        if let v = style { o["style"] = v }
        if let v = color { o["color"] = v.rawValue }
        if let v = weight { o["weight"] = v }
        if let v = lines { o["lines"] = v }
        if let v = src { o["src"] = v }
        if let v = chain { o["chain"] = v.map(plain) }
        if let v = fit { o["fit"] = v }
        if let v = aspect { o["aspect"] = v }
        if let v = shape { o["shape"] = v }
        if template { o["template"] = true }
        if let v = name { o["name"] = v }
        if let v = sf { o["sf"] = v }
        if let v = material { o["material"] = v }
        if let v = self.size { o["size"] = v }
        if let v = fill { o["fill"] = v.rawValue }
        if let v = look { o["look"] = v }
        return o
    }
}
