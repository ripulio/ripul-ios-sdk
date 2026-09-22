import XCTest
@testable import RipulAgent

final class PersistentVoiceLogTests: XCTestCase {
    private var directory: URL!
    private var url: URL { directory.appendingPathComponent("voice/events.jsonl") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testErrorMetadataKeepsTLSCodesWithoutPrivateErrorContents() {
        let error = NSError(domain: NSURLErrorDomain, code: -1200, userInfo: [
            NSLocalizedDescriptionKey: "private transcript",
            NSURLErrorFailingURLErrorKey: URL(string: "https://secret.example/?token=credential")!,
            NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -9820)
        ])
        XCTAssertEqual(voiceErrorMetadata(error), "error=NSURLErrorDomain:-1200 underlying1=NSOSStatusErrorDomain:-9820")
        XCTAssertEqual(voiceErrorMetadata(NSError(domain: "private server response", code: 1)), "error=other:1")
    }

    func testImmediateRestartRestoresOriginalIDsAndOnlyOptedInDiagnostics() throws {
        let log = RipulLog(voiceLog: PersistentVoiceLog(url: url))
        log.append("private transcript and token", level: .error)
        log.appendVoiceDiagnostic("[VOICE-STT] disconnect code=-9820", level: .warn)
        let before = try XCTUnwrap(log.entries.last)
        let restarted = RipulLog(voiceLog: PersistentVoiceLog(url: url))
        XCTAssertEqual(restarted.entries.count, 1)
        XCTAssertEqual(restarted.entries.first?.id, before.id)
        XCTAssertEqual(restarted.entries.first?.timestamp, before.timestamp)
        XCTAssertEqual(restarted.entries.first?.level, "WARN")
        XCTAssertFalse(try String(contentsOf: url).contains("private transcript"))
        XCTAssertTrue(restarted.entries[0].message.contains("run="))
    }

    func testGeneralConsoleFloodCannotEvictOrDuplicateVoiceHistory() {
        let log = RipulLog(voiceLog: PersistentVoiceLog(url: url))
        log.appendVoiceDiagnostic("[VOICE] mic DOWN")
        for i in 0..<4100 { log.append("ordinary \(i)") }
        XCTAssertEqual(log.entries.filter { $0.message.contains("[VOICE]") }.count, 1)
        XCTAssertEqual(PersistentVoiceLog(url: url).entries().count, 1)
        XCTAssertEqual(log.count, log.entries.count)
    }

    func testClearRemovesHistoryAcrossRestart() {
        let log = RipulLog(voiceLog: PersistentVoiceLog(url: url))
        log.appendVoiceDiagnostic("[VOICE] old")
        log.clear()
        XCTAssertTrue(log.entries.isEmpty)
        XCTAssertTrue(PersistentVoiceLog(url: url).entries().isEmpty)
        log.appendVoiceDiagnostic("[VOICE] new")
        XCTAssertEqual(PersistentVoiceLog(url: url).entries().count, 1)
        XCTAssertFalse(PersistentVoiceLog(url: url).entries()[0].message.contains("old"))
    }

    func testRotationBoundsDiskAndPreservesNewestEvents() throws {
        let log = RipulLog(voiceLog: PersistentVoiceLog(url: url, maxEntries: 8, maxBytes: 4096))
        for i in 0..<100 { log.appendVoiceDiagnostic("[VOICE] event=\(i) " + String(repeating: "x", count: 800)) }
        XCTAssertLessThanOrEqual(try Data(contentsOf: url).count, 4096)
        let restored = PersistentVoiceLog(url: url, maxEntries: 8, maxBytes: 4096).entries()
        XCTAssertLessThanOrEqual(restored.count, 8)
        XCTAssertTrue(restored.last?.message.contains("event=99 ") == true)
        XCTAssertEqual(Set(restored.map(\.id)).count, restored.count)
    }

    func testExpiryPrunesDiskAndHistoryOnNextWrite() throws {
        let now = Date()
        let log = PersistentVoiceLog(url: url, retention: 60, now: now)
        log.append(ConsoleLogEntry(timestamp: now.addingTimeInterval(-61), level: "WARN", message: "expired"))
        log.append(ConsoleLogEntry(timestamp: now, level: "LOG", message: "recent"))
        XCTAssertEqual(log.entries(now: now).map(\.message), ["recent"])
        XCTAssertFalse(try String(contentsOf: url).contains("expired"))
        XCTAssertTrue(PersistentVoiceLog(url: url, retention: 60, now: now.addingTimeInterval(61)).entries(now: now.addingTimeInterval(61)).isEmpty)
    }

    func testTruncatedTailDoesNotLoseEarlierEventsOrPoisonFutureWrites() throws {
        let log = RipulLog(voiceLog: PersistentVoiceLog(url: url))
        log.appendVoiceDiagnostic("[VOICE] before interruption")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"timestamp\":".utf8))
        try handle.close()
        let restarted = RipulLog(voiceLog: PersistentVoiceLog(url: url))
        XCTAssertEqual(restarted.entries.count, 1)
        restarted.appendVoiceDiagnostic("[VOICE] after restart")
        XCTAssertEqual(PersistentVoiceLog(url: url).entries().count, 2)
    }

    func testWriteFailureIsVisibleAndNextEventRetriesWithoutLosingHistory() throws {
        let blocker = url.deletingLastPathComponent()
        try Data("not a directory".utf8).write(to: blocker)
        let log = RipulLog(voiceLog: PersistentVoiceLog(url: url))
        log.appendVoiceDiagnostic("[VOICE] first")
        XCTAssertTrue(log.entries.contains { $0.message.contains("Disk write failed") })
        try FileManager.default.removeItem(at: blocker)
        log.appendVoiceDiagnostic("[VOICE] second")
        XCTAssertFalse(log.entries.contains { $0.message.contains("Disk write failed") })
        XCTAssertEqual(PersistentVoiceLog(url: url).entries().count, 2)
    }
}
