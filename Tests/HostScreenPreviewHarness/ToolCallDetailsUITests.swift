import XCTest

final class ToolCallDetailsUITests: XCTestCase {
    func testHighlightedCallInformationInBothAppearances() {
        continueAfterFailure = false
        for light in [true, false] {
            let app = XCUIApplication()
            app.launchArguments = ["--tool-details-ui-tests"] + (light ? ["--light-appearance"] : [])
            app.launch()
            app.buttons["Open tool details"].tap()
            app.buttons["Call information"].tap()
            let diagnostics = app.staticTexts["ToolCallDetails.diagnostics"]
            XCTAssertTrue(diagnostics.waitForExistence(timeout: 5))
            XCTAssertTrue(diagnostics.label.contains("\"background\" : false"))
            XCTAssertTrue(diagnostics.label.contains("\"duration\" : 42.5"))
            XCTAssertTrue(app.buttons["ToolCallDetails.diagnostics.copy"].exists)
            app.swipeUp()
            let wrap = app.switches["ToolCallDetails.diagnostics.wrap"]
            XCTAssertEqual(wrap.value as? String, "0", "JSON starts without wrapping")
            let unwrapped = diagnostics.frame.size
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Unwrapped JSON \(light ? "light" : "dark")"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            wrap.tap()
            XCTAssertEqual(wrap.value as? String, "1")
            XCTAssertLessThan(diagnostics.frame.width, unwrapped.width)
            XCTAssertGreaterThan(diagnostics.frame.height, unwrapped.height)
            let wrapped = XCTAttachment(screenshot: app.screenshot())
            wrapped.name = "Wrapped JSON \(light ? "light" : "dark")"
            wrapped.lifetime = .keepAlways
            add(wrapped)
            wrap.tap()
            XCTAssertEqual(wrap.value as? String, "0")
            XCTAssertEqual(diagnostics.frame.width, unwrapped.width, accuracy: 1)
            app.buttons["ToolCallDetails.done"].tap()
        }
    }

    func testNativePickerAndDismissal() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--tool-details-ui-tests"]
        app.launch()
        app.buttons["Open tool details"].tap()
        let result = app.staticTexts["ToolCallDetails.result"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertEqual(result.label, "Result for call 2")
        app.buttons["ToolCallDetails.iteration"].tap()
        app.buttons["Call 1 of 2 · Completed"].tap()
        XCTAssertEqual(result.label, "Result for call 1")
        XCTAssertTrue(app.staticTexts["NativeTool.command"].label.contains("command 1"))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Native tool-call detail picker"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["ToolCallDetails.done"].tap()
        XCTAssertTrue(app.staticTexts["Details dismissed"].waitForExistence(timeout: 5))
        XCTAssertFalse(result.exists)
    }

    func testCommonNativeRenderersShowContentInsteadOfJSON() {
        continueAfterFailure = false
        let cases: [(String, [String])] = [
            ("codex-terminal", ["npm test", "Exit code", "Tests passed"]),
            ("read", ["app.ts", "const before = 1;", "const after = 2;"]),
            ("edit", ["1 added · 1 removed", "const value = 2;", "const value = 1;"]),
            ("codex-patch", ["app.ts", "1 added · 1 removed", "const value = 2;"]),
            ("grep", ["TODO", "src/app.ts:12:TODO add tests"]),
            ("logs", ["4 of 120 logs · 1 error · 1 warning", "×2", "Connected", "Retrying connection"]),
            ("todos", ["Inspect existing renderers", "Port native views", "Verify on iPhone"]),
            ("evaluate", ["Inspect the selected view", "Visible", "Yes"]),
        ]
        for (name, labels) in cases {
            let app = XCUIApplication()
            app.launchArguments = ["--tool-details-ui-tests", "--renderer=\(name)"]
            app.launch()
            app.buttons["Open tool details"].tap()
            for label in labels {
                let matching = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
                XCTAssertTrue(matching.waitForExistence(timeout: 5), "\(name): missing \(label)")
            }
            XCTAssertFalse(app.staticTexts["Arguments"].exists)
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Native renderer \(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
            app.buttons["ToolCallDetails.done"].tap()
        }
    }
}
