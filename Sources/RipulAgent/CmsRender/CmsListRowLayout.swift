import SwiftUI

/// A grid's `listRow` (docs/cms-list-styles.md, plan docs/plans/cms-list-rows.md):
/// which of its columns go in which part of a list row. Each `{column}` slot
/// draws that column's value with its own transform, format and style-rule
/// words; the site's list style says how each part looks. Nothing here knows
/// what the rows are.
struct CmsListRowLayout: Equatable {
    enum Leading: Equatable {
        /// A date column: the weekday over the day of the month.
        case date(String)
        /// A column whose picture draws.
        case image(String)
    }

    struct Line: Equatable {
        var text: String
        /// A column whose picture starts the line.
        var image: String?
    }

    var leading: Leading?
    var title: Line
    /// At most three.
    var lines: [Line]
    var trailing: Line?
    /// A column drawn as its chip.
    var chip: String?

    static let maxLines = 3

    /// Lenient: a row layout with no title is none; extra lines are dropped.
    init?(_ json: CmsJSON?) {
        guard let o = json?.objectValue, let title = Self.line(o["title"]) else { return nil }
        self.title = title
        lines = Array((o["lines"]?.arrayValue ?? []).compactMap(Self.line).prefix(Self.maxLines))
        trailing = Self.line(o["trailing"])
        chip = o.string("chip").flatMap { $0.isEmpty ? nil : $0 }
        if let l = o.object("leading") {
            if let date = l.string("date"), !date.isEmpty { leading = .date(date) }
            else if let image = l.string("image"), !image.isEmpty { leading = .image(image) }
        }
    }

    static func line(_ json: CmsJSON?) -> Line? {
        switch json {
        case .string(let text)?:
            return text.isEmpty ? nil : Line(text: text)
        case .object(let o)?:
            let text = o.string("text") ?? ""
            let image = o.string("image").flatMap { $0.isEmpty ? nil : $0 }
            return text.isEmpty && image == nil ? nil : Line(text: text, image: image)
        default:
            return nil
        }
    }

    /// The columns a layout names (slots, leading, chip, pictures), for
    /// looking up their presentation.
    var columnNames: Set<String> {
        var out = Set<String>()
        for line in [title] + lines + (trailing.map { [$0] } ?? []) {
            out.formUnion(Self.slots(line.text))
            if let image = line.image { out.insert(image) }
        }
        switch leading {
        case .date(let c)?, .image(let c)?: out.insert(c)
        case nil: break
        }
        if let chip { out.insert(chip) }
        return out
    }

    static func slots(_ text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\{([^{}]+)\}"#) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]).trimmingCharacters(in: .whitespaces) }
        }
    }

    /// A line's words for a row: each slot as its column draws it. A line
    /// whose slots are all empty is dropped (nil), as is a blank one.
    ///
    /// The words joining two slots show only between two values that are
    /// shown, and the words before the first slot or after the last only when
    /// that slot has one: "{job} • {role}" with no role is "KFC", not "KFC •".
    static func fill(_ text: String, row: [String: CmsJSON],
                     column: (String) -> CmsColumnPresentation) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\{([^{}]+)\}"#) else { return text }
        // Alternating: literal, slot, literal, slot, …, literal.
        var literals: [String] = []
        var values: [String] = []
        var last = text.startIndex
        for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(m.range, in: text), let name = Range(m.range(at: 1), in: text) else { continue }
            literals.append(String(text[last..<whole.lowerBound]))
            let slot = String(text[name]).trimmingCharacters(in: .whitespaces)
            values.append(slotText(slot, row: row, column: column))
            last = whole.upperBound
        }
        literals.append(String(text[last...]))
        if !values.isEmpty && values.allSatisfy(\.isEmpty) { return nil }
        var out = ""
        if values.isEmpty {
            out = literals[0]
        } else {
            let shown = values.indices.filter { !values[$0].isEmpty }
            if values[0].isEmpty == false { out += literals[0] }
            for (n, i) in shown.enumerated() {
                // Between two values shown: the words just before this one.
                if n > 0 { out += literals[i] }
                out += values[i]
            }
            if let lastShown = shown.last, lastShown == values.count - 1 { out += literals[values.count] }
        }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A slot's words: the column as it draws, or the built-in `{today}` and
    /// `{timeOfDay}` (with their own `|` format) when the row has no column
    /// of that name. A row's own column wins.
    static func slotText(_ slot: String, row: [String: CmsJSON],
                         column: (String) -> CmsColumnPresentation) -> String {
        let bar = slot.firstIndex(of: "|")
        let name = bar.map { String(slot[..<$0]).trimmingCharacters(in: .whitespaces) } ?? slot
        let format = bar.map { String(slot[slot.index(after: $0)...]) }.flatMap { $0.isEmpty ? nil : $0 }
        if row[name] == nil, let builtIn = CmsLevers.builtIn(name, format: format) { return builtIn }
        return column(slot).text(row)
    }

    /// The date block's two parts: the weekday (`EEE`) and the day of the
    /// month (`d`), in the viewer's time zone; a bare date is that day.
    /// A naive datetime counts as UTC unless `naiveIsLocal` (the column's
    /// `timezone: "local"`), as the web's grid reads it.
    static func dateParts(_ value: CmsJSON?, naiveIsLocal: Bool = false, locale: Locale = .current,
                          timeZone: TimeZone = .current) -> (weekday: String, day: String)? {
        guard let raw = value?.stringValue ?? (value.flatMap { $0 == .null ? nil : $0.displayString }),
              !raw.isEmpty, let date = CmsFormatValue.toDate(raw, naiveUTC: !naiveIsLocal, localZone: timeZone) else { return nil }
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.dateFormat = "EEE"
        let weekday = f.string(from: date)
        f.dateFormat = "d"
        return (weekday, f.string(from: date))
    }
}
