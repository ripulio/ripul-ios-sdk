import XCTest

final class ExplorerAgentTouchUITests: XCTestCase {
    func testCompactRowCoordinateTapOpensAgentWithoutSelectingOrPinning() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--explorer-agent-touch-ui-tests"]
        app.launch()
        let state = app.staticTexts["explorerAgentHarness.state"]
        let minimize = app.buttons["RipulDevConsole.compact.minimizeButton"]
        XCTAssertTrue(minimize.waitForExistence(timeout: 15))
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        let ready = NSPredicate(format: "label == %@", "minimized; picks=0; pinned=false")
        expectation(for: ready, evaluatedWith: state)
        waitForExpectations(timeout: 5)
        // Wait for the production bubble-to-row morph before measuring its
        // real on-screen position. A coordinate tap cannot bypass hit testing.
        let rowY = minimize.frame.midY
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: app.frame.midX, dy: rowY)).tap()
        let expanded = NSPredicate(format: "label == %@", "expanded; picks=0; pinned=false")
        expectation(for: expanded, evaluatedWith: state)
        waitForExpectations(timeout: 5)
        // Allow the inspector's delayed tap-to-pin work item to fire if the
        // same tap accidentally reached it as well.
        RunLoop.current.run(until: Date().addingTimeInterval(0.7))
        XCTAssertEqual(state.label, "expanded; picks=0; pinned=false")
    }
}
