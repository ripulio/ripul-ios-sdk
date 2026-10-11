import XCTest

final class SessionFamiliesUITests: XCTestCase {
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
            XCTAssertEqual(marks.count, 5, "One mark for each started chat that is shown")
            // A started chat sits further in than its starter, and one it started further still.
            let lead = app.staticTexts["Design alignment"].frame.minX
            let started = app.staticTexts["Theme: chat panels"].frame.minX
            XCTAssertGreaterThan(started, lead)
            XCTAssertGreaterThan(app.staticTexts["Check the bubble colours for contrast"].frame.minX, started)
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
}
