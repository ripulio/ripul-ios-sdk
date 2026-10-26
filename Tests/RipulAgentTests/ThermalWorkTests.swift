import XCTest
import Combine
import SwiftUI
@testable import RipulAgent

@MainActor
final class ThermalWorkTests: XCTestCase {
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
    func testScrollRestorationEmitsOnlyOnChatSwitchOrToggleAndKeepsRowIdsStable() {
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

        // 1. Initial backfill for empty store emits .restore
        store.applyBackfill(
            initialEntries,
            chatId: "chat-1",
            scrollPosition: ["rowId": "turn-1", "offset": 18.0, "following": false]
        )
        XCTAssertEqual(restoredPositions.count, 1)
        XCTAssertEqual(restoredPositions.first?.offset, 18.0)
        XCTAssertEqual(store.rows.map(\.id), ["toolGroup:tool-2", "turn-1"])

        // 2. Identical backfill or mid-session catch-up backfill on the same chat does NOT emit .restore,
        //    keeps toolGroup ID stable when an earlier tool call is prepended, and keeps turn-1 ID stable
        //    when prose content arrives after thinking.
        store.applyBackfill(
            initialEntries,
            chatId: "chat-1",
            scrollPosition: ["rowId": "turn-1", "offset": 18.0, "following": false]
        )
        XCTAssertEqual(restoredPositions.count, 1, "No-op backfill must not re-emit .restore")

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
        XCTAssertEqual(restoredPositions.count, 1, "Mid-session catch-up backfill must not emit .restore")
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
        XCTAssertEqual(restoredPositions.count, 2)
        XCTAssertEqual(restoredPositions.last?.offset, 42.0)

        // 4. Cold chat switch: initial switch-time backfill arrives empty with scrollPosition,
        //    then hydration backfill arrives non-empty without scrollPosition — kept across empty
        //    and consumed once on first non-empty row build.
        store.applyBackfill(
            [],
            chatId: "chat-cold",
            scrollPosition: ["rowId": "turn-1", "offset": 31.0, "following": false]
        )
        XCTAssertEqual(restoredPositions.count, 2, "Empty cold-chat backfill must hold scrollPosition until rows exist")
        XCTAssertEqual(store.pendingScrollRestoration?.offset, 31.0)

        store.applyBackfill(
            [
                [
                    "messageId": "turn-1",
                    "chatId": "chat-cold",
                    "role": "assistant",
                    "method": "llmRequest",
                    "content": "Hydrated cold chat reply.",
                    "timestamp": 5_000.0,
                ],
            ],
            chatId: "chat-cold",
            scrollPosition: nil
        )
        XCTAssertEqual(restoredPositions.count, 3, "First non-empty hydration backfill must emit held scrollPosition")
        XCTAssertEqual(restoredPositions.last?.chatId, "chat-cold")
        XCTAssertEqual(restoredPositions.last?.offset, 31.0)
        XCTAssertEqual(
            store.pendingScrollRestoration?.offset,
            31.0,
            "pendingScrollRestoration remains available in store until NativeChatView consumes it on mount"
        )

        // 5. Splitting an existing toolGroup (either when the second tool call gains thinking or when a
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
}
