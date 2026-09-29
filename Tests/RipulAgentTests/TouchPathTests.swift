import CoreGraphics
import XCTest
@testable import RipulAgent

final class TouchPathTests: XCTestCase {
    func testMovesEndAtTheLiftPointAndExcludeTheStart() {
        let moves = TouchPath.moves(from: CGPoint(x: 0, y: 100), to: CGPoint(x: 0, y: 0), steps: 4)
        XCTAssertEqual(moves, [CGPoint(x: 0, y: 75), CGPoint(x: 0, y: 50), CGPoint(x: 0, y: 25), CGPoint(x: 0, y: 0)])
    }

    func testStepsAreAboutSixtyPerSecondWithAFloor() {
        XCTAssertEqual(TouchPath.steps(for: 0.25), 15)
        XCTAssertEqual(TouchPath.steps(for: 1), 60)
        XCTAssertEqual(TouchPath.steps(for: 0), 2)
        XCTAssertEqual(TouchPath.moves(from: .zero, to: CGPoint(x: 10, y: 0), steps: 0), [CGPoint(x: 10, y: 0)])
    }
}

final class ScreenFrameIDTests: XCTestCase {
    func testSameBytesSameIdDifferentBytesDifferentId() {
        let a = ScreenFrameID.of(Data([1, 2, 3]))
        XCTAssertEqual(a, ScreenFrameID.of(Data([1, 2, 3])))
        XCTAssertNotEqual(a, ScreenFrameID.of(Data([1, 2, 4])))
        XCTAssertEqual(ScreenFrameID.of(Data()), "cbf29ce484222325")
    }
}

final class LiveViewIdentityTests: XCTestCase {
    func testModelNames() {
        XCTAssertEqual(RipulLiveViewIdentity.name(forModel: "iPhone16,2"), "iPhone 15 Pro Max")
        XCTAssertEqual(RipulLiveViewIdentity.name(forModel: "iPhone18,5"), "iPhone 17e")
        XCTAssertEqual(RipulLiveViewIdentity.name(forModel: "iPhone18,2"), "iPhone 17 Pro Max")
        XCTAssertEqual(RipulLiveViewIdentity.name(forModel: "iPhone99,9"), "iPhone")
        XCTAssertEqual(RipulLiveViewIdentity.name(forModel: "iPad16,3"), "iPad")
    }
}
