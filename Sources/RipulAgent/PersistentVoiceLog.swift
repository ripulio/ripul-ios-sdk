import Foundation

/// Low-frequency, metadata-only voice events. RipulLog's lock serializes access.
/// Appends finish before returning: there is no debounce window to lose on quit.
/// This is never called from an audio tap or for individual audio/transcript frames.
final class PersistentVoiceLog {
    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "RipulAgent", isDirectory: true)
            .appendingPathComponent(ProcessInfo.processInfo.arguments.contains("--watchdog") ? "VoiceDiagnostics-watchdog" : "VoiceDiagnostics", isDirectory: true)
            .appendingPathComponent("events.jsonl")
    }

    private let url: URL
    private let maxEntries: Int
    private let maxBytes: Int
    private let retention: TimeInterval
    private var stored: [ConsoleLogEntry] = []
    private var bytes = 0
    private var needsRewrite = true
    private(set) var writeFailed = false

    init(url: URL, maxEntries: Int = 2000, maxBytes: Int = 1_048_576,
         retention: TimeInterval = 7 * 24 * 60 * 60, now: Date = Date()) {
        self.url = url
        self.maxEntries = max(2, maxEntries)
        self.maxBytes = max(4096, maxBytes)
        self.retention = retention
        // Bound reads too; independently decode lines so a truncated final write
        // cannot hide the valid history before it.
        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            if let data = try? handle.read(upToCount: self.maxBytes) {
                var ids = Set<UUID>()
                stored = data.split(separator: 10).compactMap {
                    try? JSONDecoder().decode(ConsoleLogEntry.self, from: Data($0))
                }.filter { $0.timestamp >= now.addingTimeInterval(-retention) && ids.insert($0.id).inserted }
                stored = Array(stored.suffix(self.maxEntries))
            }
        }
    }

    func entries(now: Date = Date()) -> [ConsoleLogEntry] {
        stored.filter { $0.timestamp >= now.addingTimeInterval(-retention) }
    }

    func append(_ entry: ConsoleLogEntry) {
        let retained = entries(now: entry.timestamp)
        if retained.count != stored.count { needsRewrite = true }
        stored = retained
        stored.append(entry)
        do {
            var line = try JSONEncoder().encode(entry)
            line.append(10)
            if needsRewrite || stored.count > maxEntries || bytes + line.count > maxBytes {
                // Compact in batches so steady logging needs only small appends.
                if stored.count > maxEntries { stored = Array(stored.suffix(maxEntries / 2)) }
                var data = try encodedHistory()
                while data.count > maxBytes, stored.count > 1 {
                    stored.removeFirst(max(1, stored.count / 2))
                    data = try encodedHistory()
                }
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                var directory = url.deletingLastPathComponent()
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? directory.setResourceValues(values)
                bytes = data.count
            } else {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
                bytes += line.count
            }
            needsRewrite = false
            writeFailed = false
        } catch {
            // Keep diagnostics readable in memory and retry a complete snapshot
            // next time; never recursively log through this store.
            stored = Array(stored.suffix(maxEntries))
            needsRewrite = true
            writeFailed = true
        }
    }

    func clear() {
        stored.removeAll()
        needsRewrite = true
        bytes = 0
        do {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            writeFailed = false
        } catch { writeFailed = true }
    }

    private func encodedHistory() throws -> Data {
        var data = Data()
        for entry in stored {
            data.append(try JSONEncoder().encode(entry))
            data.append(10)
        }
        return data
    }
}

/// Only audited metadata belongs here. Never pass transcripts, audio, URLs,
/// credentials, localized error descriptions or raw server responses.
func voiceDiagnostic(_ message: String, level: RipulLogLevel = .log) {
    Foundation.NSLog("%@", message)
    RipulLog.shared.appendVoiceDiagnostic(message, level: level)
}

/// Preserve useful nested TLS/OSStatus codes without error userInfo, which can
/// contain a signed URL, provider body or other private data. Cap nested depth.
func voiceErrorMetadata(_ error: Error) -> String {
    var current: NSError? = error as NSError
    var parts: [String] = []
    for depth in 0..<3 {
        guard let error = current else { break }
        let domain = [NSURLErrorDomain, NSOSStatusErrorDomain, NSPOSIXErrorDomain, NSCocoaErrorDomain]
            .contains(error.domain) ? error.domain : "other"
        parts.append("\(depth == 0 ? "error" : "underlying\(depth)")=\(domain):\(error.code)")
        current = error.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    return parts.joined(separator: " ")
}
