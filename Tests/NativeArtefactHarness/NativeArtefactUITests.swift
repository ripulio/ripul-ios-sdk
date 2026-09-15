import XCTest

final class NativeArtefactUITests: XCTestCase {
  func testCalculatorAndChecklistShareHost() {
    let app = XCUIApplication()
    app.launch()
    check(app)
  }
  func testDarkAppearance() {
    let app = XCUIApplication()
    app.launchArguments = ["--dark"]
    app.launch()
    check(app)
  }
  private func check(_ app: XCUIApplication) {
    continueAfterFailure = false
    let run = app.buttons["NativeArtefact.run"]
    XCTAssertTrue(run.waitForExistence(timeout: 30), app.debugDescription)
    func replace(_ key: String, _ value: String) {
      let input = app.textFields["Artefacts.input.\(key)"]
      XCTAssertTrue(input.waitForExistence(timeout: 5), app.debugDescription)
      input.tap()
      XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
      input.press(forDuration: 1.1)
      let selectAll = app.menuItems["Select All"]
      XCTAssertTrue(selectAll.waitForExistence(timeout: 3), app.debugDescription)
      selectAll.tap()
      input.typeText(value)
      XCTAssertEqual(input.value as? String, value)
    }
    replace("headcount", "3")
    replace("hours", "7")
    replace("hourlyRate", "20")
    run.tap()
    let cost = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier == 'NativeArtefact.result' AND value CONTAINS '420'")
    ).firstMatch
    XCTAssertTrue(cost.waitForExistence(timeout: 15), app.debugDescription)
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "Native calculator"
    shot.lifetime = .keepAlways
    add(shot)
    app.buttons["Probe"].tap()
    XCTAssertTrue(app.staticTexts["NativeArtefactHarness.status"].label.contains("attached=1"))
    app.buttons["Hide"].tap()
    XCTAssertTrue(run.waitForNonExistence(timeout: 5))
    app.buttons["Show"].tap()
    XCTAssertTrue(cost.waitForExistence(timeout: 15), app.debugDescription)
    XCTAssertEqual(app.textFields["Artefacts.input.headcount"].value as? String, "3")
    app.buttons["Checklist"].tap()
    let toggle = app.switches["Artefacts.input.scopeAgreed"]
    XCTAssertTrue(toggle.waitForExistence(timeout: 15), app.debugDescription)
    for key in ["scopeAgreed", "ownerAssigned", "launchApproved"] {
      app.switches["Artefacts.input.\(key)"].switches.firstMatch.tap()
    }
    run.tap()
    let ready = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier == 'NativeArtefact.result' AND value == 'Ready to start'")
    ).firstMatch
    XCTAssertTrue(ready.waitForExistence(timeout: 15), app.debugDescription)
    let checklist = XCTAttachment(screenshot: app.screenshot())
    checklist.name = "Native checklist"
    checklist.lifetime = .keepAlways
    add(checklist)
    app.buttons["Hide"].tap()
    XCTAssertTrue(run.waitForNonExistence(timeout: 5))
    app.buttons["Show"].tap()
    XCTAssertTrue(ready.waitForExistence(timeout: 15))
  }
}
