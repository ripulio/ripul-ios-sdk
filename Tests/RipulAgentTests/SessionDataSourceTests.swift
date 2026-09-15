import XCTest
@testable import RipulAgent

@MainActor
final class SessionDataSourceTests: XCTestCase {
    private final class Source: RipulSessionDataSource {
        var snapshot = RipulSessionSourceSnapshot(machines: [], sessionsByMachineID: [:])
        var loads = 0
        var opened: String?
        var failure: Error?
        func load() async throws -> RipulSessionSourceSnapshot {
            loads += 1
            if let failure { throw failure }
            return snapshot
        }
        func open(_ session: UnifiedSession, bridge: AgentBridge) async throws -> ChatSession {
            opened = session.machineId
            if let failure { throw failure }
            return ChatSession(id: session.metadataKey, sourceChatId: session.metadataKey,
                               displayName: session.title, createdAt: session.lastUsed)
        }
    }
    private func machine(_ id: String) throws -> RemoteMachine {
        let raw: [String: Any] = ["machineId": id, "displayName": "Mac", "userId": "", "roomId": "",
                                  "registeredAt": "", "lastSeenAt": "", "meta": ["hostKind": "native", "caps": "cli"]]
        return try JSONDecoder().decode(RemoteMachine.self, from: JSONSerialization.data(withJSONObject: raw))
    }
    private func row(_ id: String, machine: String) throws -> RemoteSessionInfo {
        let raw: [String: Any] = ["id": "direct:\(machine):\(id)", "sourceChatId": id, "displayName": id,
                                  "createdAt": 0, "isRunning": false, "machineId": machine, "hostChatId": id]
        return try JSONDecoder().decode(RemoteSessionInfo.self, from: JSONSerialization.data(withJSONObject: raw))
    }
    private func cache() -> RipulSessionCache { UserDefaultsSessionCache(suiteName: "io.ripul.tests.source.\(UUID().uuidString)") }

    func testDirectRefreshDoesNotRequestAnAccountToken() async throws {
        let source = Source(); let host = try machine("pin:a")
        source.snapshot = .init(machines: [host], sessionsByMachineID: [host.id: [try row("mac_one", machine: host.id)]])
        var tokenReads = 0
        let model = RipulSessionListModel(bridge: AgentBridge(), tokenProvider: { tokenReads += 1; return nil }, cache: cache(), dataSource: source)
        await model.refresh()
        XCTAssertEqual(tokenReads, 0)
        XCTAssertEqual(source.loads, 1)
        XCTAssertTrue(model.hasSuccessfulMachinesResponse)
        XCTAssertEqual(model.unifiedSessions.first?.metadataKey, "mac_one")
        XCTAssertEqual(model.unifiedSessions.first?.machineId, "pin:a")
    }

    func testFailedHostKeepsItsRowsButSuccessfulEmptyResponseRemovesThem() async throws {
        let source = Source(); let a = try machine("pin:a"); let b = try machine("pin:b")
        source.snapshot = .init(machines: [a, b], sessionsByMachineID: [a.id: [try row("mac_a", machine: a.id)], b.id: [try row("mac_b", machine: b.id)]])
        let model = RipulSessionListModel(bridge: AgentBridge(), tokenProvider: { nil }, cache: cache(), dataSource: source)
        await model.refresh()
        source.snapshot = .init(machines: [a, b], sessionsByMachineID: [b.id: []])
        await model.refresh()
        XCTAssertEqual(model.unifiedSessions.map(\.metadataKey), ["mac_a"])
        source.snapshot = .init(machines: [], sessionsByMachineID: [:])
        await model.refresh()
        XCTAssertTrue(model.unifiedSessions.isEmpty, "Forgetting the host retracts its cached rows")
    }

    func testCachedDirectHistoryReturnsBeforeTheMacAnswers() async throws {
        let source = Source(); let host = try machine("pin:a"); let savedCache = cache()
        source.snapshot = .init(machines: [host], sessionsByMachineID: [host.id: [try row("mac_one", machine: host.id)]])
        let first = RipulSessionListModel(bridge: AgentBridge(), tokenProvider: { nil }, cache: savedCache, dataSource: source)
        await first.refresh()
        let restored = RipulSessionListModel(bridge: AgentBridge(), tokenProvider: { nil }, cache: savedCache, dataSource: Source())
        XCTAssertEqual(restored.unifiedSessions.map(\.metadataKey), ["mac_one"])
    }

    func testOpeningAlwaysUsesTheOwningDirectSource() async throws {
        let source = Source(); let host = try machine("pin:owner")
        source.snapshot = .init(machines: [host], sessionsByMachineID: [host.id: [try row("mac_one", machine: host.id)]])
        let model = RipulSessionListModel(bridge: AgentBridge(), tokenProvider: { XCTFail("No account lookup"); return nil }, cache: cache(), dataSource: source)
        await model.refresh()
        let selected = expectation(description: "Direct chat opened")
        model.openSession(try XCTUnwrap(model.unifiedSessions.first), onSelect: { chat in
            XCTAssertEqual(chat.sourceChatId, "mac_one"); selected.fulfill()
        }, onDismiss: { XCTFail("Do not dismiss before the owning Mac has opened the chat") })
        await fulfillment(of: [selected], timeout: 2)
        XCTAssertEqual(source.opened, host.id)
        XCTAssertNil(model.openingUnifiedSessionId)
    }
}
