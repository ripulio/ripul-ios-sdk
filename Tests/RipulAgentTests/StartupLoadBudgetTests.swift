import XCTest
@testable import RipulAgent

final class StartupLoadBudgetTests: XCTestCase {
    func testColdDownloadCanExceedOldFifteenSecondDeadline() {
        var budget = StartupLoadBudget()
        for _ in 0..<5 {
            budget.advance(by: 20)
            XCTAssertNil(budget.failure)
            budget.madeProgress()
        }
        XCTAssertEqual(budget.elapsed, 100)
        budget.advance(by: 29)
        XCTAssertEqual(budget.failure, .overallLimit)
    }

    func testStallIsMeasuredFromLastProgress() {
        var budget = StartupLoadBudget()
        budget.advance(by: 25)
        budget.madeProgress()
        budget.advance(by: 29)
        XCTAssertNil(budget.failure)
        budget.advance(by: 1)
        XCTAssertEqual(budget.failure, .stalled)
    }

    func testContinuousActivityCannotExtendOverallCap() {
        var budget = StartupLoadBudget()
        for _ in 0..<119 {
            budget.advance(by: 1)
            budget.madeProgress()
            XCTAssertNil(budget.failure)
        }
        budget.advance(by: 1)
        budget.madeProgress()
        XCTAssertEqual(budget.failure, .overallLimit)
    }

    func testRepeatedOrOscillatingAuthStateDoesNotCountAsProgress() {
        var budget = StartupLoadBudget()
        budget.reachedMilestone("Signing in")
        budget.advance(by: 20)
        budget.reachedMilestone("Session found")
        budget.advance(by: 20)
        budget.reachedMilestone("Signing in")
        budget.reachedMilestone("Session found")
        budget.advance(by: 10)
        XCTAssertEqual(budget.failure, .stalled)
    }

    func testBackgroundSuspensionPreservesRemainingAllowance() {
        var budget = StartupLoadBudget()
        budget.sample(at: 0, isActive: true)
        budget.sample(at: 20, isActive: false)
        budget.sample(at: 3620, isActive: true)
        budget.sample(at: 3629, isActive: true)
        XCTAssertEqual(budget.elapsed, 29)
        XCTAssertNil(budget.failure)
        budget.sample(at: 3630, isActive: true)
        XCTAssertEqual(budget.failure, .stalled)
    }

    func testForegroundMainThreadDelayStillCounts() {
        var budget = StartupLoadBudget()
        budget.sample(at: 0, isActive: true)
        budget.sample(at: 31, isActive: true)
        XCTAssertEqual(budget.failure, .stalled)
    }

    func testRetryStartsWithFreshIdleAndOverallBudgets() {
        var budget = StartupLoadBudget()
        budget.advance(by: 120)
        XCTAssertEqual(budget.failure, .overallLimit)
        budget = StartupLoadBudget()
        budget.advance(by: 29)
        XCTAssertNil(budget.failure)
        XCTAssertEqual(budget.elapsed, 29)
    }
}
