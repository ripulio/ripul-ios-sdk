import XCTest

final class ExplorerAgentTouchUITests: XCTestCase {
    func testCompactRowReopensAgentAboveExplorerAndMinimizeRestoresInspection() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--explorer-agent-touch-ui-tests"]
        app.launch()
        let state = app.staticTexts["explorerAgentHarness.state"]
        let minimize = app.buttons["RipulDevConsole.compact.minimizeButton"]
        XCTAssertTrue(minimize.waitForExistence(timeout: 15))
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        let ready = NSPredicate(format: "label == %@", "minimized; picks=0; pinned=false; agent=0; panel=0")
        expectation(for: ready, evaluatedWith: state)
        waitForExpectations(timeout: 5)
        // Wait for the production bubble-to-row morph before measuring its
        // real on-screen position. A coordinate tap cannot bypass hit testing.
        let rowY = minimize.frame.midY
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: app.frame.midX, dy: rowY)).tap()
        let expanded = NSPredicate(format: "label == %@", "expanded; picks=0; pinned=false; agent=0; panel=0")
        expectation(for: expanded, evaluatedWith: state)
        waitForExpectations(timeout: 5)
        // Allow the inspector's delayed tap-to-pin work item to fire if the
        // same tap accidentally reached it as well.
        RunLoop.current.run(until: Date().addingTimeInterval(0.7))
        XCTAssertEqual(state.label, "expanded; picks=0; pinned=false; agent=0; panel=0")
        let agentControl = app.buttons["explorerAgentHarness.agentButton"]
        agentControl.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        expectation(for: NSPredicate(format: "label == %@", "expanded; picks=0; pinned=false; agent=1; panel=0"), evaluatedWith: state)
        waitForExpectations(timeout: 5)
        // A touch away from the overlapping floating panel must also stay in
        // the agent, rather than reaching the explorer's full-screen capture.
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 30, dy: 280)).tap()
        RunLoop.current.run(until: Date().addingTimeInterval(0.7))
        XCTAssertEqual(state.label, "expanded; picks=0; pinned=false; agent=1; panel=0")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Expanded agent above explorer panel"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["explorerAgentHarness.collapse"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        expectation(for: NSPredicate(format: "label BEGINSWITH %@", "minimized;"), evaluatedWith: state)
        waitForExpectations(timeout: 5)
        app.buttons["explorerAgentHarness.panelButton"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        expectation(for: NSPredicate(format: "label == %@", "minimized; picks=0; pinned=false; agent=1; panel=1"), evaluatedWith: state)
        waitForExpectations(timeout: 5)
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 30, dy: 280)).tap()
        expectation(for: NSPredicate(format: "label CONTAINS %@", "pinned=true"), evaluatedWith: state)
        waitForExpectations(timeout: 5)
    }
}
