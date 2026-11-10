import XCTest
@testable import RipulAgent

/// The cases of calendarDecorations.test.ts, on the native twin (CmsCalendarDecorations.swift).
final class CmsCalendarDecorationsTests: XCTestCase {
    typealias D = CmsCalendarDecorations

    private func json(_ any: Any) -> CmsJSON {
        let data = try! JSONSerialization.data(withJSONObject: any, options: [.fragmentsAllowed])
        return try! JSONDecoder().decode(CmsJSON.self, from: data)
    }
    private func rows(_ list: [[String: Any]]) -> [[String: CmsJSON]] {
        list.map { $0.mapValues { $0 is NSNull ? CmsJSON.null : json($0) } }
    }

    private lazy var fill = D.dayFill(json([
        "column": "state",
        "values": [
            ["value": "pending", "color": "#f00", "label": "Pending"],
            ["value": "worked", "color": "#00ff00", "label": "Worked"],
            ["value": "holiday", "color": "color.primary"],
        ],
    ]))!

    // MARK: dayFill

    func testFillPriorityIsTheListOrder() {
        let out = D.decorate(rows: rows([
            ["day": "2026-10-01", "state": "holiday"],
            ["day": "2026-10-01", "state": "worked"],
            ["day": "2026-10-02", "state": "holiday"],
        ]), dateColumn: "day", fill: fill, markers: nil)
        XCTAssertEqual(out["2026-10-01"]?.fill?.value, "worked")
        XCTAssertEqual(out["2026-10-02"]?.fill?.color, "color.primary")
    }

    func testUnlistedValueDrawsNothing() {
        let out = D.decorate(rows: rows([["day": "2026-10-03", "state": "mystery"]]), dateColumn: "day", fill: fill, markers: nil)
        XCTAssertNil(out["2026-10-03"])
    }

    func testNumbersMatchAsText() {
        let f = D.dayFill(json(["column": "s", "values": [["value": 1, "color": "#123"]]]))!
        XCTAssertEqual(D.decorate(rows: rows([["d": "2026-10-04", "s": 1]]), dateColumn: "d", fill: f, markers: nil)["2026-10-04"]?.fill?.value, "1")
    }

    func testBadEntriesDropThemselves() {
        let f = D.dayFill(json(["column": "s", "values": [["value": "a", "color": "blurple"], "x", ["value": "b", "color": "#abc"]], "style": "odd"]))!
        XCTAssertEqual(f.values.map(\.value), ["b"])
        XCTAssertFalse(f.ring)
        XCTAssertNil(D.dayFill(json(["column": "s", "values": [["value": "a", "color": "nope"]]])))
        XCTAssertNil(D.dayFill(json(["values": []])))
    }

    // MARK: markers

    private var markerRows: [[String: CmsJSON]] {
        rows([
            ["day": "2026-10-05", "job": "Café", "colour": "#112233"],
            ["day": "2026-10-05", "job": "Shop"],
            ["day": "2026-10-05", "job": "Café", "colour": "#999999"],
            ["day": "2026-10-05", "job": "Bar"],
            ["day": "2026-10-05", "job": "Pub"],
            ["day": "2026-10-05", "job": NSNull()],
        ])
    }

    func testOnePerKeyInOrderThenOverflow() {
        let m = D.markers(json(["keyColumn": "job", "colorColumn": "colour"]))!
        let d = D.decorate(rows: markerRows, dateColumn: "day", fill: nil, markers: m)["2026-10-05"]!
        XCTAssertEqual(d.markers.map(\.key), ["Café", "Shop"])
        XCTAssertEqual(d.overflow, 2)
        XCTAssertEqual(d.markers[0].color, "#112233")
        XCTAssertFalse(d.markers[0].fromPalette)
        XCTAssertEqual(d.markers[1].color, D.paletteColor("Shop"))
        XCTAssertTrue(d.markers[1].fromPalette)
    }

    func testMaxIncludingZero() {
        let three = D.decorate(rows: markerRows, dateColumn: "day", fill: nil, markers: D.markers(json(["keyColumn": "job", "max": 3])))["2026-10-05"]!
        XCTAssertEqual(three.markers.count, 3)
        XCTAssertEqual(three.overflow, 1)
        let none = D.decorate(rows: markerRows, dateColumn: "day", fill: nil, markers: D.markers(json(["keyColumn": "job", "max": 0])))["2026-10-05"]!
        XCTAssertEqual(none.markers.count, 0)
        XCTAssertEqual(none.overflow, 4)
    }

    func testInvalidRowColourFallsBackToPalette() {
        let d = D.decorate(rows: rows([["day": "2026-10-06", "job": "X", "colour": "reddish"]]), dateColumn: "day", fill: nil,
                           markers: D.markers(json(["keyColumn": "job", "colorColumn": "colour"])))["2026-10-06"]!
        XCTAssertEqual(d.markers[0].color, D.paletteColor("X"))
    }

    // MARK: palette (vectors shared with the web)

    func testHashMatchesTheWeb() {
        XCTAssertEqual(D.stableHash(""), 0x811c9dc5)
        XCTAssertEqual(D.stableHash("a"), 0xe40c292c)
        XCTAssertEqual(D.stableHash("Harbour Café"), 1232600577)
        XCTAssertEqual(D.stableHash("Corner Shop"), 1941377020)
        XCTAssertEqual(D.paletteColor("Harbour Café"), D.palette[7])
        XCTAssertEqual(D.paletteColor("Corner Shop"), D.palette[0])
        XCTAssertEqual(D.paletteColor("job 7"), D.palette[1])
    }

    func testPaletteSpreads() {
        XCTAssertGreaterThan(Set((0..<50).map { D.paletteColor("job \($0)") }).count, 6)
    }

    // MARK: colours and dates

    func testColours() {
        XCTAssertTrue(D.isColor("#abc"))
        XCTAssertTrue(D.isColor("#A1B2C3"))
        XCTAssertTrue(D.isColor("color.success"))
        XCTAssertFalse(D.isColor("color.gradient"))
        XCTAssertFalse(D.isColor("#abcd"))
        XCTAssertFalse(D.isColor("red"))
    }

    func testLocalDays() {
        XCTAssertEqual(D.localDayKey(.string("2026-10-27")), "2026-10-27")
        var c = DateComponents()
        c.year = 2026; c.month = 10; c.day = 27; c.hour = 23; c.minute = 30
        let local = Calendar(identifier: .gregorian).date(from: c)!
        let iso = ISO8601DateFormatter()
        XCTAssertEqual(D.localDayKey(.string(iso.string(from: local))), "2026-10-27")
        XCTAssertEqual(D.localDayKey(.string("2026-10-27T08:00:00")), "2026-10-27")
        XCTAssertEqual(D.localDayKey(.string("2026-10-27 08:00:00")), "2026-10-27")
        XCTAssertNil(D.localDayKey(.string("nonsense")))
        XCTAssertNil(D.localDayKey(.null))
    }

    // MARK: image chain

    func testCandidatesInOrderSkippingEmpty() {
        let row = rows([["img": "https://x.test/a.png", "http": "http://x.test/b.png", "name": "Café", "blank": ""]])[0]
        let chain = D.imageChain(json([
            ["column": "blank"], ["column": "http"], ["source": "logos", "column": "blank"],
            ["column": "img"], ["source": "logos", "column": "name"], ["source": ""], 7,
        ]))
        XCTAssertEqual(chain.count, 5)
        XCTAssertEqual(D.imageCandidates(row, chain), [.url("https://x.test/a.png"), .source("logos", value: "Café")])
    }

    func testChainTakesTheFirstThatLoads() async {
        var calls = 0
        let got: String? = await D.resolveChain([.url("https://x/1"), .source("s", value: "v"), .url("https://x/3")], size: 42) { c, _ in
            calls += 1
            if case .url(let u) = c, u.hasSuffix("3") { return "shown" }
            return nil
        }
        XCTAssertEqual(got, "shown")
        XCTAssertEqual(calls, 3)
        let none: String? = await D.resolveChain([], size: 42) { _, _ in "x" }
        XCTAssertNil(none)
    }

    @MainActor
    func testCacheIsPerSizeAndNeverRefetchesA404() async {
        CmsMarkerImageCache.missing = []
        var calls = 0
        let pixel = CmsPlatformImage(data: Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=")!)!
        let fetch: CmsMarkerImageCache.Fetch = { c, _ in
            calls += 1
            if case .source(_, let v) = c, v == "none" { return (nil, true) }
            return (pixel, false)
        }
        let a = CmsMarkerImageCache(fetch: fetch)
        let logo = D.ImageCandidate.source("s", value: "Café")
        let first = await a.resolve([logo], size: 42)
        let again = await a.resolve([logo], size: 42)
        XCTAssertNotNil(first)
        XCTAssertNotNil(again)
        XCTAssertEqual(calls, 1)
        _ = await a.resolve([logo], size: 24)
        XCTAssertEqual(calls, 2)

        let none = D.ImageCandidate.source("s", value: "none")
        let missing = await a.resolve([none], size: 42)
        XCTAssertNil(missing)
        // A fresh page's cache shares the session's misses.
        let b = CmsMarkerImageCache(fetch: fetch)
        let stillMissing = await b.resolve([none], size: 42)
        XCTAssertNil(stillMissing)
        XCTAssertEqual(calls, 3)
        CmsMarkerImageCache.missing = []
    }

    /// A marker's icon (`iconColumn`, docs/plans/cms-events-multi-add.md): the row's icon, sized as pictures are.
    func testAMarkersIcon() {
        let m = D.markers(.object(["keyColumn": .string("kind"), "iconColumn": .string("icon"), "max": .number(3)]))
        XCTAssertEqual(m?.iconColumn, "icon")
        XCTAssertEqual(m?.usesImages, true)
        let out = D.decorate(rows: rows([
            ["day": "2026-10-12", "kind": "tasting", "icon": "cup.and.saucer"],
            ["day": "2026-10-12", "kind": "meeting", "icon": ""],
        ]), dateColumn: "day", fill: nil, markers: m)
        XCTAssertEqual(out["2026-10-12"]?.markers.map(\.icon), ["cup.and.saucer", nil])
        let dots = D.markers(.object(["keyColumn": .string("kind"), "iconColumn": .string("icon"), "look": .string("dots")]))
        XCTAssertNil(D.decorate(rows: rows([["day": "2026-10-12", "kind": "tasting", "icon": "cup.and.saucer"]]),
                                dateColumn: "day", fill: nil, markers: dots)["2026-10-12"]?.markers.first?.icon)
    }
}

/// A tap's selection on the native Calendar Strip, as the web's handleDayClick.
final class CmsSimpleCalendarPickTests: XCTestCase {
    private let cal = Calendar(identifier: .gregorian)
    private func day(_ d: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: d, hour: 9))! }
    private func midnight(_ d: Int) -> Date { cal.startOfDay(for: day(d)) }
    private func pick(_ d: Int, _ start: Date?, _ end: Date?, range: Bool) -> (Date?, Date?) {
        CmsSimpleCalendarBlockView.pick(day(d), start: start, end: end, range: range, calendar: cal)
    }

    func testSingleTogglesTheSameDay() {
        var (s, e) = pick(24, nil, nil, range: false)
        XCTAssertEqual(s, midnight(24)); XCTAssertNil(e)
        (s, e) = pick(24, s, e, range: false)
        XCTAssertNil(s); XCTAssertNil(e)
        (s, e) = pick(25, midnight(24), nil, range: false)
        XCTAssertEqual(s, midnight(25))
    }

    func testRangeStartsCompletesClearsAndRestarts() {
        var (s, e) = pick(24, nil, nil, range: true)
        XCTAssertEqual(s, midnight(24)); XCTAssertNil(e)
        // Tapping the open start again clears it.
        (s, e) = pick(24, s, e, range: true)
        XCTAssertNil(s); XCTAssertNil(e)
        // Completed in either order.
        (s, e) = pick(20, midnight(24), nil, range: true)
        XCTAssertEqual(s, midnight(20)); XCTAssertEqual(e, midnight(24))
        (s, e) = pick(28, midnight(24), nil, range: true)
        XCTAssertEqual(s, midnight(24)); XCTAssertEqual(e, midnight(28))
        // A tap on a complete range starts a new one.
        (s, e) = pick(26, midnight(24), midnight(28), range: true)
        XCTAssertEqual(s, midnight(26)); XCTAssertNil(e)
    }

}
