import XCTest
import Combine
#if os(iOS)
import WebKit
#endif
@testable import RipulAgent

final class NativeToolStripTests: XCTestCase {
    @MainActor func testBusyTasksStayVisibleAfterIdleAndTerminalStatusReleasesTheRow() {
        let store = NativeToolStripStore()
        let tools: [[String: Any]] = [["id": "a", "label": "Run tests", "count": 1, "status": "running"],
                                     ["id": "b", "label": "Read", "count": 1]]
        store.receive(message(time: 1000, tools: tools), now: 100_000)
        XCTAssertFalse(store.collapsed, "Long running work must remain individually visible")
        XCTAssertEqual(store.display?.tools.first?.status, "running")
        var completed = tools
        completed[0]["status"] = "completed"
        store.receive(message(time: 1000, tools: completed), now: 100_000)
        XCTAssertTrue(store.collapsed)
        XCTAssertEqual(store.display?.tools.first?.status, "completed")
        XCTAssertFalse(ToolTaskStatus.isBusy("orphaned"))
        XCTAssertFalse(ToolTaskStatus.isBusy("paused"))
    }

    @MainActor func testDefaultActionsAreGenericOwnedAndRejectChangedOrRemovedActions() {
        let store = NativeToolStripStore()
        var events: [[String: Any]] = []
        store.present { events.append($0) }
        let tools: [[String: Any]] = [["id": "a", "label": "Example", "count": 1,
                                      "defaultAction": ["id": "example.inspect", "title": "Inspect example"]]]
        store.receive(message(tools: tools))
        store.performDefault("a", actionId: "example.inspect")
        XCTAssertEqual(events.last?["type"] as? String, "agent-framework:toolStrip:defaultAction")
        XCTAssertEqual(events.last?["ownerId"] as? String, "one")
        XCTAssertEqual(events.last?["actionId"] as? String, "example.inspect")
        store.beginToolTouch()
        store.performDefault("a", actionId: "example.inspect", fromTouch: true)
        let afterHold = events.count
        store.select("a", fromTouch: true)
        XCTAssertEqual(events.count, afterHold, "The same touch must not also open details")
        store.select("a")
        XCTAssertEqual(events.count, afterHold + 1, "Accessibility activation remains available")
        store.beginToolTouch()
        store.select("a", fromTouch: true)
        XCTAssertEqual(events.count, afterHold + 2, "The next physical tap works normally")
        let count = events.count
        store.performDefault("a", actionId: "old.action")
        store.performDefault("missing", actionId: "example.inspect")
        XCTAssertEqual(events.count, count)
        store.receive(message())
        store.performDefault("a", actionId: "example.inspect")
        XCTAssertEqual(events.count, count)
        store.hide()
    }

    @MainActor func testDefaultActionRegistryDispatchesOnlyRegisteredActions() {
        let registry = ToolDefaultActionRegistry()
        var calls: [String] = []
        registry.register("example.inspect") { calls.append($0["chatId"] as! String) }
        registry.perform(["actionId": "unknown", "chatId": "wrong"])
        registry.perform(["actionId": "example.inspect", "chatId": "correct"])
        XCTAssertEqual(calls, ["correct"])
        XCTAssertEqual(registry.features, ["toolDefaultAction:example.inspect"])
    }
    private func message(_ owner: String = "one", group: String = "row", time: Double = 1000, tools: [[String: Any]]? = nil) -> [String: Any] {
        ["ownerId": owner, "chatId": "chat-" + owner, "groupId": group, "updatedAt": time,
         "tools": tools ?? [["id": "a", "label": "Python", "count": 1], ["id": "b", "label": "Grep", "count": 2]]]
    }

    #if os(iOS)
    @MainActor func testRowStateIsLightweightAndClearsOnlyItsOwner() {
        let presenter = NativeToolStripStore()
        var presentation: [Bool] = []
        presenter.presentationChanged = { presentation.append($0) }
        let rows = NativeToolStripRowsController(webView: WKWebView(), presenter: presenter, send: { _ in })
        for n in 0..<120 { rows.receive(message(group: "row-\(n)")) }
        XCTAssertEqual(rows.rowCount, 120)
        XCTAssertEqual(rows.attachmentCount, 0, "Metadata must not allocate native views")
        presenter.present { _ in }
        XCTAssertEqual(rows.attachmentCount, 0, "Only a mounted DOM anchor can allocate a view")
        rows.clear(ownerId: "stale")
        XCTAssertEqual(rows.rowCount, 120)
        rows.clear(ownerId: "one", groupId: "row-5")
        XCTAssertEqual(rows.rowCount, 119)
        rows.receive(message("two", group: "row-5"))
        rows.clear(ownerId: "one")
        XCTAssertEqual(rows.rowCount, 1)
        presenter.hide()
        XCTAssertEqual(presentation, [true, false], "The existing native presenter still receives lifecycle events")
        rows.invalidate()
        XCTAssertEqual(rows.rowCount, 0)
        presenter.present { _ in }
        XCTAssertEqual(presentation, [true, false, true], "Invalidation restores the previous presenter callback")
    }

    @MainActor func testClearingARecycledRowDiscardsGeometryThatArrivedBeforeMetadata() {
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 440, height: 800))
        let presenter = NativeToolStripStore()
        let rows = NativeToolStripRowsController(webView: web, presenter: presenter, send: { _ in })
        let geometry: [String: Any] = ["ownerId": "one", "groupId": "row", "viewportWidth": 440, "contentHeight": 800,
            "viewport": ["x": 0, "y": 0, "width": 440, "height": 800],
            "anchor": ["x": 0, "y": 100, "width": 440, "height": 44]]
        rows.receiveAnchor(geometry)
        rows.clear(ownerId: "one")
        rows.receive(message())
        presenter.present { _ in }
        XCTAssertEqual(rows.attachmentCount, 0, "A cleared owner's late geometry cannot resurrect a strip")
        rows.receiveAnchor(geometry)
        XCTAssertEqual(rows.attachmentCount, 1)
        rows.receiveAnchor(["ownerId": "one", "groupId": "row", "anchor": NSNull()])
        XCTAssertEqual(rows.attachmentCount, 0)
        XCTAssertEqual(rows.rowCount, 1, "Recycling releases the view and retains only compact state")
        rows.invalidate()
    }
    #endif

    @MainActor func testAcknowledgementRequiresMountedPresenterAndClearIsOwned() {
        let store = NativeToolStripStore()
        var events: [[String: Any]] = []
        store.receive(message(), now: 1000)
        XCTAssertTrue(events.isEmpty)
        store.present { events.append($0) }
        XCTAssertEqual(events.last?["visible"] as? Bool, true)
        store.receive(message("two"), now: 1000)
        store.clear(ownerId: "one")
        XCTAssertEqual(store.display?.ownerId, "two")
        store.hide()
        XCTAssertEqual(events.last?["visible"] as? Bool, false)
        store.clear(ownerId: "two")
        XCTAssertNil(store.display)
    }

    @MainActor func testOutputActivityDoesNotPublishDisplayAndRestartsIdle() {
        let store = NativeToolStripStore()
        store.receive(message(), now: 21_000)
        XCTAssertTrue(store.collapsed)
        var redraws = 0
        let subscription = store.$display.dropFirst().sink { _ in redraws += 1 }
        store.receive(message(time: 21_001), now: 21_001)
        XCTAssertFalse(store.collapsed)
        XCTAssertEqual(redraws, 0, "Output-only activity must not rebuild native buttons")
        store.expand()
        store.receive(message(time: 21_001), now: 60_000)
        XCTAssertFalse(store.collapsed, "An equivalent replay preserves manual expansion")
        store.receive(message(time: 21_002), now: 60_000)
        XCTAssertTrue(store.collapsed)
        subscription.cancel()
    }

    @MainActor func testSingleLozengeStaysVisibleAfterIdleRegardlessOfCallCount() {
        for count in [1, 12] {
            let store = NativeToolStripStore()
            store.receive(message(tools: [["id": "a", "label": "Python", "count": count]]), now: 21_000)
            XCTAssertFalse(store.collapsed, "Count badges do not make a second lozenge")
            store.present { _ in }
            XCTAssertFalse(store.collapsed, "Recycled single-tool rows stay visible")
            store.hide()
        }
    }

    @MainActor func testCollapsedRowReopensWhenOnlyOneLozengeRemains() {
        let store = NativeToolStripStore()
        store.receive(message(), now: 21_000)
        XCTAssertTrue(store.collapsed)
        store.receive(message(tools: [["id": "a", "label": "Python", "count": 3]]), now: 21_000)
        XCTAssertFalse(store.collapsed)
        store.receive(message(time: 21_000), now: 21_000)
        XCTAssertFalse(store.collapsed, "A second lozenge starts a fresh idle period")
        store.receive(message(time: 21_001), now: 41_001)
        XCTAssertTrue(store.collapsed, "Multiple lozenges still collapse after idle")
    }

    @MainActor func testReducingToOneLozengeCancelsScheduledCollapse() async throws {
        let store = NativeToolStripStore()
        store.present { _ in }
        defer { store.hide() }
        let now = Date().timeIntervalSince1970 * 1000
        store.receive(message(time: now - 19_900), now: now)
        XCTAssertFalse(store.collapsed)
        store.receive(message(time: now - 19_900, tools: [["id": "a", "label": "Python", "count": 3]]), now: now)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(store.collapsed, "The former multi-lozenge timer must not hide the remaining tool")
    }

    @MainActor func testRepeatedActivityDoesNotInvalidateTheNativeStrip() {
        let store = NativeToolStripStore()
        store.receive(message(), now: 1000)
        var redraws = 0
        let subscription = store.objectWillChange.sink { redraws += 1 }
        for time in 1001...1100 { store.receive(message(time: Double(time)), now: Double(time)) }
        XCTAssertEqual(redraws, 0, "Output activity changes only the idle deadline")
        XCTAssertFalse(store.collapsed)
        subscription.cancel()
    }

    @MainActor func testTapUsesCurrentOwnerAndIdentityAcrossReorderAndCompaction() {
        let store = NativeToolStripStore()
        var events: [[String: Any]] = []
        store.present { events.append($0) }
        store.receive(message(), now: 1000)
        store.receive(message(tools: [["id": "b", "label": "Grep", "count": 4], ["id": "a", "label": "Python", "count": 3]]), now: 1001)
        store.select("a")
        XCTAssertEqual(events.last?["toolId"] as? String, "a")
        XCTAssertEqual(store.display?.tools.map(\.id), ["b", "a"])
        store.receive(message("two", group: "new", tools: [["id": "c", "label": "Read", "count": 1]]), now: 1001)
        let count = events.count
        store.select("a")
        XCTAssertEqual(events.count, count, "Stale buttons must not select a different chat")
        store.select("c")
        XCTAssertEqual(events.last?["ownerId"] as? String, "two")
        XCTAssertEqual(events.last?["groupId"] as? String, "new")
    }

    @MainActor func testDOMReplacementWaitsForAttachmentAndFallsBackOnDetach() {
        let store = NativeToolStripStore()
        store.enableDOMAnchor()
        var events: [[String: Any]] = []
        store.scopeChanged = { store.setAnchored(false) }
        store.present { events.append($0) }
        store.receive(message(), now: 1000)
        XCTAssertEqual(events.last?["visible"] as? Bool, false)
        store.setAnchored(true)
        XCTAssertEqual(events.last?["visible"] as? Bool, true)
        store.setAnchored(false)
        XCTAssertEqual(events.last?["visible"] as? Bool, false)
        store.setAnchored(true)
        store.receive(message("two", group: "new"), now: 1000)
        XCTAssertEqual(events.last?["visible"] as? Bool, false)
        XCTAssertEqual(events.last?["ownerId"] as? String, "two")
        store.setAnchored(true)
        store.hide()
        XCTAssertEqual(events.last?["visible"] as? Bool, false)
        store.scopeChanged = nil
    }

    @MainActor func testMalformedSnapshotsCannotReplaceTheStrip() {
        let store = NativeToolStripStore()
        store.receive(message(), now: 1000)
        store.receive(message("bad", tools: [["id": "a", "label": "Bad", "count": 0]]))
        store.receive(message("bad", tools: [["id": "a", "label": "Bad", "count": 1], ["id": "a", "label": "Duplicate", "count": 1]]))
        XCTAssertEqual(store.display?.ownerId, "one")
    }
}
