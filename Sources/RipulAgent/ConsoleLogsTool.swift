import Foundation

/// Built-in NativeTool that exposes the bridge's console log buffer.
/// Surfaced to CLI as `host_console_logs`.
public struct ConsoleLogsTool: NativeTool {
    public let name = "console_logs"
    public let description = "Get console logs from the host app. " +
        "Captures both native app logs and web view console output — errors, warnings, and debug messages from all layers."
    public let inputSchema: [String: Any] = ToolSchema.object(
        .string("query", "Text search filter — only return logs containing this substring"),
        .string("levels", "Comma-separated log levels to include (log,info,warn,error,debug,trace). Defaults to all."),
        .number("since", "Only return logs after this timestamp (epoch ms)"),
        .number("until", "Only return logs at or before this timestamp (epoch ms) — with since, reads a past window"),
        .number("limit", "Max number of log entries to return (default 50, max 500)"),
        .bool("includeStack", "Include stack traces for error entries")
    )

    let bridge: AgentBridge

    /// SDK-internal: constructible only from within this module (the console
    /// composition path and `.ripulDevTools()`) — see `RipulDeveloperOnlyTool`.
    init(bridge: AgentBridge) {
        self.bridge = bridge
    }

    @MainActor
    public func execute(args: [String: Any]) async throws -> Any {
        let includeStack = args["includeStack"] as? Bool ?? false
        let limit = min(args["limit"] as? Int ?? 50, 500)
        let since = (args["since"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        let until = (args["until"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }

        let levelsFilter: Set<String>?
        if let levelsStr = args["levels"] as? String {
            levelsFilter = Set(levelsStr.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).uppercased() })
        } else {
            levelsFilter = nil
        }

        // Native (RipulLog) + web (bridge) interleaved by timestamp — the tool
        // promises "logs from all layers", and native logs live in the host-owned
        // buffer so they survive from launch, before this bridge existed.
        let allEntries = RipulLog.merged(with: bridge.consoleLogs)

        // This runs on the main actor, which on the Mac host also serves every
        // CLI bridge request. Lowercasing every buffered message per query
        // (thousands of lines, some ~40 KB) froze the host for 45 s+ on
        // 2026-09-26. Walk newest-first, match case-insensitively without
        // copying, and stop as soon as `limit` entries are found.
        let query = (args["query"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        var tail: [ConsoleLogEntry] = []
        tail.reserveCapacity(limit)
        for entry in allEntries.reversed() {
            if let until, entry.timestamp > until { continue }
            if let since, entry.timestamp < since { break }
            if let levelsFilter, !levelsFilter.contains(entry.level) { continue }
            if let query, entry.message.range(of: query, options: .caseInsensitive) == nil { continue }
            tail.append(entry)
            if tail.count >= limit { break }
        }
        tail.reverse()

        let logs: [[String: Any]] = tail.map { entry in
            var dict: [String: Any] = [
                "level": entry.level,
                "message": entry.message,
                "ts": Int64(entry.timestamp.timeIntervalSince1970 * 1000),
            ]
            if includeStack, let stack = entry.stack {
                dict["stack"] = stack
            }
            return dict
        }

        return ["logs": logs, "count": logs.count, "total": allEntries.count]
    }
}
