import XCTest

final class InspectorAttachmentUITests: XCTestCase {
    func testNativeAndWebElementsUseReviewedComposerAttachments() {
        checkAttachments(minimized: false)
    }

    func testHostGestureAttachesNativeAndWebElementsToMinimizedChat() {
        checkAttachments(minimized: true)
    }

    /// The composer's @ → Element round trip, in the explorer's default Design
    /// mode: closing returns with nothing attached; each Add to chat returns
    /// with the next lettered element as a chip and its name where the @ was,
    /// so one message can compare several elements (native, then web).
    func testComposerElementPickReturnsTheElementToTheChat() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--inspector-attachment-ui-tests", "--chat-pick"]
        app.launch()
        let status = app.staticTexts["attachmentHarness.status"]
        let returns = app.staticTexts["attachmentHarness.returns"]
        let field = app.textViews.firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertEqual(returns.label, "returns=0")

        pickElement(in: app, typing: "@")
        app.buttons["InspectorHUD.exitButton"].tap()
        expectation(for: NSPredicate(format: "label == %@", "returns=1"), evaluatedWith: returns)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(status.label, "attachments=0; images=0; tab=0")
        XCTAssertEqual(field.value as? String, "", "A closed pick leaves no name behind")
        XCTAssertFalse(app.buttons["Inspector.addToChat"].exists)

        addElement(in: app, typing: "Look at @el", returns: returns, expectedReturns: 2)
        XCTAssertEqual(status.label, "attachments=1; images=1; tab=0")
        XCTAssertEqual(field.value as? String, "Look at @Element A ")

        addElement(in: app, typing: "and compare it with @", returns: returns, expectedReturns: 3)
        XCTAssertEqual(status.label, "attachments=2; images=2; tab=0", "A second element adds to the first")
        XCTAssertEqual(field.value as? String, "Look at @Element A and compare it with @Element B ")
        for letter in ["A", "B"] {
            let chip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Preview Element \(letter) — ")).firstMatch
            XCTAssertTrue(chip.exists, "The composer must show Element \(letter)")
        }
        let returned = XCTAttachment(screenshot: app.screenshot())
        returned.name = "two elements returned to the composer"
        returned.lifetime = .keepAlways
        add(returned)
    }

    private func addElement(in app: XCUIApplication, typing text: String, returns: XCUIElement, expectedReturns: Int) {
        pickElement(in: app, typing: text)
        let addToChat = app.buttons["Inspector.addToChat"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: addToChat)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.buttons["Inspector.attachElement"].exists, "A pick for the chat has one way back")
        let picking = XCTAttachment(screenshot: app.screenshot())
        picking.name = "explorer picking element \(expectedReturns - 1) for the chat"
        picking.lifetime = .keepAlways
        add(picking)
        addToChat.tap()
        expectation(for: NSPredicate(format: "label == %@", "returns=\(expectedReturns)"), evaluatedWith: returns)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(app.buttons["InspectorHUD.exitButton"].exists, "Add to chat closes the explorer")
    }

    private func pickElement(in app: XCUIApplication, typing text: String) {
        let field = app.textViews.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        // The end of the text, where a person continues typing.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.99)).tap()
        field.typeText(text)
        let row = app.buttons["NativeChatInput.at.element"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "@ must offer the Element picker")
        row.tap()
        XCTAssertTrue(app.buttons["Inspector.addToChat"].waitForExistence(timeout: 10))
    }

    private func checkAttachments(minimized: Bool) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--inspector-attachment-ui-tests"]
        if minimized { app.launchArguments.append("--minimized-chat") }
        app.launch()
        let status = app.staticTexts["attachmentHarness.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertEqual(status.label, "attachments=0; images=0; tab=0")

        for (kind, images) in [("native", 0), ("web", 1)] {
            app.buttons["Open \(kind) inspector"].tap()
            let attach = app.buttons["Inspector.attachElement"]
            XCTAssertTrue(attach.waitForExistence(timeout: 10))
            expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: attach)
            waitForExpectations(timeout: 5)
            XCTAssertFalse(app.buttons["Add to chat"].exists)
            attach.tap()
            let screenshot = app.switches["ComposerContext.screenshot"]
            XCTAssertTrue(screenshot.waitForExistence(timeout: 10))
            XCTAssertEqual(screenshot.value as? String, "1", "Inspector must use the composer's configured defaults")
            XCTAssertEqual(app.switches["ComposerContext.instrumentedText"].value as? String, "1")
            if kind == "native" {
                app.buttons["Cancel"].tap()
                XCTAssertEqual(status.label, "attachments=0; images=0; tab=0")
                attach.tap()
                XCTAssertTrue(screenshot.waitForExistence(timeout: 10))
                screenshot.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
                XCTAssertEqual(screenshot.value as? String, "0")
            }
            let preview = XCTAttachment(screenshot: app.screenshot())
            preview.name = "\(kind) element in composer attachment preview"
            preview.lifetime = .keepAlways
            add(preview)
            app.buttons["ComposerContext.attach"].tap()
            app.buttons["InspectorHUD.exitButton"].tap()
            expectation(for: NSPredicate(format: "label == %@", "attachments=1; images=\(images); tab=0"), evaluatedWith: status)
            waitForExpectations(timeout: 5)
            let chip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Preview Element")).firstMatch
            XCTAssertTrue(chip.exists, "The real composer must render the new attachment chip")
            chip.tap()
            XCTAssertEqual(app.switches["ComposerContext.screenshot"].value as? String, "\(images)")
            app.buttons["Cancel"].tap()
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Remove Element")).firstMatch.tap()
            XCTAssertEqual(status.label, "attachments=0; images=0; tab=0")
        }
    }
}
