import XCTest
@testable import RipulAgent

/// A user with the app but NO machine — an invited guest — has exactly one
/// source of session rows: the web app's tab list. These pin the behaviour
/// that used to freeze such a list after its first build (no machine ever
/// answered, so the "remote scan loaded" flag never flipped and every rebuild
/// degraded to a rematch that cannot add or re-describe a row).
@MainActor
final class GuestSessionListTests: XCTestCase {
    private func cache(machinesFetched: Bool = true) -> RipulSessionCache {
        let c = UserDefaultsSessionCache(suiteName: "io.ripul.tests.guest.\(UUID().uuidString)")
        // A machines fetch has succeeded and returned none: the settled state
        // of an account that owns no Mac.
        if machinesFetched { c.set(true, forKey: "ripul.hasSuccessfulMachinesFetch") }
        return c
    }

    /// A machine record left in the device cache by an earlier sign-in (the
    /// registry's empty answer never clears one) that is long offline.
    private func staleMachine() throws -> RemoteMachine {
        let raw: [String: Any] = ["machineId": "mac-stale", "displayName": "Old Mac", "userId": "", "roomId": "",
                                  "registeredAt": "2026-01-01T00:00:00.000Z", "lastSeenAt": "2026-01-01T00:00:00.000Z",
                                  "meta": ["hostKind": "native", "caps": "cli"]]
        return try JSONDecoder().decode(RemoteMachine.self, from: JSONSerialization.data(withJSONObject: raw))
    }

    func testAStaleOfflineMachineDoesNotFreezeTheList() async throws {
        let shared = cache()
        RemoteMachine.saveToCache([try staleMachine()], cache: shared)
        let bridge = AgentBridge()
        let model = RipulSessionListModel(bridge: bridge, tokenProvider: { nil }, cache: shared)
        XCTAssertEqual(model.machines.count, 1, "The stale record is kept for display")
        XCTAssertFalse(model.machines[0].isOnline)

        bridge.sessions = [tab("shared_1", provider: "claude-cli", model: "claude-opus-5")]
        await settle()
        XCTAssertEqual(model.unifiedSessions.map(\.id), ["shared_1"])

        bridge.sessions = [tab("shared_1", provider: "claude-cli", model: "claude-opus-5"), tab("shared_2")]
        await settle()
        XCTAssertEqual(Set(model.unifiedSessions.map(\.id)), ["shared_1", "shared_2"],
                       "An offline machine cannot answer a scan; it must not block new rows")

        let restored = RipulSessionListModel(bridge: AgentBridge(), tokenProvider: { nil }, cache: shared)
        XCTAssertEqual(Set(restored.unifiedSessions.map(\.id)), ["shared_1", "shared_2"],
                       "…nor the row cache")
    }

    func testRowsPersistEvenWhenTheMachinesFetchNeverSucceeded() async throws {
        // Slow network, or the registry unreachable: the guest still has tabs
        // to show, and the next launch must start from them.
        let shared = cache(machinesFetched: false)
        let bridge = AgentBridge()
        let first = RipulSessionListModel(bridge: bridge, tokenProvider: { nil }, cache: shared)
        bridge.sessions = [tab("shared_1", provider: "claude-cli", model: "claude-opus-5")]
        await settle()
        XCTAssertEqual(first.unifiedSessions.count, 1)
        let restored = RipulSessionListModel(bridge: AgentBridge(), tokenProvider: { nil }, cache: shared)
        XCTAssertEqual(restored.unifiedSessions.map(\.id), ["shared_1"])
    }

    private func tab(_ id: String, provider: String? = nil, model: String? = nil) -> ChatSession {
        ChatSession(id: id, sourceChatId: id, displayName: "Shared chat \(id)", createdAt: Date(),
                    remoteMachineName: "Shared Chat", provider: provider,
                    providerLabel: provider == nil ? nil : "Claude", model: model, isSharedGuest: true)
    }

    /// The `$sessions` sink is throttled (500ms, latest wins); give it time.
    private func settle() async {
        try? await Task.sleep(nanoseconds: 800_000_000)
    }

    func testAChatJoinedAfterTheFirstBuildStillAppears() async throws {
        let bridge = AgentBridge()
        let model = RipulSessionListModel(bridge: bridge, tokenProvider: { nil }, cache: cache())
        XCTAssertTrue(model.machines.isEmpty)

        bridge.sessions = [tab("shared_1")]
        await settle()
        XCTAssertEqual(model.unifiedSessions.map(\.id), ["shared_1"])

        // Second invite accepted while the app is running.
        bridge.sessions = [tab("shared_1"), tab("shared_2")]
        await settle()
        XCTAssertEqual(Set(model.unifiedSessions.map(\.id)), ["shared_1", "shared_2"],
                       "A guest's list must accept a new tab without a relaunch")
    }

    func testAnOrphanRowFollowsItsTabsProviderAndModel() async throws {
        let bridge = AgentBridge()
        let model = RipulSessionListModel(bridge: bridge, tokenProvider: { nil }, cache: cache())

        bridge.sessions = [tab("shared_1")]
        await settle()
        XCTAssertNil(model.unifiedSessions.first?.provider)
        XCTAssertFalse(model.unifiedSessions.first?.isCliSession ?? true)

        // SessionChannel facts arrive: the web now knows the model and provider.
        bridge.sessions = [tab("shared_1", provider: "claude-cli", model: "claude-opus-5")]
        await settle()
        let row = try XCTUnwrap(model.unifiedSessions.first)
        XCTAssertEqual(row.provider, "claude-cli")
        XCTAssertEqual(row.model, "claude-opus-5")
        XCTAssertTrue(row.isCliSession, "The row's icon and CLI branches follow the tab")
        XCTAssertTrue(row.isSharedGuest)
    }

    func testTheRowCacheIsWrittenSoTheNextLaunchStartsPopulated() async throws {
        let shared = cache()
        let bridge = AgentBridge()
        let first = RipulSessionListModel(bridge: bridge, tokenProvider: { nil }, cache: shared)
        bridge.sessions = [tab("shared_1", provider: "claude-cli", model: "claude-opus-5")]
        await settle()
        XCTAssertEqual(first.unifiedSessions.count, 1)

        let restored = RipulSessionListModel(bridge: AgentBridge(), tokenProvider: { nil }, cache: shared)
        XCTAssertEqual(restored.unifiedSessions.map(\.id), ["shared_1"],
                       "A guest's rows must survive a relaunch from the cache")
        XCTAssertEqual(restored.unifiedSessions.first?.provider, "claude-cli")
    }

    func testTheWireDecoderReadsTheModelOnBothPaths() throws {
        let wire: [String: Any] = [
            "id": "shared_1", "sourceChatId": "shared_1", "displayName": "Shared", "createdAt": 1_700_000_000_000.0,
            "provider": "claude-cli", "providerLabel": "Claude", "modelId": "claude-opus-5",
            "hostChatId": "cli_abc", "isSharedGuest": true, "projectName": "ripul", "gitBranch": "main",
        ]
        let session = try XCTUnwrap(ChatSession.fromWire(wire))
        XCTAssertEqual(session.model, "claude-opus-5")
        XCTAssertEqual(session.provider, "claude-cli")
        XCTAssertEqual(session.hostChatId, "cli_abc")
        XCTAssertEqual(session.isSharedGuest, true)
        XCTAssertEqual(session.projectName, "ripul")
        XCTAssertEqual(session.gitBranch, "main")
        XCTAssertNil(ChatSession.fromWire(["id": "x"]), "A row without its identity fields is dropped")
    }
}
