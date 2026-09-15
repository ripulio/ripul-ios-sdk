import Foundation

/// Supplies the existing Agents screen without a cloud registry or account.
/// A missing machine bucket means a failed fetch; an empty bucket is a
/// successful response with no chats. Only successful fetches retract rows.
public struct RipulSessionSourceSnapshot {
    public let machines: [RemoteMachine]
    public let sessionsByMachineID: [String: [RemoteSessionInfo]]
    public init(machines: [RemoteMachine], sessionsByMachineID: [String: [RemoteSessionInfo]]) {
        self.machines = machines
        self.sessionsByMachineID = sessionsByMachineID
    }
}

@MainActor
public protocol RipulSessionDataSource: AnyObject {
    func load() async throws -> RipulSessionSourceSnapshot
    func open(_ session: UnifiedSession, bridge: AgentBridge) async throws -> ChatSession
}
