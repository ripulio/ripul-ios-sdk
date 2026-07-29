import XCTest
@testable import RipulAgent

/// Phase-1 gate (native-tool-registry): the registry's contract and the
/// channel's audience PROJECTION — which is a different mechanism from the
/// phase-0 marker gate (`ChannelGateTests`). The projection filters by the
/// entry's audience TAG; the marker gate re-asserts that SDK dev tools never
/// reach an `.endUser` channel even if a tag is wrong. Both are pinned here.
@MainActor
final class ToolRegistryTests: XCTestCase {

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

    /// Marked like the real SDK dev tools, but TAGGED `.endUser` in tests —
    /// the mis-tag case the marker gate exists to survive.
    private final class MarkedTool: RipulDeveloperOnlyTool {
        let name: String
        let description = "test tool"
        let inputSchema: [String: Any] = [:]
        init(name: String) { self.name = name }
        func execute(args: [String: Any]) async throws -> Any { ["ok": true] }
    }

    private func handshake() -> [String: Any] { ["type": "agent-framework:handshake"] }

    private func broadcastNames(_ bridge: AgentBridge) -> [String] {
        var broadcasts: [[String: Any]] = []
        bridge.testOutboundSink = { broadcasts.append($0) }
        bridge.handleMessage(handshake())
        let toolsMessage = broadcasts.first { ($0["type"] as? String) == "agent-framework:mcp:tools" }
        return (toolsMessage?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
    }

    // MARK: - Registry contract

    func testRegistrationOrderAndAudienceProjection() {
        let registry = RipulToolRegistry()
        registry.register([PlainTool(name: "a"), PlainTool(name: "b")], audience: .endUser)
        registry.register([PlainTool(name: "dev_x")], audience: .developer)

        XCTAssertEqual(registry.tools(audience: .endUser).map(\.name), ["a", "b"])
        XCTAssertEqual(registry.tools(audience: .developer).map(\.name), ["dev_x"])
        XCTAssertEqual(registry.allEntries.map(\.tool.name), ["a", "b", "dev_x"])
    }

    func testAudienceLookupIsCanonical() {
        let registry = RipulToolRegistry()
        registry.register([PlainTool(name: "get_events")], audience: .endUser)
        // A collection stores the transport-prefixed name a CLI session saw.
        XCTAssertEqual(registry.audience(ofToolNamed: "device_get_events"), .endUser)
        XCTAssertNil(registry.audience(ofToolNamed: "not_registered"))
    }

    func testEditorCatalogsProjectHostSurfaces() {
        let registry = RipulToolRegistry()
        XCTAssertTrue(registry.editorCatalogs().isEmpty, "no tools → no catalogs, not empty ones")

        registry.register([PlainTool(name: "a")], audience: .endUser)
        registry.register([PlainTool(name: "dev_x")], audience: .developer)
        let catalogs = registry.editorCatalogs()
        // Developer tools are the CONSOLE CHANNEL's projection, appended by the
        // console itself — the registry only projects host-owned surfaces.
        XCTAssertEqual(catalogs.map(\.id), [RipulToolCatalog.endUserId])
        XCTAssertEqual(catalogs.first?.toolNames, ["a"])
    }

    // MARK: - Channel projection (audience tags, distinct from the marker gate)

    func testEndUserChannelDoesNotExposeDeveloperTaggedEntries() {
        // A PLAIN tool tagged .developer: the marker gate would not catch it —
        // only the audience projection keeps it off the end-user channel.
        let registry = RipulToolRegistry()
        registry.register([PlainTool(name: "plain_dev_tool")], audience: .developer)
        registry.register([PlainTool(name: "user_tool")], audience: .endUser)
        let bridge = AgentBridge(registry: registry, audience: .endUser)

        let names = broadcastNames(bridge)
        XCTAssertTrue(names.contains("user_tool"))
        XCTAssertFalse(names.contains("plain_dev_tool"), "developer-tagged entry leaked into an .endUser projection")
    }

    func testDeveloperChannelDoesNotExposeEndUserEntriesWithoutAbsorption() {
        let registry = RipulToolRegistry()
        registry.register([PlainTool(name: "user_tool")], audience: .endUser)
        registry.register([PlainTool(name: "dev_tool")], audience: .developer)
        let bridge = AgentBridge(registry: registry, audience: .developer)

        let names = broadcastNames(bridge)
        XCTAssertTrue(names.contains("dev_tool"))
        XCTAssertFalse(names.contains("user_tool"), "end-user tools require phase-2 testing mode, never ambient exposure")
    }

    func testMisTaggedMarkedToolStillGatedOnEndUserChannel() {
        // Defense in depth: even TAGGED .endUser, a RipulDeveloperOnlyTool
        // never crosses to an .endUser channel — the phase-0 marker gate
        // holds against a wrong tag.
        let registry = RipulToolRegistry()
        registry.register([MarkedTool(name: "marked_tool")], audience: .endUser)
        let bridge = AgentBridge(registry: registry, audience: .endUser)

        XCTAssertFalse(broadcastNames(bridge).contains("marked_tool"))
    }

    func testRegistryChangeAfterConnectionRebroadcasts() async throws {
        let registry = RipulToolRegistry()
        let bridge = AgentBridge(registry: registry, audience: .endUser)
        registry.register([PlainTool(name: "early_tool")], audience: .endUser)

        var broadcasts: [[String: Any]] = []
        bridge.testOutboundSink = { broadcasts.append($0) }
        bridge.handleMessage(handshake())
        registry.register([PlainTool(name: "late_tool")], audience: .endUser)

        // The observer hops through a MainActor task; let it land.
        for _ in 0..<20 {
            await Task.yield()
            if broadcasts.filter({ ($0["type"] as? String) == "agent-framework:mcp:tools" }).count >= 2 { break }
        }

        // Count is >= 2, not exactly 2: a pre-handshake registration's deferred
        // observer task can land after connection and emit an extra broadcast
        // of identical content — harmless on the wire (the web side diffs).
        // What matters is that a broadcast happened after the late
        // registration and that the final list carries both tools.
        let toolLists = broadcasts
            .filter { ($0["type"] as? String) == "agent-framework:mcp:tools" }
            .map { ($0["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? [] }
        XCTAssertGreaterThanOrEqual(toolLists.count, 2, "late registration must re-broadcast mcp:tools")
        XCTAssertEqual(toolLists.last, ["early_tool", "late_tool"])
    }

    func testTwoRegistriesInOneProcessStayIsolated() {
        // WAC's isolated-instance pattern: two hosts, two registries, no bleed.
        let registryA = RipulToolRegistry()
        let registryB = RipulToolRegistry()
        registryA.register([PlainTool(name: "a_tool")], audience: .endUser)
        registryB.register([PlainTool(name: "b_tool")], audience: .endUser)

        let bridgeA = AgentBridge(registry: registryA, audience: .endUser)
        let bridgeB = AgentBridge(registry: registryB, audience: .endUser)
        XCTAssertEqual(broadcastNames(bridgeA), ["a_tool"])
        XCTAssertEqual(broadcastNames(bridgeB), ["b_tool"])
    }
}
