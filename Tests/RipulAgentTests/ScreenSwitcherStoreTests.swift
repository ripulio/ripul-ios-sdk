#if canImport(UIKit)
import XCTest
import UIKit
@testable import RipulAgent

@MainActor
final class ScreenSwitcherStoreTests: XCTestCase {
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
}
#endif
