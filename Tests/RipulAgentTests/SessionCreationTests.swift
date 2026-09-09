import XCTest
@testable import RipulAgent

final class SessionCreationTests: XCTestCase {
    func testCreationPreservesDistinctNavigationAndSourceIdentities() throws {
        let session = try XCTUnwrap(ChatSession.creationSeed(from: [
            "success": true, "tabId": "tab-1", "chatId": "cli-source",
            "machineName": "Mac"
        ], providerKey: "codex-cli", modelId: "codex-cli-picked-model"))
        XCTAssertEqual(session.id, "tab-1")
        XCTAssertEqual(session.sourceChatId, "cli-source")
        XCTAssertNil(session.hostChatId, "Do not invent a handshake identity")
        XCTAssertEqual(session.remoteMachineName, "Mac")
        XCTAssertEqual(session.provider, "codex-cli")
        XCTAssertEqual(session.model, "codex-cli-picked-model")
        XCTAssertEqual(session.displayNameSource, "auto", "Placeholder must not rename CLI history")
    }

    func testPlainMachineCreationDoesNotInventProvider() throws {
        let session = try XCTUnwrap(ChatSession.creationSeed(from: [
            "success": true, "tabId": "tab", "chatId": "chat"
        ]))
        XCTAssertNil(session.provider)
        XCTAssertNil(session.model)
    }

    func testFailedOrIncompleteReplyCannotCreateNavigableSession() {
        for reply: [String: Any] in [
            ["success": false, "tabId": "tab", "chatId": "chat"],
            ["success": true, "tabId": "tab"],
            ["success": true, "tabId": "", "chatId": "chat"]
        ] {
            XCTAssertNil(ChatSession.creationSeed(from: reply))
        }
    }
}
