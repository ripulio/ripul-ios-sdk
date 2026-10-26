import XCTest
@testable import RipulAgent

@MainActor
final class NativeChatStateRevisionTests: XCTestCase {
    func testHeightRevisionSeparatesContentAndStateAndKeepsOtherRowsStable() {
        let registry = NativeChatRowStateRegistry()
        let coordinator = NativeChatScrollCoordinator()
        coordinator.bindRowStateRegistry(registry)
        let initial = coordinator.windowRevision(for: "row", content: 1)
        let sibling = coordinator.windowRevision(for: "sibling", content: 1)
        XCTAssertEqual(coordinator.windowRevision(for: "row", content: 1), initial)

        registry.setValue(true, forRow: "row", component: "expanded", default: false)
        let expanded = coordinator.windowRevision(for: "row", content: 1)
        XCTAssertNotEqual(expanded, initial)
        XCTAssertEqual(coordinator.windowRevision(for: "sibling", content: 1), sibling)

        // These pairs would collide if the adapter merely added the revisions:
        // (content: 1, state: 1) and (content: 2, state: 0).
        registry.clear()
        let changedContent = coordinator.windowRevision(for: "row", content: 2)
        XCTAssertNotEqual(changedContent, expanded)
        XCTAssertNotEqual(changedContent, initial)
    }

    func testNoOpAndNonHeightStateKeepMeasuredIdentity() {
        let registry = NativeChatRowStateRegistry()
        let coordinator = NativeChatScrollCoordinator()
        coordinator.bindRowStateRegistry(registry)
        let initial = coordinator.windowRevision(for: "row", content: 7)
        registry.setValue(false, forRow: "row", component: "expanded", default: false)
        registry.setValue(true, forRow: "row", component: "sheet", default: false, affectsHeight: false)
        XCTAssertEqual(coordinator.windowRevision(for: "row", content: 7), initial)
        registry.setValue(true, forRow: "row", component: "expanded", default: false)
        let expanded = coordinator.windowRevision(for: "row", content: 7)
        registry.setValue(true, forRow: "row", component: "expanded", default: false)
        XCTAssertEqual(coordinator.windowRevision(for: "row", content: 7), expanded)
    }
}
