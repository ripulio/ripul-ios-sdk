import Combine
import Foundation

/// What one bridge has heard from the web app's console and network: two
/// rolling buffers, and the copy of the console that is kept across launches.
///
/// Native log lines are not here. They live in `RipulLog`, which exists from
/// launch, and readers merge the two by time.
@MainActor
final class BridgeLogStore {
    /// Both buffers empty outright at this size rather than trimming as they
    /// go. A rolling buffer calls removeFirst() on every append past the cap
    /// (O(n) each time); under the log floods we've seen from the native poll
    /// loop that thrashes the array and pegs the main actor. Clearing outright
    /// gives one O(n) op per 5000 entries instead of one per entry. Losing
    /// older history at the cap is acceptable — these buffers are only for
    /// debug views.
    static let capacity = 5000

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Console

    /// Appended on every console line, potentially dozens per second, so
    /// nothing observes it. The debug views that show it (ConsoleLogViewer, the
    /// Settings error badge) listen to `consoleChanged` instead.
    var console: [ConsoleLogEntry] = [] {
        didSet { consoleChanged.send(()) }
    }
    let consoleChanged = PassthroughSubject<Void, Never>()

    /// Add one line as the web app sends it: an optional "LOG:", "WARN:" or
    /// "ERROR:" prefix, and an optional stack trace after a `__STACK__` line.
    @discardableResult
    func appendConsole(_ message: String) -> ConsoleLogEntry {
        // Split off stack trace if present (appended after __STACK__ separator)
        let mainMessage: String
        let stack: String?
        if let stackRange = message.range(of: "\n__STACK__\n") {
            mainMessage = String(message[message.startIndex..<stackRange.lowerBound])
            let rawStack = String(message[stackRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            stack = rawStack.isEmpty ? nil : rawStack
        } else {
            mainMessage = message
            stack = nil
        }

        // Parse level prefix ("LOG: ...", "WARN: ...", "ERROR: ...")
        let level: String
        let body: String
        if let colonIdx = mainMessage.firstIndex(of: ":") {
            let prefix = String(mainMessage[mainMessage.startIndex..<colonIdx])
            if ["LOG", "WARN", "ERROR"].contains(prefix) {
                level = prefix
                body = String(mainMessage[mainMessage.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
            } else {
                level = "LOG"
                body = mainMessage
            }
        } else {
            level = "LOG"
            body = mainMessage
        }

        if console.count >= Self.capacity {
            console.removeAll(keepingCapacity: true)
        }
        let entry = ConsoleLogEntry(timestamp: Date(), level: level, message: body, stack: stack)
        console.append(entry)
        scheduleSave(for: entry)
        return entry
    }

    // MARK: - Saved across launches

    private static let savesErrorsKey = "ripulPersistErrorLogs"
    private static let savesAllKey = "ripulPersistAllLogs"
    private static let savedKey = "ripulPersistedErrorLogs"
    private static let maxSavedErrors = 500
    private static let maxSavedAll = 2000

    /// When true, WARN and ERROR entries are saved to UserDefaults.
    var savesErrors: Bool {
        get { defaults.bool(forKey: Self.savesErrorsKey) }
        set { defaults.set(newValue, forKey: Self.savesErrorsKey) }
    }

    /// When true, ALL entries are saved to UserDefaults (for crash diagnosis).
    var savesAll: Bool {
        get { defaults.bool(forKey: Self.savesAllKey) }
        set { defaults.set(newValue, forKey: Self.savesAllKey) }
    }

    /// Put the last launch's saved lines at the front of the buffer, with a
    /// note after them saying where they came from.
    func restoreSaved() {
        guard savesErrors || savesAll else { return }
        guard let data = defaults.data(forKey: Self.savedKey),
              let entries = try? JSONDecoder().decode([ConsoleLogEntry].self, from: data),
              !entries.isEmpty else { return }
        let separator = ConsoleLogEntry(
            timestamp: Date(), level: "LOG",
            message: "--- Restored \(entries.count) persisted logs from previous session ---"
        )
        console.insert(contentsOf: entries + [separator], at: 0)
    }

    func clearSaved() {
        defaults.removeObject(forKey: Self.savedKey)
    }

    private var unsaved = false
    private var saveDebounce: DispatchWorkItem?

    private func scheduleSave(for entry: ConsoleLogEntry) {
        let all = savesAll
        guard all || savesErrors else { return }

        // In errors-only mode, skip LOG entries
        if !all && entry.level == "LOG" { return }

        unsaved = true
        saveDebounce?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.unsaved else { return }
            self.unsaved = false
            self.save()
        }
        saveDebounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: item)
    }

    private func save() {
        let all = savesAll
        let cap = all ? Self.maxSavedAll : Self.maxSavedErrors

        var existing: [ConsoleLogEntry] = []
        if let data = defaults.data(forKey: Self.savedKey) {
            existing = (try? JSONDecoder().decode([ConsoleLogEntry].self, from: data)) ?? []
        }
        let existingIds = Set(existing.map(\.id))
        let newEntries = console.filter { entry in
            !existingIds.contains(entry.id) &&
            (all || entry.level == "ERROR" || entry.level == "WARN")
        }
        guard !newEntries.isEmpty else { return }
        let combined = Array((existing + newEntries).suffix(cap))
        if let data = try? JSONEncoder().encode(combined) {
            defaults.set(data, forKey: Self.savedKey)
        }
    }

    // MARK: - Network

    private static let capturesNetworkKey = "ripulNetworkCaptureEnabled"

    /// Whether the user has asked for network requests to be captured. Off
    /// until they opt in from the Network tab. The bridge tells the page.
    var capturesNetwork: Bool {
        get { defaults.bool(forKey: Self.capturesNetworkKey) }
        set { defaults.set(newValue, forKey: Self.capturesNetworkKey) }
    }

    var network: [NetworkLogEntry] = [] {
        didSet { networkChanged.send(()) }
    }
    let networkChanged = PassthroughSubject<Void, Never>()

    /// Add one request as the page's interceptor reports it. Anything that is
    /// not a dictionary is ignored.
    func appendNetwork(_ body: Any) {
        guard let dict = body as? [String: Any] else { return }
        let method = dict["method"] as? String ?? "GET"
        let url = dict["url"] as? String ?? ""
        let status = dict["status"] as? Int ?? 0
        let statusText = dict["statusText"] as? String ?? ""
        let durationMs = dict["duration"] as? Int ?? -1
        let requestSize = dict["reqSize"] as? Int ?? -1
        let responseSize = dict["resSize"] as? Int ?? -1
        let reqHeaders = dict["reqHeaders"] as? [String: String] ?? [:]
        let resHeaders = dict["resHeaders"] as? [String: String] ?? [:]
        let error = dict["error"] as? String

        if network.count >= Self.capacity {
            network.removeAll(keepingCapacity: true)
        }
        network.append(NetworkLogEntry(
            timestamp: Date(), method: method, url: url,
            status: status, statusText: statusText, durationMs: durationMs,
            requestSize: requestSize, responseSize: responseSize,
            requestHeaders: reqHeaders, responseHeaders: resHeaders,
            error: error
        ))
    }
}
