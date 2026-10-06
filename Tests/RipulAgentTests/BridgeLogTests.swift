import Combine
import XCTest
@testable import RipulAgent

/// The bridge's console and network log buffers, through the bridge's own API:
/// what a line becomes, when the buffer empties, what is saved across launches.
@MainActor
final class BridgeLogTests: XCTestCase {
    private static let savedLogsKey = "ripulPersistedErrorLogs"
    private static let keys = ["ripulPersistErrorLogs", "ripulPersistAllLogs", savedLogsKey, "ripulNetworkCaptureEnabled"]

    override func setUp() async throws { Self.keys.forEach(UserDefaults.standard.removeObject) }
    override func tearDown() async throws { Self.keys.forEach(UserDefaults.standard.removeObject) }

    /// Only the lines these tests wrote: a bridge also logs on its own account.
    private func mine(_ entries: [ConsoleLogEntry]) -> [ConsoleLogEntry] {
        entries.filter { $0.message.hasPrefix("t:") }
    }

    private func saved() -> [ConsoleLogEntry] {
        guard let data = UserDefaults.standard.data(forKey: Self.savedLogsKey) else { return [] }
        return (try? JSONDecoder().decode([ConsoleLogEntry].self, from: data)) ?? []
    }

    /// Saving is debounced by two seconds.
    private func waitForSave(_ count: Int) async {
        let deadline = Date().addingTimeInterval(5)
        while mine(saved()).count < count, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    // MARK: - Console

    func testALevelPrefixBecomesTheLevel() {
        let bridge = AgentBridge()
        let lines: [(String, String, String, String?)] = [
            ("LOG: t: hello", "LOG", "t: hello", nil),
            ("WARN:   t: spaced  ", "WARN", "t: spaced", nil),
            ("ERROR: t: boom", "ERROR", "t: boom", nil),
            ("t: plain", "LOG", "t: plain", nil),
            ("INFO: t: not a level", "LOG", "INFO: t: not a level", nil),
            ("ERROR: t: bad\n__STACK__\n  at f (x.js:1)\n", "ERROR", "t: bad", "at f (x.js:1)"),
            ("LOG: t: blank stack\n__STACK__\n   \n", "LOG", "t: blank stack", nil),
        ]
        for (line, level, message, stack) in lines {
            let before = bridge.consoleLogs.count
            bridge.handleConsoleLog(line)
            XCTAssertEqual(bridge.consoleLogs.count, before + 1, line)
            let entry = bridge.consoleLogs.last
            XCTAssertEqual(entry?.level, level, line)
            XCTAssertEqual(entry?.message, message, line)
            XCTAssertEqual(entry?.stack, stack, line)
        }
    }

    func testTheBufferEmptiesWhenItIsFull() {
        let bridge = AgentBridge()
        bridge.clearConsoleLogs()
        for index in 0..<5000 { bridge.handleConsoleLog("t: \(index)") }
        XCTAssertEqual(bridge.consoleLogs.count, 5000)
        bridge.handleConsoleLog("t: one more")
        XCTAssertEqual(bridge.consoleLogs.map(\.message), ["t: one more"])
    }

    func testEachLineAnnouncesItselfAndClearEmpties() {
        let bridge = AgentBridge()
        var announcements = 0
        let watching = bridge.consoleLogsSubject.sink { announcements += 1 }
        bridge.handleConsoleLog("t: a")
        bridge.handleConsoleLog("t: b")
        XCTAssertEqual(announcements, 2)
        bridge.clearConsoleLogs()
        XCTAssertTrue(bridge.consoleLogs.isEmpty)
        XCTAssertEqual(announcements, 3)
        watching.cancel()
    }

    // MARK: - Saved across launches

    func testNothingIsSavedUnlessAsked() async {
        let bridge = AgentBridge()
        bridge.handleConsoleLog("ERROR: t: unsaved")
        try? await Task.sleep(nanoseconds: 2_400_000_000)
        XCTAssertNil(UserDefaults.standard.data(forKey: Self.savedLogsKey))
    }

    func testErrorsOnlySavesWarningsAndErrors() async {
        let bridge = AgentBridge()
        bridge.isPersistErrorLogsEnabled = true
        bridge.handleConsoleLog("LOG: t: log")
        bridge.handleConsoleLog("WARN: t: warn")
        bridge.handleConsoleLog("ERROR: t: error")
        await waitForSave(2)
        XCTAssertEqual(mine(saved()).map(\.message), ["t: warn", "t: error"])
    }

    func testSaveAllSavesEveryLine() async {
        let bridge = AgentBridge()
        bridge.isPersistAllLogsEnabled = true
        bridge.handleConsoleLog("LOG: t: log")
        bridge.handleConsoleLog("WARN: t: warn")
        await waitForSave(2)
        XCTAssertEqual(mine(saved()).map(\.message), ["t: log", "t: warn"])
    }

    func testSavedErrorsStopAtFiveHundredAndDropTheOldest() async throws {
        let old = (0..<500).map { ConsoleLogEntry(timestamp: Date(), level: "ERROR", message: "t: old \($0)") }
        UserDefaults.standard.set(try JSONEncoder().encode(old), forKey: Self.savedLogsKey)
        let bridge = AgentBridge()
        bridge.isPersistErrorLogsEnabled = true
        bridge.handleConsoleLog("ERROR: t: newest")
        let deadline = Date().addingTimeInterval(5)
        while saved().last?.message != "t: newest", Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let now = saved()
        XCTAssertEqual(now.count, 500)
        XCTAssertEqual(now.first?.message, "t: old 1")
        XCTAssertEqual(now.last?.message, "t: newest")
    }

    func testRestorePutsSavedLinesFirstFollowedByANote() throws {
        let old = ["t: one", "t: two"].map { ConsoleLogEntry(timestamp: Date(), level: "ERROR", message: $0) }
        UserDefaults.standard.set(try JSONEncoder().encode(old), forKey: Self.savedLogsKey)

        let off = AgentBridge()
        off.clearConsoleLogs()
        off.loadPersistedErrorLogs()
        XCTAssertTrue(off.consoleLogs.isEmpty, "Saving is off, so nothing is restored")

        let on = AgentBridge()
        on.clearConsoleLogs()
        on.isPersistErrorLogsEnabled = true
        on.handleConsoleLog("t: already here")
        on.loadPersistedErrorLogs()
        XCTAssertEqual(on.consoleLogs.map(\.message), [
            "t: one", "t: two", "--- Restored 2 persisted logs from previous session ---", "t: already here",
        ])
        XCTAssertEqual(on.consoleLogs.prefix(2).map(\.id), old.map(\.id), "A restored line keeps its identity")

        on.clearPersistedErrorLogs()
        XCTAssertNil(UserDefaults.standard.data(forKey: Self.savedLogsKey))
    }

    // MARK: - Network

    func testANetworkLineTakesItsFieldsOrTheirDefaults() {
        let bridge = AgentBridge()
        var announcements = 0
        let watching = bridge.networkLogsSubject.sink { announcements += 1 }
        bridge.handleNetworkLog([
            "method": "POST", "url": "https://x/y", "status": 201, "statusText": "Created", "duration": 42,
            "reqSize": 10, "resSize": 20, "reqHeaders": ["a": "b"], "resHeaders": ["c": "d"], "error": "late",
        ] as [String: Any])
        bridge.handleNetworkLog([String: Any]())
        bridge.handleNetworkLog("not a dictionary")
        XCTAssertEqual(bridge.networkLogs.count, 2)
        XCTAssertEqual(announcements, 2)

        let full = bridge.networkLogs[0]
        XCTAssertEqual([full.method, full.url, full.statusText], ["POST", "https://x/y", "Created"])
        XCTAssertEqual([full.status, full.durationMs, full.requestSize, full.responseSize], [201, 42, 10, 20])
        XCTAssertEqual(full.requestHeaders, ["a": "b"])
        XCTAssertEqual(full.responseHeaders, ["c": "d"])
        XCTAssertEqual(full.error, "late")

        let bare = bridge.networkLogs[1]
        XCTAssertEqual([bare.method, bare.url, bare.statusText], ["GET", "", ""])
        XCTAssertEqual([bare.status, bare.durationMs, bare.requestSize, bare.responseSize], [0, -1, -1, -1])
        XCTAssertTrue(bare.requestHeaders.isEmpty && bare.responseHeaders.isEmpty)
        XCTAssertNil(bare.error)

        bridge.clearNetworkLogs()
        XCTAssertTrue(bridge.networkLogs.isEmpty)
        watching.cancel()
    }

    func testTheNetworkBufferEmptiesWhenItIsFull() {
        let bridge = AgentBridge()
        for index in 0..<5000 { bridge.handleNetworkLog(["url": "u\(index)"]) }
        XCTAssertEqual(bridge.networkLogs.count, 5000)
        bridge.handleNetworkLog(["url": "one more"])
        XCTAssertEqual(bridge.networkLogs.map(\.url), ["one more"])
    }

    func testTheCaptureSwitchIsRemembered() {
        XCTAssertFalse(AgentBridge().isNetworkCaptureEnabled, "Off until asked for")
        AgentBridge().isNetworkCaptureEnabled = true
        XCTAssertTrue(AgentBridge().isNetworkCaptureEnabled)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "ripulNetworkCaptureEnabled"))
    }
}
