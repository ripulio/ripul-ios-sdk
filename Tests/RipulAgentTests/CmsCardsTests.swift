import XCTest
import SwiftUI
@testable import RipulAgent

/// Cards and views (docs/plans/cms-cards.md): card styles against the web's
/// table, the view route's stream and merging, and the cards block's rules.
final class CmsCardsTests: XCTestCase {
    private func json(_ s: String) -> CmsJSON { try! JSONDecoder().decode(CmsJSON.self, from: Data(s.utf8)) }
    private func obj(_ s: String) -> [String: CmsJSON] { json(s).objectValue! }
    private func theme(_ s: String) -> CmsPortalThemeConfig {
        try! JSONDecoder().decode(CmsPortalThemeConfig.self, from: Data(s.utf8))
    }

    // MARK: Card styles

    private func sharedTable() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("chrome-extension/packages/shared-types/src/cmsCardStyles.builtin.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testBuiltInCardStylesEqualTheSharedTable() throws {
        let styles = try XCTUnwrap(try sharedTable()["styles"] as? [String: Any])
        XCTAssertEqual(Set(styles.keys), Set(CmsCardStyles.builtInNames))
        for (name, raw) in styles {
            let data = try JSONSerialization.data(withJSONObject: raw)
            let expected = try JSONDecoder().decode([String: CmsJSON].self, from: data)
            XCTAssertEqual(CmsCardStyles.builtIns[name], expected, "built-in card style \(name) differs from the web's table")
        }
        XCTAssertEqual(try sharedTable()["paletteRoles"] as? [String], CmsPaletteRole.allCases.map(\.rawValue))
    }

    func testWhichCardStyle() {
        let t = theme(#"{ "defaultCardStyle": "home", "cardStyles": { "home": { "base": "outlined" }, "x": "not a style" } }"#)
        XCTAssertEqual(CmsCardStyles.name(config: t, block: "plain"), "plain", "the block's first")
        XCTAssertEqual(CmsCardStyles.name(config: t, block: nil), "home", "then the theme's default")
        XCTAssertEqual(CmsCardStyles.name(config: t, block: "missing"), "home", "an unknown name is passed over")
        XCTAssertEqual(CmsCardStyles.name(config: t, block: "x"), "home", "a style that isn't an object names nothing")
        XCTAssertEqual(CmsCardStyles.name(config: nil, block: nil), "elevated", "then elevated")
    }

    func testASiteCardStyleMergesOverItsBase() throws {
        let t = theme("""
        { "cardStyles": {
            "home": { "base": "outlined",
                      "surface": { "cornerRadius": 10, "shadow": { "radius": 6 }, "fill": "#FFFFFF" },
                      "media": { "shape": "hexagon", "size": "big" },
                      "chip": { "variant": "glass", "size": 13 },
                      "title": { "color": "primary" },
                      "unknown": { "x": 1 },
                      "tones": { "highlight": { "fill": "accent" }, "calm": { "fill": "tint" } } },
            "elevated": { "surface": { "cornerRadius": 99 } } } }
        """)
        let home = CmsCardStyles.resolve(config: t, name: "home").json
        let outlined = CmsCardStyles.builtIns["outlined"]!
        func at(_ path: String...) -> CmsJSON? { CmsCardStyles.get(home, path) }
        XCTAssertEqual(at("base"), .string("outlined"))
        XCTAssertEqual(at("surface", "cornerRadius"), .number(10))
        XCTAssertEqual(at("surface", "shadow", "radius"), .number(6), "merged at any depth")
        XCTAssertEqual(at("surface", "shadow", "opacity"), CmsCardStyles.get(outlined, ["surface", "shadow", "opacity"]))
        XCTAssertEqual(at("surface", "border", "width"), .number(1), "the base's surface kept where unset")
        XCTAssertEqual(at("surface", "fill"), .string("paper"), "a colour that isn't a role keeps the base's")
        XCTAssertEqual(at("media", "shape"), .string("roundedSquare"), "an unknown shape keeps the base's")
        XCTAssertEqual(at("media", "size"), .number(40), "a value of the wrong kind keeps the base's")
        XCTAssertEqual(at("chip", "variant"), .string("outlined"), "an unknown chip variant keeps the base's")
        XCTAssertEqual(at("chip", "size"), .number(13))
        XCTAssertEqual(at("title", "color"), .string("primary"))
        XCTAssertNil(at("unknown"), "only settings the base has")
        XCTAssertEqual(at("tones", "highlight", "fill"), .string("accent"))
        XCTAssertEqual(at("tones", "highlight", "text"), .string("paper"), "a tone merges over the base's by name")
        XCTAssertEqual(at("tones", "calm"), json(#"{ "fill": "tint", "text": "text", "muted": "mutedText", "accent": "primary" }"#),
                       "a new tone starts from paper, text, mutedText and primary")
        XCTAssertEqual(CmsCardStyles.resolve(config: t, name: "elevated").json, CmsCardStyles.builtIns["elevated"],
                       "a site can't redefine a built-in")
    }

    func testCardStyleColoursAndTones() {
        let t = theme(##"{ "palette": { "primary": "#6F2D80", "paper": "#FFFFFF" }, "darkPalette": { "paper": "#1C1C1E" } }"##)
        let light = CmsResolvedCardStyle(config: t, block: nil, theme: CmsPortalTheme(config: t, effectiveDark: false))
        let dark = CmsResolvedCardStyle(config: t, block: nil, theme: CmsPortalTheme(config: t, effectiveDark: true))
        XCTAssertEqual(light.name, "elevated")
        XCTAssertEqual(light.color("surface", "fill"), CmsRGBA(css: "#FFFFFF")!.color)
        XCTAssertEqual(dark.color("surface", "fill"), CmsRGBA(css: "#1C1C1E")!.color, "the dark palette when dark")
        XCTAssertEqual(light.tone("highlight")?.fill, CmsRGBA(css: "#6F2D80")!.color)
        XCTAssertEqual(light.tone("highlight")?.text, CmsRGBA(css: "#FFFFFF")!.color)
        XCTAssertNil(light.tone("none"), "a tone the style lacks draws no tone")
        XCTAssertEqual(light.number("surface", "cornerRadius"), 16)
        XCTAssertEqual(light.listStyle.style.chip?.variant, "outlined", "the chip shared with list styles")
    }

    // MARK: Views

    private let view: CmsViewDef = try! JSONDecoder().decode(CmsViewDef.self, from: Data("""
    { "slug": "home_paydays", "base": "my_paydays", "key": "id",
      "sources": [ { "alias": "estimate", "query": "payday_estimate", "perRow": { "payslip_id": "{id}" } },
                   { "alias": "job", "query": "jobs", "match": { "base": "job_id", "source": "id" } },
                   { "query": "no_alias" } ] }
    """.utf8))

    func testDecodesAView() {
        XCTAssertEqual(view.sources?.count, 2, "a source without an alias drops itself")
        XCTAssertTrue(view.sources![0].isPerRow)
        XCTAssertFalse(view.sources![1].isPerRow)
        XCTAssertEqual(view.queries, ["my_paydays", "payday_estimate", "jobs"])
        XCTAssertTrue(view.isUsable)
        let broken = try! JSONDecoder().decode(CmsViewDef.self, from: Data(#"{ "slug": "x" }"#.utf8))
        XCTAssertFalse(broken.isUsable, "a view missing its base or key is left out, never failing the site")
    }

    func testAViewBuildsUpAsItStreams() {
        var result = CmsViewResult(key: "id")
        let lines = [
            #"{"type":"base","rows":[{"id":1,"state":"estimate"},{"id":2,"state":"payday_past"},{"id":3}],"schema":[{"name":"id"},{"name":"state"}],"key":"id","later":["3"]}"#,
            #"{"type":"source","alias":"estimate","results":[{"key":"1","status":"ready","row":{"net":412.5}},{"key":"2","status":"failed","error":"Rails took too long"}]}"#,
            #"{"type":"source","alias":"job","results":[{"key":"1","status":"ready","row":{"name":"KFC"}},{"key":"2","status":"ready","row":null}]}"#,
            #"not json"#,
            #"{"type":"end"}"#,
        ]
        for line in lines {
            if let event = CmsViewEvent.parse(line: Substring(line)) { result.apply(event, view: view) }
        }
        XCTAssertEqual(result.rows.count, 3, "the base rows are the view's rows, in order")
        XCTAssertEqual(result.rows[0]["estimate.net"], .number(412.5), "a source's row joins as alias.column")
        XCTAssertEqual(result.rows[0]["job.name"], .string("KFC"))
        XCTAssertNil(result.rows[1]["job.name"], "a ready result with no row leaves that source's columns empty")
        XCTAssertEqual(result.status["1"]?["estimate"], .ready)
        XCTAssertEqual(result.status["2"]?["estimate"], .failed("Rails took too long"))
        XCTAssertEqual(result.status["3"]?["estimate"], .later, "a per-row source past the first rows is asked for later")
        XCTAssertEqual(result.status["3"]?["job"], .pending, "a matched source is never later")
        XCTAssertEqual(result.laterKeys, ["3"])
        XCTAssertTrue(result.ended)
        result.failRemainingPending("Couldn't load this")
        XCTAssertEqual(result.status["3"]?["job"], .failed("Couldn't load this"), "still pending at the end: failed")
        XCTAssertEqual(result.status["3"]?["estimate"], .later, "later stays later")
    }

    func testARefetchedSourceReplacesItsColumns() {
        var result = CmsViewResult(key: "id")
        result.apply(.base(rows: [["id": .number(1)]], schema: [], key: "id", later: []), view: view)
        result.merge(alias: "estimate", results: [.init(key: "1", status: .ready, row: ["net": .number(1), "gross": .number(2)])])
        result.merge(alias: "estimate", results: [.init(key: "1", status: .ready, row: ["net": .number(3)])])
        XCTAssertEqual(result.rows[0]["estimate.net"], .number(3))
        XCTAssertNil(result.rows[0]["estimate.gross"], "the source's old columns go")
        XCTAssertEqual(result.status(row: ["id": .number(1)], alias: "estimate"), .ready)
        XCTAssertEqual(result.status(row: ["id": .number(9)], alias: "estimate"), .ready, "an unknown row reads ready")
    }

    func testTheWholeAnswerReadsAsTheSameEvents() {
        let events = CmsViewEvent.events(fromWhole: json("""
        { "ok": true, "rows": [{"id": 1}], "schema": [{"name": "id"}], "key": "id", "later": [],
          "sources": { "estimate": { "1": { "status": "ready", "row": { "net": 5 } } } } }
        """))
        var result = CmsViewResult()
        for e in events { result.apply(e, view: view) }
        XCTAssertEqual(result.rows.first?["estimate.net"], .number(5))
        XCTAssertTrue(result.ended)
        XCTAssertEqual(CmsViewEvent.events(fromWhole: json(#"{ "ok": false, "error": "No such view" }"#)), [.error("No such view")])
        XCTAssertEqual(CmsViewEvent.parse(line: #"{"type":"error","error":"Base failed"}"#), .error("Base failed"))
    }

    // MARK: Cards: decoding

    func testDecodesTheBlock() {
        let props = CmsCardsProps(obj("""
        { "display": "carousel", "carousel": { "indicator": "count", "height": "tallest", "peek": 24, "autoplayMs": 4000, "loop": true },
          "cardStyle": "home",
          "items": [
            { "card": { "id": "week", "query": "my_week", "title": "This week: {hours}" } },
            { "card": { "title": "No id" } },
            { "rows": { "query": "home_paydays", "key": "id", "card": { "title": "{job}" } } },
            { "rows": { "query": "q", "key": "id", "card": { "title": "a" }, "cardsBy": { "column": "kind", "cards": {} } } },
            { "rows": { "query": "q", "key": "id" } } ] }
        """))
        XCTAssertEqual(props.display, "carousel")
        XCTAssertEqual(props.carousel.indicator, "count")
        XCTAssertEqual(props.carousel.height, "tallest")
        XCTAssertEqual(props.carousel.peek, 24)
        XCTAssertEqual(props.carousel.autoplayMs, 4000)
        XCTAssertTrue(props.carousel.loop)
        XCTAssertEqual(props.cardStyle, "home")
        XCTAssertEqual(props.items.count, 2, "a written card needs an id; a rows item needs card or cardsBy, not both")
        XCTAssertEqual(CmsCardsProps([:]).display, "stack")
        XCTAssertEqual(CmsCardsProps([:]).carousel.indicator, "both")
    }

    func testPartsAreCapped() {
        let card = CmsCard(json("""
        { "id": "c", "figures": [ {"label":"a","value":"1"},{"label":"b","value":"2"},{"label":"c","value":"3"},{"label":"d","value":"4"},{"label":"e","value":"5"} ],
          "lines": ["a","b","c","d"], "buttons": [ {"label":"1","close":true},{"label":"2","close":true},{"label":"3","close":true},{"label":"4","close":true} ] }
        """))!
        XCTAssertEqual(card.parts.figures?.count, 4)
        XCTAssertEqual(card.parts.lines?.count, 3)
        XCTAssertEqual(card.parts.buttons?.count, 3)
    }

    // MARK: Cards: states

    private let payday = CmsCard(try! JSONDecoder().decode(CmsJSON.self, from: Data("""
    { "id": "p", "title": "Pay so far", "body": "{hours}",
      "variants": [
        { "name": "setup", "when": { "column": "state", "equals": "setup" }, "title": "Set up your estimate" },
        { "name": "payday", "when": { "column": "state", "in": ["payday_today", "payday_past"] }, "title": "How did payday go?", "body": "Was it a match?" },
        { "name": "answering", "title": "Saving…" },
        { "name": "change", "title": "Did it match?" } ] }
    """.utf8)))!

    func testVariantsFollowTheRow() {
        let none: (String) -> Int? = { _ in nil }
        XCTAssertEqual(payday.resolvedParts(row: ["state": .string("setup")], requested: nil, rowCount: none).parts.title?.text, "Set up your estimate")
        let past = payday.resolvedParts(row: ["state": .string("payday_past")], requested: nil, rowCount: none)
        XCTAssertEqual(past.variant, "payday")
        XCTAssertEqual(past.parts.body?.text, "Was it a match?", "a part the variant sets replaces the card's")
        let estimate = payday.resolvedParts(row: ["state": .string("estimate")], requested: nil, rowCount: none)
        XCTAssertNil(estimate.variant, "none applies: the card's own parts")
        XCTAssertEqual(estimate.parts.body?.text, "{hours}")
        XCTAssertEqual(payday.resolvedParts(row: ["state": .string("estimate")], requested: "change", rowCount: none).parts.title?.text,
                       "Did it match?", "a variant without when shows on request")
        XCTAssertEqual(payday.resolvedParts(row: ["state": .string("setup")], requested: "answering", rowCount: none).parts.body?.text,
                       "{hours}", "a part the variant leaves out keeps the card's")
    }

    func testConditions() {
        func holds(_ c: String, _ row: [String: CmsJSON]?, rows: Int? = nil) -> Bool {
            CmsCardCondition(json(c))!.holds(row: row, rowCount: { _ in rows })
        }
        XCTAssertTrue(holds(#"{ "column": "n", "equals": "1" }"#, ["n": .number(1)]), "values compare as text")
        XCTAssertTrue(holds(#"{ "column": "n", "equals": 1 }"#, ["n": .string("1")]))
        XCTAssertTrue(holds(#"{ "column": "s", "in": ["a", "b"] }"#, ["s": .string("b")]))
        XCTAssertTrue(holds(#"{ "column": "s", "empty": true }"#, ["s": .string("  ")]), "blank text is empty")
        XCTAssertTrue(holds(#"{ "column": "s", "empty": true }"#, [:]), "missing is empty")
        XCTAssertTrue(holds(#"{ "column": "s", "empty": true }"#, ["s": .null]))
        XCTAssertFalse(holds(#"{ "column": "s", "empty": false }"#, ["s": .null]))
        XCTAssertTrue(holds(#"{ "column": "estimate.net", "empty": false }"#, ["estimate.net": .number(3)]), "a source's column")
        XCTAssertTrue(holds(#"{ "rows": "offers" }"#, nil, rows: 2))
        XCTAssertFalse(holds(#"{ "rows": "offers" }"#, nil, rows: 0))
        XCTAssertTrue(holds(#"{ "rows": "offers", "empty": true }"#, nil, rows: 0))
        XCTAssertNil(CmsCardCondition(json(#"{ "equals": 1 }"#)))
    }

    func testDateWindowOnTheViewersCalendar() {
        let card = CmsCard(json(#"{ "id": "tip", "from": "2026-10-28", "until": "2026-10-30" }"#))!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/London")!
        func day(_ s: String) -> Date { let f = ISO8601DateFormatter(); return f.date(from: s)! }
        XCTAssertFalse(card.inWindow(today: day("2026-10-27T23:30:00Z"), calendar: cal))
        XCTAssertTrue(card.inWindow(today: day("2026-10-28T00:30:00Z"), calendar: cal), "inclusive")
        XCTAssertTrue(card.inWindow(today: day("2026-10-30T22:00:00Z"), calendar: cal))
        XCTAssertFalse(card.inWindow(today: day("2026-10-31T00:30:00Z"), calendar: cal))
    }

    // MARK: Cards: places and groups

    func testPlaces() {
        let props = CmsCardsProps(obj("""
        { "items": [
            { "card": { "id": "week", "query": "my_week", "title": "This week" } },
            { "card": { "id": "empty", "query": "nothing", "title": "Never" } },
            { "rows": { "query": "home", "key": "id",
                        "cardsBy": { "column": "kind", "cards": { "payday": { "title": "{job}" }, "notice": { "title": "{message}" } } },
                        "group": { "by": "section" } } },
            { "card": { "id": "tip", "title": "A tip" } } ] }
        """))
        let data: [String: [[String: CmsJSON]]] = [
            "my_week": [["hours": .number(31.5)]],
            "nothing": [],
            "home": [
                ["id": .number(1), "kind": .string("payday"), "section": .string("pay"), "job": .string("KFC")],
                ["id": .number(2), "kind": .string("notice"), "section": .string("notices"), "message": .string("Hi")],
                ["id": .number(3), "kind": .string("payday"), "section": .string("pay"), "job": .string("Costa")],
                ["id": .number(4), "kind": .string("unknown"), "section": .string("pay")],
            ],
        ]
        let places = CmsCards.places(items: props.items, rows: { data[$0] }, visible: { _ in true }, header: { _, _, _ in nil })
        XCTAssertEqual(places.map(\.id), ["card:week", "row:2#pay", "row:2:2", "card:tip"],
                       "a written card with no rows doesn't show; groups take their first row's place; a group of one row is a card")
        XCTAssertEqual(places.first?.cards.first?.closeKey, "week", "closing remembers a written card's id")
        XCTAssertEqual(places[2].cards.first?.closeKey, "2", "and a row's card by its row key")
        XCTAssertEqual(places[0].cards.first?.row?["hours"], .number(31.5), "a written card reads its query's first row")
        XCTAssertEqual(places[1].cards.map(\.rowKey), ["1", "3"], "a row whose kind names no template doesn't show")
        let hidden = CmsCards.places(items: props.items, rows: { data[$0] }, visible: { $0.rowKey != "1" && $0.rowKey != "3" },
                                     header: { _, _, _ in "Header" })
        XCTAssertFalse(hidden.map(\.id).contains("row:2#pay"), "a group whose cards are all hidden doesn't show, header included")
        XCTAssertTrue(hidden.contains { $0.id == "row:2:2" }, "a group of one row draws as a card, with no header")
        let oneShown = CmsCards.places(items: props.items, rows: { data[$0] }, visible: { $0.rowKey != "3" },
                                       header: { _, _, _ in "Header" })
        if case .group(_, let header, _, let cards)? = oneShown.first(where: { $0.id == "row:2#pay" }) {
            XCTAssertEqual(header, "Header", "several rows with one card shown stay a group, with the header")
            XCTAssertEqual(cards.count, 1)
        } else {
            XCTFail("expected the group")
        }
        let loading = CmsCards.places(items: props.items, rows: { $0 == "home" ? nil : data[$0] }, loading: { $0 == "home" },
                                      visible: { _ in true }, header: { _, _, _ in nil })
        XCTAssertEqual(loading.map(\.id), ["card:week", "row:2", "card:tip"], "a query still loading holds its place")
        XCTAssertNil(CmsCards.places(items: props.items, rows: { $0 == "home" ? nil : data[$0] }, visible: { _ in true },
                                     header: { _, _, _ in nil }).first { $0.id.hasPrefix("home") }, "rows not loaded: nothing yet")
    }

    func testAWrittenCardHoldsItsPlaceWhileItsQueryLoads() {
        let props = CmsCardsProps(obj("""
        { "items": [
          { "card": { "id": "hello", "query": "me", "eyebrow": "{today|EEEE}", "title": "Good {timeOfDay} {name}" } },
          { "card": { "id": "tip", "title": "Tip" } } ] }
        """))
        let header: (CmsCardsRows, String, [[String: CmsJSON]]) -> String? = { _, _, _ in nil }
        let waiting = CmsCards.places(items: props.items, rows: { _ in nil }, loading: { $0 == "me" },
                                      visible: { _ in true }, header: header)
        XCTAssertEqual(waiting.map(\.id), ["card:hello", "card:tip"], "it holds its place in every display, as itself")
        XCTAssertEqual(waiting.first?.cards.first?.queryWaiting, true)
        XCTAssertNil(waiting.first?.cards.first?.row)
        let failed = CmsCards.places(items: props.items, rows: { _ in nil }, failure: { $0 == "me" ? "Timed out" : nil },
                                     visible: { _ in true }, header: header)
        XCTAssertEqual(failed.first?.cards.first?.queryFailed, "Timed out", "a failed query: Couldn't load this, Try again")
        let empty = CmsCards.places(items: props.items, rows: { _ in [] }, visible: { _ in true }, header: header)
        XCTAssertEqual(empty.map(\.id), ["card:tip"], "no rows: the card goes")
        let filled = CmsCards.places(items: props.items, rows: { $0 == "me" ? [["name": .string("Sam")]] : nil },
                                     visible: { _ in true }, header: header)
        XCTAssertEqual(filled.first?.cards.first?.row?["name"], .string("Sam"))
        XCTAssertEqual(filled.first?.cards.first?.queryWaiting, false, "rows arrived: its slots fill in place")
    }

    func testOnlyTheQuerysSlotsWaitInline() {
        XCTAssertTrue(CmsCards.slotWaitsOnQuery("name"))
        XCTAssertTrue(CmsCards.slotWaitsOnQuery("pay|\"£\"#,##0.00"))
        XCTAssertFalse(CmsCards.slotWaitsOnQuery("timeOfDay"), "built in: drawn at once")
        XCTAssertFalse(CmsCards.slotWaitsOnQuery("today|EEEE"))
        XCTAssertFalse(CmsCards.slotWaitsOnQuery("@me.name"), "another query's token")
        XCTAssertNil(CmsCards.waitingRow(for: "As of {today}", row: nil), "nothing waits: drawn as usual")
        let row = CmsCards.waitingRow(for: "Good {timeOfDay} {name}", row: nil)
        XCTAssertEqual(row?["name"], .string(CmsCards.waitingMark))
        XCTAssertNil(row?["timeOfDay"])
        let segments = CmsCards.waitingSegments("Good afternoon \(CmsCards.waitingMark)")
        XCTAssertEqual(segments.map(\.text), ["Good afternoon ", ""])
        XCTAssertEqual(segments.map(\.placeholder), [false, true], "the words, then the name's placeholder")
        XCTAssertEqual(CmsCards.waitingSegments("\(CmsCards.waitingMark) of \(CmsCards.waitingMark)").map(\.placeholder),
                       [true, false, true])
    }

    func testGroupHeadersReadTotalsByTheGridsNames() {
        let line = CmsCardLine(text: "{job}: {pay_sum} over {row_count} shifts")
        let rows: [[String: CmsJSON]] = [["pay": .number(72)], ["pay": .number(90.5)]]
        let columns: [CmsJSON] = [json(##"{ "key": "pay", "aggFunc": "sum", "format": "\"£\"#,##0.00" }"##)]
        XCTAssertEqual(CmsCards.headerText(line, groupColumn: "job", value: "KFC", rows: rows, columns: columns),
                       "KFC: £162.50 over 2 shifts")
    }

    func testSlotsAndInputs() {
        XCTAssertEqual(CmsCards.splitSlot("pay|£#,##0.00").column, "pay")
        XCTAssertEqual(CmsCards.splitSlot("pay|£#,##0.00").format, "£#,##0.00")
        XCTAssertNil(CmsCards.splitSlot("estimate.net").format)
        let row: [String: CmsJSON] = ["id": .number(42), "name": .string("KFC"), "ok": .bool(true)]
        let inputs = CmsCards.inputs(["id": .string("{id}"), "note": .string("For {name}"), "match": .bool(true),
                                      "rate": .number(1.5), "missing": .string("{nope}")], row: row)
        XCTAssertEqual(inputs["id"], json(#"{ "value": "42", "type": "integer" }"#), "one slot keeps the column's type, sent as text (the worker binds strings)")
        XCTAssertEqual(inputs["note"], json(#"{ "value": "For KFC", "type": "string" }"#), "other text is text")
        XCTAssertEqual(inputs["match"], json(#"{ "value": "true", "type": "boolean" }"#))
        XCTAssertEqual(inputs["rate"], json(#"{ "value": "1.5", "type": "float" }"#))
        XCTAssertEqual(inputs["missing"], json(#"{ "value": null, "type": "string" }"#))
    }

    func testAliasesACardReads() {
        let card = CmsCard(json("""
        { "id": "p", "title": "{job}", "body": "You should get {estimate.net}", "when": { "column": "lookup.state", "equals": "x" },
          "lines": [{ "text": "{a.b}", "image": "logo.url" }] }
        """))!
        let v = try! JSONDecoder().decode(CmsViewDef.self, from: Data("""
        { "slug": "v", "base": "b", "key": "id",
          "sources": [ { "alias": "estimate", "query": "e", "perRow": {} }, { "alias": "lookup", "query": "l", "match": { "base": "id", "source": "id" } } ] }
        """.utf8))
        XCTAssertEqual(CmsCards.aliases(of: card.parts, card: card, view: v), ["estimate", "lookup"],
                       "only the view's aliases; a dotted column of the base is not one")
        XCTAssertEqual(CmsCards.aliases(of: card.parts, card: card, view: nil), [], "a query, not a view, has no sources")
    }

    func testAPicturesThreeForms() {
        let plain: (String) -> CmsColumnPresentation = { CmsColumnPresentation(key: $0, json: nil) }
        let asset = "https://llm-proxy.ripul.io/v1/files/assets/cms_1/asset_1.png"
        XCTAssertEqual(CmsCards.mediaCandidates(asset, chain: [], row: nil, column: plain), [.url(asset)],
                       "an address works on a written card with no row")
        XCTAssertEqual(CmsCards.mediaCandidates(asset, chain: [], row: ["logo": .string("https://x.test/a.png")], column: plain),
                       [.url(asset)], "an address is used as it is, even with a row")
        let row: [String: CmsJSON] = ["id": .number(7), "logo": .string("https://x.test/a.png")]
        XCTAssertEqual(CmsCards.mediaCandidates("https://x.test/jobs/{id}.png", chain: [], row: row, column: plain),
                       [.url("https://x.test/jobs/7.png")], "a template fills from the row")
        XCTAssertEqual(CmsCards.mediaCandidates("logo", chain: [], row: row, column: plain), [.url("https://x.test/a.png")],
                       "otherwise a column name holding an address")
        XCTAssertEqual(CmsCards.mediaCandidates("logo", chain: [], row: nil, column: plain), [], "a column needs a row")
        XCTAssertEqual(CmsCards.mediaCandidates("name", chain: [], row: ["name": .string("KFC")], column: plain), [],
                       "a column that holds no address draws nothing")
        let chain = [CmsCalendarDecorations.ImageEntry(column: "job", source: "logo")]
        XCTAssertEqual(CmsCards.mediaCandidates("job", chain: chain, row: ["job": .string("KFC")], column: plain),
                       [.source("logo", value: "KFC")], "the chain still applies")
    }

    func testClosedCardsAreRememberedPerBlock() {
        let defaults = UserDefaults(suiteName: "CmsCardsTests.\(UUID().uuidString)")!
        CmsCardsClosedStore.close("tip", cmsId: "cms_1", blockId: "home", defaults: defaults)
        CmsCardsClosedStore.close("home:3", cmsId: "cms_1", blockId: "home", defaults: defaults)
        XCTAssertEqual(CmsCardsClosedStore.closed(cmsId: "cms_1", blockId: "home", defaults: defaults), ["tip", "home:3"])
        XCTAssertEqual(CmsCardsClosedStore.closed(cmsId: "cms_1", blockId: "other", defaults: defaults), [])
    }
}
