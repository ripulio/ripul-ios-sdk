import XCTest
@testable import RipulAgent

/// Pins the anchor math — pure Foundation, so these run under plain
/// `swift test` on macOS. The invariants that matter:
///
/// 1. Round-trip: fraction → point against the SAME frame reproduces the
///    original point, in both layout directions.
/// 2. Element-grounded: the point derived against a MOVED/RESIZED frame lands
///    at the same fraction of the new frame — never at the old screen spot.
/// 3. Leading-relative: an anchor recorded in LTR names the mirrored spot
///    under RTL, so "the control near the leading edge" stays that control.
final class MacroAnchorTests: XCTestCase {
    func testRoundTripLTR() throws {
        let anchor = try XCTUnwrap(MacroAnchor.fraction(x: 304, y: 122, frameX: 16, frameY: 100,
                                                        width: 360, height: 44, rightToLeft: false))
        XCTAssertEqual(anchor.leading, 0.8, accuracy: 0.0001)
        XCTAssertEqual(anchor.top, 0.5, accuracy: 0.0001)
        let p = anchor.point(frameX: 16, frameY: 100, width: 360, height: 44, rightToLeft: false)
        XCTAssertEqual(p.x, 304, accuracy: 0.0001)
        XCTAssertEqual(p.y, 122, accuracy: 0.0001)
    }

    func testRoundTripRTL() throws {
        // 80% from the LEADING edge in RTL is 20% from the left.
        let anchor = try XCTUnwrap(MacroAnchor.fraction(x: 304, y: 122, frameX: 16, frameY: 100,
                                                        width: 360, height: 44, rightToLeft: true))
        XCTAssertEqual(anchor.leading, 0.2, accuracy: 0.0001)
        let p = anchor.point(frameX: 16, frameY: 100, width: 360, height: 44, rightToLeft: true)
        XCTAssertEqual(p.x, 304, accuracy: 0.0001)
    }

    func testFollowsMovedAndResizedFrame() throws {
        let anchor = try XCTUnwrap(MacroAnchor.fraction(x: 304, y: 122, frameX: 16, frameY: 100,
                                                        width: 360, height: 44, rightToLeft: false))
        // The element moved right and shrank — the anchor lands at 80% of the
        // NEW frame, far from the stale 304pt screen position.
        let p = anchor.point(frameX: 112, frameY: 300, width: 144, height: 44, rightToLeft: false)
        XCTAssertEqual(p.x, 112 + 0.8 * 144, accuracy: 0.0001)
        XCTAssertEqual(p.y, 322, accuracy: 0.0001)
        XCTAssertGreaterThan(abs(p.x - 304), 40, "an element-grounded anchor must not track the old screen point")
    }

    func testLTRRecordingReplaysAtMirroredSpotUnderRTL() throws {
        // Recorded 80% from leading in LTR; under RTL the leading edge is the
        // RIGHT edge, so the same anchor names x at 20% from the left.
        let anchor = try XCTUnwrap(MacroAnchor.fraction(x: 96, y: 10, frameX: 0, frameY: 0,
                                                        width: 120, height: 20, rightToLeft: false))
        let p = anchor.point(frameX: 0, frameY: 0, width: 120, height: 20, rightToLeft: true)
        XCTAssertEqual(p.x, 24, accuracy: 0.0001)
    }

    func testDegenerateFrameRefused() {
        XCTAssertNil(MacroAnchor.fraction(x: 10, y: 10, frameX: 0, frameY: 0,
                                          width: 0, height: 44, rightToLeft: false))
        XCTAssertNil(MacroAnchor.fraction(x: 10, y: 10, frameX: 0, frameY: 0,
                                          width: 44, height: 0, rightToLeft: false))
    }

    func testClampsOutOfBoundsPoint() throws {
        // A point recorded just outside the frame (rounding, borders) clamps
        // to the edge instead of replaying outside the element.
        let anchor = try XCTUnwrap(MacroAnchor.fraction(x: 130, y: -3, frameX: 0, frameY: 0,
                                                        width: 120, height: 20, rightToLeft: false))
        XCTAssertEqual(anchor.leading, 1)
        XCTAssertEqual(anchor.top, 0)
    }

    func testStepCodableRoundTripAndBackCompat() throws {
        // A step with an anchor survives encoding; old JSON without the key
        // decodes to nil — recorded macros predating anchors keep working.
        let step = MacroStep(kind: .tap, selector: MacroSelector(id: "x"),
                             anchor: MacroAnchor(leading: 0.8, top: 0.5), recordedLabel: "Tap x")
        let data = try JSONEncoder().encode(step)
        let decoded = try JSONDecoder().decode(MacroStep.self, from: data)
        XCTAssertEqual(decoded.anchor, MacroAnchor(leading: 0.8, top: 0.5))

        let legacy = #"{"id":"1","kind":"tap","selector":{"id":"x"},"recordedLabel":"Tap x"}"#
        let old = try JSONDecoder().decode(MacroStep.self, from: Data(legacy.utf8))
        XCTAssertNil(old.anchor)
    }
}
