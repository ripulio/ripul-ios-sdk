import XCTest
@testable import RipulAgent

/// The heal ladder and the host-bridge backstop by themselves: no bridge, no
/// web view, and the clock is whatever the test says it is. Both platforms'
/// ladders are covered here, whichever one the tests are running on.
final class WebContextRecoveryTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - HealLadder

    func testTheFirstThreeRungsAreReloadThenPurgeTwice() {
        var ladder = HealLadder(persistent: false)
        XCTAssertEqual(ladder.next(at: start), .heal(attempt: 1, rung: .reload, floor: 10))
        XCTAssertEqual(ladder.next(at: start + 10), .heal(attempt: 2, rung: .purge, floor: 10))
        XCTAssertEqual(ladder.next(at: start + 20), .heal(attempt: 3, rung: .purge, floor: 10))
        XCTAssertEqual(ladder.attempts, 3)
    }

    func testAHealInsideTheFloorIsTooSoonAndChangesNothing() {
        var ladder = HealLadder(persistent: false)
        _ = ladder.next(at: start)
        let before = ladder
        XCTAssertEqual(ladder.next(at: start + 9.5), .tooSoon(since: 9.5, floor: 10))
        XCTAssertEqual(ladder, before)
        XCTAssertEqual(ladder.remainingFloor(at: start + 4), 6)
        XCTAssertEqual(ladder.remainingFloor(at: start + 60), 0)
        XCTAssertEqual(HealLadder(persistent: true).remainingFloor(at: start), 0, "Nothing to wait for before the first heal")
    }

    func testAPhoneStopsAfterTheThirdAttempt() {
        var ladder = HealLadder(persistent: false)
        for step in 0..<3 { _ = ladder.next(at: start + Double(step) * 10) }
        XCTAssertEqual(ladder.next(at: start + 30), .heal(attempt: 4, rung: .exhausted, floor: 10))
        XCTAssertEqual(ladder.next(at: start + 40), .heal(attempt: 5, rung: .exhausted, floor: 10),
                       "It still counts, so the log says which attempt was refused")
        XCTAssertEqual(ladder.floor(for: 9), 10, "No backoff where nothing more is tried")
    }

    func testAMacKeepsPurgingWithAFloorThatDoublesToFiveMinutes() {
        let ladder = HealLadder(persistent: true)
        XCTAssertEqual((1...10).map(ladder.floor(for:)), [10, 10, 10, 20, 40, 80, 160, 300, 300, 300])

        var climbing = HealLadder(persistent: true)
        var now = start
        for _ in 0..<3 { _ = climbing.next(at: now); now += 10 }
        XCTAssertEqual(climbing.next(at: now), .tooSoon(since: 10, floor: 20))
        now += 10
        XCTAssertEqual(climbing.next(at: now), .heal(attempt: 4, rung: .persistentPurge, floor: 20))
        XCTAssertEqual(climbing.remainingFloor(at: now + 5), 15, "Measured against the attempt just made")
    }

    func testAHealLongAfterTheLastStartsAgainAtTheFirstRung() {
        var ladder = HealLadder(persistent: false)
        _ = ladder.next(at: start)
        _ = ladder.next(at: start + 10)
        XCTAssertEqual(ladder.next(at: start + 100), .heal(attempt: 3, rung: .purge, floor: 10), "Exactly 90s is still the same incident")
        XCTAssertEqual(ladder.next(at: start + 190.5), .heal(attempt: 1, rung: .reload, floor: 10))
    }

    func testResetStartsTheNextIncidentCheapButKeepsTheFloor() {
        var ladder = HealLadder(persistent: true)
        _ = ladder.next(at: start)
        _ = ladder.next(at: start + 10)
        ladder.reset()
        XCTAssertEqual(ladder.attempts, 0)
        XCTAssertEqual(ladder.next(at: start + 15), .tooSoon(since: 5, floor: 10))
        XCTAssertEqual(ladder.next(at: start + 20), .heal(attempt: 1, rung: .reload, floor: 10))
    }

    // MARK: - Reading the probe's canary

    private func read(_ fields: String) -> AgentBridge.WebContextProbe {
        AgentBridge.WebContextProbe.read("{\(fields)}")
    }

    func testNoAnswerOrOneThatIsNotTheCanaryMeansTheContextIsDead() {
        XCTAssertEqual(AgentBridge.WebContextProbe.read(nil).health, .contextDead)
        XCTAssertEqual(AgentBridge.WebContextProbe.read("not json").health, .contextDead)
        XCTAssertEqual(AgentBridge.WebContextProbe.read("[1, 2]").health, .contextDead)
        XCTAssertEqual(AgentBridge.WebContextProbe.read("not json").raw, "not json", "Kept for the technical details")
    }

    func testCallablesPresentIsHealthyUnlessTheAppSaysItCrashed() {
        XCTAssertEqual(read(#""callables": true"#).health, .healthy)
        XCTAssertEqual(read(#""callables": true, "crashed": true"#).health, .webCrashed)
        XCTAssertEqual(read(#""callables": false, "crashed": true"#).health, .webCrashed)
    }

    func testWithoutCallablesAgeAndReadyStateDecideBetweenBootingAndBroken() {
        XCTAssertEqual(read(#""callables": false, "docAgeMs": 7999, "readyState": "complete""#).health, .callablesMissing)
        XCTAssertEqual(read(#""callables": false, "docAgeMs": 8000, "readyState": "complete""#).health, .callablesAbsent)
        XCTAssertEqual(read(#""callables": false, "docAgeMs": 60000, "readyState": "interactive""#).health, .callablesMissing,
                       "Old but still loading is still booting")
        XCTAssertEqual(read(#""readyState": "complete""#).health, .callablesMissing, "No age reported counts as young")
    }

    func testTheBootBeaconsLastPhaseOverridesAge() {
        for phase in ["boot-complete", "boot-failed", "native-mode-false", "sidepanel-initialized"] {
            XCTAssertEqual(read(#""callables": false, "docAgeMs": 10, "bootPhase": "\#(phase)""#).health, .callablesAbsent, phase)
        }
        XCTAssertEqual(read(#""callables": false, "docAgeMs": 10, "bootPhase": "importing""#).health, .callablesMissing)
        XCTAssertEqual(read(#""callables": true, "bootPhase": "boot-failed""#).health, .healthy, "Callables present wins")
    }

    func testTheDigestListsWhatWasSeenInAFixedOrder() {
        let probe = read(#""callables": false, "path": "/popup", "readyState": "complete", "docAgeMs": 12345, "nav": "reload", "globals": 3, "uaNative": true, "bootPhase": "boot-failed", "bootError": "chunk 404", "build": "b7""#)
        XCTAssertEqual(probe.digest, "path=/popup ready=complete age=12s nav=reload globals=3 uaNative=true boot=boot-failed bootErr=chunk 404 build=b7")
        XCTAssertEqual(read(#""callables": true"#).digest, "")
    }

    // MARK: - HostBridgeBackstop

    func testTheBackstopArmsWaitsOutItsGraceThenAsksForOneProbeAtATime() {
        var backstop = HostBridgeBackstop()
        XCTAssertEqual(backstop.noteUnavailable(at: start), .armed)
        XCTAssertEqual(backstop.noteUnavailable(at: start + 14.9), .waiting)
        XCTAssertEqual(backstop.noteUnavailable(at: start + 15), .probe(since: start))
        XCTAssertEqual(backstop.noteUnavailable(at: start + 29.9), .waiting, "Probed 14.9s ago")
        XCTAssertEqual(backstop.noteUnavailable(at: start + 30), .probe(since: start), "The outage is still measured from its start")
    }

    func testAnAnswerClearsTheOutageAndTheNextOneStartsOver() {
        var backstop = HostBridgeBackstop()
        XCTAssertFalse(backstop.noteAvailable(), "Nothing to clear")
        _ = backstop.noteUnavailable(at: start)
        _ = backstop.noteUnavailable(at: start + 20)
        XCTAssertTrue(backstop.noteAvailable())
        XCTAssertNil(backstop.unavailableSince)
        XCTAssertEqual(backstop.noteUnavailable(at: start + 21), .armed)
        XCTAssertEqual(backstop.noteUnavailable(at: start + 36), .probe(since: start + 21), "The earlier probe does not hold this one back")
    }
}
