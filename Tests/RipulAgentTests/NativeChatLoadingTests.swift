import XCTest
import Combine
@testable import RipulAgent

@MainActor
final class NativeChatLoadingTests: XCTestCase {
    func testColdChatStaysLoadingUntilAnExplicitReadyEmptyBackfill() {
        let store = NativeChatMessageStore()
        XCTAssertEqual(store.loadingState.phase, .loading)
        store.applyBackfill([], chatId: "cold", loadingState: .loading)
        XCTAssertEqual(store.loadingState.phase, .loading)
        store.applyBackfill([], chatId: "cold", loadingState: .ready)
        XCTAssertEqual(store.loadingState.phase, .ready)
        XCTAssertTrue(store.rows.isEmpty)
    }

    func testProgressPublishesOnlyWhenChangedWithoutTouchingRows() {
        let store = NativeChatMessageStore()
        store.applyBackfill([["messageId": "one", "content": "Hello", "timestamp": 1]], chatId: "chat", loadingState: .loading)
        let rows = store.rows
        var publications = 0
        let token = store.objectWillChange.sink { publications += 1 }
        let progress = NativeChatLoadingState(wire: ["phase": "loading", "fraction": 0.5])!
        store.applyLoadingState(progress, chatId: "chat")
        store.applyLoadingState(progress, chatId: "chat")
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(store.rows, rows)
        withExtendedLifetime(token) {}
    }

    func testPreviousChatsProgressAndErrorsCannotReplaceCurrentChatState() {
        let store = NativeChatMessageStore()
        store.applyBackfill([], chatId: "new", loadingState: .loading)
        store.applyLoadingState(.ready, chatId: "old")
        store.applyLoadingState(NativeChatLoadingState(wire: ["phase": "failed"])!, chatId: "old")
        XCTAssertEqual(store.loadingState.phase, .loading)
        store.applyLoadingState(NativeChatLoadingState(wire: ["phase": "failed"])!, chatId: "new")
        XCTAssertEqual(store.loadingState.phase, .failed)
    }

    func testPatchDoesNotFinishAnOngoingImportAndLegacyBackfillStillWorks() {
        let store = NativeChatMessageStore()
        store.applyBackfill([], chatId: "chat", loadingState: .loading)
        store.applyPatch([["messageId": "one", "content": "First", "timestamp": 1]], chatId: "chat")
        XCTAssertEqual(store.loadingState.phase, .loading)
        store.applyBackfill([], chatId: "legacy")
        XCTAssertEqual(store.loadingState.phase, .ready)
    }

    func testMalformedProgressDoesNotProduceAnInvalidProgressBar() {
        XCTAssertNil(NativeChatLoadingState(wire: ["phase": "unknown"]))
        XCTAssertNil(NativeChatLoadingState(wire: ["phase": "loading", "fraction": Double.nan])?.fraction)
        XCTAssertEqual(NativeChatLoadingState(wire: ["phase": "loading", "fraction": 2])?.fraction, 1)
        XCTAssertEqual(NativeChatLoadingState(wire: ["phase": "loading", "fraction": -1])?.fraction, 0)
    }
}
