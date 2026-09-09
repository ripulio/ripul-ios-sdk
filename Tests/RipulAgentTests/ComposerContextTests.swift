import XCTest
@testable import RipulAgent

final class ComposerContextTests: XCTestCase {
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
