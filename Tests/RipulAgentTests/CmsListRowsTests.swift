import XCTest
import SwiftUI
@testable import RipulAgent

/// Richer list rows (plan docs/plans/cms-list-rows.md): a grid's `listRow`,
/// a column's own presentation (style rules, chips, image chains), formats
/// with quoted text, and the list style's new levers.
final class CmsListRowsTests: XCTestCase {
    private func json(_ s: String) -> CmsJSON { try! JSONDecoder().decode(CmsJSON.self, from: Data(s.utf8)) }
    private func row(_ s: String) -> [String: CmsJSON] { json(s).objectValue! }

    // MARK: Formats with quoted text

    func testQuotedTextInFormats() {
        XCTAssertEqual(CmsFormatValue.apply("6", pattern: #"0.##"h""#), "6h", "a unit in double quotes")
        XCTAssertEqual(CmsFormatValue.apply("7.5", pattern: #"0.##"h""#), "7.5h")
        XCTAssertEqual(CmsFormatValue.apply("1285", pattern: #"#,##0 "m""#), "1,285 m")
        XCTAssertEqual(CmsFormatValue.apply("72", pattern: ##""£"#,##0.00"##), "£72.00", "a quoted prefix")
        XCTAssertEqual(CmsFormatValue.apply("3", pattern: "0 'km'"), "3 km", "single quotes too")
        XCTAssertFalse(CmsFormatValue.isDurationPattern(#"0.##"h""#), "an h in quotes is not a duration token")
        XCTAssertFalse(CmsFormatValue.isDatePattern(#"0 "days""#), "a d in quotes is not a date token")
        XCTAssertEqual(CmsFormatValue.apply("125", pattern: "mm:ss"), "02:05", "durations unchanged")
        XCTAssertEqual(CmsFormatValue.apply("1234.5", pattern: "#,##0.00"), "1,234.50", "plain numbers unchanged")
    }

    // MARK: Style rules and chips

    private let kind = CmsColumnPresentation(key: "kind", json: [
        "lozenge": .object(["variant": .string("outlined"), "icon": .string("check"), "fg": .string("#333333")]),
        "styleRules": .array([
            .object(["when": .object(["op": .string("=="), "value": .string("regular")]),
                     "style": .object(["text": .string("Worked"), "icon": .string("swap")])]),
            .object(["when": .object(["op": .string("in"), "values": .array([.string("sick"), .string("ill")])]),
                     "style": .object(["text": .string("Sick"), "fg": .string("#C62828"), "icon": .string("sick")])]),
            .object(["when": .object(["op": .string("=="), "value": .string("holiday")]),
                     "style": .object(["rowWide": .bool(true), "bg": .string("#FFFF00")])]),
        ]),
    ])

    func testChipTakesTheMatchingRulesWordsIconAndColour() {
        let worked = kind.chip(row(#"{ "kind": "regular" }"#))
        XCTAssertEqual(worked?.text, "Worked")
        XCTAssertEqual(worked?.icon, "swap", "the rule's icon wins over the lozenge's")
        XCTAssertEqual(worked?.fg, "#333333", "no rule colour: the lozenge's")
        XCTAssertEqual(worked?.variant, "outlined")
        let sick = kind.chip(row(#"{ "kind": "ill" }"#))
        XCTAssertEqual(sick?.text, "Sick")
        XCTAssertEqual(sick?.fg, "#C62828", "the rule's colour wins")
        XCTAssertEqual(sick?.icon, "sick")
        let holiday = kind.chip(row(#"{ "kind": "holiday" }"#))
        XCTAssertEqual(holiday?.text, "holiday", "a row-wide rule doesn't style the chip")
        XCTAssertEqual(holiday?.icon, "check", "no rule icon: the lozenge's")
        XCTAssertNil(kind.chip(row(#"{ "kind": null }"#)), "no value, no chip")
    }

    func testAChipComesFromTheOneMatchingRule() {
        let column = CmsColumnPresentation(key: "kind", json: [
            "lozenge": .object(["bg": .string("#EEEEEE"), "fg": .string("#111111")]),
            "styleRules": .array([
                .object(["when": .object(["op": .string("=="), "value": .string("a")]),
                         "style": .object(["icon": .string("check")])]),
                .object(["when": .object(["op": .string("=="), "value": .string("a")]),
                         "style": .object(["text": .string("Later"), "bg": .string("#FF0000")])]),
                .object(["when": .object(["op": .string("=="), "value": .string("b")]),
                         "style": .object(["fg": .string("#C62828")])]),
            ]),
        ])
        let a = column.chip(row(#"{ "kind": "a" }"#))
        XCTAssertEqual(a?.icon, "check")
        XCTAssertEqual(a?.text, "a", "a later rule is never read, even for what the first doesn't set")
        XCTAssertEqual(a?.bg, "#EEEEEE", "no colour on the rule: the lozenge's pair")
        XCTAssertEqual(a?.fg, "#111111")
        let b = column.chip(row(#"{ "kind": "b" }"#))
        XCTAssertEqual(b?.fg, "#C62828")
        XCTAssertNil(b?.bg, "colours come as a pair from the rule; its unset bg stays unset")
    }

    func testConditions() {
        func holds(_ cond: String, _ value: CmsJSON?, row r: [String: CmsJSON] = [:]) -> Bool {
            CmsStyleCondition(json(cond))!.holds(value, row: r)
        }
        XCTAssertTrue(holds(#"{ "op": "==", "value": 5 }"#, .string("5")), "loose equality, as JavaScript's ==")
        XCTAssertFalse(holds(#"{ "op": "==", "value": 5 }"#, .string("5.1")))
        XCTAssertTrue(holds(#"{ "op": "between", "min": 1, "max": 3 }"#, .number(2)))
        XCTAssertTrue(holds(#"{ "op": "notBetween", "min": 1, "max": 3 }"#, .number(4)))
        XCTAssertTrue(holds(#"{ "op": ">", "value": 30, "valueFrom": "limit" }"#, .number(40), row: ["limit": .number(30)]))
        XCTAssertFalse(holds(#"{ "op": ">", "value": 30, "valueFrom": "limit" }"#, .number(40), row: [:]), "no limit: no match")
        XCTAssertTrue(holds(#"{ "op": "isNull" }"#, nil))
        XCTAssertTrue(holds(#"{ "op": "notIn", "values": ["a"] }"#, .string("b")))
        XCTAssertNil(CmsStyleCondition(json(#"{ "op": "~" }"#)), "an unknown operator drops the rule")
    }

    func testRuleTextFillsColumns() {
        XCTAssertEqual(CmsColumnPresentation.fillRuleText("out {d|distance} away", row: ["d": .number(1300)]), "out 1.3 km away")
        XCTAssertEqual(CmsColumnPresentation.fillRuleText("{a}·{b}", row: ["a": .string("x")]), "x·")
    }

    func testChipColoursPerVariant() throws {
        let style = CmsResolvedListStyle(config: nil, block: "cards", dark: false)
        let theme = CmsPortalTheme(config: nil)
        func chip(_ variant: String?, fg: String? = nil, bg: String? = nil) -> CmsColumnPresentation.Chip {
            CmsColumnPresentation.Chip(text: "x", icon: nil, fg: fg, bg: bg, variant: variant)
        }
        let outlined = CmsChipView.colours(chip(nil, fg: "#C62828"), style: style)
        XCTAssertEqual(CmsChipView.variant(chip(nil), style: style), "outlined", "the style's default variant")
        XCTAssertEqual(outlined.border, CmsRGBA(css: "#C62828")!.color)
        XCTAssertEqual(outlined.text, CmsRGBA(css: "#C62828")!.color)
        let tinted = CmsChipView.colours(chip("tinted"), style: style)
        XCTAssertEqual(tinted.text, theme.primary, "nothing set: the style's chip colour, primary")
        XCTAssertNil(tinted.border)
        let filled = CmsChipView.colours(chip("filled", fg: "#000000", bg: "#FFEB3B"), style: style)
        XCTAssertEqual(filled.fill, CmsRGBA(css: "#FFEB3B")!.color)
        XCTAssertEqual(filled.text, CmsRGBA(css: "#000000")!.color)
        XCTAssertEqual(CmsChipView.colours(chip("filled"), style: style).text, .white)
    }

    func testPicturesFromAnImageChainOrAnAddress() {
        let job = CmsColumnPresentation(key: "job", json: [
            "image": .object(["chain": .array([.object(["source": .string("logo"), "column": .string("job")])])]),
        ])
        XCTAssertEqual(job.pictureCandidates(row(#"{ "job": "KFC" }"#)), [.source("logo", value: "KFC")])
        let avatar = CmsColumnPresentation(key: "avatar", json: ["image": .object([:])])
        XCTAssertEqual(avatar.pictureCandidates(row(#"{ "avatar": "https://x.test/a.png" }"#)), [.url("https://x.test/a.png")])
        XCTAssertEqual(avatar.pictureCandidates(row(#"{ "avatar": "not an address" }"#)), [])
        XCTAssertEqual(CmsColumnPresentation(key: "job", json: nil).pictureCandidates(row(#"{ "job": "KFC" }"#)), [],
                       "no image config: no picture")
    }

    // MARK: The row layout

    func testDecodesARowLayout() throws {
        let layout = try XCTUnwrap(CmsListRowLayout(json("""
        { "leading": { "date": "day" }, "title": "{hours}",
          "lines": ["{start} – {end}", { "text": "{job} • {role}", "image": "job" }, "a", "b"],
          "trailing": "{pay}", "chip": "kind" }
        """)))
        XCTAssertEqual(layout.leading, .date("day"))
        XCTAssertEqual(layout.lines.count, 3, "at most three lines")
        XCTAssertEqual(layout.lines[1], .init(text: "{job} • {role}", image: "job"))
        XCTAssertEqual(layout.chip, "kind")
        XCTAssertEqual(layout.columnNames, ["day", "hours", "start", "end", "job", "role", "pay", "kind"])
        XCTAssertNil(CmsListRowLayout(json(#"{ "lines": ["x"] }"#)), "no title: no layout")
        XCTAssertEqual(CmsListRowLayout(json(#"{ "title": "{a}", "leading": { "image": "logo" } }"#))?.leading, .image("logo"))
    }

    func testSlotsDrawInTheirColumnsOwnFormat() {
        let columns: [String: CmsColumnPresentation] = [
            "hours": CmsColumnPresentation(key: "hours", json: ["format": .string(#"0.##"h""#)]),
            "start": CmsColumnPresentation(key: "start", json: ["format": .string("H:mm")]),
            "end": CmsColumnPresentation(key: "end", json: ["format": .string("H:mm")]),
            "secs": CmsColumnPresentation(key: "secs", json: ["transform": .string("seconds_to_hours")]),
        ]
        func column(_ name: String) -> CmsColumnPresentation { columns[name] ?? CmsColumnPresentation(key: name, json: nil) }
        let r = row(#"{ "hours": 6, "start": "2026-10-25T05:00:00", "end": "2026-10-25T11:00:00", "job": "KFC", "secs": 7200 }"#)
        XCTAssertEqual(CmsListRowLayout.fill("{hours}", row: r, column: column), "6h")
        XCTAssertEqual(CmsListRowLayout.fill("{start} – {end}", row: r, column: column), "5:00 – 11:00")
        XCTAssertEqual(CmsListRowLayout.fill("{secs}", row: r, column: column), "2", "the column's transform")
        XCTAssertEqual(CmsListRowLayout.fill("{job} • {role}", row: r, column: column), "KFC",
                       "an empty slot draws as nothing, and so do the words joining it")
        XCTAssertEqual(CmsListRowLayout.fill("{role} – {job}", row: r, column: column), "KFC")
        XCTAssertEqual(CmsListRowLayout.fill("{job}, {role}, {hours}", row: r, column: column), "KFC, 6h")
        XCTAssertEqual(CmsListRowLayout.fill("At {job}", row: r, column: column), "At KFC")
        XCTAssertNil(CmsListRowLayout.fill("{role} • {other}", row: r, column: column), "a line left empty is dropped")
        XCTAssertEqual(CmsListRowLayout.fill("Fixed words", row: r, column: column), "Fixed words")
    }

    func testDateBlock() throws {
        let en = Locale(identifier: "en_GB")
        let london = TimeZone(identifier: "Europe/London")!
        let bare = try XCTUnwrap(CmsListRowLayout.dateParts(.string("2026-10-25"), locale: en, timeZone: london))
        XCTAssertEqual(bare.weekday, "Sun")
        XCTAssertEqual(bare.day, "25")
        let instant = try XCTUnwrap(CmsListRowLayout.dateParts(.string("2026-10-25T23:30:00Z"), locale: en,
                                                               timeZone: TimeZone(identifier: "Asia/Tokyo")!))
        XCTAssertEqual(instant.day, "26", "a timestamp is shown in the viewer's time zone")
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertEqual(CmsListRowLayout.dateParts(.string("2026-10-25T23:30:00"), locale: en, timeZone: tokyo)?.day, "26",
                       "a naive datetime counts as UTC")
        XCTAssertEqual(CmsListRowLayout.dateParts(.string("2026-10-25 23:30"), naiveIsLocal: true, locale: en,
                                                  timeZone: tokyo)?.day, "25", "timezone local: as written")
        XCTAssertEqual(CmsListRowLayout.dateParts(.string("2026-10-25"), locale: en, timeZone: tokyo)?.day, "25",
                       "a bare date is that day everywhere")
        XCTAssertNil(CmsListRowLayout.dateParts(.null))
        XCTAssertNil(CmsListRowLayout.dateParts(.string("")))
    }

    // MARK: The list style's new levers

    func testNewLeversMergeOneObjectAtATime() throws {
        let config = try JSONDecoder().decode(CmsPortalThemeConfig.self, from: Data("""
        { "listStyles": { "shift": { "basedOn": "cards",
            "chip": { "variant": "glass", "size": 13 },
            "leading": { "date": { "top": { "color": "primary" } } },
            "trailing": { "align": "middle" },
            "lines": { "color": "#123456" } } } }
        """.utf8))
        let style = config.listStyle(block: "shift").style
        XCTAssertEqual(style.chip?.variant, "outlined", "an unknown variant takes the built-in's")
        XCTAssertEqual(style.chip?.size, 13)
        XCTAssertEqual(style.chip?.paddingVertical, CmsListStyle.cards.chip?.paddingVertical)
        XCTAssertEqual(style.leading?.date?.top?.color, .primary)
        XCTAssertEqual(style.leading?.date?.top?.uppercase, true, "the rest of the weekday from the built-in")
        XCTAssertEqual(style.leading?.date?.bottom, CmsListStyle.cards.leading?.date?.bottom)
        XCTAssertEqual(style.trailing?.align, "spread", "an unknown align takes the built-in's")
        XCTAssertEqual(style.lines?.color, .mutedText, "a colour that isn't a role takes the built-in's")
        XCTAssertEqual(style.inlineImage, CmsListStyle.cards.inlineImage)
    }

    func testAPictureThatDoesntLoadTakesNoSpace() {
        XCTAssertFalse(CmsPictureLoad(nil).takesSpace, "a 404 or a failed load: no picture and no space")
        XCTAssertTrue(CmsPictureLoad.loading.takesSpace, "loading holds the place, invisibly")
        #if canImport(UIKit)
        XCTAssertTrue(CmsPictureLoad(UIImage()).takesSpace)
        #endif
    }

    func testNewNavIcons() {
        XCTAssertEqual(CmsNavIcon.symbol(for: "swap"), "arrow.left.arrow.right")
        XCTAssertEqual(CmsNavIcon.symbol(for: "check"), "checkmark.circle.fill")
        XCTAssertNotNil(CmsNavIcon.symbol(for: "sick"))
        XCTAssertNotNil(CmsNavIcon.symbol(for: "holiday"))
    }
}
