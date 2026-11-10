import XCTest
@testable import RipulAgent

final class WaitingOnYouButtonPlacementTests: XCTestCase {
    private let portrait = CGRect(x: 0, y: 59, width: 393, height: 759)

    func testUnmovedButtonKeepsItsPositionAboveTheComposer() {
        let frame = WaitingOnYouButtonPlacement.frame(position: nil, in: portrait)
        XCTAssertEqual(frame.size, CGSize(width: 64, height: 64))
        XCTAssertEqual(frame.maxX, portrait.maxX - 12)
        XCTAssertEqual(frame.maxY, portrait.maxY - 96)
    }

    func testADragCanLeaveTheButtonAnywhereAndRestoreIt() {
        let dragged = WaitingOnYouButtonPlacement.frame(origin: CGPoint(x: 120, y: 300), in: portrait)
        let saved = WaitingOnYouButtonPlacement.position(of: dragged, in: portrait)
        let restored = WaitingOnYouButtonPlacement.frame(position: saved, in: portrait)
        XCTAssertEqual(restored.minX, 120, accuracy: 0.001)
        XCTAssertEqual(restored.minY, 300, accuracy: 0.001)
    }

    func testDraggingPastTheScreenStopsInsideTheSafeArea() {
        let left = WaitingOnYouButtonPlacement.frame(origin: CGPoint(x: -400, y: -400), in: portrait)
        let right = WaitingOnYouButtonPlacement.frame(origin: CGPoint(x: 2000, y: 2000), in: portrait)
        XCTAssertTrue(portrait.contains(left))
        XCTAssertTrue(portrait.contains(right))
        XCTAssertEqual(WaitingOnYouButtonPlacement.position(of: left, in: portrait), .zero)
        XCTAssertEqual(WaitingOnYouButtonPlacement.position(of: right, in: portrait), CGPoint(x: 1, y: 1))
    }

    func testRotationKeepsTheRememberedSideAndRelativeHeight() {
        let landscape = CGRect(x: 59, y: 0, width: 734, height: 372)
        let position = CGPoint(x: 1, y: 0.5)
        let frame = WaitingOnYouButtonPlacement.frame(position: position, in: landscape)
        XCTAssertTrue(landscape.contains(frame))
        XCTAssertEqual(frame.maxX, landscape.maxX - 12)
        XCTAssertEqual(frame.midY, landscape.midY)
        XCTAssertEqual(WaitingOnYouButtonPlacement.position(of: frame, in: landscape), position)
    }

    func testKeyboardMovesTheButtonTemporarilyWithoutChangingItsSavedPosition() {
        let position = CGPoint(x: 1, y: 1)
        let resting = WaitingOnYouButtonPlacement.frame(position: position, in: portrait)
        let keyboard = CGRect(x: 0, y: 500, width: 393, height: 352)
        let raised = WaitingOnYouButtonPlacement.frame(position: position, in: portrait, keyboard: keyboard)
        XCTAssertLessThanOrEqual(raised.maxY, keyboard.minY - 16)
        XCTAssertEqual(WaitingOnYouButtonPlacement.frame(position: position, in: portrait), resting)
        let floatingKeyboard = CGRect(x: 0, y: 500, width: 200, height: 200)
        XCTAssertEqual(WaitingOnYouButtonPlacement.frame(position: position, in: portrait, keyboard: floatingKeyboard), resting)
    }

    func testSmallWindowDoesNotSaveAnInvalidPosition() {
        let safe = CGRect(x: 0, y: 0, width: 64, height: 64)
        let frame = WaitingOnYouButtonPlacement.frame(position: CGPoint(x: 1, y: 1), in: safe)
        XCTAssertEqual(frame, safe)
        XCTAssertEqual(WaitingOnYouButtonPlacement.position(of: frame, in: safe), .zero)
    }

    func testInitialButtonClearsTheWholeComposerAboveAnOpenKeyboard() {
        let keyboard = CGRect(x: 0, y: 500, width: 393, height: 352)
        // Includes all composer controls and its jump-to-latest row.
        let composer = CGRect(x: 12, y: 268, width: 369, height: 224)
        let frame = WaitingOnYouButtonPlacement.frame(position: nil, in: portrait, keyboard: keyboard, composers: [composer])
        XCTAssertFalse(frame.isNull)
        XCTAssertLessThanOrEqual(frame.maxY, composer.minY - 8)
        XCTAssertFalse(frame.intersects(keyboard))
    }

    func testSavedAndDraggedPositionsCannotCoverAGrowingComposer() {
        let composer = CGRect(x: 12, y: 410, width: 369, height: 380)
        let saved = CGPoint(x: 1, y: 0.75)
        let before = WaitingOnYouButtonPlacement.frame(position: saved, in: portrait)
        XCTAssertTrue(before.intersects(composer))
        let avoided = WaitingOnYouButtonPlacement.frame(position: saved, in: portrait, composers: [composer])
        XCTAssertLessThanOrEqual(avoided.maxY, composer.minY - 8)
        let dragged = WaitingOnYouButtonPlacement.frame(origin: composer.origin, in: portrait, composers: [composer])
        XCTAssertFalse(dragged.isNull)
        XCTAssertFalse(dragged.intersects(composer))
        XCTAssertEqual(WaitingOnYouButtonPlacement.frame(position: saved, in: portrait), before,
                       "Closing the composer restores the saved position")
    }

    func testNarrowChatCanLeaveRoomBesideTheComposer() {
        let safe = CGRect(x: 0, y: 0, width: 900, height: 600)
        let composer = CGRect(x: 0, y: 10, width: 400, height: 580)
        let frame = WaitingOnYouButtonPlacement.frame(origin: CGPoint(x: 300, y: 200), in: safe, composers: [composer])
        XCTAssertFalse(frame.isNull)
        XCTAssertGreaterThanOrEqual(frame.minX, composer.maxX + 8)
        XCTAssertTrue(safe.contains(frame))
    }

    func testNoRoomHidesTheButtonInsteadOfCoveringControls() {
        XCTAssertTrue(WaitingOnYouButtonPlacement.frame(position: nil, in: portrait, composers: [portrait]).isNull)
        XCTAssertFalse(WaitingOnYouButtonPlacement.frame(position: nil, in: portrait).isNull)
    }
}
