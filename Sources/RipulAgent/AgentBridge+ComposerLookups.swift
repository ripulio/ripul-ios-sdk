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
    public func queryParticipants() async -> [[String: Any]] {
        let reply = await callPage("__ripulQueryParticipants", [], .orElse("{ participants: [] }"))
        return reply.dictionary?["participants"] as? [[String: Any]] ?? []
    }

    /// Invite a teammate into the active chat by email — the same owner-issued
    /// invitation the share sheet's "Invite by Email" sends. Returns a
    /// user-facing error message, or nil on success.
    public func inviteTeammate(email: String) async -> String? {
        let reply = await callPage("__ripulInviteToSession", [email], .orElse("{ success: false, error: 'Invitations unavailable' }"))
        if let reason = reply.failure(detached: "The chat isn't ready yet") { return reason }
        guard let dict = reply.dictionary else { return "Unexpected response" }
        if dict["success"] as? Bool == true { return nil }
        return dict["error"] as? String ?? "Invitation failed"
    }

    /// Query the web view for autocomplete suggestions for a given category and query string.
    /// Used by the native @ picker in NativeChatInput.
    /// Returns an array of dictionaries representing standard suggestions.
    public func queryAutocomplete(category: String, query: String) async -> [[String: Any]] {
        let reply = await callPage("__ripulQueryAutocomplete", [category, query], .orElse("{ suggestions: [] }"))
        return reply.dictionary?["suggestions"] as? [[String: Any]] ?? []
    }
}
