import Foundation

public enum NewChatConnection: String, CaseIterable, Codable {
    case relay, direct
    public var title: String { self == .relay ? "Relay" : "Direct" }
}

public struct NewChatMachine: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let connection: NewChatConnection
    public let unavailableReason: String?
    public init(id: String, name: String, connection: NewChatConnection, unavailableReason: String? = nil) {
        self.id = id; self.name = name; self.connection = connection; self.unavailableReason = unavailableReason
    }
}

/// Creation preferences only. Nothing here edits an existing chat or its owner.
public struct NewChatDraft: Codable, Equatable {
    public var connection: NewChatConnection = .relay
    public private(set) var machines: [String: String] = [:]
    public private(set) var machineNames: [String: String] = [:]
    public private(set) var folders: [String: String] = [:]

    public init(data: Data? = nil, forcedConnection: NewChatConnection? = nil) {
        if let data, let saved = try? JSONDecoder().decode(Self.self, from: data) { self = saved }
        if let forcedConnection { connection = forcedConnection }
    }
    public var data: Data? { try? JSONEncoder().encode(self) }
    public var machineID: String? { machines[connection.rawValue] }
    public var machineName: String? { machineNames[connection.rawValue] }
    private var folderKey: String { connection.rawValue + ":" + (machineID ?? "") }
    public var folder: String {
        get { folders[folderKey] ?? "" }
        set { if machineID != nil { folders[folderKey] = newValue } }
    }
    /// Remembered project paths are suggestions until explicitly enabled in
    /// this New Chat sheet. An automatic launch never inherits an old override.
    public func forLaunch(usingCustomFolder: Bool) -> Self {
        var launch = self
        if !usingCustomFolder { launch.folder = "" }
        return launch
    }
    public mutating func select(_ machine: NewChatMachine) {
        connection = machine.connection
        machines[connection.rawValue] = machine.id
        machineNames[connection.rawValue] = machine.name
    }
    public mutating func selectInitial(from available: [NewChatMachine], preferredRelayID: String? = nil) {
        // A removed/offline remembered host must remain visibly unavailable.
        guard machineID == nil else { return }
        let candidates = available.filter { $0.connection == connection }
        if connection == .relay, let preferred = candidates.first(where: { $0.id == preferredRelayID }) { select(preferred) }
        else if candidates.count == 1 { select(candidates[0]) }
    }
    public func validationError(in available: [NewChatMachine]) -> String? {
        guard let machineID else { return "Choose a Mac to start a chat." }
        guard let machine = available.first(where: { $0.connection == connection && $0.id == machineID }) else {
            return "\(machineName ?? "The selected Mac") is unavailable. Choose a Mac or reconnect it."
        }
        if let reason = machine.unavailableReason { return reason }
        let path = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.isEmpty || (path.hasPrefix("/") && !path.contains("\0")) else { return "Enter an absolute project folder, or use the automatic Ripul workspace." }
        return nil
    }
}

public struct NewChatLaunch: Equatable {
    public let requestID: String
    public let connection: NewChatConnection
    public let machineID: String
    public let folder: String
    public let modelID: String
    public init(draft: NewChatDraft, modelID: String, previous: NewChatLaunch? = nil) {
        connection = draft.connection; machineID = draft.machineID ?? ""
        folder = draft.folder.trimmingCharacters(in: .whitespacesAndNewlines); self.modelID = modelID
        if let previous, previous.connection == connection, previous.machineID == machineID,
           previous.folder == folder, previous.modelID == modelID { requestID = previous.requestID }
        else { requestID = UUID().uuidString.lowercased() }
    }
}
