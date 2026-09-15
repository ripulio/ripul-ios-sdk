import XCTest
@testable import RipulAgent

final class ToolDisplayNameTests: XCTestCase {
    @MainActor func testActivityNamesMatchAcrossNativeSurfacesWithoutChangingIdentity() {
        let store = SessionListStore()
        for (name, expected) in [
            ("mcp__ripul_tools__device_evaluate", "Device evaluate"),
            ("mcp__ripul_tools_host_console_logs", "Host console logs"),
            ("host_console_logs", "Host console logs"),
            ("Device EVALUATE", "Device evaluate"),
            ("Read", "Read")
        ] {
            for kind in ["toolStart", "toolEnd"] {
                let event = AgentActivityEvent.from(dict: ["kind": kind, "toolName": name, "toolId": "call", "status": "success", "toolDetail": "Keep My Detail"])
                XCTAssertEqual(event?.displayName, expected)
                XCTAssertEqual(event?.toolNameForIcon, name)
                XCTAssertEqual(event?.detail, "Keep My Detail")
                store.latestActivityByChatId["chat"] = event
                XCTAssertEqual(store.latestToolLabelForList(for: "chat"), expected)
                XCTAssertEqual(store.latestToolActivityForList(for: "chat")?.displayName, expected)
            }
        }
        store.updatesSuppressed = true
        XCTAssertNil(store.latestToolLabelForList(for: "chat"))
    }

    func testSuppliedLabelsAndExecutableIdentities() {
        let name = "mcp__ripul_tools__device_evaluate"
        for label in [name, "Device Evaluate", ""] {
            XCTAssertEqual(AgentActivityEvent.toolStart(toolName: name, toolId: "call", toolLabel: label, toolDetail: nil).displayName, "Device evaluate")
        }
        XCTAssertEqual(AgentActivityEvent.toolEnd(toolName: "Bash", toolId: "call", status: "success", toolLabel: "Python + Status", toolDetail: nil).displayName, "Python + Status")
        XCTAssertNil(AgentActivityEvent.thinking.displayName)
    }
}
