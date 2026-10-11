import XCTest
@testable import RipulAgent

final class VoiceSendPolicyTests: XCTestCase {
    private func command(_ text: String, quiet: Double = 0.8, idle: Double = 0.8, fresh: Bool = true) -> String? {
        VoiceSendPolicy.messageToSend(mode: .sendCommand, text: text, quietFor: quiet,
                                     transcriptIdleFor: idle, audioIsFresh: fresh)
    }

    private func run(_ text: String, quiet: Double = 5, unchanged: Double = 1.5, repeats: Int = 1,
                     fresh: Bool = true) -> String? {
        VoiceSendPolicy.commandToRun(text: text, quietFor: quiet, wordsUnchangedFor: unchanged,
                                     unchangedRepeats: repeats, audioIsFresh: fresh)
    }

    func testACommandEndsWhenTheRecogniserRepeatsItself() {
        // No closing phrase is needed, and none is waited for.
        XCTAssertEqual(run(" go back to my chats "), "go back to my chats")
        // A stalled microphone is not a pause.
        XCTAssertNil(run("go back to my chats", unchanged: 3, repeats: 3, fresh: false))
        XCTAssertNil(run("   ", unchanged: 9, repeats: 9))
    }

    func testTimeAloneNeverEndsACommand() {
        // Measured on a phone: the recogniser reports about once a second, so
        // a wait of 0.8 seconds expired between two reports and ended
        // sentences mid-word ("Open the chat about app or-"). Without a
        // repeat there is no evidence the person has stopped.
        XCTAssertNil(run("Open the chat about app", unchanged: 0.9, repeats: 0))
        XCTAssertNil(run("Open the chat about app", unchanged: 3, repeats: 0))
        // Nor does a repeat hard on the heels of a change.
        XCTAssertNil(run("Open the chat about app", unchanged: 0.3, repeats: 1))
    }

    func testAVoiceJustHeardHoldsItBack() {
        // When the level check can hear the speaker, a voice in the last half
        // second means the words are about to change.
        XCTAssertNil(run("Open the chat", quiet: 0.2))
        // When it cannot (quiet reads as forever), the repeat still decides.
        XCTAssertEqual(run("Open the chat", quiet: 999), "Open the chat")
    }

    func testAnUnfinishedSentenceIsGivenLonger() {
        for trailing in ["Open the one about", "Open the one about-", "Open the chat called…", "Go to my", "Open the tunnel chat and"] {
            XCTAssertTrue(VoiceSendPolicy.looksUnfinished(trailing), trailing)
            XCTAssertNil(run(trailing, unchanged: 1.5, repeats: 1), trailing)
            XCTAssertNil(run(trailing, unchanged: 2.5, repeats: 2), trailing)
            XCTAssertEqual(run(trailing, unchanged: 3.5, repeats: 3), trailing)
        }
        // Words that end real commands are not mistaken for trailing off.
        for whole in ["carry on", "log in", "open the last one", "what is this chat about?", "stop", "go back to my chats."] {
            let unfinished = VoiceSendPolicy.looksUnfinished(whole)
            XCTAssertEqual(unfinished, whole.hasSuffix("about?"), whole)
        }
    }

    func testTheClosingPhraseStillEndsACommandAndSooner() {
        // An explicit end needs no repeat. The text comes back whole; the
        // phrase is dropped where the sentence is sent.
        XCTAssertEqual(run("go back to my chats. Send command.", unchanged: 0.7, repeats: 0),
                       "go back to my chats. Send command.")
        XCTAssertNil(run("go back to my chats", unchanged: 0.7, repeats: 0))
    }

    func testRepunctuatedWordsAreTheSameWords() {
        XCTAssertEqual(VoiceSendPolicy.words("Go back to my chats."), VoiceSendPolicy.words("go back, to my  chats"))
        XCTAssertNotEqual(VoiceSendPolicy.words("Go back to my chats"), VoiceSendPolicy.words("Go back to my chat"))
    }

    func testALoudRoomStillEndsEventually() {
        XCTAssertEqual(run("go back to my chats", quiet: 0, unchanged: 6, repeats: 0), "go back to my chats")
        XCTAssertNil(run("go back to my chats", quiet: 0, unchanged: 5, repeats: 5))
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
                     "Please send commander", "Please unsend command", "Please sendcommander"] {
            XCTAssertNil(command(text), text)
        }
    }

    func testClosingPhraseToleratesMishearingsAndJoinedWords() {
        for text in ["Check the logs sendcommand", "Check the logs sent command",
                     "Check the logs send-command.", "Check the logs sand command",
                     "Check the logs send comand", "Check the logs send commend."] {
            XCTAssertEqual(command(text), "Check the logs", text)
        }
        for text in ["Check the logs. Same command.", "Check the logs. Same, command.",
                     "Check the logs. Said command.", "Check the logs. Send commands.",
                     "Check the logs. Send comment.", "Check the logs.  same command"] {
            XCTAssertEqual(command(text), "Check the logs.", text)
        }
    }

    func testLooseFormsNeedTheirOwnSentence() {
        for text in ["Run the same command", "How do I send commands", "Please send comment",
                     "What she said command", "Run the samecommand"] {
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
        XCTAssertEqual(SpeechPreferences.voiceSendMode, .sendCommand)
        XCTAssertNil(VoiceSendPolicy.messageToSend(
            mode: SpeechPreferences.voiceSendMode, text: "Still thinking", quietFor: 120,
            transcriptIdleFor: 120, audioIsFresh: true))
        defaults.set(VoiceSendMode.automatic.rawValue, forKey: SpeechPreferences.voiceSendModeKey)
        SpeechPreferences.store = UserDefaults(suiteName: suite)!
        SpeechPreferences.activeProfile = VoiceProfileConfig(allowUserOverride: false)
        XCTAssertEqual(SpeechPreferences.voiceSendMode, .automatic)
        defaults.set("invalid", forKey: SpeechPreferences.voiceSendModeKey)
        XCTAssertEqual(SpeechPreferences.voiceSendMode, .sendCommand)
    }
}
