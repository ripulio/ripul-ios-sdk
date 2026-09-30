import XCTest

final class InspectorAttachmentUITests: XCTestCase {
    func testNativeAndWebElementsUseReviewedComposerAttachments() {
        checkAttachments(minimized: false)
    }

    func testHostGestureAttachesNativeAndWebElementsToMinimizedChat() {
        checkAttachments(minimized: true)
    }

    /// The composer's @ → Element round trip, in the explorer's default Design
    /// mode: closing returns with nothing attached; Add to chat returns with
    /// the element as a chip, using the composer's defaults, and removes the
    /// typed @ text.
    func testComposerElementPickReturnsTheElementToTheChat() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--inspector-attachment-ui-tests", "--chat-pick"]
        app.launch()
        let status = app.staticTexts["attachmentHarness.status"]
        let returns = app.staticTexts["attachmentHarness.returns"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertEqual(returns.label, "returns=0")

        pickElement(in: app, typing: "@")
        app.buttons["InspectorHUD.exitButton"].tap()
        expectation(for: NSPredicate(format: "label == %@", "returns=1"), evaluatedWith: returns)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(status.label, "attachments=0; images=0; tab=0")
        XCTAssertFalse(app.buttons["Inspector.addToChat"].exists)

        pickElement(in: app, typing: "Look at @el")
        let addToChat = app.buttons["Inspector.addToChat"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: addToChat)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.buttons["Inspector.attachElement"].exists, "A pick for the chat has one way back")
        let picking = XCTAttachment(screenshot: app.screenshot())
        picking.name = "explorer picking an element for the chat"
        picking.lifetime = .keepAlways
        add(picking)
        addToChat.tap()
        expectation(for: NSPredicate(format: "label == %@", "returns=2"), evaluatedWith: returns)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(status.label, "attachments=1; images=1; tab=0")
        XCTAssertFalse(app.buttons["InspectorHUD.exitButton"].exists, "Add to chat closes the explorer")
        XCTAssertEqual(app.textViews.firstMatch.value as? String, "Look at ")
        let chip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Preview Element")).firstMatch
        XCTAssertTrue(chip.exists, "The composer must show the returned element")
        let returned = XCTAttachment(screenshot: app.screenshot())
        returned.name = "element returned to the composer"
        returned.lifetime = .keepAlways
        add(returned)
    }

    private func pickElement(in app: XCUIApplication, typing text: String) {
        let field = app.textViews.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
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
