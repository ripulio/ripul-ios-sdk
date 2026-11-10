import XCTest
@testable import RipulAgent

/// A site's own text styles, held to the web's resolveTypography and siteTextStyle.
final class CmsSiteTextTests: XCTestCase {
    func testCssLengths() {
        XCTAssertEqual(CmsCssLength.points("17px", viewport: 390), 17)
        XCTAssertEqual(CmsCssLength.points("1.5rem", viewport: 390), 24)
        XCTAssertEqual(CmsCssLength.points("10vw", viewport: 390), 39)
        // Sandsend's body1 at a 390-wide phone: 17.77 + 0.315 × 3.9 = 19.0, held at least 19.
        XCTAssertEqual(CmsCssLength.points("clamp(19px, calc(17.77px + 0.315vw), 21.8px)", viewport: 390)!, 19, accuracy: 0.01)
        XCTAssertEqual(CmsCssLength.points("clamp(19px, calc(17.77px + 0.315vw), 21.8px)", viewport: 1400)!, 21.8, accuracy: 0.01)
        // h1: 28.87 + 2.314 × 3.9 = 37.9.
        XCTAssertEqual(CmsCssLength.points("clamp(37.9px, calc(28.87px + 2.314vw), 58.2px)", viewport: 390)!, 37.9, accuracy: 0.05)
        XCTAssertEqual(CmsCssLength.points("max(12px, 2vw)", viewport: 390), 12)
        XCTAssertNil(CmsCssLength.points("large", viewport: 390))
        XCTAssertNil(CmsCssLength.points(nil, viewport: 390))
    }

    private let styles: [String: CmsSiteTextStyleConfig] = [
        "body1": .init(fontFamily: "\"freight-sans-pro\", \"Source Sans 3\", sans-serif", fontSize: "19px", fontWeight: 350,
                       lineHeight: "1.4", textAlign: "center", color: "color.primary"),
        "h2": .init(fontFamily: "\"ivypresto-display\", \"Playfair Display\", serif", fontSize: "31.9px", fontWeight: 600,
                    lineHeight: "1.2", textAlign: "center", color: "color.primary"),
    ]

    func testABlockWithNoTypographyFollowsItsElementsStyle() {
        let p = CmsSiteText.resolve(typography: nil, element: "p", styles: styles, viewport: 390)
        XCTAssertEqual(p?.size, 19)
        XCTAssertEqual(p?.weight, 350)
        XCTAssertEqual(p?.align, "center")
        XCTAssertEqual(p?.lineHeight, 1.4)
        XCTAssertEqual(p?.color, "color.primary")
        XCTAssertEqual(CmsSiteText.resolve(typography: [:], element: "h2", styles: styles, viewport: 390)?.weight, 600)
        // An element the site has no style for draws as before.
        XCTAssertNil(CmsSiteText.resolve(typography: nil, element: "h3", styles: styles, viewport: 390))
        XCTAssertNil(CmsSiteText.resolve(typography: nil, element: "p", styles: nil, viewport: 390))
    }

    func testAVariantWithTheBlocksOwnSettingsOverIt() {
        let t: [String: CmsJSON] = ["variant": .string("body1"), "color": .string("color.secondary"), "size": .string("24px")]
        let r = CmsSiteText.resolve(typography: t, element: "p", styles: styles, viewport: 390)
        XCTAssertEqual(r?.color, "color.secondary")
        XCTAssertEqual(r?.size, 24)
        XCTAssertEqual(r?.align, "center", "the variant's own")
        // Typography with no variant: only its own settings.
        let own = CmsSiteText.resolve(typography: ["textAlign": .string("left")], element: "p", styles: styles, viewport: 390)
        XCTAssertEqual(own?.align, "left")
        XCTAssertNil(own?.size)
    }

    /// A variant the site has no style for, a colour or an alignment changes
    /// nothing about the lettering: the block keeps its text style's font (and
    /// its taller lines) and a heading its theme family and weight.
    func testOnlyColourOrAlignSetsNoLettering() {
        let muted = CmsSiteText.resolve(typography: ["color": .string("color.mutedText"), "variant": .string("body2")],
                                        element: "p", styles: nil, viewport: 390)
        XCTAssertEqual(muted?.setsLettering, false)
        XCTAssertEqual(CmsSiteText.resolve(typography: ["textAlign": .string("center")], element: "h2", styles: nil, viewport: 390)?.setsLettering, false)
        XCTAssertEqual(CmsSiteText.resolve(typography: nil, element: "p", styles: styles, viewport: 390)?.setsLettering, true)
        XCTAssertEqual(CmsSiteText.resolve(typography: ["weight": .number(700)], element: "p", styles: nil, viewport: 390)?.setsLettering, true)
    }

    /// Android's cases (CmsPortalTheme.stackFamily), with Helvetica Neue for "Brand Sans".
    func testStackWalkMatchesAndroid() {
        XCTAssertEqual(CmsSiteText.installedFamily(stack: "freight-sans, ivypresto, Helvetica Neue, sans-serif"), "Helvetica Neue")
        XCTAssertEqual(CmsSiteText.installedFamily(stack: "'Missing One', \"Helvetica Neue\""), "Helvetica Neue")
        // A generic family ends the walk, as a browser's does.
        XCTAssertNil(CmsSiteText.installedFamily(stack: "freight-sans, sans-serif, Helvetica Neue"))
        XCTAssertNil(CmsSiteText.installedFamily(stack: "freight-sans, ivypresto"))
        // Case and spaces don't matter; the device's own spelling comes back.
        XCTAssertEqual(CmsSiteText.installedFamily(stack: " helvetica neue "), "Helvetica Neue")
    }

    func testTheFontIsTheFirstInTheStackThisDeviceHas() {
        XCTAssertNil(CmsSiteText.installedFamily(stack: "\"not-a-font-anyone-has\", sans-serif"))
        // Helvetica Neue is on every Apple platform; the web font before it is not.
        XCTAssertEqual(CmsSiteText.installedFamily(stack: "\"freight-sans-pro\", \"Helvetica Neue\", Arial, sans-serif"), "Helvetica Neue")
    }

    func testPagePaddingWithExpressions() {
        // Sandsend's page frame: 24 at a phone's width, a centred 1160 column on a wide screen.
        let phone = CmsCss.insets("56px max(24px, calc(50% - 580px)) 80px", width: 390)
        XCTAssertEqual(phone?.top, 56); XCTAssertEqual(phone?.leading, 24); XCTAssertEqual(phone?.trailing, 24); XCTAssertEqual(phone?.bottom, 80)
        XCTAssertEqual(CmsCss.insets("56px max(24px, calc(50% - 580px)) 80px", width: 1400)?.leading, 120)
        XCTAssertEqual(CmsCss.insets("8px 16px")?.leading, 16)
        XCTAssertEqual(CmsCss.topLevelParts("a max(1px, 2px) b"), ["a", "max(1px, 2px)", "b"])
    }

    func testLayeredCssBackgrounds() {
        let hero = CmsCssBackground("linear-gradient(rgba(78,96,131,0.18), rgba(78,96,131,0.38)), url('https://x.test/a.jpg') center / cover no-repeat")
        XCTAssertEqual(hero?.layers, [
            .gradient(stops: ["rgba(78,96,131,0.18)", "rgba(78,96,131,0.38)"], angle: 180),
            .image(url: "https://x.test/a.jpg", contain: false),
        ])
        XCTAssertEqual(CmsCssBackground("linear-gradient(90deg, #fff 0%, #000 100%)")?.layers, [.gradient(stops: ["#fff", "#000"], angle: 90)])
        XCTAssertEqual(CmsCssBackground("url(\"https://x.test/b.png\") center / contain")?.layers, [.image(url: "https://x.test/b.png", contain: true)])
        // A plain colour stays with the frame's ordinary fill.
        XCTAssertNil(CmsCssBackground("#1c3664"))
        XCTAssertNil(CmsCssBackground(nil))
    }

    func testMarkdownTakesTheSitesStyles() throws {
        let config = try JSONDecoder().decode(CmsPortalThemeConfig.Typography.self, from: Data(#"""
        {"paragraphSpacing":"0.87em","styles":{
          "body1":{"fontFamily":"'freight-sans-pro', 'Helvetica Neue'","fontSize":"19px","fontWeight":350,"textAlign":"center","color":"color.primary"},
          "h3":{"fontFamily":"'ivypresto-display', serif","fontSize":"23px","fontWeight":600,"textAlign":"center"}}}
        """#.utf8))
        let site = try XCTUnwrap(CmsSiteMarkdown(typography: nil, config: config, linkColour: nil, viewport: 390))
        XCTAssertEqual(site.body.size, 19)
        XCTAssertEqual(site.alignment, .center)
        XCTAssertEqual(site.spacing ?? 0, 16.53, accuracy: 0.01, "0.87em of the body's 19")
        // Headings take the site's style but never its alignment.
        XCTAssertEqual(site.headings[3]?.size, 23)
        XCTAssertNil(site.headings[3]?.align)
        XCTAssertNil(site.headings[2], "a level the site has no style for keeps the renderer's")
        // The block's own typography: its variant and settings, its colour reaching headings.
        let own = try XCTUnwrap(CmsSiteMarkdown(typography: ["variant": .string("body1"), "textAlign": .string("left"), "color": .string("color.secondary")],
                                                config: config, linkColour: "color.primary", viewport: 390))
        XCTAssertEqual(own.alignment, .leading)
        XCTAssertEqual(own.ownColour, "color.secondary")
        XCTAssertEqual(own.linkColour, "color.primary")
        // No site styles and no typography: the renderer's own look.
        XCTAssertNil(CmsSiteMarkdown(typography: nil, config: nil, linkColour: nil, viewport: 390))
    }

    func testSmartQuotes() {
        XCTAssertEqual(CmsSiteText.typographicQuotes("it's \"ours\" and 'theirs'"), "it’s “ours” and ‘theirs’")
    }
}
