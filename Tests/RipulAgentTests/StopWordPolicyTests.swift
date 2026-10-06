import XCTest
@testable import RipulAgent

final class StopWordPolicyTests: XCTestCase {
    private let plan = "Here is the plan for today."

    func testCommandWordsStopAReadout() {
        for heard in ["Stop", "stop.", "OK stop", "Pause!", "wait wait", "hey, STOP it"] {
            XCTAssertTrue(StopWordPolicy.heardCommand(heard, whileSpeaking: plan), heard)
        }
    }

    func testOtherWordsDoNot() {
        for heard in ["", "stopped", "it stops here", "unstoppable", "waiting room", "paused"] {
            XCTAssertFalse(StopWordPolicy.heardCommand(heard, whileSpeaking: plan), heard)
        }
    }

    // No echo cancellation: the mic hears the phone too. The phone saying
    // "stop" is recognised by its neighbours in the readout.
    func testThePhoneSayingACommandIsEcho() {
        let speaking = "Try saying stop now while I'm talking, or wait for the end."
        XCTAssertEqual(StopWordPolicy.verdict(heard: "try saying stop now", whileSpeaking: speaking), .echo)
        XCTAssertEqual(StopWordPolicy.verdict(heard: "or wait for", whileSpeaking: speaking), .echo)
        XCTAssertEqual(StopWordPolicy.verdict(heard: "saying stop", whileSpeaking: speaking), .echo)
    }

    // The bug the first version had: a readout that says "stop" made the
    // listener's own "stop" impossible for that whole utterance.
    func testTheListenerSayingACommandTheReadoutAlsoSays() {
        let speaking = "Try saying stop now while I'm talking."
        XCTAssertTrue(StopWordPolicy.heardCommand("try saying stop now while I'm stop", whileSpeaking: speaking))
        XCTAssertTrue(StopWordPolicy.heardCommand("while stop", whileSpeaking: speaking))
        XCTAssertTrue(StopWordPolicy.heardCommand("pause", whileSpeaking: speaking))
    }

    // A lone command word the readout also says might be the first word of
    // the phone's own sentence: wait for the next result rather than guess.
    func testALoneWordTheReadoutSaysWaitsForContext() {
        let speaking = "That's done. Stop me any time."
        XCTAssertEqual(StopWordPolicy.verdict(heard: "stop", whileSpeaking: speaking), .echo)
        XCTAssertEqual(StopWordPolicy.verdict(heard: "stop me", whileSpeaking: speaking), .echo)
        XCTAssertEqual(StopWordPolicy.verdict(heard: "stop", whileSpeaking: plan), .command)
    }
}
