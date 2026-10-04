import Foundation

/// The file behind `AgentBridge.debugLog`.
///
/// Each line used to be written on the calling thread, opening, seeking,
/// writing and closing the file every time. On the Mac host that thread is the
/// main thread, once for every web console message it forwards. Nothing trimmed
/// the file either: 94 MB on one Mac on 2026-10-03.
///
/// Now lines go to a serial queue that keeps one append-only descriptor open,
/// and the file rolls over to `<path>.1` past `maxBytes`, so the pair holds
/// about twice that at most. O_APPEND keeps lines whole when another process
/// writes the same file, and a rollover by another process is followed by name.
/// Tests/DebugLog in ripul-native-app covers all of this.
final class DebugLogFile: @unchecked Sendable {
    static let shared = DebugLogFile(path: "/tmp/ripul-debug.log", maxBytes: 16 * 1024 * 1024)

    let path: String
    private let maxBytes: Int64
    private let queue = DispatchQueue(label: "ripul.debug-log", qos: .utility)
    // Only touched on `queue`.
    private var fd: Int32 = -1
    private var lastOpenFailure: Date?

    init(path: String, maxBytes: Int64) {
        self.path = path
        self.maxBytes = maxBytes
    }

    /// Queues `line` (with its newline) for the file and returns at once.
    func append(_ line: String) {
        let data = Data(line.utf8)
        queue.async { [self] in write(data) }
    }

    /// Waits until every line appended so far has been written.
    func flush() {
        queue.sync {}
    }

    private func write(_ data: Data) {
        guard let size = openSize() else { return }
        if size > 0, size + Int64(data.count) > maxBytes {
            rollOver()
            guard openSize() != nil else { return }
        }
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written <= 0 {
                    if written < 0 && errno == EINTR { continue }
                    return
                }
                offset += written
            }
        }
    }

    /// The size of the open file, opening it if needed. If another process
    /// renamed it, the next write goes to whatever now has the name.
    private func openSize() -> Int64? {
        if fd >= 0 {
            var mine = stat(), named = stat()
            if fstat(fd, &mine) == 0, stat(path, &named) == 0, mine.st_ino == named.st_ino, mine.st_dev == named.st_dev {
                return Int64(mine.st_size)
            }
            close(fd)
            fd = -1
        }
        // An unwritable path (iOS has no /tmp) costs one attempt per 5 seconds.
        if let failed = lastOpenFailure, Date().timeIntervalSince(failed) < 5 { return nil }
        fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            lastOpenFailure = Date()
            return nil
        }
        lastOpenFailure = nil
        var info = stat()
        return fstat(fd, &info) == 0 ? Int64(info.st_size) : 0
    }

    private func rollOver() {
        close(fd)
        fd = -1
        let previous = path + ".1"
        unlink(previous)
        rename(path, previous)
    }
}
