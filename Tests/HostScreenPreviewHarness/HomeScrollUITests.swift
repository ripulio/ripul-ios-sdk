import XCTest

/// Ripul's Home jumping as it scrolls (Peter, 2 November 2026: "Scrolling the
/// Home Screen, it jumps around"). With agents working, Jump back in's rows
/// change: a chat that speaks moves up, a family comes into the first three
/// with its chats, and a row following a plan grows a line while a tool runs.
/// Each change moved everything under it. This scrolls Jump back in out of
/// sight, lets go, and watches where the Everything section sits.
final class HomeScrollUITests: XCTestCase {
    private struct Watch {
        var positions: [CGFloat] = []
        var orders: [[String]] = []
        /// How many times the section moved, and how far it went in all.
        var moves: Int { zip(positions, positions.dropFirst()).filter { abs($0 - $1) > 0.5 }.count }
        var range: CGFloat { (positions.max() ?? 0) - (positions.min() ?? 0) }
        var reorders: Int { zip(orders, orders.dropFirst()).filter { $0 != $1 }.count }
        var summary: String {
            "\(positions.count) looks: the section moved \(moves) times over \(Int(range.rounded())) pt; "
                + "Jump back in changed order \(reorders) times"
        }
    }

    /// Before the fix, at rest, the section moved 5 times over 175 pt in 15 s
    /// (a SwiftUI scroll position anchor on the column changed nothing).
    @MainActor
    func testWhatIsBelowJumpBackInStaysPutWhileAgentsWork() throws {
        let watched = try watch()
        print("[HOMESCROLL] " + watched.summary)
        let note = XCTAttachment(string: watched.summary + "\n\npositions: \(watched.positions)")
        note.name = "Home scroll measurements"
        note.lifetime = .keepAlways
        add(note)
        XCTAssertLessThanOrEqual(watched.range, 1, "What is below Jump back in stays where it is: " + watched.summary)
    }

    /// Launches the harness, scrolls Jump back in out of sight without a fling, and looks for 15 s.
    @MainActor
    private func watch() throws -> Watch {
        let app = XCUIApplication()
        app.launchArguments = ["--home-scroll-ui-tests", "--home-demo"]
        app.launch()
        defer { app.terminate() }
        let heading = app.staticTexts["HomeScrollHarness.everything"]
        XCTAssertTrue(heading.waitForExistence(timeout: 10))
        // Let the first speakers settle the order, as a phone's list has before Home is scrolled.
        Thread.sleep(forTimeInterval: 4)
        // A list that drew nothing would stay still too: Jump back in has its rows.
        let rows = app.descendants(matching: .any).matching(identifier: "GlassSessionsList.recent.row")
        XCTAssertGreaterThanOrEqual(rows.count, 3, "Jump back in draws its rows\n" + app.debugDescription)
        let top = XCTAttachment(screenshot: app.screenshot())
        top.name = "Jump back in, before scrolling"
        top.lifetime = .keepAlways
        add(top)
        let window = app.windows.firstMatch
        let from = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        let to = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
        from.press(forDuration: 0.1, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.6)
        Thread.sleep(forTimeInterval: 1)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Scrolled, Jump back in out of sight"
        shot.lifetime = .keepAlways
        add(shot)

        var watch = Watch()
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let snapshot = try app.snapshot()
            var titles: [String] = []
            var everything: CGFloat?
            walk(snapshot) { element in
                if element.identifier == "HomeScrollHarness.everything" { everything = element.frame.minY }
                if element.identifier == "UnifiedSessionRow.title" { titles.append(element.label) }
            }
            if let everything { watch.positions.append(everything) }
            watch.orders.append(titles)
            Thread.sleep(forTimeInterval: 0.2)
        }
        return watch
    }

    private func walk(_ element: XCUIElementSnapshot, _ visit: (XCUIElementSnapshot) -> Void) {
        visit(element)
        for child in element.children { walk(child, visit) }
    }
}
