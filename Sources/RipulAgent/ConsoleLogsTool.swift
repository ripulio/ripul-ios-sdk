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
        let query = args["query"] as? String
        let includeStack = args["includeStack"] as? Bool ?? false
        let limit = min(args["limit"] as? Int ?? 50, 500)
        let since = args["since"] as? Double

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
        var entries = allEntries

        if let since {
            let sinceDate = Date(timeIntervalSince1970: since / 1000)
            entries = entries.filter { $0.timestamp >= sinceDate }
        }

        if let levelsFilter {
            entries = entries.filter { levelsFilter.contains($0.level) }
        }

        if let query, !query.isEmpty {
            let q = query.lowercased()
            entries = entries.filter { $0.message.lowercased().contains(q) }
        }

        let tail = entries.suffix(limit)

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
