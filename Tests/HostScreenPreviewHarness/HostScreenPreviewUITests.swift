import XCTest

final class HostScreenPreviewUITests: XCTestCase {
    func testMinimiseHitAreaAfterMovingAndResizing() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--preview-ui-tests"]
        app.launch()
        let minimise = app.buttons["Minimise host screen preview"]
        let expand = app.buttons["Expand host screen preview"]
        XCTAssertTrue(minimise.waitForExistence(timeout: 10))

        // These points are inside the visible 44-point button, away from the
        // thin minus glyph. Use coordinate taps so AX activation cannot mask
        // an incorrectly sized touch region.
        let points = [CGVector(dx: 0.5, dy: 0.5), CGVector(dx: 0.5, dy: 0.25), CGVector(dx: 0.5, dy: 0.75),
                      CGVector(dx: 0.25, dy: 0.5), CGVector(dx: 0.75, dy: 0.5),
                      CGVector(dx: 0.6, dy: 0.6)]
        func exerciseButtons() {
            for point in points {
                minimise.coordinate(withNormalizedOffset: point).tap()
                XCTAssertTrue(expand.waitForExistence(timeout: 2), "Minimise missed tap at \(point)")
                expand.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
                XCTAssertTrue(minimise.waitForExistence(timeout: 2), "FAB missed tap above its icon")
            }
        }
        exerciseButtons()

        // Drag from the picture, then resize with the actual corner grip.
        let buttonFrame = minimise.frame
        let screen = app.coordinate(withNormalizedOffset: .zero)
        let start = screen.withOffset(CGVector(dx: buttonFrame.midX - 70, dy: buttonFrame.maxY + 70))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 80, dy: 40)))
        XCTAssertGreaterThan(minimise.frame.minX, buttonFrame.minX + 40)
        exerciseButtons()

        let screenshot = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Host screen preview, view only")).firstMatch
        XCTAssertTrue(screenshot.exists)
        let originalWidth = screenshot.frame.width
        let corner = screen.withOffset(CGVector(dx: screenshot.frame.maxX - 15, dy: screenshot.frame.maxY - 15))
        corner.press(forDuration: 0.1, thenDragTo: corner.withOffset(CGVector(dx: -30, dy: -60)))
        XCTAssertLessThan(screenshot.frame.width, originalWidth - 10)
        exerciseButtons()

        let agentButton = app.buttons["previewHarness.agentButton"]
        agentButton.tap()
        XCTAssertEqual(agentButton.label, "Agent taps: 1")
    }
}
