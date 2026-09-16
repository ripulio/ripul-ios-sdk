import Foundation

/// A captured tool result, never a subscription to the live console.
struct NativeConsoleLogs {
    let entries: [NativeToolLogEntry]
    let groups: [NativeToolLogGroup]
    let total: Int?

    init?(_ output: CmsJSON?) {
        guard let output else { return nil }
        let value = ToolValue.unwrap(output)
        guard let object = value.objectValue, let logs = object["logs"]?.toolArray else { return nil }
        entries = logs.enumerated().map { NativeToolLogEntry(id: $0.offset, value: $0.element) }
        groups = NativeToolLogGroup.collect(entries)
        let count = object.double("total")
        total = count.flatMap { $0.isFinite && $0 >= 0 && $0 < Double(Int.max) ? Int($0) : nil }
    }

    var levels: [String] {
        let present = Set(entries.map(\.level))
        let known = ["ERROR", "WARN", "INFO", "LOG", "DEBUG", "TRACE"]
        return known.filter { present.contains($0) } + present.subtracting(known).sorted()
    }

    func matching(query: String, level: String?) -> [NativeToolLogGroup] {
        // Group before filtering so two separate occurrences never become a repeat.
        groups.filter { $0.entry.matches(query: query, level: level) }
    }

    func copyText(query: String, level: String?, newestFirst: Bool) -> String {
        let matching = entries.filter { $0.matches(query: query, level: level) }
        return (newestFirst ? Array(matching.reversed()) : matching).map(\.copyText).joined(separator: "\n")
    }
}

struct NativeToolLogEntry: Equatable, Identifiable {
    let id: Int
    let level: String
    let message: String
    let stack: String?
    let timestamp: CmsJSON?
    let date: Date?

    init(id: Int, value: CmsJSON) {
        self.id = id
        let row = value.objectValue ?? [:]
        let rawLevel = (row.string("level") ?? "LOG").uppercased()
        level = rawLevel == "WARNING" ? "WARN" : rawLevel
        message = row.string("message") ?? row.string("text") ?? value.stringValue ?? value.displayString
        stack = row.string("stack")
        timestamp = row["ts"] ?? row["timestamp"]
        if let milliseconds = timestamp?.doubleValue, milliseconds.isFinite {
            date = Date(timeIntervalSince1970: milliseconds / 1000)
        } else if let iso = timestamp?.stringValue {
            date = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(iso))
                ?? (try? Date.ISO8601FormatStyle().parse(iso))
        } else { date = nil }
    }

    func matches(query: String, level: String?) -> Bool {
        guard level == nil || self.level == level else { return false }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return needle.isEmpty || message.localizedCaseInsensitiveContains(needle)
            || (stack?.localizedCaseInsensitiveContains(needle) ?? false)
    }

    var copyText: String {
        let time = date?.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)) ?? timestamp?.displayString
        return [time, "[\(level)]", message].compactMap { $0 }.joined(separator: " ")
            + (stack.flatMap { $0.isEmpty ? nil : "\n" + $0 } ?? "")
    }
}

struct NativeToolLogGroup: Equatable, Identifiable {
    let entry: NativeToolLogEntry
    var lastEntry: NativeToolLogEntry
    var count: Int
    var id: Int { entry.id }
    var level: String { entry.level }

    static func collect(_ values: [CmsJSON]) -> [Self] {
        collect(values.enumerated().map { NativeToolLogEntry(id: $0.offset, value: $0.element) })
    }

    static func collect(_ entries: [NativeToolLogEntry]) -> [Self] {
        var groups: [Self] = []
        for entry in entries {
            if let last = groups.last, last.level == entry.level,
               last.entry.message == entry.message, last.entry.stack == entry.stack {
                groups[groups.count - 1].count += 1
                groups[groups.count - 1].lastEntry = entry
            } else { groups.append(.init(entry: entry, lastEntry: entry, count: 1)) }
        }
        return groups
    }
}
