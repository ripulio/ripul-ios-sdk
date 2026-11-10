import Foundation

public extension Notification.Name {
    static let ripulWorkScopeChanged = Notification.Name("ripulWorkScopeChanged")
}

/// The working directory for new chats, resolved by the web layer.
public struct WorkScopeState: Codable, Sendable {
    public let effective: String?
    public let source: String
    public let options: [String]
    public let machineName: String?
}

extension AgentBridge {
    /// Empty chatId uses the app's chosen machine and directory.
    public func workScope(chatId: String) async -> WorkScopeState? {
        let reply = await callPage("__ripulWorkScope", [chatId])
        guard let dict = reply.dictionary, dict["error"] == nil,
              let source = dict["source"] as? String, let options = dict["options"] as? [String]
        else { return nil }
        return WorkScopeState(effective: dict["effective"] as? String, source: source,
                              options: options, machineName: dict["machineName"] as? String)
    }

    /// Nil clears the app's override and restores the default directory.
    public func setWorkScope(path: String?) async -> Bool {
        let reply = await callPage("__ripulSetWorkScope", [path])
        return reply.dictionary?["ok"] as? Bool == true
    }
}
