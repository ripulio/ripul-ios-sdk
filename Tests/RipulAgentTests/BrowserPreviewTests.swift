#if os(iOS)
import XCTest
import UIKit
import Combine
@testable import RipulAgent

@MainActor
final class BrowserPreviewTests: XCTestCase {
    private func snapshot(_ color: UIColor = .blue) -> BrowserPreviewSnapshot {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 64)).image { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 64))
        }
        return BrowserPreviewSnapshot(image: image, title: "Local browser")
    }

    func testTracksExplicitTabAndPreservesMinimisationDuringTools() async {
        let state = BrowserPreviewState()
        var captured: [Int?] = []
        state.capture = { tab in captured.append(tab); return self.snapshot() }
        state.open(chatId: "chat", tabId: 9, automatic: true)
        await state.refresh()
        XCTAssertEqual(captured, [9])
        XCTAssertEqual(state.aspectRatio, 0.5)
        state.collapsed = true
        state.open(chatId: "chat", tabId: 10, automatic: true)
        XCTAssertTrue(state.collapsed)
        await state.refresh()
        XCTAssertEqual(captured.count, 1)
        state.open(chatId: "chat") // Menu restores and follows the active tab.
        XCTAssertFalse(state.collapsed)
        await state.refresh()
        XCTAssertNil(captured.last!)
        state.setAllowed(false)
        await state.refresh()
        state.close()
        state.setAllowed(true)
        await state.refresh()
        XCTAssertEqual(captured.count, 2)
    }

    func testUnchangedFramesDoNotInvalidateChatOrPanel() async {
        let state = BrowserPreviewState()
        let same = snapshot()
        state.capture = { _ in same }
        state.open(chatId: "chat")
        await state.refresh()
        var panelUpdates = 0, imageUpdates = 0
        let panel = state.objectWillChange.sink { panelUpdates += 1 }
        let image = state.frame.objectWillChange.sink { imageUpdates += 1 }
        defer { panel.cancel(); image.cancel() }
        for _ in 0..<10 { state.setAllowed(true); await state.refresh() }
        XCTAssertEqual(panelUpdates, 0)
        XCTAssertEqual(imageUpdates, 0)
        state.capture = { _ in self.snapshot(.red) }
        await state.refresh()
        XCTAssertEqual(panelUpdates, 0)
        XCTAssertEqual(imageUpdates, 1)
    }

    func testLateCaptureCannotReplaceNewTabOrReopenClosedPreview() async {
        for close in [false, true] {
            let state = BrowserPreviewState()
            var pending: CheckedContinuation<BrowserPreviewSnapshot, Never>?
            state.capture = { _ in await withCheckedContinuation { pending = $0 } }
            state.open(chatId: "chat", tabId: 1)
            let task = Task { await state.refresh() }
            while pending == nil { await Task.yield() }
            state.capture = { _ in XCTFail("Overlapping capture"); return self.snapshot() }
            await state.refresh()
            if close { state.close() } else { state.open(chatId: "other", tabId: 2) }
            pending?.resume(returning: snapshot())
            await task.value
            XCTAssertNil(state.frame.image)
            XCTAssertEqual(state.chatId, close ? nil : "other")
        }
    }

    func testEmptyBrowserAndTransientCaptureFailureRecover() async {
        let state = BrowserPreviewState()
        state.capture = { _ in BrowserPreviewSnapshot(image: nil, title: "No browser tabs open") }
        state.open(chatId: "chat")
        await state.refresh()
        XCTAssertEqual(state.message, "No browser tabs open")
        state.capture = { _ in throw NSError(domain: "test", code: 1) }
        await state.refresh()
        XCTAssertTrue(state.message?.hasPrefix("Browser preview unavailable.") == true)
        state.capture = { _ in self.snapshot() }
        await state.refresh()
        XCTAssertNil(state.message)
        XCTAssertNotNil(state.frame.image)
    }

    func testDoesNotOpenInHostsWithoutALocalBrowser() {
        let state = BrowserPreviewState()
        state.open(chatId: "chat", automatic: true)
        XCTAssertNil(state.chatId)
    }
}
#endif
