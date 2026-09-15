import XCTest

final class ToolCallDetailsUITests: XCTestCase {
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
