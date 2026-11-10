import XCTest
import SwiftUI
@testable import RipulAgent

/// List styles in a CMS site's theme (docs/cms-list-styles.md): decoding,
/// which style a list uses, palette roles in light and dark, the built-in
/// values against the web's table, the engine's cascade, and the link list.
final class CmsListStylesTests: XCTestCase {
    private func theme(_ json: String) throws -> CmsPortalThemeConfig {
        try JSONDecoder().decode(CmsPortalThemeConfig.self, from: Data(json.utf8))
    }

    // MARK: The built-ins against the web's table

    /// The web's table, shared by both renderers.
    private func sharedTable() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("chrome-extension/packages/shared-types/src/cmsListStyles.builtin.json")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testBuiltInsEqualTheSharedTable() throws {
        let table = try sharedTable()
        let styles = try XCTUnwrap(table["styles"] as? [String: Any])
        XCTAssertEqual(Set(styles.keys), Set(CmsListStyle.builtInNames))
        for (name, raw) in styles {
            var object = try XCTUnwrap(raw as? [String: Any])
            // The table names the layout `layout`; a site style says `basedOn`.
            object["basedOn"] = object.removeValue(forKey: "layout")
            let data = try JSONSerialization.data(withJSONObject: object)
            let decoded = try JSONDecoder().decode(CmsListStyle.self, from: data)
            XCTAssertEqual(decoded, CmsListStyle.builtIns[name], "built-in \(name) differs from the web's table")
            // Every setting is filled: re-encoding gives back the table's keys exactly.
            let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? NSDictionary
            XCTAssertEqual(encoded, object as NSDictionary, "built-in \(name) has a setting the table lacks, or the reverse")
        }
    }

    func testPaletteRolesEqualTheSharedTable() throws {
        let roles = try XCTUnwrap(try sharedTable()["paletteRoles"] as? [String])
        XCTAssertEqual(roles, CmsPaletteRole.allCases.map(\.rawValue))
    }

    // MARK: Decoding

    func testDecodesListStylesAndDefault() throws {
        let config = try theme("""
        { "defaultListStyle": "wac",
          "listStyles": {
            "wac": { "basedOn": "cards",
                     "card": { "cornerRadius": 10, "shadow": { "radius": 10, "offsetY": "2" }, "pageBackground": "surfaceMuted" },
                     "row": { "minHeight": 86, "separators": false },
                     "picture": { "badge": "circle", "badgeSize": 32, "badgeTint": "tint" },
                     "title": { "size": 18, "weight": 500, "color": "primary" } } } }
        """)
        XCTAssertEqual(config.defaultListStyle, "wac")
        let wac = try XCTUnwrap(config.listStyles?["wac"])
        XCTAssertEqual(wac.basedOn, .cards)
        XCTAssertEqual(wac.card?.cornerRadius, 10)
        XCTAssertEqual(wac.card?.shadow?.offsetY, 2, "a numeric string reads as a number")
        XCTAssertNil(wac.card?.shadow?.color)
        XCTAssertEqual(wac.card?.pageBackground, .surfaceMuted)
        XCTAssertEqual(wac.row?.minHeight, 86)
        XCTAssertEqual(wac.row?.separators, false)
        XCTAssertEqual(wac.picture?.badge, .circle)
        XCTAssertEqual(wac.title?.color, .primary)
    }

    func testDecodingIsLenient() throws {
        let config = try theme("""
        { "palette": { "primary": "#6F2D80" },
          "defaultListStyle": 3,
          "listStyles": {
            "broken": "not a style",
            "odd": { "basedOn": "glass", "card": { "fill": "#ffffff", "cornerRadius": "big" },
                     "row": { "chevron": "yes" }, "title": { "color": "brandPurple", "size": 20 } } } }
        """)
        XCTAssertEqual(config.palette?.primary, "#6F2D80", "the rest of the theme still decodes")
        XCTAssertNil(config.defaultListStyle)
        XCTAssertNil(config.listStyles?["broken"], "an entry that is not an object is skipped")
        let odd = try XCTUnwrap(config.listStyles?["odd"])
        XCTAssertNil(odd.basedOn, "an unknown layout is unset")
        XCTAssertNil(odd.card?.fill, "a colour that is not a palette role is unset")
        XCTAssertNil(odd.card?.cornerRadius)
        XCTAssertNil(odd.row?.chevron)
        XCTAssertNil(odd.title?.color)
        XCTAssertEqual(odd.title?.size, 20)
        // Unset settings draw as the built-in's.
        let resolved = config.listStyle(block: "odd").style
        XCTAssertEqual(resolved.basedOn, .system)
        XCTAssertEqual(resolved.card?.fill, CmsListStyle.system.card?.fill)
        XCTAssertEqual(resolved.title?.color, .text)
        XCTAssertEqual(resolved.title?.size, 20)
    }

    // MARK: Which style a list uses

    func testResolutionOrder() throws {
        let config = try theme("""
        { "defaultListStyle": "mine",
          "listStyles": { "mine": { "basedOn": "plain" }, "other": { "basedOn": "cards" } } }
        """)
        XCTAssertEqual(config.listStyleName(block: "other"), "other", "the block's own style first")
        XCTAssertEqual(config.listStyleName(block: "cards"), "cards")
        XCTAssertEqual(config.listStyleName(block: nil), "mine", "then the theme's default")
        XCTAssertEqual(config.listStyleName(block: ""), "mine")
        XCTAssertEqual(config.listStyleName(block: "missing"), "mine", "a name that names no style is passed over")
        XCTAssertEqual(CmsPortalThemeConfig().listStyleName(block: nil), "system", "then system")
        XCTAssertEqual(try theme(#"{ "defaultListStyle": "gone" }"#).listStyleName(block: "gone"), "system")
        let none: CmsPortalThemeConfig? = nil
        XCTAssertEqual(none.listStyle(block: "cards").name, "cards")
        XCTAssertEqual(none.listStyle(block: nil).name, "system")
    }

    func testSiteCannotRedefineABuiltIn() throws {
        let config = try theme("""
        { "listStyles": { "cards": { "card": { "cornerRadius": 99 } } }, "defaultListStyle": "cards" }
        """)
        let resolved = config.listStyle(block: nil)
        XCTAssertEqual(resolved.name, "cards")
        XCTAssertEqual(resolved.style, CmsListStyle.cards, "the built-in wins")
        XCTAssertTrue(resolved.explicit.isEmpty)
    }

    func testSiteStyleFillsFromItsBuiltInOneLevelAtATime() throws {
        let config = try theme("""
        { "listStyles": { "wac": { "basedOn": "cards", "card": { "shadow": { "radius": 10 } }, "row": { "minHeight": 86 } } } }
        """)
        let resolved = config.listStyle(block: "wac")
        let style = resolved.style
        XCTAssertEqual(style.basedOn, .cards)
        XCTAssertEqual(style.card?.shadow?.radius, 10)
        XCTAssertEqual(style.card?.shadow?.offsetY, CmsListStyle.cards.card?.shadow?.offsetY, "other shadow fields kept")
        XCTAssertEqual(style.card?.shadow?.opacity, CmsListStyle.cards.card?.shadow?.opacity)
        XCTAssertEqual(style.card?.cornerRadius, CmsListStyle.cards.card?.cornerRadius)
        XCTAssertEqual(style.row?.minHeight, 86)
        XCTAssertEqual(style.row?.separators, CmsListStyle.cards.row?.separators)
        XCTAssertEqual(style.picture, CmsListStyle.cards.picture)
        XCTAssertEqual(resolved.explicit.card?.shadow?.radius, 10)
        XCTAssertNil(resolved.explicit.card?.cornerRadius, "explicit holds only what the site set")

        let unbased = try theme(#"{ "listStyles": { "x": { "title": { "size": 20 } } } }"#).listStyle(block: "x").style
        XCTAssertEqual(unbased.basedOn, .system, "basedOn unset = system")
        XCTAssertEqual(unbased.row, CmsListStyle.system.row)
    }

    func testBareSystemOnlyForTheBuiltIn() throws {
        let config = try theme(#"{ "listStyles": { "quiet": { "basedOn": "system", "title": { "size": 15 } } } }"#)
        XCTAssertTrue(CmsResolvedListStyle(config: nil, block: nil, dark: false).isBareSystem)
        XCTAssertTrue(CmsResolvedListStyle(config: config, block: "system", dark: false).isBareSystem)
        let quiet = CmsResolvedListStyle(config: config, block: "quiet", dark: false)
        XCTAssertFalse(quiet.isBareSystem, "a site's own system-based style draws its values")
        XCTAssertEqual(quiet.layout, .system)
    }

    // MARK: Colours from palette roles, light and dark

    private let paletteJSON = """
    { "palette": { "primary": "#6F2D80", "accent": "#12CEA8", "text": "#373635", "mutedText": "#777777",
                   "background": "#F2F2F7", "paper": "#FFFFFF", "divider": "#DDDDDD" },
      "darkPalette": { "text": "#F5F5F5", "background": "#000000", "paper": "#1C1C1E" },
      "listStyles": { "wac": { "basedOn": "cards", "card": { "fill": "paper", "pageBackground": "background",
                               "shadow": { "color": "primary", "opacity": 0.5 } },
                               "title": { "color": "text" }, "picture": { "badgeTint": "accent" } } } }
    """

    private func assertRGBA(_ c: CmsRGBA, _ hex: String, alpha: Double = 1,
                            file: StaticString = #filePath, line: UInt = #line) {
        let expected = CmsRGBA(css: hex)!
        XCTAssertEqual(c.r, expected.r, accuracy: 0.002, file: file, line: line)
        XCTAssertEqual(c.g, expected.g, accuracy: 0.002, file: file, line: line)
        XCTAssertEqual(c.b, expected.b, accuracy: 0.002, file: file, line: line)
        XCTAssertEqual(c.a, alpha, accuracy: 0.002, file: file, line: line)
    }

    func testColoursResolveFromRolesInLight() throws {
        let config = try theme(paletteJSON)
        let style = CmsResolvedListStyle(config: config, block: "wac", dark: false)
        let s = style.style
        assertRGBA(style.rgba(try XCTUnwrap(s.card?.fill)), "#FFFFFF")
        assertRGBA(style.rgba(try XCTUnwrap(s.card?.pageBackground)), "#F2F2F7")
        assertRGBA(style.rgba(try XCTUnwrap(s.title?.color)), "#373635")
        assertRGBA(style.rgba(try XCTUnwrap(s.subtitle?.color)), "#777777")
        assertRGBA(style.rgba(try XCTUnwrap(s.picture?.badgeTint)), "#12CEA8")
        XCTAssertEqual(style.fill, CmsRGBA(css: "#FFFFFF")!.color)
        XCTAssertEqual(style.titleColor, CmsRGBA(css: "#373635")!.color)
        XCTAssertEqual(style.shadowColor, CmsRGBA(css: "#6F2D80")!.withAlpha(0.5).color,
                       "the shadow is its role's colour at the style's opacity")
    }

    func testColoursFollowTheDarkPalette() throws {
        let config = try theme(paletteJSON)
        let style = CmsResolvedListStyle(config: config, block: "wac", dark: true)
        assertRGBA(style.rgba(.paper), "#1C1C1E")
        assertRGBA(style.rgba(.background), "#000000")
        assertRGBA(style.rgba(.text), "#F5F5F5")
        assertRGBA(style.rgba(.primary), "#6F2D80", alpha: 1)
        XCTAssertEqual(style.fill, CmsRGBA(css: "#1C1C1E")!.color)
        XCTAssertEqual(style.titleColor, CmsRGBA(css: "#F5F5F5")!.color)
        // A theme pinned to light stays light.
        var pinned = config
        pinned.mode = "light"
        assertRGBA(CmsResolvedListStyle(config: pinned, block: "wac", dark: true).rgba(.paper), "#FFFFFF")
    }

    func testEveryRoleHasAColourWithNoPalette() {
        let light = CmsPortalTheme(config: nil, effectiveDark: false)
        let dark = CmsPortalTheme(config: nil, effectiveDark: true)
        XCTAssertEqual(Set(light.roleRGBA.keys), Set(CmsPaletteRole.allCases))
        assertRGBA(light.rgba(role: .text), "#000000", alpha: 0.87)
        assertRGBA(dark.rgba(role: .text), "#ffffff")
        assertRGBA(light.rgba(role: .paper), "#ffffff")
        assertRGBA(dark.rgba(role: .paper), "#121212")
        XCTAssertEqual(light.rgba(role: .tint), light.tintRGBA)
    }

    // MARK: Page background and font family

    func testPageBackgroundOnlyWhenThePaletteNamesOne() throws {
        XCTAssertFalse(CmsPortalTheme(config: nil, effectiveDark: false).setsPageBackground,
                       "a site that sets nothing keeps the system background")
        XCTAssertFalse(CmsPortalTheme(config: try theme(##"{ "palette": { "primary": "#6F2D80" } }"##),
                                      effectiveDark: false).setsPageBackground)
        let grey = try theme(##"{ "palette": { "background": "#EFEFEF" }, "darkPalette": { "background": "#000000" } }"##)
        let light = CmsPortalTheme(config: grey, effectiveDark: false)
        XCTAssertTrue(light.setsPageBackground)
        assertRGBA(light.rgba(role: .background), "#EFEFEF")
        let dark = CmsPortalTheme(config: grey, effectiveDark: true)
        XCTAssertTrue(dark.setsPageBackground)
        assertRGBA(dark.rgba(role: .background), "#000000")
        let darkOnly = try theme(##"{ "darkPalette": { "background": "#000000" } }"##)
        XCTAssertFalse(CmsPortalTheme(config: darkOnly, effectiveDark: false).setsPageBackground)
        XCTAssertTrue(CmsPortalTheme(config: darkOnly, effectiveDark: true).setsPageBackground)
    }

    func testFontFamilyOnlyWhenInstalled() throws {
        let helvetica = try theme(##"{ "typography": { "fontFamily": "'Helvetica Neue', sans-serif" } }"##)
        XCTAssertEqual(CmsPortalTheme(config: helvetica).fontFamily, "Helvetica Neue",
                       "the stack's first family, unquoted, when installed")
        let missing = try theme(##"{ "typography": { "fontFamily": "Not A Real Family, sans-serif" } }"##)
        XCTAssertNil(CmsPortalTheme(config: missing).fontFamily, "not installed: the system font")
        let generic = try theme(##"{ "typography": { "fontFamily": "system-ui" } }"##)
        XCTAssertNil(CmsPortalTheme(config: generic).fontFamily)
        XCTAssertNil(CmsPortalTheme(config: nil).fontFamily)
        let style = CmsResolvedListStyle(config: helvetica, block: "cards", dark: false)
        XCTAssertEqual(style.fontFamily, "Helvetica Neue")
        XCTAssertEqual(style.titleFont, Font.custom("Helvetica Neue", size: 17).weight(.semibold))
        XCTAssertEqual(CmsResolvedListStyle(config: missing, block: "cards", dark: false).titleFont,
                       Font.system(size: 17, weight: .semibold))
    }

    // MARK: Following the colour scheme

    @MainActor
    func testRuntimeRedrawsWhenTheColourSchemeChanges() throws {
        let runtime = CmsRuntime(cmsId: "cms_test", client: CmsClient(config: CmsClientConfig(getToken: { nil })))
        runtime.themeConfig = try theme(##"{ "palette": { "background": "#EFEFEF" }, "darkPalette": { "background": "#000000" } }"##)
        runtime.updateEffectiveDark(false)
        var changes = 0
        let watch = runtime.objectWillChange.sink { changes += 1 }
        defer { watch.cancel() }
        runtime.updateEffectiveDark(true)
        XCTAssertGreaterThan(changes, 0, "views that read the theme are told to redraw")
        XCTAssertTrue(runtime.theme.isDark)
        assertRGBA(runtime.theme.rgba(role: .background), "#000000")
        runtime.updateEffectiveDark(false)
        XCTAssertFalse(runtime.theme.isDark)
        assertRGBA(runtime.theme.rgba(role: .background), "#EFEFEF")
    }

    @MainActor
    func testAForcedModeIgnoresTheDevice() throws {
        let runtime = CmsRuntime(cmsId: "cms_test", client: CmsClient(config: CmsClientConfig(getToken: { nil })))
        runtime.themeConfig = try theme(##"{ "mode": "light", "darkPalette": { "background": "#000000" } }"##)
        runtime.updateEffectiveDark(true)
        XCTAssertFalse(runtime.theme.isDark, "mode light stays light on a dark phone")
    }

    func testForcedColourScheme() throws {
        XCTAssertEqual(try theme(##"{ "mode": "light" }"##).forcedColorScheme, .light)
        XCTAssertEqual(try theme(##"{ "mode": "dark" }"##).forcedColorScheme, .dark)
        XCTAssertNil(try theme(##"{ "mode": "system" }"##).forcedColorScheme)
        XCTAssertNil(CmsPortalThemeConfig().forcedColorScheme, "unset follows the device")
    }

    // MARK: The link list

    private func items(_ json: String) -> [CmsNavItem] {
        CmsNavItem.decodeList(try? JSONDecoder().decode(CmsJSON.self, from: Data(json.utf8)))
    }

    func testLinkListSections() {
        let list = items("""
        [ { "label": "Profile", "icon": "person", "description": "Name and photo", "targetPageSlug": "profile", "badge": "New" },
          { "label": "Work", "heading": true },
          { "label": "Jobs", "icon": "work", "targetPageSlug": "jobs", "children": [ { "label": "Child", "targetPageSlug": "c" } ] },
          { "label": "Export", "actionType": "exportSheet" },
          { "label": "Help", "url": "https://example.com/help" },
          { "label": "Empty", "heading": true },
          { "label": "Legal", "heading": true },
          { "label": "Terms", "targetPageSlug": "terms" } ]
        """)
        let sections = CmsLinkList.sections(list)
        XCTAssertEqual(sections.map(\.heading), [nil, "Work", "Legal"], "a heading with no rows is dropped")
        XCTAssertEqual(sections.map { $0.rows.map(\.label) }, [["Profile"], ["Jobs", "Help"], ["Terms"]],
                       "only links are rows")
        XCTAssertEqual(sections[0].rows[0].description, "Name and photo")
        XCTAssertEqual(sections[0].rows[0].badge, "New")
        XCTAssertEqual(sections[0].rows[0].icon, "person")
        XCTAssertTrue(sections[1].rows[0].children.isEmpty, "children are ignored")
        XCTAssertEqual(sections[1].rows[1].url, "https://example.com/help")
    }

    func testLinkListVisibility() {
        let list = items("""
        [ { "label": "Everyone", "targetPageSlug": "a" },
          { "label": "Members", "targetPageSlug": "b", "visibility": "members" },
          { "label": "Managers", "targetPageSlug": "c", "visibility": "roles", "requiredRoles": ["manager"] } ]
        """)
        let visitor = CmsLinkList.sections(CmsNavItem.visible(list, membership: nil, canDesign: false))
        XCTAssertEqual(visitor.flatMap { $0.rows.map(\.label) }, ["Everyone"])
        let designer = CmsLinkList.sections(CmsNavItem.visible(list, membership: nil, canDesign: true))
        XCTAssertEqual(designer.flatMap { $0.rows.map(\.label) }, ["Everyone", "Members", "Managers"])
    }

    // MARK: The engine's cascade

    #if os(iOS)
    func testKnobsRoundTrip() {
        for (name, style) in CmsListStyle.builtIns {
            let knobs = CmsListStyleKind.knobs(style)
            XCTAssertEqual(knobs["layout"]?.string, name)
            XCTAssertEqual(CmsListStyleKind.style(knobs), style, "\(name) survives knobs and back")
            XCTAssertEqual(Set(knobs.keys), Set(CmsListStyleKind.knobs.map(\.key)), "\(name): one knob per setting")
        }
        XCTAssertEqual(CmsListStyleKind.knobs(CmsListStyle.system)["row.separators"], .bool(true))
    }

    func testEngineCascadeEqualsTheRenderersResolution() throws {
        let config = try theme("""
        { "defaultListStyle": "wac",
          "listStyles": { "wac": { "basedOn": "cards", "card": { "shadow": { "radius": 10 } }, "title": { "size": 18 } },
                          "flat": { "basedOn": "plain", "row": { "chevron": false } },
                          "system": { "row": { "minHeight": 99 } } } }
        """)
        for block in [nil, "wac", "flat", "system", "plain", "cards", "missing"] as [String?] {
            XCTAssertEqual(CmsListStyleKind.resolve(config: config, block: block),
                           config.listStyle(block: block).style, "block \(block ?? "nil")")
        }
        XCTAssertNil(CmsListStyleKind.namedStyles(config)["system"], "a built-in name is not a site style")
        let kind = RipulStyleKind.cmsList()
        XCTAssertEqual(kind.name, "cmsList")
        XCTAssertEqual(Set(kind.builtIns.keys), Set(CmsListStyle.builtInNames))
        XCTAssertEqual(CmsListStyleKind.style(kind.resolve(element: CmsListStyleKind.element, style: nil)),
                       CmsListStyle.system, "the default tier is system")
    }
    #endif
}
