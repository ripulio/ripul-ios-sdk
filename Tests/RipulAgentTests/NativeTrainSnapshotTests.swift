import XCTest
@testable import RipulAgent

final class NativeTrainSnapshotTests: XCTestCase {
  func testDecodesAMovingTrain() throws {
    let train = try NativeTrainSnapshot.decode([
      "id": "train_7", "track": "web", "title": "web train", "detail": "Running the job",
      "state": "running", "since": 1_791_553_266_000.0, "elapsedMs": NSNull(), "stepsDone": 1, "stepsTotal": 3,
    ])
    XCTAssertEqual(train.state, .running)
    XCTAssertTrue(train.isLive)
    XCTAssertEqual(train.since, Date(timeIntervalSince1970: 1_791_553_266))
    XCTAssertNil(train.elapsed)
    XCTAssertEqual([train.stepsDone, train.stepsTotal], [1, 3])
  }

  func testAFinishedTrainHasNoClockAndKeepsItsDuration() throws {
    let train = try NativeTrainSnapshot.decode([
      "id": "train_7", "title": "web train", "detail": "Arrived", "state": "done",
      "since": NSNull(), "elapsedMs": 63_000, "stepsDone": 3, "stepsTotal": 3,
    ])
    XCTAssertFalse(train.isLive)
    XCTAssertNil(train.since)
    XCTAssertEqual(train.elapsed, 63)
  }

  func testRefusesWhatItCannotDraw() {
    XCTAssertThrowsError(try NativeTrainSnapshot.decode(["id": "t", "title": "web train", "detail": "x", "state": "flying"]))
    XCTAssertThrowsError(try NativeTrainSnapshot.decode(["id": "t", "title": "", "detail": "x", "state": "running"]))
  }

  func testStepCountsAreBounded() throws {
    let train = try NativeTrainSnapshot.decode([
      "id": "t", "title": "web train", "detail": "x", "state": "running", "stepsDone": 99, "stepsTotal": 400,
    ])
    XCTAssertEqual([train.stepsDone, train.stepsTotal], [12, 12])
  }

  func testOpensOnlyWhenItKnowsWhichTrainOnWhichMac() throws {
    var value: [String: Any] = ["id": "req_2", "title": "web train", "detail": "x", "state": "waiting", "projectId": "p", "trainId": "train_1"]
    XCTAssertNil(try NativeTrainSnapshot.decode(value).openTarget)
    value["machineId"] = "mac"
    XCTAssertEqual(try NativeTrainSnapshot.decode(value).openTarget, ["machineId": "mac", "projectId": "p", "trainId": "train_1"])
    value["trainId"] = NSNull()
    XCTAssertNil(try NativeTrainSnapshot.decode(value).openTarget)
  }

  func testElapsedMatchesTheWebRow() {
    XCTAssertEqual(NativeTrainSnapshot.elapsedText(65), "1:05")
    XCTAssertEqual(NativeTrainSnapshot.elapsedText(3727), "1:02:07")
  }
}
