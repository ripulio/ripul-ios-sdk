import XCTest

final class ToolCallDetailsUITests: XCTestCase {
    func testNativeChatLoadingProgressEmptyAndRetry() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--native-chat-loading-ui-tests"]
        app.launch()
        XCTAssertTrue(app.staticTexts["NativeChatView.loadingLabel"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["NativeChatView.empty"].exists)
        app.buttons["Progress"].tap()
        XCTAssertTrue(app.staticTexts["50 of 100 messages"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.progressIndicators["NativeChatView.loadingProgress"].exists)
        XCTAssertFalse(app.staticTexts["NativeChatView.empty"].exists)
        app.buttons["Fail"].tap()
        XCTAssertTrue(app.buttons["NativeChatView.retryLoad"].exists)
        app.buttons["NativeChatView.retryLoad"].tap()
        XCTAssertEqual(app.staticTexts["NativeChatView.loadingLabel"].label, "Loading chat…")
        app.buttons["Empty"].tap()
        XCTAssertTrue(app.staticTexts["NativeChatView.empty"].exists)
        XCTAssertFalse(app.staticTexts["NativeChatView.loadingLabel"].exists)
        app.buttons["Messages"].tap()
        XCTAssertTrue(app.staticTexts["Loaded message"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["NativeChatView.empty"].exists)
        app.buttons["Progress"].tap()
        XCTAssertTrue(app.staticTexts["Loaded message"].exists)
        XCTAssertTrue(app.staticTexts["50 of 100 messages"].waitForExistence(timeout: 3), app.debugDescription)
    }

    func testNativeChatLoadedMessagesNeverShowEmptyLoadFailure() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--native-chat-loading-ui-tests"]
        app.launch()
        app.buttons["Messages"].tap()
        XCTAssertTrue(app.staticTexts["Loaded message"].waitForExistence(timeout: 3))
        app.buttons["Fail"].tap()
        XCTAssertTrue(app.staticTexts["Loaded message"].exists)
        XCTAssertFalse(app.staticTexts["NativeChatView.loadingLabel"].exists,
                       "A stale load failure must not cover messages that have already loaded")
        XCTAssertFalse(app.buttons["NativeChatView.retryLoad"].exists)
        XCTAssertFalse(app.staticTexts["NativeChatView.empty"].exists)
    }

    func testBusyLozengeRemainsVisibleUntilTaskEnds() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--tool-strip-ui-tests"]
        app.launch()
        app.buttons["Start tasks"].tap()
        let task = app.buttons["NativeToolStrip.tool.call-1"]
        XCTAssertTrue(task.waitForExistence(timeout: 5))
        XCTAssertTrue(task.label.contains("Running"))
        app.buttons["Idle tools"].tap()
        XCTAssertTrue(task.exists)
        XCTAssertFalse(app.buttons["NativeToolStrip.summary"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Busy task lozenge"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["Finish tasks"].tap()
        XCTAssertTrue(app.buttons["NativeToolStrip.summary"].waitForExistence(timeout: 3))
    }

    func testTaskActivityLeadsWithProgressAndKeepsLaunchDetailsSecondary() {
        continueAfterFailure = false
        for light in [true, false] {
            let app = XCUIApplication()
            app.launchArguments = ["--tool-details-ui-tests", "--task-activity"] + (light ? ["--light-appearance"] : [])
            app.launch()
            app.buttons["Open tool details"].tap()
            XCTAssertTrue(app.staticTexts["ToolCallDetails.summary.call-1"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.staticTexts["ToolCallDetails.summary.call-1"].label, "Check background task rendering")
            XCTAssertTrue(app.staticTexts["Recent activity"].exists)
            XCTAssertTrue(app.staticTexts["1,234 tokens · 8 tool uses · 42s"].exists)
            XCTAssertFalse(app.staticTexts["NativeTool.command"].exists, "The launch renderer starts inside its own disclosure")
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "Task activity \(light ? "light" : "dark")"; shot.lifetime = .keepAlways; add(shot)
            app.buttons["ToolCallDetails.done"].tap()
            XCTAssertTrue(app.staticTexts["Details dismissed"].exists)
            app.terminate()
        }
    }

    func testConsoleBrowserSearchesUnrevealedLogsAndExpandsLongMessages() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--tool-details-ui-tests", "--renderer=logs-single-prefix", "--console-large-capture"]
        app.launch()
        app.buttons["Open tool details"].tap()
        let message = app.staticTexts["NativeTool.logs.message.129"]
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertFalse(message.label.contains("END OF MESSAGE"))
        app.buttons["NativeTool.logs.expand.129"].tap()
        XCTAssertTrue(message.label.contains("END OF MESSAGE"))
        app.buttons["NativeTool.logs.copy"].tap()
        app.buttons["ToolCallDetails.done"].tap()
        app.buttons["Read copied command"].tap()
        let copied = app.staticTexts["Copied command"].label
        XCTAssertEqual(copied.components(separatedBy: "[INFO]").count - 1, 130)
        XCTAssertTrue(copied.contains("END OF MESSAGE"))
        app.buttons["Open tool details"].tap()
        let search = app.textFields["NativeTool.logs.search"]
        search.tap(); search.typeText("Captured entry 0\n")
        XCTAssertEqual(app.staticTexts["NativeTool.logs.matchCount"].label, "1 matching entry")
        XCTAssertTrue(app.staticTexts["NativeTool.logs.message.0"].exists)
    }

    func testConsoleBrowserFiltersSearchesOrdersAndCopiesCapturedEntries() {
        continueAfterFailure = false
        for light in [true, false] {
            let app = XCUIApplication()
            app.launchArguments = ["--tool-details-ui-tests", "--renderer=logs-single-prefix"] + (light ? ["--light-appearance"] : [])
            app.launch()
            app.buttons["Open tool details"].tap()
            let search = app.textFields["NativeTool.logs.search"]
            XCTAssertTrue(search.waitForExistence(timeout: 5), "The reported single-underscore tool must use the console browser")
            XCTAssertEqual(app.staticTexts["NativeTool.logs.summary"].label, "4 of 120 logs · 1 error · 1 warning")
            let error = app.staticTexts["NativeTool.logs.message.3"]
            let info = app.staticTexts["NativeTool.logs.message.0"]
            XCTAssertLessThan(error.frame.minY, info.frame.minY)
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "Console browser \(light ? "light" : "dark")"; shot.lifetime = .keepAlways; add(shot)

            app.buttons["NativeTool.logs.level.ERROR"].tap()
            XCTAssertEqual(app.staticTexts["NativeTool.logs.matchCount"].label, "1 matching entry")
            XCTAssertFalse(info.exists)
            app.buttons["NativeTool.logs.stackToggle.3"].tap()
            XCTAssertTrue(app.staticTexts["NativeTool.logs.stack.3"].exists)
            search.tap(); search.typeText("fetchData")
            XCTAssertTrue(error.exists, "Search includes collapsed stack traces")
            app.buttons["Clear search"].tap()
            search.tap(); search.typeText("missing")
            XCTAssertTrue(app.staticTexts["NativeTool.logs.empty"].exists)
            XCTAssertFalse(app.buttons["NativeTool.logs.copy"].isEnabled)
            app.buttons["NativeTool.logs.reset"].tap()
            XCTAssertEqual(app.staticTexts["NativeTool.logs.matchCount"].label, "4 matching entries")
            app.buttons["NativeTool.logs.order"].tap()
            app.buttons["Oldest first"].tap()
            XCTAssertLessThan(info.frame.minY, error.frame.minY)
            app.buttons["NativeTool.logs.level.INFO"].tap()
            app.buttons["NativeTool.logs.copy"].tap()
            app.buttons["ToolCallDetails.done"].tap()
            app.buttons["Read copied command"].tap()
            let copied = app.staticTexts["Copied command"].label
            XCTAssertEqual(copied.components(separatedBy: "\n").count, 2)
            XCTAssertFalse(copied.contains("Retrying"))
            XCTAssertTrue(copied.contains("[INFO] Connected"))
            app.terminate()
        }
    }

    func testPackageScriptOperationKeepsRunnerShellAndFullCommand() {
        continueAfterFailure = false
        for light in [true, false] {
            let app = XCUIApplication()
            app.launchArguments = ["--tool-details-ui-tests", "--renderer=package-script"] + (light ? ["--light-appearance"] : [])
            app.launch()
            app.buttons["Open tool details"].tap()
            let title = app.staticTexts["ToolCallDetails.summary.call-1"]
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            XCTAssertEqual(title.label, "Build: typecheck")
            let context = app.staticTexts["ToolCallDetails.executionContext.call-1"]
            XCTAssertEqual(context.label, "npm · zsh")
            XCTAssertGreaterThan(context.frame.minY, title.frame.minY)
            XCTAssertFalse(app.staticTexts["ToolCallDetails.subtitle.call-1"].exists)
            let command = app.staticTexts["NativeTool.command"]
            XCTAssertEqual(command.label, "npm run build:typecheck")
            app.buttons["NativeTool.command.copy"].tap()
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "Package script operation \(light ? "light" : "dark")"
            shot.lifetime = .keepAlways; add(shot)
            app.buttons["ToolCallDetails.done"].tap()
            app.buttons["Read copied command"].tap()
            XCTAssertEqual(app.staticTexts["Copied command"].label, "npm run build:typecheck")
            app.terminate()
        }
    }

    func testNativeToolDefaultActionHoldAndTap() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--anchored-tool-strip-ui-tests", "--tool-default-actions-ui-tests"]
        app.launch()
        let status = app.staticTexts["AnchorHarness.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        let ready = NSPredicate(format: "label == 'Ready'")
        expectation(for: ready, evaluatedWith: status)
        waitForExpectations(timeout: 10)
        app.buttons["Simulator"].tap()
        let tool = app.buttons["NativeToolStrip.tool.call-2"]
        XCTAssertTrue(tool.waitForExistence(timeout: 10))
        tool.press(forDuration: 0.7)
        expectation(for: NSPredicate(format: "label == 'Default actions: 1'"), evaluatedWith: status)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.buttons["ToolCallDetails.done"].exists, "Releasing a hold must not open details")
        tool.tap()
        let done = app.buttons["ToolCallDetails.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "A normal tap after a hold still opens details")
        done.tap()
        XCTAssertTrue(tool.waitForExistence(timeout: 5))
        tool.press(forDuration: 0.7)
        expectation(for: NSPredicate(format: "label == 'Default actions: 2'"), evaluatedWith: status)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(done.exists)
        let beforeDrag = tool.frame.midY
        let point = tool.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        point.press(forDuration: 0.1, thenDragTo: point.withOffset(CGVector(dx: 0, dy: 55)))
        XCTAssertEqual(status.label, "Default actions: 2", "Scrolling from a lozenge must cancel its pending default")
        XCTAssertFalse(done.exists)
        XCTAssertGreaterThan(abs(tool.frame.midY - beforeDrag), 20, "The native row still follows the scroll gesture")
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.lifetime = .keepAlways; add(attachment)
    }
    func testAllNativeToolRowsScrollSelectAndRecycleIndependently() {
        continueAfterFailure = false
        for appearance in ["--light-appearance", "--dark-appearance"] {
            let app = XCUIApplication()
            app.launchArguments = ["--all-tool-rows-ui-tests", appearance]
            app.launch()
            let status = app.staticTexts["AnchorHarness.status"]
            XCTAssertTrue(status.waitForExistence(timeout: 5))
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Ready'"), object: status)], timeout: 10), .completed)
            func tool(_ row: Int) -> XCUIElement { app.buttons["NativeToolStrip.tool.multi-\(row)-1"] }
            func summary(_ row: Int) -> XCUIElement { app.buttons["NativeToolStrip.summary.multi-\(row)-0"] }
            func metric(_ name: String) -> Double {
                Double(status.label.split(separator: " ").first(where: { $0.hasPrefix(name + "=") })?.split(separator: "=").last ?? "-1") ?? -1
            }
            func measure() {
                app.buttons["Measure"].tap()
                XCTAssertLessThanOrEqual(metric("error"), 1.5, status.label)
                XCTAssertEqual(metric("fallback"), 0, status.label)
            }
            func open(_ row: Int) {
                if summary(row).exists { summary(row).tap() }
                XCTAssertTrue(tool(row).waitForExistence(timeout: 5), status.label)
                tool(row).tap()
                let detail = app.buttons["ToolCallDetails.toggle.multi-\(row)-1"]
                XCTAssertTrue(detail.waitForExistence(timeout: 5))
                XCTAssertEqual(detail.value as? String, "Expanded")
                XCTAssertTrue(app.buttons["ToolCallDetails.toggle.multi-\(row)-0"].exists)
                XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'ToolCallDetails.toggle.'")).count, 2)
                app.buttons["ToolCallDetails.done"].tap()
            }
            app.buttons["Rows"].tap()
            for row in 0..<3 { XCTAssertTrue(tool(row).waitForExistence(timeout: 5)) }
            measure()
            XCTAssertEqual(metric("native"), 3, status.label)
            let before = (0..<3).map { tool($0).frame.minY }
            app.buttons["Scroll"].tap()
            measure()
            for row in 0..<3 { XCTAssertEqual(tool(row).frame.minY - before[row], 69, accuracy: 1.5) }
            for row in 0..<3 { open(row) }

            XCTAssertTrue(summary(0).waitForExistence(timeout: 25))
            XCTAssertTrue(summary(1).exists)
            XCTAssertTrue(summary(2).exists)
            summary(0).tap()
            XCTAssertTrue(tool(0).exists)
            XCTAssertTrue(summary(1).exists, "Expanding one row must leave its neighbours collapsed")
            XCTAssertTrue(summary(2).exists)
            app.buttons["Append"].tap()
            XCTAssertTrue(tool(3).waitForExistence(timeout: 5))
            XCTAssertTrue(tool(0).exists, "New activity in another row preserves manual reveal")
            XCTAssertTrue(summary(1).exists)
            open(3)
            app.buttons["Hide"].tap()
            measure()
            XCTAssertEqual(metric("native"), 0, "Off-screen rows must release their native views")
            app.buttons["Show"].tap()
            app.buttons["End"].tap()
            XCTAssertTrue(tool(0).waitForExistence(timeout: 5), "Recycling must retain that row's manual reveal")
            XCTAssertTrue(summary(1).exists)
            measure()
            // The scroller briefly prewarms after a complete DOM remount.
            // Accessibility can find native views before that curtain is lifted.
            let curtainDeadline = Date().addingTimeInterval(8)
            while metric("opacity") < 1 && Date() < curtainDeadline {
                Thread.sleep(forTimeInterval: 0.25)
                measure()
            }
            XCTAssertEqual(metric("opacity"), 1, status.label)
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "Multiple native tool rows " + appearance; shot.lifetime = .keepAlways; add(shot)

            app.buttons["History"].tap()
            app.buttons["End"].tap()
            XCTAssertTrue(tool(119).waitForExistence(timeout: 5))
            measure()
            XCTAssertEqual(metric("states"), 120, status.label)
            XCTAssertLessThan(metric("native"), 20, "Native views should cover the viewport, not the entire web overscan")
            XCTAssertLessThan(metric("native"), metric("dom"), status.label)
            open(119)
            app.buttons["Top"].tap()
            XCTAssertTrue(tool(0).waitForExistence(timeout: 5))
            XCTAssertFalse(tool(119).exists)
            measure()
            XCTAssertLessThan(metric("native"), 20, status.label)
            open(0)
            app.buttons["Rows"].tap()
            app.buttons["End"].tap()
            measure()
            XCTAssertEqual(metric("states"), 3, "Deleted history releases its retained row state")
            XCTAssertLessThanOrEqual(metric("native"), 3)
            app.terminate()
        }
    }

    func testDOMAnchoredNativeStripScrollAndTapAtIPhoneScale() {
        continueAfterFailure = false
        // Older WebKit rounds scrollTop to whole CSS pixels. Allow that one
        // pixel at 115% plus the half-point bridge's rounding, never drift.
        let alignmentTolerance = 1.5
        for appearance in ["--light-appearance", "--dark-appearance"] {
            let app = XCUIApplication()
            app.launchArguments = ["--anchored-tool-strip-ui-tests", appearance]
            app.launch()
            let status = app.staticTexts["AnchorHarness.status"]
            XCTAssertTrue(status.waitForExistence(timeout: 5))
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Ready'"), object: status)], timeout: 10), .completed)
            let tool = app.buttons["NativeToolStrip.tool.call-2"]
            let detail = app.buttons["ToolCallDetails.toggle.call-2"]
            func revealTool() {
                let summary = app.buttons["NativeToolStrip.summary"]
                let available = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in tool.exists || summary.exists }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [available], timeout: 5), .completed)
                if summary.exists { summary.tap() }
                XCTAssertTrue(tool.exists)
            }
            // Reproduce a fresh chat whose first content is two tool calls.
            app.buttons["Short"].tap()
            let firstAttached = tool.waitForExistence(timeout: 5)
            app.buttons["Measure"].tap()
            XCTAssertTrue(firstAttached, status.label)
            revealTool()
            tool.tap()
            XCTAssertTrue(detail.waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["ToolCallDetails.toggle.call-1"].exists)
            app.buttons["ToolCallDetails.done"].tap()
            app.buttons["Load"].tap()
            let attached = tool.waitForExistence(timeout: 5)
            app.buttons["Measure"].tap()
            XCTAssertTrue(attached, status.label)
            // Measure the adjacent virtual rows first: at fractional zoom their
            // estimated heights can change on first mount. Then isolate a
            // scroll with settled layout from a legitimate layout update.
            app.buttons["Scroll"].tap()
            app.buttons["End"].tap()
            app.buttons["Measure"].tap()
            let before = tool.frame.minY
            let beforeStatus = status.label
            let reports = status.label.components(separatedBy: "\n").last!
            app.buttons["Scroll"].tap()
            app.buttons["Measure"].tap()
            XCTAssertEqual(tool.frame.minY - before, 69, accuracy: 1, beforeStatus + " -> " + status.label)
            XCTAssertLessThanOrEqual(abs(Double(status.label.components(separatedBy: " ")[0].replacingOccurrences(of: "error=", with: "")) ?? 999), alignmentTolerance, status.label)
            XCTAssertEqual(status.label.components(separatedBy: " scroll=").first!.components(separatedBy: "\n").last!, reports.components(separatedBy: " scroll=").first!, "No native placement or layout report during scrolling: " + beforeStatus + " -> " + status.label)
            revealTool()
            tool.tap()
            XCTAssertTrue(detail.waitForExistence(timeout: 5))
            XCTAssertEqual(detail.value as? String, "Expanded")
            XCTAssertTrue(app.buttons["ToolCallDetails.toggle.call-1"].exists)
            app.buttons["ToolCallDetails.done"].tap()

            // Starting a vertical drag on a native button must scroll its ancestor
            // rather than activate the tool or leave the strip behind.
            let dragStart = tool.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let dragEnd = dragStart.withOffset(CGVector(dx: 0, dy: -110))
            let dragY = tool.frame.minY
            dragStart.press(forDuration: 0.05, thenDragTo: dragEnd)
            app.buttons["Measure"].tap()
            XCTAssertLessThan(tool.frame.minY, dragY - 40)
            XCTAssertLessThanOrEqual(abs(Double(status.label.components(separatedBy: " ")[0].replacingOccurrences(of: "error=", with: "")) ?? 999), alignmentTolerance, status.label)
            XCTAssertFalse(detail.exists, "A vertical pan must not open the disclosure")

            app.buttons["Grow"].tap()
            app.buttons["End"].tap()
            if app.buttons["NativeToolStrip.summary"].exists { app.buttons["NativeToolStrip.summary"].tap() }
            revealTool()
            app.buttons["Measure"].tap()
            XCTAssertLessThanOrEqual(abs(Double(status.label.components(separatedBy: " ")[0].replacingOccurrences(of: "error=", with: "")) ?? 999), alignmentTolerance, status.label)
            app.buttons["Hide"].tap()
            XCTAssertFalse(tool.exists)
            app.buttons["Show"].tap()
            app.buttons["End"].tap()
            if app.buttons["NativeToolStrip.summary"].exists { app.buttons["NativeToolStrip.summary"].tap() }
            revealTool()
            app.buttons["Measure"].tap()
            XCTAssertLessThanOrEqual(abs(Double(status.label.components(separatedBy: " ")[0].replacingOccurrences(of: "error=", with: "")) ?? 999), alignmentTolerance, status.label)
            revealTool()
            tool.tap()
            XCTAssertTrue(detail.waitForExistence(timeout: 5))
            app.buttons["ToolCallDetails.done"].tap()
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "DOM anchored strip " + appearance; shot.lifetime = .keepAlways; add(shot)
            app.buttons["Short"].tap()
            app.buttons["Measure"].tap()
            if app.buttons["NativeToolStrip.summary"].exists { app.buttons["NativeToolStrip.summary"].tap() }
            XCTAssertTrue(tool.waitForExistence(timeout: 5), status.label)
            revealTool()
            tool.tap()
            XCTAssertTrue(detail.waitForExistence(timeout: 5))
            app.buttons["ToolCallDetails.done"].tap()
            app.buttons["Load"].tap()
            app.buttons["End"].tap()
            revealTool()
            app.buttons["Measure"].tap()
            XCTAssertLessThanOrEqual(abs(Double(status.label.components(separatedBy: " ")[0].replacingOccurrences(of: "error=", with: "")) ?? 999), alignmentTolerance, status.label)
            let longY = tool.frame.minY
            app.buttons["Scroll"].tap()
            XCTAssertEqual(tool.frame.minY - longY, 69, accuracy: 1)
            app.terminate()
        }
    }

    func testNativeToolStripBurstIdleTapAndComposer() {
        for appearance in ["--light-appearance", "--dark-appearance"] {
            let app = XCUIApplication()
            app.launchArguments = ["--tool-strip-ui-tests", appearance]
            app.launch()
            app.buttons["Start tools"].tap()
            let composer = app.textFields["StripHarness.composer"]
            let originalY = composer.frame.minY
            let first = app.buttons["NativeToolStrip.tool.call-2"]
            XCTAssertTrue(first.waitForExistence(timeout: 5))
            first.tap()
            let target = app.buttons["ToolCallDetails.toggle.call-2"]
            XCTAssertTrue(target.waitForExistence(timeout: 5))
            XCTAssertEqual(target.value as? String, "Expanded")
            XCTAssertTrue(app.buttons["ToolCallDetails.toggle.call-1"].exists)
            app.buttons["ToolCallDetails.done"].tap()
            app.buttons["Burst tools"].tap()
            let newest = app.buttons["NativeToolStrip.tool.call-10"]
            XCTAssertTrue(newest.waitForExistence(timeout: 5))
            XCTAssertEqual(composer.frame.minY, originalY, accuracy: 1)
            app.buttons["Idle tools"].tap()
            let summary = app.buttons["NativeToolStrip.summary"]
            XCTAssertTrue(summary.waitForExistence(timeout: 3))
            XCTAssertTrue(summary.label.contains("11 tool calls"))
            XCTAssertEqual(composer.frame.minY, originalY, accuracy: 1)
            summary.tap()
            XCTAssertTrue(newest.waitForExistence(timeout: 3))
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "Native tool strip " + appearance
            shot.lifetime = .keepAlways
            add(shot)
            app.buttons["Switch row"].tap()
            XCTAssertTrue(app.buttons["NativeToolStrip.tool.call-1"].waitForExistence(timeout: 3))
            XCTAssertFalse(newest.exists)
            composer.tap()
            composer.typeText("hello")
            XCTAssertEqual(composer.value as? String, "hello")
            XCTAssertTrue(app.buttons["NativeToolStrip.tool.call-1"].isHittable)
            app.terminate()
        }
    }

    func testInputAndOutputWrappingIsIndependent() {
        continueAfterFailure = false
        let output = String(repeating: "Long output remains copyable and horizontally scrollable. ", count: 6) + "END"
        for light in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = ["--tool-details-ui-tests", "--renderer=pipeline-command", "--long-output"] + (light ? ["--light-appearance"] : [])
            app.launch()
            app.buttons["Open tool details"].tap()
            let command = app.staticTexts["NativeTool.command.part.0"]
            XCTAssertTrue(command.waitForExistence(timeout: 5))
            let inputWrap = app.switches["NativeTool.command.wrap"]
            let outputWrap = app.switches["ToolCallDetails.result.wrap"]
            let result = app.staticTexts["ToolCallDetails.result"]
            XCTAssertTrue(inputWrap.waitForExistence(timeout: 5))
            XCTAssertTrue(outputWrap.waitForExistence(timeout: 5))
            for identifier in ["NativeTool.command", "ToolCallDetails.result"] {
                let title = app.staticTexts["\(identifier).title"]
                XCTAssertEqual(title.frame.midY, app.buttons["\(identifier).copy"].frame.midY, accuracy: 2)
                XCTAssertEqual(title.frame.midY, app.switches["\(identifier).wrap"].frame.midY, accuracy: 2)
            }
            XCTAssertEqual(inputWrap.value as? String, "0")
            XCTAssertEqual(outputWrap.value as? String, "0")
            let inputSize = command.frame.size
            let outputSize = result.frame.size
            XCTAssertGreaterThan(inputSize.width, app.frame.width)
            XCTAssertGreaterThan(outputSize.width, app.frame.width)
            let pipe = app.descendants(matching: .any)["NativeTool.command.pipe.1"].firstMatch
            let pipeX = pipe.frame.minX
            let commandX = command.frame.minX
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: 270, dy: command.frame.midY))
                .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: 80, dy: command.frame.midY)))
            XCTAssertLessThan(command.frame.minX, commandX - 30, "The command scrolls horizontally")
            XCTAssertEqual(pipe.frame.minX, pipeX, accuracy: 1, "The pipe divider stays inside the panel")

            inputWrap.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            XCTAssertEqual(inputWrap.value as? String, "1")
            XCTAssertLessThan(command.frame.width, inputSize.width)
            XCTAssertGreaterThan(command.frame.height, inputSize.height)
            XCTAssertEqual(outputWrap.value as? String, "0", "Wrapping input does not change output")
            XCTAssertEqual(result.frame.height, outputSize.height, accuracy: 1)
            inputWrap.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            XCTAssertEqual(command.frame.width, inputSize.width, accuracy: 1)

            outputWrap.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            XCTAssertEqual(outputWrap.value as? String, "1")
            XCTAssertEqual(inputWrap.value as? String, "0")
            XCTAssertLessThan(result.frame.width, outputSize.width)
            XCTAssertGreaterThan(result.frame.height, outputSize.height)
            XCTAssertEqual(result.label, output)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Independent command and output wrapping \(light ? "light" : "dark")"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            app.buttons["ToolCallDetails.result.copy"].tap()
            app.buttons["ToolCallDetails.done"].tap()
            app.buttons["Read copied command"].tap()
            XCTAssertEqual(app.staticTexts["Copied command"].label, output)
        }
    }

    func testPipelineDividerExplainsFlowAndCopiesWholeCommand() {
        continueAfterFailure = false
        let command = "rg -n 'Xcode|xcodebuild|CURRENT_PROJECT_VERSION' /tmp/ripul-direct-model-iphone-build2.log |\nhead -n 10;\nsed -n '1,180p' docs/plans/unified-new-chat-sheet.md"
        for light in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = ["--tool-details-ui-tests", "--renderer=pipeline-command"] + (light ? ["--light-appearance"] : [])
            app.launch()
            app.buttons["Open tool details"].tap()
            let pipe = app.descendants(matching: .any)["NativeTool.command.pipe.1"].firstMatch
            XCTAssertTrue(pipe.waitForExistence(timeout: 5))
            XCTAssertTrue(pipe.label.contains("Piped input"))
            XCTAssertEqual(app.staticTexts["NativeTool.command.part.1"].label, "head -n 10;")
            XCTAssertTrue(app.staticTexts["NativeTool.command.part.2"].label.hasPrefix("sed -n"))
            XCTAssertTrue(app.descendants(matching: .any)["NativeTool.command.divider.2"].exists)
            XCTAssertFalse(app.descendants(matching: .any)["NativeTool.command.pipe.2"].exists)
            XCTAssertLessThan(app.staticTexts["NativeTool.command.part.0"].frame.maxY, pipe.frame.minY)
            XCTAssertLessThan(pipe.frame.maxY, app.staticTexts["NativeTool.command.part.1"].frame.minY)
            app.switches["NativeTool.command.wrap"].coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            XCTAssertEqual(app.buttons.matching(identifier: "NativeTool.command.copy").count, 1)
            app.buttons["NativeTool.command.copy"].tap()
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Piped input separator \(light ? "light" : "dark")"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            app.buttons["ToolCallDetails.done"].tap()
            app.buttons["Read copied command"].tap()
            XCTAssertEqual(app.staticTexts["Copied command"].label, command)
        }
    }

    func testLiveCallsMoveExistingPanelsDownAndPreserveDisclosures() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--tool-details-ui-tests", "--live-calls"]
        app.launch()
        app.buttons["Open tool details"].tap()
        let second = app.buttons["ToolCallDetails.toggle.call-2"]
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        let originalY = second.frame.minY
        app.staticTexts["ToolCallDetails.summary.call-1"].tap()
        let third = app.buttons["ToolCallDetails.toggle.call-3"]
        XCTAssertTrue(third.waitForExistence(timeout: 6))
        XCTAssertEqual(third.value as? String, "Collapsed")
        XCTAssertGreaterThan(second.frame.minY, originalY + 50, "An arrival moves existing panels down")
        XCTAssertLessThan(third.frame.minY, second.frame.minY)
        XCTAssertEqual(second.value as? String, "Expanded")
        XCTAssertEqual(app.buttons["ToolCallDetails.toggle.call-1"].value as? String, "Expanded")
        let fifth = app.buttons["ToolCallDetails.toggle.call-5"]
        XCTAssertTrue(fifth.waitForExistence(timeout: 6))
        XCTAssertEqual(fifth.value as? String, "Collapsed")
        XCTAssertLessThan(fifth.frame.minY, app.buttons["ToolCallDetails.toggle.call-4"].frame.minY)
        XCTAssertLessThan(app.buttons["ToolCallDetails.toggle.call-4"].frame.minY, third.frame.minY)
        XCTAssertEqual(second.value as? String, "Expanded", "Batched arrivals preserve the open call")
        XCTAssertEqual(app.buttons["ToolCallDetails.toggle.call-1"].value as? String, "Expanded")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Live arrivals preserve open disclosures"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["ToolCallDetails.done"].tap()
    }

    func testCommandDividersRetainOneWholeCommandCopy() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--tool-details-ui-tests", "--renderer=compound-command"]
        app.launch()
        app.buttons["Open tool details"].tap()
        let first = app.staticTexts["NativeTool.command.part.0"]
        let second = app.staticTexts["NativeTool.command.part.1"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertEqual(first.label, "python3 check.py &&")
        XCTAssertEqual(second.label, "git status --short")
        XCTAssertTrue(app.descendants(matching: .any)["NativeTool.command.divider.1"].exists)
        XCTAssertGreaterThan(second.frame.minY - first.frame.maxY, 15)
        XCTAssertEqual(app.buttons.matching(identifier: "NativeTool.command.copy").count, 1)
        XCTAssertFalse(app.switches["NativeTool.command.wrap"].exists, "Separate short commands do not need wrapping")
        XCTAssertEqual(app.staticTexts["NativeTool.command.title"].frame.midY, app.buttons["NativeTool.command.copy"].frame.midY, accuracy: 2)
        app.buttons["NativeTool.command.copy"].tap()
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Native command dividers with one Copy button"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["ToolCallDetails.done"].tap()
        app.buttons["Read copied command"].tap()
        XCTAssertEqual(app.staticTexts["Copied command"].label, "python3 check.py &&\ngit status --short")
    }

    func testWrapAvailabilityFollowsPanelWidthAndUpdatedText() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--code-width-ui-tests"]
        app.launch()
        let wrap = app.switches["NativeTool.code.wrap"]
        let code = app.staticTexts["NativeTool.code"]
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        XCTAssertFalse(wrap.exists, "The line fits in the wide panel")
        app.buttons["Narrow panel"].tap()
        XCTAssertTrue(wrap.waitForExistence(timeout: 5))
        XCTAssertEqual(wrap.value as? String, "0")
        wrap.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(wrap.value as? String, "1", "The toggle remains available when wrapping is enabled")
        app.buttons["Wide panel"].tap()
        XCTAssertTrue(wrap.waitForNonExistence(timeout: 5), "A wider panel no longer needs Wrap")
        app.buttons["Narrow panel"].tap()
        XCTAssertTrue(wrap.waitForExistence(timeout: 5))
        XCTAssertEqual(wrap.value as? String, "1", "Resizing preserves the user's choice")
        app.buttons["Short text"].tap()
        XCTAssertTrue(wrap.waitForNonExistence(timeout: 5))
        app.buttons["Long text"].tap()
        XCTAssertTrue(wrap.waitForExistence(timeout: 5), "Updated text is measured without reopening the panel")
        XCTAssertEqual(wrap.value as? String, "1")
    }

    func testTappedCallIsExpandedAndScrolledIntoViewWithinWholeRow() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--tool-details-ui-tests", "--call-gallery", "--initial-call=call-3"]
        app.launch()
        app.buttons["Open tool details"].tap()
        let target = app.buttons["ToolCallDetails.toggle.call-3"]
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        XCTAssertTrue(target.isHittable, "A target well below the newest call must be scrolled into view")
        XCTAssertEqual(target.value as? String, "Expanded")
        XCTAssertTrue(app.staticTexts["Result for call 3"].isHittable)
        XCTAssertTrue(app.buttons["ToolCallDetails.toggle.call-2"].isHittable)
        XCTAssertTrue(app.buttons["ToolCallDetails.toggle.call-4"].exists)
        XCTAssertFalse(app.staticTexts["Result for call 10"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Tapped call open among surrounding disclosures"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.swipeDown()
        XCTAssertTrue(app.buttons["ToolCallDetails.toggle.call-4"].isHittable)
        app.buttons["ToolCallDetails.done"].tap()
    }

    func testExecutableIdentityAndReadablePythonScript() {
        continueAfterFailure = false
        for light in [true, false] {
            let app = XCUIApplication()
            app.launchArguments = ["--tool-details-ui-tests", "--renderer=wrapped-python"] + (light ? ["--light-appearance"] : [])
            app.launch()
            app.buttons["Open tool details"].tap()
            let toggle = app.buttons["ToolCallDetails.toggle.call-1"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            XCTAssertTrue(toggle.label.contains("Python"))
            XCTAssertTrue(toggle.label.contains("Verify iPhone installation"))
            // Numbered source exposes individual lines, not one static text.
            let source = app.staticTexts.matching(NSPredicate(format: "label == %@", "import json,plistlib")).firstMatch
            XCTAssertTrue(source.waitForExistence(timeout: 5))
            let wrap = app.switches["NativeTool.command.wrap"]
            XCTAssertEqual(wrap.value as? String, "0", "Numbered scripts start without wrapping")
            let longLine = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "a=json.loads")).firstMatch
            let unwrapped = longLine.frame.size
            XCTAssertGreaterThan(unwrapped.width, app.frame.width)
            wrap.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            XCTAssertLessThan(longLine.frame.width, unwrapped.width)
            XCTAssertGreaterThan(longLine.frame.height, unwrapped.height)
            wrap.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            XCTAssertEqual(longLine.frame.width, unwrapped.width, accuracy: 1)
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", "assert a['bundleVersion']==v")).firstMatch.exists)
            XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "/bin/zsh")).firstMatch.exists)
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Python command disclosure \(light ? "light" : "dark")"
            attachment.lifetime = .keepAlways
            add(attachment)
            toggle.tap()
            XCTAssertTrue(source.waitForNonExistence(timeout: 5))
            toggle.tap()
            XCTAssertTrue(source.waitForExistence(timeout: 5))
            app.swipeUp()
            app.buttons["Call information"].tap()
            let raw = app.staticTexts["ToolCallDetails.invocation"]
            XCTAssertTrue(raw.waitForExistence(timeout: 5))
            XCTAssertTrue(raw.label.hasPrefix("'/bin/zsh'"))
            app.buttons["ToolCallDetails.done"].tap()
        }
    }

    func testTerminalSourceOutputInBothAppearances() {
        continueAfterFailure = false
        for light in [true, false] {
            let app = XCUIApplication()
            app.launchArguments = ["--tool-details-ui-tests", "--renderer=codex-terminal", "--terminal-source"] + (light ? ["--light-appearance"] : [])
            app.launch()
            app.buttons["Open tool details"].tap()
            let source = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "public enum RipulVoiceModeRequest")).firstMatch
            XCTAssertTrue(source.waitForExistence(timeout: 10))
            XCTAssertTrue(source.label.contains("pending = true"))
            XCTAssertTrue(app.staticTexts["Exit code"].exists)
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Detected terminal Swift output \(light ? "light" : "dark")"
            attachment.lifetime = .keepAlways
            add(attachment)
            app.buttons["ToolCallDetails.done"].tap()
        }
    }

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
            // The accessibility element includes the label; tap the switch at
            // its trailing edge rather than the label's non-interactive text.
            wrap.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            XCTAssertEqual(wrap.value as? String, "1")
            XCTAssertLessThan(diagnostics.frame.width, unwrapped.width)
            XCTAssertGreaterThan(diagnostics.frame.height, unwrapped.height)
            let wrapped = XCTAttachment(screenshot: app.screenshot())
            wrapped.name = "Wrapped JSON \(light ? "light" : "dark")"
            wrapped.lifetime = .keepAlways
            add(wrapped)
            wrap.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            XCTAssertEqual(wrap.value as? String, "0")
            XCTAssertEqual(diagnostics.frame.width, unwrapped.width, accuracy: 1)
            app.buttons["ToolCallDetails.done"].tap()
        }
    }

    func testIndependentCallDisclosuresAndDismissal() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--tool-details-ui-tests"]
        app.launch()
        app.buttons["Open tool details"].tap()
        let firstResult = app.staticTexts.matching(NSPredicate(format: "label == %@", "Result for call 1")).firstMatch
        let secondResult = app.staticTexts.matching(NSPredicate(format: "label == %@", "Result for call 2")).firstMatch
        XCTAssertTrue(secondResult.waitForExistence(timeout: 10))
        XCTAssertTrue(firstResult.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons["ToolCallDetails.iteration"].exists)
        let firstToggle = app.buttons["ToolCallDetails.toggle.call-1"]
        let secondToggle = app.buttons["ToolCallDetails.toggle.call-2"]
        XCTAssertLessThan(secondToggle.frame.minY, firstToggle.frame.minY, "Newest calls appear first")
        XCTAssertTrue(firstToggle.label.contains("Inspect working tree"))
        let firstHeading = app.staticTexts["ToolCallDetails.summary.call-1"]
        firstHeading.tap()
        XCTAssertTrue(firstResult.waitForExistence(timeout: 5))
        XCTAssertTrue(secondResult.exists, "Opening the first call keeps the second open")
        XCTAssertTrue(firstResult.isHittable)
        XCTAssertTrue(secondResult.isHittable, "Both short results fit on screen together")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Two native tool calls expanded together"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        // iOS 27's AX button frame can include expanded content. Tap the visible
        // heading so XCTest hits the disclosure header rather than its output.
        firstHeading.tap()
        XCTAssertTrue(firstResult.waitForNonExistence(timeout: 5))
        XCTAssertTrue(secondResult.exists, "Closing one call leaves the other open")
        app.buttons["ToolCallDetails.done"].tap()
        XCTAssertTrue(app.staticTexts["Details dismissed"].waitForExistence(timeout: 5))
        XCTAssertFalse(secondResult.exists)
    }

    func testTenSummaryCardsInBothAppearances() {
        continueAfterFailure = false
        for light in [true, false] {
            let app = XCUIApplication()
            app.launchArguments = ["--tool-details-ui-tests", "--call-gallery"] + (light ? ["--light-appearance"] : [])
            app.launch()
            app.buttons["Open tool details"].tap()
            let latest = app.buttons["ToolCallDetails.toggle.call-10"]
            XCTAssertTrue(latest.waitForExistence(timeout: 5))
            XCTAssertTrue(latest.label.contains("Review recent commits"))
            XCTAssertTrue(latest.label.contains("git log -5 --oneline"))
            XCTAssertTrue(app.staticTexts["Result for call 10"].exists)
            latest.tap()
            XCTAssertFalse(app.staticTexts["Result for call 10"].exists)
            let ninth = app.buttons["ToolCallDetails.toggle.call-9"]
            XCTAssertLessThan(latest.frame.minY, ninth.frame.minY)
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Files-style tool summary panels \(light ? "light" : "dark")"
            attachment.lifetime = .keepAlways
            add(attachment)
            app.buttons["ToolCallDetails.done"].tap()
        }
    }

    func testAgentCallsLeadWithWhoAndKeepIdsUnderDetails() {
        continueAfterFailure = false
        let cases: [(String, String, [String])] = [
            ("agent-spawn", "Started Check the upload retry", ["Claude Code · Opus", "Finished", "Task", "Reply", "kept", "Picked Claude Code: looks like design, planning or review."]),
            ("agent-send", "Message to Check the upload retry", ["Working on it. The reply will arrive in this chat as a new message.", "Also say what happens to a parked part"]),
            ("agent-await", "Reply from Check the upload retry", ["Replied", "Parked parts are retried"]),
            ("agent-archive", "Archived Check the upload retry", ["Archived. Its transcript is kept and can be restored."]),
            ("agent-list", "Recent agents", ["3 agents · 1 working · 1 needs input", "Fix the failing sync tests", "Needs input", "Task to Check the upload retry", "MacBook Pro"]),
        ]
        for (name, title, labels) in cases {
            for light in [true, false] {
                let app = XCUIApplication()
                app.launchArguments = ["--tool-details-ui-tests", "--renderer=\(name)"] + (light ? ["--light-appearance"] : [])
                app.launch()
                app.buttons["Open tool details"].tap()
                let summary = app.staticTexts["ToolCallDetails.summary.call-1"]
                XCTAssertTrue(summary.waitForExistence(timeout: 5), name)
                XCTAssertEqual(summary.label, title, name)
                func shown(_ text: String) -> XCUIElement {
                    app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
                }
                for label in labels { XCTAssertTrue(shown(label).waitForExistence(timeout: 5), "\(name): missing \(label)") }
                // Ids are how the calls address each other, not what the panel is read for.
                for id in ["cli_3f9a2c1b", "agentmsg_"] { XCTAssertFalse(shown(id).exists, "\(name): \(id) is on the face") }
                XCTAssertFalse(app.staticTexts["Parameters"].exists, name)
                let face = XCTAttachment(screenshot: app.screenshot())
                face.name = "Agent panel \(name) \(light ? "light" : "dark")"; face.lifetime = .keepAlways; add(face)

                app.buttons["Details"].firstMatch.tap()
                XCTAssertTrue(shown("cli_3f9a2c1b").waitForExistence(timeout: 3), "\(name): the id is kept under Details")
                let details = XCTAttachment(screenshot: app.screenshot())
                details.name = "Agent details \(name) \(light ? "light" : "dark")"; details.lifetime = .keepAlways; add(details)
                app.terminate()
            }
        }
    }

    func testCommonNativeRenderersShowContentInsteadOfJSON() {
        continueAfterFailure = false
        let cases: [(String, [String])] = [
            ("codex-terminal", ["npm test", "Exit code", "Tests passed"]),
            ("read", ["app.ts", "const before = 1;", "const after = 2;"]),
            ("edit", ["1 added · 1 removed", "const value = 2;", "const value = 1;"]),
            ("codex-patch", ["app.ts", "1 added · 1 removed", "const value = 2;"]),
            ("grep", ["TODO", "src/app.ts:12:TODO add tests"]),
            ("logs", ["4 of 120 logs · 1 error · 1 warning", "Repeated 2 times", "Connected", "Retrying connection"]),
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

    func testNativeChatViewInteractiveParity() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--native-chat-ui-tests"]
        app.launch()

        // 1. Scene 1: User quote, context tags, tool strip, sub-agent task row, code block, respondent & thinking
        let swiftTool = app.buttons["NativeToolStrip.tool.call-bash-1"]
        XCTAssertTrue(swiftTool.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["NativeToolStrip.tool.call-read-1"].exists)
        XCTAssertTrue(app.staticTexts["Compare V2MessageRow and NativeChatView"].waitForExistence(timeout: 5))

        // Tap tool lozenge -> opens ToolCallDetailsSheet
        swiftTool.tap()
        let doneButton = app.buttons["ToolCallDetails.done"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["ToolCallDetails.summary.call-bash-1"].exists)
        let sheetShot = XCTAttachment(screenshot: app.screenshot())
        sheetShot.name = "NativeChat ToolCallDetails Sheet"
        sheetShot.lifetime = .keepAlways
        add(sheetShot)
        doneButton.tap()

        // The respondent lozenge is in the reply's toolbar, which a tap on the
        // card opens (since 02af849b8). The notch's texts all carry its id.
        let notch = app.descendants(matching: .any).matching(identifier: "NativeChat.respondentNotch.a-1").firstMatch
        XCTAssertTrue(notch.waitForExistence(timeout: 5))
        notch.tap()

        // Tap respondent lozenge -> expands turn metadata tray
        let respondent = app.buttons["NativeChat.respondentLozenge.a-1"]
        XCTAssertTrue(respondent.waitForExistence(timeout: 5))
        respondent.tap()
        XCTAssertTrue(app.staticTexts["claude-opus-4-6"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["NativeChat.rewind.a-1"].exists)

        // Thinking is open by default, as the web chat shows it: in a reply's
        // card and in a row of its own, each with the button that folds them.
        let thinkingText = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Checking how V2MessageRow")).firstMatch
        let standaloneThinking = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Deciding whether the strip")).firstMatch
        let thinkingToggle = app.buttons["NativeChat.thinking.toggle"]
        XCTAssertTrue(thinkingText.waitForExistence(timeout: 3))
        XCTAssertTrue(standaloneThinking.exists)
        XCTAssertEqual(app.buttons.matching(identifier: "NativeChat.thinking.fold").count, 2)
        XCTAssertFalse(thinkingToggle.exists)
        let openShot = XCTAttachment(screenshot: app.screenshot())
        openShot.name = "NativeChat Thinking Open"
        openShot.lifetime = .keepAlways
        add(openShot)

        // Folded: a lozenge in place of each, which opens its own
        app.buttons["NativeChatHarness.thinkingFolded"].tap()
        XCTAssertTrue(thinkingToggle.waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons.matching(identifier: "NativeChat.thinking.toggle").count, 2)
        XCTAssertFalse(thinkingText.exists)
        XCTAssertFalse(standaloneThinking.exists)
        let foldedShot = XCTAttachment(screenshot: app.screenshot())
        foldedShot.name = "NativeChat Thinking Folded"
        foldedShot.lifetime = .keepAlways
        add(foldedShot)
        // The reply's lozenge opens the reply's thinking and leaves the other folded.
        XCTAssertFalse(app.buttons["NativeChat.thinking.pin"].exists)
        app.otherElements["NativeChat.assistantMessage.a-1"].buttons["NativeChat.thinking.toggle"].tap()
        XCTAssertTrue(thinkingText.waitForExistence(timeout: 3))
        XCTAssertFalse(standaloneThinking.exists)
        // The opened lozenge, and only that one, offers the pin that switches to Open.
        XCTAssertEqual(app.buttons.matching(identifier: "NativeChat.thinking.pin").count, 1)
        XCTAssertTrue(app.otherElements["NativeChat.assistantMessage.a-1"].buttons["NativeChat.thinking.pin"].exists)
        let pinShot = XCTAttachment(screenshot: app.screenshot())
        pinShot.name = "NativeChat Thinking Folded, One Opened"
        pinShot.lifetime = .keepAlways
        add(pinShot)

        // None: no thinking at all
        app.buttons["NativeChatHarness.thinkingNone"].tap()
        XCTAssertTrue(thinkingToggle.waitForNonExistence(timeout: 3))
        XCTAssertFalse(thinkingText.exists)
        XCTAssertFalse(standaloneThinking.exists)
        let noneShot = XCTAttachment(screenshot: app.screenshot())
        noneShot.name = "NativeChat Thinking None"
        noneShot.lifetime = .keepAlways
        add(noneShot)

        app.buttons["NativeChatHarness.thinkingOpen"].tap()
        XCTAssertTrue(thinkingText.waitForExistence(timeout: 3))

        // 2. Scene 2: Interactive askUser card + structured table
        app.buttons["NativeChatHarness.scene2"].tap()
        let option = app.buttons["NativeChat.askUser.option.strip"]
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        option.tap()
        // No page/transport is attached in this harness. A tap must not claim
        // success; only the separate acknowledgement can finish the card.
        XCTAssertTrue(option.isEnabled)
        app.buttons["NativeChatHarness.acknowledgeAnswer"].tap()
        // An answered card keeps the chosen option lit and disables them all; the
        // "Answered:" line is only for a typed answer that matches no option.
        expectation(for: NSPredicate(format: "isEnabled == false"), evaluatedWith: option)
        waitForExpectations(timeout: 3)

        // 3. Scene 3: Group chat avatar, conversation gap, note, artefact card, CLI seams, error card
        app.buttons["NativeChatHarness.scene3"].tap()
        XCTAssertTrue(app.staticTexts["Alex Rivera"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["native-chat-architecture"].exists)
        XCTAssertTrue(app.staticTexts["GIT COMMIT"].exists)
        XCTAssertTrue(app.staticTexts["CONTEXT COMPACTED"].exists)
        XCTAssertTrue(app.staticTexts["Upstream Rate Limit (429)"].exists)
    }

    func testNativeChatImageViewerFitsZoomsAndPans() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--native-chat-ui-tests", "--scene=4"]
        app.launch()

        // The reply's wide picture opens fitted: its whole width across the
        // viewer, its own shape, centred.
        let wide = app.buttons["Landscape test card"]
        XCTAssertTrue(wide.waitForExistence(timeout: 5))
        wide.tap()
        let viewer = app.scrollViews["NativeChat.imageViewer"]
        let picture = viewer.images["NativeChat.imageViewer.image"]
        XCTAssertTrue(picture.waitForExistence(timeout: 5))
        assertFitted(picture, in: viewer, aspect: 1.6)
        attachScreenshot(app, "Image viewer: wide picture fitted")

        // A pinch zooms in, keeping the shape, with no blank space beside it.
        viewer.pinch(withScale: 3, velocity: 4)
        let zoomed = settledFrame(of: picture)
        XCTAssertGreaterThan(zoomed.width, viewer.frame.width * 1.8)
        XCTAssertEqual(zoomed.width / zoomed.height, 1.6, accuracy: 0.02)
        XCTAssertLessThanOrEqual(zoomed.minX, viewer.frame.minX + 1)
        XCTAssertGreaterThanOrEqual(zoomed.maxX, viewer.frame.maxX - 1)
        attachScreenshot(app, "Image viewer: pinched")

        // A drag pans it, and the edge it pans towards still meets the viewer's.
        viewer.swipeLeft()
        let panned = settledFrame(of: picture)
        XCTAssertLessThan(panned.minX, zoomed.minX - 40)
        XCTAssertGreaterThanOrEqual(panned.maxX, viewer.frame.maxX - 1)
        XCTAssertEqual(panned.width, zoomed.width, accuracy: 1)
        attachScreenshot(app, "Image viewer: panned")

        // While zoomed, a downward drag stays in the picture: the sheet stays open.
        viewer.swipeDown()
        _ = settledFrame(of: picture)
        XCTAssertTrue(picture.exists)
        XCTAssertGreaterThan(picture.frame.width, viewer.frame.width * 1.8)

        // A double tap goes back to the fit; the next zooms in on that point,
        // here the top-left corner, whose edges then meet the viewer's.
        viewer.doubleTap()
        assertFitted(picture, in: viewer, aspect: 1.6)
        picture.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.1)).doubleTap()
        let corner = settledFrame(of: picture)
        XCTAssertGreaterThan(corner.width, viewer.frame.width * 1.8)
        XCTAssertEqual(corner.minX, viewer.frame.minX, accuracy: 1)
        XCTAssertEqual(corner.minY, viewer.frame.minY, accuracy: 1)
        attachScreenshot(app, "Image viewer: double tapped in at the top-left")

        // At the picture's top edge a downward drag is still the picture's:
        // the sheet stays open and the corner settles back in place.
        viewer.swipeDown(velocity: .fast)
        let afterDrag = settledFrame(of: picture)
        XCTAssertTrue(picture.exists)
        XCTAssertEqual(afterDrag.width, corner.width, accuracy: 1)
        XCTAssertEqual(afterDrag.minY, viewer.frame.minY, accuracy: 1)
        viewer.doubleTap()
        assertFitted(picture, in: viewer, aspect: 1.6)

        // Fitted, a downward swipe closes the sheet as before.
        viewer.swipeDown(velocity: .fast)
        XCTAssertTrue(picture.waitForNonExistence(timeout: 5))

        // The user's tall attachment fits by its height instead, and pans up
        // and down once zoomed.
        let tall = app.buttons["Portrait test card"]
        XCTAssertTrue(tall.waitForExistence(timeout: 5))
        tall.tap()
        XCTAssertTrue(picture.waitForExistence(timeout: 5))
        assertFitted(picture, in: viewer, aspect: 0.5)
        attachScreenshot(app, "Image viewer: tall picture fitted")
        viewer.pinch(withScale: 3, velocity: 4)
        let tallZoomed = settledFrame(of: picture)
        XCTAssertGreaterThan(tallZoomed.height, viewer.frame.height * 1.8)
        viewer.swipeUp()
        let tallPanned = settledFrame(of: picture)
        XCTAssertLessThan(tallPanned.minY, tallZoomed.minY - 40)
        XCTAssertGreaterThanOrEqual(tallPanned.maxY, viewer.frame.maxY - 1)
        attachScreenshot(app, "Image viewer: tall picture zoomed and panned up")
        app.buttons["NativeChat.imageViewer.done"].tap()
        XCTAssertTrue(picture.waitForNonExistence(timeout: 5))
    }

    func testNativeChatFirstMessageStartsBelowTheBar() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--native-chat-inset-ui-tests"]
        app.launch()

        // The chat column runs under the status bar, as in the agent screen,
        // and the bar floats at the window's top clearance. Scrolled to its
        // top, the chat's first message must start below the bar, not behind it.
        let bar = app.otherElements["NativeChatInsetHarness.bar"]
        let first = app.otherElements["NativeChat.userMessage.u-inset"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        // The window's clearance reaches the chat a moment after it appears.
        let deadline = Date().addingTimeInterval(5)
        while first.frame.minY < bar.frame.maxY, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        attachScreenshot(app, "Native chat below the bar")
        XCTAssertGreaterThanOrEqual(first.frame.minY, bar.frame.maxY,
                                    "first message \(first.frame) under the bar \(bar.frame)")
    }

    /// Peter, 27 October 2026: dragging to extend a text selection in place also
    /// slid the bubble to reply. A drag that is selecting text is the
    /// selection's, and so is any drag while a selection shows; once it is
    /// dismissed, a plain swipe replies again.
    func testNativeChatSelectingTextDoesNotSwipeToReply() {
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchArguments = ["--native-chat-ui-tests"]
        app.launch()
        let reply = app.staticTexts["NativeChatHarness.replyTarget"]
        let responder = app.staticTexts["NativeChatHarness.responder"]
        XCTAssertTrue(reply.waitForExistence(timeout: 10))
        let prose = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "I've ported the web chat pipeline")).firstMatch
        XCTAssertTrue(prose.waitForExistence(timeout: 5))
        XCTAssertEqual(reply.label, "reply=-")
        let card = app.otherElements["NativeChat.assistantMessage.a-1"]
        let swipeRight = {
            card.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.97))
                .press(forDuration: 0.05, thenDragTo: card.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.97)),
                       withVelocity: .default, thenHoldForDuration: 0)
        }

        // Long-press into the text to start a selection, then drag right to extend it.
        prose.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.2))
            .press(forDuration: 1.2, thenDragTo: prose.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.2)))
        attachScreenshot(app, "Selection extended to the right")
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", ",selected"), object: responder)
        XCTAssertEqual(XCTWaiter().wait(for: [selected], timeout: 2), .completed, "no selection was made: \(responder.label)")
        XCTAssertEqual(reply.label, "reply=-", "extending a selection swiped the reply into a quote")

        // While the selection shows, a swipe right is not a reply either.
        swipeRight()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(reply.label, "reply=-", "a swipe with text selected replied")

        // Dismissed (a tap in the text outside it), a plain swipe replies again.
        let lastLine = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Tap any tool lozenge above")).firstMatch
        lastLine.tap()
        let deadline = Date().addingTimeInterval(3)
        while responder.label.contains(",selected"), Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertFalse(responder.label.contains(",selected"), "the selection did not go: \(responder.label)")
        swipeRight()
        XCTAssertTrue(reply.wait(for: \.label, toEqual: "reply=a-1", timeout: 3),
                      "a plain swipe right no longer replies: \(reply.label)")
    }

    /// Peter, 27 October 2026: the lozenges a tap reveals must cut into the
    /// bubble's edge as the web chat's do, and not move the bubble. A reply's
    /// actions open on its top edge beside the respondent pill, with its time on
    /// the bottom edge; a user message's open on its top edge. Neither moves.
    func testNativeChatEdgeActionsCutInWithoutMovingTheBubble() {
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchArguments = ["--native-chat-ui-tests"]
        app.launch()

        // At rest the respondent label is cut into the card's top edge, and the
        // card ends at the row's bottom: that gives both edges.
        let reply = app.otherElements["NativeChat.assistantMessage.a-1"]
        let notch = app.descendants(matching: .any).matching(identifier: "NativeChat.respondentNotch.a-1").firstMatch
        XCTAssertTrue(notch.waitForExistence(timeout: 10))
        let prose = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "I've ported the web chat pipeline")).firstMatch
        XCTAssertTrue(prose.exists)
        let resting = settledFrame(of: reply)
        let restingProse = settledFrame(of: prose)
        let topEdge = notch.frame.midY
        attachScreenshot(app, "Reply at rest")
        notch.tap()
        let replyAction = app.otherElements["NativeChat.assistantToolbar.a-1"].buttons["Reply"]
        XCTAssertTrue(replyAction.waitForExistence(timeout: 5))
        let open = settledFrame(of: reply)
        attachScreenshot(app, "Reply's actions open")
        XCTAssertEqual(settledFrame(of: prose).minY, restingProse.minY, accuracy: 0.5, "the reply's text moved when its actions opened")
        XCTAssertEqual(open.minY, resting.minY, accuracy: 0.5, "the reply moved when its actions opened")
        XCTAssertEqual(open.height, resting.height, accuracy: 0.5, "the reply changed height when its actions opened")
        XCTAssertEqual(topEdge, resting.minY + 11, accuracy: 2, "the resting label is not on the card's top edge")
        XCTAssertEqual(replyAction.frame.midY, topEdge, accuracy: 2, "Reply is not on the card's top edge")
        let respondent = app.buttons["NativeChat.respondentLozenge.a-1"]
        XCTAssertTrue(respondent.exists)
        XCTAssertEqual(respondent.frame.midY, topEdge, accuracy: 2, "the respondent pill is not on the card's top edge")
        let time = app.descendants(matching: .any).matching(identifier: "NativeChat.time").firstMatch
        XCTAssertTrue(time.exists)
        XCTAssertEqual(time.frame.midY, resting.maxY, accuracy: 2, "the time is not on the card's bottom edge")

        // The user message above it: bring it into view, then open its actions
        // (which closes the reply's: one bubble's actions show at a time).
        app.windows.firstMatch.swipeDown(velocity: .slow)
        let user = app.otherElements["NativeChat.userMessage.u-1"]
        XCTAssertTrue(user.waitForExistence(timeout: 5))
        let userText = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "port the web chat tool strip")).firstMatch
        let userResting = settledFrame(of: user)
        let userTextResting = settledFrame(of: userText)
        user.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.9)).tap()
        let userReply = app.otherElements["NativeChat.userToolbar.u-1"].buttons["Reply"]
        XCTAssertTrue(userReply.waitForExistence(timeout: 5))
        let userOpen = settledFrame(of: user)
        attachScreenshot(app, "User message's actions open")
        XCTAssertEqual(settledFrame(of: userText).minY, userTextResting.minY, accuracy: 0.5, "the user message's text moved")
        XCTAssertEqual(userOpen.minY, userResting.minY, accuracy: 0.5, "the user message moved when its actions opened")
        XCTAssertEqual(userOpen.height, userResting.height, accuracy: 0.5, "the user message changed height")
        XCTAssertEqual(userReply.frame.midY, userResting.minY, accuracy: 2, "Reply is not on the bubble's top edge")
        let userTime = app.descendants(matching: .any).matching(identifier: "NativeChat.time").firstMatch
        XCTAssertTrue(userTime.exists)
        XCTAssertEqual(userTime.frame.midY, userResting.maxY, accuracy: 2, "the time is not on the bubble's bottom edge")
    }

    /// Peter, 27 October 2026: entering a chat in native mode, it was sometimes
    /// blank until a scroll, and not at its end. Every chat entered opens at its
    /// end with its last message on screen: a cold chat first after launch (sent
    /// empty, then its rows), another chat (saved place and catch-ups), the same
    /// chat again after reading up while rows arrived, a cold chat after another
    /// read partway, a short chat after that, and back to a long one.
    func testNativeChatOpensEveryEnteredChatAtItsEnd() {
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchArguments = ["--native-chat-entry-ui-tests"]
        app.launch()
        XCTAssertTrue(app.staticTexts["NativeChatEntryHarness.report"].waitForExistence(timeout: 10))

        enterNativeChat("chat-d", in: app, settle: 6)
        readOlderNativeChatMessages(in: app)
        enterNativeChat("chat-a", in: app, settle: 6)
        readOlderNativeChatMessages(in: app)
        enterNativeChat("chat-b", in: app, settle: 6)
        readOlderNativeChatMessages(in: app)
        enterNativeChat("chat-b", in: app, settle: 3)
        readOlderNativeChatMessages(in: app)
        enterNativeChat("chat-e", in: app, settle: 6)
        readOlderNativeChatMessages(in: app)
        enterNativeChat("chat-c", in: app, settle: 6)
        enterNativeChat("chat-a", in: app, settle: 3)
    }

    /// A cold chat whose rows land as it slides in moves only sideways. On Peter's Duo
    /// (8 November 2026) the rows of a cold chat, its history applied just as the
    /// slide began, drifted about 70 pt down along the slide's own curve: the nod.
    func testNativeChatColdEntryHoldsStillWhileSliding() {
        continueAfterFailure = true
        // The offset write before the fix, which took the slide's animation
        // (`-perfOff unanimatedOffsets`): reported beside it in the same build.
        print("[ENTRYDRIFT] control \(coldEntryDrifts(arguments: ["-perfOff", "unanimatedOffsets"]))")
        let drifts = coldEntryDrifts(arguments: [])
        print("[ENTRYDRIFT] fixed \(drifts)")
        for (index, drift) in drifts.enumerated() {
            XCTAssertTrue(drift >= 0 && drift <= 2,
                          "entry \(index + 1) of chat-f moved \(drift) pt up or down while it slid in")
        }
    }

    /// History landing above a chat that follows its end must not move what is on
    /// screen. Peter's Duo, 8 November 2026: after he opened a chat, an older tool
    /// call's screenshots landed above him one by one (seven 430 pt cards within a
    /// second, from 2.2 s), the chat corrected each one twice, and it "nods a few
    /// times". chat-g replays those times, then three more after the 3 s entry hold,
    /// and tracks its last row as drawn, every frame, for seven seconds once landed.
    func testNativeChatHoldsStillWhileHistoryLandsAboveIt() {
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchArguments = ["--native-chat-entry-ui-tests"]
        app.launch()
        XCTAssertTrue(app.staticTexts["NativeChatEntryHarness.report"].waitForExistence(timeout: 10))

        enterNativeChat("chat-c", in: app, settle: 3)
        enterNativeChat("chat-g", in: app, settle: 8.5)
        let state = nativeChatEntryReport(app)
        print("[CATCHUPDRIFT] \(state)")
        let frames = Int(state["catchUpFrames"] ?? "") ?? 0
        XCTAssertGreaterThan(frames, 120, "the recorder did not see the last row for long enough: \(state)")
        let drift = Double(state["catchUpDrift"] ?? "") ?? .infinity
        XCTAssertTrue(drift >= 0 && drift <= 1,
                      "the last row moved \(drift) pt as history landed above it: \(state)")
        XCTAssertEqual(state["catchUpMoves"], "0", "frames where the last row moved: \(state)")
    }

    /// A composer fold undone within moments must not move a chat resting at its end.
    /// Peter's iPhone 17 Pro Max, 9 November 2026: 1.6 s after a chat landed, the
    /// composer folded to its pill and unfolded 15 ms later (clearance 195 → 106 → 195
    /// pt), and the chat jumped 89 pt and came back down. chat-c once its catch-ups
    /// have landed: three folds undone after 15 ms, its last row tracked every frame.
    func testNativeChatHoldsStillThroughAFoldUndone() {
        continueAfterFailure = true
        // Two controls, reported beside it in the same build: the SwiftUI scroller this
        // replaces, and the list taking each drop at once (`-perfOff clearanceDropDelay`).
        print("[FOLDDRIFT] old scroller \(foldUndoneReport(arguments: ["-ripul.nativeChatPerf.ownedList", "NO"]))")
        print("[FOLDDRIFT] control \(foldUndoneReport(arguments: ["-perfOff", "clearanceDropDelay"]))")
        let state = foldUndoneReport(arguments: [])
        print("[FOLDDRIFT] fixed \(state)")
        let frames = Int(state["catchUpFrames"] ?? "") ?? 0
        XCTAssertGreaterThan(frames, 60, "the recorder did not see the last row for long enough: \(state)")
        let drift = Double(state["catchUpDrift"] ?? "") ?? .infinity
        XCTAssertTrue(drift >= 0 && drift <= 1, "the last row moved \(drift) pt through a fold undone: \(state)")
        XCTAssertEqual(state["catchUpMoves"], "0", "frames where the last row moved: \(state)")
    }

    /// Scrolling a long chat costs no more with the owned list than with the SwiftUI
    /// scroller it replaces. Fast flings through chat-a (170 rows of text, older and
    /// back), with every frame's gap recorded (`HitchRecorder`: frames later than one
    /// and a half intervals, the time they lost, the worst gap), alternating the two
    /// scrollers in the same build. XCTest's own hitch metric gives no numbers on a
    /// simulator. Printed as `[SCROLLHITCH]`; the test asks only that frames were seen.
    func testNativeChatScrollHitchesAgainstTheOldScroller() {
        scrollHitchRounds([("old scroller", ["-ripul.nativeChatPerf.ownedList", "NO"]), ("owned list", [])])
    }

    /// The same flings with the owned list's rows in `UIHostingConfiguration` content
    /// views (`-perfOff rowController`, Debug) and in the hosting controllers they are in.
    func testNativeChatScrollHitchesRowHosting() {
        scrollHitchRounds([("rows in content views", ["-perfOff", "rowController"]), ("rows in hosting controllers", [])])
    }

    private func scrollHitchRounds(_ variants: [(String, [String])]) {
        continueAfterFailure = true
        for round in 1...2 {
            for (name, arguments) in variants {
                let state = scrollHitches(arguments: arguments)
                print("[SCROLLHITCH] round \(round) \(name): hitches=\(state["hitches"] ?? "-") lostMs=\(state["hitchLostMs"] ?? "-") "
                      + "worstMs=\(state["hitchWorstMs"] ?? "-") frames=\(state["hitchFrames"] ?? "-")")
                XCTAssertGreaterThan(Int(state["hitchFrames"] ?? "") ?? 0, 100, "\(name): no frames recorded: \(state)")
            }
        }
    }

    private func scrollHitches(arguments: [String]) -> [String: String] {
        let app = XCUIApplication()
        app.launchArguments = ["--native-chat-entry-ui-tests"] + arguments
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["NativeChatEntryHarness.report"].waitForExistence(timeout: 10))
        enterNativeChat("chat-a", in: app, settle: 5)
        app.buttons["NativeChatEntryHarness.recordHitches"].tap()
        let window = app.windows.firstMatch
        for _ in 0..<3 {
            window.swipeDown(velocity: .fast)
            window.swipeDown(velocity: .fast)
            Thread.sleep(forTimeInterval: 0.8)
            window.swipeUp(velocity: .fast)
            window.swipeUp(velocity: .fast)
            Thread.sleep(forTimeInterval: 0.8)
        }
        // XCUITest waits out each coast before the next swipe; the recorder runs a
        // minute, and its counts are read as they stand.
        Thread.sleep(forTimeInterval: 0.5)
        return nativeChatEntryReport(app)
    }

    /// Every message on screen moves with the chat. Peter, 9 November 2026: with rows as
    /// hosting-configuration views, "the next panel that's due sticks, then eventually
    /// unsticks": a row passing under the status bar kept its content out of the safe
    /// area, held at the edge. The row tests track rows' frames, not where their content
    /// is drawn; this tracks the paragraphs themselves, as drawn, through four nudges of
    /// 120 pt that carry rows across the top edge. The simulator has never shown the
    /// sticking, not even in the control, so the phone remains the real check.
    func testNativeChatMessagesMoveWithTheScroll() {
        continueAfterFailure = true
        // Under a bar that adds itself to the safe area, as in the app. Control, reported
        // beside it: rows in hosting-configuration views (`-perfOff rowController`).
        let control = paragraphMoves(arguments: ["--bar-safe-area", "-perfOff", "rowController"])
        print("[MOVEWITHSCROLL] control compared=\(control.compared) off=\(control.off.count) worst=\(control.off.first ?? "-")")
        let fixed = paragraphMoves(arguments: ["--bar-safe-area"])
        print("[MOVEWITHSCROLL] fixed compared=\(fixed.compared) off=\(fixed.off.count)")
        XCTAssertGreaterThan(fixed.compared, 8, "too few paragraphs were seen on both sides of a nudge")
        XCTAssertEqual(fixed.off, [], "paragraphs that did not move with the chat")
    }

    /// chat-a entered, then four nudges of 120 pt: how many paragraphs were seen on both
    /// sides of a nudge, and those that did not move 120 pt with it.
    private func paragraphMoves(arguments: [String]) -> (compared: Int, off: [String]) {
        let app = XCUIApplication()
        app.launchArguments = ["--native-chat-entry-ui-tests"] + arguments
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["NativeChatEntryHarness.report"].waitForExistence(timeout: 10))
        enterNativeChat("chat-a", in: app, settle: 5)
        // One snapshot of the screen's tree per read: asking each of the hundreds of
        // paragraphs a kept chat holds one at a time took minutes.
        let screen = app.windows.firstMatch.frame
        func positions() -> [String: CGFloat] {
            var found: [String: CGFloat] = [:]
            func visit(_ node: XCUIElementSnapshot) {
                if node.elementType == .staticText, node.label.hasPrefix("Paragraph"), node.frame.intersects(screen) {
                    found[node.label] = node.frame.minY
                }
                node.children.forEach(visit)
            }
            if let root = try? app.snapshot() { visit(root) }
            return found
        }
        var compared = 0
        var off: [String] = []
        for nudge in 1...4 {
            let before = positions()
            app.buttons["NativeChatEntryHarness.nudge"].tap()
            Thread.sleep(forTimeInterval: 0.5)
            let after = positions()
            for (label, y) in before {
                guard let moved = after[label] else { continue }
                compared += 1
                if abs(moved - y - 120) > 1 {
                    off.append(String(format: "nudge %d: %@ moved %.0f pt from %.0f", nudge, String(label.prefix(36)), moved - y, y))
                }
            }
        }
        return (compared, off)
    }

    /// Settings > Debug > Native Chat Performance > Owned chat list swaps the scroller in
    /// the chat that is open, as the screen says, both ways. On Peter's Duo (9 November
    /// 2026) the chat stayed on the old scroller with the switch showing on.
    func testOwnedChatListSwitchActsInTheOpenChat() {
        continueAfterFailure = true
        let app = XCUIApplication()
        // No launch argument: one would hide the switch's own value from the app.
        app.launchArguments = ["--native-chat-entry-ui-tests"]
        app.launch()
        XCTAssertTrue(app.staticTexts["NativeChatEntryHarness.report"].waitForExistence(timeout: 10))
        enterNativeChat("chat-c", in: app, settle: 5)
        XCTAssertEqual(nativeChatEntryReport(app)["list"], "owned", "the chat did not open on the owned list")
        app.buttons["NativeChatEntryHarness.switchScroller"].tap()
        Thread.sleep(forTimeInterval: 2)
        let off = nativeChatEntryReport(app)
        XCTAssertEqual(off["list"], "old", "switched off, the open chat kept the owned list: \(off)")
        app.buttons["NativeChatEntryHarness.switchScroller"].tap()
        Thread.sleep(forTimeInterval: 2)
        let on = nativeChatEntryReport(app)
        XCTAssertEqual(on["list"], "owned", "switched back on, the open chat kept the old scroller: \(on)")
        XCTAssertLessThanOrEqual(abs(Double(on["fromEnd"] ?? "") ?? .infinity), 2, "switched back, not at the end: \(on)")
    }

    /// chat-c entered, its catch-ups landed, then three folds undone after 15 ms.
    private func foldUndoneReport(arguments: [String]) -> [String: String] {
        let app = XCUIApplication()
        app.launchArguments = ["--native-chat-entry-ui-tests"] + arguments
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["NativeChatEntryHarness.report"].waitForExistence(timeout: 10))
        enterNativeChat("chat-c", in: app, settle: 5)
        app.buttons["NativeChatEntryHarness.foldUndone"].tap()
        Thread.sleep(forTimeInterval: 4.5)
        return nativeChatEntryReport(app)
    }

    /// chat-f's drift on each of its two entries, among others.
    private func coldEntryDrifts(arguments: [String]) -> [Double] {
        let app = XCUIApplication()
        app.launchArguments = ["--native-chat-entry-ui-tests"] + arguments
        app.launch()
        XCTAssertTrue(app.staticTexts["NativeChatEntryHarness.report"].waitForExistence(timeout: 10))
        var drifts: [Double] = []
        for chat in ["chat-c", "chat-f", "chat-a", "chat-f"] {
            enterNativeChat(chat, in: app, settle: 3)
            guard chat == "chat-f" else { continue }
            drifts.append(Double(nativeChatEntryReport(app)["drift"] ?? "") ?? .infinity)
        }
        app.terminate()
        return drifts
    }

    private func enterNativeChat(_ chat: String, in app: XCUIApplication, settle: TimeInterval,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let back = app.buttons["NativeChatEntryHarness.back"]
        if back.exists, back.isHittable {
            back.tap()
            Thread.sleep(forTimeInterval: 1)
        }
        app.buttons["NativeChatEntryHarness.open.\(chat)"].tap()
        Thread.sleep(forTimeInterval: settle)
        let state = nativeChatEntryReport(app)
        attachScreenshot(app, "Entered \(chat): \(state)")
        XCTAssertEqual(state["chat"], chat, file: file, line: line)
        let fromEnd = Double(state["fromEnd"] ?? "") ?? .infinity
        XCTAssertLessThanOrEqual(abs(fromEnd), 2, "\(chat) did not open at its end: \(state)", file: file, line: line)
        let last = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier ENDSWITH %@", ".\(state["last"] ?? "-")")).firstMatch
        XCTAssertTrue(last.exists && app.windows.firstMatch.frame.intersects(last.frame),
                      "\(chat)'s last message is not on screen: \(state)", file: file, line: line)
    }

    /// Flings toward older messages, leaving the chat well away from its end.
    private func readOlderNativeChatMessages(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<4 { app.windows.firstMatch.swipeDown(velocity: .fast) }
        Thread.sleep(forTimeInterval: 2)
        let fromEnd = Double(nativeChatEntryReport(app)["fromEnd"] ?? "") ?? 0
        XCTAssertGreaterThan(fromEnd, 300, "the chat did not scroll up to read", file: file, line: line)
    }

    private func nativeChatEntryReport(_ app: XCUIApplication) -> [String: String] {
        var fields: [String: String] = [:]
        for part in app.staticTexts["NativeChatEntryHarness.report"].label.split(separator: " ") {
            let pair = part.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { fields[String(pair[0])] = String(pair[1]) }
        }
        return fields
    }

    /// Inside the viewer, across it along one dimension, in the picture's own
    /// shape, and centred.
    private func assertFitted(_ picture: XCUIElement, in viewer: XCUIElement, aspect: CGFloat,
                              file: StaticString = #filePath, line: UInt = #line) {
        let frame = settledFrame(of: picture)
        let bounds = viewer.frame
        XCTAssertEqual(frame.width / frame.height, aspect, accuracy: 0.02, "shape of \(frame)", file: file, line: line)
        XCTAssertTrue(frame.insetBy(dx: 1, dy: 1).width <= bounds.width && frame.insetBy(dx: 1, dy: 1).height <= bounds.height,
                      "\(frame) is larger than the viewer \(bounds)", file: file, line: line)
        XCTAssertTrue(abs(frame.width - bounds.width) < 1 || abs(frame.height - bounds.height) < 1,
                      "\(frame) fills neither dimension of \(bounds)", file: file, line: line)
        XCTAssertEqual(frame.midX, bounds.midX, accuracy: 1, "horizontal centre", file: file, line: line)
        XCTAssertEqual(frame.midY, bounds.midY, accuracy: 1, "vertical centre", file: file, line: line)
    }

    /// The frame once two reads a beat apart agree, so a zoom, a bounce or a
    /// deceleration has finished.
    private func settledFrame(of element: XCUIElement) -> CGRect {
        var last = element.frame
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.15)
            let now = element.frame
            if abs(now.minX - last.minX) < 0.5, abs(now.minY - last.minY) < 0.5, abs(now.width - last.width) < 0.5 {
                return now
            }
            last = now
        }
        return last
    }

    private func attachScreenshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
