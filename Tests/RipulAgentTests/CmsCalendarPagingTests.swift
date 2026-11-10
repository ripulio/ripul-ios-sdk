import XCTest
import Combine
@testable import RipulAgent

/// The Calendar Strip's paging rules (CmsCalendarPaging): which week or month
/// each of the pager's three pages shows, what a scroll at rest means, and the
/// rotation that keeps the page on screen in its own view.
final class CmsCalendarPagingTests: XCTestCase {
    typealias P = CmsCalendarPaging

    private let cal: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        return cal
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    func testThreePagesAreTheMonthBeforeTheMonthAndTheMonthAfter() {
        let anchor = date(2026, 10, 30)
        let keys = (-1...1).map { P.pageKey(P.pageDate(anchor, offset: $0, months: true, calendar: cal), months: true, calendar: cal) }
        XCTAssertEqual(keys, ["m2026-9", "m2026-10", "m2026-11"])
        // Across a year.
        let january = date(2027, 1, 31)
        XCTAssertEqual(P.pageKey(P.pageDate(january, offset: -1, months: true, calendar: cal), months: true, calendar: cal), "m2026-12")
    }

    func testThreePagesAreTheWeekBeforeTheWeekAndTheWeekAfter() {
        let anchor = date(2026, 10, 30)
        let dates = (-1...1).map { P.pageDate(anchor, offset: $0, months: false, calendar: cal) }
        XCTAssertEqual(dates.map { cal.component(.day, from: $0) }, [23, 30, 6])
        let keys = dates.map { P.pageKey($0, months: false, calendar: cal) }
        XCTAssertEqual(Set(keys).count, 3)
        // Every day of a week has its week's key (Monday to Sunday here).
        XCTAssertEqual(P.pageKey(date(2026, 10, 26), months: false, calendar: cal), keys[1])
        XCTAssertEqual(P.pageKey(date(2026, 11, 1), months: false, calendar: cal), keys[1])
        XCTAssertNotEqual(P.pageKey(date(2026, 11, 2), months: false, calendar: cal), keys[1])
    }

    func testOffsetZeroIsTheAnchorItself() {
        let anchor = date(2026, 10, 30)
        XCTAssertEqual(P.pageDate(anchor, offset: 0, months: true, calendar: cal), anchor)
    }

    func testTheStepOfAScrollAtRest() {
        let w: CGFloat = 378
        XCTAssertEqual(P.settledStep(offsetX: w, width: w), 0)
        XCTAssertEqual(P.settledStep(offsetX: 0, width: w), -1)
        XCTAssertEqual(P.settledStep(offsetX: 2 * w, width: w), 1)
        // Paging rests on a page; a fraction rounds to the nearest and never past a neighbour.
        XCTAssertEqual(P.settledStep(offsetX: 1.6 * w, width: w), 1)
        XCTAssertEqual(P.settledStep(offsetX: 0.4 * w, width: w), -1)
        XCTAssertEqual(P.settledStep(offsetX: 3 * w, width: w), 1)
        XCTAssertEqual(P.settledStep(offsetX: -w, width: w), -1)
        // No width yet: nothing happened.
        XCTAssertEqual(P.settledStep(offsetX: 100, width: 0), 0)
        XCTAssertEqual(P.settledStep(offsetX: .nan, width: w), 0)
    }

    func testTheHeightFollowsTheScrollTowardsANeighbourOfOtherRows() {
        let step: CGFloat = 44
        // October (5) shown, September (5) before, November (6) after.
        let rows = [5, 5, 6]
        XCTAssertEqual(P.growth(progress: 0, rows: rows, rowStep: step), 0)
        XCTAssertEqual(P.growth(progress: 0.5, rows: rows, rowStep: step), 22)
        XCTAssertEqual(P.growth(progress: 1, rows: rows, rowStep: step), 44)
        // Towards September: as many rows, no change.
        XCTAssertEqual(P.growth(progress: -0.7, rows: rows, rowStep: step), 0)
        // February 2027 (4) shown: towards March (5) a row, back from it none.
        XCTAssertEqual(P.growth(progress: 0.25, rows: [5, 4, 5], rowStep: step), 11)
        XCTAssertEqual(P.growth(progress: -0.25, rows: [5, 4, 5], rowStep: step), 11)
        // November (6) shown, towards October (5): shrinks.
        XCTAssertEqual(P.growth(progress: -0.5, rows: [5, 6, 5], rowStep: step), -22)
        // A rubber band past the neighbour stops at its height; nothing measured, nothing grows.
        XCTAssertEqual(P.growth(progress: 1.4, rows: rows, rowStep: step), 44)
        XCTAssertEqual(P.growth(progress: 0.5, rows: rows, rowStep: 0), 0)
        XCTAssertEqual(P.growth(progress: .nan, rows: rows, rowStep: step), 0)
        // Weeks: one row each, never grows.
        XCTAssertEqual(P.growth(progress: 0.8, rows: [1, 1, 1], rowStep: step), 0)
    }

    func testGrowthPublishesWholePixels() {
        let growth = CmsCalendarGrowth()
        var published = 0
        let watch = growth.objectWillChange.sink { published += 1 }
        growth.follow(0.1, scale: 3)
        XCTAssertEqual(growth.extra, 0)
        XCTAssertEqual(published, 0)
        growth.follow(0.2, scale: 3)
        XCTAssertEqual(growth.extra, 1.0 / 3, accuracy: 0.0001)
        growth.follow(0.3, scale: 3)
        XCTAssertEqual(published, 1)
        growth.follow(0, scale: 3)
        XCTAssertEqual(growth.extra, 0)
        XCTAssertEqual(published, 2)
        watch.cancel()
    }

    func testRotationKeepsThePageShownInItsOwnView() {
        let hosts = ["before", "shown", "after"]
        // Swiped on to the page after: that view moves to the middle, keeping what it
        // draws, and the old page before comes round to be drawn as the new page after.
        XCTAssertEqual(P.rotated(hosts, step: 1), ["shown", "after", "before"])
        XCTAssertEqual(P.rotated(hosts, step: -1), ["after", "before", "shown"])
        XCTAssertEqual(P.rotated(hosts, step: 0), hosts)
        for step in [-1, 1] {
            XCTAssertEqual(P.rotated(hosts, step: step)[1], hosts[1 + step])
        }
    }
}
