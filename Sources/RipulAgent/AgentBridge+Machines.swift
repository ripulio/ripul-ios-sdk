import Foundation
import WebKit

/// Work that happens on a paired Mac: listing machines and their chats,
/// forking and moving a chat, working directories, actions and commands.
extension AgentBridge {
    /// Fork a CLI session into a new independent conversation.
    /// Returns the new chatId on success, or nil on failure.
    public func forkSession(sourceChatId: String, displayName: String?) async -> (success: Bool, newChatId: String?, error: String?) {
        let reply = await callPage("__ripulForkSession", [sourceChatId, displayName], .orElse("{success:false, error:'not ready'}"))
        if let reason = reply.failure() { return (false, nil, reason) }
        guard reply.succeeded, let dict = reply.dictionary else { return (false, nil, reply.dictionary?["error"] as? String) }
        let newChatId = dict["newChatId"] as? String
        NSLog("[AgentBridge] forkSession: forked %@ → %@", sourceChatId, newChatId ?? "?")
        return (true, newChatId, nil)
    }

    /// Move a CLI session from its currently-paired machine to a different
    /// target machine. The source copy is left intact (fork-and-move). Returns
    /// the new local chatId on success, the effective cwd chosen by the target
    /// (and whether that was a fallback), and the target machine's display name.
    public func moveSession(
        sourceChatId: String,
        targetMachineId: String,
        displayName: String?,
        sourceMachineId: String? = nil
    ) async -> (
        success: Bool,
        newChatId: String?,
        effectiveCwd: String?,
        cwdFallback: Bool,
        targetMachineName: String?,
        error: String?,
        /// The move retires the original on the source Mac once the target has
        /// the chat. False (with the reason) when that step failed — the move
        /// itself still succeeded, and the original is still there.
        sourceRemoved: Bool,
        sourceRemoveError: String?
    ) {
        let reply = await callPage("__ripulMoveSession", [sourceChatId, targetMachineId, displayName, sourceMachineId],
                                   .orElse("{success:false, error:'not ready'}"))
        if let reason = reply.failure() { return (false, nil, nil, false, nil, reason, false, nil) }
        guard reply.succeeded, let dict = reply.dictionary else {
            return (false, nil, nil, false, nil, reply.dictionary?["error"] as? String, false, nil)
        }
        let newChatId = dict["newChatId"] as? String
        let effectiveCwd = dict["effectiveCwd"] as? String
        let cwdFallback = (dict["cwdFallback"] as? Bool) ?? false
        let targetName = dict["targetMachineName"] as? String
        let sourceRemoved = (dict["sourceRemoved"] as? Bool) ?? false
        let sourceRemoveError = dict["sourceRemoveError"] as? String
        NSLog("[AgentBridge] moveSession: moved %@ → %@ (new=%@)", sourceChatId, targetMachineId, newChatId ?? "?")
        return (true, newChatId, effectiveCwd, cwdFallback, targetName, nil, sourceRemoved, sourceRemoveError)
    }

    /// Set the working directory for a CLI session via the web app's relay.
    /// Pass nil to reset to the host's default.
    @discardableResult
    public func setWorkingDirectory(sessionId: String, directory: String?) async -> Bool {
        await callPage("__ripulSetWorkingDirectory", [sessionId, directory], .orElse("{success:false}")).succeeded
    }

    /// A live, session-scoped response. An empty list is valid; failures throw.
    public struct FavoriteDirectories {
        public let directories: [String]
        public let current: String?
        public let sessionDirectory: String?
    }

    public func getFavoriteDirectories(sessionId: String) async throws -> FavoriteDirectories {
        let reply = await callPage("__ripulGetFavoriteDirectories", [sessionId],
                                   .orElse("{error:'Chat is still connecting. Try again.'}"), log: .none)
        if reply.isDetached {
            throw NSError(domain: "RipulDirectories", code: 1, userInfo: [NSLocalizedDescriptionKey: "Chat is still connecting. Try again."])
        }
        if let error = reply.error { throw error }
        guard let dict = reply.dictionary, let dirs = dict["directories"] as? [String], dict["error"] == nil else {
            let message = reply.dictionary?["error"] as? String ?? "Could not read directories from this conversation’s host."
            throw NSError(domain: "RipulDirectories", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return FavoriteDirectories(directories: dirs, current: dict["current"] as? String, sessionDirectory: dict["sessionDirectory"] as? String)
    }

    /// Discover remote actions available on a specific host machine.
    /// Returns an array of action descriptor dictionaries.
    public func discoverRemoteActions(machineId: String) async -> [[String: Any]] {
        guard attachedWebView != nil else { return [] }
        for attempt in 1...3 {
            let reply = await callPage("__ripulDiscoverRemoteActions", [machineId], .orElse("{actions:[]}"), log: .none)
            if let error = reply.error {
                handleConsoleLog("[AgentBridge] discoverRemoteActions error (attempt \(attempt)): \(error.localizedDescription)")
            } else if let dict = reply.dictionary, let actions = dict["actions"] as? [[String: Any]] {
                if let error = dict["error"] as? String, !error.isEmpty {
                    handleConsoleLog("[AgentBridge] discoverRemoteActions warning: \(error)")
                }
                return actions
            }
            if attempt < 3 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        return []
    }

    /// Execute a remote action on a specific host machine.
    /// Returns the result dictionary from the host.
    public func executeRemoteAction(machineId: String, actionId: String, params: [String: Any] = [:]) async -> [String: Any] {
        guard let webView = attachedWebView else { return ["status": "error", "error": "webView is nil"] }
        do {
            let paramsData = try JSONSerialization.data(withJSONObject: params)
            let paramsJson = String(data: paramsData, encoding: .utf8) ?? "{}"
            let result = try await webView.callAsyncJavaScript(
                "return await window.__ripulExecuteRemoteAction?.(machineId, actionId, JSON.parse(paramsJson)) ?? {success:false, error:'not ready'};",
                arguments: ["machineId": machineId, "actionId": actionId, "paramsJson": paramsJson],
                contentWorld: .page
            )
            if let dict = result as? [String: Any] {
                // Web bridge returns an envelope {success, output?, error?}.
                // Unwrap so callers receive the provider's own result dict
                // (which carries status/outputSchema/fields for native rendering).
                if let success = dict["success"] as? Bool {
                    if success, let output = dict["output"] as? [String: Any] {
                        return output
                    }
                    let errorMsg = dict["error"] as? String ?? "Action failed"
                    return ["status": "error", "error": errorMsg]
                }
                return dict
            }
            return ["status": "error", "error": "Unexpected result type"]
        } catch {
            handleConsoleLog("[AgentBridge] executeRemoteAction error: \(error.localizedDescription)")
            return ["status": "error", "error": error.localizedDescription]
        }
    }

    /// Run a shell command on a host machine through the web app's typed
    /// `agent:execCommand` relay command. Every exec is a fresh `zsh -lc` on
    /// the host — no session state survives; callers track cwd themselves and
    /// pass it per call. With `background: true` the host launches the command
    /// as a managed job and returns immediately with `jobId` (plus `pid`),
    /// which is then tailed/stopped via `controlRemoteJob`.
    ///
    /// Returns the host's result dict: `exitCode/stdout/stderr/timedOut/
    /// truncated/durationMs/cwd` for foreground, `background/jobId/pid` when
    /// backgrounded, or `error`.
    public func execRemoteCommand(machineId: String, command: String, cwd: String? = nil, timeoutMs: Int? = nil, background: Bool = false) async -> [String: Any] {
        // Every key referenced in the body MUST be present: callAsyncJavaScript
        // turns the dictionary into the wrapper function's named parameters, so
        // an omitted key is an undeclared identifier — a ReferenceError, not
        // `undefined`. Nil optionals therefore go as NSNull() (→ JS `null`),
        // never as an absent key and never as a boxed `nil as Any`.
        let arguments: [String: Any] = [
            "machineId": machineId,
            "command": command,
            "background": background,
            "cwd": cwd.map { $0 as Any } ?? NSNull(),
            "timeoutMs": timeoutMs.map { $0 as Any } ?? NSNull(),
        ]
        let reply = await runPage(
            """
            // The phone restores its web view across app relaunches to keep
            // chat state, so the running bundle can predate the console
            // callables even though the server serves the current build.
            // GetMachines registers in the same pass as the console
            // callables — if IT exists and they don't, this build is stale:
            // reload to the current bundle so the retry lands.
            if (typeof window.__ripulGetMachines === 'function' && typeof window.__ripulConsoleExec !== 'function') {
                try { location.reload(); } catch (e) {}
                return {error:'console-reloading'};
            }
            if (typeof window.__ripulConsoleExec !== 'function') return {error:'not ready'};
            // `?? undefined` so a nil Swift optional reaches the callable as an
            // absent argument, exactly as before — the web side forwards these
            // straight onto the relay payload, where null !== omitted.
            return await window.__ripulConsoleExec(machineId, command, cwd ?? undefined, timeoutMs ?? undefined, background);
            """,
            arguments: arguments, log: .console)
        if let reason = reply.failure() { return ["error": reason] }
        return reply.dictionary ?? ["error": "Unexpected result type"]
    }

    /// List, tail, or stop a background command job started by
    /// `execRemoteCommand(..., background: true)` on a host machine.
    /// `output` returns the bytes written since `offset` plus `nextOffset`,
    /// so callers tail incrementally instead of re-reading the whole log.
    public func controlRemoteJob(machineId: String, action: String, jobId: String? = nil, offset: Int? = nil) async -> [String: Any] {
        // Keys are always present — see the note in execRemoteCommand.
        let arguments: [String: Any] = [
            "machineId": machineId,
            "action": action,
            "jobId": jobId.map { $0 as Any } ?? NSNull(),
            "offset": offset.map { $0 as Any } ?? NSNull(),
        ]
        let reply = await runPage(
            """
            if (typeof window.__ripulGetMachines === 'function' && typeof window.__ripulConsoleJobControl !== 'function') {
                try { location.reload(); } catch (e) {}
                return {error:'console-reloading'};
            }
            if (typeof window.__ripulConsoleJobControl !== 'function') return {error:'not ready'};
            return await window.__ripulConsoleJobControl(machineId, action, jobId ?? undefined, offset ?? undefined);
            """,
            arguments: arguments, log: .console)
        if let reason = reply.failure() { return ["error": reason] }
        return reply.dictionary ?? ["error": "Unexpected result type"]
    }

    /// List sessions available on a remote machine via the relay discovery protocol.
    /// The machine registry as the web app currently knows it.
    ///
    /// Preferred over the native REST fetch: the web app polls the registry with
    /// a live token, whereas the native copy silently retains its last cache
    /// whenever its own fetch cannot run. A retained cache ages past
    /// `RemoteMachine.isOnline`'s 5-minute TTL, at which point every machine
    /// reads offline and `RemoteSessionScan` returns nothing at all — the
    /// session list then shows only orphan local tabs, dated by when each tab
    /// was opened rather than by conversation activity.
    public func listMachines() async -> [RemoteMachine] {
        let reply = await callPage("__ripulGetMachines", [], .ifMissing("{machines: [], error: 'not ready'}"))
        if reply.isDetached { NSLog("[AgentBridge] listMachines: webView is nil") }
        guard reply.failure() == nil else { return [] }
        guard let dict = reply.dictionary, let raw = dict["machines"] as? [[String: Any]] else {
            NSLog("[AgentBridge] listMachines: unexpected result type: %@", String(describing: reply.value))
            return []
        }
        if let error = dict["error"] as? String, !error.isEmpty {
            NSLog("[AgentBridge] listMachines: JS error: %@", error)
        }
        let parsed = raw.compactMap { item -> RemoteMachine? in
            guard let machineId = item["machineId"] as? String,
                  let displayName = item["displayName"] as? String,
                  let roomId = item["roomId"] as? String,
                  let lastSeenAt = item["lastSeenAt"] as? String else {
                return nil
            }
            return RemoteMachine(
                machineId: machineId,
                displayName: displayName,
                userId: item["userId"] as? String ?? "",
                roomId: roomId,
                registeredAt: item["registeredAt"] as? String ?? lastSeenAt,
                lastSeenAt: lastSeenAt,
                meta: item["meta"] as? [String: String],
                teamId: item["teamId"] as? String,
                teamName: item["teamName"] as? String,
                teamRole: item["teamRole"] as? String,
                shared: item["shared"] as? Bool
            )
        }
        NSLog("[AgentBridge] listMachines: %d machines from web registry", parsed.count)
        return parsed
    }

    /// Posted (object: the bridge) when a host announces a chat was archived;
    /// userInfo carries `sessionId` (`claude-cli:<uuid>`) and `chatId` (`cli_<uuid>`).
    public static let remoteSessionArchivedNotification = Notification.Name("ripulRemoteSessionArchived")

    public func listRemoteSessions(machineId: String) async -> [RemoteSessionInfo] {
        await listRemoteSessionsAnswer(machineId: machineId).sessions
    }

    /// The machine's session list, and whether the machine actually gave it.
    /// A failed scan (relay down, machine not found, JS not ready) comes back as
    /// an empty list too; `answered` is what tells an empty machine from one
    /// that couldn't be asked. The host lists every session it has, so an
    /// answered scan is authoritative about what exists there.
    public func listRemoteSessionsAnswer(machineId: String) async -> (sessions: [RemoteSessionInfo], answered: Bool) {
        let reply = await runPage(
            """
            if (!window.__ripulListRemoteSessions) return {sessions:[], error:'not ready'};
            const result = await window.__ripulListRemoteSessions(machineId);
            if (!result.sessions || result.sessions.length === 0) {
                console.log('[listRemoteSessions] empty for ' + machineId +
                    ', error=' + (result.error || 'none'));
            }
            return result;
            """,
            arguments: ["machineId": machineId], caller: "listRemoteSessions")
        if reply.isDetached { NSLog("[AgentBridge] listRemoteSessions: webView is nil") }
        guard reply.failure() == nil else { return ([], false) }
        guard let dict = reply.dictionary, let rawSessions = dict["sessions"] as? [[String: Any]] else {
            NSLog("[AgentBridge] listRemoteSessions: unexpected result type: %@", String(describing: reply.value))
            return ([], false)
        }
        let errorText = dict["error"] as? String
        // Log relay timeline from JS side
        if let timeline = dict["timeline"] as? [String] {
            let joined = timeline.joined(separator: " | ")
            handleConsoleLog("LOG: [relay] debug_timeline listRemoteSessions(\(machineId)): \(joined)")
        }
        if let error = dict["error"] as? String, !error.isEmpty {
            NSLog("[AgentBridge] listRemoteSessions error from JS: %@", error)
            handleConsoleLog("LOG: [AgentBridge] listRemoteSessions(\(machineId)) JS error: \(error)")
        }
        let parsed = rawSessions.compactMap { item -> RemoteSessionInfo? in
            guard let id = item["id"] as? String,
                  let sourceChatId = item["sourceChatId"] as? String,
                  let displayName = item["displayName"] as? String,
                  let createdAt = item["createdAt"] as? Double else {
                return nil
            }
            let isRunning = item["isRunning"] as? Bool ?? false
            let lastModifiedMs = item["lastModified"] as? Double
            return RemoteSessionInfo(
                id: id,
                sourceChatId: sourceChatId,
                displayName: displayName,
                createdAt: Date(timeIntervalSince1970: createdAt / 1000),
                lastModified: lastModifiedMs.map { Date(timeIntervalSince1970: $0 / 1000) },
                isRunning: isRunning,
                projectName: item["projectName"] as? String,
                cwd: item["cwd"] as? String,
                gitBranch: item["gitBranch"] as? String,
                messageCount: item["messageCount"] as? Int,
                provider: item["provider"] as? String,
                providerLabel: item["providerLabel"] as? String,
                model: item["model"] as? String,
                hostChatId: item["hostChatId"] as? String,
                machineId: machineId
            )
        }
        NSLog("[AgentBridge] listRemoteSessions: %d sessions on %@", parsed.count, machineId)
        return (parsed, errorText?.isEmpty ?? true)
    }

    /// Fetch Claude Code CLI account info from a remote machine via the relay bridge.
    public func fetchCliAccount(machineId: String) async -> CliAccountInfo? {
        let reply = await callPage("__ripulGetRemoteCliAccount", [machineId], .ifMissing("{ account: null, error: 'not ready' }"))
        if reply.isDetached { NSLog("[AgentBridge] fetchCliAccount: webView is nil") }
        guard reply.failure() == nil else { return nil }
        guard let dict = reply.dictionary else {
            NSLog("[AgentBridge] fetchCliAccount: unexpected result type: %@", String(describing: reply.value))
            return nil
        }
        return CliAccountInfo.from(dict: dict)
    }
}
