import XCTest
import Combine
import SwiftUI
@testable import RipulAgent

@MainActor
final class ThermalWorkTests: XCTestCase {
    func testPersistedAddReordersThinkingPlaceholderAndReindexesUpdates() {
        let store = NativeChatMessageStore()
        store.applyBackfill([["messageId": "later", "content": "Later", "timestamp": 20.0]], chatId: "chat")
        store.applyUpdate(["messageId": "earlier", "chatId": "chat", "timestamp": 30.0,
                           "thinking": ["content": "Early thought", "isStreaming": true]])
        _ = store.consumeDirtyRowIds()
        store.applyAdd(["messageId": "earlier", "chatId": "chat", "content": "Earlier", "timestamp": 10.0])
        XCTAssertEqual(store.messages.map(\.id), ["earlier", "later"])
        XCTAssertNil(store.consumeDirtyRowIds())
        store.applyUpdate(["messageId": "later", "thinking": ["content": "Later thought", "isStreaming": true]])
        XCTAssertEqual(store.messages[0].thinking, "Early thought")
        XCTAssertEqual(store.messages[1].thinking, "Later thought")
        XCTAssertEqual(store.rows, NativeChatMessageStore.buildRows(from: store.messages, previousRows: store.rows))
    }

    func testPatchForPreviousChatCannotPopulateNewEmptyChat() {
        let store = NativeChatMessageStore()
        store.applyBackfill([], chatId: "shared_new")
        store.applyPatch([["messageId": "old", "content": "Old chat", "timestamp": 1.0]], chatId: "remote-open_old")
        XCTAssertEqual(store.currentChatId, "shared_new")
        XCTAssertTrue(store.messages.isEmpty)
        store.applyPatch([["messageId": "new", "content": "New chat", "timestamp": 2.0]], chatId: "shared_new")
        XCTAssertEqual(store.messages.map(\.id), ["new"])
    }

    func testToolThinkingFastPathRebuildsGroupWhenChatIdentityChanges() {
        let store = NativeChatMessageStore()
        var tool: [String: Any] = ["messageId": "tool", "chatId": "shared_local", "method": "Bash",
                                   "timestamp": 1.0, "thinking": ["content": "Working", "isStreaming": true]]
        store.applyBackfill([tool], chatId: "shared_local")
        _ = store.consumeDirtyRowIds()
        tool["chatId"] = "cli_host"
        store.applyPatch([tool], chatId: "shared_local")
        XCTAssertEqual(store.rows, NativeChatMessageStore.buildRows(from: store.messages, previousRows: store.rows))
        guard case .toolGroup(let group) = store.rows.last else { return XCTFail("Expected tool group") }
        XCTAssertEqual(group.chatId, "cli_host")
        XCTAssertTrue(store.consumeDirtyRowIds()?.contains(store.rows.last!.id) == true)
    }

    func testTerminalStatusesCannotRestartThinkingFromLateDeltas() {
        for status in ["complete", "completed", "success", "error", "failed", "cancelled", "canceled", "stopped", "done", "killed", "ended", "orphaned"] {
            let store = NativeChatMessageStore()
            store.applyBackfill([["messageId": "m", "status": status, "timestamp": 1.0,
                                  "thinking": ["content": "Retained", "isStreaming": true]]], chatId: "chat")
            XCTAssertFalse(store.messages[0].isThinkingStreaming, status)
            store.applyUpdate(["messageId": "m", "thinking": ["content": "Late text", "isStreaming": true]])
            XCTAssertFalse(store.messages[0].isThinkingStreaming, status)
            XCTAssertEqual(store.messages[0].thinking, "Late text")
        }
    }

    func testDirtyIDsAccumulateThroughReorderRemovalAndRepeatedPatches() {
        let store = NativeChatMessageStore()
        store.applyBackfill([
            ["messageId": "a", "content": "A", "timestamp": 1.0],
            ["messageId": "b", "content": "B", "timestamp": 2.0],
            ["messageId": "c", "content": "C", "timestamp": 3.0],
        ], chatId: "chat")
        _ = store.consumeDirtyRowIds()
        store.applyPatch([["messageId": "a", "content": "A2", "timestamp": 1.0]], chatId: "chat")
        store.applyPatch([["messageId": "b", "content": "B2", "timestamp": 2.0]], chatId: "chat")
        XCTAssertEqual(store.consumeDirtyRowIds(), ["a", "b"])
        store.applyPatch([["messageId": "c", "content": "C2", "timestamp": 0.5]], removedIds: ["b"], chatId: "chat")
        XCTAssertEqual(store.messages.map(\.id), ["c", "a"])
        XCTAssertNil(store.consumeDirtyRowIds(), "Reordered/removed rows require a full revision scan")
        store.applyUpdate(["messageId": "a", "thinking": ["content": "Correct index", "isStreaming": true]])
        XCTAssertEqual(store.messages[1].thinking, "Correct index")
        XCTAssertEqual(store.rows, NativeChatMessageStore.buildRows(from: store.messages, previousRows: store.rows))
    }

    private final class Cache: RipulSessionCache {
        let userDefaults = UserDefaults(suiteName: "io.ripul.thermal-tests.\(UUID())")!
        var values: [String: Any] = [:]
        var writes: [String] = []
        func data(forKey key: String) -> Data? { values[key] as? Data }
        func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
        func dictionary(forKey key: String) -> [String: Any]? { values[key] as? [String: Any] }
        func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
        func object(forKey key: String) -> Any? { values[key] }
        func set(_ value: Any?, forKey key: String) { values[key] = value; writes.append(key) }
        func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    }

    func testDuplicateWireActivityDoesNotPersistAndOlderCorrectionStillLands() async throws {
        let bridge = AgentBridge()
        let cache = Cache()
        let model = RipulSessionListModel(bridge: bridge, tokenProvider: { nil }, cache: cache)
        var activities = 0
        let sink = bridge.latestActivitySubject.sink { _ in activities += 1 }
        defer { sink.cancel(); withExtendedLifetime(model) {} }
        let timestamp = Date().timeIntervalSince1970 * 1000
        func activity(_ time: Double) {
            bridge.handleMessage(["type": "agent-framework:agent:activity", "chatId": "chat", "timestamp": time, "event": ["kind": "thinking"]])
        }
        activity(timestamp)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(cache.writes.contains("ripulLastActiveTimeByChatId"))
        cache.writes.removeAll()
        for _ in 0..<100 { activity(timestamp) }
        try await Task.sleep(for: .milliseconds(2100))
        XCTAssertTrue(cache.writes.isEmpty)
        XCTAssertEqual(activities, 1)
        activity(timestamp - 1000)
        XCTAssertEqual(bridge.sessionList.lastActiveTimeByChatId["chat"], Date(timeIntervalSince1970: (timestamp - 1000) / 1000))
    }

    func testEqualTimestampsAndActivityDoNotPublishButCorrectionsDo() async throws {
        let store = SessionListStore()
        let timestamp = Date(timeIntervalSince1970: 100)
        store.lastActiveTimeByChatId["chat"] = timestamp
        store.latestActivityByChatId["chat"] = .thinking
        try await Task.sleep(for: .milliseconds(300)) // drain the existing coalescer
        // The store is @Observable, read per chat through its cell: count the
        // first change a reader of this chat's row would see.
        final class Count: @unchecked Sendable { var value = 0 }
        let publications = Count()
        let cell = store.cell("chat")
        withObservationTracking {
            _ = cell.lastActive
            _ = cell.latestActivity
            _ = store.recencyRevision
        } onChange: { publications.value += 1 }
        var timestampWrites = 0
        let b = store.lastActiveTimeSubject.sink { _ in timestampWrites += 1 }
        defer { b.cancel() }
        for _ in 0..<100 {
            store.lastActiveTimeByChatId["chat"] = timestamp
            store.latestActivityByChatId["chat"] = .thinking
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(publications.value, 0)
        XCTAssertEqual(timestampWrites, 0)
        store.lastActiveTimeByChatId["chat"] = timestamp.addingTimeInterval(-10)
        XCTAssertEqual(timestampWrites, 1, "Authoritative downward corrections must survive")
        XCTAssertEqual(publications.value, 1)
    }

    func testCancelledPlaybackWaitExitsWithoutAnotherPollOrCompletion() async throws {
        var polls = 0
        var completed = false
        let task = Task {
            do {
                _ = try await VoiceReplyWait.untilPlaybackEnds { polls += 1; return true }
                completed = true
            } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        }
        while polls == 0 { await Task.yield() }
        task.cancel()
        await task.value
        XCTAssertEqual(polls, 1)
        XCTAssertFalse(completed)
    }

    func testMissingPlaybackCallbackTimesOutAndNormalCompletionReturns() async throws {
        let expired = try await VoiceReplyWait.untilPlaybackEnds(timeout: .milliseconds(5), pollInterval: .milliseconds(1)) { true }
        XCTAssertFalse(expired)
        var pending = true
        let task = Task { try await VoiceReplyWait.untilPlaybackEnds(pollInterval: .milliseconds(1)) { pending } }
        await Task.yield()
        pending = false
        let finished = try await task.value
        XCTAssertTrue(finished)
    }

    func testHistoryBatchPublishesOnceAndIdenticalUpdatesDoNotPublish() {
        let store = NativeChatMessageStore()
        let entries: [[String: Any]] = (0..<100).map { ["messageId": "\($0)", "content": "Reply \($0)", "timestamp": 123.0] }
        var publications = 0
        let observation = store.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }
        store.applyBackfill(entries)
        XCTAssertEqual(store.messages.count, 100)
        XCTAssertEqual(publications, 1)
        store.applyBackfill(entries)
        for _ in 0..<100 { store.applyAdd(entries[0]) }
        XCTAssertEqual(publications, 1)
        store.applyUpdate(["messageId": "0", "thinking": ["content": "Working", "isStreaming": true]])
        for _ in 0..<100 { store.applyUpdate(["messageId": "0", "thinking": ["content": "Working", "isStreaming": true]]) }
        XCTAssertEqual(publications, 2)
        XCTAssertEqual(store.messages[0].thinking, "Working")
        store.applyAdd(entries[0])
        XCTAssertTrue(store.messages[0].isThinkingStreaming)
        XCTAssertEqual(publications, 2)
    }

    // One store change, one publication (chat sync plan, step 3): a page of
    // history or a batch of rows used to arrive as the whole chat.
    func testPatchAppliesOneChangeInOnePublication() {
        let store = NativeChatMessageStore()
        store.applyBackfill([
            ["messageId": "r3", "content": "Three", "timestamp": 3000.0],
            ["messageId": "r4", "content": "Four", "timestamp": 4000.0],
        ], chatId: "chat")
        var publications = 0
        let observation = store.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }

        // An older page lands above, in order, in one publication.
        store.applyPatch([
            ["messageId": "r1", "content": "One", "timestamp": 1000.0],
            ["messageId": "r2", "content": "Two", "timestamp": 2000.0],
        ], truncatedCount: 7, chatId: "chat")
        XCTAssertEqual(store.messages.map(\.id), ["r1", "r2", "r3", "r4"])
        XCTAssertEqual(store.truncatedCount, 7)
        XCTAssertEqual(publications, 1)

        // The same patch again changes nothing and publishes nothing.
        store.applyPatch([
            ["messageId": "r1", "content": "One", "timestamp": 1000.0],
            ["messageId": "r2", "content": "Two", "timestamp": 2000.0],
        ], truncatedCount: 7, chatId: "chat")
        XCTAssertEqual(publications, 1)

        // A changed row, a removed one and a new one together: still one.
        store.applyPatch([
            ["messageId": "r4", "content": "Four, edited", "timestamp": 4000.0],
            ["messageId": "r5", "content": "Five", "timestamp": 5000.0],
        ], removedIds: ["r2"], truncatedCount: 7, chatId: "chat")
        XCTAssertEqual(store.messages.map(\.id), ["r1", "r3", "r4", "r5"])
        XCTAssertEqual(store.messages[2].content, "Four, edited")
        XCTAssertEqual(publications, 2)

        // Streaming thinking survives a patched copy that does not carry it.
        store.applyUpdate(["messageId": "r5", "thinking": ["content": "Working", "isStreaming": true]])
        store.applyPatch([["messageId": "r5", "content": "Five", "timestamp": 5000.0]], truncatedCount: 7, chatId: "chat")
        XCTAssertEqual(store.messages.last?.thinking, "Working")
        XCTAssertTrue(store.messages.last?.isThinkingStreaming ?? false)

        // A patch meant for another chat is not mixed into this one.
        store.applyPatch([["messageId": "x1", "content": "Elsewhere", "timestamp": 6000.0]], chatId: "other")
        XCTAssertFalse(store.messages.contains { $0.id == "x1" })
    }

    func testPatchIntoAnEmptyStoreIsTheFirstWindow() {
        let store = NativeChatMessageStore()
        store.applyPatch([
            ["messageId": "b", "content": "Two", "timestamp": 2000.0],
            ["messageId": "a", "content": "One", "timestamp": 1000.0],
        ], truncatedCount: 3, chatId: "chat")
        XCTAssertEqual(store.messages.map(\.id), ["a", "b"])
        XCTAssertEqual(store.currentChatId, "chat")
        XCTAssertEqual(store.truncatedCount, 3)
    }

    func testNativeChatRowGroupingAndInteractiveState() {
        let store = NativeChatMessageStore()
        let t0: Double = 1_710_000_000_000
        let tLater: Double = t0 + (3 * 3_600_000) // +3 hours -> triggers gap before user message

        let entries: [[String: Any]] = [
            [
                "messageId": "u1",
                "chatId": "chat-1",
                "role": "user",
                "kind": "user",
                "content": "Inspect the auth service",
                "timestamp": t0,
                "contextTags": [["id": "tag-1", "tagName": "ide_opened_file", "label": "Auth.swift", "content": "/src/Auth.swift"]],
                "replyQuote": ["correlationId": "prev-1", "senderDisplayName": "Claude", "excerpt": "Ready to inspect"],
            ],
            [
                "messageId": "tool-1",
                "chatId": "chat-1",
                "role": "tool",
                "kind": "toolCall",
                "toolName": "Read",
                "toolStatus": "success",
                "timestamp": t0 + 1_000,
                "toolCall": [
                    "id": "tool-1",
                    "toolName": "Read",
                    "label": "Read",
                    "rendererName": "Read",
                    "symbol": "doc.text",
                    "status": "success",
                    "timestamp": t0 + 1_000,
                    "arguments": "{\"file_path\":\"/src/Auth.swift\"}",
                    "result": "struct Auth {}",
                    "diagnostics": "{}",
                ] as [String: Any],
            ],
            [
                "messageId": "tool-2",
                "chatId": "chat-1",
                "role": "tool",
                "kind": "toolCall",
                "toolName": "Read",
                "toolStatus": "success",
                "timestamp": t0 + 2_000,
                "toolCall": [
                    "id": "tool-2",
                    "toolName": "Read",
                    "label": "Read",
                    "rendererName": "Read",
                    "symbol": "doc.text",
                    "status": "success",
                    "timestamp": t0 + 2_000,
                    "arguments": "{\"file_path\":\"/src/Token.swift\"}",
                    "result": "struct Token {}",
                    "diagnostics": "{}",
                ] as [String: Any],
            ],
            [
                "messageId": "tool-bash",
                "chatId": "chat-1",
                "role": "tool",
                "kind": "toolCall",
                "toolName": "Bash",
                "toolStatus": "success",
                "timestamp": t0 + 3_000,
                "toolCall": [
                    "id": "tool-bash",
                    "toolName": "Bash",
                    "label": "Swift",
                    "rendererName": "terminal",
                    "symbol": "swift",
                    "status": "success",
                    "timestamp": t0 + 3_000,
                    "arguments": "{\"command\":\"swift test\"}",
                    "result": "Passed",
                    "diagnostics": "{}",
                ] as [String: Any],
            ],
            [
                "messageId": "a1",
                "chatId": "chat-1",
                "role": "assistant",
                "kind": "askUser",
                "content": "",
                "timestamp": t0 + 4_000,
                "respondent": [
                    "label": "Opus 4.6",
                    "modelId": "claude-opus-4-6",
                    "provider": "anthropic",
                    "contextTokens": 42_000,
                    "contextWindow": 200_000,
                    "contextPercent": 21,
                    "isRewindable": true,
                ] as [String: Any],
                "askUser": [
                    "question": "Which token store should we use?",
                    "options": [
                        ["label": "Keychain", "value": "keychain", "description": "Hardware-backed"],
                        ["label": "In-Memory", "value": "memory", "description": "Ephemeral"],
                    ],
                    "multiSelect": false,
                    "completed": false,
                    "responseKey": "rk-1",
                ] as [String: Any],
            ],
            [
                "messageId": "ans-hidden",
                "chatId": "chat-1",
                "role": "user",
                "kind": "user",
                "content": "Keychain",
                "timestamp": t0 + 5_000,
                "hiddenInChat": true,
                "mergedIntoQuestionId": "a1",
            ],
            [
                "messageId": "u2",
                "chatId": "chat-1",
                "role": "user",
                "kind": "user",
                "content": "Follow up after break",
                "timestamp": tLater,
            ],
            [
                "messageId": "cli-1",
                "chatId": "chat-1",
                "role": "system",
                "kind": "cliEvent",
                "content": "",
                "timestamp": tLater + 1_000,
                "cliEvent": [
                    "kind": "vcs",
                    "label": "git commit",
                    "detail": "feat: add keychain store",
                    "accent": "success",
                    "chips": ["abc1234"],
                ] as [String: Any],
            ],
        ]

        store.applyBackfill(entries)

        // Expected rows:
        // 0: .user(u1)
        // 1: .toolGroup (compacts tool-1, tool-2, tool-bash into 2 lozenges: Swift(1), Read(2))
        // 2: .assistant(a1)
        // (ans-hidden is filtered out!)
        // 3: .gap (3 hours elapsed before u2)
        // 4: .user(u2)
        // 5: .cliEvent(cli-1)
        XCTAssertEqual(store.rows.count, 6)

        if case .user(let u1) = store.rows[0] {
            XCTAssertEqual(u1.replyQuote?.correlationId, "prev-1")
            XCTAssertEqual(u1.contextTags.first?.label, "Auth.swift")
        } else {
            XCTFail("Expected row 0 to be .user")
        }

        if case .toolGroup(let group) = store.rows[1] {
            XCTAssertEqual(group.calls.count, 3)
            XCTAssertEqual(group.tools.count, 2, "Two Read calls and one Swift call should compact to 2 lozenges")
            XCTAssertEqual(group.tools.first?.label, "Swift")
            XCTAssertEqual(group.tools.last?.label, "Read")
            XCTAssertEqual(group.tools.last?.count, 2)
        } else {
            XCTFail("Expected row 1 to be .toolGroup")
        }

        if case .assistant(let a1) = store.rows[2] {
            XCTAssertEqual(a1.respondent?.label, "Opus 4.6")
            XCTAssertEqual(a1.respondent?.contextPercent, 21)
            XCTAssertEqual(a1.askUser?.completed, false)
        } else {
            XCTFail("Expected row 2 to be .assistant")
        }

        if case .gap(let gap) = store.rows[3] {
            XCTAssertTrue(gap.text.contains("hour"), "Expected 3 hour gap label, got \(gap.text)")
        } else {
            XCTFail("Expected row 3 to be .gap")
        }

        // Now mark question a1 as answered and verify row updates in place
        store.markQuestionAnswered(messageId: "a1", answer: "Keychain", selectedValues: ["keychain"])
        if case .assistant(let updatedA1) = store.rows[2] {
            XCTAssertEqual(updatedA1.askUser?.completed, true)
            XCTAssertEqual(updatedA1.askUser?.answer, "Keychain")
            XCTAssertEqual(updatedA1.askUser?.selectedValues, ["keychain"])
        } else {
            XCTFail("Expected row 2 to remain .assistant after answering")
        }
    }

    @MainActor
    func testScrollRestorationEmitsOnlyOnToggleAndKeepsRowIdsStable() {
        let store = NativeChatMessageStore()
        var restoredPositions: [NativeChatScrollPosition] = []
        let sub = store.scrollCommands.sink { cmd in
            if case .restore(let pos) = cmd {
                restoredPositions.append(pos)
            }
        }
        defer { sub.cancel() }

        let initialEntries: [[String: Any]] = [
            [
                "messageId": "tool-2",
                "chatId": "chat-1",
                "role": "assistant",
                "method": "Read",
                "timestamp": 2_000.0,
                "toolCall": [
                    "id": "tool-2",
                    "toolName": "Read",
                    "label": "Read",
                    "rendererName": "Read",
                    "status": "completed",
                ] as [String: Any],
            ],
            [
                "messageId": "turn-1",
                "chatId": "chat-1",
                "role": "assistant",
                "method": "llmRequest",
                "content": "",
                "timestamp": 3_000.0,
                "thinking": [
                    "content": "Reasoning about scroll anchors…",
                    "isStreaming": true,
                ] as [String: Any],
            ],
        ]

        // 1. Entering a chat opens it at its end: the page's saved place is not restored.
        store.applyBackfill(
            initialEntries,
            chatId: "chat-1",
            scrollPosition: ["rowId": "turn-1", "offset": 18.0, "following": false]
        )
        XCTAssertEqual(restoredPositions.count, 0, "Entering a chat must not restore its saved place")
        XCTAssertNil(store.pendingScrollRestoration)
        XCTAssertEqual(store.lastScrollSnapshot?.following, true)
        XCTAssertEqual(store.rows.map(\.id), ["toolGroup:tool-2", "turn-1"])

        // 2. Identical backfill or mid-session catch-up backfill on the same chat does NOT emit .restore,
        //    keeps toolGroup ID stable when an earlier tool call is prepended, and keeps turn-1 ID stable
        //    when prose content arrives after thinking.
        store.applyBackfill(
            initialEntries,
            chatId: "chat-1",
            scrollPosition: ["rowId": "turn-1", "offset": 18.0, "following": false]
        )
        XCTAssertEqual(restoredPositions.count, 0, "No-op backfill must not emit .restore")

        let catchUpEntries: [[String: Any]] = [
            [
                "messageId": "tool-1",
                "chatId": "chat-1",
                "role": "assistant",
                "method": "Read",
                "timestamp": 1_000.0,
                "toolCall": [
                    "id": "tool-1",
                    "toolName": "Read",
                    "label": "Read",
                    "rendererName": "Read",
                    "status": "completed",
                ] as [String: Any],
            ],
            initialEntries[0],
            [
                "messageId": "turn-1",
                "chatId": "chat-1",
                "role": "assistant",
                "method": "llmRequest",
                "content": "Final answer prose.",
                "timestamp": 3_000.0,
                "thinking": [
                    "content": "Reasoning about scroll anchors…",
                    "isStreaming": false,
                ] as [String: Any],
            ],
        ]
        store.applyBackfill(
            catchUpEntries,
            truncatedCount: 15,
            chatId: "chat-1",
            scrollPosition: ["rowId": "turn-1", "offset": 99.0, "following": false]
        )
        XCTAssertEqual(restoredPositions.count, 0, "Mid-session catch-up backfill must not emit .restore")
        XCTAssertEqual(
            store.rows.map(\.id),
            ["toolGroup:tool-2", "turn-1"],
            "Prepending tool-1 into existing toolGroup and transitioning turn-1 from thinking to prose must preserve row IDs"
        )

        // 3. Explicit web->native toggle restore emits .restore even on the same chat
        store.markAwaitingWebToggleRestore()
        store.applyBackfill(
            catchUpEntries,
            truncatedCount: 15,
            chatId: "chat-1",
            scrollPosition: ["rowId": "turn-1", "offset": 42.0, "following": false]
        )
        XCTAssertEqual(restoredPositions.count, 1)
        XCTAssertEqual(restoredPositions.last?.offset, 42.0)

        // 4. Cold chat switch: the switch-time backfill arrives empty with the page's saved
        //    place, then the hydration backfill arrives with rows. Entering it opens at its end,
        //    so neither restores.
        store.applyBackfill(
            [],
            chatId: "chat-cold",
            scrollPosition: ["rowId": "turn-1", "offset": 31.0, "following": false]
        )
        XCTAssertNil(store.pendingScrollRestoration, "Entering a cold chat must not keep its saved place")
        let hydratedCold: [[String: Any]] = [
            [
                "messageId": "turn-1",
                "chatId": "chat-cold",
                "role": "assistant",
                "method": "llmRequest",
                "content": "Hydrated cold chat reply.",
                "timestamp": 5_000.0,
            ],
        ]
        store.applyBackfill(hydratedCold, chatId: "chat-cold", scrollPosition: nil)
        XCTAssertEqual(restoredPositions.count, 1, "Hydrating an entered chat must not restore a place")

        // 5. Turning Native Chat on over a chat still loading: the web chat's place is kept
        //    across the empty backfill and restored once on the first non-empty one.
        store.markAwaitingWebToggleRestore()
        store.applyBackfill(
            [],
            chatId: "chat-toggle",
            scrollPosition: ["rowId": "turn-1", "offset": 31.0, "following": false]
        )
        XCTAssertEqual(restoredPositions.count, 1, "An empty toggle backfill must hold the place until rows exist")
        XCTAssertEqual(store.pendingScrollRestoration?.offset, 31.0)
        store.applyBackfill(
            hydratedCold.map { entry in entry.merging(["chatId": "chat-toggle"]) { _, new in new } },
            chatId: "chat-toggle",
            scrollPosition: nil
        )
        XCTAssertEqual(restoredPositions.count, 2, "First non-empty backfill after the toggle must restore the held place")
        XCTAssertEqual(restoredPositions.last?.chatId, "chat-toggle")
        XCTAssertEqual(restoredPositions.last?.offset, 31.0)
        XCTAssertEqual(
            store.pendingScrollRestoration?.offset,
            31.0,
            "pendingScrollRestoration remains available in store until NativeChatView consumes it on mount"
        )

        // 6. Splitting an existing toolGroup (either when the second tool call gains thinking or when a
        //    mid-list message lands between the two tool calls by timestamp) must never produce duplicate row IDs.
        store.applyBackfill(
            [
                [
                    "messageId": "t1",
                    "chatId": "chat-split",
                    "role": "assistant",
                    "method": "Read",
                    "timestamp": 1_000.0,
                    "toolCall": [
                        "id": "t1",
                        "toolName": "Read",
                        "label": "Read",
                        "rendererName": "Read",
                        "status": "completed",
                    ] as [String: Any],
                ],
                [
                    "messageId": "t2",
                    "chatId": "chat-split",
                    "role": "assistant",
                    "method": "Bash",
                    "timestamp": 2_000.0,
                    "toolCall": [
                        "id": "t2",
                        "toolName": "Bash",
                        "label": "Bash",
                        "rendererName": "Bash",
                        "status": "completed",
                    ] as [String: Any],
                ],
            ],
            chatId: "chat-split"
        )
        XCTAssertEqual(store.rows.map(\.id), ["toolGroup:t1"])

        // 5a. Split via thinking attached to t2
        store.applyUpdate([
            "messageId": "t2",
            "chatId": "chat-split",
            "thinking": [
                "content": "Checking command result…",
                "isStreaming": false,
            ] as [String: Any],
        ])
        let splitByThinkingIds = store.rows.map(\.id)
        XCTAssertEqual(splitByThinkingIds, ["toolGroup:t1", "thinking:t2", "toolGroup:t2"])
        XCTAssertEqual(Set(splitByThinkingIds).count, splitByThinkingIds.count, "Row IDs must be unique after thinking split")

        // 5b. Re-merge into one group, then split via mid-list message inserted by timestamp between t1 and t2
        store.applyBackfill(
            [
                [
                    "messageId": "t1",
                    "chatId": "chat-split",
                    "role": "assistant",
                    "method": "Read",
                    "timestamp": 1_000.0,
                    "toolCall": [
                        "id": "t1",
                        "toolName": "Read",
                        "label": "Read",
                        "rendererName": "Read",
                        "status": "completed",
                    ] as [String: Any],
                ],
                [
                    "messageId": "t2",
                    "chatId": "chat-split",
                    "role": "assistant",
                    "method": "Bash",
                    "timestamp": 2_000.0,
                    "toolCall": [
                        "id": "t2",
                        "toolName": "Bash",
                        "label": "Bash",
                        "rendererName": "Bash",
                        "status": "completed",
                    ] as [String: Any],
                ],
            ],
            chatId: "chat-split"
        )
        XCTAssertEqual(store.rows.map(\.id), ["toolGroup:t1"])

        store.applyAdd([
            "messageId": "mid-msg",
            "chatId": "chat-split",
            "role": "assistant",
            "content": "Interleaved assistant note",
            "timestamp": 1_500.0,
        ])
        let splitByMidMessageIds = store.rows.map(\.id)
        XCTAssertEqual(splitByMidMessageIds, ["toolGroup:t1", "mid-msg", "toolGroup:t2"])
        XCTAssertEqual(Set(splitByMidMessageIds).count, splitByMidMessageIds.count, "Row IDs must be unique after mid-list split")
    }

    @MainActor
    func testNativeChatRowContainerEquatabilityAndTargetedInvalidation() {
        let store = NativeChatMessageStore()
        let actions = NativeChatRowActions()
        let entries: [[String: Any]] = (0..<10).map { i in
            [
                "messageId": "m-\(i)",
                "chatId": "chat-eq",
                "role": i.isMultiple(of: 2) ? "user" : "assistant",
                "content": "Message \(i) with ```swift\nlet x = \(i)\n```",
                "timestamp": Double(i * 1000 + 1000),
            ]
        }
        store.applyBackfill(entries, chatId: "chat-eq")
        XCTAssertEqual(store.rows.count, 10)

        let beforeRows = store.rows.map { row in
            NativeChatRowContainerView(
                row: row,
                isToolbarOpen: false,
                isHighlighted: false,
                store: store,
                bridge: nil,
                actions: actions
            )
        }

        // Update only m-4 (content delta via applyAdd / applyPatch)
        store.applyAdd([
            "messageId": "m-4",
            "chatId": "chat-eq",
            "role": "user",
            "content": "Message 4 updated with ```swift\nlet x = 42\n```",
            "timestamp": 5000.0,
        ])

        let afterRows = store.rows.map { row in
            NativeChatRowContainerView(
                row: row,
                isToolbarOpen: false,
                isHighlighted: false,
                store: store,
                bridge: nil,
                actions: actions
            )
        }

        // Exactly 1 row (`m-4`) should compare unequal; all other 9 rows are Equatable-identical.
        let changedIndices = zip(beforeRows, afterRows).enumerated().compactMap { idx, pair in
            pair.0 == pair.1 ? nil : idx
        }
        XCTAssertEqual(changedIndices, [4], "A single-row store update must invalidate only the modified row")

        // Verify toolbar and highlight flags participate in equality
        let openToolbarRow = NativeChatRowContainerView(
            row: store.rows[4],
            isToolbarOpen: true,
            isHighlighted: false,
            store: store,
            bridge: nil,
            actions: actions
        )
        XCTAssertNotEqual(afterRows[4], openToolbarRow)

        let highlightedRow = NativeChatRowContainerView(
            row: store.rows[4],
            isToolbarOpen: false,
            isHighlighted: true,
            store: store,
            bridge: nil,
            actions: actions
        )
        XCTAssertNotEqual(afterRows[4], highlightedRow)

        // How thinking is shown changes what a row draws, so it must pass the gate
        for mode in [ThinkingDisplayMode.none, .folded] {
            let row = NativeChatRowContainerView(
                row: store.rows[4],
                isToolbarOpen: false,
                isHighlighted: false,
                thinkingMode: mode,
                store: store,
                bridge: nil,
                actions: actions
            )
            XCTAssertNotEqual(afterRows[4], row, "Thinking mode \(mode) must invalidate the row")
        }

        // Verify nested message changes (thinking delta on m-5) participate in equality
        store.applyUpdate([
            "messageId": "m-5",
            "chatId": "chat-eq",
            "thinking": ["content": "Streaming thought", "isStreaming": true] as [String: Any],
        ])
        let afterThinkingRows = store.rows.map { row in
            NativeChatRowContainerView(
                row: row,
                isToolbarOpen: false,
                isHighlighted: false,
                store: store,
                bridge: nil,
                actions: actions
            )
        }
        let thinkingChangedIndices = zip(afterRows, afterThinkingRows).enumerated().compactMap { idx, pair in
            pair.0 == pair.1 ? nil : idx
        }
        XCTAssertEqual(thinkingChangedIndices, [5], "A thinking update on m-5 must mark only row 5 unequal")
    }

    @MainActor
    func testReadingPositionBinarySearchAndO1WebRowIdMap() {
        let store = NativeChatMessageStore()
        let t0: Double = 1_710_000_000_000
        let entries: [[String: Any]] = [
            [
                "messageId": "u1",
                "chatId": "chat-snap",
                "role": "user",
                "content": "First user message",
                "timestamp": t0,
            ],
            [
                "messageId": "tool-1",
                "chatId": "chat-snap",
                "role": "assistant",
                "method": "Read",
                "timestamp": t0 + 1_000,
                "thinking": [
                    "content": "Thinking before tool",
                    "isStreaming": false,
                ] as [String: Any],
                "toolCall": [
                    "id": "tool-1",
                    "toolName": "Read",
                    "label": "Read",
                    "rendererName": "Read",
                    "status": "completed",
                ] as [String: Any],
            ],
            [
                "messageId": "standalone-think",
                "chatId": "chat-snap",
                "role": "assistant",
                "method": "llmRequest",
                "content": "",
                "timestamp": t0 + 2_000,
                "thinking": [
                    "content": "Standalone thinking",
                    "isStreaming": true,
                ] as [String: Any],
            ],
            [
                "messageId": "u2",
                "chatId": "chat-snap",
                "role": "user",
                "content": "After 3 hour gap",
                "timestamp": t0 + (3 * 3_600_000),
            ],
        ]
        store.applyBackfill(entries, chatId: "chat-snap")

        // Verify O(1) webRowId resolution across all row kinds:
        // rows: u1, thinking:tool-1, toolGroup:tool-1, standalone-think, gap:u2, u2
        XCTAssertEqual(store.resolveWebRowId(forNativeRowId: "u1"), "u1")
        XCTAssertEqual(store.resolveWebRowId(forNativeRowId: "thinking:tool-1"), "header_tool-1")
        XCTAssertEqual(store.resolveWebRowId(forNativeRowId: "toolGroup:tool-1"), "header_tool-1")
        XCTAssertEqual(store.resolveWebRowId(forNativeRowId: "standalone-think"), "thinking_standalone-think")
        XCTAssertEqual(store.resolveWebRowId(forNativeRowId: "gap:u2"), "gap_u2")
        XCTAssertEqual(store.resolveWebRowId(forNativeRowId: "u2"), "u2")

        // Verify binary search in NativeChatScrollCoordinator.firstRowIntersecting
        let coordinator = NativeChatScrollCoordinator()
        coordinator.store = store
        var frames: [String: CGRect] = [:]
        for (idx, row) in store.rows.enumerated() {
            let y = CGFloat(idx) * 100.0
            frames[row.id] = CGRect(x: 0, y: y, width: 320, height: 90)
        }
        coordinator.rowFrames = frames
        XCTAssertEqual(coordinator.orderedRowFrames.map(\.id), store.rows.map(\.id))

        // Threshold at y=210 should pick row index 2 (y=200..290, maxY=290 > 210)
        let hit2 = coordinator.firstRowIntersecting(thresholdMaxY: 210)
        XCTAssertEqual(hit2?.id, store.rows[2].id)

        // Threshold at y=290 should advance to row index 3 (since maxY must be strictly > thresholdMaxY)
        let hit3 = coordinator.firstRowIntersecting(thresholdMaxY: 290)
        XCTAssertEqual(hit3?.id, store.rows[3].id)

        // Threshold past all rows returns nil
        XCTAssertNil(coordinator.firstRowIntersecting(thresholdMaxY: 1000))

        // While decelerating (held row publication), if a patch removes the row at index 3 (`standalone-think`)
        // before `rowFrames` / `orderedRowFrames` are updated, `firstRowIntersecting` must skip the stale
        // removed row and return the next row still in `store.rows` (`gap:u2`).
        store.applyPatch([], removedIds: ["standalone-think"], chatId: "chat-snap")
        XCTAssertFalse(store.containsNativeRowId("standalone-think"))
        let hitAfterRemoval = coordinator.firstRowIntersecting(thresholdMaxY: 290, in: store)
        XCTAssertEqual(hitAfterRemoval?.id, "gap:u2", "Stale removed row in orderedRowFrames must be skipped in O(1) via store membership")
    }

    @MainActor
    func testImagePreloaderNotifiesOnlyTargetAttachmentKey() {
        let preloader = NativeChatImagePreloader.shared
        let att1 = NativeChatImageAttachment(id: "img-1", mediaType: "image/png", url: "https://example.com/1.png", width: 100, height: 100)
        let att2 = NativeChatImageAttachment(id: "img-2", mediaType: "image/png", url: "https://example.com/2.png", width: 100, height: 100)

        var receivedFor1 = 0
        var receivedFor2 = 0
        let key1 = preloader.cacheKey(for: att1)
        let key2 = preloader.cacheKey(for: att2)

        let sub1 = preloader.keyLoaded.sink { key in
            if key == key1 { receivedFor1 += 1 }
        }
        let sub2 = preloader.keyLoaded.sink { key in
            if key == key2 { receivedFor2 += 1 }
        }
        defer {
            sub1.cancel()
            sub2.cancel()
        }

        #if os(iOS)
        let sampleImage = UIImage()
        #elseif os(macOS)
        let sampleImage = NSImage(size: NSSize(width: 100, height: 100))
        #endif
        preloader.notifyLoadedForTesting(image: sampleImage, for: att1)
        XCTAssertEqual(receivedFor1, 1)
        XCTAssertEqual(receivedFor2, 0, "Finishing image 1 must not notify listeners for image 2")
    }

    @MainActor
    func testRowStateRegistryPreservesUserStateAndStoresAcrossRemounts() {
        let registry = NativeChatRowStateRegistry(maxEntries: 3)
        var changedRowIds: [String] = []
        registry.onRowStateChanged = { rowId in
            changedRowIds.append(rowId)
        }

        // 1. Default value returned when unset; setting equal value does not bump revision
        XCTAssertEqual(registry.value(forRow: "row-1", component: "thinking.isExpanded", default: false), false)
        XCTAssertEqual(registry.revision(forRow: "row-1"), 0)
        registry.setValue(false, forRow: "row-1", component: "thinking.isExpanded", default: false, affectsHeight: true)
        XCTAssertEqual(registry.revision(forRow: "row-1"), 0)
        XCTAssertTrue(changedRowIds.isEmpty)

        // 2. Setting a height-affecting state persists across remounts and bumps row revision
        registry.setValue(true, forRow: "row-1", component: "thinking.isExpanded", affectsHeight: true)
        XCTAssertEqual(registry.value(forRow: "row-1", component: "thinking.isExpanded", default: false), true)
        XCTAssertEqual(registry.revision(forRow: "row-1"), 1)
        XCTAssertEqual(changedRowIds, ["row-1"])

        // 3. Non-height-affecting state (e.g. unsent multi-select options or date picker) persists without bumping revision
        let selected: Set<String> = ["opt-a", "opt-b"]
        registry.setValue(selected, forRow: "row-1", component: "assistant.multiSelectedValues", affectsHeight: false)
        XCTAssertEqual(registry.value(forRow: "row-1", component: "assistant.multiSelectedValues", default: Set<String>()), selected)
        XCTAssertEqual(registry.revision(forRow: "row-1"), 1, "Non-height state must not bump row revision")

        // 4. Hierarchical scope composition via NativeChatRowStateContext
        let rootCtx = NativeChatRowStateContext(registry: registry, rowId: "row-1", scopePath: "")
        let tabCtx = rootCtx.scoped("tab:1").scoped("code:0")
        XCTAssertEqual(tabCtx.scopedComponentId("codeBlock.visibleLines#swift"), "tab:1/code:0/codeBlock.visibleLines#swift")

        // 5. NativeToolStripStore is cached per row, pre-populated before view subscription, and preserves user expansion
        let messageStore = NativeChatMessageStore()
        messageStore.applyBackfill([
            [
                "messageId": "call-1",
                "chatId": "chat-1",
                "role": "assistant",
                "method": "Bash",
                "timestamp": 1_000.0,
                "toolCall": [
                    "id": "call-1",
                    "toolName": "Bash",
                    "label": "Bash",
                    "rendererName": "terminal",
                    "symbol": "terminal",
                    "status": "completed",
                    "arguments": "{\"command\":\"ls\"}",
                    "result": "ok",
                ] as [String: Any],
            ],
            [
                "messageId": "call-2",
                "chatId": "chat-1",
                "role": "assistant",
                "method": "Read",
                "timestamp": 1_001.0,
                "toolCall": [
                    "id": "call-2",
                    "toolName": "Read",
                    "label": "Read",
                    "rendererName": "Read",
                    "symbol": "doc.text",
                    "status": "completed",
                    "arguments": "{\"path\":\"a.swift\"}",
                    "result": "ok",
                ] as [String: Any],
            ],
        ], chatId: "chat-1")
        guard case .toolGroup(let group) = messageStore.rows.first else {
            return XCTFail("Expected .toolGroup row")
        }
        let store1 = registry.toolStripStore(forRow: group.id, group: group)
        XCTAssertEqual(store1.display?.tools.count, 2, "Tool strip store must be pre-populated synchronously on pass 1")
        XCTAssertTrue(store1.collapsed)
        store1.expand()

        let store2 = registry.toolStripStore(forRow: group.id, group: group)
        XCTAssertTrue(store1 === store2, "Remounting the same toolGroup row must reuse the cached NativeToolStripStore")
        XCTAssertFalse(store2.collapsed, "User expansion of tool strip must survive unmount/remount")
        XCTAssertEqual(registry.revision(forRow: group.id), 1, "Expanding a collapsed tool strip must bump the row revision")

        // 6. LRU eviction when maxEntries (3) is exceeded
        registry.setValue(true, forRow: "row-2", component: "note.isExpanded", affectsHeight: true)
        // Touch row-1/thinking.isExpanded so row-1/assistant.multiSelectedValues is oldest
        _ = registry.value(forRow: "row-1", component: "thinking.isExpanded", default: false)
        registry.setValue(true, forRow: "row-3", component: "error.showDetails", affectsHeight: true)

        XCTAssertEqual(registry.value(forRow: "row-1", component: "thinking.isExpanded", default: false), true, "Recently read entry must remain in registry")
        XCTAssertEqual(registry.value(forRow: "row-1", component: "assistant.multiSelectedValues", default: Set<String>()), Set<String>(), "Least-recently-used entry should be evicted when capacity is exceeded")
    }

    @MainActor
    func testRowStateRegressionFixesForFallbackSubscopesStreamingEvictionAndStaleStores() {
        // 1. Two independent object disclosures with no registry root (fallback mode)
        //    plus equal setters must not increment localRevision.
        let fallbackState = NativeRowState(wrappedValue: false, "value.disclosure")
        XCTAssertFalse(fallbackState.value(subscope: "NativeTool.value:alpha"))
        XCTAssertFalse(fallbackState.value(subscope: "NativeTool.value:beta"))
        XCTAssertEqual(fallbackState.debugLocalRevision, 0)

        // Setting the default value (false) must not bump localRevision
        fallbackState.setValue(false, subscope: "NativeTool.value:alpha")
        XCTAssertEqual(fallbackState.debugLocalRevision, 0)

        // Expanding sibling alpha must not expand sibling beta in fallback mode
        fallbackState.binding(subscope: "NativeTool.value:alpha").wrappedValue = true
        XCTAssertTrue(fallbackState.value(subscope: "NativeTool.value:alpha"))
        XCTAssertFalse(fallbackState.value(subscope: "NativeTool.value:beta"), "Sibling disclosure in fallback mode must remain independent")

        // Setting true again on alpha must not bump localRevision
        let revAfterExpand = fallbackState.debugLocalRevision
        fallbackState.setValue(true, subscope: "NativeTool.value:alpha")
        XCTAssertEqual(fallbackState.debugLocalRevision, revAfterExpand)

        // 2. Expand prose, code, and diff then append streamed text/lines:
        //    scope keys must stay stable so user expansion survives streaming and remount.
        let codeShort = NativeToolCodeBlock(text: "line 1\nline 2", title: "Output")
        let codeStreamed = NativeToolCodeBlock(text: "line 1\nline 2\nline 3\nline 4", title: "Output")
        XCTAssertEqual(codeShort.codeScopeKey, codeStreamed.codeScopeKey, "Streaming text into NativeToolCodeBlock must not change its state key")

        let proseShort = NativeToolProse(text: "Initial paragraph", identifier: "NativeTool.prose")
        let proseStreamed = NativeToolProse(text: "Initial paragraph with more streamed words appended", identifier: "NativeTool.prose")
        XCTAssertEqual(proseShort.proseScopeKey, proseStreamed.proseScopeKey, "Streaming text into NativeToolProse must not change its state key")

        let diffShort = NativeToolDiffView(lines: [NativeToolDiffLine(kind: .added, text: "+a")], path: "Sources/A.swift")
        let diffStreamed = NativeToolDiffView(lines: [NativeToolDiffLine(kind: .added, text: "+a"), NativeToolDiffLine(kind: .added, text: "+b")], path: "Sources/A.swift")
        XCTAssertEqual(diffShort.diffScopeKey, diffStreamed.diffScopeKey, "Appending diff lines into NativeToolDiffView must not change its state key")

        let registry = NativeChatRowStateRegistry(maxEntries: 3)
        var invalidatedRows: [String] = []
        registry.onRowStateChanged = { rowId in
            invalidatedRows.append(rowId)
        }
        registry.setValue(280, forRow: "stream-row", component: "code.visibleLines:\(codeShort.codeScopeKey)", default: 80, affectsHeight: true)
        XCTAssertEqual(
            registry.value(forRow: "stream-row", component: "code.visibleLines:\(codeStreamed.codeScopeKey)", default: 80),
            280,
            "Revealed line count must survive after streaming appends more lines and remounts"
        )
        let streamRowMeasuredRev = registry.revision(forRow: "stream-row")
        XCTAssertEqual(streamRowMeasuredRev, 1)

        // 3. Evicting an expanded row must bump its revision and notify onRowStateChanged
        //    so the height ledger invalidates the stale expanded height.
        registry.setValue(true, forRow: "row-a", component: "thinking.isExpanded", default: false, affectsHeight: true)
        registry.setValue(true, forRow: "row-b", component: "thinking.isExpanded", default: false, affectsHeight: true)
        invalidatedRows.removeAll()

        // Inserting row-c exceeds maxEntries (3) and evicts the oldest entry ("stream-row")
        registry.setValue(true, forRow: "row-c", component: "thinking.isExpanded", default: false, affectsHeight: true)
        XCTAssertEqual(registry.value(forRow: "stream-row", component: "code.visibleLines:\(codeStreamed.codeScopeKey)", default: 80), 80, "Evicted row resets to default value")
        XCTAssertTrue(invalidatedRows.contains("stream-row"), "Evicting a height-affecting state entry must fire onRowStateChanged for that row")
        XCTAssertGreaterThan(registry.revision(forRow: "stream-row"), streamRowMeasuredRev, "Evicting an expanded row must advance its revision so stale measured height is invalidated")

        // 4. Updating a tool group while unmounted must synchronize the reused NativeToolStripStore
        //    before pass-1 layout of remount.
        let messageStore = NativeChatMessageStore()
        messageStore.applyBackfill([
            [
                "messageId": "c1",
                "chatId": "chat-1",
                "role": "assistant",
                "method": "Bash",
                "timestamp": 1_000.0,
                "toolCall": [
                    "id": "c1",
                    "toolName": "Bash",
                    "label": "Bash",
                    "rendererName": "terminal",
                    "symbol": "terminal",
                    "status": "running",
                ] as [String: Any],
            ]
        ], chatId: "chat-1")
        guard case .toolGroup(let initialGroup) = messageStore.rows.first else {
            return XCTFail("Expected initial .toolGroup")
        }
        let stripStore = registry.toolStripStore(forRow: initialGroup.id, group: initialGroup)
        XCTAssertEqual(stripStore.display?.tools.count, 1)
        XCTAssertEqual(stripStore.display?.tools.first?.status, "running")
        // Simulate mount then unmount
        stripStore.present { _ in }
        stripStore.hide()
        XCTAssertFalse(stripStore.isPresented)

        // While unmounted, a second tool call arrives in the same group and both complete
        messageStore.applyBackfill([
            [
                "messageId": "c1",
                "chatId": "chat-1",
                "role": "assistant",
                "method": "Bash",
                "timestamp": 1_000.0,
                "toolCall": [
                    "id": "c1",
                    "toolName": "Bash",
                    "label": "Bash",
                    "rendererName": "terminal",
                    "symbol": "terminal",
                    "status": "completed",
                ] as [String: Any],
            ],
            [
                "messageId": "c2",
                "chatId": "chat-1",
                "role": "assistant",
                "method": "Read",
                "timestamp": 1_002.0,
                "toolCall": [
                    "id": "c2",
                    "toolName": "Read",
                    "label": "Read",
                    "rendererName": "Read",
                    "symbol": "doc.text",
                    "status": "completed",
                ] as [String: Any],
            ],
        ], chatId: "chat-1")
        guard case .toolGroup(let updatedGroup) = messageStore.rows.first else {
            return XCTFail("Expected updated .toolGroup")
        }
        let remountedStore = registry.toolStripStore(forRow: updatedGroup.id, group: updatedGroup)
        XCTAssertTrue(remountedStore === stripStore, "Remount must reuse the cached NativeToolStripStore")
        XCTAssertEqual(remountedStore.display?.tools.count, 2, "Reused store must synchronously reflect the updated group on pass 1 before onAppear")
        XCTAssertEqual(remountedStore.display?.tools.first?.status, "completed")

        // 5. Visiting many rows must bound stripStores, stripSubscriptions, entries, and rowRevisions to maxEntries (3)
        for i in 0..<10 {
            let rowId = "many-group-\(i)"
            let syntheticGroup = NativeChatToolGroup(
                id: rowId,
                chatId: "chat-1",
                updatedAt: Double(2_000 + i),
                tools: updatedGroup.tools,
                callIdsByToolId: updatedGroup.callIdsByToolId,
                taskRuns: [],
                agentComms: [],
                calls: updatedGroup.calls,
                allCallIds: updatedGroup.allCallIds
            )
            _ = registry.toolStripStore(forRow: rowId, group: syntheticGroup)
            registry.setValue(true, forRow: rowId, component: "note.isExpanded", default: false, affectsHeight: true)
        }
        XCTAssertLessThanOrEqual(registry.entryCount, 3, "Scalar entries must be bounded by maxEntries")
        XCTAssertLessThanOrEqual(registry.stripStoreCount, 3, "Cached strip stores must be bounded by maxEntries")
        XCTAssertLessThanOrEqual(registry.stripSubscriptionCount, 3, "Cached strip subscriptions must be disposed and bounded by maxEntries")
        XCTAssertLessThanOrEqual(registry.revisionCount, 3, "Row revisions must be bounded by maxEntries")

        // Evicted revision metadata must preserve monotonicity so HeightKey is never reused.
        let floorAfterEviction = registry.revision(forRow: "many-group-0")
        XCTAssertGreaterThanOrEqual(floorAfterEviction, 2, "Evicted row revision must not regress below its pre-eviction revision")
        registry.setValue(true, forRow: "many-group-0", component: "note.isExpanded", default: false, affectsHeight: true)
        XCTAssertGreaterThan(registry.revision(forRow: "many-group-0"), floorAfterEviction, "Re-mutating an evicted row must strictly advance its revision")
    }

    func testAuthoritativeThinkingSettleAndDirtyRowIds() {
        let store = NativeChatMessageStore()
        store.applyBackfill([
            ["messageId": "m1", "chatId": "chat-1", "role": "user", "content": "Hello", "timestamp": 1000.0],
            ["messageId": "m2", "chatId": "chat-1", "role": "assistant", "content": "", "thinking": ["content": "Step 1", "isStreaming": true], "timestamp": 2000.0],
        ], chatId: "chat-1")
        _ = store.consumeDirtyRowIds()
        XCTAssertTrue(store.messages[1].isThinkingStreaming)
        XCTAssertEqual(store.messages[1].thinking, "Step 1")

        // Streaming thinking delta updates in-place and records dirty thinking row ID
        store.applyUpdate(["messageId": "m2", "thinking": ["content": "Step 1 + 2", "isStreaming": true]])
        XCTAssertEqual(store.consumeDirtyRowIds(), ["m2"])
        XCTAssertEqual(store.messages[1].thinking, "Step 1 + 2")
        XCTAssertTrue(store.messages[1].isThinkingStreaming)

        // Newer message being added alone does NOT settle m2's streaming thinking (only authoritative state does)
        store.applyPatch([
            ["messageId": "m3", "chatId": "chat-1", "role": "assistant", "content": "Working on it", "timestamp": 3000.0],
        ], chatId: "chat-1")
        XCTAssertTrue(store.messages[1].isThinkingStreaming)
        XCTAssertEqual(store.consumeDirtyRowIds(), ["m3"])

        // Content delta on m3 uses in-place fast path and reports only m3 dirty
        store.applyPatch([
            ["messageId": "m3", "chatId": "chat-1", "role": "assistant", "content": "Working on it...", "timestamp": 3000.0],
        ], chatId: "chat-1")
        XCTAssertEqual(store.consumeDirtyRowIds(), ["m3"])

        // Authoritative terminal status on m2 settles isThinkingStreaming while preserving accumulated thinking text
        store.applyPatch([
            ["messageId": "m2", "chatId": "chat-1", "role": "assistant", "content": "", "status": "complete", "timestamp": 2000.0],
        ], chatId: "chat-1")
        XCTAssertFalse(store.messages[1].isThinkingStreaming)
        XCTAssertEqual(store.messages[1].thinking, "Step 1 + 2")
        XCTAssertEqual(store.consumeDirtyRowIds(), ["m2"])

        // Turn-end signal settleStreaming(chatId:) settles any remaining streaming thinking in that chat
        store.applyUpdate(["messageId": "m3", "thinking": ["content": "Finalizing", "isStreaming": true]])
        _ = store.consumeDirtyRowIds()
        XCTAssertTrue(store.messages[2].isThinkingStreaming)
        store.settleStreaming(chatId: "other-chat")
        XCTAssertTrue(store.messages[2].isThinkingStreaming, "settleStreaming for another chat must not settle chat-1")
        store.settleStreaming(chatId: "chat-1")
        XCTAssertFalse(store.messages[2].isThinkingStreaming)
        XCTAssertEqual(store.messages[2].thinking, "Finalizing")
        XCTAssertEqual(store.consumeDirtyRowIds(), ["m3"])
    }

    @MainActor
    func testMarkerFramesSentinelStabilityAndCoherenceValidation() {
        let store = NativeChatMessageStore()
        store.applyBackfill([
            ["messageId": "u1", "chatId": "c1", "role": "user", "content": "Hello", "timestamp": 1000.0],
            ["messageId": "t1", "chatId": "c1", "role": "assistant", "content": "", "thinking": ["content": "Thinking", "isStreaming": true], "timestamp": 1500.0],
            ["messageId": "a1", "chatId": "c1", "role": "assistant", "content": "Part 1", "timestamp": 2000.0],
        ], chatId: "c1")
        _ = store.consumeDirtyRowIds()

        let band = NativeChatWindowBand(rows: [])
        let coordinator = band.coordinator
        coordinator.windowEnabled = true
        coordinator.useMarkerFrames = true

        // 1. Initial mount is a structure change (disabled -> enabled) and sets serial = 1
        coordinator.updateWindowRows(store.rows)
        XCTAssertTrue(band.snapshot.enabled)
        XCTAssertEqual(band.snapshot.serial, 1)
        XCTAssertEqual(band.snapshot.rows.map(\.id), ["u1", "t1", "a1"])

        // 2. Pure data delta (streaming text into a1 without changing mounted row IDs or fillers)
        //    must update snapshot.rows while keeping snapshot.serial == 1.
        store.applyPatch([
            ["messageId": "a1", "chatId": "c1", "role": "assistant", "content": "Part 1 + Part 2", "timestamp": 2000.0],
        ], chatId: "c1")
        coordinator.updateWindowRows(store.rows, dirtyRowIDs: store.consumeDirtyRowIds())
        XCTAssertEqual(band.snapshot.serial, 1, "Pure data delta inside unchanged band must not bump sentinel serial when markerFrames is enabled")
        if case .assistant(let msg) = band.snapshot.rows[2] {
            XCTAssertEqual(msg.content, "Part 1 + Part 2")
        } else {
            XCTFail("Expected updated assistant row")
        }

        // 3. Adding a new row changes band membership and MUST bump snapshot.serial
        store.applyPatch([
            ["messageId": "a2", "chatId": "c1", "role": "assistant", "content": "Follow-up", "timestamp": 3000.0],
        ], chatId: "c1")
        coordinator.updateWindowRows(store.rows, dirtyRowIDs: store.consumeDirtyRowIds())
        XCTAssertEqual(band.snapshot.serial, 2, "Band membership change must increment sentinel serial")

        // 4. Coherent-pass verification for marker frames:
        //    4 rows (u1: 40pt, t1 folded thinking: 28pt narrow capsule width 120, a1: 80pt, a2: 50pt)
        //    with 10pt VStack spacing -> total height = 40 + 10 + 28 + 10 + 80 + 10 + 50 = 228pt.
        let containerFrames: [String: CGRect] = [
            "__rows": CGRect(x: 0, y: 12, width: 320, height: 228),
            "__content": CGRect(x: 0, y: 0, width: 320, height: 240),
            "__window:2": .zero,
        ]
        let coherentMarkers: [String: CGRect] = [
            "u1": CGRect(x: 0, y: 12, width: 320, height: 40),
            "t1": CGRect(x: 0, y: 62, width: 120, height: 28), // folded thinking lozenge is narrower than 320
            "a1": CGRect(x: 0, y: 100, width: 320, height: 80),
            "a2": CGRect(x: 0, y: 190, width: 320, height: 50),
        ]
        XCTAssertTrue(
            coordinator.areMarkerFramesCoherent(frames: coherentMarkers, allFrames: containerFrames),
            "Contiguous 10pt-spaced markers matching __rows bounds (including narrow folded thinking) must be coherent"
        )

        // Unshifted subsequent marker after a1 grew by +20pt (__rows height is 248, but a2 is still at y=190) must be rejected
        let containerAfterGrowth: [String: CGRect] = [
            "__rows": CGRect(x: 0, y: 12, width: 320, height: 248),
            "__content": CGRect(x: 0, y: 0, width: 320, height: 260),
            "__window:2": .zero,
        ]
        var partiallyUpdatedMarkers = coherentMarkers
        partiallyUpdatedMarkers["a1"] = CGRect(x: 0, y: 100, width: 320, height: 100)
        XCTAssertFalse(
            coordinator.areMarkerFramesCoherent(frames: partiallyUpdatedMarkers, allFrames: containerAfterGrowth),
            "Marker pass where a1 grew but a2 has not yet shifted down must be rejected as incoherent"
        )

        // Stale width on a full-width row after container resized from 320 -> 390 must be rejected
        let resizedContainer: [String: CGRect] = [
            "__rows": CGRect(x: 0, y: 12, width: 390, height: 228),
            "__content": CGRect(x: 0, y: 0, width: 390, height: 240),
            "__window:2": .zero,
        ]
        XCTAssertFalse(
            coordinator.areMarkerFramesCoherent(frames: coherentMarkers, allFrames: resizedContainer),
            "Stale pre-resize marker widths must be rejected when __rows width has changed"
        )

        // When thinkingMode == .none, t1 renders EmptyView (no slot, no marker, 0 height and 0 spacing):
        // total height = 40 + 10 + 80 + 10 + 50 = 190pt.
        let containerWithHiddenThinking: [String: CGRect] = [
            "__rows": CGRect(x: 0, y: 12, width: 320, height: 190),
            "__content": CGRect(x: 0, y: 0, width: 320, height: 202),
            "__window:2": .zero,
        ]
        let markersWithHiddenThinking: [String: CGRect] = [
            "u1": CGRect(x: 0, y: 12, width: 320, height: 40),
            "a1": CGRect(x: 0, y: 62, width: 320, height: 80),
            "a2": CGRect(x: 0, y: 152, width: 320, height: 50),
        ]
        XCTAssertTrue(
            coordinator.areMarkerFramesCoherent(frames: markersWithHiddenThinking, allFrames: containerWithHiddenThinking),
            "Zero-slot EmptyView row must be accepted when remaining markers account for the exact __rows height"
        )
    }

    @MainActor
    func testToolGroupSplitAndPlaceholderReorderNeverProduceDuplicateRowIDs() {
        let store = NativeChatMessageStore()
        let band = NativeChatWindowBand(rows: [])
        let coordinator = band.coordinator
        coordinator.windowEnabled = true
        coordinator.useMarkerFrames = true

        // Scenario A: call-2 arrives first, then call-1 arrives via update-before-add placeholder
        // at a later arrival timestamp (30.0) and is then corrected to its earlier persisted
        // timestamp (10.0), merging into [call-1, call-2] with group.id == "call-2".
        // When call-2 subsequently gets thinking (or an assistant message lands between them),
        // the group splits into [call-1] and [call-2] — neither may steal the other's group ID.
        store.applyBackfill([
            ["messageId": "call-2", "chatId": "c1", "role": "assistant", "content": "", "method": "Bash", "timestamp": 20.0],
        ], chatId: "c1")
        coordinator.updateWindowRows(store.rows, dirtyRowIDs: store.consumeDirtyRowIds())
        XCTAssertEqual(store.rows.map(\.id), ["toolGroup:call-2"])

        store.applyUpdate([
            "messageId": "call-1",
            "chatId": "c1",
            "timestamp": 30.0,
            "thinking": ["content": "", "isStreaming": false],
        ])
        coordinator.updateWindowRows(store.rows, dirtyRowIDs: store.consumeDirtyRowIds())

        store.applyAdd([
            "messageId": "call-1",
            "chatId": "c1",
            "role": "assistant",
            "content": "",
            "method": "Bash",
            "timestamp": 10.0,
        ])
        coordinator.updateWindowRows(store.rows, dirtyRowIDs: store.consumeDirtyRowIds())
        XCTAssertEqual(store.rows.map(\.id), ["toolGroup:call-2"])

        // Now call-2 receives a thinking delta, splitting [call-1, call-2] into [call-1], thinking:call-2, [call-2]
        store.applyUpdate([
            "messageId": "call-2",
            "chatId": "c1",
            "timestamp": 20.0,
            "thinking": ["content": "Reasoning before second tool", "isStreaming": true],
        ])
        let rowIDsAfterThinkingSplit = store.rows.map(\.id)
        XCTAssertEqual(Set(rowIDsAfterThinkingSplit).count, rowIDsAfterThinkingSplit.count, "Split tool groups must have unique row IDs")
        XCTAssertEqual(rowIDsAfterThinkingSplit, ["toolGroup:call-1", "thinking:call-2", "toolGroup:call-2"])
        coordinator.updateWindowRows(store.rows, dirtyRowIDs: store.consumeDirtyRowIds())
        XCTAssertEqual(band.snapshot.rows.map(\.id), ["toolGroup:call-1", "thinking:call-2", "toolGroup:call-2"])

        // Scenario B: call-1 has thinking at timestamp 20.0, call-2 is a tool row at timestamp 30.0
        // sharing group "call-1" ([call-1, call-2]), then call-2's persisted add corrects its timestamp
        // to 10.0 (before call-1), so call-1's thinking peer splits [call-2] and [call-1].
        let store2 = NativeChatMessageStore()
        store2.applyBackfill([
            [
                "messageId": "call-1",
                "chatId": "c2",
                "role": "assistant",
                "content": "",
                "method": "Bash",
                "thinking": ["content": "First thought", "isStreaming": false],
                "timestamp": 20.0,
            ],
            [
                "messageId": "call-2",
                "chatId": "c2",
                "role": "assistant",
                "content": "",
                "method": "Read",
                "timestamp": 30.0,
            ],
        ], chatId: "c2")
        coordinator.updateWindowRows(store2.rows, dirtyRowIDs: store2.consumeDirtyRowIds())
        XCTAssertEqual(store2.rows.map(\.id), ["thinking:call-1", "toolGroup:call-1"])

        store2.applyAdd([
            "messageId": "call-2",
            "chatId": "c2",
            "role": "assistant",
            "content": "",
            "method": "Read",
            "timestamp": 10.0,
        ])
        let reorderedIDs = store2.rows.map(\.id)
        XCTAssertEqual(Set(reorderedIDs).count, reorderedIDs.count, "Reordered tool groups split by thinking peer must have unique row IDs")
        XCTAssertEqual(reorderedIDs, ["toolGroup:call-2", "thinking:call-1", "toolGroup:call-1"])
        coordinator.updateWindowRows(store2.rows, dirtyRowIDs: store2.consumeDirtyRowIds())
        XCTAssertEqual(band.snapshot.rows.map(\.id), ["toolGroup:call-2", "thinking:call-1", "toolGroup:call-1"])
    }

    @MainActor
    func testUpdateWindowRowsDropsDuplicateRowIDsDefensivelyWithoutCrashing() {
        let band = NativeChatWindowBand(rows: [])
        let coordinator = band.coordinator
        coordinator.windowEnabled = true
        coordinator.useMarkerFrames = true

        let msg1 = NativeChatMessage(id: "dup-id", chatId: "c1", role: .assistant, content: "First", timestamp: 1000)
        let msg2 = NativeChatMessage(id: "dup-id", chatId: "c1", role: .assistant, content: "Second duplicate", timestamp: 2000)
        let msg3 = NativeChatMessage(id: "unique-id", chatId: "c1", role: .assistant, content: "Third", timestamp: 3000)

        coordinator.updateWindowRows([.assistant(msg1), .assistant(msg2), .assistant(msg3)])
        XCTAssertEqual(band.snapshot.rows.map(\.id), ["dup-id", "unique-id"])
        if case .assistant(let kept) = band.snapshot.rows.first {
            XCTAssertEqual(kept.content, "First", "First occurrence must be retained when dropping later duplicates")
        } else {
            XCTFail("Expected assistant row")
        }
    }

    @MainActor
    func testIncrementalRowsSwitchProducesIdenticalRowsInBothModes() {
        let defaults = UserDefaults.standard
        let optionKey = NativeChatPerformance.key(.incrementalRows)
        let allKey = NativeChatPerformance.allKey
        let savedOption = defaults.object(forKey: optionKey)
        let savedAll = defaults.object(forKey: allKey)
        defer {
            if let savedOption { defaults.set(savedOption, forKey: optionKey) } else { defaults.removeObject(forKey: optionKey) }
            if let savedAll { defaults.set(savedAll, forKey: allKey) } else { defaults.removeObject(forKey: allKey) }
        }

        func runSequence(incremental: Bool) -> (
            stepRows: [[NativeChatRow]],
            stepBandRows: [[NativeChatRow]],
            stepHeights: [[CGFloat]],
            stepPrefixes: [[CGFloat]],
            dirtyAfterContentPatch: Set<String>?,
            lastChangedAfterContentPatch: Set<String>?
        ) {
            defaults.removeObject(forKey: allKey)
            defaults.set(incremental, forKey: optionKey)
            XCTAssertEqual(NativeChatPerformance.isEnabled(.incrementalRows), incremental)

            let store = NativeChatMessageStore()
            let band = NativeChatWindowBand(rows: [])
            let coordinator = band.coordinator
            coordinator.windowEnabled = true
            coordinator.store = store
            var model = NativeChatWindowModel(layout: .init(width: 390, scale: 3))

            var stepRows: [[NativeChatRow]] = []
            var stepBandRows: [[NativeChatRow]] = []
            var stepHeights: [[CGFloat]] = []
            var stepPrefixes: [[CGFloat]] = []

            func recordStep() {
                coordinator.updateWindowRows(store.rows)
                model.update(coordinator.windowModel.descriptors)
                stepRows.append(store.rows)
                stepBandRows.append(band.snapshot.rows)
                stepHeights.append(model.heights)
                stepPrefixes.append(model.prefix)
            }

            // Step 1: initial backfill + measure first two rows so medians & lastMeasured are populated
            store.applyBackfill([
                ["messageId": "u1", "chatId": "c1", "role": "user", "content": "Run checks", "timestamp": 10.0],
                ["messageId": "call-1", "chatId": "c1", "role": "assistant", "content": "", "method": "Bash", "timestamp": 20.0],
                ["messageId": "a1", "chatId": "c1", "role": "assistant", "content": "Starting", "timestamp": 40.0],
            ], chatId: "c1")
            recordStep()
            let initialDescriptors = model.descriptors
            _ = model.measure([
                (model.key(for: initialDescriptors[0]), 64),
                (model.key(for: initialDescriptors[1]), 42),
                (model.key(for: initialDescriptors[2]), 118),
            ])

            // Step 2: content-only streaming patch on a1 (changes revision -> falls back to lastMeasured)
            store.applyPatch([
                ["messageId": "a1", "chatId": "c1", "role": "assistant", "content": "Starting checks...", "timestamp": 40.0],
            ], chatId: "c1")
            let lastChangedAfterContentPatch = store.lastChangedRowIds
            let dirtyAfterContentPatch = store.consumeDirtyRowIds()
            coordinator.updateWindowRows(store.rows, dirtyRowIDs: dirtyAfterContentPatch)
            model.update(coordinator.windowModel.descriptors)
            stepRows.append(store.rows)
            stepBandRows.append(band.snapshot.rows)
            stepHeights.append(model.heights)
            stepPrefixes.append(model.prefix)

            // Step 3: update-before-add placeholder call-2, then persisted add with corrected timestamp
            store.applyUpdate([
                "messageId": "call-2",
                "chatId": "c1",
                "timestamp": 50.0,
                "thinking": ["content": "Planning second tool", "isStreaming": true],
            ])
            recordStep()

            store.applyAdd([
                "messageId": "call-2",
                "chatId": "c1",
                "role": "assistant",
                "content": "",
                "method": "Read",
                "timestamp": 25.0,
            ])
            recordStep()

            // Step 4: patch adding call-3 into the group and streaming more prose into a1
            store.applyPatch([
                ["messageId": "call-3", "chatId": "c1", "role": "assistant", "content": "", "method": "Grep", "timestamp": 30.0],
                ["messageId": "a1", "chatId": "c1", "role": "assistant", "content": "Starting checks... done.", "status": "complete", "timestamp": 40.0],
            ], chatId: "c1")
            recordStep()

            // Step 5: settle streaming at end of turn
            store.settleStreaming(chatId: "c1")
            recordStep()

            return (stepRows, stepBandRows, stepHeights, stepPrefixes, dirtyAfterContentPatch, lastChangedAfterContentPatch)
        }

        let incResult = runSequence(incremental: true)
        let fullResult = runSequence(incremental: false)

        XCTAssertEqual(incResult.dirtyAfterContentPatch, ["a1"])
        XCTAssertEqual(incResult.lastChangedAfterContentPatch, ["a1"])
        XCTAssertNil(fullResult.dirtyAfterContentPatch, "consumeDirtyRowIds must return nil when incrementalRows is off")
        XCTAssertNil(fullResult.lastChangedAfterContentPatch, "lastChangedRowIds must be nil when incrementalRows is off")

        XCTAssertEqual(incResult.stepRows.count, fullResult.stepRows.count)
        for idx in incResult.stepRows.indices {
            XCTAssertEqual(incResult.stepRows[idx], fullResult.stepRows[idx], "store.rows mismatch at step \(idx)")
            XCTAssertEqual(incResult.stepBandRows[idx], fullResult.stepBandRows[idx], "windowBand.snapshot.rows mismatch at step \(idx)")
            XCTAssertEqual(incResult.stepHeights[idx], fullResult.stepHeights[idx], "windowModel.heights mismatch at step \(idx)")
            XCTAssertEqual(incResult.stepPrefixes[idx], fullResult.stepPrefixes[idx], "windowModel.prefix mismatch at step \(idx)")
        }
    }
}
