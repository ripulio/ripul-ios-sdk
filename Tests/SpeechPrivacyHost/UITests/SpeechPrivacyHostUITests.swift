import XCTest

final class SpeechPrivacyHostUITests: XCTestCase {
    @MainActor
    private func verifyWarning(dictation: Bool) {
        let app = XCUIApplication()
        if dictation { app.launchArguments = ["--dictation"] }
        app.launch()
        let microphone = app.buttons["NativeChatInput.microphone"]
        XCTAssertTrue(microphone.waitForExistence(timeout: 10))
        microphone.tap()
        let warning = app.alerts["Microphone unavailable"]
        XCTAssertTrue(warning.waitForExistence(timeout: 5))
        XCTAssertTrue(warning.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "continue by typing")).firstMatch.exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = dictation ? "Dictation warning" : "Conversation warning"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        warning.buttons["OK"].tap()
        app.buttons["Still responsive"].tap()
        XCTAssertTrue(app.staticTexts["Host responsive: 1"].exists)
        XCTAssertEqual(app.state, .runningForeground)
        // The next tap must remain safe after dismissal too.
        microphone.tap()
        XCTAssertTrue(warning.waitForExistence(timeout: 5))
    }

    @MainActor func testProfileMenuChangesProviderAndPersistsAcrossLaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--profile", "--reset-profile"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Effective provider: apple"].waitForExistence(timeout: 10))
        app.buttons["Sessions menu"].tap()
        app.buttons["Profile"].tap()
        XCTAssertTrue(app.staticTexts["Test User"].waitForExistence(timeout: 5))
        app.buttons["Voice"].tap()
        app.buttons["VoiceSettingsScreen.dictationProvider"].tap()
        app.buttons["ElevenLabs"].tap()
        app.navigationBars.buttons["Profile"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["Effective provider: elevenlabs"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = ["--profile"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Effective provider: elevenlabs"].waitForExistence(timeout: 10))
    }

    @MainActor func testConversationWarnsAndHostRemainsUsable() { verifyWarning(dictation: false) }
    @MainActor func testDictationWarnsAndHostRemainsUsable() { verifyWarning(dictation: true) }
}
