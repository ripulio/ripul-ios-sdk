import XCTest
import Combine
@testable import RipulAgent

/// The sidebar round (docs/plans/cms-sidebar.md): the native choice list,
/// a side region's pinned foot, `openSidebar`, and the drawer's width.
final class CmsSidebarTests: XCTestCase {
    private func json<T: Decodable>(_ type: T.Type, _ s: String) -> T {
        try! JSONDecoder().decode(type, from: Data(s.utf8))
    }

    private func props(_ s: String) -> [String: CmsJSON] { json([String: CmsJSON].self, s) }

    // MARK: Options

    func testWrittenOptionsCarryMediaColoursAndPeriods() {
        let p = props(#"""
        { "options": [
            { "label": "Pay cycle", "media": { "symbol": "calendar" }, "placeholder": true },
            { "label": "Month", "predicate": { "operator": "thisMonth" } },
            { "value": "worked", "label": "Worked", "color": "primary" },
            { "label": "Custom", "predicate": { "operator": "between" } },
            { "label": "Odd", "predicate": { "operator": "sometime" } },
            { "media": { "symbol": "x" } } ] }
        """#)
        let options = CmsChoiceList.writtenOptions(p)
        XCTAssertEqual(options.map(\.label), ["Pay cycle", "Month", "Worked", "Custom", "Odd"], "an option without a label is left out")
        XCTAssertTrue(options[0].placeholder)
        XCTAssertEqual(options[0].symbol, "calendar")
        XCTAssertEqual(options[1].predicate, "thisMonth")
        XCTAssertNil(options[1].value, "a period option writes a predicate, not a value")
        XCTAssertEqual(options[1].id, "predicate:thisMonth")
        XCTAssertEqual(options[2].value, "worked")
        XCTAssertEqual(options[2].color, "primary")
        XCTAssertNil(options[4].predicate, "an operator that isn't a range operator is no period")
        XCTAssertEqual(options[4].value, "Odd", "and the label stands as its value")
        let old = CmsChoiceList.writtenOptions(props(#"{ "manualOptions": "Red, Green\nBlue" }"#))
        XCTAssertEqual(old.map(\.value), ["Red", "Green", "Blue"], "manualOptions still works")
    }

    func testQueryOptions() {
        let rows: [[String: CmsJSON]] = [
            ["id": .number(7), "name": .string("Corner Shop"), "colour": .string("#6F2D80")],
            ["id": .number(9), "name": .string("Costa")],
            ["id": .number(7), "name": .string("Again")],
        ]
        let options = CmsChoiceList.queryOptions(rows, props: props(#"{ "valueColumn": "id", "labelColumn": "name", "colorColumn": "colour" }"#))
        XCTAssertEqual(options.map(\.value), ["7", "9"], "values as text, a value seen before left out")
        XCTAssertEqual(options.map(\.label), ["Corner Shop", "Costa"])
        XCTAssertEqual(options[0].color, "#6F2D80")
        XCTAssertEqual(options[0].row["name"], .string("Corner Shop"), "the row, for a row action's slots")
        XCTAssertTrue(CmsChoiceList.queryOptions(rows, props: [:]).isEmpty, "no value column: no options")
    }

    // MARK: Choosing

    func testDefaultsTogglesAndMinimum() {
        let options = CmsChoiceList.writtenOptions(props(#"""
        { "options": [ { "value": "a", "label": "A" }, { "value": "b", "label": "B" }, { "value": "c", "label": "C", "placeholder": true } ] }
        """#))
        let all = CmsChoiceList(props(#"{ "selectionMode": "multi", "defaultSelection": "all", "minSelected": 1, "look": "check" }"#))
        XCTAssertEqual(all.initialSelection(options), ["a", "b"], "all, placeholders left out")
        var chosen = all.toggled(["a", "b"], option: options[0])
        XCTAssertEqual(chosen, ["b"])
        chosen = all.toggled(chosen, option: options[1])
        XCTAssertEqual(chosen, ["b"], "the last one can't be unticked with minSelected 1")
        XCTAssertEqual(all.toggled(chosen, option: options[0]), ["b", "a"])

        let one = CmsChoiceList(props(#"{ "defaultSelection": "first" }"#))
        XCTAssertEqual(one.initialSelection(options), ["a"])
        XCTAssertEqual(one.toggled(["a"], option: options[1]), ["b"], "pick one")
        XCTAssertEqual(one.toggled(["a"], option: options[0]), [], "a second tap clears it, as on the web")
        let highlight = CmsChoiceList(props(#"{ "look": "highlight" }"#))
        XCTAssertEqual(highlight.toggled(["a"], option: options[0]), ["a"], "a highlight stays chosen")
        XCTAssertEqual(CmsChoiceList(props(#"{ "defaultSelection": ["b"] }"#)).initialSelection(options), ["b"])
        XCTAssertEqual(CmsChoiceList(props(#"{ "look": "fancy" }"#)).look, nil)
    }

    // MARK: Output

    func testTheOutputIsTheWebs() {
        let options = CmsChoiceList.writtenOptions(props(#"""
        { "options": [ { "value": "7", "label": "Corner Shop" }, { "value": "9", "label": "Costa" },
                       { "label": "Month", "predicate": { "operator": "thisMonth" } },
                       { "label": "Custom", "predicate": { "operator": "between" } } ] }
        """#))
        XCTAssertNil(CmsChoiceList.output([], options: options), "nothing chosen: no row, as the web's null")
        let several = CmsChoiceList.output(["7", "9"], options: options)
        XCTAssertEqual(several?["value"], .string("7,9"), "comma-joined")
        XCTAssertEqual(several?["count"], .number(2))
        XCTAssertNil(CmsChoiceList.output(["predicate:thisMonth"], options: options),
                     "a period isn't a value: it writes the date parameter, the output stays null")
        XCTAssertEqual(CmsChoiceList.output(["predicate:thisMonth", "7"], options: options)?["value"], .string("7"))
        XCTAssertEqual(CmsChoiceList.parameterValue("thisMonth"),
                       .object(["operator": .string("thisMonth"), "start": .null, "end": .null]),
                       "the calendar's shared date parameter")
        XCTAssertEqual(CmsChoiceList.parameterValue("between", range: ("2026-10-01", "2026-10-14")),
                       .object(["operator": .string("between"), "start": .string("2026-10-01"), "end": .string("2026-10-14")]))
        XCTAssertEqual(CmsChoiceList.period(of: .object(["operator": .string("thisWeek")])), "thisWeek",
                       "the list's highlight follows the parameter")
        let periods = CmsChoiceList(props(#"{ "look": "highlight", "defaultSelection": ["thisMonth"] }"#))
        XCTAssertEqual(periods.initialSelection(options), [], "a default never picks a period")
    }

    // MARK: The drawer, openSidebar, sidebarWidth

    func testPinBottomSplitsTheRegion() {
        let page = json(CmsPage.self, #"""
        { "id": "p", "slug": "records", "title": "Records", "bodyType": "blocks", "mobileBurgers": "none",
          "blocks": { "layout": "list", "items": [
            { "id": "cal", "type": "listSelector", "props": {} },
            { "id": "me", "type": "cards", "props": {}, "frame": { "pin": "bottom" } },
            { "id": "jobs", "type": "listSelector", "props": {}, "frame": { "pin": "sideways" } } ] } }
        """#)
        XCTAssertEqual(page.mobileBurgers, "none")
        guard let blocks = page.blocks else { return XCTFail("blocks") }
        let (body, footer) = CmsDrawerOverlay.splitPinnedBottom(blocks)
        guard case .list(let scrolling, _) = body, case .list(let pinned, _)? = footer else { return XCTFail("two lists") }
        XCTAssertEqual(scrolling.map(\.id), ["cal", "jobs"])
        XCTAssertEqual(pinned.map(\.id), ["me"], "pinned to the drawer's foot")
        XCTAssertNil(scrolling[1].frame?.pin, "an unknown pin is unset")
        let (_, none) = CmsDrawerOverlay.splitPinnedBottom(.list(items: [scrolling[0]], frame: nil))
        XCTAssertNil(none)
    }

    func testTheDrawerWidthLivesOnTheSidebarLayout() {
        let blocks = json(CmsPageBlocks.self, #"""
        { "layout": "sidebar", "variant": "both", "sidebarWidth": 321, "rightSidebarWidth": 280,
          "slots": { "main": { "layout": "list", "items": [] }, "left": { "layout": "list", "items": [] } } }
        """#)
        guard case .sidebar(_, _, let frame) = blocks else { return XCTFail("a sidebar layout") }
        XCTAssertEqual(frame?.sidebarWidth(left: true), 321, "WAC's")
        XCTAssertEqual(frame?.sidebarWidth(left: false), 280, "a side's own width wins")
        let again = try! JSONDecoder().decode(CmsPageBlocks.self, from: JSONEncoder().encode(blocks))
        XCTAssertEqual(again, blocks, "kept when the page is stored")
    }

    func testOnASidebarPageTheLeversReadTheMainRegion() {
        let page = json(CmsPage.self, #"""
        { "id": "p", "slug": "records", "title": "Records", "bodyType": "blocks", "titleDisplay": "hidden",
          "blocks": { "layout": "sidebar", "variant": "left", "slots": {
            "left": { "layout": "list", "items": [
              { "id": "leftFab", "type": "actionButton", "props": { "placement": "floating" } },
              { "id": "period", "type": "listSelector", "props": {} } ] },
            "main": { "layout": "list", "items": [
              { "id": "cal", "type": "simpleCalendar", "props": {}, "frame": { "bleed": true, "pin": "behind", "overlap": 48 } },
              { "id": "add", "type": "actionButton", "props": { "placement": "floating" } } ] } } } }
        """#)
        XCTAssertEqual(CmsLevers.firstBlock(page.blocks)?.id, "cal", "the main region's first block bleeds and pins")
        XCTAssertEqual(CmsLevers.pinnedBlock(page.blocks)?.id, "cal")
        XCTAssertEqual(CmsLevers.floatingButton(page.blocks)?.id, "add", "the main region's floating button, before a side region's")
    }

    func testAnEdgeDragStartsWithin22PointsOfTheEdge() {
        XCTAssertTrue(CmsEdgeDrag.startsAtEdge(6, width: 402, leading: true))
        XCTAssertTrue(CmsEdgeDrag.startsAtEdge(22, width: 402, leading: true))
        XCTAssertFalse(CmsEdgeDrag.startsAtEdge(30, width: 402, leading: true), "further in: the content's")
        XCTAssertTrue(CmsEdgeDrag.startsAtEdge(395, width: 402, leading: false))
        XCTAssertFalse(CmsEdgeDrag.startsAtEdge(200, width: 402, leading: false))
    }

    func testOpenSidebarOnACard() {
        XCTAssertEqual(CmsCardAction(.object(["open": .object(["sidebar": .string("left")])])), .openSidebar("left"))
        XCTAssertEqual(CmsCardAction(.object(["open": .object(["sidebar": .string("right")])])), .openSidebar("right"))
        XCTAssertEqual(CmsCardAction(.object(["open": .object(["sidebar": .string("up")])])), .openSidebar("left"), "unset or unknown: left")
    }

    @MainActor
    func testOpenSidebarOpensTheRegionOnThatEdge() {
        let runtime = CmsRuntime(cmsId: "c", client: CmsClient(config: CmsClientConfig(getToken: { nil })))
        runtime.openSidebar(edge: "left")
        XCTAssertNil(runtime.openDrawer, "no region on that edge: nothing")
        let slot = CmsPageBlocks.list(items: [], frame: nil)
        runtime.edgeSwipeLeftSlot = slot
        runtime.openSidebar(edge: nil)
        XCTAssertEqual(runtime.openDrawer?.edge, .leading)
        runtime.openDrawer = nil
        runtime.openSidebar(edge: "right")
        XCTAssertNil(runtime.openDrawer)
    }

    // MARK: Following the finger (CmsDrawerTrack)

    func testAReleaseSettlesByPositionAndSpeed() {
        XCTAssertTrue(CmsDrawerTrack.settlesOpen(progress: 0.6, velocity: 0, width: 321), "past halfway, still: open")
        XCTAssertFalse(CmsDrawerTrack.settlesOpen(progress: 0.4, velocity: 0, width: 321), "short of halfway, still: closed")
        XCTAssertTrue(CmsDrawerTrack.settlesOpen(progress: 0.2, velocity: 1200, width: 321), "a quick flick opens from a short pull")
        XCTAssertFalse(CmsDrawerTrack.settlesOpen(progress: 0.8, velocity: -1200, width: 321), "a quick flick back closes it")
    }

    @MainActor
    func testAnEdgePanMovesTheTrackNotPublishedState() {
        let runtime = CmsRuntime(cmsId: "c", client: CmsClient(config: CmsClientConfig(getToken: { nil })))
        runtime.edgeSwipeLeftWidth = 321
        var publishes = 0
        let watch = runtime.objectWillChange.sink { publishes += 1 }
        runtime.beginInteractiveDrawer(edge: .leading, slot: .list(items: [], frame: nil))
        XCTAssertEqual(runtime.openDrawer?.edge, .leading)
        let afterBegin = publishes
        for pulled in stride(from: 0.0, through: 300.0, by: 10.0) {
            runtime.dragDrawer(pulled: pulled, edge: .leading)
        }
        XCTAssertEqual(publishes, afterBegin, "a finger's moves publish nothing (no page re-render per frame)")
        XCTAssertEqual(runtime.drawerTrack.progress, 300 / 321, accuracy: 0.001)
        runtime.dragDrawer(pulled: 500, edge: .leading)
        XCTAssertEqual(runtime.drawerTrack.progress, 1, "held to fully open")
        watch.cancel()
    }

    @MainActor
    func testClosingWithoutAViewRemovesTheDrawerAndCallsItsHook() {
        let runtime = CmsRuntime(cmsId: "c", client: CmsClient(config: CmsClientConfig(getToken: { nil })))
        var dismissed = false
        runtime.openDrawer = CmsRuntime.DrawerRequest(edge: .leading, slot: .list(items: [], frame: nil),
                                                      onDismiss: { dismissed = true })
        runtime.closeDrawer()
        XCTAssertNil(runtime.openDrawer)
        XCTAssertTrue(dismissed)
        XCTAssertEqual(runtime.drawerTrack.progress, 0)
    }
}
