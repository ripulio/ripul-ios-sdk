import XCTest
@testable import RipulAgent

/// Phase-2 gate (native-tool-registry): absorption — the PERMISSIVE direction
/// of the valve. Toggle-on widens the developer channel's projection to the
/// host's end-user tools; every absorbed invoke is attributed; collisions
/// block; teardown resets; and the reverse direction stays structurally shut.
@MainActor
final class AbsorptionTests: XCTestCase {

    private final class PlainTool: NativeTool {
        let name: String
        let description = "test tool"
        let inputSchema: [String: Any] = [:]
        private(set) var executed = false
        init(name: String) { self.name = name }
        func execute(args: [String: Any]) async throws -> Any {
            executed = true
            return ["ok": true]
        }
    }

    private func handshake() -> [String: Any] { ["type": "agent-framework:handshake"] }

    private func invokeMessage(_ toolName: String) -> [String: Any] {
        [
            "type": "agent-framework:mcp:invoke",
            "requestId": UUID().uuidString,
            "toolName": toolName,
            "args": [String: Any](),
        ]
    }

    private func makeDevBridge(endUserTools: [NativeTool], devTools: [NativeTool] = []) -> AgentBridge {
        let registry = RipulToolRegistry()
        if !endUserTools.isEmpty { registry.register(endUserTools, audience: .endUser) }
        if !devTools.isEmpty { registry.register(devTools, audience: .developer) }
        return AgentBridge(registry: registry, audience: .developer)
    }

    private func broadcastNames(_ bridge: AgentBridge) -> [String] {
        var broadcasts: [[String: Any]] = []
        bridge.testOutboundSink = { broadcasts.append($0) }
        bridge.handleMessage(handshake())
        let toolsMessage = broadcasts.last { ($0["type"] as? String) == "agent-framework:mcp:tools" }
        return (toolsMessage?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
    }

    func testToggleOnWidensProjectionAndOffRemoves() {
        let bridge = makeDevBridge(
            endUserTools: [PlainTool(name: "user_tool")],
            devTools: [PlainTool(name: "dev_tool")]
        )

        XCTAssertFalse(broadcastNames(bridge).contains("user_tool"))

        XCTAssertEqual(bridge.setEndUserTesting(true), .on)
        XCTAssertTrue(bridge.isEndUserTestingEnabled)
        let namesOn = broadcastNames(bridge)
        XCTAssertTrue(namesOn.contains("user_tool"))
        XCTAssertTrue(namesOn.contains("dev_tool"))

        XCTAssertEqual(bridge.setEndUserTesting(false), .off)
        XCTAssertFalse(broadcastNames(bridge).contains("user_tool"))
    }

    func testAbsorbedInvokeCarriesAbsorbedTrueAndOwnToolsDoNot() async throws {
        let userTool = PlainTool(name: "user_tool")
        let devTool = PlainTool(name: "dev_tool")
        let bridge = makeDevBridge(endUserTools: [userTool], devTools: [devTool])
        bridge.setEndUserTesting(true)

        var responses: [[String: Any]] = []
        bridge.testOutboundSink = { responses.append($0) }

        bridge.handleMessage(invokeMessage("user_tool"))
        for _ in 0..<20 where !userTool.executed {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let absorbedResult = responses.first { ($0["type"] as? String) == "agent-framework:mcp:result" }
        XCTAssertEqual(absorbedResult?["absorbed"] as? Bool, true, "absorbed invoke must be attributed")

        responses.removeAll()
        bridge.handleMessage(invokeMessage("dev_tool"))
        for _ in 0..<20 where !devTool.executed {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let ownResult = responses.first { ($0["type"] as? String) == "agent-framework:mcp:result" }
        XCTAssertNotNil(ownResult)
        XCTAssertNil(ownResult?["absorbed"], "the channel's own tools carry no absorption stamp")
    }

    func testNameCollisionBlocksToggleWithNamesListed() {
        // A dev tool and an end-user tool sharing a canonical name: the
        // registry itself would trap this, so the cross-set case is a
        // CHANNEL-BOUND tool vs an end-user entry.
        let registry = RipulToolRegistry()
        registry.register([PlainTool(name: "console_logs"), PlainTool(name: "user_tool")], audience: .endUser)
        let bridge = AgentBridge(registry: registry, audience: .developer)
        bridge.registerBuiltInTools([ConsoleLogsTool(bridge: bridge)])

        let result = bridge.setEndUserTesting(true)
        XCTAssertEqual(result, .blocked(collidingNames: ["console_logs"]))
        XCTAssertFalse(bridge.isEndUserTestingEnabled)
        XCTAssertFalse(broadcastNames(bridge).contains("user_tool"), "a blocked toggle must widen nothing")
    }

    func testTeardownResetsTestingMode() {
        // Session state lives on the bridge instance: a new channel on the
        // SAME registry starts with absorption off.
        let registry = RipulToolRegistry()
        registry.register([PlainTool(name: "user_tool")], audience: .endUser)

        let first = AgentBridge(registry: registry, audience: .developer)
        first.setEndUserTesting(true)
        XCTAssertTrue(first.isEndUserTestingEnabled)

        let second = AgentBridge(registry: registry, audience: .developer)
        XCTAssertFalse(second.isEndUserTestingEnabled)
        XCTAssertFalse(broadcastNames(second).contains("user_tool"))
    }

    func testReverseDirectionStaysShutWithTestingModeOn() {
        // Phase-0 regression, re-asserted under phase 2: absorption on the
        // dev channel must not leak developer entries to a SIBLING .endUser
        // channel on the same registry — the valve is one-way, not merely
        // off-by-default.
        let registry = RipulToolRegistry()
        registry.register([PlainTool(name: "user_tool")], audience: .endUser)
        registry.register([PlainTool(name: "plain_dev_tool")], audience: .developer)

        let console = AgentBridge(registry: registry, audience: .developer)
        console.setEndUserTesting(true)

        let panel = AgentBridge(registry: registry, audience: .endUser)
        let names = broadcastNames(panel)
        XCTAssertTrue(names.contains("user_tool"))
        XCTAssertFalse(names.contains("plain_dev_tool"), "developer tools reached an end-user channel")
    }
}
