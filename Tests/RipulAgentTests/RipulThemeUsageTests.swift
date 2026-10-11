import XCTest
@testable import RipulAgent

/// The theme usage map: an identifier gives the tokens its source names, each resolved
/// against the live theme, and an identifier the map does not know gives nothing.
final class RipulThemeUsageTests: XCTestCase {
    override func setUp() { RipulTheme.resetToDefaults() }
    override func tearDown() { RipulTheme.resetToDefaults() }

    /// Neutral names: nothing here is one of Ripul's screens.
    private let json = """
    {"schema":1,"elements":{
      "Catalogue.offer.title":[{"file":"Shop/OfferRow.swift","line":40,"text":true,"tokens":[
        {"k":"type","role":"headline","property":"Font","file":"Shop/OfferRow.swift","line":38},
        {"k":"colour","role":"textSecondary","form":"style","property":"Foreground","file":"Shop/OfferRow.swift","line":39}]}],
      "Catalogue.offer.*":[{"file":"Shop/OfferRow.swift","line":60,"parts":["Catalogue.offer.title"],"tokens":[
        {"k":"colour","role":"accent","form":"style","property":"Fill","cond":true,"file":"Shop/OfferRow.swift","line":58},
        {"k":"icon","size":"18","weight":"semibold","property":"Font","file":"Shop/OfferRow.swift","line":57},
        {"k":"control","name":"prominentButton","file":"Shop/OfferRow.swift","line":59},
        {"k":"colour","role":"info","accentOr":true,"form":"style","property":"Foreground","via":"Badge","file":"Shop/Badge.swift","line":9}]}],
      "Catalogue.plain":[{"file":"Shop/Plain.swift","line":5,"text":true,"tokens":[]}],
      "Catalogue.back":[{"file":"Shop/Bar.swift","line":9,"tokens":[
        {"k":"colour","role":"text","property":"Foreground","ctl":"Button","line":7}]}],
      "Catalogue.plainBack":[{"file":"Shop/Bar.swift","line":19,"tokens":[
        {"k":"colour","role":"text","property":"Foreground","ctl":"Button","ctlStyle":".plain","line":17}]}],
      "Catalogue.boxedBack":[{"file":"Shop/Bar.swift","line":29,"tokens":[
        {"k":"colour","role":"textSecondary","property":"Foreground","ctl":"Button","ctlStyle":".bordered","line":27}]}],
      "Catalogue.fixedBack":[{"file":"Shop/Bar.swift","line":39,"tokens":[
        {"k":"colour","role":"text","form":"Color","property":"Foreground","ctl":"Button","line":37}]}],
      "Catalogue.item":[{"file":"Shop/Bar.swift","line":59,"tokens":[
        {"k":"colour","role":"text","property":"Foreground","ctl":"Button","ctlIn":"menu","line":57}]}],
      "Catalogue.bare":[{"file":"Shop/Bar.swift","line":49,"tokens":[
        {"k":"control","name":"buttonTint","ctl":"Menu","line":47}]}],
      "*.*":[{"file":"Shop/Any.swift","line":1,"tokens":[{"k":"type","role":"caption","line":1}]}],
      "Catalogue.brand":[{"file":"Shop/Brand.swift","line":8,"text":true,"tokens":[
        {"k":"other","property":"Foreground","src":"supplier.colour","line":7},
        {"k":"other","property":"Font","src":"supplier.font","line":6}]}],
      "Catalogue.twice":[
        {"file":"Shop/A.swift","line":1,"tokens":[{"k":"type","role":"caption","file":"Shop/A.swift","line":1}]},
        {"file":"Shop/B.swift","line":2,"tokens":[{"k":"type","role":"body","file":"Shop/B.swift","line":2}]}]
    }}
    """

    private func map() throws -> RipulThemeUsageMap { try XCTUnwrap(RipulThemeUsageMap(data: Data(json.utf8))) }

    func testAnExactIdentifierWinsOverAPattern() throws {
        let answer = try XCTUnwrap(map().answer(for: "Catalogue.offer.title"))
        XCTAssertEqual(answer.places, ["OfferRow.swift:40"])
        XCTAssertEqual(answer.lines.map(\.token), ["headline", "ripul.textSecondary"])
    }

    func testAnIdentifierBuiltAtRunTimeMatchesItsPattern() throws {
        let answer = try XCTUnwrap(map().answer(for: "Catalogue.offer.42"))
        XCTAssertEqual(answer.places, ["OfferRow.swift:60"])
        XCTAssertEqual(answer.parts, ["Catalogue.offer.title"])
        XCTAssertNil(try map().answer(for: "Catalogue.offer."), "a pattern's gap is never empty")
    }

    func testAnUnknownIdentifierGivesNothing() throws {
        XCTAssertNil(try map().answer(for: "Elsewhere.thing"), "a pattern that is all gap matches nothing")
        XCTAssertNil(RipulThemeUsageMap(data: Data("[]".utf8)))
    }

    func testWithNoThemeEveryLineIsTheDefault() throws {
        let lines = try XCTUnwrap(map().answer(for: "Catalogue.offer.title")).lines
        XCTAssertEqual(lines[0].property, "Font")
        XCTAssertTrue(lines[0].value.hasPrefix("system font"), lines[0].value)
        XCTAssertTrue(lines[0].value.hasSuffix("semibold"), "headline carries the system's weight: \(lines[0].value)")
        XCTAssertEqual(lines[0].origin, "default")
        XCTAssertEqual(lines[1].value, "system:secondaryLabel")
        XCTAssertEqual(lines[1].origin, "default")
        XCTAssertEqual(lines[1].text, "Foreground: ripul.textSecondary = system:secondaryLabel, default")
    }

    func testAThemeDocumentChangesTheValueAndTheOrigin() throws {
        try RipulTheme.adopt(documentData: Data("""
        {"palette":{"teal":{"light":"#1f6f70","dark":"#62b9b4"}},"roles":{"ripul.accent":"teal"},
         "typography":{"families":{"text":"Archivo"}}}
        """.utf8))
        let title = try XCTUnwrap(map().answer(for: "Catalogue.offer.title")).lines
        XCTAssertTrue(title[0].value.hasPrefix("Archivo "), title[0].value)
        XCTAssertEqual(title[0].origin, "family from the theme document")
        XCTAssertEqual(title[1].origin, "default", "the document names no text colour")

        let row = try XCTUnwrap(map().answer(for: "Catalogue.offer.7")).lines
        let fill = try XCTUnwrap(row.first { $0.property.hasPrefix("Fill") })
        XCTAssertEqual(fill.property, "Fill (one of several)")
        // A light and dark pair is shown as a pair, never as one colour.
        XCTAssertEqual(fill.value, "#1F6F70 light, #62B9B4 dark")
        XCTAssertEqual(fill.origin, "theme document")
        XCTAssertEqual(fill.colour?.dark, RipulColorLiteral("#62b9b4"))
    }

    func testASymbolSizeIsNeverThemed() throws {
        let icon = try XCTUnwrap(map().answer(for: "Catalogue.offer.7")?.lines.first { $0.token == "symbol size" })
        XCTAssertEqual(icon.value, "18 pt semibold")
        XCTAssertEqual(icon.origin, "never themed")
    }

    func testAnAccentOrRoleIsTheRoleUntilAThemeNamesAnAccent() throws {
        func badge() throws -> RipulThemeUsageLine {
            try XCTUnwrap(map().answer(for: "Catalogue.offer.7")?.lines.first { $0.property.contains("in Badge") })
        }
        XCTAssertEqual(try badge().token, "ripul.info")
        try RipulTheme.adopt(documentData: Data(##"{"roles":{"accent":"#112233"}}"##.utf8))
        XCTAssertEqual(try badge().token, "ripul.accent")
        XCTAssertEqual(try badge().value, "#112233")
    }

    func testAProminentButtonNamesItsFillAndItsLabel() throws {
        let lines = try XCTUnwrap(map().answer(for: "Catalogue.offer.7")).lines
        XCTAssertEqual(lines.first { $0.property == "Button fill" }?.token, "ripul.accent")
        XCTAssertEqual(lines.first { $0.property == "Button label" }?.value, "the system's white label")
    }

    func testTextWithNoFontIsSaidSo() throws {
        let plain = try XCTUnwrap(map().answer(for: "Catalogue.plain"))
        XCTAssertTrue(plain.lines.isEmpty)
        XCTAssertTrue(plain.textWithNoFont)
        XCTAssertFalse(try XCTUnwrap(map().answer(for: "Catalogue.offer.title")).textWithNoFont)
    }

    // MARK: what the system draws, where it is not what the source writes

    private func line(_ id: String) throws -> RipulThemeUsageLine { try XCTUnwrap(map().answer(for: id)?.lines.first) }

    func testATextRoleInsideAButtonIsDrawnInTheAccent() throws {
        try RipulTheme.adopt(documentData: Data("""
        {"palette":{"teal":{"light":"#1f6f70","dark":"#62b9b4"}},"roles":{"ripul.accent":"teal"}}
        """.utf8))
        let back = try line("Catalogue.back")
        XCTAssertEqual(back.token, "ripul.accent, as the system draws it")
        XCTAssertEqual(back.value, "#1F6F70 light, #62B9B4 dark")
        XCTAssertEqual(back.colour, RipulTheme.color(.accent), "the swatch is the accent, not the text colour")
        XCTAssertTrue(back.origin.contains("the source writes ripul.text"), back.origin)
        XCTAssertFalse(back.isWindowTint)
    }

    func testWithNoThemeTheAccentIsTheWindowsTint() throws {
        let back = try line("Catalogue.back")
        XCTAssertEqual(back.value, "system:tint")
        XCTAssertTrue(back.isWindowTint)
    }

    func testAThemedTextRoleInsideAButtonIsDrawnAsWritten() throws {
        try RipulTheme.adopt(documentData: Data(##"{"roles":{"text":"#102030"}}"##.utf8))
        let back = try line("Catalogue.back")
        XCTAssertEqual(back.token, "ripul.text")
        XCTAssertEqual(back.value, "#102030")
    }

    func testAPlainButtonAndAColorFormAreDrawnAsWritten() throws {
        XCTAssertEqual(try line("Catalogue.plainBack").token, "ripul.text")
        XCTAssertEqual(try line("Catalogue.fixedBack").token, "ripul.text")
    }

    func testAnotherButtonStyleShowsNoSwatch() throws {
        let boxed = try line("Catalogue.boxedBack")
        XCTAssertEqual(boxed.token, "ripul.textSecondary")
        XCTAssertNil(boxed.colour, "the label colour a style draws is not known here")
        XCTAssertTrue(boxed.origin.contains(".bordered"), boxed.origin)
    }

    func testAMenuItemShowsNoSwatch() throws {
        let item = try line("Catalogue.item")
        XCTAssertEqual(item.token, "ripul.text")
        XCTAssertNil(item.colour)
    }

    func testAControlWithNoForegroundIsTheTint() throws {
        let bare = try line("Catalogue.bare")
        XCTAssertEqual(bare.property, "Menu label")
        XCTAssertEqual(bare.token, "none written")
        XCTAssertNil(bare.colour, "where it sits decides the colour, so no swatch is shown")
        XCTAssertTrue(bare.origin.contains("usually ripul.accent"), bare.origin)
    }

    func testAFontOrColourThatIsNotATokenIsSaidSo() throws {
        let brand = try XCTUnwrap(map().answer(for: "Catalogue.brand"))
        XCTAssertEqual(brand.lines.first?.text, "Foreground: not a theme token = supplier.colour, set in code or from data")
        XCTAssertFalse(brand.textWithNoFont, "a font is written, though not a token")
    }

    func testAnIdentifierWrittenTwiceSaysWhichPlaceIsNotKnown() throws {
        let twice = try XCTUnwrap(map().answer(for: "Catalogue.twice"))
        XCTAssertEqual(twice.places, ["A.swift:1", "B.swift:2"])
        XCTAssertEqual(twice.lines.map(\.property), ["Font (in one of 2 places)", "Font (in one of 2 places)"])
    }
}
