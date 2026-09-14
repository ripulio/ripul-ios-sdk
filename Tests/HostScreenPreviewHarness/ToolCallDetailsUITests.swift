import XCTest

final class ToolCallDetailsUITests: XCTestCase {
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
        app.buttons["NativeTool.command.copy"].tap()
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Native command dividers with one Copy button"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["ToolCallDetails.done"].tap()
        app.buttons["Read copied command"].tap()
        XCTAssertEqual(app.staticTexts["Copied command"].label, "python3 check.py &&\ngit status --short")
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
