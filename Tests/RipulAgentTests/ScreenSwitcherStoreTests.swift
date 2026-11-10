#if canImport(UIKit)
import XCTest
import UIKit
@testable import RipulAgent

@MainActor
final class ScreenSwitcherStoreTests: XCTestCase {
    func testImmediateCloseCancelsAPendingBubbleHandoff() async throws {
        let store = ScreenSwitcherStore()
        store.open(document(1))
        store.open(document(2))
        store.bubbleTargetProvider = { CGRect(x: 20, y: 400, width: 56, height: 56) }
        var folds = 0
        store.onBubble = { _ in folds += 1 }
        store.beginInteractive(snapshot: nil)
        store.updateInteractive(translation: store.travelDistance * ScreenSwitcherStore.bubbleProgress)
        advance(store)
        store.endInteractive(translation: 0, velocity: 0)
        XCTAssertTrue(store.isBubbling)
        store.closeImmediately()
        XCTAssertFalse(store.isActive)
        XCTAssertEqual(store.stop, .screen)
        XCTAssertEqual(store.progress, 0)
        try await Task.sleep(for: .milliseconds(550))
        XCTAssertEqual(folds, 0)
        XCTAssertEqual(store.documents.count, 2)
    }

    private func document(_ number: Int) -> SwitcherDocument {
        .instance(host: "browser", instance: String(number), title: "Tab \(number)", icon: "globe")
    }

    private func fullStore() -> ScreenSwitcherStore {
        let store = ScreenSwitcherStore()
        for number in 1...8 { store.open(document(number)) }
        return store
    }

    func testNinthTileReplacesOldestSlotWithoutClosingItsResource() async {
        let store = fullStore()
        var evicted: [String] = []
        store.onClose = { _ in XCTFail("Capacity eviction must not close a browser tab") }
        store.onSelect = { _ in XCTFail("Eviction must not navigate to a neighbour") }
        store.onEvict = { id in
            evicted.append(id)
            XCTAssertEqual(store.documents.count, 8)
            XCTAssertEqual(store.activeDestinationId, "browser:9")
        }

        // Evicting the previously active card must still focus the new one.
        store.open(document(1))
        store.open(document(9))

        XCTAssertEqual(store.order, [9, 2, 3, 4, 5, 6, 7, 8].map { "browser:\($0)" })
        XCTAssertEqual(evicted, ["browser:1"])
        XCTAssertEqual(store.openingOrder, (2...9).map { "browser:\($0)" })
    }

    func testVisitingOrReorderingDoesNotChangeWhichTileIsOldest() async {
        let store = fullStore()
        store.move(id: "browser:1", to: "browser:5")
        let arranged = store.order
        store.open(document(1))
        store.open(document(9))

        XCTAssertEqual(store.order, arranged.map { $0 == "browser:1" ? "browser:9" : $0 })
        XCTAssertEqual(store.activeDestinationId, "browser:9")
    }

    func testExistingTileRefreshDoesNotEvictOrDuplicate() async {
        let store = fullStore()
        let before = store.order
        store.onEvict = { _ in XCTFail("Focusing an existing tile needs no room") }
        var renamed = document(3)
        renamed.title = "Renamed"
        store.open(renamed)

        XCTAssertEqual(store.order, before)
        XCTAssertEqual(store.document(for: renamed.id)?.title, "Renamed")
        XCTAssertEqual(store.activeDestinationId, renamed.id)
    }

    func testManualCloseAndReopenGivesTileANewAdmissionAge() async {
        let store = fullStore()
        var closed: [String] = []
        store.onClose = { closed.append($0) }
        store.close(id: "browser:1")
        store.open(document(1))
        store.open(document(9))

        XCTAssertEqual(closed, ["browser:1"])
        XCTAssertNotNil(store.document(for: "browser:1"))
        XCTAssertNil(store.document(for: "browser:2"))
        XCTAssertEqual(store.documents.count, 8)
    }

    func testRestoringOversizedBoardKeepsNewestEight() async {
        let store = ScreenSwitcherStore()
        var evicted: [String] = []
        store.onEvict = { evicted.append($0) }
        store.onClose = { _ in XCTFail("Restoring must not close underlying resources") }
        store.restore(documents: (1...12).map(document), activeId: "browser:12")

        XCTAssertEqual(store.order, (5...12).map { "browser:\($0)" })
        XCTAssertEqual(evicted, (1...4).map { "browser:\($0)" })
        XCTAssertEqual(store.activeDestinationId, "browser:12")
        store.open(document(13))
        XCTAssertNil(store.document(for: "browser:5"))
        XCTAssertEqual(store.documents.count, 8)
    }

    func testAdmissionAgeSurvivesPersistenceAndReordering() async throws {
        let original = fullStore()
        original.move(id: "browser:1", to: "browser:8")
        let data = try JSONEncoder().encode(original.documents)
        let restored = ScreenSwitcherStore()
        restored.restore(
            documents: try JSONDecoder().decode([SwitcherDocument].self, from: data),
            activeId: original.activeDestinationId,
            openingOrder: original.openingOrder
        )
        restored.open(document(9))

        XCTAssertEqual(restored.order, (2...9).map { "browser:\($0)" })
        XCTAssertEqual(restored.openingOrder, (2...9).map { "browser:\($0)" })
    }

    func testEvictionReleasesSnapshotAndRejectsLateCapture() async {
        let store = fullStore()
        let image = UIImage()
        store.store(snapshot: image, for: "browser:1")
        XCTAssertNotNil(store.snapshots["browser:1"])
        store.open(document(9))
        store.store(snapshot: image, for: "browser:1")

        XCTAssertNil(store.snapshots["browser:1"])
        XCTAssertFalse(store.snapshotIdsForPersistence.contains("browser:1"))
    }

    func testRepeatedOpeningsStayBounded() async {
        let store = fullStore()
        for number in 9...40 {
            store.open(document(number))
            XCTAssertEqual(store.documents.count, 8)
            XCTAssertEqual(store.openingOrder.count, 8)
            XCTAssertEqual(Set(store.order), Set(((number - 7)...number).map { "browser:\($0)" }))
            XCTAssertEqual(store.activeDestinationId, "browser:\(number)")
        }
    }

    // MARK: - Bubble stop

    private let bubbleFrame = CGRect(x: 350, y: 850, width: 56, height: 56)

    /// A board with a file and a chat, the chat on screen, ready to be pulled.
    private func chatBoard(bubble: Bool) -> ScreenSwitcherStore {
        let store = ScreenSwitcherStore()
        store.open(.instance(host: "files", instance: "readme", title: "README", icon: "doc.text"))
        store.open(.instance(host: "agent", instance: "chat-1", title: "Chat", icon: "message"))
        if bubble { store.bubbleTargetProvider = { [bubbleFrame] in bubbleFrame } }
        store.calibrate(windowHeight: 956)
        return store
    }

    private func pull(_ store: ScreenSwitcherStore, to progress: CGFloat) {
        store.beginInteractive(snapshot: nil)
        store.updateInteractive(translation: progress * store.travelDistance)
        advance(store)
    }

    private func advance(_ store: ScreenSwitcherStore) {
        for frame in 0...240 { store.advanceInteractiveFrame(at: Double(frame) / 120) }
    }

    func testBatchedRecognitionStartsAtRestAndAcceleratesSmoothly() {
        let store = chatBoard(bubble: true)
        store.beginInteractive(snapshot: nil)
        store.updateInteractive(translation: store.travelDistance)
        XCTAssertEqual(store.progress, 0, "A queued thumb update is intent, not the first visible frame")
        store.advanceInteractiveFrame(at: 0)
        XCTAssertEqual(store.progress, 0)
        store.advanceInteractiveFrame(at: 1.0 / 120)
        let first = store.progress
        XCTAssertGreaterThan(first, 0)
        XCTAssertLessThan(first, 0.002)
        store.advanceInteractiveFrame(at: 2.0 / 120)
        XCTAssertGreaterThan(store.progress - first, first, "Motion eases in from rest")

        let beforeStall = store.progress
        store.advanceInteractiveFrame(at: 0.5)
        XCTAssertLessThan(store.progress - beforeStall, 0.01, "A stalled frame must not catch up to the thumb")
        store.closeImmediately()
    }

    func testRampConvergesAndReversesWithoutTeleporting() {
        let store = chatBoard(bubble: true)
        store.beginInteractive(snapshot: nil)
        store.updateInteractive(translation: store.travelDistance * 1.3)
        var previous: CGFloat = 0
        for frame in 0...180 {
            store.advanceInteractiveFrame(at: Double(frame) / 120)
            XCTAssertGreaterThanOrEqual(store.progress, previous)
            XCTAssertLessThanOrEqual(store.progress - previous, 2.8 / 120 + 0.0001)
            previous = store.progress
        }
        XCTAssertEqual(store.progress, 1.3, accuracy: 0.001)
        store.updateInteractive(translation: 0)
        XCTAssertEqual(store.progress, previous)
        for frame in 181...360 {
            store.advanceInteractiveFrame(at: Double(frame) / 120)
            XCTAssertLessThanOrEqual(store.progress, previous)
            previous = store.progress
        }
        XCTAssertEqual(store.progress, 0, accuracy: 0.001)
        store.closeImmediately()
    }

    func testFastReleaseWaitsForStartingFrameAndPreservesAllStops() {
        for (intent, expected) in [(CGFloat(0.25), SwitcherStop.deck), (0.8, .grid), (1.3, .bubble)] {
            let store = chatBoard(bubble: true)
            store.beginInteractive(snapshot: nil)
            store.updateInteractive(translation: store.travelDistance * intent)
            store.endInteractive(translation: 0, velocity: 0)
            XCTAssertEqual(store.progress, 0)
            store.advanceInteractiveFrame(at: 0)
            XCTAssertEqual(store.progress, 0)
            store.advanceInteractiveFrame(at: 1.0 / 60)
            XCTAssertEqual(store.stop, expected, "Visual lag must not change release intent")
            store.closeImmediately()
        }
    }

    func testInterruptedOrDismissedPreparationCannotRestartMotion() {
        let store = chatBoard(bubble: true)
        store.beginInteractive(snapshot: nil)
        store.updateInteractive(translation: store.travelDistance)
        store.settleAfterInterruption()
        advance(store)
        XCTAssertEqual(store.progress, 0)
        XCTAssertFalse(store.isDragging)

        store.beginInteractive(snapshot: nil)
        store.updateInteractive(translation: store.travelDistance * 1.3)
        store.endInteractive(translation: 0, velocity: 0)
        store.closeImmediately()
        advance(store)
        XCTAssertEqual(store.progress, 0)
        XCTAssertFalse(store.isActive)
    }

    func testDeckPullStartsFromTheDeckAndHorizontalSlideStaysDirect() {
        let store = chatBoard(bubble: true)
        store.openDeck()
        let deck = store.progress
        store.beginInteractive(snapshot: nil)
        store.updateInteractive(translation: store.travelDistance * 0.5)
        XCTAssertEqual(store.progress, deck)
        advance(store)
        XCTAssertEqual(store.progress, deck + 0.5, accuracy: 0.001)
        store.cancelInteractive()
        XCTAssertEqual(store.stop, .deck)
        store.closeImmediately()

        store.beginSlide(snapshot: nil)
        store.updateSlide(translation: 110, width: 440)
        XCTAssertEqual(store.slideFraction, 0.25)
        store.cancelSlide()
    }

    func testDisplayClockMovesTheRampAndStopsAfterRelease() async throws {
        let store = chatBoard(bubble: true)
        defer { store.closeImmediately() }
        store.beginInteractive(snapshot: UIImage())
        store.updateInteractive(translation: store.travelDistance * 0.8)
        XCTAssertEqual(store.progress, 0)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertGreaterThan(store.progress, 0)
        XCTAssertLessThan(store.progress, 0.8)
        store.endInteractive(translation: 0, velocity: 0)
        XCTAssertEqual(store.stop, .grid, "Release uses intent while the picture is still travelling")
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(store.progress, 1, "A retired display clock cannot overwrite the settling spring")
    }

    func testBackgroundSettlesAnAlreadyReleasedPreparation() {
        let store = chatBoard(bubble: true)
        store.beginInteractive(snapshot: nil)
        store.updateInteractive(translation: store.travelDistance * 0.8)
        store.endInteractive(translation: 0, velocity: 0)
        XCTAssertEqual(store.progress, 0)
        store.settleAfterInterruption()
        XCTAssertEqual(store.stop, .grid)
        advance(store)
        XCTAssertEqual(store.progress, 1)
        store.closeImmediately()
    }

    func testPullWithoutABubbleTargetStopsAtTheGrid() {
        let store = chatBoard(bubble: false)
        pull(store, to: 5)
        XCTAssertFalse(store.canBubble)
        XCTAssertNil(store.bubbleTarget)
        XCTAssertEqual(store.progress, 1, "The ramp still tops out at the grid")
        store.endInteractive(translation: 0, velocity: 0)
        XCTAssertEqual(store.stop, .grid)
    }

    func testFoldNeedsAnotherCardToLandOn() {
        let store = ScreenSwitcherStore()
        store.open(.instance(host: "agent", instance: "chat-1", title: "Chat", icon: "message"))
        store.bubbleTargetProvider = { [bubbleFrame] in bubbleFrame }
        store.calibrate(windowHeight: 956)
        pull(store, to: 5)
        XCTAssertNotNil(store.bubbleTarget, "The target is frozen even when it cannot be used")
        XCTAssertFalse(store.canBubble)
        XCTAssertEqual(store.progress, 1)
    }

    func testPullPastTheGridFoldsAndHandsOffToTheHost() async throws {
        let store = chatBoard(bubble: true)
        var folded: [String] = []
        // The host answers inside the callback, as the shell does: show the
        // bubble, move the app, then tell the board where it landed.
        store.onBubble = { id in
            folded.append(id)
            store.completeBubble(retiring: id, landingOn: "files:readme")
        }
        store.onClose = { _ in XCTFail("Folding is not closing") }
        store.onSelect = { _ in XCTFail("Folding navigates through the host, not onSelect") }

        pull(store, to: 5)
        XCTAssertTrue(store.canBubble)
        XCTAssertEqual(store.bubbleTarget, bubbleFrame)
        XCTAssertEqual(store.progress, ScreenSwitcherStore.bubbleProgress, "The ramp runs on past the grid")

        store.endInteractive(translation: 0, velocity: 0)
        XCTAssertEqual(store.stop, .bubble)
        XCTAssertTrue(store.isBubbling)
        XCTAssertTrue(store.isSettled)
        XCTAssertFalse(store.isOpen)
        XCTAssertEqual(folded, [], "The hand-off waits for the fold to land")

        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(folded, ["agent:chat-1"])
        XCTAssertNil(store.document(for: "agent:chat-1"), "The folded chat leaves the board")
        XCTAssertEqual(store.activeDestinationId, "files:readme")
        XCTAssertEqual(store.stop, .grid)
        XCTAssertEqual(store.progress, 1)
        XCTAssertTrue(store.isActive, "The board stays open on the landing card")
        XCTAssertNil(store.bubbleTarget)
    }

    func testReleaseShortOfTheFoldReturnsToTheGrid() {
        let store = chatBoard(bubble: true)
        pull(store, to: 1.05)
        store.endInteractive(translation: 0, velocity: 0)
        XCTAssertEqual(store.stop, .grid)
        XCTAssertEqual(store.progress, 1)
    }

    func testFlickPastTheGridFoldsButAFlickIntoItDoesNot() {
        let flicked = chatBoard(bubble: true)
        pull(flicked, to: 1.05)
        flicked.endInteractive(translation: 0, velocity: 1000)
        XCTAssertEqual(flicked.stop, .bubble, "Past the grid a flick promotes one stop")

        let opening = chatBoard(bubble: true)
        pull(opening, to: 0.8)
        opening.endInteractive(translation: 0, velocity: 1000)
        XCTAssertEqual(opening.stop, .grid, "A brisk pull that opens the board must never fold instead")
    }

    func testFlickDownFromPastTheGridLandsOnTheGrid() {
        let store = chatBoard(bubble: true)
        pull(store, to: 1.3)
        store.endInteractive(translation: 0, velocity: -1000)
        XCTAssertEqual(store.stop, .grid)
    }

    func testHostThatIgnoresTheFoldGetsTheGridBack() async throws {
        let store = chatBoard(bubble: true)
        pull(store, to: 5)
        store.endInteractive(translation: 0, velocity: 0)
        XCTAssertEqual(store.stop, .bubble)
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(store.stop, .grid)
        XCTAssertNotNil(store.document(for: "agent:chat-1"), "Nothing was retired")
    }

    func testTapsAreDeadWhileTheFoldIsLanding() {
        let store = chatBoard(bubble: true)
        var selected: [String] = []
        store.onSelect = { selected.append($0) }
        pull(store, to: 5)
        store.endInteractive(translation: 0, velocity: 0)
        store.close()
        store.select("files:readme")
        XCTAssertEqual(store.stop, .bubble)
        XCTAssertEqual(selected, [])
    }

    func testFoldWithNowhereToLandDismissesFlat() async throws {
        let store = chatBoard(bubble: true)
        pull(store, to: 5)
        store.endInteractive(translation: 0, velocity: 0)
        store.completeBubble(retiring: nil, landingOn: nil)
        XCTAssertTrue(store.isFlatDismissing)
        XCTAssertNotNil(store.document(for: "agent:chat-1"), "Nothing folded, so nothing is retired")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(store.isActive)
        XCTAssertEqual(store.stop, .screen)
    }

    // MARK: - Carried to a wide window's edge

    /// An open Duo held landscape (951 by 669): a screen docks in the 548
    /// points beside a phone-width app.
    private let duoTargets = ScreenSwitcherStore.DockTargets(
        left: CGRect(x: 0, y: 0, width: 548, height: 669),
        right: CGRect(x: 403, y: 0, width: 548, height: 669))

    private func wideBoard() -> ScreenSwitcherStore {
        let store = chatBoard(bubble: false)
        store.dockTargetsProvider = { [duoTargets] in duoTargets }
        return store
    }

    /// Pulled `lift` of the way to the grid, then carried sideways with the finger at `fingerX`.
    private func carry(_ store: ScreenSwitcherStore, by carry: CGFloat, fingerX: CGFloat, lift: CGFloat = 0.6) {
        store.beginInteractive(snapshot: nil)
        store.updateInteractive(translation: lift * store.travelDistance)
        store.fingerLocation = CGPoint(x: fingerX, y: 300)
        store.updateCarry(translation: carry)
    }

    func testAPhonesCardStaysCentredWhateverTheFingerDoesSideways() {
        let store = chatBoard(bubble: false)
        carry(store, by: 300, fingerX: 420)
        XCTAssertNil(store.dockTargets)
        XCTAssertEqual(store.carry, 0)
        XCTAssertNil(store.dockHover)
        store.closeImmediately()
    }

    func testAWideWindowsCardFollowsTheFingerAndAnEdgeTakesIt() {
        let store = wideBoard()
        carry(store, by: 120, fingerX: 600)
        XCTAssertEqual(store.dockTargets, duoTargets)
        XCTAssertEqual(store.carry, 120)
        XCTAssertNil(store.dockHover, "not near an edge yet")
        store.fingerLocation = CGPoint(x: 910, y: 300)
        store.updateCarry(translation: 430)
        XCTAssertEqual(store.dockHover, .right)
        // A finger resting near the boundary stays in.
        store.fingerLocation = CGPoint(x: 830, y: 300)
        store.updateCarry(translation: 350)
        XCTAssertEqual(store.dockHover, .right)
        // Well away, out again.
        store.fingerLocation = CGPoint(x: 600, y: 300)
        store.updateCarry(translation: 120)
        XCTAssertNil(store.dockHover)
        // And the left edge.
        store.fingerLocation = CGPoint(x: 30, y: 300)
        store.updateCarry(translation: -440)
        XCTAssertEqual(store.dockHover, .left)
        store.closeImmediately()
    }

    func testOnlyALiftedCardDocks() {
        let store = wideBoard()
        carry(store, by: 430, fingerX: 920, lift: 0.05)
        XCTAssertNil(store.dockHover, "a card still filling the window has not been lifted")
        store.closeImmediately()
    }

    func testAPullStartingAtAnEdgeHasNotBeenCarriedThere() {
        XCTAssertNil(ScreenSwitcherStore.dockSide(fingerX: 930, carry: 10, width: 951, lifted: true, current: nil))
        XCTAssertEqual(ScreenSwitcherStore.dockSide(fingerX: 930, carry: 40, width: 951, lifted: true, current: nil), .right)
        // Carried far enough across, wherever the finger is.
        XCTAssertEqual(ScreenSwitcherStore.dockSide(fingerX: 700, carry: 280, width: 951, lifted: true, current: nil), .right)
        XCTAssertEqual(ScreenSwitcherStore.dockSide(fingerX: nil, carry: -280, width: 951, lifted: true, current: nil), .left)
        XCTAssertNil(ScreenSwitcherStore.dockSide(fingerX: 930, carry: 400, width: 951, lifted: false, current: nil))
    }

    func testLettingGoOverAnEdgeLandsTheCardAndHandsItToTheHost() async throws {
        let store = wideBoard()
        var docked: [String] = []
        var sides: [ScreenSwitcherStore.DockSide] = []
        store.onDock = { id, side in
            docked.append(id)
            sides.append(side)
            store.completeDock(landingOn: nil)
        }
        store.onSelect = { _ in XCTFail("Docking goes through the host, not onSelect") }
        carry(store, by: 430, fingerX: 920)
        store.endInteractive(translation: 0, velocity: 0)
        XCTAssertEqual(store.dockLanding, .right)
        XCTAssertTrue(store.isDocking)
        XCTAssertFalse(store.isSettled, "no tap is live while it lands")
        store.close()
        XCTAssertTrue(store.isDocking, "nor does a tap outside put it back")
        XCTAssertEqual(docked, [], "the hand-off waits for the card to land")

        try await Task.sleep(for: .milliseconds(550))
        XCTAssertEqual(docked, ["agent:chat-1"])
        XCTAssertEqual(sides, [.right])
        XCTAssertFalse(store.isActive, "with no card to land on, the board goes")
        XCTAssertNil(store.dockLanding)
        XCTAssertEqual(store.carry, 0)
        XCTAssertNotNil(store.document(for: "agent:chat-1"), "docking is not closing")
    }

    func testADockWithALandingCardLeavesTheBoardOpenOnIt() async throws {
        let store = wideBoard()
        store.onDock = { _, _ in store.completeDock(landingOn: "files:readme") }
        carry(store, by: -440, fingerX: 25)
        store.endInteractive(translation: 0, velocity: 0)
        try await Task.sleep(for: .milliseconds(550))
        XCTAssertTrue(store.isActive)
        XCTAssertEqual(store.stop, .grid)
        XCTAssertEqual(store.progress, 1)
        XCTAssertEqual(store.activeDestinationId, "files:readme")
        XCTAssertNil(store.dockTargets)
        XCTAssertNil(store.dockLanding)
        XCTAssertEqual(store.carry, 0)
    }

    func testAHostThatIgnoresTheDockGetsTheGridBack() async throws {
        let store = wideBoard()
        store.onDock = { _, _ in }
        carry(store, by: 430, fingerX: 920)
        store.endInteractive(translation: 0, velocity: 0)
        try await Task.sleep(for: .milliseconds(550))
        XCTAssertEqual(store.stop, .grid)
        XCTAssertNil(store.dockLanding)
        XCTAssertEqual(store.carry, 0)
        XCTAssertEqual(store.activeDestinationId, "agent:chat-1", "the card is intact")
    }

    func testLettingGoAwayFromAnEdgeLandsOnAStopAndCentresTheCard() {
        let store = wideBoard()
        var docked = 0
        store.onDock = { _, _ in docked += 1 }
        carry(store, by: 150, fingerX: 620, lift: 0.8)
        advance(store)
        store.endInteractive(translation: 0, velocity: 0)
        XCTAssertEqual(store.stop, .grid)
        XCTAssertEqual(store.carry, 0)
        XCTAssertNil(store.dockTargets)
        XCTAssertEqual(docked, 0)
        store.closeImmediately()
    }

    func testAPullFromTheDeckPagesRatherThanCarries() {
        let store = wideBoard()
        pull(store, to: 0.3)
        store.endInteractive(translation: 0, velocity: 0)
        XCTAssertEqual(store.stop, .deck)
        store.beginInteractive(snapshot: nil)
        store.fingerLocation = CGPoint(x: 920, y: 300)
        store.updateCarry(translation: 430)
        XCTAssertNil(store.dockTargets, "on the deck a sideways drag pages the cards")
        XCTAssertEqual(store.carry, 0)
        store.closeImmediately()
    }

    func testMostRecentlyUsedIsRecencyNotDisplayOrder() {
        let store = ScreenSwitcherStore()
        store.open(document(1))
        store.open(document(2))
        store.open(document(3))
        store.open(document(1))
        XCTAssertEqual(store.mostRecentlyUsed(excluding: "browser:1")?.id, "browser:3")
        XCTAssertEqual(store.mostRecentlyUsed(excluding: "browser:1") { $0.id != "browser:3" }?.id, "browser:2")
        XCTAssertNil(store.mostRecentlyUsed(excluding: "browser:1") { _ in false })
    }
}
#endif
