import XCTest
@testable import RipulAgent

final class ToolCallDetailsTests: XCTestCase {
    private func call(_ id: String, result: String? = nil) -> [String: Any] {
        var value: [String: Any] = ["id": id, "toolName": "Bash", "status": result == nil ? "pending" : "success",
                                    "timestamp": 1_789_106_000_000, "arguments": "{\"command\":\"pwd\"}", "diagnostics": "{}"]
        if let result { value["result"] = result }
        return value
    }

    @MainActor func testSelectionSurvivesResultsAndNewIterations() {
        let store = ToolCallDetailsStore()
        store.receive(["requestId": "one", "title": "Bash", "calls": [call("a"), call("b")]], opening: true)
        XCTAssertEqual(store.selectedId, "b")
        store.selectedId = "a"
        store.receive(["requestId": "one", "title": "Bash", "calls": [call("a", result: "/repo"), call("b"), call("c")]], opening: false)
        XCTAssertEqual(store.selectedId, "a")
        XCTAssertEqual(store.selectedCall?.result, "/repo")
        XCTAssertEqual(store.selectedCall?.statusTitle, "Completed")
    }

    @MainActor func testDismissalAndChatIsolation() {
        let store = ToolCallDetailsStore()
        let first: [String: Any] = ["requestId": "one", "title": "Bash", "calls": [call("a")]]
        store.receive(first, opening: true)
        XCTAssertEqual(store.close(), "one")
        store.receive(first, opening: false)
        XCTAssertNil(store.request)
        store.receive(["requestId": "two", "title": "Read", "calls": [call("b")]], opening: true)
        store.receive(first, opening: false)
        store.close(requestId: "one")
        XCTAssertEqual(store.request?.requestId, "two")
    }

    @MainActor func testMalformedOrDuplicateCallsDoNotPresent() {
        let store = ToolCallDetailsStore()
        store.receive(["requestId": "one", "title": "Bash", "calls": []], opening: true)
        XCTAssertNil(store.request)
        store.receive(["requestId": "one", "title": "Bash", "calls": [call("a"), call("a")]], opening: true)
        XCTAssertNil(store.request)
    }
}
