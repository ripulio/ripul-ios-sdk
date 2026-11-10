import XCTest
@testable import RipulAgent

final class ToolCallDetailsTests: XCTestCase {
    private func call(_ id: String, result: String? = nil) -> [String: Any] {
        var value: [String: Any] = ["id": id, "toolName": "Bash", "status": result == nil ? "pending" : "success",
                                    "timestamp": 1_789_106_000_000, "arguments": "{\"command\":\"pwd\"}", "diagnostics": "{}"]
        if let result { value["result"] = result }
        return value
    }

    @MainActor func testTaskActivityUpdatesWithoutResettingTheOpenSheet() {
        let store = ToolCallDetailsStore()
        var task: [String: Any] = ["id": "task-a", "type": "local_bash", "title": "Run checks", "status": "running",
                                  "entries": [["kind": "tool", "label": "Read", "detail": "one.ts"]], "totalCount": 11, "synthetic": false]
        var launch = call("a", result: "Started in background")
        launch["status"] = "running"
        launch["task"] = task
        store.receive(["requestId": "task", "title": "Tool calls", "calls": [launch]], opening: true)
        XCTAssertEqual(store.request?.calls.first?.task?.entries.first?.detail, "one.ts")
        XCTAssertEqual(store.request?.calls.first?.task?.subtitle, "Shell")
        store.setExpanded(false, callId: "a")
        task["entries"] = [["kind": "tool", "label": "Read", "detail": "two.ts"]]
        task["status"] = "completed"
        task["summary"] = "Checks passed"
        launch["task"] = task
        launch["status"] = "completed"
        store.receive(["requestId": "task", "title": "Tool calls", "calls": [launch]], opening: false)
        XCTAssertTrue(store.expandedCallIds.isEmpty)
        XCTAssertEqual(store.request?.calls.first?.task?.entries.first?.detail, "two.ts")
        XCTAssertEqual(store.request?.calls.first?.task?.summary, "Checks passed")
        XCTAssertEqual(store.request?.calls.first?.result, "Started in background")
    }

    @MainActor func testWorkflowRunArrivesWithItsPhasesAndAgents() {
        let store = ToolCallDetailsStore()
        let agents: [[String: Any]] = [
            ["id": "1", "label": "read-a", "state": "done", "detail": "11,153 tokens · 1 tool use · 2s"],
            ["id": "2", "label": "read-b", "state": "running", "detail": "Read …/b.txt"],
            ["id": "3", "label": "read-c", "state": "queued"],
        ]
        let workflow: [String: Any] = ["progress": "1 of 3 agents done", "done": 1, "total": 3, "phases": [
            ["id": "1", "title": "Read", "state": "running", "count": "1 of 3", "agents": agents, "omitted": 0],
            ["id": "2", "title": "Join", "state": "queued", "count": "", "agents": [[String: Any]](), "omitted": 0],
        ]]
        var launch = call("w", result: "Workflow launched in background")
        launch["status"] = "running"
        launch["task"] = ["id": "w3bqqfkwa", "type": "local_workflow", "title": "Three readers then one joiner", "status": "running",
                          "variant": "capture-probe", "entries": [[String: Any]](), "totalCount": 0, "synthetic": false, "workflow": workflow]
        store.receive(["requestId": "run", "title": "Tool calls", "calls": [launch]], opening: true)

        let task = store.request?.calls.first?.task
        XCTAssertEqual(task?.subtitle, "Workflow · capture-probe")
        XCTAssertEqual(task?.workflow?.progress, "1 of 3 agents done")
        XCTAssertEqual(task?.workflow?.phases.map(\.title), ["Read", "Join"])
        XCTAssertEqual(task?.workflow?.phases.first?.agents.map(\.state), ["done", "running", "queued"])
        // An agent with nothing to say about itself still decodes.
        XCTAssertNil(task?.workflow?.phases.first?.agents.last?.detail)
    }

    @MainActor func testMultipleExpandedCallsSurviveResultsAndNewIterations() {
        let store = ToolCallDetailsStore()
        store.receive(["requestId": "one", "title": "Bash", "calls": [call("a"), call("b")]], opening: true)
        XCTAssertEqual(store.expandedCallIds, ["b"])
        store.setExpanded(true, callId: "a")
        XCTAssertEqual(store.expandedCallIds, ["a", "b"])
        store.receive(["requestId": "one", "title": "Bash", "calls": [call("a", result: "/repo"), call("b"), call("c")]], opening: false)
        XCTAssertEqual(store.expandedCallIds, ["a", "b"])
        XCTAssertEqual(store.request?.calls.first?.result, "/repo")
        XCTAssertEqual(store.request?.calls.first?.statusTitle, "Completed")
        store.setExpanded(false, callId: "a")
        XCTAssertEqual(store.expandedCallIds, ["b"])
    }

    @MainActor func testAllCollapsedStaysCollapsedAndRemovedCallsArePruned() {
        let store = ToolCallDetailsStore()
        store.receive(["requestId": "one", "title": "Bash", "calls": [call("a"), call("b")]], opening: true)
        store.setExpanded(false, callId: "b")
        store.receive(["requestId": "one", "title": "Bash", "calls": [call("a"), call("b", result: "done"), call("c")]], opening: false)
        XCTAssertTrue(store.expandedCallIds.isEmpty)
        store.setExpanded(true, callId: "a")
        store.setExpanded(true, callId: "c")
        store.receive(["requestId": "one", "title": "Bash", "calls": [call("b"), call("c")]], opening: false)
        XCTAssertEqual(store.expandedCallIds, ["c"])
    }

    @MainActor func testTappedCallOpensWithinWholeRowWithoutReopeningOnUpdates() {
        let store = ToolCallDetailsStore()
        var message: [String: Any] = ["requestId": "one", "title": "Tool calls", "initialCallId": "a", "calls": [call("a"), call("b"), call("c")]]
        store.receive(message, opening: true)
        XCTAssertEqual(store.request?.calls.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(store.request?.initialExpandedCallId, "a")
        XCTAssertEqual(store.expandedCallIds, ["a"])
        store.setExpanded(false, callId: "a")
        store.setExpanded(true, callId: "b")
        message["calls"] = [call("a", result: "done"), call("b"), call("c"), call("d")]
        store.receive(message, opening: false)
        XCTAssertEqual(store.expandedCallIds, ["b"], "Live results must not reopen the initial target")
        // Re-opening the same row for a different lozenge switches the expanded call to the newly tapped one.
        message["initialCallId"] = "c"
        store.receive(message, opening: true)
        XCTAssertEqual(store.request?.calls.map(\.id), ["a", "b", "c", "d"])
        XCTAssertEqual(store.expandedCallIds, ["c"], "Re-opening the same row for a different lozenge must unfold only that lozenge")
        store.close()
        message["initialCallId"] = "removed-call"
        store.receive(message, opening: true)
        XCTAssertEqual(store.expandedCallIds, ["d"], "A removed target falls back to the latest call")
    }

    @MainActor func testRowStripEventAlwaysOpensAllCallsInRowAndUnfoldsTappedLozengeAfterStreamingGrowth() {
        let store = NativeChatMessageStore()
        let rowStates = NativeChatRowStateRegistry()
        let bridge = AgentBridge()
        let firstMsg: [String: Any] = [
            "messageId": "call-1", "chatId": "chat-1", "role": "assistant", "content": "",
            "timestamp": 1_000, "method": "Read", "status": "success",
            "toolCall": [
                "id": "call-1", "toolName": "Read", "label": "Read a.swift", "status": "success",
                "detail": [
                    "id": "call-1", "toolName": "Read", "status": "success", "timestamp": 1_000,
                    "arguments": "{\"file_path\":\"/repo/a.swift\"}", "diagnostics": "{}",
                    "result": "contents of a",
                ] as [String: Any],
            ] as [String: Any],
        ]
        store.applyBackfill([firstMsg], chatId: "chat-1")
        guard case .toolGroup(let initialGroup)? = store.rows.first else {
            return XCTFail("Expected initial toolGroup row")
        }
        let stripStore = rowStates.toolStripStore(forRow: initialGroup.id, group: initialGroup)
        var handledEvents: [[String: Any]] = []
        stripStore.present { [weak stripStore] (event: [String: Any]) in
            handledEvents.append(event)
            NativeToolGroupRowView.handleStripEvent(
                event,
                for: stripStore?.latestGroup ?? initialGroup,
                bridge: bridge
            )
        }

        // Stream more tool calls into the same row (two strip lozenges and one synthesized taskRun).
        let secondMsg: [String: Any] = [
            "messageId": "call-2", "chatId": "chat-1", "role": "assistant", "content": "",
            "timestamp": 1_010, "method": "Grep", "status": "running",
            "toolCall": [
                "id": "call-2", "toolName": "Grep", "label": "Grep pattern", "status": "running",
                "detail": [
                    "id": "call-2", "toolName": "Grep", "status": "running", "timestamp": 1_010,
                    "arguments": "{\"pattern\":\"foo\"}", "diagnostics": "{}",
                    "task": [
                        "id": "task-2", "type": "local_bash", "title": "Search", "status": "running",
                        "entries": [["kind": "text", "detail": "Checking logic"]], "totalCount": 1, "synthetic": false,
                    ] as [String: Any],
                ] as [String: Any],
            ] as [String: Any],
        ]
        let thirdMsg: [String: Any] = [
            "messageId": "call-3", "chatId": "chat-1", "role": "assistant", "content": "",
            "timestamp": 1_020, "method": "Bash", "status": "success",
            "toolCall": [
                "id": "call-3", "toolName": "Bash", "label": "swift test", "status": "success",
                "detail": [
                    "id": "call-3", "toolName": "Bash", "status": "success", "timestamp": 1_020,
                    "arguments": "{\"command\":\"swift test\"}", "diagnostics": "{}",
                    "result": "Executed 10 tests",
                ] as [String: Any],
            ] as [String: Any],
        ]
        let fourthMsg: [String: Any] = [
            "messageId": "call-4", "chatId": "chat-1", "role": "assistant", "content": "",
            "timestamp": 1_030, "method": "Agent", "status": "running",
            "toolCall": [
                "id": "call-4", "toolName": "Agent", "label": "Agent Review", "status": "running",
                "task": [
                    "id": "task-4", "type": "local_agent", "title": "Review", "status": "running",
                    "entries": [["kind": "text", "detail": "Auditing row"]], "totalCount": 1, "synthetic": false,
                ] as [String: Any],
                "detail": [
                    "id": "call-4", "toolName": "Agent", "status": "running", "timestamp": 1_030,
                    "arguments": "{\"description\":\"Review\"}", "diagnostics": "{}",
                ] as [String: Any],
            ] as [String: Any],
        ]
        store.applyPatch([secondMsg, thirdMsg, fourthMsg], chatId: "chat-1")
        guard case .toolGroup(let grownGroup)? = store.rows.first else {
            return XCTFail("Expected grown toolGroup row")
        }
        NativeChatRowStateRegistry.syncToolStripStore(stripStore, with: grownGroup)
        XCTAssertEqual(grownGroup.calls.map { $0.id }, ["call-1", "call-2", "call-3", "call-4"])
        XCTAssertEqual(grownGroup.taskRuns.first?.id, "call-4", "Synthesized task run must use the launching call's ID")

        // Tapping each lozenge in the grown row must show all 4 calls and unfold only the tapped one.
        for targetId in ["call-1", "call-2", "call-3"] {
            stripStore.select(targetId)
            XCTAssertEqual(bridge.toolCallDetails.request?.calls.map { $0.id }, ["call-1", "call-2", "call-3", "call-4"])
            XCTAssertEqual(bridge.toolCallDetails.request?.initialExpandedCallId, targetId)
            XCTAssertEqual(bridge.toolCallDetails.expandedCallIds, [targetId])
        }
        // Tapping the synthesized task run also opens all 4 calls and unfolds call-4.
        NativeToolGroupRowView.openToolDetails(for: grownGroup, initialCallId: grownGroup.taskRuns.first?.id ?? "", bridge: bridge)
        XCTAssertEqual(bridge.toolCallDetails.request?.calls.map { $0.id }, ["call-1", "call-2", "call-3", "call-4"])
        XCTAssertEqual(bridge.toolCallDetails.expandedCallIds, ["call-4"])
        XCTAssertEqual(
            bridge.toolCallDetails.request?.calls.first(where: { $0.id == "call-2" })?.task?.entries.first?.detail,
            "Checking logic",
            "Opening tool details locally must preserve task activity on tool calls"
        )
    }

    @MainActor func testDismissalAndChatIsolation() {
        let store = ToolCallDetailsStore()
        let first: [String: Any] = ["requestId": "one", "title": "Bash", "calls": [call("a")]]
        store.receive(first, opening: true)
        XCTAssertEqual(store.close(), "one")
        XCTAssertTrue(store.expandedCallIds.isEmpty)
        store.receive(first, opening: false)
        XCTAssertNil(store.request)
        store.receive(["requestId": "two", "title": "Read", "calls": [call("b")]], opening: true)
        store.receive(first, opening: false)
        store.close(requestId: "one")
        XCTAssertEqual(store.request?.requestId, "two")
        XCTAssertEqual(store.expandedCallIds, ["b"])
    }

    @MainActor func testMalformedOrDuplicateCallsDoNotPresent() {
        let store = ToolCallDetailsStore()
        store.receive(["requestId": "one", "title": "Bash", "calls": []], opening: true)
        XCTAssertNil(store.request)
        store.receive(["requestId": "one", "title": "Bash", "calls": [call("a"), call("a")]], opening: true)
        XCTAssertNil(store.request)
    }

    func testSummariesUseCanonicalInputsAndReadableFallbacks() throws {
        func summary(name: String, args: [String: Any], canonical: [String: Any]? = nil) throws -> NativeToolSummary {
            var value = call("summary")
            value["toolName"] = name
            value["arguments"] = String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)
            value["renderArguments"] = canonical
            return NativeToolSummary(try JSONDecoder().decode(ToolCallDetail.self, from: JSONSerialization.data(withJSONObject: value)))
        }
        XCTAssertEqual(try summary(name: "Bash", args: ["command": "ls\n  -la"]).title, "ls -la")
        let terminal = try summary(name: "Bash", args: ["description": "Run tests", "command": "npm test"])
        XCTAssertEqual(terminal.title, "Run tests")
        XCTAssertEqual(terminal.subtitle, "npm test")
        let file = try summary(name: "Read", args: [:], canonical: ["file_path": "/repo/app.swift"])
        XCTAssertEqual(file.title, "Read app.swift")
        XCTAssertEqual(file.subtitle, "/repo/app.swift")
        XCTAssertEqual(try summary(name: "Grep", args: ["pattern": "TODO", "path": "src"]).subtitle, "TODO · src")
        XCTAssertEqual(try summary(name: "WebFetch", args: ["url": "https://example.com"]).title, "Fetch example.com")
        let custom = try summary(name: "custom_tool", args: ["limit": 10])
        XCTAssertEqual(custom.title, "Custom tool")
        XCTAssertEqual(custom.subtitle, "Limit: 10")
        XCTAssertNil(try summary(name: "custom_tool", args: [:]).subtitle)
        let patch = try summary(name: "apply_patch", args: ["changes": ["src/app.ts": ["type": "update"], "src/new.ts": ["type": "add"]]])
        XCTAssertEqual(patch.subtitle, "app.ts, new.ts")
        XCTAssertFalse(patch.subtitle!.contains("type"))
        let tasks = try summary(name: "TodoWrite", args: ["todos": [["content": "Inspect code", "status": "completed"], ["content": "Run checks", "status": "in_progress"]]])
        XCTAssertEqual(tasks.title, "Run checks")
        XCTAssertEqual(tasks.subtitle, "1 of 2 tasks complete")
        let long = try summary(name: "Bash", args: ["command": String(repeating: "x", count: 1000)])
        XCTAssertEqual(long.title.count, 241)
        XCTAssertTrue(long.title.hasSuffix("…"))
    }
}
