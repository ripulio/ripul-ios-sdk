import XCTest
@testable import RipulAgent

final class NativeChatSpeechTests: XCTestCase {
    private func call(_ name: String = "mcp__ripul_tools__device_speak", text: String = "Here is the spoken reply.", status: String = "pending", result: String? = nil) throws -> ToolCallDetail {
        let args = try JSONSerialization.data(withJSONObject: ["text": text, "device": "iphone-test"])
        return ToolCallDetail(id: "speech", toolName: name, status: status, timestamp: 2,
                              arguments: String(decoding: args, as: UTF8.self), result: result, error: nil,
                              diagnostics: "Original invocation", rendererName: "device_speak", renderArguments: nil, commandPresentation: nil)
    }

    private func wire(_ id: String, name: String = "mcp__ripul_tools__device_speak", text: String = "Here is the spoken reply.", status: String = "pending", result: String? = nil) -> [String: Any] {
        var detail: [String: Any] = [
            "id": id, "toolName": name, "status": status, "timestamp": 2,
            "arguments": "{}", "renderArguments": ["text": text, "device": "iphone-test"],
            "diagnostics": "Original invocation",
        ]
        if let result { detail["result"] = result }
        return ["messageId": id, "chatId": "chat", "role": "assistant", "content": "", "timestamp": 2,
                "method": "llmRequest.toolStatus", "status": status,
                "toolCall": ["id": id, "toolName": name, "status": status, "detail": detail]]
    }

    func testUsesToolIdentityAndReadableWords() throws {
        for name in ["device_speak", "host_speak", "mcp__ripul_tools__device_speak", "mcp__ripul_tools__host_speak", "functions.mcp__ripul_tools__device_speak"] {
            XCTAssertEqual(try NativeChatSpeech(call(name, text: "  Read this.\n "))?.text, "Read this.", name)
        }
        for name in ["Bash", "exec", "mcp__other__device_speak", "device_speak_more"] {
            XCTAssertNil(try NativeChatSpeech(call(name)), "A label or code mentioning speech is not a speech call")
        }
        XCTAssertNil(try NativeChatSpeech(call(text: " \n ")))
    }

    func testDeliveryDoesNotClaimPlaybackOnToolSuccess() throws {
        XCTAssertEqual(try NativeChatSpeech(call())?.delivery, .pending)
        XCTAssertEqual(try NativeChatSpeech(call(status: "success"))?.delivery, .unknown)
        let sent = try XCTUnwrap(NativeChatSpeech(call(status: "success", result: #"{"spoken":true,"_deviceLabel":"Test_Phone"}"#)))
        XCTAssertEqual(sent.delivery, .sent)
        XCTAssertEqual(sent.detail, "Sent for speech on Test Phone")
        XCTAssertNil(sent.label)
        let silent = try XCTUnwrap(NativeChatSpeech(call(status: "success", result: #"{"spoken":false,"reason":"No voice conversation is active."}"#)))
        XCTAssertEqual(silent.delivery, .notSpoken)
        XCTAssertEqual(silent.label, "Audio not played")
        XCTAssertEqual(silent.detail, "No voice conversation is active.")
        XCTAssertEqual(try NativeChatSpeech(call(status: "error", result: "Disconnected"))?.label, "Audio unavailable")
        XCTAssertEqual(try NativeChatSpeech(call(status: "success", result: "Unreadable result"))?.text, "Here is the spoken reply.")
    }

    func testDecodesMCPAndStructuredResultEnvelopes() throws {
        for result in [
            #"{"content":[{"type":"text","text":"{\"spoken\":false}"}]}"#,
            #"{"structuredContent":{"spoken":false},"content":[]}"#,
            #"{"status":"success","result":"{\"spoken\":false}"}"#,
        ] {
            XCTAssertEqual(try NativeChatSpeech(call(status: "success", result: result))?.delivery, .notSpoken)
        }
    }

    @MainActor
    func testSpeechBreaksOutOfToolsInOrderForHistoryAndLiveUpdates() throws {
        let before = wire("before", name: "Bash")
        let pending = wire("speech")
        let after = wire("after", name: "Read")
        let store = NativeChatMessageStore()
        store.applyBackfill([before, pending, after], chatId: "chat")
        XCTAssertEqual(store.rows.map(\.id), ["toolGroup:before", "speech", "toolGroup:after"])
        guard case .assistant(let message) = store.rows[1] else { return XCTFail("Speech must be a visible assistant panel") }
        XCTAssertEqual(message.content, "Here is the spoken reply.")
        XCTAssertFalse(message.isToolRow)
        XCTAssertEqual(message.speech?.delivery, .pending)
        XCTAssertEqual(message.toolCall?.detail?.diagnostics, "Original invocation")
        XCTAssertEqual(store.resolveWebRowId(forNativeRowId: message.id), "speech")

        // A late result changes the existing panel without adding a tool row or losing its text.
        let done = wire("speech", status: "success", result: #"{"spoken":false}"#)
        store.applyPatch([done], chatId: "chat")
        XCTAssertEqual(store.rows.map(\.id), ["toolGroup:before", "speech", "toolGroup:after"])
        XCTAssertEqual(store.messages.first { $0.id == "speech" }?.speech?.delivery, .notSpoken)
        let replay = NativeChatMessageStore()
        replay.applyBackfill([before, done, after], chatId: "chat")
        XCTAssertEqual(store.rows, replay.rows)

        let live = NativeChatMessageStore()
        live.applyBackfill([before, after], chatId: "chat")
        live.applyPatch([pending], chatId: "chat")
        XCTAssertEqual(live.rows.filter { if case .assistant = $0 { return true }; return false }.count, 1)
    }

    @MainActor
    func testFailuresKeepTheWordsAndEmptySpeechKeepsDiagnostics() {
        let store = NativeChatMessageStore()
        store.applyBackfill([wire("failed", status: "error", result: "Disconnected")], chatId: "chat")
        guard case .assistant(let message) = store.rows.first else { return XCTFail("A speech failure must not hide the reply") }
        XCTAssertEqual(message.content, "Here is the spoken reply.")
        XCTAssertEqual(message.speech?.delivery, .unavailable)
        store.applyBackfill([wire("empty", text: "  ")], chatId: "chat")
        guard case .toolGroup = store.rows.first else { return XCTFail("Empty speech still has tool diagnostics") }
    }
}
