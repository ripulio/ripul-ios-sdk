import Foundation
import CoreFoundation

/// The report/steps wire format is shared with markdownReportBlocks.ts. Keep
/// normalization, amount scaling and CSV values compatible with the web card.
struct NativeMarkdownReport: Sendable {
    enum Tone: String, Sendable { case neutral, ok, warn, bad }
    struct Stat: Sendable { let value: String; let label: String; let tone: Tone }
    struct Bar: Sendable {
        let label: String
        var value: Double
        let planned: Double?
        let worked: Double?
        let amount: Double?
        let note: String
        let tone: Tone
    }
    struct Group: Sendable { let title: String; let detail: String; let person: Bool; var bars: [Bar] }
    struct Note: Sendable { let title: String; let text: String; let tone: Tone }
    struct Table: Sendable { let columns: [String]; let rows: [[String]] }
    struct Badge: Sendable { let text: String; let tone: Tone }
    let title: String
    let badge: Badge?
    let stats: [Stat]
    let groups: [Group]
    let notes: [Note]
    let table: Table?
    let download: String

    enum Parsed: Sendable {
        case complete(NativeMarkdownReport), writing(NativeMarkdownReport), preparing, invalid
    }
    private final class Box: NSObject {
        let value: Parsed
        init(_ value: Parsed) { self.value = value }
    }
    nonisolated(unsafe) private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 32
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    static func cached(_ source: String) -> Parsed? { cache.object(forKey: source as NSString)?.value }

    static func parse(_ source: String) -> Parsed {
        guard source.utf8.count <= 2 * 1024 * 1024 else { return .invalid }
        if let hit = cache.object(forKey: source as NSString) { return hit.value }
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: Parsed
        if trimmed.isEmpty { value = .preparing }
        else if let data = trimmed.data(using: .utf8), let raw = try? JSONSerialization.jsonObject(with: data) {
            value = normalize(raw).map(Parsed.complete) ?? .invalid
        } else if trimmed.hasPrefix("{"), hasOpenContainer(trimmed) {
            if let closed = closePartialJSON(trimmed), let data = closed.data(using: .utf8),
               let raw = try? JSONSerialization.jsonObject(with: data), let report = normalize(raw) {
                value = .writing(report)
            } else { value = .preparing }
        } else { value = .invalid }
        cache.setObject(Box(value), forKey: source as NSString, cost: source.utf8.count * 3)
        return value
    }

    private static func text(_ value: Any?) -> String {
        if let string = value as? String { return string.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite { return number.stringValue }
        return ""
    }
    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
    private static func isFalse(_ value: Any?) -> Bool {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
        return !value.boolValue
    }
    private static func list(_ value: Any?) -> [Any] { value as? [Any] ?? [] }
    private static func tone(_ value: Any?, fallback: Tone = .neutral) -> Tone { (value as? String).flatMap(Tone.init) ?? fallback }

    static func normalize(_ value: Any) -> NativeMarkdownReport? {
        guard let raw = value as? [String: Any] else { return nil }
        let title = text(raw["title"])
        let stats: [Stat] = list(raw["stats"]).prefix(6).compactMap {
            guard let s = $0 as? [String: Any] else { return nil }
            let value = text(s["value"]), label = text(s["label"])
            return value.isEmpty && label.isEmpty ? nil : Stat(value: value, label: label, tone: tone(s["tone"]))
        }
        var groups: [Group] = list(raw["groups"] ?? raw["people"]).prefix(200).compactMap {
            guard let g = $0 as? [String: Any] else { return nil }
            let bars: [Bar] = list(g["bars"] ?? g["days"]).prefix(100).compactMap {
                guard let b = $0 as? [String: Any] else { return nil }
                let label = text(b["label"] ?? b["day"])
                guard !label.isEmpty else { return nil }
                let planned = number(b["planned"]), worked = number(b["worked"]), amount = number(b["amount"] ?? b["hours"])
                var value = number(b["value"])
                if value == nil, let worked { value = (planned ?? 0) > 0 ? worked / planned! : (worked > 0 ? 1 : 0) }
                return Bar(label: label, value: value == nil && amount != nil ? .nan : min(1, max(0, value ?? 0)),
                           planned: planned, worked: worked, amount: amount, note: text(b["note"]), tone: tone(b["tone"]))
            }
            let title = text(g["title"] ?? g["name"])
            return title.isEmpty && bars.isEmpty ? nil : Group(title: title, detail: text(g["detail"]), person: !isFalse(g["person"]), bars: bars)
        }
        let most = groups.flatMap(\.bars).compactMap(\.amount).max() ?? 0
        for g in groups.indices {
            for b in groups[g].bars.indices where groups[g].bars[b].value.isNaN {
                groups[g].bars[b].value = most > 0 ? min(1, max(0, (groups[g].bars[b].amount ?? 0) / most)) : 0
            }
        }
        let notes: [Note] = list(raw["notes"]).prefix(24).compactMap {
            if let string = $0 as? String {
                let body = text(string)
                return body.isEmpty ? nil : Note(title: "", text: body, tone: .warn)
            }
            guard let n = $0 as? [String: Any] else { return nil }
            let body = text(n["text"])
            return body.isEmpty ? nil : Note(title: text(n["title"]), text: body, tone: tone(n["tone"], fallback: .warn))
        }
        guard !title.isEmpty || !stats.isEmpty || !groups.isEmpty,
              !stats.isEmpty || !groups.isEmpty || !notes.isEmpty else { return nil }
        var badge: Badge?
        if let b = raw["badge"] as? [String: Any], !text(b["text"]).isEmpty { badge = Badge(text: text(b["text"]), tone: tone(b["tone"])) }
        var table: Table?
        if let t = raw["table"] as? [String: Any] {
            let columns = list(t["columns"]).map(text).filter { !$0.isEmpty }
            let rows = list(t["rows"]).prefix(2000).compactMap { ($0 as? [Any])?.map(text) }
            if !columns.isEmpty && !rows.isEmpty { table = Table(columns: columns, rows: rows) }
        }
        let label = text(raw["download"])
        return NativeMarkdownReport(title: title, badge: badge, stats: stats, groups: groups, notes: notes, table: table,
                                    download: isFalse(raw["download"]) ? "" : (label.isEmpty ? "Download full report" : label))
    }

    /// Preserve only completed values during streaming, just as the web card
    /// does. Never invent the end of a partially written number or string.
    static func closePartialJSON(_ source: String) -> String? {
        let chars = Array(source)
        var closers: [Character] = [], keyNext: [Bool] = []
        var inString = false, escaped = false, stringIsKey = false
        var cut: Int?, cutClosers = ""
        func complete(_ at: Int) { cut = at; cutClosers = String(closers.reversed()) }
        for (i, c) in chars.enumerated() {
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false; if !stringIsKey { complete(i + 1) } }
                continue
            }
            if c == "\"" {
                inString = true
                stringIsKey = closers.last == "}" && keyNext.last == true
                if stringIsKey { keyNext[keyNext.count - 1] = false }
            } else if c == "{" || c == "[" {
                guard closers.count < 128 else { return nil }
                closers.append(c == "{" ? "}" : "]"); keyNext.append(c == "{")
            } else if c == "}" || c == "]" {
                guard closers.last == c else { return nil }
                closers.removeLast(); keyNext.removeLast()
                if closers.isEmpty { return String(chars.prefix(i + 1)) }
                complete(i + 1)
            } else if c == ",", !closers.isEmpty {
                complete(i)
                if closers.last == "}" { keyNext[keyNext.count - 1] = true }
            }
        }
        return cut.map { String(chars.prefix($0)) + cutClosers }
    }

    private static func hasOpenContainer(_ source: String) -> Bool {
        var stack: [Character] = []
        var inString = false, escaped = false
        for c in source {
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else if c == "\"" { inString = true }
            else if c == "{" || c == "[" { stack.append(c == "{" ? "}" : "]") }
            else if c == "}" || c == "]" {
                guard stack.popLast() == c else { return false }
                if stack.isEmpty { return false }
            }
        }
        return !stack.isEmpty
    }

    var filename: String {
        let name = title.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "-")
        return name.isEmpty ? "report" : String(name.prefix(100))
    }

    static func csvCell(_ text: String) -> String {
        // Match web exports: a cell cannot become a spreadsheet formula.
        let formula = text.first.map { "=+-@".contains($0) } == true && Double(text) == nil
        let safe = formula ? "'" + text : text
        return safe.contains(where: { ",\"\n\r".contains($0) }) ? "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : safe
    }
    var csv: String {
        func row(_ cells: [String]) -> String { cells.map(Self.csvCell).joined(separator: ",") }
        func hours(_ value: Double?) -> String { value.map { NSNumber(value: ($0 * 100).rounded() / 100).stringValue } ?? "" }
        var lines: [String] = []
        if !title.isEmpty { lines.append(row([title])) }
        if let badge { lines.append(row([badge.text])) }
        if !stats.isEmpty { lines += ["", "Summary"] + stats.map { row([$0.label, $0.value]) } }
        let bars = groups.flatMap(\.bars)
        if !bars.isEmpty {
            let timed = bars.contains { $0.planned != nil || $0.worked != nil }
            let measured = !timed && bars.contains { $0.amount != nil }
            lines += ["", row(timed ? ["Name", "Detail", "Day", "Planned hours", "Worked hours", "Variance", "Note"] : measured ? ["Name", "Detail", "Item", "Amount", "Note"] : ["Name", "Detail", "Item", "Note"])]
            for g in groups { for b in g.bars {
                var cells = [g.title, g.detail, b.label]
                if timed { cells += [hours(b.planned), hours(b.worked), hours(b.planned.flatMap { p in b.worked.map { $0 - p } })] }
                else if measured { cells.append(hours(b.amount)) }
                lines.append(row(cells + [b.note]))
            } }
        }
        if !notes.isEmpty { lines += ["", "Notes"] + notes.map { row([$0.title, $0.text]) } }
        if let table { lines += ["", row(table.columns)] + table.rows.map(row) }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    var html: String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        var body = "<h1>\(escape(title))</h1>"
        if let badge { body += "<p>\(escape(badge.text))</p>" }
        body += "<dl>" + stats.map { "<dt>\(escape($0.label))</dt><dd>\(escape($0.value))</dd>" }.joined() + "</dl>"
        for group in groups {
            body += "<section><h2>\(escape(group.title))</h2><p>\(escape(group.detail))</p>"
            for bar in group.bars {
                body += "<p><strong>\(escape(bar.label))</strong> <meter min=\"0\" max=\"1\" value=\"\(bar.value)\"></meter> \(escape(bar.note))</p>"
            }
            body += "</section>"
        }
        for note in notes { body += "<p><strong>\(escape(note.title))</strong> \(escape(note.text))</p>" }
        if let table {
            body += "<table><thead><tr>" + table.columns.map { "<th>\(escape($0))</th>" }.joined() + "</tr></thead><tbody>"
            for row in table.rows { body += "<tr>" + row.map { "<td>\(escape($0))</td>" }.joined() + "</tr>" }
            body += "</tbody></table>"
        }
        return "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width\"><title>\(escape(title))</title><style>body{font:16px system-ui;max-width:900px;margin:24px auto;padding:16px;color:#111;background:white}p,td{white-space:pre-wrap;overflow-wrap:anywhere}table{border-collapse:collapse;width:100%}td,th{border:1px solid #ccc;padding:8px;text-align:left}section{break-inside:avoid}dd{margin:0 0 12px;font-weight:bold}meter{width:120px}</style></head><body>\(body)</body></html>"
    }
}

/// Large reports can arrive a few characters at a time. Serialize their JSON
/// normalization away from the main actor; the view coalesces streamed edits.
actor NativeMarkdownReportParser {
    static let shared = NativeMarkdownReportParser()
    func parse(_ source: String) -> NativeMarkdownReport.Parsed {
        guard !Task.isCancelled else { return .preparing }
        return NativeMarkdownReport.parse(source)
    }
}
