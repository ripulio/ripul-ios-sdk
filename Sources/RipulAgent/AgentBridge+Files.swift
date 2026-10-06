import Foundation

/// Finding in the file viewer, and browsing, searching and reading files on
/// a Mac.
extension AgentBridge {
    /// Set the find-in-file query. Returns total matches and the 1-based
    /// index of the current match (or 0 when there are no matches).
    public func fileViewerFind(query: String) async -> RipulFindResult {
        await findInFileViewer("__ripulFileViewerFind", [query])
    }

    private func findInFileViewer(_ function: String, _ arguments: [Any?] = [], caller: String = #function) async -> RipulFindResult {
        let reply = await callPage(function, arguments, .orElse("{ total: 0, current: 0 }"), detachedIsFailure: true, caller: caller)
        return reply.error == nil ? RipulFindResult.parse(reply.value) : RipulFindResult(total: 0, current: 0)
    }

    /// Advance to the next find match. Wraps at the end.
    public func fileViewerFindNext() async -> RipulFindResult {
        await findInFileViewer("__ripulFileViewerFindNext")
    }

    /// Step back to the previous find match. Wraps at the start.
    public func fileViewerFindPrev() async -> RipulFindResult {
        await findInFileViewer("__ripulFileViewerFindPrev")
    }

    /// Search for files on the connected remote machine.
    /// Returns an array of `{ path, isDirectory }` dictionaries.
    /// Use `offset` for pagination (each page returns up to 25 results).
    public func searchRemoteFiles(query: String, offset: Int = 0) async -> [(path: String, isDirectory: Bool)] {
        let reply = await callPage("__ripulSearchFiles", [query, offset], .orElse("[]"), detachedIsFailure: true)
        guard let arr = reply.value as? [[String: Any]] else { return [] }
        return arr.compactMap { dict in
            guard let path = dict["path"] as? String else { return nil }
            let isDir = dict["isDirectory"] as? Bool ?? false
            return (path: path, isDirectory: isDir)
        }
    }

    /// List the direct children of a specific remote directory.
    /// Accepts absolute paths, `~`-prefixed paths, or paths relative to the
    /// session's working directory. Returns the entries and an optional error
    /// string if the listing failed (path missing, not a directory, etc.).
    public func listRemoteDirectory(path: String, machineId: String? = nil) async -> (entries: [(path: String, isDirectory: Bool)], error: String?) {
        if let machineId {
            let reply = await callPage("__ripulFilesDirectory", [machineId, path],
                                       .orElse("{error:'Files is still connecting. Try again.'}"), log: .none)
            if let error = reply.error { return ([], error.localizedDescription) }
            let value = reply.dictionary
            let entries = (value?["entries"] as? [[String: Any]] ?? []).compactMap { item -> (path: String, isDirectory: Bool)? in
                guard let path = item["path"] as? String else { return nil }
                return (path, item["isDirectory"] as? Bool ?? false)
            }
            return (entries, value?["error"] as? String ?? (value == nil ? "Files is still connecting. Try again." : nil))
        }
        let reply = await callPage("__ripulListDirectory", [path], .orElse("{ entries: [] }"), detachedIsFailure: true)
        if let error = reply.error { return (entries: [], error: error.localizedDescription) }
        guard let dict = reply.dictionary else { return (entries: [], error: "Malformed response") }
        let arr = (dict["entries"] as? [[String: Any]]) ?? []
        let entries: [(path: String, isDirectory: Bool)] = arr.compactMap { d in
            guard let p = d["path"] as? String else { return nil }
            let isDir = d["isDirectory"] as? Bool ?? false
            return (path: p, isDirectory: isDir)
        }
        let err = dict["error"] as? String
        return (entries: entries, error: err)
    }

    /// Grep the contents of tracked files on the connected remote machine.
    /// Returns hits with path, 1-based line number, and a snippet of the line.
    public func grepRemoteFiles(query: String, maxResults: Int = 100) async -> [RipulGrepHit] {
        let reply = await callPage("__ripulGrepRemoteFiles", [query, maxResults], .orElse("[]"), detachedIsFailure: true)
        guard let arr = reply.value as? [[String: Any]] else { return [] }
        return arr.compactMap { dict in
            guard let path = dict["path"] as? String else { return nil }
            let line = (dict["line"] as? Int) ?? Int((dict["line"] as? Double) ?? 0)
            let snippet = (dict["snippet"] as? String) ?? ""
            return RipulGrepHit(path: path, line: line, snippet: snippet)
        }
    }

    /// Read a file's content from the connected remote machine. Pass `chatId` so the
    /// read targets the paired machine for that chat (matches the reliable in-chat
    /// viewer path); without it the web falls back to the active chat id.
    public func readRemoteFile(path: String, chatId: String? = nil, machineId: String? = nil) async -> String? {
        if let machineId {
            return await callPage("__ripulFilesRead", [machineId, path], log: .none).dictionary?["content"] as? String
        }
        let reply = await callPage("__ripulReadRemoteFile", [path, chatId], detachedIsFailure: true)
        return reply.dictionary?["content"] as? String
    }

    /// Poll the file-viewer web view until its inject hook is registered (i.e.
    /// FileViewerManager has mounted in file-viewer bootstrap mode). The viewer
    /// loads a FULL web app, which routinely takes longer than a fixed delay —
    /// injecting before it was ready dropped the content on the floor (spinner ->
    /// "host did not respond"; it only "worked once" when the app happened to boot
    /// within the old 500ms).
    public func waitForFileViewerReady(timeout: TimeInterval = 12) async {
        let start = CFAbsoluteTimeGetCurrent()
        while CFAbsoluteTimeGetCurrent() - start < timeout {
            if let ready = try? await callAsyncJavaScript(
                "return typeof window.__ripulInjectFileContent === 'function'"
            ) as? Bool, ready {
                return
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    /// Inject pre-fetched file content into a file-viewer web view. Waits for the
    /// viewer to be ready first so the content is never dropped into a web app that
    /// hasn't mounted yet.
    public func injectFileContent(_ content: String) {
        Task { @MainActor in
            await waitForFileViewerReady()
            _ = await callPage("__ripulInjectFileContent", [content], log: .none)
        }
    }

    /// Signal that file content could not be read, so the viewer stops showing a
    /// loading spinner and displays an error instead. Also waits for readiness.
    public func injectFileError(_ message: String) {
        Task { @MainActor in
            await waitForFileViewerReady()
            _ = await callPage("__ripulInjectFileError", [message], log: .none)
        }
    }
}
