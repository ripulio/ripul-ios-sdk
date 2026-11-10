import XCTest
@testable import RipulAgent

final class NativeChatWindowModelTests: XCTestCase {
    func testResizeEstimateReplacementRemovesOldMountedIndex() {
        var subject = model([100])
        subject.measure(777, for: subject.key(for: subject.descriptors[0]))
        let originalLayout = subject.layout
        subject.changeLayoutPreservingEstimates(.init(width: 600))
        subject.changeLayoutPreservingEstimates(originalLayout)
        subject.update([.init(id: "r0", revision: 2, kind: "message", estimate: 42)])
        XCTAssertEqual(subject.heights, [42], "Resize replaced the old measurement with an estimate; the index must agree")
    }

    func testEvictedMeasurementDoesNotSurviveInSecondaryIndex() {
        var subject = model([100], configuration: .init(cacheLimit: 2))
        let original = subject.descriptors[0]
        subject.measure(777, for: subject.key(for: original))
        // Measuring rebuilds the ledger and touches the mounted cache entry.
        // Eviction must still recognize and remove its secondary-index copy.
        for i in 1...4 {
            subject.update([.init(id: "other-\(i)", revision: 1, kind: "other", estimate: 50)])
        }
        XCTAssertNil(subject.cache[subject.key(for: original)])
        subject.update([.init(id: "r0", revision: 2, kind: "new-kind", estimate: 42)])
        XCTAssertEqual(subject.heights, [42], "An evicted measurement must not remain an estimate forever")
    }

    private func model(_ heights: [CGFloat], configuration: NativeChatWindowModel.Configuration = .init()) -> NativeChatWindowModel {
        var model = NativeChatWindowModel(layout: .init(width: 320), configuration: configuration)
        model.update(heights.enumerated().map { .init(id: "r\($0.offset)", revision: 1, kind: "message", estimate: $0.element) })
        return model
    }

    func testEveryBandMatchesEagerGeometryIncludingChrome() {
        for count in 1...24 {
            let heights = (0..<count).map { CGFloat(($0 * 37) % 121) + 0.5 }
            let subject = model(heights)
            for a in 0..<count {
                for b in (a + 1)...count {
                    let plan = subject.geometry(for: a..<b)
                    let mounted = heights[a..<b].reduce(0, +) + CGFloat(b - a - 1) * 10
                    let reference = heights.reduce(0, +) + CGFloat(count - 1) * 10
                    XCTAssertEqual(plan.top + mounted + plan.bottom, reference, accuracy: 0.0001)
                    XCTAssertEqual(plan.top, heights[..<a].reduce(0, +) + CGFloat(a) * 10, accuracy: 0.0001)
                    // Outer stack has one row section, optional chrome, and bottom anchor.
                    for top in [CGFloat(0), 48] {
                        for banner in [CGFloat(0), 36] {
                            for bottom in [CGFloat(0), 88] {
                                let chrome = [top, banner, bottom].filter { $0 > 0 }
                                let actual = 24 + chrome.reduce(0, +) + plan.totalHeight + 1 + CGFloat(chrome.count + 1) * 10
                                let eager = 24 + chrome.reduce(0, +) + heights.reduce(0, +) + 1 + CGFloat(chrome.count + count) * 10
                                XCTAssertEqual(actual, eager, accuracy: 0.0001)
                            }
                        }
                    }
                }
            }
        }
    }

    func testEmptyAndStrictThresholds() {
        XCTAssertEqual(model([]).plan(viewport: 0..<100).totalHeight, 0)
        let subject = model([20, 30, 40])
        XCTAssertEqual(subject.firstRow(after: 19), 0)
        XCTAssertEqual(subject.firstRow(after: 20), 1)
        XCTAssertEqual(subject.firstRow(after: 60), 2)
        XCTAssertEqual(subject.firstRow(after: 110), 3)
    }

    func testRevisionsAreEqualityBasedAndSurviveReordering() {
        var tracker = NativeChatRowRevisionTracker<String>()
        let first = tracker.revisions(for: [("a", "one"), ("b", "two")])
        XCTAssertEqual(tracker.revisions(for: [("b", "two"), ("a", "one")]), Array(first.reversed()))
        let changed = tracker.revisions(for: [("a", "changed"), ("b", "two")])
        XCTAssertNotEqual(first[0], changed[0])
        XCTAssertEqual(first[1], changed[1])
    }

    func testCacheKeysRejectStaleMeasurementsAndBoundEviction() {
        var configuration = NativeChatWindowModel.Configuration()
        configuration.cacheLimit = 3
        var subject = model([20, 30], configuration: configuration)
        let key = subject.key(for: subject.descriptors[0])
        XCTAssertTrue(subject.measure(44, for: key))
        XCTAssertEqual(subject.cache[key]?.confidence, .mounted)
        XCTAssertEqual(subject.heights[0], 44)
        XCTAssertFalse(subject.measure(.nan, for: key))
        XCTAssertFalse(subject.measure(-1, for: key))
        subject.update([.init(id: "r0", revision: 2, kind: "message", estimate: 20)])
        XCTAssertFalse(subject.measure(50, for: key))
        subject.update(subject.descriptors, layout: .init(width: 640, textMetrics: "large"))
        XCTAssertFalse(subject.measure(50, for: key))
        for revision in 3...20 {
            subject.update([.init(id: "r0", revision: UInt64(revision), kind: "message", estimate: 20)])
            XCTAssertLessThanOrEqual(subject.cache.count, 3)
        }
    }

    func testMedianEstimatesAndFallback() {
        var subject = model([100, 100, 100])
        XCTAssertTrue(subject.measure(40, for: subject.key(for: subject.descriptors[0])))
        XCTAssertTrue(subject.measure(80, for: subject.key(for: subject.descriptors[1])))
        XCTAssertEqual(subject.heights[2], 100, "Existing estimates must not chase new medians")
        subject.update(subject.descriptors + [.init(id: "new-kind-row", revision: 1, kind: "message", estimate: 100)])
        XCTAssertEqual(subject.heights.last, 80, "Only a new estimate uses the latest median")
        subject.update([.init(id: "unknown", revision: 1, kind: "other", estimate: .infinity)])
        XCTAssertEqual(subject.heights, [100])
    }

    func testHysteresisDirectionCapsAndJump() {
        let subject = model(Array(repeating: 30, count: 600))
        let first = subject.plan(viewport: 8000..<8500)
        let still = subject.plan(viewport: 8010..<8510, current: first)
        XCTAssertEqual(first.range, still.range)
        XCTAssertLessThanOrEqual(first.range.count, 32)
        let fast = subject.plan(viewport: 8000..<8500, direction: .down, fast: true)
        XCTAssertGreaterThanOrEqual(fast.range.upperBound, first.range.upperBound)
        XCTAssertLessThanOrEqual(fast.range.count, 48)
        let target = subject.plan(viewport: 0..<500, current: first, targetID: "r500")
        XCTAssertTrue(target.range.contains(500))
        XCTAssertFalse(target.range.contains(0))
    }

    func testMandatoryRowsOverrideCapAndTallRowsStaySmall() {
        let short = model(Array(repeating: 1, count: 600))
        let plan = short.plan(viewport: 0..<1000)
        XCTAssertTrue(plan.exceedsCap)
        XCTAssertEqual(plan.range, plan.mandatory)
        let tall = model(Array(repeating: 3000, count: 100))
        XCTAssertLessThanOrEqual(tall.plan(viewport: 5000..<5500).range.count, 8)
    }

    func testPrependAndBandMovesKeepLogicalAnchorByID() {
        var subject = model([20, 30, 40])
        let old = subject.prefix[1]
        subject.update([.init(id: "older", revision: 1, kind: "other", estimate: 50)] + subject.descriptors)
        XCTAssertEqual(subject.prefix[2] - old, 60)
        let plan = subject.geometry(for: 2..<3)
        XCTAssertEqual(plan.top, subject.prefix[2])
        let key = subject.key(for: subject.descriptors[0])
        XCTAssertTrue(subject.measure(80, for: key))
        XCTAssertEqual(subject.prefix[2] - plan.top, 30)
        subject.setCorrectionMode(.deferUntilRest)
        XCTAssertEqual(subject.correctionMode, .deferUntilRest)
    }
    func testWidthChangesDoNotReuseMeasuredMedianOrHeight() {
        var subject = model([100, 100])
        let old = subject.key(for: subject.descriptors[0])
        XCTAssertTrue(subject.measure(400, for: old))
        subject.update(subject.descriptors, layout: .init(width: 600))
        XCTAssertEqual(subject.heights, [100, 100])
        XCTAssertFalse(subject.measure(20, for: old))
    }

    func testDeterministicBandCoverageAcrossManyViewports() {
        let subject = model((0..<600).map { CGFloat(($0 * 71) % 211) })
        var current: NativeChatWindowModel.Plan?
        for y in stride(from: CGFloat(-100), to: subject.totalHeight + 100, by: 173) {
            let plan = subject.plan(viewport: y..<(y + 500), current: current, direction: .down, fast: true)
            XCTAssertLessThanOrEqual(plan.range.lowerBound, plan.mandatory.lowerBound)
            XCTAssertGreaterThanOrEqual(plan.range.upperBound, plan.mandatory.upperBound)
            XCTAssertLessThanOrEqual(plan.range.count, max(48, plan.mandatory.count))
            let mounted = subject.heights[plan.range].reduce(0, +) + CGFloat(plan.range.count - 1) * 10
            XCTAssertEqual(plan.top + mounted + plan.bottom, subject.totalHeight, accuracy: 0.0001)
            current = plan
        }
    }

    func testBatchRebuildsOnceAndPreservesHysteresisAfterMeasurement() {
        var subject = model(Array(repeating: 30, count: 600))
        let before = subject.plan(viewport: 8000..<8500)
        let heightGeneration = subject.generation
        let structure = subject.structureGeneration
        let batch = before.range.map { (subject.key(for: subject.descriptors[$0]), CGFloat(30)) }
        XCTAssertEqual(subject.measure(batch), batch.count)
        XCTAssertEqual(subject.generation, heightGeneration + 1)
        XCTAssertEqual(subject.structureGeneration, structure)
        XCTAssertEqual(subject.plan(viewport: 8010..<8510, current: before).range, before.range)
        let unchanged = subject.generation
        XCTAssertEqual(subject.measure(batch), batch.count)
        XCTAssertEqual(subject.generation, unchanged)
        subject.update([.init(id: "new", revision: 1, kind: "message", estimate: 30)] + subject.descriptors)
        XCTAssertNotEqual(subject.structureGeneration, structure)
    }

    func testNewRevisionUsesLastMeasuredHeightBeforeKindMedian() {
        var subject = model([100, 100])
        XCTAssertEqual(subject.measure([(subject.key(for: subject.descriptors[0]), 400),
                                        (subject.key(for: subject.descriptors[1]), 20)]), 2)
        subject.update([.init(id: "r0", revision: 2, kind: "message", estimate: 100)] + Array(subject.descriptors.dropFirst()))
        XCTAssertEqual(subject.heights[0], 400)
        XCTAssertEqual(subject.cache[subject.key(for: subject.descriptors[0])]?.confidence, .estimated)
    }

    func testNoSlotRowsMatchEagerReferenceForEveryBand() {
        for omitted in [[0], [1, 3], [0, 1, 2, 3, 4], [4]] {
            var subject = model([20, 30, 0, 40, 50])
            subject.setNoSlot(omitted.map { subject.key(for: subject.descriptors[$0]) })
            let active = (0..<5).filter { !omitted.contains($0) }
            let total = active.map { subject.heights[$0] }.reduce(0, +) + CGFloat(max(0, active.count - 1)) * 10
            XCTAssertEqual(subject.totalHeight, total)
            for a in 0..<5 {
                for b in (a + 1)...5 {
                    let plan = subject.geometry(for: a..<b)
                    let mounted = active.filter { (a..<b).contains($0) }
                    let height = mounted.map { subject.heights[$0] }.reduce(0, +) + CGFloat(max(0, mounted.count - 1)) * 10
                    XCTAssertEqual(plan.top + height + plan.bottom, total)
                    for index in mounted {
                        let preceding = active.filter { $0 < index }
                        XCTAssertEqual(subject.prefix[index], preceding.map { subject.heights[$0] }.reduce(0, +) + CGFloat(preceding.count) * 10)
                    }
                }
            }
            if let first = active.first { XCTAssertEqual(subject.firstRow(after: -1), first) }
        }
        var subject = model([20, 30])
        XCTAssertTrue(subject.measure(30, for: subject.key(for: subject.descriptors[1])))
        let key = subject.key(for: subject.descriptors[0])
        subject.setNoSlot([key])
        XCTAssertFalse(subject.hasSlot(at: 0))
        XCTAssertTrue(subject.measure(0, for: key)) // A zero-height child still owns spacing.
        XCTAssertTrue(subject.hasSlot(at: 0))
        XCTAssertEqual(subject.totalHeight, 40)
    }

    func testPinnedTargetSurvivesRepeatedLayoutKeysAndNewHeightEstimates() {
        var subject = model(Array(repeating: 100, count: 600))
        var current = subject.plan(viewport: 53000..<53600, targetID: "r535")
        for width: CGFloat in [951, 678, 466, 951] {
            subject.update(subject.descriptors, layout: .init(width: width, textMetrics: "large"))
            let batch = (current.range).map { index in
                (subject.key(for: subject.descriptors[index]), CGFloat(20 + index % 10))
            }
            subject.measure(batch)
            // Old physical offsets can be far from the new ledger. An explicit
            // target, rather than those offsets, must determine the transition band.
            current = subject.plan(viewport: 500..<1100, current: current, targetID: "r535")
            XCTAssertTrue(current.range.contains(535))
            XCTAssertFalse(current.range.contains(20))
        }
    }

    func testNoSlotConfirmationDoesNotSurviveContentOrLayoutChange() {
        var subject = model([20, 30])
        subject.setNoSlot([subject.key(for: subject.descriptors[0])])
        XCTAssertFalse(subject.hasSlot(at: 0))
        subject.update([.init(id: "r0", revision: 2, kind: "message", estimate: 20)] + Array(subject.descriptors.dropFirst()))
        XCTAssertTrue(subject.hasSlot(at: 0))
        subject.setNoSlot([subject.key(for: subject.descriptors[0])])
        subject.update(subject.descriptors, layout: .init(width: 640))
        XCTAssertTrue(subject.hasSlot(at: 0))
    }

    func testMeasurementsDoNotMoveHundredsOfDistantEstimates() {
        var subject = model(Array(repeating: 100, count: 600))
        let initial = subject.totalHeight
        subject.measure([(subject.key(for: subject.descriptors[580]), 400)])
        XCTAssertEqual(subject.totalHeight - initial, 300)
        XCTAssertEqual(subject.prefix[580], 580 * 110)
        for width: CGFloat in [951, 678, 466] {
            let oldHeights = subject.heights
            let oldPrefix = subject.prefix
            subject.changeLayoutPreservingEstimates(.init(width: width, textMetrics: "large"))
            XCTAssertEqual(subject.heights, oldHeights)
            XCTAssertEqual(subject.prefix, oldPrefix)
            XCTAssertEqual(subject.cache[subject.key(for: subject.descriptors[580])]?.confidence, .estimated)
            subject.measure([(subject.key(for: subject.descriptors[580]), 200)])
            XCTAssertEqual(subject.heights[100], 100)
        }
    }

    func testDirtyIDsSkipEqualityOnUnchangedRowsWhileUpdatingDirtyAndNewRows() {
        final class Counter { var comparisons = 0 }
        struct TrackedRow: Equatable, Identifiable {
            let id: String
            let text: String
            let counter: Counter
            static func == (lhs: TrackedRow, rhs: TrackedRow) -> Bool {
                lhs.counter.comparisons += 1
                return lhs.id == rhs.id && lhs.text == rhs.text
            }
        }
        let counter = Counter()
        var tracker = NativeChatRowRevisionTracker<TrackedRow>()
        let initial = (0..<50).map { TrackedRow(id: "r\($0)", text: "v1", counter: counter) }
        let rev1 = tracker.revisions(for: initial)
        XCTAssertEqual(counter.comparisons, 0, "First insert needs no equality checks")

        var updated = initial
        updated[49] = TrackedRow(id: "r49", text: "v2", counter: counter)
        let rev2 = tracker.revisions(for: updated, dirtyIDs: ["r49"])
        XCTAssertEqual(counter.comparisons, 1, "Only the 1 dirty row should run Equatable.==")
        XCTAssertEqual(Array(rev1.prefix(49)), Array(rev2.prefix(49)))
        XCTAssertNotEqual(rev1[49], rev2[49])
    }

    // The steady band (27 Oct 2026). 200 rows of 100 pt with 10 pt gaps: row k spans
    // 110k..<110k + 100. The screen is 880 pt, eight rows.

    func testMotionPlanHoldsTheBandWhileTheScreenStaysInside() {
        let subject = model(Array(repeating: 100, count: 200))
        let current = subject.geometry(for: 80..<120)
        for direction in [NativeChatWindowModel.Direction.up, .down, .stationary] {
            let plan = subject.motionPlan(viewport: 10_000..<10_880, current: current, direction: direction)
            XCTAssertEqual(plan.range, 80..<120, "\(direction)")
        }
    }

    func testMotionPlanGrowsOnlyTheLeadingEdgeInOneChangeEstimatesCountingTwice() {
        var subject = model(Array(repeating: 100, count: 200))
        let viewport: Range<CGFloat> = 8_800..<9_680
        var current = subject.geometry(for: 80..<120)
        // Every row is still an estimate: 24 / 2 = 12 rows in one change.
        XCTAssertEqual(subject.motionPlan(viewport: viewport, current: current, direction: .up).range, 68..<120,
                       "one change toward two screens above, nothing below dropped")
        XCTAssertEqual(subject.motionPlan(viewport: viewport, current: current, direction: .up, step: 4).range, 78..<120,
                       "at most `step` rows a change")
        XCTAssertEqual(subject.motionPlan(viewport: viewport, current: current, direction: .down).range, 80..<120,
                       "travelling away from an edge never grows it")
        XCTAssertEqual(subject.motionPlan(viewport: viewport, current: current, direction: .stationary).range, 80..<120,
                       "no direction yet: nothing grows")
        // Not yet half a screen from the edge: nothing changes.
        XCTAssertEqual(subject.motionPlan(viewport: 9_500..<10_380, current: current, direction: .up).range, 80..<120)
        // Measured rows count once: the change reaches the full two screens (16 rows).
        subject.measure((60..<80).map { (subject.key(for: subject.descriptors[$0]), CGFloat(100)) })
        current = subject.geometry(for: 80..<120)
        XCTAssertEqual(subject.motionPlan(viewport: viewport, current: current, direction: .up).range, 64..<120)
    }

    func testMotionPlanExchangesOnlyWhatGrewPastItsCap() {
        let subject = model(Array(repeating: 100, count: 200))
        let full = subject.geometry(for: 56..<120)
        XCTAssertEqual(subject.motionPlan(viewport: 6_160..<7_040, current: full, direction: .up).range, 44..<108,
                       "at the cap: twelve estimated rows grown above, twelve of the farthest behind dropped")
        // A band over the cap (kept across a landing) is never cut down in bulk mid-fling.
        let oversized = subject.geometry(for: 20..<120)
        XCTAssertEqual(subject.motionPlan(viewport: 6_000..<6_880, current: oversized, direction: .up).range, 20..<120)
        XCTAssertEqual(subject.motionPlan(viewport: 2_200..<3_080, current: oversized, direction: .up).range, 8..<108)
    }

    func testMotionPlanReplansAfterAJumpOutOfTheBand() {
        let subject = model(Array(repeating: 100, count: 200))
        let current = subject.geometry(for: 80..<120)
        let plan = subject.motionPlan(viewport: 1_100..<1_980, current: current, direction: .up)
        XCTAssertTrue(plan.range.contains(12))
        XCTAssertLessThan(plan.range.upperBound, 80)
    }

    func testRestPlanKeepsThreeScreensAheadAndTwoBehindWithinItsCap() {
        let subject = model(Array(repeating: 100, count: 200))
        let viewport: Range<CGFloat> = 11_000..<11_880
        XCTAssertEqual(subject.restPlan(viewport: viewport, direction: .up).range, 76..<124)
        XCTAssertEqual(subject.restPlan(viewport: viewport, direction: .down).range, 84..<132)
        // Capped, the rows past the screen are shared three to two, ahead first.
        XCTAssertEqual(subject.restPlan(viewport: viewport, direction: .up, cap: 32).range, 86..<118)
    }

    func testGrowthStepMountsFourRowsAtATimeAheadFirstThenTrimsToTheTarget() {
        let subject = model(Array(repeating: 100, count: 200))
        let target = subject.geometry(for: 76..<124, mandatory: 100..<108)
        var range = 96..<112
        var steps: [Range<Int>] = []
        while let next = subject.growthStep(current: range, target: target, direction: .up), steps.count < 20 {
            steps.append(next.range)
            range = next.range
        }
        XCTAssertEqual(steps.first, 92..<112, "ahead (above) first")
        XCTAssertEqual(steps.count, 8)
        XCTAssertEqual(range, 76..<124)
        XCTAssertEqual(subject.growthStep(current: 70..<130, target: target, direction: .up)?.range, 76..<124,
                       "once the target is covered, the rows beyond it go")
        XCTAssertNil(subject.growthStep(current: 76..<124, target: target, direction: .up))
    }

    func testGrowthStepShrinksAGrownBandSixteenRowsAStep() {
        let subject = model(Array(repeating: 100, count: 200))
        let target = subject.geometry(for: 60..<124, mandatory: 90..<98)
        var range = 0..<160
        var dropped: [Int] = []
        while let next = subject.growthStep(current: range, target: target, direction: .up), dropped.count < 20 {
            dropped.append(range.count - next.range.count)
            range = next.range
        }
        XCTAssertEqual(range, 60..<124)
        XCTAssertEqual(dropped, [16, 16, 16, 16, 16, 16], "never a hundred rows in one frame")
    }

    func testGrowthStepNeverMountsMoreThanTheBandOrTheTarget() {
        let subject = model(Array(repeating: 100, count: 200))
        let target = subject.geometry(for: 16..<80, mandatory: 40..<48)
        var range = 40..<104
        var largest = range.count
        while let next = subject.growthStep(current: range, target: target, direction: .up) {
            range = next.range
            largest = max(largest, range.count)
            if range == target.range { break }
        }
        XCTAssertEqual(range, 16..<80)
        XCTAssertEqual(largest, 64, "rows grown above are exchanged for rows below, never added on top")
        XCTAssertEqual(subject.growthStep(current: 40..<104, target: target, direction: .up)?.range, 36..<100)
    }
}
