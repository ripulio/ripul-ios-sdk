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
        // Minimising shrinks into the minimise button at the panel's top-right,
        // and expanding grows back out of it to where the panel was.
        let panelRight = surface.frame.maxX, panelTop = surface.frame.minY
        for _ in 0..<3 {
            minimise.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
            XCTAssertTrue(expand.waitForExistence(timeout: 3))
            XCTAssertEqual(expand.frame.maxX, panelRight, accuracy: 3)
            XCTAssertEqual(expand.frame.minY, panelTop, accuracy: 3)
            expand.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
            XCTAssertTrue(minimise.waitForExistence(timeout: 3))
            for _ in 0..<20 where abs(surface.frame.minX - (panelRight - resizedWidth)) > 2 { usleep(100_000) }
            XCTAssertEqual(surface.frame.maxX, panelRight, accuracy: 3)
            XCTAssertEqual(surface.frame.minY, panelTop, accuracy: 3)
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

    func testASecondSimulatorAddsASwitchAndEveryButtonStaysInsideThePanel() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--simulator-preview-ui-tests"]
        app.launch()
        app.buttons["Open simulator tool"].tap()
        let view = app.buttons["View Simulator"]
        XCTAssertTrue(view.waitForExistence(timeout: 5))
        view.tap()
        let surface = app.otherElements["SimulatorPreview.surface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 5))
        app.buttons["Open second simulator"].tap()
        let switcher = app.buttons["Switch simulator"]
        XCTAssertTrue(switcher.waitForExistence(timeout: 5))
        let named = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "iPhone Air"), object: switcher)
        XCTAssertEqual(XCTWaiter.wait(for: [named], timeout: 5), .completed)
        // A panel a third of the screen wide holds them all.
        XCTAssertEqual(surface.frame.width, app.frame.width / 3, accuracy: 5)
        for label in ["Close simulator preview", "Simulator controls", "Control the simulator", "Minimise simulator preview", "Switch simulator"] {
            let button = app.buttons[label]
            XCTAssertTrue(button.exists, label)
            XCTAssertTrue(surface.frame.insetBy(dx: -1, dy: -1).contains(button.frame), "\(label) at \(button.frame) is outside the panel at \(surface.frame)")
        }
        switcher.tap()
        let first = app.buttons["iPhone 17"]
        XCTAssertTrue(first.waitForExistence(timeout: 3))
        first.tap()
        let switched = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "iPhone 17"), object: switcher)
        XCTAssertEqual(XCTWaiter.wait(for: [switched], timeout: 3), .completed)
        // Driving hides the switch: switching would stop it.
        app.buttons["Control the simulator"].tap()
        XCTAssertTrue(app.buttons["Stop controlling the simulator"].waitForExistence(timeout: 3))
        XCTAssertFalse(switcher.exists)
    }
}
