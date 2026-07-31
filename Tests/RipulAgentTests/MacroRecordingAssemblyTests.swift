import XCTest
@testable import RipulAgent

/// The auto-pause assembly rules for recording: pause-before-action only
/// once a step already exists, and disabled at zero.
final class MacroRecordingAssemblyTests: XCTestCase {

    private func tap() -> MacroStep {
        MacroStep(kind: .tap, selector: MacroSelector(id: "x"), recordedLabel: "Tap X")
    }

    func testFirstStepGetsNoLeadingPause() {
        let result = MacroRecordingAssembly.appending(tap(), to: [], autoPauseSeconds: 1.5)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].kind, .tap)
    }

    func testLaterStepsGetAPrecedingPause() {
        let first = MacroRecordingAssembly.appending(tap(), to: [], autoPauseSeconds: 1.5)
        let second = MacroRecordingAssembly.appending(tap(), to: first, autoPauseSeconds: 1.5)
        XCTAssertEqual(second.map(\.kind), [.tap, .pause, .tap])
        XCTAssertEqual(second[1].seconds, 1.5)
        XCTAssertEqual(second[1].recordedLabel, "Pause 1.5s")
    }

    func testZeroSecondsDisablesAutoPause() {
        let first = MacroRecordingAssembly.appending(tap(), to: [], autoPauseSeconds: 0)
        let second = MacroRecordingAssembly.appending(tap(), to: first, autoPauseSeconds: 0)
        XCTAssertEqual(second.map(\.kind), [.tap, .tap])
    }

    func testFormatSecondsKeepsWholeNumbersTidy() {
        XCTAssertEqual(MacroRecordingAssembly.formatSeconds(1.0), "1")
        XCTAssertEqual(MacroRecordingAssembly.formatSeconds(1.5), "1.5")
    }
}
