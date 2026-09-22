import Foundation
import Combine

// MARK: - RipulLog — host-owned native log buffer
//
// A process-lifetime buffer, plus bounded persistent voice diagnostics,
// owned by nobody and depending on nothing. This is the answer to "I want to read
// the logs BEFORE anything has mounted": an `AgentBridge` only exists once a host
// brings agent UI up, so a bridge-owned buffer structurally cannot hold the
// launch-path logs that matter most when something fails early.
//
// Division of labour, so an entry is never stored twice:
//
//   RipulLog.shared        NATIVE logs — the SDK's own `NSLog` (via NativeLogTee)
//                          and whatever the host routes in via `RipulLog.log`.
//   AgentBridge.consoleLogs WEB logs — `console.*` from the WKWebView, plus the
//                          handful of native lines Swift injects deliberately via
//                          `handleConsoleLog`.
//
// Readers that want "everything" merge the two at read time with
// `RipulLog.merged(with:)`, which interleaves by timestamp. There is no
// duplication to de-dupe because each entry has exactly one home.
//
// Host adoption is one line per log call, or zero if the host shadows `print` /
// `NSLog` at module scope the way `NativeLogTee` does for the SDK:
//
//     RipulLog.log("cold start: restoring session")
//     RipulLog.error("upload failed: \(error)")

/// Severity for a `RipulLog` entry. Matches the level strings the console viewer
/// and `console_logs` tool already filter on.
public enum RipulLogLevel: String, Sendable {
    case log = "LOG"
    case warn = "WARN"
    case error = "ERROR"
}

public final class RipulLog: @unchecked Sendable {
    public static let shared = RipulLog()

    /// Set false to stop capturing (the pass-through to the OS logger is unaffected).
    /// Default on: capture has to be live before any host code runs, or the launch
    /// path — the whole point of this buffer — is already lost by the time it's set.
    public static var isCaptureEnabled = true

    /// Hard cap. Cleared outright rather than trimmed per-append: a rolling buffer
    /// pays O(n) on every append past the cap, which thrashes under log floods.
    /// Same rationale as `AgentBridge.handleConsoleLog`.
    private static let maxEntries = 2000

    private let lock = NSLock()
    private var storage: [ConsoleLogEntry] = []

    /// Fires on the main queue when entries change, coalesced so a hot loop can't
    /// drive a SwiftUI redraw per line.
    public let changed = PassthroughSubject<Void, Never>()
    private var notifyScheduled = false

    private let voiceLog: PersistentVoiceLog
    private let runID = UUID().uuidString

    private convenience init() {
        self.init(voiceLog: PersistentVoiceLog(url: PersistentVoiceLog.defaultURL))
        appendVoiceDiagnostic("[VOICE-DIAG] launch build=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")")
    }

    // Injectable disk store for restart/rotation tests without touching app data.
    init(voiceLog: PersistentVoiceLog) { self.voiceLog = voiceLog }

    private func snapshot() -> [ConsoleLogEntry] {
        var result = storage + voiceLog.entries()
        if voiceLog.writeFailed {
            result.append(ConsoleLogEntry(timestamp: Date(), level: "ERROR",
                message: "[VOICE-DIAG] Disk write failed; voice history may not survive restart."))
        }
        return result.sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: Reading

    /// Current native logs and saved voice history, oldest first.
    public var entries: [ConsoleLogEntry] {
        lock.lock(); defer { lock.unlock() }
        return snapshot()
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return snapshot().count
    }

    /// The native buffer interleaved with a bridge's web logs, oldest first — the
    /// unified stream for anything that reports "the app's logs".
    public static func merged(with bridgeLogs: [ConsoleLogEntry]) -> [ConsoleLogEntry] {
        (shared.entries + bridgeLogs).sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: Writing

    /// Append a line. Safe from any thread and synchronous, so a log emitted
    /// microseconds before a crash is already in the buffer.
    public func append(_ message: String, level: RipulLogLevel = .log, stack: String? = nil) {
        append(message, level: level, stack: stack, persistent: false)
    }

    func appendVoiceDiagnostic(_ message: String, level: RipulLogLevel = .log) {
        append("[native] \(String(message.prefix(1024))) run=\(runID)", level: level, stack: nil, persistent: true)
    }

    private func append(_ message: String, level: RipulLogLevel, stack: String?, persistent: Bool) {
        guard Self.isCaptureEnabled else { return }
        let entry = ConsoleLogEntry(timestamp: Date(), level: level.rawValue,
                                    message: message, stack: stack)
        lock.lock()
        if persistent {
            voiceLog.append(entry)
        } else {
            if storage.count >= Self.maxEntries { storage.removeAll(keepingCapacity: true) }
            storage.append(entry)
        }
        let shouldSchedule = !notifyScheduled
        if shouldSchedule { notifyScheduled = true }
        lock.unlock()

        guard shouldSchedule else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.notifyScheduled = false; self.lock.unlock()
            self.changed.send(())
        }
    }

    public func clear() {
        lock.lock(); storage.removeAll(); voiceLog.clear(); lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.changed.send(()) }
    }

    // MARK: Convenience

    public static func log(_ message: String) { shared.append(message, level: .log) }
    public static func warn(_ message: String) { shared.append(message, level: .warn) }
    public static func error(_ message: String, stack: String? = nil) {
        shared.append(message, level: .error, stack: stack)
    }
}
