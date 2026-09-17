import XCTest

final class InspectorAttachmentUITests: XCTestCase {
    func testNativeAndWebElementsUseReviewedComposerAttachments() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--inspector-attachment-ui-tests"]
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
