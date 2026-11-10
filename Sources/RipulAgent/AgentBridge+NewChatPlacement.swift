import Foundation

extension AgentBridge {
    /// Where the New Chat sheet's Automatic starts a chat: the Mac with the
    /// most room that has the folder's repository, and the folder there.
    public struct NewChatPlacement: Equatable {
        public let machineID: String
        public let machineName: String
        /// The folder on that Mac; nil for its configured working directory.
        public let folder: String?
        public let why: String
    }

    /// Asks the page which of `machineIDs` a new chat in `folder` (nil: the
    /// Mac's working directory) should start on. Nil when the page could not
    /// read the Macs or the folder is in no repository.
    public func chooseNewChatMac(machineIDs: [String], folder: String?) async -> NewChatPlacement? {
        let reply = await callPage("__ripulChooseNewChatMac", [machineIDs, folder], .orElse("null"), log: .console)
        guard let raw = reply.dictionary, let id = raw["machineId"] as? String, !id.isEmpty else { return nil }
        return NewChatPlacement(machineID: id, machineName: raw["machineName"] as? String ?? id,
                                folder: raw["folder"] as? String, why: raw["why"] as? String ?? "")
    }
}
