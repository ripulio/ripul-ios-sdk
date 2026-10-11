import XCTest
@testable import RipulAgent

final class NativeTaskRunSnapshotTests: XCTestCase {
  func testDecodesARunUnderWay() throws {
    let run = try NativeTaskRunSnapshot.decode([
      "id": "cli_stream_toolcall_toolu_1", "title": "Three readers then one joiner",
      "detail": "Phase 1 of 2: Read · 1 of 3 agents done", "state": "running", "since": 1_791_571_300_000.0,
      "marks": ["done", "running", "running"],
      "live": [["id": "2", "label": "read-b", "detail": "Read …/b.txt"], ["id": "3", "label": "read-c", "detail": "Read …/c.txt"]],
      "more": NSNull(),
    ])
    XCTAssertEqual(run.state, .running)
    XCTAssertEqual(run.since, Date(timeIntervalSince1970: 1_791_571_300))
    XCTAssertEqual(run.marks, [.done, .running, .running])
    XCTAssertEqual(run.live.map(\.label), ["read-b", "read-c"])
    XCTAssertNil(run.more)
    XCTAssertTrue(run.showsMarks)
  }

  func testAFinishedRunHasNoClockAndNoBar() throws {
    let run = try NativeTaskRunSnapshot.decode([
      "id": "c", "title": "Count lines", "detail": "Completed · 4 agents · 126,309 tokens · 38s", "state": "done",
      // A clock left on a finished run by mistake is not drawn.
      "since": 1_791_571_300_000.0, "marks": ["done", "done", "done", "done"], "live": [], "more": NSNull(),
    ])
    XCTAssertNil(run.since)
    XCTAssertFalse(run.showsMarks)
  }

  func testAFinishedRunKeepsItsBarWhenNotEveryAgentFinished() throws {
    let run = try NativeTaskRunSnapshot.decode([
      "id": "c", "title": "Audit", "detail": "Stopped · 1 of 3 agents done", "state": "stopped", "marks": ["done", "stopped", "stopped"],
    ])
    XCTAssertTrue(run.showsMarks)
  }

  func testRefusesWhatItCannotDraw() {
    XCTAssertThrowsError(try NativeTaskRunSnapshot.decode(["id": "c", "title": "Audit", "detail": "x", "state": "flying"]))
    XCTAssertThrowsError(try NativeTaskRunSnapshot.decode(["id": "c", "title": "", "detail": "x", "state": "running"]))
    XCTAssertThrowsError(try NativeTaskRunSnapshot.decode(["id": "c", "title": "Audit", "state": "running"]))
  }

  func testDecodesASubAgentAtWork() throws {
    let run = try NativeTaskRunSnapshot.decode([
      "id": "cli_stream_toolcall_toolu_1", "kind": "agent", "title": "Find the train row",
      "detail": "Explore · 13,110 tokens · 2 tool uses", "state": "running", "since": 1_791_571_300_000.0, "marks": [],
      "live": [
        ["id": "3", "label": "Read", "detail": "…/chatTrains.ts"],
        // A tool used on nothing in particular, and a line the agent said.
        ["id": "2", "label": "Bash", "detail": ""],
        ["id": "1", "label": "", "detail": "I will look for the renderer first."],
      ],
      "more": NSNull(),
    ])
    XCTAssertFalse(run.showsMarks)
    XCTAssertEqual(run.live.map(\.id), ["3", "2", "1"])
    XCTAssertEqual(run.live.map(\.label), ["Read", "Bash", ""])
    XCTAssertEqual(run.live.map(\.detail), ["…/chatTrains.ts", "", "I will look for the renderer first."])
  }

  func testALineWithNothingToShowIsDropped() throws {
    let run = try NativeTaskRunSnapshot.decode([
      "id": "c", "title": "Find", "detail": "Explore · Working", "state": "running",
      "live": [["id": "1", "label": "", "detail": ""], ["id": "2", "label": "Grep", "detail": "foo"]],
    ])
    XCTAssertEqual(run.live.map(\.id), ["2"])
  }

  func testEachKindNamesItsOwnRow() {
    XCTAssertEqual(NativeTaskRunSnapshot.Kind.workflow.identifier, "NativeWorkflowRun")
    XCTAssertEqual(NativeTaskRunSnapshot.Kind.agent.identifier, "NativeAgentRun")
    XCTAssertNotEqual(NativeTaskRunSnapshot.Kind.workflow.runningSymbol, NativeTaskRunSnapshot.Kind.agent.runningSymbol)
  }

  func testWhatItDrawsIsBounded() throws {
    let run = try NativeTaskRunSnapshot.decode([
      "id": "c", "title": String(repeating: "t", count: 900), "detail": "x", "state": "running",
      "marks": Array(repeating: "done", count: 400) + ["unheard-of"],
      "live": (0..<9).map { ["id": "\($0)", "label": "agent", "detail": "Working"] } + [["id": "x"]],
      "more": "6 more working",
    ])
    XCTAssertEqual(run.title.count, 300)
    XCTAssertEqual(run.marks.count, NativeTaskRunSnapshot.maxMarks)
    XCTAssertEqual(run.live.count, NativeTaskRunSnapshot.maxLines)
    XCTAssertEqual(run.more, "6 more working")
  }
}
