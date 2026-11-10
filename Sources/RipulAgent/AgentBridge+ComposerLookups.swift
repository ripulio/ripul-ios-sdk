import Foundation

/// What the composer offers while typing: slash commands, files, page
/// elements, people and completions.
extension AgentBridge {
    /// Fetch the list of available slash commands from the web app.
    /// Pass `showHidden: true` to get hidden debug commands (the /rr. menu).
    public func getSlashCommands(showHidden: Bool = false) async -> [SlashCommandInfo] {
        let reply = await callPage("__ripulGetSlashCommands", [showHidden], .orElse("[]"))
        guard let array = reply.value as? [[String: Any]] else { return [] }
        return array.compactMap { dict in
            guard let command = dict["command"] as? String,
                  let description = dict["description"] as? String else { return nil }
            var options: [SlashCommandOption] = []
            if let rawOptions = dict["options"] as? [[String: Any]] {
                options = rawOptions.compactMap { o in
                    guard let value = o["value"] as? String,
                          let label = o["label"] as? String else { return nil }
                    return SlashCommandOption(value: value, label: label, description: o["description"] as? String)
                }
            }
            return SlashCommandInfo(
                command: command,
                description: description,
                icon: dict["icon"] as? String,
                type: (dict["type"] as? String) ?? "template",
                hasVariables: (dict["hasVariables"] as? Bool) ?? false,
                options: options
            )
        }
    }

    /// Query the remote host for file suggestions matching a partial path/name.
    /// Used by the native @files autocomplete in NativeChatInput.
    /// Returns an array of dictionaries with `path` (String) and `isDirectory` (Bool).
    public func queryRemoteFiles(query: String) async -> [[String: Any]] {
        guard !query.isEmpty else { return [] }
        let reply = await callPage("__ripulQueryRemoteFiles", [query], .orElse("{ files: [] }"))
        return reply.dictionary?["files"] as? [[String: Any]] ?? []
    }

    public func queryPageElements() async -> [String] {
        await callPage("__ripulQueryPageElements", [], .orElse("[]")).value as? [String] ?? []
    }

    /// Query the chat's participant catalog (agents, plus humans in the future).
    /// Used by the native @people picker in NativeChatInput.
    /// Returns an array of dictionaries with `id`, `name`, `group`, and `kind`.
    /// Names the chat when the caller must not follow a change of the active one.
    public func queryParticipants(chatId: String? = nil) async -> [[String: Any]] {
        let reply = await callPage("__ripulQueryParticipants", chatId.map { [$0] } ?? [], .orElse("{ participants: [] }"))
        return reply.dictionary?["participants"] as? [[String: Any]] ?? []
    }

    /// Invite a teammate into the active chat by email — the same owner-issued
    /// invitation the share sheet's "Invite by Email" sends. Returns a
    /// user-facing error message, or nil on success.
    public func inviteTeammate(email: String) async -> String? {
        let reply = await callPage("__ripulInviteToSession", [email], .orElse("{ success: false, error: 'Invitations unavailable' }"))
        if let reason = reply.failure(detached: "The chat isn't ready yet") { return reason }
        guard let dict = reply.dictionary else { return "Unexpected response" }
        if dict["success"] as? Bool == true {
            NotificationCenter.default.post(name: .ripulChatMembershipChanged, object: nil)
            return nil
        }
        return dict["error"] as? String ?? "Invitation failed"
    }

    /// Make a room (docs/plans/rooms.md): a chat with no model, kept by Ripul's
    /// server, where people talk and ask agents by name. Returns the room's tab
    /// id, ready to focus, or throws with words for a person.
    public func createRoom(title: String) async throws -> String {
        let reply = await callPage("__ripulCreateRoom", [title], .orElse("{ success: false, error: 'Rooms are unavailable' }"))
        if let reason = reply.failure(detached: "Ripul isn't ready yet") { throw RoomCreationError(message: reason) }
        guard let dict = reply.dictionary else { throw RoomCreationError(message: "Unexpected response") }
        if dict["success"] as? Bool == true, let chatId = dict["chatId"] as? String, !chatId.isEmpty { return chatId }
        throw RoomCreationError(message: dict["error"] as? String ?? "The room could not be made.")
    }

    /// The icon a chat offered under @ Chats wears: the one given it in the chat
    /// list (`SessionListStore.customIcon`), else its provider's, as its row there shows.
    public func chatSuggestionIcon(_ suggestion: [String: Any]) -> String? {
        let sessionId = suggestion["sessionId"] as? String
        let keys: [String?] = [suggestion["chatId"] as? String, sessionId,
                               sessionId?.split(separator: ":").last.map(String.init)]
        if let custom = sessionList.customIcon(anyOf: keys) { return custom }
        guard let provider = suggestion["provider"] as? String, !provider.isEmpty else { return nil }
        return ProviderConstants.icon(for: provider, providerLabel: nil)
    }

    /// Query the web view for autocomplete suggestions for a given category and query string.
    /// Used by the native @ picker in NativeChatInput.
    /// Returns an array of dictionaries representing standard suggestions.
    public func queryAutocomplete(category: String, query: String) async -> [[String: Any]] {
        let reply = await callPage("__ripulQueryAutocomplete", [category, query], .orElse("{ suggestions: [] }"))
        return reply.dictionary?["suggestions"] as? [[String: Any]] ?? []
    }
}

/// Why a room could not be made, in words for a person (`AgentBridge.createRoom`).
public struct RoomCreationError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}
