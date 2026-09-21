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
        store.close()
        message["initialCallId"] = "removed-call"
        store.receive(message, opening: true)
        XCTAssertEqual(store.expandedCallIds, ["d"], "A removed target falls back to the latest call")
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
