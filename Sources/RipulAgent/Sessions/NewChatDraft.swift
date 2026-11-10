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
    public let teamName: String?
    /// SF Symbol the user gave this Mac; `nil` uses the generic computer.
    public let icon: String?
    public init(id: String, name: String, connection: NewChatConnection, unavailableReason: String? = nil,
                teamName: String? = nil, icon: String? = nil) {
        self.id = id; self.name = name; self.connection = connection; self.unavailableReason = unavailableReason
        self.teamName = teamName; self.icon = icon
    }

    /// The Relay choice that starts the chat on the account's Mac with the
    /// most room that has the folder's repository, chosen when it starts
    /// (the page's `__ripulChooseNewChatMac`). Work follows the chat, so a
    /// chat started on the busiest Mac keeps loading it.
    public static let automaticID = "automatic"
    public static let automatic = NewChatMachine(id: automaticID, name: "Automatic", connection: .relay, icon: "a.circle")
    public var isAutomatic: Bool { id == Self.automaticID }

    /// The account's own Relay Macs that can take a chat now: what Automatic chooses among.
    public static func automaticCandidates(_ available: [NewChatMachine]) -> [NewChatMachine] {
        available.filter { $0.connection == .relay && !$0.isAutomatic && $0.teamName == nil && $0.unavailableReason == nil }
    }
    /// Automatic is offered when the account has two or more of its own Relay Macs.
    public static func offersAutomatic(_ available: [NewChatMachine]) -> Bool {
        available.filter { $0.connection == .relay && !$0.isAutomatic && $0.teamName == nil }.count >= 2
    }
}

/// Creation preferences only. Nothing here edits an existing chat or its owner.
public struct NewChatDraft: Codable, Equatable {
    public var connection: NewChatConnection = .relay
    public private(set) var machines: [String: String] = [:]
    public private(set) var machineNames: [String: String] = [:]
    public private(set) var folders: [String: String] = [:]
    /// Set once Automatic has been offered. A Relay Mac remembered before
    /// then was mostly the last Mac used, not a choice, and kept every new
    /// chat on the Studio (6 November 2026), so it is forgotten once.
    private var automaticOffered: Bool?

    public init(data: Data? = nil, forcedConnection: NewChatConnection? = nil) {
        if let data, let saved = try? JSONDecoder().decode(Self.self, from: data) {
            self = saved
            if saved.automaticOffered != true {
                machines[NewChatConnection.relay.rawValue] = nil
                machineNames[NewChatConnection.relay.rawValue] = nil
            }
        }
        automaticOffered = true
        if let forcedConnection { connection = forcedConnection }
    }
    public var isAutomatic: Bool { connection == .relay && machineID == NewChatMachine.automaticID }
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
    /// The sheet was opened from a machine row: that Mac is the destination,
    /// whatever was remembered. Remembering only seeds a sheet opened from
    /// nowhere in particular. An unlisted id still selects, so validation names
    /// it unavailable rather than launching on the remembered Mac.
    public mutating func selectRequested(relayID: String, from available: [NewChatMachine]) {
        select(available.first(where: { $0.connection == .relay && $0.id == relayID })
            ?? NewChatMachine(id: relayID, name: "The selected Mac", connection: .relay))
    }
    /// When the Relay/Direct switch is hidden, stick to the connection the user
    /// set the Mac up with: Relay whenever a Relay Mac exists (the common setup),
    /// or Direct when only Direct Macs are configured or Standalone mode is active.
    public static func resolvedConnection(for available: [NewChatMachine], allowsRelay: Bool = true,
                                          allowsDirectSwitching: Bool = false,
                                          preferredDirectID: String? = nil) -> NewChatConnection? {
        if !allowsRelay { return .direct }
        guard !allowsDirectSwitching else { return nil }
        if preferredDirectID != nil { return .direct }
        let hasRelay = available.contains(where: { $0.connection == .relay })
        let hasDirect = available.contains(where: { $0.connection == .direct })
        return hasRelay ? .relay : (hasDirect ? .direct : .relay)
    }
    /// With nothing chosen, Relay starts on Automatic when the account has
    /// two or more Macs of its own, before any default Mac.
    public mutating func selectInitial(from available: [NewChatMachine], preferredRelayID: String? = nil) {
        // A removed/offline remembered host must remain visibly unavailable.
        guard machineID == nil else { return }
        let candidates = available.filter { $0.connection == connection }
        if connection == .relay, NewChatMachine.offersAutomatic(available) { select(.automatic) }
        else if connection == .relay, let preferred = candidates.first(where: { $0.id == preferredRelayID }) { select(preferred) }
        else if candidates.count == 1 { select(candidates[0]) }
    }
    public func validationError(in available: [NewChatMachine]) -> String? {
        guard let machineID else { return "Choose a Mac to start a chat." }
        if isAutomatic {
            guard NewChatMachine.offersAutomatic(available) else { return "Choose a Mac to start a chat." }
            guard !NewChatMachine.automaticCandidates(available).isEmpty else { return "None of your Macs is online. Choose a Mac or reconnect one." }
            let path = folder.trimmingCharacters(in: .whitespacesAndNewlines)
            guard path.isEmpty || (path.hasPrefix("/") && !path.contains("\0")) else { return "Choose an absolute project folder, or use the Mac's configured working directory." }
            return nil
        }
        guard let machine = available.first(where: { $0.connection == connection && $0.id == machineID }) else {
            return "\(machineName ?? "The selected Mac") is unavailable. Choose a Mac or reconnect it."
        }
        if let reason = machine.unavailableReason { return reason }
        let path = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.isEmpty || (path.hasPrefix("/") && !path.contains("\0")) else { return "Choose an absolute project folder, or use the Mac's configured working directory." }
        return nil
    }
}

/// Folders chats were started in from New Chat, most recent first, per
/// destination Mac. Built only from explicit picks: the Mac's configured
/// default is resolved on the Mac, so its path is never known here.
public struct NewChatRecentFolders: Codable, Equatable {
    public static let preferencesKey = "ripul.newChat.recentFolders"
    public static let limit = 4
    private var folders: [String: [String]] = [:]

    public init(data: Data? = nil) {
        if let data, let saved = try? JSONDecoder().decode(Self.self, from: data) { self = saved }
    }
    public var data: Data? { try? JSONEncoder().encode(self) }
    public func folders(connection: NewChatConnection, machineID: String) -> [String] {
        folders[Self.key(connection, machineID)] ?? []
    }
    /// Moves `folder` to the front, dropping the oldest beyond `limit`.
    public mutating func record(_ folder: String, connection: NewChatConnection, machineID: String) {
        var path = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        guard path.hasPrefix("/"), !machineID.isEmpty else { return }
        let key = Self.key(connection, machineID)
        folders[key] = Array(([path] + (folders[key] ?? []).filter { $0 != path }).prefix(Self.limit))
    }
    private static func key(_ connection: NewChatConnection, _ machineID: String) -> String {
        connection.rawValue + ":" + machineID
    }
}

public struct NewChatLaunch: Equatable {
    public let requestID: String
    public let connection: NewChatConnection
    public private(set) var machineID: String
    public private(set) var folder: String
    public let modelID: String
    /// Applied once the chat exists, so it is not part of the creation
    /// identity: retitling a failed attempt still retries the same request.
    public var title = ""
    public init(draft: NewChatDraft, modelID: String, previous: NewChatLaunch? = nil) {
        connection = draft.connection; machineID = draft.machineID ?? ""
        folder = draft.folder.trimmingCharacters(in: .whitespacesAndNewlines); self.modelID = modelID
        if let previous, previous.connection == connection, previous.machineID == machineID,
           previous.folder == folder, previous.modelID == modelID { requestID = previous.requestID }
        else { requestID = UUID().uuidString.lowercased() }
    }
    /// The same request, sent to the Mac Automatic chose and the folder there.
    public func placed(on machineID: String, folder: String) -> Self {
        var copy = self; copy.machineID = machineID; copy.folder = folder
        return copy
    }
}
