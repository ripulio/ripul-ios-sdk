import XCTest
import SwiftUI
@testable import RipulAgent

/// Home and Records levers (docs/plans/cms-home-records-levers.md): hidden
/// page titles, bleeding blocks, groups open by default, the floating button,
/// and the built-in `{today}` and `{timeOfDay}` slots.
final class CmsLeversTests: XCTestCase {
    private func json<T: Decodable>(_ type: T.Type, _ s: String) -> T {
        try! JSONDecoder().decode(type, from: Data(s.utf8))
    }

    private var london: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/London")!
        return c
    }

    private func at(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    // MARK: Built-in slots

    func testTodayOnTheViewersCalendar() {
        XCTAssertEqual(CmsLevers.builtIn("today", format: nil, now: at("2026-10-28T23:30:00Z"), calendar: london),
                       "28 Oct 2026", "unset format: d MMM yyyy")
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertEqual(CmsLevers.builtIn("today", format: nil, now: at("2026-10-28T23:30:00Z"), calendar: tokyo),
                       "29 Oct 2026", "the viewer's own day, not UTC's")
        XCTAssertEqual(CmsLevers.builtIn("today", format: "EEEE, d MMM yyyy", now: at("2026-10-28T09:00:00Z"), calendar: london),
                       "Wednesday, 28 Oct 2026")
        XCTAssertEqual(CmsLevers.builtIn("today", format: "EEEE", now: at("2026-10-28T09:00:00Z"), calendar: london),
                       "Wednesday", "a weekday on its own is still a date")
        XCTAssertEqual(CmsLevers.builtIn("today", format: #"d"th" MMMM"#, now: at("2026-10-28T09:00:00Z"), calendar: london),
                       "28th October", "double-quoted text is literal")
    }

    func testTimeOfDayOnTheViewersClock() {
        // London is on GMT after 25 October 2026.
        XCTAssertEqual(CmsLevers.builtIn("timeOfDay", format: nil, now: at("2026-10-28T11:59:00Z"), calendar: london), "morning")
        XCTAssertEqual(CmsLevers.builtIn("timeOfDay", format: nil, now: at("2026-10-28T12:00:00Z"), calendar: london), "afternoon")
        XCTAssertEqual(CmsLevers.builtIn("timeOfDay", format: nil, now: at("2026-10-28T17:59:00Z"), calendar: london), "afternoon")
        XCTAssertEqual(CmsLevers.builtIn("timeOfDay", format: nil, now: at("2026-10-28T18:00:00Z"), calendar: london), "evening")
        // Summer time: 07:30 UTC is 08:30 in London, still morning; 11:30 UTC is 12:30, afternoon.
        XCTAssertEqual(CmsLevers.builtIn("timeOfDay", format: nil, now: at("2026-07-01T11:30:00Z"), calendar: london), "afternoon",
                       "on the viewer's clock, not the database's")
        XCTAssertNil(CmsLevers.builtIn("name", format: nil))
    }

    func testBuiltInSlotsInLines() {
        let saved = CmsLevers.now
        CmsLevers.now = { self.at("2026-10-28T08:00:00Z") }
        defer { CmsLevers.now = saved }
        let plain: (String) -> CmsColumnPresentation = { CmsColumnPresentation(key: $0, json: nil) }
        let greeting = CmsListRowLayout.fill("Good {timeOfDay} {name}", row: ["name": .string("Sam")], column: plain)
        XCTAssertTrue(greeting == "Good morning Sam" || greeting == "Good afternoon Sam" || greeting == "Good evening Sam",
                      "built in, beside a row's own column")
        XCTAssertEqual(CmsListRowLayout.fill("{today|yyyy}", row: [:], column: plain), "2026", "the slot's own format")
        XCTAssertEqual(CmsListRowLayout.fill("{today}", row: ["today": .string("Mine")], column: plain), "Mine",
                       "a row's own column of the same name wins")
        XCTAssertEqual(CmsCards.headerText(CmsCardLine(text: "As of {today|d MMM}"), groupColumn: nil, value: "",
                                           rows: [], columns: []), "As of 28 Oct", "in group headers too")
    }

    // MARK: Shapes

    func testDecodesTheShapes() {
        let page = json(CmsPage.self, """
        { "id": "p", "slug": "home", "title": "Home", "bodyType": "blocks", "titleDisplay": "hidden",
          "blocks": { "layout": "list", "items": [
            { "id": "b1", "type": "cards", "props": {}, "frame": { "bleed": true } },
            { "id": "b2", "type": "text", "props": {}, "frame": { "bleed": "yes", "padding": "8px" } } ] } }
        """)
        XCTAssertEqual(page.titleDisplay, "hidden")
        XCTAssertEqual(CmsLevers.firstBlock(page.blocks)?.id, "b1")
        let shell = json(CmsPage.self, """
        { "id": "p", "slug": "home", "title": "Home", "bodyType": "blocks", "titleDisplay": "hidden",
          "blocks": { "layout": "list", "items": [
            { "id": "bar", "type": "tabBar", "props": {} },
            { "id": "fab", "type": "actionButton", "props": { "placement": "floating" } },
            { "id": "web", "type": "text", "props": {}, "visibleOn": ["desktop"] },
            { "id": "head", "type": "cards", "props": {}, "frame": { "bleed": true } } ] } }
        """)
        XCTAssertEqual(CmsLevers.firstBlock(shell.blocks)?.id, "head",
                       "the tab bar, a floating button and a desktop-only block take no room above it")
        XCTAssertEqual(CmsLevers.firstBlock(page.blocks)?.frame?.bleed, true)
        if case .list(let items, _)? = page.blocks {
            XCTAssertNil(items[1].frame?.bleed, "a bleed of the wrong type is unset")
            XCTAssertEqual(items[1].frame?.padding, "8px", "and the rest of the frame still reads")
        }
    }

    func testOverlapAndPin() {
        let page = json(CmsPage.self, """
        { "id": "p", "slug": "home", "title": "Home", "bodyType": "blocks", "titleDisplay": "hidden",
          "blocks": { "layout": "list", "items": [
            { "id": "bar", "type": "tabBar", "props": {} },
            { "id": "head", "type": "cards", "props": {}, "frame": { "bleed": true, "pin": "behind", "overlap": 44 } },
            { "id": "later", "type": "cards", "props": {}, "frame": { "pin": "behind", "overlap": -3 } },
            { "id": "odd", "type": "text", "props": {}, "frame": { "pin": "front", "overlap": "big" } } ] } }
        """)
        guard case .list(let items, _)? = page.blocks else { return XCTFail("a list") }
        XCTAssertEqual(items[1].frame?.overlap, 44)
        XCTAssertEqual(items[1].frame?.pin, "behind")
        XCTAssertNil(items[2].frame?.overlap, "a negative overlap is unset")
        XCTAssertNil(items[3].frame?.pin, "only 'behind' pins")
        XCTAssertNil(items[3].frame?.overlap, "a wrong type is unset")
        XCTAssertTrue(CmsLevers.overlapGrowsSurface(items[1]), "a card's face grows")
        XCTAssertFalse(CmsLevers.overlapGrowsSurface(items[3]), "text has no surface: the frame grows, clear")
        XCTAssertEqual(CmsLevers.pinnedBlock(page.blocks)?.id, "head", "the first block that takes room, past the tab bar")
        let second = json(CmsPage.self, """
        { "id": "p", "slug": "x", "title": "X", "bodyType": "blocks", "blocks": { "layout": "list", "items": [
            { "id": "a", "type": "text", "props": {} },
            { "id": "b", "type": "cards", "props": {}, "frame": { "pin": "behind" } } ] } }
        """)
        XCTAssertNil(CmsLevers.pinnedBlock(second.blocks), "a block that isn't first scrolls normally")
    }

    func testPinCoverAndKeep() {
        let page = json(CmsPage.self, """
        { "id": "p", "slug": "records", "title": "Records", "bodyType": "blocks", "titleDisplay": "hidden",
          "blocks": { "layout": "list", "items": [
            { "id": "cal", "type": "simpleCalendar", "props": {},
              "frame": { "bleed": true, "pin": "behind", "overlap": 48, "pinCover": "sheet", "pinKeep": 42 } },
            { "id": "a", "type": "text", "props": {}, "frame": { "pinCover": "clear", "pinKeep": 0 } },
            { "id": "b", "type": "text", "props": {}, "frame": { "pinCover": "glass", "pinKeep": "42" } } ] } }
        """)
        guard case .list(let items, _)? = page.blocks else { return XCTFail("a list") }
        XCTAssertEqual(items[0].frame?.pinCover, "sheet")
        XCTAssertEqual(items[0].frame?.pinKeep, 42)
        XCTAssertNil(items[1].frame?.pinCover, "clear is the default: unset")
        // 0 is kept (eb328c811): the cut sits at the content's top, which is how a masthead's
        // default `over` stops what scrolls at the status bar (cmsMasthead.md).
        XCTAssertEqual(items[1].frame?.pinKeep, 0, "0 keeps nothing above the content's top, and is kept")
        XCTAssertNil(items[2].frame?.pinCover, "an unknown cover is unset")
        XCTAssertNil(items[2].frame?.pinKeep, "a wrong type is unset")
        XCTAssertEqual(CmsLevers.pinnedBlock(page.blocks)?.id, "cal")
    }

    func testTheKeptLineCutsTheListAboveIt() {
        let rect = CGRect(x: 0, y: 0, width: 400, height: 900)
        let cut = CmsBelowLine(cut: 42).path(in: rect).boundingRect
        XCTAssertEqual(cut.minY, 42, "nothing of the list above the kept line")
        XCTAssertLessThan(cut.minX, 0, "bleeding blocks and the sheet reach past the sides")
        XCTAssertGreaterThan(cut.maxY, rect.maxY, "and past the bottom")
        XCTAssertLessThan(CmsBelowLine(cut: nil).path(in: rect).boundingRect.minY, -100, "no pinKeep: nothing cut")
        XCTAssertEqual(CmsBelowLine(cut: 42 + 300).path(in: rect).boundingRect.minY, 342, "the line moves down the list as it scrolls")
    }

    func testTheListTakesTapsOnlyWhereItCoversThePinnedBlock() {
        XCTAssertNil(CmsPinnedListClip.hitLine(cut: nil, hitTop: nil), "clear, no strip: the list's own shapes decide")
        XCTAssertEqual(CmsPinnedListClip.hitLine(cut: nil, hitTop: 300), 300, "a sheet: below the top of what follows")
        XCTAssertEqual(CmsPinnedListClip.hitLine(cut: 44, hitTop: 300), 300, "at rest the strip is above what follows")
        XCTAssertEqual(CmsPinnedListClip.hitLine(cut: 444, hitTop: 300), 444,
                       "scrolled: nothing under the strip takes a tap")
    }

    func testAPagerTakesSidewaysDragsOnlyWhereTheBlockIsUncovered() {
        XCTAssertTrue(CmsHorizontalSwipe.isHorizontal(CGPoint(x: 300, y: 40)), "sideways: the pager's")
        XCTAssertFalse(CmsHorizontalSwipe.isHorizontal(CGPoint(x: 40, y: 300)), "vertical: the page scrolls")
        XCTAssertFalse(CmsHorizontalSwipe.isHorizontal(CGPoint(x: 100, y: 100)), "a tie scrolls the page")
        XCTAssertTrue(CmsHorizontalSwipe.uncovered(900, cover: nil, scrolled: 0), "not pinned: anywhere on it")
        let cover = CmsPinnedCover(coverTop: 300, keepTop: 44)
        XCTAssertTrue(CmsHorizontalSwipe.uncovered(250, cover: cover, scrolled: 0), "above what follows")
        XCTAssertFalse(CmsHorizontalSwipe.uncovered(320, cover: cover, scrolled: 0), "on the card over it")
        XCTAssertFalse(CmsHorizontalSwipe.uncovered(350, cover: cover, scrolled: 200), "scrolled: the sheet covers it")
        XCTAssertTrue(CmsHorizontalSwipe.uncovered(230, cover: cover, scrolled: 200), "the kept strip, scrolled down the content")
        XCTAssertFalse(CmsHorizontalSwipe.uncovered(500, cover: cover, scrolled: 400), "scrolled past: only the strip, 444 and up")
    }

    func testAButtonMenuDecodes() {
        let props = json([String: CmsJSON].self, #"""
        { "menu": { "items": [
            { "label": "Event", "media": { "symbol": "calendar.badge.plus" }, "placeholder": true },
            { "label": "Bulk import", "subtitle": "From a file", "media": { "image": "https://cdn.example/bulk.png" }, "fill": "tint",
              "actionType": "navigatePage", "pageSlug": "import" },
            { "label": "Sick day", "fill": "glitter", "actionType": "mutation", "mutationSlug": "add_sick_day" },
            { "subtitle": "No label: left out" } ],
          "primary": { "label": "Add an entry", "subtitle": "Worked or scheduled" } } }
        """#)
        guard let menu = CmsButtonMenu(props["menu"]) else { return XCTFail("a menu") }
        XCTAssertEqual(menu.items.map(\.label), ["Event", "Bulk import", "Sick day"], "a row without a label is left out")
        XCTAssertTrue(menu.items[0].placeholder)
        XCTAssertNil(menu.items[0].action, "a placeholder runs nothing")
        XCTAssertEqual(menu.items[0].comingSoon, "Event is coming soon")
        XCTAssertEqual(menu.items[1].image, "https://cdn.example/bulk.png", "an image is an address, as a card's media")
        XCTAssertEqual(menu.items[1].fill, .tint)
        XCTAssertEqual(menu.items[1].action?.string("targetPageSlug"), "import", "pageSlug reads as the button's targetPageSlug")
        XCTAssertNil(menu.items[1].action?["label"], "the row's own fields aren't the action's")
        XCTAssertEqual(menu.items[1].accessibilityName, "Bulk import, From a file")
        XCTAssertNil(menu.items[2].fill, "a fill that isn't a palette role is unset")
        XCTAssertEqual(menu.items[2].action?.string("mutationSlug"), "add_sick_day", "a row's action is in the button's own fields")
        XCTAssertEqual(menu.primary, CmsButtonMenu.Primary(label: "Add an entry", subtitle: "Worked or scheduled"))
        XCTAssertNil(CmsButtonMenu(nil))
        XCTAssertNil(CmsButtonMenu(.object(["items": .array([])])), "no rows and no primary: no menu")
    }

    func testTheMenuPanelIsWACsShippedLook() {
        let props = json([String: CmsJSON].self, #"""
        { "menu": { "tint": "primary", "items": [ { "label": "Event", "placeholder": true }, { "label": "Holiday", "placeholder": true } ],
                    "primary": { "label": "Add an entry", "fill": "secondary" } } }
        """#)
        guard let menu = CmsButtonMenu(props["menu"]) else { return XCTFail("a menu") }
        XCTAssertEqual(menu.style, "panel", "unset: the panel")
        XCTAssertEqual(menu.tile, "square", "unset: square tiles")
        XCTAssertEqual(menu.tint, .primary)
        XCTAssertEqual(menu.primary?.fill, .secondary)
        let rows = CmsButtonMenu(.object(["style": .string("rows"), "tile": .string("circle"), "tint": .string("sparkle"),
                                          "items": .array([.object(["label": .string("A")])])]))
        XCTAssertEqual(rows?.style, "rows")
        XCTAssertEqual(rows?.tile, "circle")
        XCTAssertNil(rows?.tint, "a tint that isn't a palette role is unset")
        // Two rows of 50, 10 apart, the main row 16 below at 62, padding 14 each side.
        XCTAssertEqual(menu.panelContentHeight, 50 + 10 + 50 + 16 + 62)
        XCTAssertEqual(menu.panelHeight, menu.panelContentHeight + 28)
        XCTAssertEqual(CmsButtonMenu.panelWidth, 278, "rows 250 wide")
        let button = CGRect(x: 330, y: 719, width: 56, height: 56)
        let open = menu.panelFrame(button: button, screen: CGSize(width: 402, height: 874), topInset: 62)
        XCTAssertEqual(open.maxX, 386, "its trailing edge on the button's")
        XCTAssertEqual(open.maxY, 719 - 14, "14 above the button")
        let narrow = menu.panelFrame(button: CGRect(x: 20, y: 719, width: 56, height: 56), screen: CGSize(width: 402, height: 874), topInset: 62)
        XCTAssertEqual(narrow.minX, 16, "kept 16 from the screen's edge")
        XCTAssertEqual(CmsButtonMenu.collapsedFrame(button: button).width, 56 - 2 * 12.32, accuracy: 0.01, "a circle tucked inside the button")
    }

    /// The panel's measures equal the web's one table (`BUTTON_MENU_PANEL`
    /// in the shared types), read from its source.
    func testTheMenuPanelMatchesTheWebsTable() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("chrome-extension/packages/shared-types/src/cmsLevers.ts")
        let source = try String(contentsOf: url, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "export const BUTTON_MENU_PANEL = {"))
        let table = String(source[start.upperBound...].prefix { $0 != ";" })
        func number(_ pattern: String) -> Double? {
            guard let r = table.range(of: pattern + #"\s*:\s*([0-9.]+)"#, options: .regularExpression) else { return nil }
            return Double(table[r].split(separator: ":").last!.trimmingCharacters(in: .whitespaces))
        }
        XCTAssertEqual(number("rowWidth"), Double(CmsButtonMenu.panelRowWidth))
        XCTAssertEqual(number("padding"), Double(CmsButtonMenu.panelPadding))
        XCTAssertEqual(number("cornerRadius"), Double(CmsButtonMenu.panelCorner), "the panel's, the first in the table")
        XCTAssertEqual(number("gapAboveButton"), 14)
        XCTAssertEqual(number("edgeInset"), 16)
        XCTAssertEqual(number("height"), Double(CmsButtonMenu.panelRowHeight), "a row's, the first height")
        XCTAssertEqual(number("gap"), Double(CmsButtonMenu.panelRowGap))
        XCTAssertEqual(number("gapAbove"), Double(CmsButtonMenu.panelPrimaryGap))
        XCTAssertEqual(number("backdropOpacity"), 0.16)
        XCTAssertTrue(table.contains("height: 62"), "the main row")
        XCTAssertTrue(table.contains("circle: { size: 40, iconSize: 22 }"), "the circle tile")
        XCTAssertTrue(table.contains("square: { size: 32, cornerRadius: 9, fillOpacity: 0.12, iconSize: 18 }"), "the square tile")
    }

    func testButtonMenuSymbolsAndPlacement() {
        XCTAssertEqual(CmsButtonMenu.symbolName("calendar.badge.plus"), "calendar.badge.plus", "an SF Symbol name")
        XCTAssertEqual(CmsButtonMenu.symbolName("add"), CmsNavIcon.symbol(for: "add"), "a nav icon key")
        XCTAssertNil(CmsButtonMenu.symbolName(""))
        let space = CGRect(x: 0, y: 0, width: 402, height: 874)
        XCTAssertTrue(CmsButtonMenu.opensBelow(anchor: CGRect(x: 16, y: 200, width: 120, height: 44), menuHeight: 300, space: space))
        XCTAssertFalse(CmsButtonMenu.opensBelow(anchor: CGRect(x: 16, y: 700, width: 120, height: 44), menuHeight: 300, space: space),
                       "no room below: above")
        XCTAssertTrue(CmsButtonMenu.opensBelow(anchor: CGRect(x: 16, y: 200, width: 120, height: 44), menuHeight: 800, space: space),
                      "no room either way: below")
    }

    func testTheFloatingButtonIsFoundAnywhereOnThePage() {
        let page = json(CmsPage.self, """
        { "id": "p", "slug": "records", "title": "Records", "bodyType": "blocks",
          "blocks": { "layout": "list", "items": [
            { "id": "a", "type": "actionButton", "props": { "label": "Inline" } },
            { "id": "s", "type": "section", "props": {}, "children": { "layout": "list", "items": [
              { "id": "f", "type": "actionButton", "props": { "label": "Add shift", "placement": "floating", "icon": "add" } },
              { "id": "g", "type": "actionButton", "props": { "label": "Second", "placement": "floating" } } ] } } ] } }
        """)
        XCTAssertEqual(CmsLevers.floatingButton(page.blocks)?.id, "f", "the first floating one, one per page")
        let none = json(CmsPage.self, #"{ "id": "p", "slug": "x", "title": "X", "bodyType": "blocks", "blocks": { "layout": "list", "items": [] } }"#)
        XCTAssertNil(CmsLevers.floatingButton(none.blocks))
    }

    func testGroupsStartOpen() {
        XCTAssertFalse(CmsLevers.groupsStartOpen(nil))
        XCTAssertFalse(CmsLevers.groupsStartOpen(0), "0: closed, AG Grid's default")
        XCTAssertTrue(CmsLevers.groupsStartOpen(-1), "-1: all open")
        XCTAssertTrue(CmsLevers.groupsStartOpen(1), "one level is every level the list has")
    }

    // MARK: Bleed

    func testABleedingBlockIsSquareAtAllFourCorners() {
        let sideways = CmsBleed.sideways.shape(radius: 16)
        XCTAssertEqual(sideways.cornerRadii.topLeading, 0)
        XCTAssertEqual(sideways.cornerRadii.bottomTrailing, 0, "mid-page, every corner meets a side")
        let masthead = CmsBleed.underStatusBar(59).shape(radius: 16)
        XCTAssertEqual(masthead.cornerRadii.topLeading, 0)
        XCTAssertEqual(masthead.cornerRadii.topTrailing, 0)
        XCTAssertEqual(masthead.cornerRadii.bottomLeading, 0)
        XCTAssertEqual(masthead.cornerRadii.bottomTrailing, 0, "under the status bar too: no special case for a header")
        XCTAssertEqual(CmsBleed.underStatusBar(59).underTop, 59)
    }
}
