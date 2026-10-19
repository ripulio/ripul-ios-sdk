import XCTest
@testable import RipulAgent

final class WebKitTerminationLogTests: XCTestCase {
    func testOldCrashHistoryStillDecodesWithoutSystemLog() throws {
        let oldRecord = Data("""
        {"id":"B0733CCB-EF03-473C-B378-F745985A5160","timestamp":800000000,
         "appMemoryMB":300,"availableMemoryMB":3100,"thermalState":"Nominal",
         "wasConnected":true,"crashNumber":11}
        """.utf8)
        let event = try JSONDecoder().decode(WebViewCrashEvent.self, from: oldRecord)
        XCTAssertEqual(event.crashNumber, 11)
        XCTAssertNil(event.terminationLog)
        XCTAssertNil(event.terminationReason)
    }

    func testSystemMessageRedactsCredentialsBeforeTruncation() {
        let message = "WebProcessProxy::processDidTerminate: reason=Crash https://example.com/#token=secret-value&code=sign-in-code&ok=1"
        let safe = WebViewLogRedaction.text(message, limit: 800)
        XCTAssertTrue(safe.contains("reason=Crash"))
        XCTAssertFalse(safe.contains("secret-value"))
        XCTAssertFalse(safe.contains("sign-in-code"))
        XCTAssertTrue(safe.contains("ok=1"))
    }

    func testLogReadFailureRemainsDistinctFromNoMatchingEntriesAfterPersistence() throws {
        let unavailable = WebKitTerminationLog(entries: [], error: "Log store unavailable", truncated: false)
        let restored = try JSONDecoder().decode(WebKitTerminationLog.self, from: JSONEncoder().encode(unavailable))
        XCTAssertEqual(restored.error, "Log store unavailable")
        XCTAssertTrue(restored.entries.isEmpty)
    }

    func testPersistedCrashExportIncludesEvidenceAndRedactsPageURL() throws {
        var event = WebViewCrashEvent(id: UUID(), timestamp: Date(), appMemoryMB: 300,
                                     availableMemoryMB: 3100, thermalState: "Nominal",
                                     url: "https://example.com/#token=secret-value", wasConnected: true, crashNumber: 1)
        event.terminationLog = WebKitTerminationLog(entries: [], error: "Unavailable", truncated: false)
        event.terminationReason = WebKitTerminationReason(rawValue: 4)
        let restored = try JSONDecoder().decode(WebViewCrashEvent.self, from: JSONEncoder().encode(event))
        XCTAssertEqual(restored.terminationReason?.rawValue, 4)
        XCTAssertEqual(restored.terminationReason?.label, "ExceededSharedProcessCrashLimit")
        let history = try ConsoleLogsTool.crashHistory(Array(repeating: event, count: 25))
        XCTAssertEqual(history.count, 20)
        XCTAssertEqual((history[0]["terminationLog"] as? [String: Any])?["error"] as? String, "Unavailable")
        XCTAssertFalse((history[0]["url"] as? String ?? "").contains("secret-value"))
        XCTAssertTrue(history[0]["timestamp"] is String)
        XCTAssertEqual((history[0]["terminationReason"] as? [String: Any])?["rawValue"] as? Int, 4)
    }

    func testAnUnfamiliarOSReasonIsPreservedWithoutInventingACause() throws {
        let reason = WebKitTerminationReason(rawValue: 999)
        let restored = try JSONDecoder().decode(WebKitTerminationReason.self, from: JSONEncoder().encode(reason))
        XCTAssertEqual(restored.rawValue, 999)
        XCTAssertEqual(restored.label, "Unknown")
    }
}
