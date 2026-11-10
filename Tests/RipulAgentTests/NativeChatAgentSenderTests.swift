import XCTest
import Observation
@testable import RipulAgent

@MainActor
final class NativeChatAgentSenderTests: XCTestCase {
    func testIncomingReplyKeepsItsIdentityQuoteAndSpeechTextAcrossUpdates() throws {
        let store = NativeChatMessageStore()
        var row: [String: Any] = [
            "messageId": "reply", "role": "user", "method": "user-message",
            "content": "The build is ready.", "isGroupChat": true, "isOwnMessage": false,
            "senderLabel": "Build checker (replied)",
            "senderAgent": ["agentId": "machine-studio/cli_check", "model": "gpt-6.1", "runtime": "Codex"],
            "replyQuote": ["correlationId": "send", "senderDisplayName": "Message from this chat", "excerpt": "Check the build"],
        ]
        store.applyBackfill([row], chatId: "room")
        var message = try XCTUnwrap(store.messages.first)
        let sender = try XCTUnwrap(message.senderAgent)
        XCTAssertEqual(sender.agentId, "machine-studio/cli_check")
        XCTAssertEqual(sender.model, "gpt-6.1")
        XCTAssertEqual(sender.runtime, "Codex")
        XCTAssertEqual(message.replyQuote?.correlationId, "send")
        XCTAssertEqual(NativeChatReadAloudController.panelText(for: message), "The build is ready.", "Speech reads the reply, without its protocol, attribution or quoted question")

        // Content changes arrive as full row patches; `update` is the
        // separate thinking-stream transport and must leave the author alone.
        store.applyUpdate(["messageId": "reply", "thinking": ["content": "", "isStreaming": false]])
        XCTAssertEqual(store.messages.first?.senderAgent, sender)
        row["content"] = "Both builds are ready."
        store.applyPatch([row], chatId: "room")
        message = try XCTUnwrap(store.messages.first)
        XCTAssertEqual(message.senderAgent, sender)
        XCTAssertEqual(NativeChatReadAloudController.panelText(for: message), "Both builds are ready.")
        XCTAssertEqual(store.rows, [.user(message)], "Keep the incoming message's timeline and reply behaviour")
    }

    func testReplyUsesTheListIconForLocalQualifiedAndHashedChatIds() throws {
        let list = SessionListStore()
        let chatId = "chat_1790000000000_1"
        list.customIconsByChatId = ["check": "network", UnifiedSession.cliUuid(for: chatId): "ladybug"]
        for id in ["cli_check", "machine-studio/cli_check", "check"] {
            let sender = try XCTUnwrap(NativeChatAgentSender(wire: ["agentId": id]))
            XCTAssertEqual(list.customIcon(anyOf: sender.iconKeys), "network", id)
        }
        let sender = try XCTUnwrap(NativeChatAgentSender(wire: ["agentId": "machine-studio/\(chatId)"]))
        XCTAssertEqual(list.customIcon(anyOf: sender.iconKeys), "ladybug")
    }

    func testReplyIconTracksOnlyItsSourceChatAndReflectsChangesAndRemoval() throws {
        let list = SessionListStore()
        let sender = try XCTUnwrap(NativeChatAgentSender(wire: ["agentId": "machine-studio/cli_check"]))
        list.customIconsByChatId = ["check": "network"]
        var changed = false
        withObservationTracking {
            XCTAssertEqual(list.customIcon(anyOf: sender.iconKeys), "network")
        } onChange: {
            MainActor.assumeIsolated { changed = true }
        }
        list.customIconsByChatId["another-chat"] = "star"
        XCTAssertFalse(changed)
        list.customIconsByChatId["check"] = "ladybug"
        XCTAssertTrue(changed)
        XCTAssertEqual(list.customIcon(anyOf: sender.iconKeys), "ladybug")
        list.customIconsByChatId.removeValue(forKey: "check")
        XCTAssertNil(list.customIcon(anyOf: sender.iconKeys), "Removing the choice allows the model glyph again")
    }

    func testHumanMessagesDoNotAcquireAnAgentIdentity() throws {
        let store = NativeChatMessageStore()
        store.applyBackfill([["messageId": "person", "role": "user", "content": "Hello", "senderUserId": "human-1"]], chatId: "room")
        XCTAssertNil(store.messages.first?.senderAgent)
        XCTAssertNil(NativeChatAgentSender(wire: [:]))
        XCTAssertNil(NativeChatAgentSender(wire: ["agentId": ""]))
    }
}
