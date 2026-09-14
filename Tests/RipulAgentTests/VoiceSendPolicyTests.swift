import XCTest
@testable import RipulAgent

final class VoiceSendPolicyTests: XCTestCase {
    private func command(_ text: String, quiet: Double = 0.8, idle: Double = 0.8, fresh: Bool = true) -> String? {
        VoiceSendPolicy.messageToSend(mode: .sendCommand, text: text, quietFor: quiet,
                                     transcriptIdleFor: idle, audioIsFresh: fresh)
    }

    func testAutomaticKeepsExistingPauseAndNoiseEscape() {
        func automatic(_ quiet: Double, _ idle: Double) -> String? {
            VoiceSendPolicy.messageToSend(mode: .automatic, text: "Hello. Send command.",
                                         quietFor: quiet, transcriptIdleFor: idle, audioIsFresh: true)
        }
        XCTAssertNil(automatic(1.79, 1.79))
        XCTAssertEqual(automatic(1.8, 1.8), "Hello. Send command.")
        XCTAssertEqual(automatic(0.1, 6), "Hello. Send command.")
    }

    func testLongThinkingPausesNeverSendWithoutCommand() {
        XCTAssertNil(command("I am still thinking", quiet: 120, idle: 120))
        XCTAssertNil(command("I can say send command within a sentence.", quiet: 120, idle: 120))
    }

    func testClosingPhraseToleratesCaseWhitespaceAndRecognitionPunctuation() {
        for text in ["Check the logs. Send command.", "Check the logs. SEND COMMAND!",
                     "Check the logs. send, command…", "Check the logs. Send\ncommand  "] {
            XCTAssertEqual(command(text), "Check the logs.", text)
        }
        XCTAssertEqual(command("Check café logs 🦊. Send command."), "Check café logs 🦊.")
    }

    func testOnlyWholeClosingWordsMatch() {
        for text in ["Please resend command", "Please send commands", "Please send command later",
                     "Please send commander", "Please sendcommand", "Please unsend command"] {
            XCTAssertNil(command(text), text)
        }
    }

    func testClosingPhraseIsRemovedButEarlierMentionsStay() {
        XCTAssertEqual(command("Explain the send command option. Send command."),
                       "Explain the send command option.")
    }

    func testCommandAloneCannotSubmitAnEmptyMessage() {
        for text in ["Send command", "SEND COMMAND!", "… Send command.", "", " "] {
            XCTAssertNil(command(text), text)
        }
    }

    func testShortGapAndFreshTranscriptBothHaveToSettle() {
        XCTAssertNil(command("Hello send command", quiet: 0.69, idle: 2))
        XCTAssertNil(command("Hello send command", quiet: 2, idle: 0.69))
        XCTAssertEqual(command("Hello send command", quiet: 0.7, idle: 0.7), "Hello")
    }

    func testContinuedSpeechAndRevisedTranscriptsCancelPendingSend() {
        XCTAssertNil(command("Discuss send command", quiet: 0.4, idle: 0.4))
        // Speech resumes before recognition has caught up.
        XCTAssertNil(command("Discuss send command", quiet: 0.05, idle: 1.2))
        XCTAssertNil(command("Discuss send command as an option", quiet: 1, idle: 1))
        // A later deliberate closing phrase can still send the whole thought.
        XCTAssertEqual(command("Discuss send command as an option. Send command."),
                       "Discuss send command as an option.")
    }

    func testDeadCaptureAndContinuousNoiseDoNotTriggerCommand() {
        XCTAssertNil(command("Hello send command", quiet: 20, idle: 20, fresh: false))
        XCTAssertNil(command("Hello send command", quiet: 0.1, idle: 20))
    }

    func testPreferenceDefaultsAndPersistsIndependentlyOfVoiceProfile() {
        let suite = "voice-send-test-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let original = SpeechPreferences.store
        let profile = SpeechPreferences.activeProfile
        defer {
            SpeechPreferences.store = original
            SpeechPreferences.activeProfile = profile
            defaults.removePersistentDomain(forName: suite)
        }
        SpeechPreferences.store = defaults
        XCTAssertEqual(SpeechPreferences.voiceSendMode, .automatic)
        defaults.set(VoiceSendMode.sendCommand.rawValue, forKey: SpeechPreferences.voiceSendModeKey)
        SpeechPreferences.store = UserDefaults(suiteName: suite)!
        SpeechPreferences.activeProfile = VoiceProfileConfig(allowUserOverride: false)
        XCTAssertEqual(SpeechPreferences.voiceSendMode, .sendCommand)
        defaults.set("invalid", forKey: SpeechPreferences.voiceSendModeKey)
        XCTAssertEqual(SpeechPreferences.voiceSendMode, .automatic)
    }
}
