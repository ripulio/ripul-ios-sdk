import Foundation

/// Signing a Mac host in to Claude from the phone, and switching between the
/// Claude accounts that host holds.
extension AgentBridge {
    /// Auth state of a machine's `claude` CLI: who is signed in, on what plan,
    /// and whether a phone-driven sign-in is already in flight. `profile`
    /// probes one account profile; nil = the host's ACTIVE profile.
    public func fetchHostAuthStatus(machineId: String, profile: String? = nil) async -> HostAuthStatusInfo {
        let reply = await hostAccountCall("__ripulRemoteHostAuthStatus", [machineId, profile],
                                          machineId: machineId, missing: "{ loggedIn: false, error: 'not ready' }")
        if let reason = reply.failure() { return HostAuthStatusInfo.from(dict: ["error": reason]) }
        return HostAuthStatusInfo.from(dict: reply.dictionary ?? ["error": "Unexpected result"])
    }

    /// One host sign-in or account callable. A thrown call goes to the bridge
    /// console with the machine it was for, which is where these have always
    /// been looked for.
    private func hostAccountCall(
        _ function: String, _ arguments: [Any?], machineId: String, missing: String, caller: String = #function
    ) async -> PageReply {
        let reply = await callPage(function, arguments, .ifMissing(missing), log: .none)
        if let error = reply.error {
            handleConsoleLog("LOG: [AgentBridge] \(caller.prefix { $0 != "(" })(\(machineId)) error: \(error.localizedDescription)")
        }
        return reply
    }

    /// Begin a Claude sign-in on a host machine. The returned authorize URL is
    /// opened on THIS device; the code it yields goes back via
    /// `submitHostAuthCode`. Safe to render as a link — it carries no secret.
    /// `profile` scopes the sign-in to one account profile; nil = active.
    public func beginHostAuth(machineId: String, profile: String? = nil) async -> HostAuthBeginInfo {
        let reply = await hostAccountCall("__ripulRemoteHostAuthBegin", [machineId, profile],
                                          machineId: machineId, missing: "{ error: 'not ready' }")
        if let reason = reply.failure() { return HostAuthBeginInfo(sessionId: nil, authUrl: nil, error: reason) }
        guard let dict = reply.dictionary else {
            return HostAuthBeginInfo(sessionId: nil, authUrl: nil, error: "Unexpected result")
        }
        return HostAuthBeginInfo(
            sessionId: dict["sessionId"] as? String,
            authUrl: dict["authUrl"] as? String,
            error: dict["error"] as? String
        )
    }

    /// Submit the code from the callback page to the host — VERBATIM. The page
    /// renders `<code>#<state>` and the CLI rejects a code split on '#'; the
    /// host strips whitespace itself. The code is single-use, so this is never
    /// retried at any layer (relay registers it single-attempt).
    /// `profile` must match the one passed to `beginHostAuth`.
    public func submitHostAuthCode(machineId: String, sessionId: String, code: String, profile: String? = nil) async -> (ok: Bool, error: String?) {
        let reply = await hostAccountCall("__ripulRemoteHostAuthSubmitCode", [machineId, sessionId, code, profile],
                                          machineId: machineId, missing: "{ ok: false, error: 'not ready' }")
        if let reason = reply.failure() { return (false, reason) }
        guard let dict = reply.dictionary else { return (false, "Unexpected result") }
        return (dict["ok"] as? Bool ?? false, dict["error"] as? String)
    }

    /// Cancel an in-flight sign-in on a host machine.
    public func cancelHostAuth(machineId: String) async -> (ok: Bool, error: String?) {
        let reply = await hostAccountCall("__ripulRemoteHostAuthCancel", [machineId],
                                          machineId: machineId, missing: "{ ok: false, error: 'not ready' }")
        if let reason = reply.failure() { return (false, reason) }
        guard let dict = reply.dictionary else { return (false, "Unexpected result") }
        return (dict["ok"] as? Bool ?? false, dict["error"] as? String)
    }

    /// List a host machine's Claude account profiles and which is active.
    public func fetchClaudeAccounts(machineId: String) async -> ClaudeAccountsListInfo {
        let reply = await hostAccountCall("__ripulRemoteClaudeAccountsList", [machineId],
                                          machineId: machineId, missing: "{ accounts: [], active: 'default', error: 'not ready' }")
        if let reason = reply.failure() { return ClaudeAccountsListInfo(accounts: [], active: "default", error: reason) }
        guard let dict = reply.dictionary else {
            return ClaudeAccountsListInfo(accounts: [], active: "default", error: "Unexpected result")
        }
        let accounts = (dict["accounts"] as? [[String: Any]] ?? []).map { ClaudeAccountProfile.from(dict: $0) }
        return ClaudeAccountsListInfo(
            accounts: accounts,
            active: dict["active"] as? String ?? "default",
            error: dict["error"] as? String
        )
    }

    /// Create a new (not yet signed-in) account profile on the host. Follow
    /// with beginHostAuth(machineId:profile:) to sign it in.
    public func createClaudeAccount(machineId: String, name: String) async -> (ok: Bool, slug: String?, name: String?, error: String?) {
        let reply = await hostAccountCall("__ripulRemoteClaudeAccountCreate", [machineId, name],
                                          machineId: machineId, missing: "{ ok: false, error: 'not ready' }")
        if let reason = reply.failure() { return (false, nil, nil, reason) }
        guard let dict = reply.dictionary else { return (false, nil, nil, "Unexpected result") }
        return (dict["ok"] as? Bool ?? false, dict["slug"] as? String, dict["name"] as? String, dict["error"] as? String)
    }

    /// Hot-swap the host's machine-global active account. Idle persistent CLI sessions recycle onto it immediately (--resume keeps the conversation);
    /// busy ones switch after their current turn.
    public func switchClaudeAccount(machineId: String, slug: String) async -> ClaudeAccountSwitchInfo {
        func failed(_ error: String) -> ClaudeAccountSwitchInfo {
            ClaudeAccountSwitchInfo(ok: false, active: nil, recycledSessions: [], deferredBusySessions: [], error: error)
        }
        let reply = await hostAccountCall("__ripulRemoteClaudeAccountSwitch", [machineId, slug],
                                          machineId: machineId, missing: "{ ok: false, error: 'not ready' }")
        if let reason = reply.failure() { return failed(reason) }
        guard let dict = reply.dictionary else { return failed("Unexpected result") }
        return ClaudeAccountSwitchInfo(
            ok: dict["ok"] as? Bool ?? false,
            active: dict["active"] as? String,
            recycledSessions: dict["recycledSessions"] as? [String] ?? [],
            deferredBusySessions: dict["deferredBusySessions"] as? [String] ?? [],
            error: dict["error"] as? String
        )
    }

    /// Remove an account profile from the host (dir + manifest + best-effort Keychain entry). Deleting the ACTIVE profile switches the machine back to default first.
    /// The default profile itself can't be deleted — the host refuses that.
    public func deleteClaudeAccount(machineId: String, slug: String) async -> (ok: Bool, active: String?, error: String?) {
        let reply = await hostAccountCall("__ripulRemoteClaudeAccountDelete", [machineId, slug],
                                          machineId: machineId, missing: "{ ok: false, error: 'not ready' }")
        if let reason = reply.failure() { return (false, nil, reason) }
        guard let dict = reply.dictionary else { return (false, nil, "Unexpected result") }
        return (dict["ok"] as? Bool ?? false, dict["active"] as? String, dict["error"] as? String)
    }
}
