import XCTest
import Combine
@testable import RipulAgent

@MainActor
final class ThermalWorkTests: XCTestCase {
    private final class Cache: RipulSessionCache {
        let userDefaults = UserDefaults(suiteName: "io.ripul.thermal-tests.\(UUID())")!
        var values: [String: Any] = [:]
        var writes: [String] = []
        func data(forKey key: String) -> Data? { values[key] as? Data }
        func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
        func dictionary(forKey key: String) -> [String: Any]? { values[key] as? [String: Any] }
        func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
        func object(forKey key: String) -> Any? { values[key] }
        func set(_ value: Any?, forKey key: String) { values[key] = value; writes.append(key) }
        func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    }

    func testDuplicateWireActivityDoesNotPersistAndOlderCorrectionStillLands() async throws {
        let bridge = AgentBridge()
        let cache = Cache()
        let model = RipulSessionListModel(bridge: bridge, tokenProvider: { nil }, cache: cache)
        var activities = 0
        let sink = bridge.latestActivitySubject.sink { _ in activities += 1 }
        defer { sink.cancel(); withExtendedLifetime(model) {} }
        let timestamp = Date().timeIntervalSince1970 * 1000
        func activity(_ time: Double) {
            bridge.handleMessage(["type": "agent-framework:agent:activity", "chatId": "chat", "timestamp": time, "event": ["kind": "thinking"]])
        }
        activity(timestamp)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(cache.writes.contains("ripulLastActiveTimeByChatId"))
        cache.writes.removeAll()
        for _ in 0..<100 { activity(timestamp) }
        try await Task.sleep(for: .milliseconds(2100))
        XCTAssertTrue(cache.writes.isEmpty)
        XCTAssertEqual(activities, 1)
        activity(timestamp - 1000)
        XCTAssertEqual(bridge.sessionList.lastActiveTimeByChatId["chat"], Date(timeIntervalSince1970: (timestamp - 1000) / 1000))
    }

    func testEqualTimestampsAndActivityDoNotPublishButCorrectionsDo() async throws {
        let store = SessionListStore()
        let timestamp = Date(timeIntervalSince1970: 100)
        store.lastActiveTimeByChatId["chat"] = timestamp
        store.latestActivityByChatId["chat"] = .thinking
        try await Task.sleep(for: .milliseconds(300)) // drain the existing coalescer
        var publications = 0
        var timestampWrites = 0
        let a = store.objectWillChange.sink { publications += 1 }
        let b = store.lastActiveTimeSubject.sink { _ in timestampWrites += 1 }
        defer { a.cancel(); b.cancel() }
        for _ in 0..<100 {
            store.lastActiveTimeByChatId["chat"] = timestamp
            store.latestActivityByChatId["chat"] = .thinking
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(publications, 0)
        XCTAssertEqual(timestampWrites, 0)
        store.lastActiveTimeByChatId["chat"] = timestamp.addingTimeInterval(-10)
        XCTAssertEqual(timestampWrites, 1, "Authoritative downward corrections must survive")
        XCTAssertEqual(publications, 1)
    }

    func testCancelledPlaybackWaitExitsWithoutAnotherPollOrCompletion() async throws {
        var polls = 0
        var completed = false
        let task = Task {
            do {
                _ = try await VoiceReplyWait.untilPlaybackEnds { polls += 1; return true }
                completed = true
            } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        }
        while polls == 0 { await Task.yield() }
        task.cancel()
        await task.value
        XCTAssertEqual(polls, 1)
        XCTAssertFalse(completed)
    }

    func testMissingPlaybackCallbackTimesOutAndNormalCompletionReturns() async throws {
        let expired = try await VoiceReplyWait.untilPlaybackEnds(timeout: .milliseconds(5), pollInterval: .milliseconds(1)) { true }
        XCTAssertFalse(expired)
        var pending = true
        let task = Task { try await VoiceReplyWait.untilPlaybackEnds(pollInterval: .milliseconds(1)) { pending } }
        await Task.yield()
        pending = false
        let finished = try await task.value
        XCTAssertTrue(finished)
    }

    func testHistoryBatchPublishesOnceAndIdenticalUpdatesDoNotPublish() {
        let store = NativeChatMessageStore()
        let entries: [[String: Any]] = (0..<100).map { ["messageId": "\($0)", "content": "Reply \($0)", "timestamp": 123.0] }
        var publications = 0
        let observation = store.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }
        store.applyBackfill(entries)
        XCTAssertEqual(store.messages.count, 100)
        XCTAssertEqual(publications, 1)
        store.applyBackfill(entries)
        for _ in 0..<100 { store.applyAdd(entries[0]) }
        XCTAssertEqual(publications, 1)
        store.applyUpdate(["messageId": "0", "thinking": ["content": "Working", "isStreaming": true]])
        for _ in 0..<100 { store.applyUpdate(["messageId": "0", "thinking": ["content": "Working", "isStreaming": true]]) }
        XCTAssertEqual(publications, 2)
        XCTAssertEqual(store.messages[0].thinking, "Working")
        store.applyAdd(entries[0])
        XCTAssertTrue(store.messages[0].isThinkingStreaming)
        XCTAssertEqual(publications, 2)
    }
}
