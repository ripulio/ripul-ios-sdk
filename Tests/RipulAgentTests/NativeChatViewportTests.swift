import XCTest
@testable import RipulAgent

/// The one viewport owner's rules (docs/plans/native-chat-viewport-owner.md): history
/// above the reader moves nothing on screen, only tail growth and clearance glide, a
/// glide in flight survives history, a layout is consumed once.
final class NativeChatViewportTests: XCTestCase {
    /// Rows stacked 10 pt apart from the top of the content, as the list lays them out.
    private func geometry(_ rows: [(String, CGFloat)], viewport: CGFloat = 800,
                          topInset: CGFloat = 0, bottomInset: CGFloat = 170) -> NativeChatViewport.Geometry {
        var g = NativeChatViewport.Geometry()
        var y: CGFloat = 0
        for (id, height) in rows {
            g.order.append(id)
            g.tops[id] = y
            y += height + 10
        }
        g.contentHeight = max(0, y - 10)
        g.viewportHeight = viewport
        g.topInset = topInset
        g.bottomInset = bottomInset
        return g
    }

    private func chat(_ count: Int) -> [(String, CGFloat)] {
        (0..<count).map { ("m\($0)", CGFloat(60 + ($0 * 37) % 140)) }
    }

    /// Peter's Duo, 8 Nov 2026: seven 430 pt screenshot cards landed above a 29-row chat
    /// following its end. Each must move the offset by exactly 430 and glide nothing.
    func testHistoryAboveAFollowingChatMovesNothingOnScreen() {
        var rows = chat(29)
        var model = NativeChatViewport()
        model.follow()
        var offset = model.commit(geometry(rows), liveOffset: 0, now: 10)
        XCTAssertEqual(offset, geometry(rows).end)
        for card in 0..<7 {
            rows.insert(("card\(card)", 420), at: 6 + card)
            let next = geometry(rows)
            let lastRowScreenBefore = (model.geometry?.tops["m28"] ?? 0) - offset
            offset = model.commit(next, liveOffset: offset, now: 10)
            XCTAssertEqual(offset, next.end, "card \(card) left the chat off its end")
            XCTAssertEqual((next.tops["m28"] ?? 0) - offset, lastRowScreenBefore, accuracy: 0.001,
                           "card \(card) moved the last row on screen")
            XCTAssertNil(model.advance(by: 1 / 60, now: 10), "card \(card) started a glide")
        }
    }

    /// A glide in flight keeps its distance through history above: neither consumed nor doubled.
    func testHistoryAboveKeepsAGlideInFlight() {
        var rows = chat(20)
        var model = NativeChatViewport()
        model.follow()
        var offset = model.commit(geometry(rows), liveOffset: 0, now: 10)
        rows.append(("reply", 100))   // the tail grows: 110 pt to glide
        offset = model.commit(geometry(rows), liveOffset: offset, now: 10)
        XCTAssertEqual(model.lag, 110, accuracy: 0.001)
        rows.insert(("card", 420), at: 3)
        let next = geometry(rows)
        let before = offset
        offset = model.commit(next, liveOffset: offset, now: 10)
        XCTAssertEqual(offset - before, 430, accuracy: 0.001, "history above must rebase by its translation")
        XCTAssertEqual(model.lag, 110, accuracy: 0.001, "the glide's distance must survive history above")
    }

    /// Growth at the tail glides in, and the glide arrives without passing the end.
    func testTailGrowthGlidesToTheEnd() {
        var rows = chat(20)
        var model = NativeChatViewport()
        model.follow()
        let start = model.commit(geometry(rows), liveOffset: 0, now: 10)
        rows[rows.count - 1].1 += 200   // a streaming reply grows
        let next = geometry(rows)
        XCTAssertEqual(model.commit(next, liveOffset: start, now: 10), start, "tail growth must not jump")
        var steps = 0
        var last = start
        while let step = model.advance(by: 1 / 60, now: 10) {
            XCTAssertGreaterThanOrEqual(step, last)
            XCTAssertLessThanOrEqual(step, next.end + 0.001)
            last = step
            steps += 1
            XCTAssertLessThan(steps, 120, "the glide never arrived")
        }
        XCTAssertEqual(last, next.end, accuracy: 0.5)
    }

    /// Codex's counterexample: history grows above (+40) as the composer's clearance drops
    /// 300. The rows hold still at once; the chat comes down with the clearance on the stiff spring.
    func testHistoryAboveWhileTheClearanceDrops() {
        var rows = chat(20)
        var model = NativeChatViewport()
        model.follow()
        let start = model.commit(geometry(rows, bottomInset: 470), liveOffset: 0, now: 10)
        rows[2].1 += 40
        let next = geometry(rows, bottomInset: 170)
        model.clearanceMoving(now: 10)
        let offset = model.commit(next, liveOffset: start, now: 10)
        XCTAssertEqual(offset - start, 40, accuracy: 0.001, "the rows must not move in this commit")
        XCTAssertEqual(model.lag, -300 + 0, accuracy: 0.001)
        var last = offset
        var steps = 0
        while let step = model.advance(by: 1 / 60, now: 10.01) {
            XCTAssertLessThanOrEqual(step, last + 0.001, "coming down, the glide must not go back up")
            last = step
            steps += 1
            XCTAssertLessThan(steps, 60)
        }
        XCTAssertEqual(last, next.end, accuracy: 0.5)
    }

    /// Reading, a row stays where it is on screen whatever changes above it.
    func testReadingHoldsItsRow() {
        var rows = chat(40)
        var model = NativeChatViewport()
        let g = geometry(rows)
        _ = model.commit(g, liveOffset: 0, now: 10)
        model.read(rowID: "m20", screenOffset: 120)
        rows[3].1 += 250
        rows.insert(("older", 90), at: 0)
        let next = geometry(rows)
        let offset = model.commit(next, liveOffset: (g.tops["m20"] ?? 0) - 120, now: 10)
        XCTAssertEqual((next.tops["m20"] ?? 0) - offset, 120, accuracy: 0.001)
        XCTAssertNil(model.advance(by: 1 / 60, now: 10), "reading never glides")
    }

    /// The row being read went: the nearest row that stayed holds its place instead.
    func testReadingRowRemovedHoldsTheNearestSurvivor() {
        var rows = chat(30)
        var model = NativeChatViewport()
        let g = geometry(rows)
        _ = model.commit(g, liveOffset: 0, now: 10)
        let live = (g.tops["m15"] ?? 0) - 50
        model.read(rowID: "m15", screenOffset: 50)
        let survivorScreen = (g.tops["m14"] ?? 0) - live
        rows.removeAll { $0.0 == "m15" }
        let next = geometry(rows)
        let offset = model.commit(next, liveOffset: live, now: 10)
        XCTAssertEqual((next.tops["m14"] ?? 0) - offset, survivorScreen, accuracy: 0.001)
    }

    /// Entering, the chat is at its end on every commit, without a glide, until the hold ends.
    func testEnteringSitsAtTheEnd() {
        var rows = chat(10)
        var model = NativeChatViewport()
        model.enter(now: 10)
        var offset = model.commit(geometry(rows), liveOffset: 0, now: 10)
        for _ in 0..<3 {
            rows.append(("more\(rows.count)", 300))
            let next = geometry(rows)
            offset = model.commit(next, liveOffset: offset, now: 11)
            XCTAssertEqual(offset, next.end)
            XCTAssertNil(model.advance(by: 1 / 60, now: 11))
        }
        rows.append(("after", 200))
        _ = model.commit(geometry(rows), liveOffset: offset, now: 14)
        XCTAssertEqual(model.intent, .following)
        XCTAssertNotNil(model.advance(by: 1 / 60, now: 14), "after the hold, tail growth glides")
    }

    /// The same layout committed twice is consumed once.
    func testTheSameLayoutIsConsumedOnce() {
        var rows = chat(20)
        var model = NativeChatViewport()
        model.follow()
        var offset = model.commit(geometry(rows), liveOffset: 0, now: 10)
        rows.insert(("card", 420), at: 2)
        let next = geometry(rows)
        offset = model.commit(next, liveOffset: offset, now: 10)
        XCTAssertEqual(model.commit(next, liveOffset: offset, now: 10), offset, "a repeated commit moved the chat")
    }

    /// A jump or a row to hold is placed by the next commit, though the layout is the same.
    func testAnIntentIsPlacedOnTheSameLayout() {
        let rows = chat(40)
        var model = NativeChatViewport()
        let g = geometry(rows)
        var offset = model.commit(g, liveOffset: 0, now: 10)
        model.read(rowID: "m10", screenOffset: 200)
        offset = model.commit(g, liveOffset: offset, now: 10)
        XCTAssertEqual((g.tops["m10"] ?? 0) - offset, 200, accuracy: 0.001, "the row to hold was not placed")
        model.follow(instantly: true)
        offset = model.commit(g, liveOffset: offset, now: 10)
        XCTAssertEqual(offset, g.end, "the jump to the end was not placed")
        XCTAssertNil(model.advance(by: 1 / 60, now: 10))
        XCTAssertEqual(model.commit(g, liveOffset: offset, now: 10), offset, "the jump was placed twice")
    }

    /// Under a finger, the first row on screen holds still through a layout change.
    func testManualKeepsTheFirstRowOnScreenStill() {
        var rows = chat(40)
        var model = NativeChatViewport()
        let g = geometry(rows)
        _ = model.commit(g, liveOffset: 0, now: 10)
        model.beginManual()
        let live = (g.tops["m12"] ?? 0) + 5
        model.noteManualOffset(live)
        let first = g.firstVisible(at: live)
        rows.insert(("card", 420), at: 1)
        let next = geometry(rows)
        let offset = model.commit(next, liveOffset: live, now: 10)
        XCTAssertEqual((next.tops[first?.id ?? ""] ?? 0) - offset, (first?.top ?? 0) - live, accuracy: 0.001)
    }

    /// When the finger and coast are done: near the end follows, elsewhere reads.
    func testSettleFollowsNearTheEndAndReadsElsewhere() {
        let rows = chat(40)
        var model = NativeChatViewport()
        let g = geometry(rows)
        _ = model.commit(g, liveOffset: 0, now: 10)
        model.beginManual()
        model.noteManualOffset(g.end - 20)
        model.settle()
        XCTAssertEqual(model.intent, .following)
        model.beginManual()
        model.noteManualOffset(400)
        model.settle()
        guard case .reading = model.intent else { return XCTFail("expected reading, got \(model.intent)") }
    }
}
