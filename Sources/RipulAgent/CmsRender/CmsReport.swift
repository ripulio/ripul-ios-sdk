import SwiftUI

/// Twin of `markdownReportBlocks.ts`'s report: the JSON a reconcile chat
/// writes (title, badge, stats, groups of bars, notes, a full table) and its
/// spreadsheet. `normalise` and `csv` are ported function for function; the
/// to-do actions a chat report carries are not read here (they belong to the
/// chat's report card, not to a kept report).
struct CmsReport: Equatable {
    enum Tone: String { case neutral, ok, warn, bad }
    struct Stat: Equatable { var value: String; var label: String; var tone: Tone }
    struct Bar: Equatable { var label: String; var value: Double; var planned: Double?; var worked: Double?; var amount: Double?; var note: String; var tone: Tone }
    struct Group: Equatable { var title: String; var detail: String; var person: Bool; var bars: [Bar] }
    struct Note: Equatable { var title: String; var text: String; var tone: Tone }

    var title: String
    var badge: (text: String, tone: Tone)?
    var stats: [Stat]
    var groups: [Group]
    var notes: [Note]
    var table: (columns: [String], rows: [[String]])?
    var download: String

    static func == (a: CmsReport, b: CmsReport) -> Bool {
        a.title == b.title && a.stats == b.stats && a.groups == b.groups && a.notes == b.notes
            && a.badge?.text == b.badge?.text && a.table?.columns == b.table?.columns && a.table?.rows == b.table?.rows
    }

    private static func text(_ v: Any?) -> String {
        if let s = v as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let n = v as? NSNumber, !(v is Bool) { return n.stringValue }
        return ""
    }
    private static func num(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, !(v is Bool), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
    private static func tone(_ v: Any?, _ fallback: Tone = .neutral) -> Tone {
        (v as? String).flatMap(Tone.init(rawValue:)) ?? fallback
    }
    private static func list(_ v: Any?) -> [Any] { v as? [Any] ?? [] }

    private static func bar(_ raw: Any) -> Bar? {
        guard let r = raw as? [String: Any] else { return nil }
        let label = text(r["label"] ?? r["day"])
        guard !label.isEmpty else { return nil }
        let planned = num(r["planned"]), worked = num(r["worked"]), amount = num(r["amount"] ?? r["hours"])
        var value = num(r["value"])
        if value == nil, let worked {
            // Nothing planned and something worked is a full bar: the work happened.
            value = (planned ?? 0) > 0 ? worked / planned! : (worked > 0 ? 1 : 0)
        }
        return Bar(label: label,
                   value: value == nil && amount != nil ? .nan : min(1, max(0, value ?? 0)),
                   planned: planned, worked: worked, amount: amount, note: text(r["note"]), tone: tone(r["tone"]))
    }

    /// `normaliseReport`: nil when it is not a report.
    static func normalise(_ raw: Any?) -> CmsReport? {
        guard let r = raw as? [String: Any] else { return nil }
        let title = text(r["title"])
        let stats: [Stat] = list(r["stats"]).prefix(6).compactMap { s in
            guard let s = s as? [String: Any] else { return nil }
            let value = text(s["value"]), label = text(s["label"])
            return value.isEmpty && label.isEmpty ? nil : Stat(value: value, label: label, tone: tone(s["tone"]))
        }
        var groups: [Group] = list(r["groups"] ?? r["people"]).prefix(40).compactMap { g in
            guard let g = g as? [String: Any] else { return nil }
            let bars = list(g["bars"] ?? g["days"]).prefix(40).compactMap(bar)
            let t = text(g["title"] ?? g["name"])
            return t.isEmpty && bars.isEmpty ? nil : Group(title: t, detail: text(g["detail"]), person: (g["person"] as? Bool) != false, bars: bars)
        }
        // scaleAmounts: bars with only an amount are drawn against the largest.
        let most = max(0, groups.flatMap(\.bars).compactMap(\.amount).max() ?? 0)
        for gi in groups.indices { for bi in groups[gi].bars.indices where groups[gi].bars[bi].value.isNaN {
            groups[gi].bars[bi].value = most > 0 ? min(1, max(0, (groups[gi].bars[bi].amount ?? 0) / most)) : 0
        } }
        let notes: [Note] = list(r["notes"]).prefix(8).compactMap { n in
            if let s = n as? String { let t = s.trimmingCharacters(in: .whitespaces); return t.isEmpty ? nil : Note(title: "", text: t, tone: .warn) }
            guard let n = n as? [String: Any] else { return nil }
            let body = text(n["text"])
            return body.isEmpty ? nil : Note(title: text(n["title"]), text: body, tone: tone(n["tone"], .warn))
        }
        if title.isEmpty && stats.isEmpty && groups.isEmpty { return nil }
        if stats.isEmpty && groups.isEmpty && notes.isEmpty { return nil }
        var badge: (String, Tone)?
        if let b = r["badge"] as? [String: Any], !text(b["text"]).isEmpty { badge = (text(b["text"]), tone(b["tone"])) }
        var table: ([String], [[String]])?
        if let t = r["table"] as? [String: Any] {
            let columns = list(t["columns"]).map { text($0) }.filter { !$0.isEmpty }
            let rows = list(t["rows"]).prefix(2000).compactMap { ($0 as? [Any])?.map { text($0) } }
            if !columns.isEmpty && !rows.isEmpty { table = (columns, rows) }
        }
        let download = (r["download"] as? Bool) == false ? "" : (text(r["download"]).isEmpty ? "Download full report" : text(r["download"]))
        return CmsReport(title: title, badge: badge, stats: stats, groups: groups, notes: notes, table: table, download: download)
    }

    // MARK: - CSV (`reportToCsv`)

    private static func cell(_ value: String) -> String {
        // A leading =, +, - or @ would run as a formula when the file is opened.
        let safe = value.range(of: "^[=+\\-@]", options: .regularExpression) != nil && Double(value) == nil ? "'" + value : value
        return safe.rangeOfCharacter(from: CharacterSet(charactersIn: "\",\n\r")) != nil
            ? "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : safe
    }
    private static func row(_ cells: [String]) -> String { cells.map(cell).joined(separator: ",") }
    private static func hours(_ n: Double?) -> String {
        guard let n else { return "" }
        let r = (n * 100).rounded() / 100
        return r.rounded() == r ? String(Int(r)) : String(r)
    }

    var csv: String {
        var lines: [String] = []
        if !title.isEmpty { lines.append(Self.row([title])) }
        if let badge { lines.append(Self.row([badge.text])) }
        if !stats.isEmpty {
            lines += ["", Self.row(["Summary"])]
            lines += stats.map { Self.row([$0.label, $0.value]) }
        }
        let bars = groups.flatMap { g in g.bars.map { (g, $0) } }
        if !bars.isEmpty {
            let timed = bars.contains { $0.1.planned != nil || $0.1.worked != nil }
            let measured = !timed && bars.contains { $0.1.amount != nil }
            lines.append("")
            lines.append(Self.row(timed ? ["Name", "Detail", "Day", "Planned hours", "Worked hours", "Variance", "Note"]
                                  : measured ? ["Name", "Detail", "Item", "Amount", "Note"] : ["Name", "Detail", "Item", "Note"]))
            for (g, b) in bars {
                let diff = b.planned != nil && b.worked != nil ? Self.hours(b.worked! - b.planned!) : ""
                lines.append(Self.row(timed ? [g.title, g.detail, b.label, Self.hours(b.planned), Self.hours(b.worked), diff, b.note]
                                      : measured ? [g.title, g.detail, b.label, Self.hours(b.amount), b.note] : [g.title, g.detail, b.label, b.note]))
            }
        }
        if !notes.isEmpty {
            lines += ["", Self.row(["Notes"])]
            lines += notes.map { Self.row([$0.title, $0.text]) }
        }
        if let table {
            lines += ["", Self.row(table.columns)]
            lines += table.rows.map(Self.row)
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// `reportFileName`.
    func fileName(_ ext: String = "csv") -> String {
        let base = title.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "\(base.isEmpty ? "report" : String(base.prefix(60))).\(ext)"
    }

    /// The CSV written to a temporary file, for the share sheet.
    func csvFile() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName())
        do { try csv.write(to: url, atomically: true, encoding: .utf8); return url } catch { return nil }
    }
}

/// A report drawn natively: headline figures, each group's bars, the notes
/// and the full table (scrolling sideways).
struct CmsReportView: View {
    let report: CmsReport
    @EnvironmentObject var runtime: CmsRuntime

    private func color(_ tone: CmsReport.Tone) -> Color {
        switch tone {
        case .ok: return runtime.theme.success
        case .warn: return runtime.theme.warning
        case .bad: return runtime.theme.error
        case .neutral: return runtime.theme.primary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text(report.title.isEmpty ? "Report" : report.title).font(.system(size: 20, weight: .bold))
                if let badge = report.badge {
                    Text(badge.text).font(.system(size: 12, weight: .bold)).foregroundColor(color(badge.tone))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(color(badge.tone).opacity(0.14)))
                }
            }
            if !report.stats.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(Array(report.stats.enumerated()), id: \.offset) { _, s in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.value).font(.system(size: 20, weight: .bold)).foregroundColor(color(s.tone))
                            Text(s.label).font(.system(size: 12)).foregroundColor(runtime.theme.textSecondary)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12).fill(runtime.theme.surfaceMuted))
                    }
                }
            }
            ForEach(Array(report.groups.enumerated()), id: \.offset) { _, g in
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(g.title).font(.system(size: 15, weight: .bold))
                        if !g.detail.isEmpty { Text(g.detail).font(.system(size: 12)).foregroundColor(runtime.theme.textSecondary) }
                    }
                    ForEach(Array(g.bars.enumerated()), id: \.offset) { _, b in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(b.label).font(.system(size: 13))
                                Spacer()
                                if let worked = b.worked {
                                    Text(b.planned.map { "\(Self.h(worked)) of \(Self.h($0))" } ?? Self.h(worked))
                                        .font(.system(size: 12)).foregroundColor(runtime.theme.textSecondary)
                                } else if let amount = b.amount {
                                    Text(Self.h(amount)).font(.system(size: 12)).foregroundColor(runtime.theme.textSecondary)
                                }
                            }
                            ProgressView(value: b.value).tint(color(b.tone))
                            if !b.note.isEmpty { Text(b.note).font(.system(size: 12)).foregroundColor(color(b.tone)) }
                        }
                    }
                }
            }
            ForEach(Array(report.notes.enumerated()), id: \.offset) { _, n in
                VStack(alignment: .leading, spacing: 2) {
                    if !n.title.isEmpty { Text(n.title).font(.system(size: 14, weight: .bold)) }
                    Text(n.text).font(.system(size: 13.5))
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(color(n.tone).opacity(0.1)))
            }
            if let table = report.table {
                ScrollView(.horizontal) {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                        GridRow { ForEach(table.columns, id: \.self) { Text($0).font(.system(size: 12, weight: .bold)) } }
                        Divider()
                        ForEach(Array(table.rows.prefix(200).enumerated()), id: \.offset) { _, row in
                            GridRow { ForEach(Array(row.enumerated()), id: \.offset) { Text($0.element).font(.system(size: 12)) } }
                        }
                    }
                }
                if table.rows.count > 200 {
                    Text("Showing 200 of \(table.rows.count) rows; the spreadsheet has them all.")
                        .font(.system(size: 12)).foregroundColor(runtime.theme.textSecondary)
                }
            }
        }
    }

    private static func h(_ n: Double) -> String {
        let r = (n * 100).rounded() / 100
        return r.rounded() == r ? "\(Int(r))h" : "\(r)h"
    }
}
