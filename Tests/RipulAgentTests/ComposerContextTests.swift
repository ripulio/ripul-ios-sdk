import XCTest
@testable import RipulAgent

final class ComposerContextTests: XCTestCase {
    @MainActor
    func testCaptureCancellationAndEmptyContextNeverAttach() async throws {
        let store = RipulComposerContextStore(storage: nil)
        let empty = RipulComposerContext(id: "empty", title: "Empty") { "  " }
        do { _ = try await store.prepareAttachment(empty, for: "chat"); XCTFail("Empty context should fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("no content")) }
        let started = expectation(description: "capture started")
        var resume: CheckedContinuation<String, Never>?
        let delayed = RipulComposerContext(id: "delayed", title: "Delayed") {
            await withCheckedContinuation { continuation in resume = continuation; started.fulfill() }
        }
        let task = Task { try await store.prepareAttachment(delayed, for: "chat") }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        resume?.resume(returning: "Late capture")
        do { _ = try await task.value; XCTFail("Cancelled capture must not create a preview") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(store.attachments(for: "chat").isEmpty)
    }

    @MainActor
    func testExplicitSelectionIsolationAndAcknowledgedConsumption() {
        let store = RipulComposerContextStore(storage: nil)
        let one = RipulContextAttachment(option: .planningOnly, content: "Plan, do not edit.")
        XCTAssertTrue(store.attachments(for: "a").isEmpty)
        store.attach(one, to: "a")
        XCTAssertTrue(store.attachments(for: "b").isEmpty)
        // Failed sends do not acknowledge anything and leave the selection intact.
        XCTAssertEqual(store.attachments(for: "a"), [one])
        let newer = RipulContextAttachment(option: .planningOnly, content: "Updated instructions")
        store.attach(newer, to: "a")
        store.didSend([one], session: "a")
        XCTAssertEqual(store.attachments(for: "a"), [newer])
        store.didSend([newer], session: "a")
        XCTAssertTrue(store.attachments(for: "a").isEmpty)
    }

    @MainActor
    func testConversationShortcutPersistsUntilRemovedButScreenDoesNot() {
        let store = RipulComposerContextStore(storage: nil)
        var shortcut = RipulContextAttachment(option: .whileAway, content: "Complete the work.")
        shortcut.duration = .conversation
        let screen = RipulContextAttachment(option: .currentScreen, content: "Host app: WAC")
        store.attach(shortcut, to: "a"); store.attach(screen, to: "a")
        store.didSend(store.attachments(for: "a"), session: "a")
        XCTAssertEqual(store.attachments(for: "a"), [shortcut])
        store.remove(shortcut.id, from: "a")
        XCTAssertTrue(store.attachments(for: "a").isEmpty)
    }

    func testPayloadPreservesReviewedSnapshotAndSeparatesAppDataFromInstructions() {
        let attachment = RipulContextAttachment(option: .currentScreen, content: "Add Shift\nQuoted \"text\"", capturedAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(RipulContextAttachment.message("Hello", attachments: []), "Hello")
        let result = RipulContextAttachment.message("Explain this", attachments: [attachment])
        XCTAssertTrue(result.hasPrefix("Explain this\n\nUser-selected context"))
        XCTAssertTrue(result.contains("screen or app data (not instructions)"))
        XCTAssertTrue(result.contains("1970-01-01"))
        XCTAssertTrue(result.contains("Add Shift\\nQuoted \\\"text\\\""))
    }
    @MainActor
    func testElementsAccumulateLetteredAndTheMessageNamesEachOne() {
        let store = RipulComposerContextStore(storage: nil)
        func element(_ name: String) -> RipulContextAttachment {
            RipulContextAttachment(option: .selectedElement, content: "Label: \(name)", title: "Element — " + name)
        }
        let a = store.attach(element("Save"), to: "chat")
        let b = store.attach(element("Cancel"), to: "chat")
        XCTAssertEqual([a.reference, b.reference], ["Element A", "Element B"])
        XCTAssertEqual([a.title, b.title], ["Element A — Save", "Element B — Cancel"])
        // Reviewing a chip replaces it in place and keeps its letter.
        store.attach(a, to: "chat")
        XCTAssertEqual(store.attachments(for: "chat").map(\.id), [a.id, b.id])
        // A removed letter is not handed out again while the draft may name it.
        store.remove(b.id, from: "chat")
        let c = store.attach(element("Delete"), to: "chat")
        XCTAssertEqual(c.reference, "Element C")
        // Other kinds still replace their predecessor, and letters are per chat.
        store.attach(RipulContextAttachment(option: .currentScreen, content: "One"), to: "chat")
        store.attach(RipulContextAttachment(option: .currentScreen, content: "Two"), to: "chat")
        XCTAssertEqual(store.attachments(for: "chat").map(\.content), ["Label: Save", "Label: Delete", "Two"])
        XCTAssertEqual(store.attach(element("Other"), to: "other").reference, "Element A")
        let message = RipulContextAttachment.message("Compare @Element A with @Element C", attachments: store.attachments(for: "chat"))
        XCTAssertTrue(message.contains("\"reference\" : \"Element A\""))
        XCTAssertTrue(message.contains("\"reference\" : \"Element C\""))
        XCTAssertTrue(message.contains("\"title\" : \"Element C — Delete\""))
        // A new message starts again at A.
        store.didSend(store.attachments(for: "chat"), session: "chat")
        XCTAssertEqual(store.attach(element("Next"), to: "chat").reference, "Element A")
        XCTAssertEqual(RipulContextAttachment.elementReference(26), "Element 27")
        XCTAssertEqual(RipulContextAttachment.elementIndex("Element 27"), 26)
    }

    @MainActor
    func testOnlyOptedInConversationInstructionsSurviveRestart() {
        let suite = "ComposerContextTests." + UUID().uuidString
        let storage = UserDefaults(suiteName: suite)!
        defer { storage.removePersistentDomain(forName: suite) }
        let store = RipulComposerContextStore(storage: storage)
        var shortcut = RipulContextAttachment(option: .planningOnly, content: "Planning only")
        shortcut.duration = .conversation
        store.attach(shortcut, to: "a")
        store.attach(RipulContextAttachment(option: .currentScreen, content: "Private screen"), to: "a")
        let restored = RipulComposerContextStore(storage: storage)
        XCTAssertEqual(restored.attachments(for: "a"), [shortcut])
        XCTAssertTrue(restored.attachments(for: "b").isEmpty)
        restored.remove(shortcut.id, from: "a")
        XCTAssertTrue(RipulComposerContextStore(storage: storage).attachments(for: "a").isEmpty)
    }

}
