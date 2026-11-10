import Foundation

/// The chats in brief: how many there are, and which are running on which Mac
/// (`RipulSessionListModel.chatsSummary`). For a screen that counts chats
/// rather than listing them, so a change to one chat redraws it only when a
/// count changes.
public struct ChatsSummary: Equatable, Sendable {
    /// A chat running on its Mac.
    public struct Working: Equatable, Sendable {
        public let machineId: String?
        public let machineName: String?
    }

    public let count: Int
    public let working: [Working]

    public init(_ chats: [UnifiedSession]) {
        count = chats.count
        working = chats.filter(\.runningOnHost).map { Working(machineId: $0.machineId, machineName: $0.machineName) }
    }
}
