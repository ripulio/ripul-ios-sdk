import XCTest
@testable import RipulAgent

/// The Calendar Strip's day styles against the table both renderers share:
/// `chrome-extension/packages/shared-types/src/cmsCalendarDayStyles.cases.json`
/// (the web runs the same file in cmsCalendarDayStyles.test.ts). `resolve`
/// cases hold the options with their defaults; `days` cases hold each day's
/// fill value, ring, shown marker keys and overflow text.
final class CmsCalendarDayStylesTests: XCTestCase {
    typealias D = CmsCalendarDecorations

    private static let table: [String: Any] = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("chrome-extension/packages/shared-types/src/cmsCalendarDayStyles.cases.json")
        let data = try! Data(contentsOf: url)
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }()

    private func json(_ any: Any?) -> CmsJSON? {
        guard let any else { return nil }
        let data = try! JSONSerialization.data(withJSONObject: any, options: [.fragmentsAllowed])
        return try! JSONDecoder().decode(CmsJSON.self, from: data)
    }

    private func cases(_ key: String) -> [[String: Any]] {
        let list = Self.table[key] as? [[String: Any]] ?? []
        XCTAssertFalse(list.isEmpty, "the table has \(key) cases")
        return list
    }

    // MARK: resolve

    /// The native options as the table writes the resolved object.
    private func resolved(_ props: [String: Any], hasImageChain: Bool) -> [String: Any] {
        var markersRaw = props["markers"] as? [String: Any]
        if hasImageChain, markersRaw != nil, markersRaw?["image"] == nil {
            markersRaw?["image"] = [["column": "logo"]]
        }
        // A dayFill without values is still read for its look, as the web.
        var fillRaw = props["dayFill"] as? [String: Any] ?? [:]
        fillRaw["column"] = fillRaw["column"] ?? "x"
        fillRaw["values"] = [["value": "x", "color": "#000"]]
        let fill = D.dayFill(json(fillRaw))!
        let ring = D.dayRing(json(props["dayRing"]))
        let markers = D.markers(json(markersRaw))

        var out: [String: Any] = [
            "fill": [
                "style": fill.style.rawValue,
                "shape": fill.shape.rawValue,
                "size": { if case .points(let p) = fill.size { return p as Any } else { return "fit" } }(),
                "textColor": fill.textColor ?? "auto",
            ] as [String: Any],
            "today": D.todayStyle(json(props["todayStyle"])).rawValue,
            "selection": D.selectionStyle(json(props["selectionStyle"])).rawValue,
            "ring": NSNull(),
            "markers": NSNull(),
        ]
        if let ring {
            var r: [String: Any] = [
                "column": ring.column,
                "values": ring.values.map { v -> [String: Any] in
                    var e: [String: Any] = ["value": v.value, "color": v.color]
                    if let l = v.label { e["label"] = l }
                    return e
                },
                "width": ring.width, "gap": ring.gap,
            ]
            switch ring.whenSeveral {
            case .first: r["whenSeveral"] = "first"
            case .neutral: r["whenSeveral"] = "neutral"
            case .color(let c): r["whenSeveral"] = c
            }
            if let c = ring.colorColumn { r["colorColumn"] = c }
            out["ring"] = r
        }
        if let m = markers {
            let size = D.markerSize(m, dotSize: 8)
            var r: [String: Any] = [
                "look": m.look.rawValue,
                "size": size,
                "placement": m.placement.rawValue,
                "gap": D.markerGap(m, size: size),
                "max": m.max ?? D.defaultMax,
                "overflow": m.overflow.rawValue,
                "border": m.border.map { ["width": $0.width, "color": $0.color] as [String: Any] } ?? NSNull(),
                "imageShape": m.imageShape.rawValue,
                "onlyWithFill": m.onlyWithFill,
                "imageBackground": m.imageBackground ?? NSNull(),
                "imageFallback": m.imageFallback.rawValue,
            ]
            if let l = m.labelColumn { r["labelColumn"] = l }
            out["markers"] = r
        }
        return out
    }

    func testResolveCases() {
        for c in cases("resolve") {
            let name = c["name"] as? String ?? "?"
            let got = resolved(c["props"] as? [String: Any] ?? [:], hasImageChain: c["hasImageChain"] as? Bool ?? false)
            XCTAssertEqual(NSDictionary(dictionary: got), NSDictionary(dictionary: c["expect"] as? [String: Any] ?? [:]), name)
        }
    }

    // MARK: days

    func testDayCases() {
        for c in cases("days") {
            let name = c["name"] as? String ?? "?"
            let props = c["props"] as? [String: Any] ?? [:]
            let rows = (c["rows"] as? [[String: Any]] ?? []).map { row in row.mapValues { json($0) ?? .null } }
            let markers = D.markers(json(props["markers"]))
            let days = D.decorate(rows: rows, dateColumn: c["dateColumn"] as? String ?? "",
                                  fill: D.dayFill(json(props["dayFill"])), markers: markers,
                                  ring: D.dayRing(json(props["dayRing"])))
            var got: [String: Any] = [:]
            for (key, day) in days {
                got[key] = [
                    "fill": day.fill?.value ?? NSNull(),
                    "ring": day.ring.map { ["color": $0.color, "value": $0.value, "several": $0.several] as [String: Any] } ?? NSNull(),
                    "markers": day.markers.map(\.key),
                    "overflow": D.overflowText(day.overflow, markers?.overflow ?? .count) ?? NSNull(),
                ] as [String: Any]
            }
            XCTAssertEqual(NSDictionary(dictionary: got), NSDictionary(dictionary: c["expect"] as? [String: Any] ?? [:]), name)
        }
    }

    // MARK: initials

    func testInitialCases() {
        let list = Self.table["initials"] as? [[String]] ?? []
        XCTAssertFalse(list.isEmpty, "the table has initials cases")
        for pair in list where pair.count == 2 {
            XCTAssertEqual(D.markerInitial(pair[0]), pair[1], pair[0])
        }
        XCTAssertEqual(D.markerInitial(""), "")
    }

    func testLabelIsTheLabelColumnElseTheKey() {
        let m = D.markers(json(["keyColumn": "job_id", "labelColumn": "job", "look": "images", "imageFallback": "initial"]))!
        let days = D.decorate(rows: [
            ["d": .string("2026-10-01"), "job_id": .number(29), "job": .string("Corner Shop")],
            ["d": .string("2026-10-01"), "job_id": .number(31), "job": .string("  ")],
        ], dateColumn: "d", fill: nil, markers: m)
        XCTAssertEqual(days["2026-10-01"]?.markers.map(\.label), ["Corner Shop", "31"])
        XCTAssertEqual(D.markerInitial("Corner Shop"), "C")
    }

    // MARK: the month's grid

    func testMonthGridResolveCases() {
        let table = Self.table["monthGrid"] as? [String: Any] ?? [:]
        let list = table["resolve"] as? [[String: Any]] ?? []
        XCTAssertFalse(list.isEmpty, "the table has monthGrid.resolve cases")
        for c in list {
            let props = c["props"] as? [String: Any] ?? [:]
            let grid = D.monthGrid(outsideDays: json(props["outsideDays"]), monthRows: json(props["monthRows"]))
            let expect = c["expect"] as? [String: String] ?? [:]
            XCTAssertEqual(grid.outsideDays.rawValue, expect["outsideDays"], c["name"] as? String ?? "?")
            XCTAssertEqual(grid.rows.rawValue, expect["monthRows"], c["name"] as? String ?? "?")
        }
    }

    /// Which weeks a month draws, as the web's monthGridShape: rows, and the
    /// grid's first and last days in whole weeks.
    func testMonthGridShapeCases() {
        let table = Self.table["monthGrid"] as? [String: Any] ?? [:]
        let list = table["shapes"] as? [[String: Any]] ?? []
        XCTAssertFalse(list.isEmpty, "the table has monthGrid.shapes cases")
        for c in list {
            let name = c["name"] as? String ?? "?"
            var cal = Calendar(identifier: .gregorian)
            cal.locale = Locale(identifier: "en_GB")
            cal.timeZone = TimeZone(identifier: "Europe/London")!
            cal.firstWeekday = (c["weekStartsOn"] as? Int ?? 1) + 1
            let gridRaw = c["grid"] as? [String: String] ?? [:]
            let grid = D.monthGrid(outsideDays: json(gridRaw["outsideDays"]), monthRows: json(gridRaw["monthRows"]))
            let date = cal.date(from: DateComponents(year: c["year"] as? Int, month: c["month"] as? Int, day: 15, hour: 12))!
            let starts = CmsCalendarPaging.weekStarts(ofMonth: date, calendar: cal, grid: grid,
                                                     showWeekends: c["showWeekends"] as? Bool ?? true)
            let formatter = DateFormatter()
            formatter.calendar = cal
            formatter.timeZone = cal.timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            let expect = c["expect"] as? [String: Any] ?? [:]
            XCTAssertEqual(starts.count, expect["weeks"] as? Int, name)
            XCTAssertEqual(starts.first.map(formatter.string(from:)), expect["first"] as? String, name)
            XCTAssertEqual(starts.last.flatMap { cal.date(byAdding: .day, value: 6, to: $0) }.map(formatter.string(from:)),
                           expect["last"] as? String, name)
        }
    }

    // MARK: markers in a cell

    /// A calendar's marker scale and each day's markers shown, as the web's
    /// markerScale and markersShown.
    func testMarkerFitCases() {
        let list = Self.table["markerFit"] as? [[String: Any]] ?? []
        XCTAssertFalse(list.isEmpty, "the table has markerFit cases")
        for c in list {
            let name = c["name"] as? String ?? "?"
            let raw = c["metrics"] as? [String: Any] ?? [:]
            let m = D.MarkerRowMetrics(size: raw["size"] as? Double ?? 0, gap: raw["gap"] as? Double ?? 0,
                                       dot: raw["dot"] as? Double ?? 0,
                                       overflow: D.MarkerOverflow(rawValue: raw["overflow"] as? String ?? "") ?? .count,
                                       border: raw["border"] as? Double ?? 0)
            let max = c["max"] as? Int ?? 0
            let cell = c["cellWidth"] as? Double ?? 0
            let expect = c["expect"] as? [String: Any] ?? [:]
            let scale = D.markerScale(cellWidth: cell, max: max, m)
            XCTAssertEqual(scale, expect["scale"] as? Double ?? -1, accuracy: 0.001, name)
            for pair in expect["shown"] as? [[Int]] ?? [] where pair.count == 2 {
                XCTAssertEqual(D.markersShown(count: pair[0], max: max, cellWidth: cell, m, scale: scale), pair[1],
                               "\(name): \(pair[0]) markers")
            }
        }
    }

    func testRowMetricsTakeTheWebsDotAndRingOnlyForImages() {
        let coins = D.markers(json(["keyColumn": "j", "look": "images", "size": 19, "gap": -5,
                                    "border": ["width": 1, "color": "#fff"]]))!
        XCTAssertEqual(D.markerRowMetrics(coins, size: 19),
                       D.MarkerRowMetrics(size: 19, gap: -5, dot: 11, overflow: .count, border: 1))
        let dots = D.markers(json(["keyColumn": "j", "look": "dots", "size": 7, "border": ["width": 1, "color": "#fff"]]))!
        XCTAssertEqual(D.markerRowMetrics(dots, size: 7),
                       D.MarkerRowMetrics(size: 7, gap: 2, dot: 7, overflow: .count, border: 0))
        XCTAssertEqual(D.markerRowWidth(shown: 3, hidden: 0, D.markerRowMetrics(coins, size: 19)), 49)
    }

    // MARK: the rest of the shared rules

    func testShapeRadiusAndFit() {
        XCTAssertEqual(D.shapeRadius(.circle, side: 32), 16)
        XCTAssertEqual(D.shapeRadius(.rounded, side: 32), 8)
        XCTAssertEqual(D.shapeRadius(.square, side: 32), 0)
        // A phone's column is wider than the 38 pt row: the shape stays 32, as before.
        XCTAssertEqual(D.shapeSide(.fit, columnWidth: 54), 32)
        XCTAssertEqual(D.shapeSide(.fit, columnWidth: 30), 24)
        XCTAssertEqual(D.shapeSide(.points(34), columnWidth: 54), 34)
    }

    func testAutoTextByLuminance() {
        func hex(_ h: String) -> (Double, Double, Double) {
            let v = Int(h, radix: 16)!
            return (Double((v >> 16) & 255) / 255, Double((v >> 8) & 255) / 255, Double(v & 255) / 255)
        }
        // WAC's statuses: worked and scheduled purple take white; pending orange and holiday green take black.
        for (h, black) in [("4C2258", false), ("A17AB1", true), ("E67B19", true), ("88E77B", true), ("FFFFFF", true), ("000000", false)] {
            let (r, g, b) = hex(h)
            XCTAssertEqual(D.blackTextOn(r: r, g: g, b: b), black, h)
        }
    }

    func testDotsLookAsksForNoImages() {
        let m = D.markers(json(["keyColumn": "j", "look": "dots", "image": [["column": "img"]]]))!
        let day = D.decorate(rows: [["d": .string("2026-10-01"), "j": .string("a"), "img": .string("https://x.test/a.png")]],
                             dateColumn: "d", fill: nil, markers: m)["2026-10-01"]!
        XCTAssertEqual(day.markers.first?.images, [])
        XCTAssertEqual(D.markerSize(m, dotSize: 8), 8)
        XCTAssertEqual(D.markerDot(m, size: 8), 8)
        let auto = D.markers(json(["keyColumn": "j", "image": [["column": "img"]]]))!
        XCTAssertEqual(D.markerSize(auto, dotSize: 8), 14)
        XCTAssertEqual(D.markerDot(auto, size: 14), 8)
    }
}
