import Foundation

/// The once-a-minute `[PERFMIN]` lines and every change of the phone's thermal
/// state, kept in a file.
///
/// The lines go to the app's console buffer, which lives in the page and is
/// emptied when the page restarts. On 11 October 2026 Peter reported a large
/// thermal spike; the page had restarted ninety seconds before the log was
/// read, so the spike itself was gone and only "thermal=serious" in the minute
/// after it was left. This file survives a page restart and a relaunch: the
/// last few hours can be read back with the `perf_journal` device tool.
public enum PerfJournal {
    /// About four hours of minutes, with room for thermal changes.
    private static let keptLines = 300
    private static let queue = DispatchQueue(label: "ripul.perf-journal", qos: .utility)

    private static var file: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ripul-perf-journal.log")
    }

    private static let stamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Adds one line, stamped with the time. Safe from any thread.
    public static func append(_ line: String) {
        let stamped = "\(stamp.string(from: Date())) \(line)"
        queue.async {
            guard let file else { return }
            var lines = (try? String(contentsOf: file, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
            lines.append(stamped)
            if lines.count > keptLines { lines.removeFirst(lines.count - keptLines) }
            try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        }
    }

    /// The newest lines, oldest first.
    public static func lines(last count: Int, containing text: String? = nil) -> [String] {
        queue.sync {
            guard let file, let all = try? String(contentsOf: file, encoding: .utf8) else { return [] }
            var lines = all.split(separator: "\n").map(String.init)
            if let text, !text.isEmpty { lines = lines.filter { $0.localizedCaseInsensitiveContains(text) } }
            return Array(lines.suffix(count))
        }
    }
}

/// Reads the journal back: what the app was doing in the minutes before, during
/// and after the phone got warm, after the fact.
public struct PerfJournalTool: NativeTool {
    public let name = "perf_journal"
    public let description = "Read the app's kept record of its once-a-minute [PERFMIN] lines (processor use, main-thread "
        + "wake time, thermal state, what was counted) and every change of the device's thermal state, each stamped "
        + "with the time. It survives a page restart and an app relaunch, unlike console_logs, so it answers what "
        + "happened around a heat spike after the fact. Debug builds record; about four hours are kept."
    public let inputSchema: [String: Any] = ToolSchema.object(
        .number("limit", "How many of the newest lines to return (default 40, max 300)"),
        .string("query", "Only lines containing this text, e.g. THERMAL or serious"),
        .bool("brief", "Leave out each line's counts and stack frames: time, processor, wake and thermal state only")
    )

    /// SDK-internal — see `RipulDeveloperOnlyTool`.
    init() {}

    public func execute(args: [String: Any]) async throws -> Any {
        let limit = min(max(args["limit"] as? Int ?? 40, 1), 300)
        var lines = PerfJournal.lines(last: limit, containing: args["query"] as? String)
        if args["brief"] as? Bool == true {
            lines = lines.map { $0.components(separatedBy: " | counts:").first ?? $0 }
        }
        return ["success": true, "count": lines.count, "lines": lines]
    }
}
