import XCTest

final class SessionFamiliesUITests: XCTestCase {
    func testAChatDraggedOntoAnotherGoesUnderIt() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--session-families-ui-tests", "--light-appearance"]
        app.launch()
        let dragged = app.staticTexts["Thermals"], target = app.staticTexts["Tool panel renders"]
        XCTAssertTrue(dragged.waitForExistence(timeout: 5))
        XCTAssertEqual(dragged.frame.minX, target.frame.minX, "Two chats by themselves start level")

        // The system's drag: a long press lifts the row, and it is let go over the other.
        dragged.press(forDuration: 1.0, thenDragTo: target, withVelocity: .slow, thenHoldForDuration: 0.8)
        XCTAssertTrue(app.buttons["Hide 1 chat under it"].waitForExistence(timeout: 5), "The chat it was dropped on is the head of a family")
        XCTAssertGreaterThan(app.staticTexts["Thermals"].frame.minY, app.staticTexts["Tool panel renders"].frame.minY)
        XCTAssertEqual(app.staticTexts["Thermals"].frame.minX, app.staticTexts["Tool panel renders"].frame.minX)
        let dropped = XCTAttachment(screenshot: app.screenshot())
        dropped.name = "Session families after a drag"; dropped.lifetime = .keepAlways; add(dropped)

        // The surface that took the drop is gone with the drag: the list takes a tap again.
        app.buttons["Hide 1 chat under it"].tap()
        XCTAssertTrue(app.buttons["Show 1 chat under it"].waitForExistence(timeout: 3), "A drop surface left over the list would swallow this tap")
        app.buttons["Show 1 chat under it"].tap()
        XCTAssertTrue(app.buttons["Hide 1 chat under it"].waitForExistence(timeout: 3))

        // A chat cannot be dropped on one that is under it: nothing moves.
        let order = { ["Tool panel renders", "Thermals"].map { app.staticTexts[$0].frame.minY } }
        let was = order()
        app.staticTexts["Tool panel renders"].press(forDuration: 1.0, thenDragTo: app.staticTexts["Thermals"], withVelocity: .slow, thenHoldForDuration: 0.8)
        XCTAssertEqual(order(), was)
        // And a drag that is refused leaves the list as usable as one that is taken.
        app.buttons["Hide 1 chat under it"].tap()
        XCTAssertTrue(app.buttons["Show 1 chat under it"].waitForExistence(timeout: 3))
        app.buttons["Show 1 chat under it"].tap()
        XCTAssertTrue(app.buttons["Hide 1 chat under it"].waitForExistence(timeout: 3))

        // Dragging another chat into the existing group places it under the same head.
        app.staticTexts["Port the parser to the new grammar"].press(
            forDuration: 1.0, thenDragTo: app.staticTexts["Tool panel renders"], withVelocity: .slow, thenHoldForDuration: 0.8)
        XCTAssertTrue(app.buttons["Hide 2 chats under it"].waitForExistence(timeout: 5), "A second chat can be dropped onto an existing group")
        app.terminate()

        // Selecting multiple rows and dragging one of them drags all selected rows into the parent.
        app.launch()
        XCTAssertTrue(app.staticTexts["Thermals"].waitForExistence(timeout: 5))
        app.buttons["Select"].tap()
        app.staticTexts["Thermals"].tap()
        app.staticTexts["Port the parser to the new grammar"].tap()
        app.staticTexts["Thermals"].press(
            forDuration: 1.0, thenDragTo: app.staticTexts["Tool panel renders"], withVelocity: .slow, thenHoldForDuration: 0.8)
        XCTAssertTrue(app.buttons["Hide 2 chats under it"].waitForExistence(timeout: 5), "Dragging one selected row places all selected rows under the parent")
        app.terminate()
    }

    func testStartedChatsSitUnderTheirStarterAndFoldBehindOneControl() {
        continueAfterFailure = false
        let every = [
            "Design alignment", "Theme: chat panels", "Check the bubble colours for contrast", "Theme: session rows", "Theme: tool sheets",
            "Theme: settings screens", "Theme: plan review", "Theme: browser", "Tool panel renders", "Thermals", "Port the parser to the new grammar",
        ]
        for light in [true, false] {
            let app = XCUIApplication()
            app.launchArguments = ["--session-families-ui-tests"] + (light ? ["--light-appearance"] : [])
            app.launch()
            XCTAssertTrue(app.staticTexts["Design alignment"].waitForExistence(timeout: 5))
            // Top to bottom, by where each title is drawn. The row's own identifier
            // covers its children's, so the titles are found by what they say.
            func shown() -> [String] {
                every.compactMap { title -> (String, CGFloat)? in
                    let text = app.staticTexts[title]
                    return text.exists ? (title, text.frame.minY) : nil
                }.sorted { $0.1 < $1.1 }.map(\.0)
            }
            // The family leads the list: its newest member spoke a minute ago, its starter 95 minutes ago.
            // "Theme: chat panels" is quiet, but a chat under it is working, so it is not one of
            // the three quiet chats a family shows: three more follow it, and two fold away.
            XCTAssertEqual(shown(), [
                "Design alignment", "Theme: chat panels", "Check the bubble colours for contrast", "Theme: session rows", "Theme: tool sheets",
                "Theme: settings screens", "Tool panel renders", "Thermals", "Port the parser to the new grammar",
            ])
            let marks = app.images.matching(NSPredicate(format: "label == %@", "Under the chat above"))
            XCTAssertEqual(marks.count, 0, "Grouped rows sit inside a shared border without indented connector arrows")
            // Started chats align cleanly with their starter inside the group border.
            let lead = app.staticTexts["Design alignment"].frame.minX
            let started = app.staticTexts["Theme: chat panels"].frame.minX
            XCTAssertEqual(started, lead)
            XCTAssertEqual(app.staticTexts["Check the bubble colours for contrast"].frame.minX, started)
            XCTAssertEqual(app.staticTexts["Thermals"].frame.minX, lead)
            XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Task from agent")).firstMatch.exists)
            // A started chat says where it works only when that differs from the chat above it.
            func count(_ label: String) -> Int { app.staticTexts.matching(NSPredicate(format: "label == %@", label)).count }
            XCTAssertEqual(count("ripul"), 3, "The three chats nobody in the list started")
            XCTAssertEqual(count("main"), 3, "Not the started chats on their starter's branch")
            XCTAssertEqual(count("tool-sheets"), 1, "The one started chat on a branch of its own")
            XCTAssertTrue(app.staticTexts["Codex migration"].exists, "A started chat with no starter in the list says whose it is")
            // A chat that is mid-turn says so on its own row, and the head speaks only for itself.
            func mark(_ label: String) -> XCUIElement {
                app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
            }
            func isOnRow(_ mark: XCUIElement, of title: String) -> Bool {
                let row = app.staticTexts[title].frame
                return abs(mark.frame.midY - row.midY) < 30
            }
            XCTAssertTrue(mark("Running").waitForExistence(timeout: 3))
            XCTAssertTrue(isOnRow(mark("Running"), of: "Check the bubble colours for contrast"))
            XCTAssertFalse(mark("1 chat under it running").exists)
            // The head last spoke 95 minutes ago, and says so while the chats it started say when they did.
            XCTAssertTrue(isOnRow(app.staticTexts["1h"], of: "Design alignment"))
            let closed = XCTAttachment(screenshot: app.screenshot())
            closed.name = "Session families folded \(light ? "light" : "dark")"; closed.lifetime = .keepAlways; add(closed)

            app.buttons["Show 2 more chats under it"].tap()
            XCTAssertTrue(app.staticTexts["Theme: browser"].waitForExistence(timeout: 3))
            XCTAssertEqual(Array(shown().prefix(8)), [
                "Design alignment", "Theme: chat panels", "Check the bubble colours for contrast", "Theme: session rows", "Theme: tool sheets",
                "Theme: settings screens", "Theme: plan review", "Theme: browser",
            ])
            let opened = XCTAttachment(screenshot: app.screenshot())
            opened.name = "Session families open \(light ? "light" : "dark")"; opened.lifetime = .keepAlways; add(opened)
            app.buttons["Show fewer chats under it"].tap()
            XCTAssertTrue(app.buttons["Show 2 more chats under it"].waitForExistence(timeout: 3))
            XCTAssertFalse(app.staticTexts["Theme: browser"].exists)

            // The icon of the chat at the head of the family puts its started chats away, and brings them back.
            app.buttons["Hide 7 chats under it"].tap()
            XCTAssertTrue(app.buttons["Show 7 chats under it"].waitForExistence(timeout: 3))
            XCTAssertEqual(shown(), ["Design alignment", "Tool panel renders", "Thermals", "Port the parser to the new grammar"])
            XCTAssertTrue(app.staticTexts["7 chats under it put away"].exists, "The head says how many it holds")
            // Its row is gone, so the head carries the running mark for it.
            XCTAssertTrue(mark("1 chat under it running").waitForExistence(timeout: 3), "A head with its chats put away says one of them is working")
            XCTAssertTrue(isOnRow(mark("1 chat under it running"), of: "Design alignment"))
            XCTAssertFalse(mark("Running").exists)
            // Its time is now the family's: a chat under it spoke a minute ago, so no row says an hour.
            XCTAssertFalse(app.staticTexts["1h"].exists, "A head with its chats put away shows when the family was last active")
            let recent = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "^[0-9]+m$")).allElementsBoundByIndex
            XCTAssertTrue(recent.contains { isOnRow($0, of: "Design alignment") && $0.label != "14m" })
            XCTAssertEqual(marks.count, 0)
            let away = XCTAttachment(screenshot: app.screenshot())
            away.name = "Session families put away \(light ? "light" : "dark")"; away.lifetime = .keepAlways; add(away)
            app.buttons["Show 7 chats under it"].tap()
            XCTAssertTrue(app.staticTexts["Theme: chat panels"].waitForExistence(timeout: 3))
            XCTAssertEqual(shown().count, 9)
            XCTAssertTrue(mark("Running").waitForExistence(timeout: 3), "Brought back, the chat says so itself again")
            XCTAssertFalse(mark("1 chat under it running").exists)
            XCTAssertTrue(isOnRow(app.staticTexts["1h"], of: "Design alignment"), "And the head's time is its own again")
            app.terminate()
        }
    }

    /// A list as long as a real one: 165 chats in fifteen families. The list
    /// must build only the rows on screen. On 22 October 2026 the session list
    /// was put in a stack that built every row: with 165 the first row took 85
    /// seconds to be reachable and each swipe 29, against under 1 and 3 for
    /// the List. This would have stopped it before it reached the phone.
    func testALongListBuildsOnlyTheRowsOnScreenAndStillOpensAndCloses() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--session-families-ui-tests", "--light-appearance", "--many-sessions"]
        let launched = Date()
        app.launch()
        XCTAssertTrue(app.staticTexts["Design alignment"].waitForExistence(timeout: 15))
        XCTAssertLessThan(Date().timeIntervalSince(launched), 15, "A long list is on screen at once")

        // The deterministic part: of fifteen families, only the rows on screen
        // (and a few the list prepares next) exist. A list that builds every
        // row has all fifteen of these.
        let lastRows = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Port the parser to the new grammar"))
        XCTAssertLessThan(lastRows.count, 8, "The list builds only the rows on screen, not all 165")

        // Scrolling a long list keeps up. Generous, for a busy shared Mac: the
        // stack took 29 seconds a swipe.
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.exists, "The rows are in a List, whose cells are reused")
        let scrolled = Date()
        list.swipeUp(velocity: .fast)
        list.swipeUp(velocity: .fast)
        list.swipeDown(velocity: .fast)
        list.swipeDown(velocity: .fast)
        XCTAssertLessThan(Date().timeIntervalSince(scrolled), 20, "Four swipes of a long list")

        // Families still open and close in a long list.
        XCTAssertTrue(app.staticTexts["Design alignment"].waitForExistence(timeout: 5))
        app.buttons["Hide 7 chats under it"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Show 7 chats under it"].firstMatch.waitForExistence(timeout: 3))
        app.terminate()

        // Closed families stay closed across a restart, and can be opened again.
        app.launchArguments = ["--session-families-ui-tests", "--light-appearance", "--many-sessions", "--keep-closed-families"]
        app.launch()
        XCTAssertTrue(app.buttons["Show 7 chats under it"].firstMatch.waitForExistence(timeout: 5), "Closed family stays closed after restart")
        XCTAssertFalse(app.staticTexts["Theme: chat panels"].exists)
        app.buttons["Show 7 chats under it"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Theme: chat panels"].waitForExistence(timeout: 3))
        app.terminate()
    }
}
