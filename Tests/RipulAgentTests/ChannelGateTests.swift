import XCTest
@testable import RipulAgent

/// The hard, structural half of the one-way tool valve
/// (docs/plans/native-tool-registry/phase-0-hard-gate-and-decision-record.md):
/// a `RipulDeveloperOnlyTool` must never be broadcast to, or invocable from,
/// an `.endUser` `AgentBridge` channel — no matter which registration call
/// (`register`, `registerBuiltInTools`, `setTools`) put it there.
///
/// These exercise the REAL message path (`handleMessage` → `handleMCPInvoke`,
/// and the `mcp:tools` broadcast assembled from `toolDefinitions`), using the
/// DEBUG-only `testOutboundSink` seam — no WKWebView needed. A tool on this
/// channel that reaches the sink as an `mcp:tools` entry or produces an
/// `mcp:result` (rather than an `mcp:error`) would mean the gate failed.
@MainActor
final class ChannelGateTests: XCTestCase {

    /// Stand-in for the real SDK dev tools. Doesn't conform to
    /// `RipulDeveloperOnlyTool` by default — tests opt individual instances in
    /// by wrapping them, so both a "gated" and a "plain host tool" case can
    /// exist side by side without one blanket conformance covering the type.
    private final class RecordingTool: NativeTool {
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

    /// Opts a `RecordingTool` into the gate, mirroring how the real dev tools
    /// are marked (see RipulDeveloperOnlyTool.swift).
    private final class GatedRecordingTool: RipulDeveloperOnlyTool {
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

    private func invokeMessage(_ toolName: String) -> [String: Any] {
        [
            "type": "agent-framework:mcp:invoke",
            "requestId": UUID().uuidString,
            "toolName": toolName,
            "args": [String: Any](),
        ]
    }

    private func handshakeMessage() -> [String: Any] {
        ["type": "agent-framework:handshake"]
    }

    // MARK: - Broadcast (registeredToolSummaries + mcp:tools)

    func testDeveloperOnlyToolExcludedFromEndUserSummaries() {
        let bridge = AgentBridge(audience: .endUser)
        bridge.registerBuiltInTools([ConsoleLogsTool(bridge: bridge)])
        XCTAssertFalse(bridge.registeredToolSummaries.contains { $0.name == "console_logs" })
    }

    func testDeveloperOnlyToolIncludedOnDeveloperChannel() {
        let bridge = AgentBridge(audience: .developer)
        bridge.registerBuiltInTools([ConsoleLogsTool(bridge: bridge)])
        XCTAssertTrue(bridge.registeredToolSummaries.contains { $0.name == "console_logs" })
    }

    func testGateAppliesRegardlessOfWhichRegistrationPathWasUsed() {
        // registry.register() → registry projection; registerBuiltInTools() →
        // channel-bound tools. Both feed the same filtered `allTools`, so the
        // gate can't be bypassed by picking the other path.
        let registry = RipulToolRegistry()
        let viaRegistry = AgentBridge(registry: registry, audience: .endUser)
        registry.register([ConsoleLogsTool(bridge: viaRegistry)], audience: .endUser)
        XCTAssertFalse(viaRegistry.registeredToolSummaries.contains { $0.name == "console_logs" })

        let viaChannel = AgentBridge(audience: .endUser)
        viaChannel.registerBuiltInTools([ConsoleLogsTool(bridge: viaChannel)])
        XCTAssertFalse(viaChannel.registeredToolSummaries.contains { $0.name == "console_logs" })
    }

    func testPlainHostToolIsNeverFiltered() {
        // The gate is specific to SDK dev tools (RipulDeveloperOnlyTool is
        // SDK-internal) — a host's own tool is unaffected on any channel.
        let registry = RipulToolRegistry()
        registry.register([RecordingTool(name: "host_tool")], audience: .endUser)
        let bridge = AgentBridge(registry: registry, audience: .endUser)
        XCTAssertTrue(bridge.registeredToolSummaries.contains { $0.name == "host_tool" })
    }

    func testEndUserHandshakeBroadcastOmitsDeveloperOnlyTool() {
        let registry = RipulToolRegistry()
        registry.register([RecordingTool(name: "host_tool")], audience: .endUser)
        let bridge = AgentBridge(registry: registry, audience: .endUser)
        bridge.registerBuiltInTools([ConsoleLogsTool(bridge: bridge)])

        var broadcasts: [[String: Any]] = []
        bridge.testOutboundSink = { broadcasts.append($0) }
        bridge.handleMessage(handshakeMessage())

        let toolsMessage = broadcasts.first { ($0["type"] as? String) == "agent-framework:mcp:tools" }
        XCTAssertNotNil(toolsMessage, "handshake should broadcast mcp:tools when tools are registered")
        let names = (toolsMessage?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        XCTAssertTrue(names.contains("host_tool"))
        XCTAssertFalse(names.contains("console_logs"), "developer-only tool leaked into an .endUser broadcast")
    }

    func testDeveloperHandshakeBroadcastIncludesDeveloperOnlyTool() {
        let bridge = AgentBridge(audience: .developer)
        bridge.registerBuiltInTools([ConsoleLogsTool(bridge: bridge)])

        var broadcasts: [[String: Any]] = []
        bridge.testOutboundSink = { broadcasts.append($0) }
        bridge.handleMessage(handshakeMessage())

        let toolsMessage = broadcasts.first { ($0["type"] as? String) == "agent-framework:mcp:tools" }
        let names = (toolsMessage?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        XCTAssertTrue(names.contains("console_logs"))
    }

    // MARK: - Regression pins for the shipped apps

    /// The safe default. A host that never thinks about audience must get the
    /// restrictive channel — flipping this default would silently expose every
    /// SDK dev tool on every consumer's end-user agent panel.
    func testDefaultAudienceIsEndUser() {
        XCTAssertEqual(AgentBridge().audience, .endUser)
    }

    /// Mirrors what `.ripulDevTools(bridge:)` registers, on the audience the
    /// first-party Ripul apps use.
    ///
    /// This is the case the original gate broke: both Ripul apps built their
    /// bridge with the `.endUser` default and attach `.ripulDevTools`, so
    /// `console_logs` / `network_logs` were filtered out of the `mcp:tools`
    /// broadcast — and with them `host_console_logs` / `device_console_logs`,
    /// which the CLI's `ripul_tools` MCP server resolves from that same list.
    /// Every gate test still passed, because they all asserted the *gate*, and
    /// none asserted that the shipping apps keep their diagnostics.
    func testDeveloperChannelKeepsDiagnosticToolsForTheCli() {
        let bridge = AgentBridge(audience: .developer)
        bridge.registerBuiltInTools([
            ConsoleLogsTool(bridge: bridge),
            NetworkLogsTool(bridge: bridge),
        ])

        var broadcasts: [[String: Any]] = []
        bridge.testOutboundSink = { broadcasts.append($0) }
        bridge.handleMessage(handshakeMessage())

        let toolsMessage = broadcasts.first { ($0["type"] as? String) == "agent-framework:mcp:tools" }
        let names = (toolsMessage?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        XCTAssertTrue(names.contains("console_logs"), "host_/device_console_logs would vanish from CLI sessions")
        XCTAssertTrue(names.contains("network_logs"), "host_/device_network_logs would vanish from CLI sessions")
    }

    // MARK: - Invocation (handleMessage → handleMCPInvoke)

    func testGatedToolRefusesInvokeOnEndUserChannelAndNeverExecutes() async throws {
        let registry = RipulToolRegistry()
        let bridge = AgentBridge(registry: registry, audience: .endUser)
        let tool = GatedRecordingTool(name: "gated_tool")
        registry.register([tool], audience: .endUser)

        var responses: [[String: Any]] = []
        bridge.testOutboundSink = { responses.append($0) }
        bridge.handleMessage(invokeMessage("gated_tool"))

        // handleMCPInvoke's success path is asynchronous (Task { @MainActor in ... });
        // the refusal path (this test) is synchronous — send() fires before
        // handleMessage returns — but yield once for symmetry with the
        // success-path test below and to be robust to a future async refactor.
        await Task.yield()

        XCTAssertFalse(tool.executed, "a developer-only tool must never execute on an .endUser channel")
        XCTAssertEqual(responses.count, 1)
        XCTAssertEqual(responses.first?["type"] as? String, "agent-framework:mcp:error")
        let error = responses.first?["error"] as? String ?? ""
        XCTAssertTrue(error.contains("not found"), "wire error must read as ordinary not-found, never hint a developer tool exists here")
    }

    func testGatedToolExecutesOnDeveloperChannel() async throws {
        let registry = RipulToolRegistry()
        let bridge = AgentBridge(registry: registry, audience: .developer)
        let tool = GatedRecordingTool(name: "gated_tool")
        registry.register([tool], audience: .developer)

        var responses: [[String: Any]] = []
        bridge.testOutboundSink = { responses.append($0) }
        bridge.handleMessage(invokeMessage("gated_tool"))

        // execute() runs inside Task { @MainActor in ... } — give it a beat.
        for _ in 0..<20 where !tool.executed {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertTrue(tool.executed, "a developer-only tool must execute normally on a .developer channel")
        XCTAssertEqual(responses.first?["type"] as? String, "agent-framework:mcp:result")
    }

    func testPlainHostToolInvokesNormallyOnEndUserChannel() async throws {
        let registry = RipulToolRegistry()
        let bridge = AgentBridge(registry: registry, audience: .endUser)
        let tool = RecordingTool(name: "host_tool")
        registry.register([tool], audience: .endUser)

        var responses: [[String: Any]] = []
        bridge.testOutboundSink = { responses.append($0) }
        bridge.handleMessage(invokeMessage("host_tool"))

        for _ in 0..<20 where !tool.executed {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertTrue(tool.executed)
        XCTAssertEqual(responses.first?["type"] as? String, "agent-framework:mcp:result")
    }
}
