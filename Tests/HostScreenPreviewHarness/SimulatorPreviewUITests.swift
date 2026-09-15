import XCTest

final class SimulatorPreviewUITests: XCTestCase {
    func testToolCallOpensMovableResizablePreviewAndRestoresFromFAB() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--simulator-preview-ui-tests"]
        app.launch()
        app.buttons["Open simulator tool"].tap()
        let view = app.buttons["View Simulator"]
        XCTAssertTrue(view.waitForExistence(timeout: 5))
        view.tap()
        let minimise = app.buttons["Minimise simulator preview"]
        let close = app.buttons["Close simulator preview"]
        let expand = app.buttons["Expand simulator preview"]
        XCTAssertTrue(minimise.waitForExistence(timeout: 5))
        let surface = app.otherElements["SimulatorPreview.surface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 5))
        let original = minimise.frame
        let width = surface.frame.width
        XCTAssertEqual(width, app.frame.width / 3, accuracy: 5)
        XCTAssertEqual(surface.frame.width / surface.frame.height, 320.0 / 695, accuracy: 0.002)
        let screen = app.coordinate(withNormalizedOffset: .zero)
        let drag = screen.withOffset(CGVector(dx: close.frame.minX + width / 2, dy: close.frame.maxY + 50))
        drag.press(forDuration: 0.1, thenDragTo: drag.withOffset(CGVector(dx: 70, dy: 35)))
        XCTAssertGreaterThan(minimise.frame.minX, original.minX + 40)
        // Resize the existing shared panel using its bottom-right grip.
        let corner = screen.withOffset(CGVector(dx: surface.frame.maxX - 15, dy: surface.frame.maxY - 15))
        corner.press(forDuration: 0.1, thenDragTo: corner.withOffset(CGVector(dx: 30, dy: 64)))
        let resizedWidth = surface.frame.width
        XCTAssertGreaterThan(resizedWidth, width + 10)
        for _ in 0..<3 {
            minimise.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
            XCTAssertTrue(expand.waitForExistence(timeout: 3))
            expand.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
            XCTAssertTrue(minimise.waitForExistence(timeout: 3))
        }
        XCTAssertEqual(surface.frame.width, resizedWidth, accuracy: 3)
        XCTAssertEqual(surface.frame.width / surface.frame.height, 320.0 / 695, accuracy: 0.002)
        let chat = app.buttons["SimulatorHarness.chat"]
        chat.tap()
        XCTAssertEqual(chat.label, "Chat taps: 1")
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.lifetime = .keepAlways; add(attachment)
        close.tap()
        XCTAssertFalse(minimise.exists)
        XCTAssertTrue(chat.isHittable)
    }
}
