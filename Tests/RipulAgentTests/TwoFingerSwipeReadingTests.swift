import CoreGraphics
import XCTest
@testable import RipulAgent

/// How the screens' two-finger swipe reads a pair of fingers: up opens the
/// overview, sideways slides between screens, and a pinch or a swipe down is
/// left to whatever else wants it.
final class TwoFingerSwipeReadingTests: XCTestCase {
    private let left = CGPoint(x: 100, y: 500)
    private let right = CGPoint(x: 160, y: 500)

    private func read(_ dx: CGFloat, _ dy: CGFloat) -> TwoFingerSwipeReading {
        TwoFingerSwipeReading.read(
            from: (left, right),
            to: (CGPoint(x: left.x + dx, y: left.y + dy), CGPoint(x: right.x + dx, y: right.y + dy)))
    }

    func testUpAndSidewaysAreSwipesAndDownIsLeftToTheScroll() {
        XCTAssertEqual(read(0, -12), .up)
        XCTAssertEqual(read(12, 2), .sideways)
        XCTAssertEqual(read(-12, -3), .sideways)
        XCTAssertEqual(read(1, 12), .declined(.down))
    }

    func testNothingIsDecidedBeforeThePairHasTravelledThePullsDistance() {
        XCTAssertEqual(read(0, -7), .undecided)
        XCTAssertEqual(read(5, -5), .undecided)
        // As the pull does, a perfect diagonal counts as sideways.
        XCTAssertEqual(read(6, -6), .sideways)
    }

    func testFingersMovingApartOrTogetherArePinches() {
        // Both fingers apart, the point between them still.
        XCTAssertEqual(TwoFingerSwipeReading.read(
            from: (left, right), to: (CGPoint(x: 90, y: 500), CGPoint(x: 170, y: 500))), .declined(.pinch))
        // One finger held, the other moving away: the point between them
        // travels half as far as the gap grows.
        XCTAssertEqual(TwoFingerSwipeReading.read(
            from: (left, right), to: (left, CGPoint(x: 174, y: 500))), .declined(.pinch))
        // Drifting a little closer while swiping up is still a swipe.
        XCTAssertEqual(TwoFingerSwipeReading.read(
            from: (left, right), to: (CGPoint(x: 103, y: 480), CGPoint(x: 157, y: 480))), .up)
    }

    func testTurningInPlaceDecidesNothing() {
        let angle = CGFloat.pi / 6
        let mid = TwoFingerSwipeReading.midpoint(left, right)
        func turned(_ point: CGPoint) -> CGPoint {
            let x = point.x - mid.x, y = point.y - mid.y
            return CGPoint(x: mid.x + x * cos(angle) - y * sin(angle), y: mid.y + x * sin(angle) + y * cos(angle))
        }
        XCTAssertEqual(TwoFingerSwipeReading.read(from: (left, right), to: (turned(left), turned(right))), .undecided)
    }

    func testAReleaseProjectsInProportionToItsSpeed() {
        XCTAssertEqual(TwoFingerSwipeReading.projection(velocity: 0), 0)
        XCTAssertEqual(TwoFingerSwipeReading.projection(velocity: -1200),
                       -1200 * TwoFingerSwipeReading.projectionFactor, accuracy: 0.001)
    }
}
