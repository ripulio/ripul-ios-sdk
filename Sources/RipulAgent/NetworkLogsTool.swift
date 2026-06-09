import Foundation

/// Built-in NativeTool that exposes the bridge's network log buffer.
/// Surfaced to CLI as `host_network_logs`.
public struct NetworkLogsTool: NativeTool {
    public let name = "network_logs"
    public let description = "Get network request logs from the host app's web view. " +
        "Shows fetch/XHR requests with method, URL, status, duration, and sizes."
    public let inputSchema: [String: Any] = ToolSchema.object(
        .string("query", "Text search filter — match against URL or error message"),
        .string("methods", "Comma-separated HTTP methods to include (GET,POST,PUT,DELETE,PATCH). Defaults to all."),
        .number("statusMin", "Only return requests with status >= this value"),
        .number("statusMax", "Only return requests with status <= this value"),
        .bool("errorsOnly", "Only return requests that have errors (status=0 or error field set)"),
        .number("since", "Only return logs after this timestamp (epoch ms)"),
        .number("limit", "Max number of log entries to return (default 50, max 500)"),
        .bool("includeHeaders", "Include request and response headers")
    )

    let bridge: AgentBridge

    public init(bridge: AgentBridge) {
        self.bridge = bridge
    }

    @MainActor
    public func execute(args: [String: Any]) async throws -> Any {
        let query = args["query"] as? String
        let includeHeaders = args["includeHeaders"] as? Bool ?? false
        let errorsOnly = args["errorsOnly"] as? Bool ?? false
        let limit = min(args["limit"] as? Int ?? 50, 500)
        let since = args["since"] as? Double
        let statusMin = args["statusMin"] as? Int
        let statusMax = args["statusMax"] as? Int

        let methodsFilter: Set<String>?
        if let methodsStr = args["methods"] as? String {
            methodsFilter = Set(methodsStr.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).uppercased() })
        } else {
            methodsFilter = nil
        }

        var entries = bridge.networkLogs

        if let since {
            let sinceDate = Date(timeIntervalSince1970: since / 1000)
            entries = entries.filter { $0.timestamp >= sinceDate }
        }

        if let methodsFilter {
            entries = entries.filter { methodsFilter.contains($0.method.uppercased()) }
        }

        if let statusMin {
            entries = entries.filter { $0.status >= statusMin }
        }

        if let statusMax {
            entries = entries.filter { $0.status <= statusMax }
        }

        if errorsOnly {
            entries = entries.filter { $0.status == 0 || $0.error != nil }
        }

        if let query, !query.isEmpty {
            let q = query.lowercased()
            entries = entries.filter {
                $0.url.lowercased().contains(q) ||
                ($0.error?.lowercased().contains(q) ?? false)
            }
        }

        let tail = entries.suffix(limit)

        let logs: [[String: Any]] = tail.map { entry in
            var dict: [String: Any] = [
                "method": entry.method,
                "url": entry.url,
                "status": entry.status,
                "statusText": entry.statusText,
                "durationMs": entry.durationMs,
                "requestSize": entry.requestSize,
                "responseSize": entry.responseSize,
                "ts": Int64(entry.timestamp.timeIntervalSince1970 * 1000),
            ]
            if let error = entry.error {
                dict["error"] = error
            }
            if includeHeaders {
                dict["requestHeaders"] = entry.requestHeaders
                dict["responseHeaders"] = entry.responseHeaders
            }
            return dict
        }

        return ["logs": logs, "count": logs.count, "total": bridge.networkLogs.count]
    }
}
