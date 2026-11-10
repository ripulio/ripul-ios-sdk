import XCTest

final class SimulatorPreviewUITests: XCTestCase {
    /// Hidden elements still exist to XCUITest: wait for one to take a tap.
    private func waitUntilHittable(_ element: XCUIElement, _ hittable: Bool = true, timeout: TimeInterval = 3) -> Bool {
        let wait = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == %@", NSNumber(value: hittable)), object: element)
        return XCTWaiter.wait(for: [wait], timeout: timeout) == .completed
    }

    /// The points of screen that show between the toolbar and the simulator's
    /// frame, down the middle of the bar, read from a screenshot: the rows
    /// under the bar that match the screen beside the panel. (The picture's
    /// own frame runs from the top of the empty band tucked under the bar.)
    private func gapUnderToolbar(_ app: XCUIApplication, toolbar: XCUIElement) throws -> CGFloat {
        let image = try XCTUnwrap(XCUIScreen.main.screenshot().image.cgImage)
        let scale = CGFloat(image.width) / app.frame.width
        let top = Int((toolbar.frame.maxY * scale).rounded()) - 6
        let rows = Int(16 * scale)
        func column(_ x: CGFloat) throws -> [UInt8] {
            let strip = try XCTUnwrap(image.cropping(to: CGRect(x: Int((x * scale).rounded()), y: top, width: 1, height: rows)))
            var greys = [UInt8](repeating: 0, count: rows)
            let context = try XCTUnwrap(CGContext(data: &greys, width: 1, height: rows, bitsPerComponent: 8, bytesPerRow: 1,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
            context.draw(strip, in: CGRect(x: 0, y: 0, width: 1, height: rows))
            return greys
        }
        let bar = try column(toolbar.frame.midX), beside = try column(toolbar.frame.maxX + 24)
        let same = zip(bar, beside).map { abs(Int($0) - Int($1)) <= 6 }
        // Past the bar's foot, count the screen showing until the frame's rim.
        guard let afterBar = same.firstIndex(of: true) else { return 0 }
        let gap = same[afterBar...].prefix { $0 }.count
        return CGFloat(gap) / scale
    }

    private func openPanel(_ app: XCUIApplication) -> XCUIElement {
        app.launchArguments = ["--simulator-preview-ui-tests"]
        app.launch()
        app.buttons["Open simulator tool"].tap()
        let view = app.buttons["View Simulator"]
        XCTAssertTrue(view.waitForExistence(timeout: 5))
        view.tap()
        let toolbar = app.otherElements["SimulatorPreview.toolbar"]
        XCTAssertTrue(toolbar.waitForExistence(timeout: 5))
        return toolbar
    }

    func testToolCallOpensMovableResizablePreviewAndRestoresFromFAB() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let toolbar = openPanel(app)
        let minimise = app.buttons["Minimise simulator preview"]
        let expand = app.buttons["Expand simulator preview"]
        let surface = app.otherElements["SimulatorPreview.surface"]
        XCTAssertTrue(waitUntilHittable(minimise, timeout: 5))
        let original = minimise.frame
        // The toolbar is as wide as the panel: a third of the screen.
        let width = toolbar.frame.width
        XCTAssertEqual(width, app.frame.width / 3, accuracy: 2)
        let screen = app.coordinate(withNormalizedOffset: .zero)
        let drag = screen.withOffset(CGVector(dx: toolbar.frame.midX, dy: toolbar.frame.maxY + 50))
        drag.press(forDuration: 0.1, thenDragTo: drag.withOffset(CGVector(dx: 70, dy: 35)))
        XCTAssertGreaterThan(minimise.frame.minX, original.minX + 40)
        // Resize the existing shared panel using its bottom-right grip.
        let corner = screen.withOffset(CGVector(dx: toolbar.frame.maxX - 15, dy: surface.frame.maxY - 15))
        corner.press(forDuration: 0.1, thenDragTo: corner.withOffset(CGVector(dx: 30, dy: 64)))
        let resizedWidth = toolbar.frame.width
        XCTAssertGreaterThan(resizedWidth, width + 10)
        // Minimising shrinks into the minimise button at the panel's top-right,
        // and expanding grows back out of it to where the panel was.
        let panelRight = toolbar.frame.maxX, panelTop = toolbar.frame.minY
        for _ in 0..<3 {
            minimise.tap()
            XCTAssertTrue(waitUntilHittable(expand))
            // The 56-point button's middle, 28 points in from the panel's corner:
            // XCUITest gives the button the frame of its icon. It grows in from
            // half its size as the picture goes into the corner.
            for _ in 0..<20 where abs(expand.frame.midX - (panelRight - 28)) > 2 { usleep(100_000) }
            XCTAssertEqual(expand.frame.midX, panelRight - 28, accuracy: 3)
            XCTAssertEqual(expand.frame.midY, panelTop + 28, accuracy: 3)
            expand.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
            XCTAssertTrue(waitUntilHittable(minimise))
            for _ in 0..<20 where abs(toolbar.frame.minX - (panelRight - resizedWidth)) > 2 { usleep(100_000) }
            XCTAssertEqual(toolbar.frame.maxX, panelRight, accuracy: 3)
            XCTAssertEqual(toolbar.frame.minY, panelTop, accuracy: 3)
        }
        XCTAssertEqual(toolbar.frame.width, resizedWidth, accuracy: 3)
        let chat = app.buttons["SimulatorHarness.chat"]
        chat.tap()
        XCTAssertEqual(chat.label, "Chat taps: 1")
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.lifetime = .keepAlways; add(attachment)
        // Minimise, as Close does: the chat takes touches where the panel was.
        minimise.tap()
        XCTAssertTrue(waitUntilHittable(minimise, false))
        XCTAssertTrue(chat.isHittable)
    }

    func testTheToolbarSitsJustAboveThePictureAndDraggingItPressesNothing() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let toolbar = openPanel(app)
        let minimise = app.buttons["Minimise simulator preview"]
        let surface = app.otherElements["SimulatorPreview.surface"]
        let picture = app.otherElements["SimulatorPreview.picture"]
        XCTAssertTrue(picture.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntilHittable(minimise, timeout: 5))
        // Half as big again as it was, and 3 points above the simulator's frame
        // (Peter, 3 November 2026): the picture's empty band is under it.
        XCTAssertEqual(toolbar.frame.height, 45, accuracy: 1)
        XCTAssertLessThan(picture.frame.minY, toolbar.frame.maxY, "the picture's band is under the toolbar")
        XCTAssertGreaterThan(picture.frame.minY, toolbar.frame.midY, "only its band")
        let gap = try gapUnderToolbar(app, toolbar: toolbar)
        XCTAssertGreaterThanOrEqual(gap, 1.5, "the toolbar is above the simulator's frame, not over it")
        XCTAssertLessThanOrEqual(gap, 4.5, "the toolbar is just above the simulator's frame")
        // A third of a 440-point phone: the menu, Control and Minimise. Maximize
        // waits in the menu, and Close goes too, as Minimise does the same.
        for label in ["Simulator controls", "Control the simulator", "Minimise simulator preview"] {
            let button = app.buttons[label]
            XCTAssertTrue(button.exists, label)
            XCTAssertTrue(toolbar.frame.insetBy(dx: -1, dy: -1).contains(button.frame), "\(label) at \(button.frame) is outside the toolbar at \(toolbar.frame)")
        }
        XCTAssertFalse(app.buttons["Close simulator preview"].exists)
        // Dragged by Minimise, the panel moves, and Minimise is not pressed.
        let start = toolbar.frame
        let screen = app.coordinate(withNormalizedOffset: .zero)
        minimise.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: screen.withOffset(CGVector(dx: minimise.frame.midX + 80, dy: minimise.frame.midY + 120)))
        usleep(600_000) // longer than minimising takes
        XCTAssertTrue(minimise.isHittable, "the drag pressed Minimise")
        XCTAssertEqual(toolbar.frame.minX, start.minX + 80, accuracy: 15)
        XCTAssertEqual(toolbar.frame.minY, start.minY + 120, accuracy: 15)
        // Wide enough from its grip, Close comes back.
        let corner = screen.withOffset(CGVector(dx: toolbar.frame.maxX - 15, dy: surface.frame.maxY - 15))
        corner.press(forDuration: 0.1, thenDragTo: corner.withOffset(CGVector(dx: 140, dy: 320)))
        XCTAssertTrue(app.buttons["Close simulator preview"].waitForExistence(timeout: 3))
        // Under Control: Home joins the toolbar, and the toolbar, with the gap
        // under it, is what moves the panel: the gap is over the picture's
        // band, and never reaches the live picture. (Not from the … button: an
        // iOS menu opens as it is touched.)
        app.buttons["Control the simulator"].tap()
        let home = app.buttons["Home"]
        XCTAssertTrue(home.waitForExistence(timeout: 3))
        XCTAssertTrue(toolbar.frame.insetBy(dx: -1, dy: -1).contains(home.frame), "Home at \(home.frame) is outside the toolbar at \(toolbar.frame)")
        let controlled = toolbar.frame
        let underBar = screen.withOffset(CGVector(dx: toolbar.frame.midX, dy: toolbar.frame.maxY + 2))
        underBar.press(forDuration: 0.1, thenDragTo: underBar.withOffset(CGVector(dx: -60, dy: -60)))
        usleep(600_000)
        XCTAssertFalse(app.buttons["App Switcher"].exists, "the drag opened the menu")
        XCTAssertEqual(toolbar.frame.minX, controlled.minX - 60, accuracy: 15)
        XCTAssertEqual(toolbar.frame.minY, controlled.minY - 60, accuracy: 15)
        app.buttons["Stop controlling the simulator"].tap()
        XCTAssertTrue(waitUntilHittable(app.buttons["Control the simulator"]))
        XCTAssertFalse(home.exists)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.lifetime = .keepAlways; add(attachment)
    }

    func testThePanelGoesOverTheChatsBarsToTheTopAndTheFootOfTheScreen() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let toolbar = openPanel(app)
        let minimise = app.buttons["Minimise simulator preview"]
        let surface = app.otherElements["SimulatorPreview.surface"]
        XCTAssertTrue(waitUntilHittable(minimise, timeout: 5))
        // It opens clear of the chat's title bar, 52 and 8 points under the
        // status bar...
        let opened = toolbar.frame
        XCTAssertGreaterThan(opened.minY, app.frame.minY + 60)
        // ...and goes over it, up to the status bar (Peter, 3 November 2026),
        // where the system would take the toolbar's touches.
        let screen = app.coordinate(withNormalizedOffset: .zero)
        screen.withOffset(CGVector(dx: minimise.frame.midX, dy: minimise.frame.midY))
            .press(forDuration: 0.1, thenDragTo: screen.withOffset(CGVector(dx: minimise.frame.midX, dy: app.frame.minY + 10)))
        usleep(600_000)
        XCTAssertTrue(minimise.exists, "the drag pressed Minimise")
        XCTAssertEqual(toolbar.frame.minY, opened.minY - 52 - 8, accuracy: 2)
        // Then, by the toolbar it is still moved by, over the bottom bar and
        // the home indicator, right to the foot of the screen.
        screen.withOffset(CGVector(dx: minimise.frame.midX, dy: minimise.frame.midY))
            .press(forDuration: 0.1, thenDragTo: screen.withOffset(CGVector(dx: minimise.frame.midX, dy: app.frame.maxY - 10)))
        usleep(600_000)
        XCTAssertTrue(minimise.exists, "the drag pressed Minimise")
        XCTAssertEqual(surface.frame.maxY, app.frame.maxY, accuracy: 2)
        // Still the size it opened at: the grip and the pinch size it, not the move.
        XCTAssertEqual(toolbar.frame.width, opened.width, accuracy: 1)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.lifetime = .keepAlways; add(attachment)
    }

    func testPinchingThePicturesResizesThemAboutTheFingersButNotUnderControl() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--simulator-preview-ui-tests"]
        app.launch()
        app.buttons["Open simulator tool"].tap()
        let view = app.buttons["View Simulator"]
        XCTAssertTrue(view.waitForExistence(timeout: 5))
        view.tap()
        let surface = app.otherElements["SimulatorPreview.surface"]
        let minimise = app.buttons["Minimise simulator preview"]
        let expand = app.buttons["Expand simulator preview"]
        XCTAssertTrue(surface.waitForExistence(timeout: 5))
        XCTAssertTrue(minimise.waitForExistence(timeout: 5))
        // Into the middle of the screen first, so it has room to grow on every side.
        let screen = app.coordinate(withNormalizedOffset: .zero)
        let opened = surface.frame
        screen.withOffset(CGVector(dx: opened.midX, dy: opened.midY + 40))
            .press(forDuration: 0.1, thenDragTo: screen.withOffset(CGVector(dx: app.frame.midX, dy: app.frame.midY + 40)))
        let before = surface.frame
        // Roughly: the move starts once the finger has gone a few points.
        XCTAssertEqual(before.midX, app.frame.midX, accuracy: 20)
        // The panel's shape is held by the panel itself (and unit-tested): the
        // surface's frame reaches a fixed few points past the drawn chassis, so
        // its own proportions drift with its size.

        // Out far enough that Close is back in the toolbar.
        surface.pinch(withScale: 2, velocity: 1)
        let grown = surface.frame
        XCTAssertGreaterThan(grown.width, before.width * 1.25, "\(before) → \(grown)")
        // About the point between the fingers: the panel's middle stays where it was.
        XCTAssertEqual(grown.midX, before.midX, accuracy: 8, "\(before) → \(grown)")
        XCTAssertEqual(grown.midY, before.midY, accuracy: 8, "\(before) → \(grown)")

        // XCUITest begins a pinch in at the panel's corners: one finger on
        // the grip, one on Close. It is still a pinch, and Close stays unpressed.
        XCTAssertTrue(app.buttons["Close simulator preview"].exists)
        surface.pinch(withScale: 0.6, velocity: -1)
        usleep(600_000) // longer than minimising takes
        XCTAssertTrue(minimise.isHittable, "the pinch pressed Close")
        let shrunk = surface.frame
        XCTAssertLessThan(shrunk.width, grown.width * 0.85, "\(grown) → \(shrunk)")
        XCTAssertEqual(shrunk.midX, grown.midX, accuracy: 8, "\(grown) → \(shrunk)")
        XCTAssertEqual(shrunk.midY, grown.midY, accuracy: 8, "\(grown) → \(shrunk)")

        // The pinched size is kept: minimised and expanded, the panel comes back as it was.
        minimise.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        XCTAssertTrue(expand.waitForExistence(timeout: 3))
        expand.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        XCTAssertTrue(minimise.waitForExistence(timeout: 3))
        for _ in 0..<20 where abs(surface.frame.maxX - shrunk.maxX) > 2 { usleep(100_000) }
        XCTAssertEqual(surface.frame.width, shrunk.width, accuracy: 2)
        XCTAssertEqual(surface.frame.maxX, shrunk.maxX, accuracy: 3)
        XCTAssertEqual(surface.frame.minY, shrunk.minY, accuracy: 3)

        // Under Control the fingers are the simulator's: a pinch leaves the panel be.
        app.buttons["Control the simulator"].tap()
        XCTAssertTrue(app.buttons["Stop controlling the simulator"].waitForExistence(timeout: 3))
        let controlled = surface.frame
        surface.pinch(withScale: 1.6, velocity: 1)
        XCTAssertEqual(surface.frame.width, controlled.width, accuracy: 1)
        XCTAssertEqual(surface.frame.minX, controlled.minX, accuracy: 1)
        XCTAssertEqual(surface.frame.minY, controlled.minY, accuracy: 1)
        // Back to the pictures, and pinching works again.
        app.buttons["Stop controlling the simulator"].tap()
        XCTAssertTrue(app.buttons["Control the simulator"].waitForExistence(timeout: 3))
        surface.pinch(withScale: 1.5, velocity: 1)
        XCTAssertGreaterThan(surface.frame.width, controlled.width * 1.15)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.lifetime = .keepAlways; add(attachment)
    }

    func testASecondSimulatorIsSwitchedFromTheToolbarAndItsMenu() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let toolbar = openPanel(app)
        let surface = app.otherElements["SimulatorPreview.surface"]
        app.buttons["Open second simulator"].tap()
        // Wide enough, the toolbar has room for the name, which switches: as
        // wide as it goes on a 440-point phone, beside five buttons.
        let screen = app.coordinate(withNormalizedOffset: .zero)
        let corner = screen.withOffset(CGVector(dx: toolbar.frame.maxX - 15, dy: surface.frame.maxY - 15))
        corner.press(forDuration: 0.1, thenDragTo: corner.withOffset(CGVector(dx: 200, dy: 400)))
        let switcher = app.buttons["Switch simulator"]
        XCTAssertTrue(switcher.waitForExistence(timeout: 5))
        XCTAssertTrue(toolbar.frame.insetBy(dx: -1, dy: -1).contains(switcher.frame), "the switch at \(switcher.frame) is outside the toolbar at \(toolbar.frame)")
        let named = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "iPhone Air"), object: switcher)
        XCTAssertEqual(XCTWaiter.wait(for: [named], timeout: 5), .completed)
        // The menu switches too.
        app.buttons["Simulator controls"].tap()
        let first = app.buttons["iPhone 17"]
        XCTAssertTrue(first.waitForExistence(timeout: 3))
        first.tap()
        let switched = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "iPhone 17"), object: switcher)
        XCTAssertEqual(XCTWaiter.wait(for: [switched], timeout: 3), .completed)
        switcher.tap()
        let second = app.buttons["iPhone Air"]
        XCTAssertTrue(second.waitForExistence(timeout: 3))
        second.tap()
        let back = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "iPhone Air"), object: switcher)
        XCTAssertEqual(XCTWaiter.wait(for: [back], timeout: 3), .completed)
        // Driving hides the switch: switching would stop it.
        app.buttons["Control the simulator"].tap()
        XCTAssertTrue(app.buttons["Stop controlling the simulator"].waitForExistence(timeout: 3))
        XCTAssertFalse(switcher.exists)
    }
}
