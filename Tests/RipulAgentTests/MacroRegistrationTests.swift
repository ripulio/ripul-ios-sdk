import XCTest
@testable import RipulAgent

/// Phase-4 (automation-macros): proves `MacroRegistrationPlanner`'s output,
/// once fed into `RipulToolRegistry.setTools(_:audience:)` exactly as
/// `RipulAgentConsole.refreshMacroTools()` does, produces the right
/// broadcast/invoke exposure on a real `AgentBridge` — using the same
/// in-process bridge harness `ToolRegistryTests`/`ChannelGateTests` already
/// established (`testOutboundSink`, synthesized messages, no webview).
///
/// A plain fake `NativeTool` stands in for `MacroTool` here — the registry
/// doesn't know or care about the concrete type, only its audience tag, and
/// `MacroTool` itself needs live UIKit (proven separately, on-device, in
/// `MacroReplayFixtureUITests`). What's new and needs proving HERE is the
/// registration/exposure wiring, not replay.
@MainActor
final class MacroRegistrationTests: XCTestCase {

    private final class FakeMacroTool: NativeTool {
        let name: String
        let description = "fake macro tool"
        let inputSchema: [String: Any] = [:]
        private(set) var executed = false
        init(name: String) { self.name = name }
        func execute(args: [String: Any]) async throws -> Any {
            executed = true
            return ["success": true]
        }
    }

    /// Mirrors `RipulAgentConsole.refreshMacroTools()` exactly: plan, then one
    /// `setTools` call per audience.
    private func register(_ macros: [RipulMacro], into registry: RipulToolRegistry) {
        let plan = MacroRegistrationPlanner.plan(macros)
        registry.setTools(plan.developer.map { FakeMacroTool(name: "run_macro_\($0.name)") }, audience: .developer)
        registry.setTools(plan.endUser.map { FakeMacroTool(name: "run_macro_\($0.name)") }, audience: .endUser)
    }

    private func macro(name: String, published: Bool) -> RipulMacro {
        RipulMacro(id: "id_\(name)", name: name, description: "d", steps: [], published: published,
                  createdAt: Date(), updatedAt: Date())
    }

    private func handshake() -> [String: Any] { ["type": "agent-framework:handshake"] }

    private func broadcastNames(_ bridge: AgentBridge) -> [String] {
        var broadcasts: [[String: Any]] = []
        bridge.testOutboundSink = { broadcasts.append($0) }
        bridge.handleMessage(handshake())
        let toolsMessage = broadcasts.first { ($0["type"] as? String) == "agent-framework:mcp:tools" }
        return (toolsMessage?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
    }

    // MARK: - Broadcast exposure follows published

    func testPublishedMacroReachesEndUserBroadcastDraftDoesNot() {
        let registry = RipulToolRegistry()
        register([macro(name: "clock_in", published: true), macro(name: "draft_flow", published: false)], into: registry)

        let endUserBridge = AgentBridge(registry: registry, audience: .endUser)
        let names = broadcastNames(endUserBridge)
        XCTAssertTrue(names.contains("run_macro_clock_in"))
        XCTAssertFalse(names.contains("run_macro_draft_flow"))
    }

    func testDraftMacroReachesDeveloperBroadcastNotPublishedOnesAlone() {
        let registry = RipulToolRegistry()
        register([macro(name: "clock_in", published: true), macro(name: "draft_flow", published: false)], into: registry)

        let devBridge = AgentBridge(registry: registry, audience: .developer)
        let names = broadcastNames(devBridge)
        XCTAssertTrue(names.contains("run_macro_draft_flow"))
        XCTAssertFalse(names.contains("run_macro_clock_in"), "published macros require phase-2-style absorption, never ambient exposure on .developer")
    }

    /// The incumbent pin: re-registering (as `refreshMacroTools` does on every
    /// console attach) must not let a draft leak into `.endUser` on some later
    /// call even though it didn't on the first.
    func testUnpublishedMacroStaysOffEndUserAcrossRepeatedRegistration() {
        let registry = RipulToolRegistry()
        let bridge = AgentBridge(registry: registry, audience: .endUser)
        for _ in 0..<5 {
            register([macro(name: "clock_in", published: true), macro(name: "draft_flow", published: false)], into: registry)
            let names = broadcastNames(bridge)
            XCTAssertFalse(names.contains("run_macro_draft_flow"))
        }
    }

    // MARK: - Publishing moves a tool between audiences live (no restart)

    func testPublishingMovesTheToolFromDeveloperToEndUserOnReRegistration() {
        let registry = RipulToolRegistry()
        register([macro(name: "clock_in", published: false)], into: registry)
        XCTAssertTrue(registry.tools(audience: .developer).contains { $0.name == "run_macro_clock_in" })
        XCTAssertFalse(registry.tools(audience: .endUser).contains { $0.name == "run_macro_clock_in" })

        // Publish, then refresh — exactly what MacroClient.update(published:)
        // followed by refreshMacroTools() does.
        register([macro(name: "clock_in", published: true)], into: registry)
        XCTAssertFalse(registry.tools(audience: .developer).contains { $0.name == "run_macro_clock_in" })
        XCTAssertTrue(registry.tools(audience: .endUser).contains { $0.name == "run_macro_clock_in" })
    }

    // MARK: - Invocation — a published macro tool is genuinely callable on .endUser

    func testPublishedMacroToolInvokesOnEndUserChannel() async throws {
        let registry = RipulToolRegistry()
        register([macro(name: "clock_in", published: true)], into: registry)
        let bridge = AgentBridge(registry: registry, audience: .endUser)
        let tool = registry.tools(audience: .endUser).first as? FakeMacroTool

        var responses: [[String: Any]] = []
        bridge.testOutboundSink = { responses.append($0) }
        bridge.handleMessage([
            "type": "agent-framework:mcp:invoke",
            "requestId": UUID().uuidString,
            "toolName": "run_macro_clock_in",
            "args": [String: Any](),
        ])

        for _ in 0..<20 where tool?.executed != true {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(tool?.executed, true)
        XCTAssertEqual(responses.first?["type"] as? String, "agent-framework:mcp:result")
    }

    // MARK: - Duplicate-name safety (README decision: fail past a data race, don't crash)

    func testDuplicateNameFromAFetchRaceDoesNotCrashRegistration() {
        let registry = RipulToolRegistry()
        let older = RipulMacro(id: "id_old", name: "clock_in", description: "d", steps: [], published: true,
                               createdAt: Date(timeIntervalSince1970: 100), updatedAt: Date(timeIntervalSince1970: 100))
        let newer = RipulMacro(id: "id_new", name: "clock_in", description: "d", steps: [], published: true,
                               createdAt: Date(timeIntervalSince1970: 200), updatedAt: Date(timeIntervalSince1970: 200))
        // Two rows with the same name (a fetch race, or a scoping edge case) —
        // registering both under the same audience would hit RipulToolRegistry's
        // own duplicate-name fail-loud gate if dedup didn't happen first.
        register([older, newer], into: registry)
        XCTAssertEqual(registry.tools(audience: .endUser).map(\.name), ["run_macro_clock_in"])
    }
}
