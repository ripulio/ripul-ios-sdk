import Foundation

/// This device as a host, and the Macs it can reach: switching hosting on,
/// reading and changing a host's settings, its status and diagnostics.
extension AgentBridge {
    /// Enable or disable relay host mode in the web app.
    public func setHostEnabled(_ enabled: Bool, machineName: String? = nil) async -> Bool {
        let reply = await callPage("__ripulSetHostEnabled", [enabled, machineName], .ifMissing("{success:false, error:'not ready'}"))
        guard reply.failure() == nil else { return false }
        let success = reply.dictionary?["success"] as? Bool ?? false
        NSLog("[AgentBridge] setHostEnabled(%@): %@", enabled ? "true" : "false", success ? "ok" : "failed")
        return success
    }

    /// Purge THIS machine's entire local state for a chat: actions (memory +
    /// KV), the SessionChannel DO, thread/agent-run data, every per-chat CLI
    /// bookkeeping key (cliSessionMap / cliImportedUuids / cliWindow /
    /// cliSeenCount), and the tab itself.
    ///
    /// Exists because "Remove from Ripul" is DEVICE-LOCAL. Run on a viewer it
    /// clears the viewer and empties the server store, but the owning host keeps
    /// its bookkeeping and in-memory actions — and its own server-store repair
    /// then refills the server from that memory within one catch-up cycle. So a
    /// viewer-side remove cannot leave the host cold, and the next open takes
    /// the idempotency-guard skip instead of a real import.
    ///
    /// `keepRemote: true` is always passed: this forgets Ripul's state only and
    /// never archives or touches the underlying CLI session's JSONL.
    ///
    /// DESTRUCTIVE on this machine. Purging the chat a running CLI session lives
    /// in will disrupt that session.
    public func forgetChat(tabId: String) async -> [String: Any]? {
        let reply = await callPage("__ripulDeleteSession", [tabId, nil, nil, true],
                                   .ifMissing("{success:false, error:'\(Self.callableMissingError)'}"), log: .none)
        if let error = reply.error {
            NSLog("[AgentBridge] forgetChat(%@) error: %@", tabId, error.localizedDescription)
        }
        return reply.dictionary
    }

    #if DEBUG
    /// Developer cold-entry testing: put one chat back into the state of an old
    /// chat this device has not opened for a while, deleting nothing (unlike
    /// Remove from Ripul, which empties the server copy). `includeMac` also asks
    /// the owning Mac to drop it from memory; `loseNextOpen` makes the link to
    /// the Mac go dead for 3 s when this chat is next opened, as when iOS kills
    /// the socket in the background. See `coldChatDebug.ts`.
    public func makeChatCold(chatId: String, machineId: String?, includeMac: Bool, loseNextOpen: Bool) async -> [String: Any]? {
        var options: [String: Any] = ["mac": includeMac]
        if let machineId { options["machineId"] = machineId }
        if loseNextOpen { options["network"] = ["start": "next-open", "seconds": 3, "scope": "mac"] }
        let reply = await callPage("__ripulMakeChatCold", [chatId, options],
                                   .ifMissing("{success:false, error:'\(Self.callableMissingError)'}"), log: .none)
        if let error = reply.error {
            NSLog("[AgentBridge] makeChatCold(%@) error: %@", chatId, error.localizedDescription)
        }
        return reply.dictionary
    }
    #endif

    /// Read the remotely-settable host settings (an allowlist maintained on the
    /// web side, not the whole UserSettings object).
    public func getHostSettings() async -> [String: Any]? {
        await callPage("__ripulGetHostSettings", [], .ifMissing("{success:false, error:'\(Self.callableMissingError)'}")).dictionary
    }

    /// Set one allowlisted host setting. `value` must be a JSON-representable
    /// scalar (Bool / NSNumber); the web side rejects unknown keys and type
    /// mismatches rather than coercing them.
    ///
    /// Chief use: turning `disableLogging` back OFF. ConsoleWrapper no-ops every
    /// console.* while it is on, which starves the very log buffer you would
    /// otherwise use to diagnose the problem.
    public func setHostSetting(key: String, value: Any) async -> [String: Any]? {
        let reply = await callPage("__ripulSetHostSetting", [key, value],
                                   .ifMissing("{success:false, error:'\(Self.callableMissingError)'}"), log: .none)
        if let error = reply.error {
            NSLog("[AgentBridge] setHostSetting(%@) error: %@", key, error.localizedDescription)
        }
        return reply.dictionary
    }

    /// Get the current relay host status from the web app.
    public func getHostStatus() async -> [String: Any]? {
        // The stand-in reports `callable-missing`, NOT a generic "not ready":
        // an absent callable means the web app's boot chain never registered
        // its native bridge, which is a broken boot — categorically different
        // from a mounted bridge reporting itself unavailable, and it is the
        // one the caller must be able to act on.
        let reply = await callPage("__ripulGetHostStatus", [], .ifMissing("{available:false, error:'\(Self.callableMissingError)'}"))
        if let error = reply.error {
            noteHostBridgeUnavailable(reason: "eval failed: \(AgentBridge.describeEvalError(error))")
            return nil
        }
        let dict = reply.dictionary
        // Feed the unavailability backstop. A `{available:false}` reply is a
        // SUCCESSFUL eval, so without this nothing else in the recovery
        // system ever learns that the host bridge is dead.
        if let dict {
            if (dict["available"] as? Bool) == true {
                noteHostBridgeAvailable()
            } else {
                noteHostBridgeUnavailable(reason: dict["error"] as? String ?? "available=false")
            }
        }
        return dict
    }

    /// Get per-roomId ping/pong liveness diagnostics from the web app.
    /// Pass `roomId` to scope to one room, or `nil` to get all known rooms.
    /// Returns a dictionary with `pings`, `lastUpdatedAt`, and host metrics.
    public func getRelayDiagnostics(roomId: String? = nil) async -> [String: Any]? {
        await callPage("__ripulGetRelayDiagnostics", [roomId], .ifMissing("{available:false, error:'\(Self.callableMissingError)'}")).dictionary
    }

    /// Get the comms-only warn/error ring (queue blocks, stalls, stuck chains,
    /// ping timeouts, delivery stalls/failures). Persisted across relaunch.
    public func getCommsLog() async -> [String: Any]? {
        await callPage("__ripulGetCommsLog", [], .ifMissing("{available:false, error:'not ready'}")).dictionary
    }

    /// Clear the comms-only warn/error ring (also wipes its persisted copy), so
    /// the Relay Host Stats "Comms warnings & errors" list can be emptied.
    @discardableResult
    public func clearCommsLog() async -> Bool {
        let reply = await callPage("__ripulClearCommsLog", [], .ifMissing("{success:false, error:'not ready'}"))
        return (reply.dictionary?["success"] as? Bool) ?? false
    }

    /// Read the most recent new-session connect phase trace (window.__ripulConnectPhase,
    /// stamped by markConnectPhase). The connection-diagnosis sheet uses this to show
    /// WHERE a connect stalled (local IndexedDB vs the relay handshake) instead of a
    /// generic "machine unavailable".
    public func getConnectPhase() async -> String? {
        await runPage(
            """
            const p = window.__ripulConnectPhase;
            if (!p) return null;
            return `${p.phase} (+${p.elapsedMs ?? 0}ms${p.detail ? ' — ' + p.detail : ''})`;
            """,
            log: .none).value as? String
    }

    /// Ask every relay and session socket to re-check itself now and rebuild
    /// any that is dead or waiting out a backoff — the same pass the app runs
    /// when it comes to the foreground.
    @discardableResult
    public func retryRelayNow() async -> Bool {
        let reply = await callPage("__ripulForegrounded", [], .ifMissing("{ok:false, error:'not ready'}"))
        return reply.dictionary?["ok"] as? Bool ?? false
    }

    /// Reset the host high-watermarks (peaks) after reviewing them.
    @discardableResult
    public func resetHostPeaks() async -> Bool {
        let reply = await callPage("__ripulResetHostPeaks", [], .ifMissing("{ok:false, error:'not ready'}"))
        return reply.dictionary?["ok"] as? Bool ?? false
    }

    /// Send a kill command to a remote machine via the relay.
    /// The controller's web view sends a `machine:kill` command through
    /// the relay WebSocket; the target machine's guardian process handles it.
    public func killMachine(machineId: String, reason: String = "remote_user") async -> (success: Bool, error: String?) {
        let reply = await callPage("__ripulKillMachine", [machineId, reason], .ifMissing("{success:false, error:'not ready'}"))
        if let why = reply.failure(detached: "WebView not available") { return (false, why) }
        guard let dict = reply.dictionary else { return (false, "Unexpected response") }
        return (dict["success"] as? Bool ?? false, dict["error"] as? String)
    }
}
