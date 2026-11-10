import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Day decorations for the Calendar Strip (`simpleCalendar`): the native twin
/// of `calendarDecorations.ts`. A circle behind a day's number coloured by
/// the most important value of the day's rows (`dayFill`), and one marker per
/// distinct key under the date (`markers`): an image from a chain, a colour
/// from the row, or a stable colour picked from a palette by the key.
///
/// Nothing here knows what the rows are: the priority is the order of
/// `dayFill.values`, the colours are the site's, the keys are the query's.
/// The palette, the hash and the parsing rules match the web's, and
/// `CmsCalendarDecorationsTests` holds the same cases as its vitest.
enum CmsCalendarDecorations {

    // MARK: - Props (decoded leniently: a bad entry drops itself)

    struct FillValue: Hashable {
        var value: String
        var color: String
        var label: String?
    }

    /// How a day's colour is drawn: a solid shape, a ring, a tint behind the
    /// number, a bar under it, or nothing (the colour still gates markers).
    enum FillStyle: String { case filled, ring, soft, underline, none }
    enum DayShape: String { case circle, rounded, square }
    /// The shape's side: authored points, or the column's width less 6.
    enum DaySize: Equatable { case fit, points(Double) }

    struct DayFill: Equatable {
        var column: String
        /// In priority order: the first that appears on a day colours it.
        var values: [FillValue]
        var style: FillStyle = .filled
        var shape: DayShape = .circle
        var size: DaySize = .fit
        /// nil: `auto`, black or white on a filled day, whichever reads.
        var textColor: String? = nil
        var ring: Bool { style == .ring }
    }

    /// The ring's colour when the day's rows give more than one.
    enum WhenSeveral: Equatable { case first, neutral, color(String) }

    /// A second channel on the same day (paydays): a ring outside the shape.
    struct DayRing: Equatable {
        var column: String
        var values: [FillValue]
        var colorColumn: String? = nil
        var whenSeveral: WhenSeveral = .first
        var width: Double = 2
        var gap: Double = 1
    }

    /// A day's ring: the colour to draw (`neutral`: the theme's on-surface
    /// colour), the value that decided it, and whether its rows held more
    /// than one colour of their own. The web's `DayRing`.
    struct RingMark: Hashable {
        static let neutral = "neutral"
        var color: String
        var value: String
        var several: Bool
    }

    struct ImageEntry: Equatable {
        var column: String
        /// nil: the row's value is an https address. Set: the site's image source.
        var source: String?
    }

    enum MarkerLook: String { case auto, dots, images }
    enum MarkerPlacement: String { case below, overlap, inside, corner }
    enum MarkerOverflow: String { case count, plus, none }
    enum ImageShape: String { case circle, rounded }
    /// What an `images` marker draws with no image: a neutral placeholder, a
    /// full-size disc in the row's colour, or that disc with the label's initial.
    enum ImageFallback: String { case placeholder, dot, initial }

    struct MarkerBorder: Equatable {
        var width: Double
        var color: String
    }

    struct Markers: Equatable {
        var keyColumn: String
        var colorColumn: String?
        var max: Int?
        var size: Double?
        var image: [ImageEntry]
        var look: MarkerLook = .auto
        var placement: MarkerPlacement = .below
        /// As written; negative stacks markers like coins. Drawn through
        /// `markerGap`, which stops it at half a marker.
        var gap: Double = 2
        var overflow: MarkerOverflow = .count
        var border: MarkerBorder? = nil
        var imageShape: ImageShape = .circle
        var onlyWithFill: Bool = false
        /// A colour or token behind an image marker (white, for logos with transparent edges).
        var imageBackground: String? = nil
        var imageFallback: ImageFallback = .placeholder
        /// The column whose text names a marker (its initial); else the key.
        var labelColumn: String? = nil
        /// The column holding the row's icon (an SF Symbol name): a badge, the icon on a
        /// disc in the marker's colour when no picture loads (the web's `iconColumn`).
        var iconColumn: String? = nil

        /// Whether markers draw images (or their placeholders) rather than plain dots; icons are sized as images are.
        var usesImages: Bool { look == .images || (look == .auto && (!image.isEmpty || iconColumn != nil)) }
    }

    /// The block's `todayStyle`. `auto` is the earlier look: the number bold,
    /// and a ring when the day has no filled or soft colour and isn't selected.
    enum TodayStyle: String { case auto, bold, ring, fill, dot }
    /// The block's `selectionStyle`. `auto` is the earlier look: a plain day
    /// filled with the selection colour, a filled day ringed outside.
    enum SelectionStyle: String { case auto, ring, fill }

    /// Month view: the other months' days in the first and last weeks, drawn
    /// dimmed (`show`, as before) or left as blank cells (`hide`, WAC's months).
    enum OutsideDays: String { case show, hide }
    /// Month view: the weeks the month spans, 4 to 6 (`fit`, as before), or
    /// always six (`six`), so the calendar's height never changes.
    enum MonthRows: String { case fit, six }

    /// The month view's grid (cmsCalendarDayStyles.ts `resolveMonthGrid`).
    struct MonthGrid: Equatable {
        var outsideDays: OutsideDays = .show
        var rows: MonthRows = .fit
    }

    static let defaultMax = 2

    private static func fillValues(_ raw: CmsJSON?) -> [FillValue] {
        guard case .array(let list)? = raw else { return [] }
        var values: [FillValue] = []
        for entry in list {
            guard let e = entry.objectValue, let value = cellText(e["value"]),
                  let color = e["color"]?.stringValue, isColor(color) else { continue }
            values.append(FillValue(value: value, color: color.trimmingCharacters(in: .whitespaces), label: text(e["label"])))
        }
        return values
    }

    /// A positive, finite number of points.
    private static func points(_ v: CmsJSON?) -> Double? {
        v?.doubleValue.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    /// A colour or token, trimmed; nil for anything else.
    private static func color(_ v: CmsJSON?) -> String? {
        guard let c = v?.stringValue, isColor(c) else { return nil }
        return c.trimmingCharacters(in: .whitespaces)
    }

    static func dayFill(_ raw: CmsJSON?) -> DayFill? {
        guard let obj = raw?.objectValue, let column = text(obj["column"]) else { return nil }
        let values = fillValues(obj["values"])
        guard !values.isEmpty else { return nil }
        let size: DaySize = points(obj["size"]).map { .points($0) } ?? .fit
        return DayFill(column: column, values: values,
                       style: obj["style"]?.stringValue.flatMap(FillStyle.init(rawValue:)) ?? .filled,
                       shape: obj["shape"]?.stringValue.flatMap(DayShape.init(rawValue:)) ?? .circle,
                       size: size,
                       textColor: color(obj["textColor"]))
    }

    static func dayRing(_ raw: CmsJSON?) -> DayRing? {
        guard let obj = raw?.objectValue, let column = text(obj["column"]) else { return nil }
        let values = fillValues(obj["values"])
        guard !values.isEmpty else { return nil }
        let several: WhenSeveral
        switch obj["whenSeveral"]?.stringValue {
        case "neutral": several = .neutral
        case let c? where isColor(c): several = .color(c.trimmingCharacters(in: .whitespaces))
        default: several = .first
        }
        return DayRing(column: column, values: values, colorColumn: text(obj["colorColumn"]), whenSeveral: several,
                       width: points(obj["width"]) ?? 2,
                       gap: obj["gap"]?.doubleValue.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? 1)
    }

    static func todayStyle(_ raw: CmsJSON?) -> TodayStyle { raw?.stringValue.flatMap(TodayStyle.init(rawValue:)) ?? .auto }
    static func selectionStyle(_ raw: CmsJSON?) -> SelectionStyle { raw?.stringValue.flatMap(SelectionStyle.init(rawValue:)) ?? .auto }

    /// The block's `outsideDays` and `monthRows`; an unknown value is the default.
    static func monthGrid(outsideDays: CmsJSON?, monthRows: CmsJSON?) -> MonthGrid {
        MonthGrid(outsideDays: outsideDays?.stringValue.flatMap(OutsideDays.init(rawValue:)) ?? .show,
                  rows: monthRows?.stringValue.flatMap(MonthRows.init(rawValue:)) ?? .fit)
    }

    /// The corner radius for a shape of `side` points: a circle half, a rounded square a quarter, a square none.
    static func shapeRadius(_ shape: DayShape, side: Double) -> Double {
        switch shape {
        case .circle: return side / 2
        case .rounded: return side / 4
        case .square: return 0
        }
    }

    /// `fit`: the cell's shorter side less 6. A native day cell is the
    /// column's width by a 38 pt row (the 32 pt shape before these options,
    /// with room for today's ring), so a phone's default is unchanged.
    static func shapeSide(_ size: DaySize, columnWidth: Double) -> Double {
        switch size {
        case .points(let p): return p
        case .fit: return max(16, min(columnWidth, 38) - 6)
        }
    }

    /// WCAG relative luminance of an sRGB colour (components 0...1).
    static func luminance(r: Double, g: Double, b: Double) -> Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// `auto` text on a fill: black above 0.179 luminance, else white (the web's `dayTextOn`).
    static func blackTextOn(r: Double, g: Double, b: Double) -> Bool {
        luminance(r: r, g: g, b: b) > 0.179
    }

    static func imageChain(_ raw: CmsJSON?) -> [ImageEntry] {
        guard case .array(let list)? = raw else { return [] }
        return list.compactMap { entry in
            guard let e = entry.objectValue, let column = text(e["column"]) else { return nil }
            guard let source = e["source"], source != .null else { return ImageEntry(column: column, source: nil) }
            return text(source).map { ImageEntry(column: column, source: $0) }
        }
    }

    static func markers(_ raw: CmsJSON?) -> Markers? {
        guard let obj = raw?.objectValue, let key = text(obj["keyColumn"]) else { return nil }
        let max = obj["max"]?.doubleValue.flatMap { $0.isFinite && $0 >= 0 ? Int($0.rounded(.down)) : nil }
        var border: MarkerBorder?
        if let b = obj["border"]?.objectValue, let w = points(b["width"]), let c = color(b["color"]) {
            border = MarkerBorder(width: w, color: c)
        }
        return Markers(keyColumn: key, colorColumn: text(obj["colorColumn"]), max: max, size: points(obj["size"]),
                       image: imageChain(obj["image"]),
                       look: obj["look"]?.stringValue.flatMap(MarkerLook.init(rawValue:)) ?? .auto,
                       placement: obj["placement"]?.stringValue.flatMap(MarkerPlacement.init(rawValue:)) ?? .below,
                       gap: obj["gap"]?.doubleValue.flatMap { $0.isFinite ? $0 : nil } ?? 2,
                       overflow: obj["overflow"]?.stringValue.flatMap(MarkerOverflow.init(rawValue:)) ?? .count,
                       border: border,
                       imageShape: obj["imageShape"]?.stringValue.flatMap(ImageShape.init(rawValue:)) ?? .circle,
                       onlyWithFill: obj["onlyWithFill"]?.boolValue ?? false,
                       imageBackground: color(obj["imageBackground"]),
                       imageFallback: obj["imageFallback"]?.stringValue.flatMap(ImageFallback.init(rawValue:)) ?? .placeholder,
                       labelColumn: text(obj["labelColumn"]),
                       iconColumn: text(obj["iconColumn"]))
    }

    /// The space between markers: as written, but never overlapping past half
    /// a marker, so each still shows. Negative draws each over the one before
    /// it, like stacked coins (WAC's logos: 19 with −5).
    static func markerGap(_ m: Markers, size: Double) -> Double {
        max(m.gap, -size / 2)
    }

    /// The letter an `initial` fallback draws: the label's first letter or
    /// digit, upper-cased; else its first character (the web's `markerInitial`).
    static func markerInitial(_ label: String) -> String {
        let t = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ch = t.first(where: { $0.isLetter || $0.isNumber }) ?? t.first else { return "" }
        return String(ch).uppercased()
    }

    /// Marker diameter: the authored size, else 14 pt with images and the block's dot size without.
    static func markerSize(_ m: Markers, dotSize: Double) -> Double {
        m.size ?? (m.usesImages ? 14 : dotSize)
    }

    /// A marker's dot when it has no image: the full size for plain dots, 60%
    /// in an image's slot so dots read as smaller than logos.
    static func markerDot(_ m: Markers, size: Double) -> Double {
        m.look == .auto && !m.image.isEmpty ? max(4, (size * 0.6).rounded()) : size
    }

    /// Pixels asked of an image source: three times the drawn size, so every
    /// screen (and the web) shares one cached image.
    static func imageRequestSize(_ drawn: Double) -> Int {
        min(256, max(16, Int((drawn * 3).rounded())))
    }

    private static func text(_ v: CmsJSON?) -> String? {
        guard let s = v?.stringValue?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        return s
    }

    // MARK: - Colours

    /// Mirror of COLOR_PATHS' keys in colorTokens.ts (bar `color.gradient`, a fill).
    static let colorTokens: Set<String> = [
        "color.primary", "color.primary.contrast", "color.secondary", "color.secondary.contrast",
        "color.error", "color.warning", "color.info", "color.success",
        "color.text.primary", "color.text.secondary", "color.text.disabled",
        "color.background", "color.paper", "color.divider", "color.common.white", "color.common.black",
        "color.accent", "color.tint", "color.surfaceMuted",
        "color.success.soft", "color.warning.soft", "color.error.soft", "color.primary.soft",
    ]

    /// `#rgb`, `#rrggbb` or a colour token.
    static func isColor(_ value: String?) -> Bool {
        guard let v = value?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return false }
        if colorTokens.contains(v) { return true }
        guard v.hasPrefix("#") else { return false }
        let hex = v.dropFirst()
        return (hex.count == 3 || hex.count == 6) && hex.allSatisfy(\.isHexDigit)
    }

    /// Colours for keys with none of their own, the web's MARKER_PALETTE in
    /// the same order: mid tones that read on light and dark alike.
    static let palette: [String] = [
        "#3B82F6", // theme-exempt: data palette, blue
        "#F97316", // theme-exempt: data palette, orange
        "#10B981", // theme-exempt: data palette, green
        "#A855F7", // theme-exempt: data palette, purple
        "#EF4444", // theme-exempt: data palette, red
        "#14B8A6", // theme-exempt: data palette, teal
        "#EAB308", // theme-exempt: data palette, yellow
        "#EC4899", // theme-exempt: data palette, pink
        "#6366F1", // theme-exempt: data palette, indigo
        "#84CC16", // theme-exempt: data palette, lime
    ]

    /// FNV-1a (32-bit) over UTF-16 code units, as the web's `stableHash`.
    static func stableHash(_ key: String) -> UInt32 {
        var h: UInt32 = 0x811c9dc5
        for unit in key.utf16 {
            h ^= UInt32(unit)
            h = h &* 0x01000193
        }
        return h
    }

    static func paletteColor(_ key: String) -> String {
        palette[Int(stableHash(key) % UInt32(palette.count))]
    }

    // MARK: - Rows → days

    /// A cell as text for matching: whole numbers without `.0`; null and empty as nothing.
    static func cellText(_ v: CmsJSON?) -> String? {
        switch v {
        case .string(let s)?: return s.isEmpty ? nil : s
        case .number(let n)? where n.isFinite: return CmsJSON.number(n).displayString
        case .bool(let b)?: return b ? "true" : "false"
        default: return nil
        }
    }

    private static let gregorian = Calendar(identifier: .gregorian)

    private static let zoned: [ISO8601DateFormatter] = {
        let a = ISO8601DateFormatter()
        a.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let b = ISO8601DateFormatter()
        b.formatOptions = [.withInternetDateTime]
        return [a, b]
    }()

    private static let unzoned: [DateFormatter] = ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm"].map {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = gregorian
        f.dateFormat = $0
        return f
    }

    /// The key (`yyyy-MM-dd`) of a calendar day, where the calendar is.
    static func dayKey(_ date: Date) -> String {
        let c = gregorian.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The local day a cell falls on. A date (`2026-10-27`) is that day as
    /// written; a datetime counts on the day it is where the calendar is.
    static func localDayKey(_ v: CmsJSON?) -> String? {
        guard let s = v.map(\.displayString)?.trimmingCharacters(in: .whitespaces), s.count >= 10 else { return nil }
        let datePart = String(s.prefix(10))
        let isDate = datePart.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
        if s.count == 10 { return isDate ? datePart : nil }
        for f in zoned { if let d = f.date(from: s) { return dayKey(d) } }
        for f in unzoned { if let d = f.date(from: s) { return dayKey(d) } }
        return isDate ? datePart : nil
    }

    enum ImageCandidate: Equatable, Hashable {
        case url(String)
        case source(String, value: String)
    }

    struct DayMarker: Hashable {
        var key: String
        /// What names it: the row's `labelColumn` text, else the key.
        var label: String = ""
        /// The row's own colour when valid, else the palette's.
        var color: String
        var fromPalette: Bool
        var images: [ImageCandidate]
        /// The row's icon (`iconColumn`), drawn on a disc when no picture loads.
        var icon: String? = nil
    }

    struct Day: Hashable {
        var fill: FillValue?
        var markers: [DayMarker]
        /// Distinct keys beyond `max` ("+n").
        var overflow: Int
        var ring: RingMark? = nil
    }

    /// What a row's image chain offers, in order: https addresses, source lookups by value. Empty values skip.
    static func imageCandidates(_ row: [String: CmsJSON], _ chain: [ImageEntry]) -> [ImageCandidate] {
        chain.compactMap { entry in
            guard let value = cellText(row[entry.column])?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
            if let source = entry.source { return .source(source, value: value) }
            guard value.lowercased().hasPrefix("https://"), !value.contains(where: \.isWhitespace) else { return nil }
            return .url(value)
        }
    }

    /// Each day's shape, ring and markers, keyed by local day. Days with none are left out.
    static func decorate(rows: [[String: CmsJSON]], dateColumn: String, fill: DayFill?, markers: Markers?,
                         ring: DayRing? = nil) -> [String: Day] {
        guard !dateColumn.isEmpty, fill != nil || markers != nil || ring != nil else { return [:] }
        var rank: [String: Int] = [:]
        for (i, v) in (fill?.values ?? []).enumerated() where rank[v.value] == nil { rank[v.value] = i }
        var ringRank: [String: Int] = [:]
        for (i, v) in (ring?.values ?? []).enumerated() where ringRank[v.value] == nil { ringRank[v.value] = i }
        var best: [String: Int] = [:]
        // The ring: the first listed value on the day decides; of the rows
        // holding it, the first's own colour (`colorColumn`) and how many
        // distinct own colours they hold (trimmed, lower-cased).
        var ringBest: [String: Int] = [:]
        var ringFirst: [String: String] = [:]
        var ringOwn: [String: Set<String>] = [:]
        var keys: [String: [(String, [String: CmsJSON])]] = [:]
        var seen: [String: Set<String>] = [:]

        for row in rows {
            guard let day = localDayKey(row[dateColumn]) else { continue }
            if let fill, let v = cellText(row[fill.column]), let r = rank[v], r < (best[day] ?? .max) {
                best[day] = r
            }
            if let ring, let v = cellText(row[ring.column]), let r = ringRank[v], r <= (ringBest[day] ?? .max) {
                if r < (ringBest[day] ?? .max) {
                    ringBest[day] = r
                    ringFirst[day] = nil
                    ringOwn[day] = []
                }
                if let own = ring.colorColumn.flatMap({ row[$0]?.stringValue }), isColor(own) {
                    let c = own.trimmingCharacters(in: .whitespaces)
                    if ringFirst[day] == nil { ringFirst[day] = c }
                    ringOwn[day, default: []].insert(c.lowercased())
                }
            }
            if let markers, let key = cellText(row[markers.keyColumn]), !(seen[day]?.contains(key) ?? false) {
                seen[day, default: []].insert(key)
                keys[day, default: []].append((key, row))
            }
        }

        let max = markers?.max ?? defaultMax
        // `look: dots` never asks for an image, whatever the chain says.
        let chain = markers?.look == .dots ? [] : (markers?.image ?? [])
        var out: [String: Day] = [:]
        for day in Set(best.keys).union(keys.keys).union(ringBest.keys) {
            let dayFill = best[day].flatMap { fill?.values[$0] }
            // `onlyWithFill`: markers only on a day that has a fill colour.
            let all = markers?.onlyWithFill == true && dayFill == nil ? [] : (keys[day] ?? [])
            let shown = all.prefix(max).map { key, row -> DayMarker in
                let own = markers?.colorColumn.flatMap { row[$0]?.stringValue }
                let valid = isColor(own)
                let label = markers?.labelColumn.flatMap { cellText(row[$0])?.trimmingCharacters(in: .whitespacesAndNewlines) }
                return DayMarker(key: key,
                                 label: label.flatMap { $0.isEmpty ? nil : $0 } ?? key,
                                 color: valid ? own!.trimmingCharacters(in: .whitespaces) : paletteColor(key),
                                 fromPalette: !valid,
                                 images: imageCandidates(row, chain),
                                 icon: markers?.look == .dots ? nil : markers?.iconColumn
                                    .flatMap { cellText(row[$0])?.trimmingCharacters(in: .whitespacesAndNewlines) }
                                    .flatMap { $0.isEmpty ? nil : $0 })
            }
            var mark: RingMark?
            if let ring, let r = ringBest[day] {
                let several = (ringOwn[day]?.count ?? 0) > 1
                var color = ringFirst[day] ?? ring.values[r].color
                switch (several, ring.whenSeveral) {
                case (true, .neutral): color = RingMark.neutral
                case (true, .color(let c)): color = c
                default: break
                }
                mark = RingMark(color: color, value: ring.values[r].value, several: several)
            }
            guard dayFill != nil || !all.isEmpty || mark != nil else { continue }
            out[day] = Day(fill: dayFill, markers: Array(shown), overflow: all.count - shown.count, ring: mark)
        }
        return out
    }

    /// What follows the shown markers: "+n", "+", or nothing (the web's `markerOverflowText`).
    static func overflowText(_ hidden: Int, _ overflow: MarkerOverflow) -> String? {
        guard hidden > 0, overflow != .none else { return nil }
        return overflow == .plus ? "+" : "+\(hidden)"
    }

    // MARK: - Markers in a day's cell (cmsCalendarDayStyles.ts)

    /// The smallest a calendar's markers are drawn to fit its columns, against
    /// their size; below it a day shows fewer markers and a larger "+n".
    static let minMarkerScale = 0.75

    /// What a row of markers measures from, in points (`MarkerRowMetrics`).
    struct MarkerRowMetrics: Equatable {
        var size: Double
        var gap: Double
        /// A dot's diameter: the "+" is drawn from it.
        var dot: Double
        var overflow: MarkerOverflow
        /// The ring outside each marker; 0 for none, and for dots.
        var border: Double

        /// The markers, their gap and the dot at a scale (the overflow's font follows them).
        func scaled(_ scale: Double) -> MarkerRowMetrics {
            scale == 1 ? self : MarkerRowMetrics(size: size * scale, gap: gap * scale, dot: dot * scale,
                                                 overflow: overflow, border: border)
        }
    }

    /// A block's markers measured at `size`: the resolved gap, the dot the "+"
    /// is drawn from (60% of an image's size, as the web's), and the ring,
    /// which only image markers draw.
    static func markerRowMetrics(_ m: Markers, size: Double) -> MarkerRowMetrics {
        MarkerRowMetrics(size: size, gap: markerGap(m, size: size),
                         dot: m.usesImages ? max(4, (size * 0.6).rounded()) : size,
                         overflow: m.overflow, border: m.usesImages ? (m.border?.width ?? 0) : 0)
    }

    /// A row's width: `shown` markers `gap` apart, the rings outside the ends,
    /// then the overflow for `hidden`, 2 points after coins (else `gap`), its
    /// width estimated at 0.6 of its font a character (`markerRowWidth`).
    static func markerRowWidth(shown: Int, hidden: Int, _ m: MarkerRowMetrics) -> Double {
        let markers = shown > 0 ? Double(shown) * m.size + Double(shown - 1) * m.gap + 2 * m.border : 0
        guard let text = overflowText(hidden, m.overflow) else { return markers }
        return markers + (shown > 0 ? (m.gap < 0 ? 2 : m.gap) : 0) + 0.6 * overflowFont(m) * Double(text.count)
    }

    /// The overflow's font size: "+" at max(8, round(dot × 1.6)), "+n" at max(9, round(size × 0.8)).
    static func overflowFont(_ m: MarkerRowMetrics) -> Double {
        m.overflow == .plus ? max(8, (m.dot * 1.6).rounded()) : max(9, (m.size * 0.8).rounded())
    }

    /// The scale for every marker of a calendar in cells `cellWidth` wide: 1,
    /// or less so `max` markers fit side by side, never below `minMarkerScale`
    /// (`markerScale`). The rings outside the markers don't scale.
    static func markerScale(cellWidth: Double, max maxShown: Int, _ m: MarkerRowMetrics) -> Double {
        let n = Double(Swift.max(1, maxShown))
        let scalable = n * m.size + (n - 1) * m.gap
        guard cellWidth > 0, scalable > 0, scalable + 2 * m.border > cellWidth else { return 1 }
        return Swift.max(minMarkerScale, Swift.min(1, (cellWidth - 2 * m.border) / scalable))
    }

    /// How many of a day's `count` markers a cell `cellWidth` wide shows at
    /// `scale`: up to `max`, one fewer while they and the overflow after them
    /// are wider than the cell (`markersShown`). A cell of no known width
    /// shows up to `max`.
    static func markersShown(count: Int, max maxShown: Int, cellWidth: Double, _ m: MarkerRowMetrics,
                             scale: Double = 1) -> Int {
        var shown = Swift.max(0, Swift.min(count, maxShown))
        guard cellWidth > 0 else { return shown }
        let at = m.scaled(scale)
        while shown > 0, markerRowWidth(shown: shown, hidden: count - shown, at) > cellWidth + 0.5 { shown -= 1 }
        return shown
    }

    // MARK: - Image chain

    /// The first candidate that loads, or nil (the marker then draws its dot).
    static func resolveChain<T>(_ candidates: [ImageCandidate], size: Int,
                                load: (ImageCandidate, Int) async -> T?) async -> T? {
        for c in candidates {
            if let image = await load(c, size) { return image }
        }
        return nil
    }

    static func cacheKey(_ c: ImageCandidate, size: Int) -> String {
        switch c {
        case .url(let u): return "url|\(u)"
        case .source(let s, let v): return "src|\(s)|\(size)|\(v)"
        }
    }
}

#if canImport(UIKit)
typealias CmsPlatformImage = UIImage
#elseif canImport(AppKit)
typealias CmsPlatformImage = NSImage
#endif

/// Markers' images for one page, in memory, per size. Each candidate loads
/// once; a 404 is remembered for the whole session (`missing`) and never
/// asked for again; any other failure is remembered by this page only.
@MainActor
final class CmsMarkerImageCache {
    /// Answers for one candidate: the image, or nil with whether it was a 404.
    typealias Fetch = (CmsCalendarDecorations.ImageCandidate, Int) async -> (CmsPlatformImage?, notFound: Bool)

    static var missing: Set<String> = []
    private var entries: [String: Task<CmsPlatformImage?, Never>] = [:]
    private let fetch: Fetch

    init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    /// Loads through the page's client: a source by `GET …/images/:source`
    /// with the page's credentials, an https address directly.
    convenience init(client: CmsClient, cmsId: String) {
        self.init { candidate, size in
            do {
                let data: Data
                switch candidate {
                case .source(let source, let value):
                    var allowed = CharacterSet.urlQueryAllowed
                    allowed.remove(charactersIn: "&=+?#")
                    let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                    let path = "/v1/cms-definitions/\(cmsId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? cmsId)"
                        + "/images/\(source.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? source)?v=\(v)&size=\(size)"
                    data = try await client.raw(path)
                case .url(let address):
                    guard let url = URL(string: address) else { return (nil, true) }
                    let (body, response) = try await URLSession.shared.data(from: url)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        return (nil, http.statusCode == 404)
                    }
                    data = body
                }
                return (CmsPlatformImage(data: data), false)
            } catch CmsClientError.http(404, _) {
                return (nil, true)
            } catch {
                return (nil, false)
            }
        }
    }

    /// One cache per rendered page (its runtime), shared by every calendar on it, gone with the page.
    private static let pages = NSMapTable<CmsRuntime, CmsMarkerImageCache>.weakToStrongObjects()

    static func forPage(_ runtime: CmsRuntime) -> CmsMarkerImageCache {
        if let cache = pages.object(forKey: runtime) { return cache }
        let cache = CmsMarkerImageCache(client: runtime.client, cmsId: runtime.cmsId)
        pages.setObject(cache, forKey: runtime)
        return cache
    }

    func image(_ candidate: CmsCalendarDecorations.ImageCandidate, size: Int) async -> CmsPlatformImage? {
        let key = CmsCalendarDecorations.cacheKey(candidate, size: size)
        if Self.missing.contains(key) { return nil }
        if let task = entries[key] { return await task.value }
        let fetch = self.fetch
        let task = Task<CmsPlatformImage?, Never> { @MainActor in
            let (image, notFound) = await fetch(candidate, size)
            if notFound { Self.missing.insert(key) }
            return image
        }
        entries[key] = task
        return await task.value
    }

    func resolve(_ candidates: [CmsCalendarDecorations.ImageCandidate], size: Int) async -> CmsPlatformImage? {
        await CmsCalendarDecorations.resolveChain(candidates, size: size) { c, s in await self.image(c, size: s) }
    }
}

extension Image {
    init(cmsPlatformImage image: CmsPlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: image)
        #else
        self.init(nsImage: image)
        #endif
    }
}
