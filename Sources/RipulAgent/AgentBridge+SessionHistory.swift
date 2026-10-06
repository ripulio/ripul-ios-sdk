import Foundation

/// A chat's past on its Mac: archiving and restoring it, the commits it was
/// captured with, and continuing from one of them.
extension AgentBridge {
    /// Archive a remote CLI session. Moves the JSONL file into the project's
    /// `.archive/` folder on the host machine — recoverable but hidden from scans.
    /// Returns (success, error) tuple.
    public func archiveRemoteSession(machineId: String, sessionId: String) async -> (success: Bool, error: String?) {
        await sessionOutcome("__ripulArchiveRemoteSession", [machineId, sessionId])
    }

    /// Archive, restore and delete all answer `{success, error?}`, and each
    /// logs the outcome under its own name.
    private func sessionOutcome(
        _ function: String, _ arguments: [Any?], caller: String = #function
    ) async -> (success: Bool, error: String?) {
        let reply = await callPage(function, arguments, .ifMissing("{success:false, error:'not ready'}"), caller: caller)
        if let reason = reply.failure() { return (false, reason) }
        guard let dict = reply.dictionary else { return (false, "Unexpected result") }
        let success = dict["success"] as? Bool ?? false
        let error = dict["error"] as? String
        NSLog("[AgentBridge] %@: success=%@ error=%@", String(caller.prefix { $0 != "(" }), success ? "true" : "false", error ?? "nil")
        return (success, error)
    }

    /// Restore an archived remote CLI session — moves the JSONL back from
    /// `.archive/` to the active sessions directory so the CLI can resume it.
    public func restoreRemoteSession(machineId: String, sessionId: String) async -> (success: Bool, error: String?) {
        await sessionOutcome("__ripulRestoreRemoteSession", [machineId, sessionId])
    }

    /// An archived CLI session found in a .archive/ directory.
    public struct ArchivedSessionInfo: Identifiable, Hashable {
        public let id: String
        public let displayName: String
        public let projectName: String?
        public let archivedAt: Date
        public let provider: String?
        /// The machine the archive was discovered on — required to route the restore
        /// call back to the correct host. Stamped client-side after the per-machine fetch.
        public let machineId: String?
    }

    /// List archived sessions across all .archive/ directories on the host.
    public func listArchivedSessions(machineId: String) async -> [ArchivedSessionInfo] {
        let reply = await runPage(
            """
            if (!window.__ripulListArchivedSessions) return {sessions:[], error:'not ready'};
            return JSON.parse(JSON.stringify(await window.__ripulListArchivedSessions(machineId)));
            """,
            arguments: ["machineId": machineId])
        if reply.isDetached { NSLog("[AgentBridge] listArchivedSessions: webView is nil") }
        guard let dict = reply.dictionary, let sessionsRaw = dict["sessions"] as? [[String: Any]] else {
            if let error = reply.dictionary?["error"] as? String {
                NSLog("[AgentBridge] listArchivedSessions error from JS: %@", error)
            }
            return []
        }
        let parsed = sessionsRaw.compactMap { s -> ArchivedSessionInfo? in
            guard let id = s["id"] as? String else { return nil }
            let displayName = s["displayName"] as? String ?? id
            let projectName = s["projectName"] as? String
            let archivedAtMs = s["archivedAt"] as? Double ?? 0
            let provider = s["provider"] as? String
            return ArchivedSessionInfo(
                id: id,
                displayName: displayName,
                projectName: projectName,
                archivedAt: Date(timeIntervalSince1970: archivedAtMs / 1000),
                provider: provider,
                machineId: machineId
            )
        }
        NSLog("[AgentBridge] listArchivedSessions: %d sessions on %@", parsed.count, machineId)
        return parsed
    }

    /// Restore an archived session (move JSONL back from .archive/ to active).
    public func restoreArchivedSession(machineId: String, sessionId: String) async -> (success: Bool, error: String?) {
        await sessionOutcome("__ripulRestoreArchivedSession", [machineId, sessionId])
    }

    /// Permanently delete an archived session (remove the archived JSONL file).
    public func deleteArchivedSession(machineId: String, sessionId: String) async -> (success: Bool, error: String?) {
        await sessionOutcome("__ripulDeleteArchivedSession", [machineId, sessionId])
    }

    /// A file edited during a session.
    public struct FileEditEntry: Hashable {
        public let fileName: String
        public let filePath: String?
        public let editCount: Int
        public let lastSeenAt: String?
    }

    /// A user-authored note on a session.
    public struct NoteEntry: Hashable, Identifiable {
        public let id: String
        public let text: String
        public let createdAt: String?
        /// Legacy timestamp field (from commit metadata).
        public let timestamp: String?
    }

    /// A deployment made during a session.
    public struct DeploymentEntry: Hashable, Identifiable {
        public let id: String
        public let target: String
        public let timestamp: String?
    }

    /// Commit with a captured session, as returned by listCommitsWithSessions.
    public struct CommitWithSession {
        public let sha: String
        public let shortSha: String
        public let subject: String
        public let authorName: String
        /// Unix timestamp in seconds (committer date).
        public let timestamp: Double
        /// Branch name at commit time (nil for legacy entries).
        public let branch: String?
        /// Session ID from index (nil for legacy entries).
        public let sessionId: String?
        /// Session title extracted from JSONL at capture time (nil for legacy entries).
        public let sessionTitle: String?
        /// Number of unique files edited in this session (from .meta.json).
        public let filesEditedCount: Int?
        /// Session description (from .meta.json).
        public let description: String?
        /// Deployment targets triggered during this session (from .meta.json).
        public let deploymentTargets: [String]?
        /// Full files-edited list (from .meta.json).
        public let filesEdited: [FileEditEntry]?
        /// User-authored notes (from .meta.json).
        public let notes: [NoteEntry]?
        /// All deployments (from .meta.json).
        public let deployments: [DeploymentEntry]?
    }

    /// List commits that have a captured Claude session on the remote machine.
    /// `repoPath` names the repo on that machine; nil asks about the host's
    /// working folder (the only behaviour of hosts before October 2026 —
    /// check the returned `repoPath` when it matters).
    public func listCommitsWithSessions(machineId: String, repoPath: String? = nil) async -> (repoPath: String, commits: [CommitWithSession], error: String?) {
        let reply = await callPage("__ripulListCommitsWithSessions", [machineId, repoPath],
                                   .ifMissing("{ repoPath: '', commits: [], error: 'not ready' }"))
        if let reason = reply.failure() { return ("", [], reason) }
        guard let dict = reply.dictionary else { return ("", [], "Unexpected result") }
        let repoPath = dict["repoPath"] as? String ?? ""
        let error = dict["error"] as? String
        let rawCommits = dict["commits"] as? [[String: Any]] ?? []
        let commits = rawCommits.compactMap { item -> CommitWithSession? in
            guard let sha = item["sha"] as? String,
                  let shortSha = item["shortSha"] as? String,
                  let subject = item["subject"] as? String,
                  let authorName = item["authorName"] as? String,
                  let timestamp = item["timestamp"] as? Double else { return nil }
            let branch = item["branch"] as? String
            let sessionId = item["sessionId"] as? String
            let sessionTitle = item["sessionTitle"] as? String
            let filesEditedCount = item["filesEditedCount"] as? Int
            let description = item["description"] as? String
            let deploymentTargets = item["deploymentTargets"] as? [String]

            let filesEdited = (item["filesEdited"] as? [[String: Any]])?.compactMap { entry -> FileEditEntry? in
                guard let name = entry["fileName"] as? String else { return nil }
                let count = (entry["editCount"] as? Int) ?? 1
                return FileEditEntry(fileName: name, filePath: entry["filePath"] as? String, editCount: count, lastSeenAt: entry["lastSeenAt"] as? String)
            }
            let notes = (item["notes"] as? [[String: Any]])?.compactMap { entry -> NoteEntry? in
                guard let text = entry["text"] as? String else { return nil }
                return NoteEntry(id: entry["id"] as? String ?? UUID().uuidString, text: text, createdAt: entry["createdAt"] as? String, timestamp: entry["timestamp"] as? String)
            }
            let deploymentsList = (item["deployments"] as? [[String: Any]])?.compactMap { entry -> DeploymentEntry? in
                guard let target = entry["target"] as? String else { return nil }
                return DeploymentEntry(id: entry["id"] as? String ?? UUID().uuidString, target: target, timestamp: entry["timestamp"] as? String)
            }

            return CommitWithSession(sha: sha, shortSha: shortSha, subject: subject, authorName: authorName, timestamp: timestamp, branch: branch, sessionId: sessionId, sessionTitle: sessionTitle, filesEditedCount: filesEditedCount, description: description, deploymentTargets: deploymentTargets, filesEdited: filesEdited, notes: notes, deployments: deploymentsList)
        }
        return (repoPath, commits, error)
    }

    /// Resume a captured session from a commit SHA on a remote machine.
    public func resumeFromCommit(machineId: String, sha: String, repoPath: String? = nil) async -> (success: Bool, sessionId: String?, error: String?) {
        let reply = await runPage(
            """
            if (!window.__ripulResumeFromCommit) return { success: false, error: 'not ready' };
            var r = await window.__ripulResumeFromCommit(machineId, sha, repoPath);
            return JSON.parse(JSON.stringify(r));
            """,
            arguments: ["machineId": machineId, "sha": sha, "repoPath": repoPath.map { $0 as Any } ?? NSNull()])
        if let reason = reply.failure() { return (false, nil, reason) }
        guard let dict = reply.dictionary else { return (false, nil, "Unexpected result") }
        return (dict["success"] as? Bool ?? false, dict["sessionId"] as? String, dict["error"] as? String)
    }

    /// Continue a chat on `machineId` from the transcript captured on a
    /// repo's `claude-sessions` branch — for a chat whose own Mac is offline
    /// or gone. The machine fetches the newest copy and imports it as a chat
    /// of its own, under a new id; the original is not touched. On success
    /// `newChatId` is a tab on this device, already open.
    public func rescueSession(
        machineId: String,
        repoPath: String,
        sessionId: String,
        displayName: String?
    ) async -> (success: Bool, newChatId: String?, cwdFallback: Bool, targetMachineName: String?, error: String?) {
        let reply = await callPage(
            "__ripulRescueSession", [machineId, repoPath, sessionId, displayName],
            .orElse("{success:false, error:'Continuing a captured chat needs the latest app build.'}"))
        if let reason = reply.failure() { return (false, nil, false, nil, reason) }
        guard let dict = reply.dictionary else { return (false, nil, false, nil, "Unexpected result") }
        let success = dict["success"] as? Bool ?? false
        let newChatId = (dict["localTabId"] as? String) ?? (dict["newChatId"] as? String)
        NSLog("[AgentBridge] rescueSession: %@ → %@ (%@)", sessionId, machineId, success ? (newChatId ?? "?") : (dict["error"] as? String ?? "failed"))
        return (success, newChatId, dict["cwdFallback"] as? Bool ?? false, dict["targetMachineName"] as? String, dict["error"] as? String)
    }
}
