import XCTest

/// The simulator panel dragged into the right edge of an iPad in landscape
/// docks there, and the app beside it becomes a phone: the compact size class,
/// a phone's width and a bottom tab bar (PreviewDockHarness). Undocking puts
/// it all back.
final class PreviewDockUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    func testDraggingThePanelIntoTheRightEdgeDocksItBesideAPhoneLayout() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-dock-ui-tests"]
        app.launch()
        let window = app.windows.firstMatch
        let surface = app.otherElements["SimulatorPreview.surface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 5))
        guard window.frame.width >= 800 else { throw XCTSkip("needs a window wide enough for a dock (an iPad in landscape)") }
        let sizeClass = app.staticTexts["PreviewDockHarness.sizeClass"]
        let width = app.staticTexts["PreviewDockHarness.width"]
        XCTAssertEqual(sizeClass.label, "regular")
        XCTAssertGreaterThan(Int(width.label) ?? 0, 800)
        attach(app, "before")

        // A drag that stops short of the edge only moves the panel.
        let screen = window.coordinate(withNormalizedOffset: .zero)
        var start = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        start.press(forDuration: 0.2, thenDragTo: screen.withOffset(CGVector(dx: window.frame.width / 2, dy: surface.frame.midY)))
        XCTAssertTrue(surface.exists)
        XCTAssertEqual(sizeClass.label, "regular")

        // Into the right edge: docked.
        start = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        start.press(forDuration: 0.2, thenDragTo: screen.withOffset(CGVector(dx: window.frame.width - 10, dy: surface.frame.midY)),
                    withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(app.staticTexts["Docked simulator"].waitForExistence(timeout: 3))
        XCTAssertFalse(surface.exists, "the panel leaves the simulator to the dock")
        XCTAssertEqual(sizeClass.label, "compact")
        // The dock is the simulator's screen (the harness's picture, 320x695) at the
        // window's full height, so the screen fills it with no black bars.
        let fitted = Double(window.frame.width) - 1 - (Double(window.frame.height) * 320 / 695).rounded()
        XCTAssertEqual(Double(width.label) ?? 0, fitted, accuracy: 3, "fitted to the simulator's screen")
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.exists)
        XCTAssertGreaterThan(tabBar.frame.minY, window.frame.height - 140, "a phone's bottom tab bar")
        XCTAssertLessThanOrEqual(tabBar.frame.maxX, fitted + 8, "inside the app's column")
        attach(app, "docked")

        // The divider sizes the two, away from the fit…
        let divider = app.otherElements["PreviewDock.divider"]
        func drag(by distance: CGFloat) {
            let grip = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            grip.press(forDuration: 0.1, thenDragTo: grip.withOffset(CGVector(dx: distance, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        drag(by: -120)
        XCTAssertEqual(Double(width.label) ?? 0, fitted - 120, accuracy: 12, "the app narrowed with the divider")
        XCTAssertTrue(app.staticTexts["Docked simulator"].exists)
        XCTAssertEqual(sizeClass.label, "compact")
        // …and snaps back to it from near it.
        drag(by: 110)
        XCTAssertEqual(Double(width.label) ?? 0, fitted, accuracy: 1, "snapped to the fit")
        attach(app, "snapped")

        // Away again, the divider's menu fits it.
        drag(by: -120)
        XCTAssertEqual(Double(width.label) ?? 0, fitted - 120, accuracy: 12)
        divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let fit = app.buttons["PreviewDock.menu.fit"]
        XCTAssertTrue(fit.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["PreviewDock.menu.home"].exists, "the simulator's hardware is in the divider's menu")
        attach(app, "offered")
        fit.tap()
        expectation(for: NSPredicate(format: "label == %@", "\(Int(fitted))"), evaluatedWith: width)
        waitForExpectations(timeout: 3)

        // Tapped, the divider undocks: the panel is back and so is the window's layout.
        divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let undock = app.buttons["PreviewDock.menu.undock"]
        XCTAssertTrue(undock.waitForExistence(timeout: 3))
        attach(app, "offered")
        undock.tap()
        XCTAssertTrue(surface.waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Docked simulator"].exists)
        XCTAssertEqual(sizeClass.label, "regular")
        XCTAssertGreaterThan(Int(width.label) ?? 0, 800)
        attach(app, "undocked")
    }

    func testDraggingTheDividerOffTheRightEdgeUndocksAndTheDividerRemembersItsPlace() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-dock-ui-tests"]
        app.launch()
        let window = app.windows.firstMatch
        let surface = app.otherElements["SimulatorPreview.surface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 5))
        let screen = window.coordinate(withNormalizedOffset: .zero)
        let width = app.staticTexts["PreviewDockHarness.width"]
        func dock() {
            surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
                .press(forDuration: 0.2, thenDragTo: screen.withOffset(CGVector(dx: window.frame.width - 10, dy: surface.frame.midY)),
                       withVelocity: .slow, thenHoldForDuration: 0.3)
            XCTAssertTrue(app.staticTexts["Docked simulator"].waitForExistence(timeout: 3))
        }
        dock()
        let divider = app.otherElements["PreviewDock.divider"]
        let grip = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        grip.press(forDuration: 0.1, thenDragTo: grip.withOffset(CGVector(dx: 80, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.2)
        // Past the dock's narrowest, the divider springs back to it: read it once it rests.
        Thread.sleep(forTimeInterval: 1)
        let widened = Double(width.label) ?? 0
        XCTAssertGreaterThan(widened, 440)
        // Off the right edge: undocked, as an iPad's divider dragged off the screen closes the app beside it.
        let moved = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        moved.press(forDuration: 0.1, thenDragTo: screen.withOffset(CGVector(dx: window.frame.width - 20, dy: window.frame.midY)),
                    withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertTrue(surface.waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Docked simulator"].exists)
        // Docked again, the app keeps the width it was dragged to.
        dock()
        XCTAssertEqual(Double(width.label) ?? 0, widened, accuracy: 2)
    }

    func testTheIndicatorLightsTheDocksSide() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-dock-ui-tests"]
        app.launch()
        let show = app.buttons["Show where it docks"]
        XCTAssertTrue(show.waitForExistence(timeout: 5))
        show.tap()
        let indicator = app.descendants(matching: .any)["PreviewDock.indicator"].firstMatch
        XCTAssertTrue(indicator.waitForExistence(timeout: 3))
        let window = app.windows.firstMatch
        XCTAssertGreaterThan(indicator.frame.minX, 400, "the dock's side, right of a phone's width")
        XCTAssertEqual(indicator.frame.maxX, window.frame.width, accuracy: 20)
        attach(app, "indicator")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
