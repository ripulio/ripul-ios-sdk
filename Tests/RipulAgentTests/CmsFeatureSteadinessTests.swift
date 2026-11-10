import XCTest
@testable import RipulAgent

final class CmsFeatureSteadinessTests: XCTestCase {
    private let home = CGPoint(x: 201, y: 822)

    func testSmallMovesPassAtOnce() {
        var s = CmsFeatureSteadiness()
        XCTAssertTrue(s.next(CGPoint(x: 201, y: 818), shown: home, now: 0).accept)
        XCTAssertTrue(s.next(CGPoint(x: 205, y: 812), shown: CGPoint(x: 201, y: 818), now: 0.016).accept)
    }

    func testATabChangeGlitchIsIgnored() {
        // Measured: x 180 for about 33 ms, then back.
        var s = CmsFeatureSteadiness()
        XCTAssertEqual(s.next(CGPoint(x: 180, y: 822), shown: home, now: 1.000).accept, false)
        XCTAssertEqual(s.next(CGPoint(x: 180, y: 822), shown: home, now: 1.017).accept, false)
        XCTAssertEqual(s.next(CGPoint(x: 180, y: 822), shown: home, now: 1.033).accept, false)
        XCTAssertTrue(s.next(home, shown: home, now: 1.050).accept)
        // And the y one.
        XCTAssertEqual(s.next(CGPoint(x: 201, y: 31), shown: home, now: 2.0).accept, false)
        XCTAssertTrue(s.next(home, shown: home, now: 2.017).accept)
    }

    func testARealJumpIsFollowedOnceItHolds() {
        var s = CmsFeatureSteadiness()
        let rotated = CGPoint(x: 437, y: 380)
        XCTAssertEqual(s.next(rotated, shown: home, now: 0).accept, false)
        XCTAssertEqual(s.next(rotated, shown: home, now: 0.05).waiting, true)
        XCTAssertTrue(s.next(rotated, shown: home, now: 0.09).accept)
    }

    func testAMovingJumpStartsItsHoldAgain() {
        var s = CmsFeatureSteadiness()
        XCTAssertEqual(s.next(CGPoint(x: 100, y: 822), shown: home, now: 0).accept, false)
        XCTAssertEqual(s.next(CGPoint(x: 60, y: 822), shown: home, now: 0.09).accept, false)
        XCTAssertTrue(s.next(CGPoint(x: 60, y: 822), shown: home, now: 0.18).accept)
    }

    func testNothingShownYetIsAccepted() {
        var s = CmsFeatureSteadiness()
        XCTAssertTrue(s.next(home, shown: nil, now: 0).accept)
    }
}
