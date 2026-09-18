import XCTest

final class NativeArtefactUITests: XCTestCase {
  func testNativeComposerArtefactPicker() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--picker"]
    app.launch()
    let plus = app.buttons["Attachments and actions"]
    XCTAssertTrue(plus.waitForExistence(timeout: 20), app.debugDescription)
    plus.tap()
    app.buttons["Artefact"].tap()
    let search = app.textFields["Search artefacts"]
    XCTAssertTrue(search.waitForExistence(timeout: 10), app.debugDescription)
    search.tap(); search.typeText("Team")
    let planner = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Team planner'")).firstMatch
    XCTAssertTrue(planner.waitForExistence(timeout: 10), app.debugDescription)
    planner.tap()
    let add = app.buttons["ArtefactChat.add"]
    XCTAssertTrue(add.waitForExistence(timeout: 10), app.debugDescription)
    let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Native artefact picker"; shot.lifetime = .keepAlways; self.add(shot)
    add.tap()
    XCTAssertTrue(app.staticTexts["ArtefactChat.error"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["ArtefactChat.error"].label.contains("not confirmed"))
    add.tap()
    XCTAssertTrue(plus.waitForExistence(timeout: 10))
    let posted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Cards: 1; revision: 2'"), object: app.staticTexts["PickerHarness.receipt"])
    XCTAssertEqual(XCTWaiter.wait(for: [posted], timeout: 10), .completed, app.debugDescription)
    XCTAssertEqual(app.staticTexts["PickerHarness.draft"].label, "Draft: Keep my draft")
    XCTAssertEqual(app.staticTexts["PickerHarness.model"].label, "Model requests: 0")
  }

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
  func testNativeMapUsesTheSameChatHost() { checkMap(dark: false) }
  func testNativeMapDarkAppearance() { checkMap(dark: true) }
  // Functional camera movement only; this is not a chat drag/flick quality test.
  func testExploreChangesMapCamera() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--overflow"]
    app.launch()
    XCTAssertTrue(app.buttons["NativeArtefact.run"].waitForExistence(timeout: 30))
    app.buttons["Map"].tap()
    let explore = app.buttons["NativeMap.explore"]
    XCTAssertTrue(explore.waitForExistence(timeout: 20))
    app.buttons["Probe"].tap()
    explore.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    XCTAssertEqual(explore.label, "Done", app.debugDescription)
    let map = app.otherElements["NativeMap.map"].maps.firstMatch
    let camera = app.staticTexts["NativeArtefactHarness.camera"]
    let before = camera.label
    map.pinch(withScale: 1.7, velocity: 1)
    let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", before), object: camera)
    XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed, app.debugDescription)
    let zoomed = camera.label
    let start = map.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.65))
    let end = map.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.65))
    start.press(forDuration: 0.05, thenDragTo: end)
    let panned = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", zoomed), object: camera)
    XCTAssertEqual(XCTWaiter.wait(for: [panned], timeout: 5), .completed, app.debugDescription)
    XCTAssertEqual(explore.label, "Done")
    app.buttons["Updates"].tap()
    let settled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Updates done; detach=0; heights=1'"), object: app.staticTexts["NativeArtefactHarness.status"])
    XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 12), .completed, app.debugDescription)
    XCTAssertEqual(explore.label, "Done")
  }
  private func checkMap(dark: Bool) {
    continueAfterFailure = false
    let app = XCUIApplication()
    if dark { app.launchArguments = ["--dark"] }
    app.launch()
    XCTAssertTrue(app.buttons["NativeArtefact.run"].waitForExistence(timeout: 30))
    app.buttons["Map"].tap()
    let explore = app.buttons["NativeMap.explore"]
    XCTAssertTrue(explore.waitForExistence(timeout: 20), app.debugDescription)
    XCTAssertEqual(explore.label, "Explore")
    XCTAssertTrue(app.otherElements["NativeMap.map"].maps.firstMatch.exists, app.debugDescription)
    explore.tap()
    XCTAssertEqual(explore.label, "Done")
    explore.tap()
    XCTAssertEqual(explore.label, "Explore")
    let place = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'London Eye'")).firstMatch
    XCTAssertTrue(place.waitForExistence(timeout: 15), app.debugDescription)
    place.tap()
    XCTAssertEqual(app.staticTexts["NativeMap.selection"].label, "London Eye", app.debugDescription)
    XCTAssertTrue(app.buttons["NativeMap.open"].isEnabled)
    app.buttons["Probe"].tap()
    XCTAssertTrue(app.staticTexts["NativeArtefactHarness.status"].label.contains("attached=1"))
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "Native Apple Maps in chat"
    shot.lifetime = .keepAlways
    add(shot)
    if !dark {
      app.buttons["NativeMap.open"].tap()
      XCTAssertTrue(XCUIApplication(bundleIdentifier: "com.apple.Maps").wait(for: .runningForeground, timeout: 15))
      app.activate()
      XCTAssertTrue(explore.waitForExistence(timeout: 15))
    }
    app.buttons["Hide"].tap()
    XCTAssertTrue(explore.waitForNonExistence(timeout: 5))
    app.buttons["Show"].tap()
    XCTAssertTrue(explore.waitForExistence(timeout: 15))
    XCTAssertEqual(app.staticTexts["NativeMap.selection"].label, "London Eye")
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
