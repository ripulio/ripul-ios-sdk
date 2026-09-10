import XCTest
@testable import RipulAgent

@MainActor
final class RemoteThemeClientTests: XCTestCase {
    private let url = URL(string: "https://example.com/v1/app-themes/test")!
    private let fallback = Data(#"{"title":"bundled","localOnly":true}"#.utf8)

    private func directory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func response(_ status: Int = 200, etag: String? = nil) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                        headerFields: etag.map { ["ETag": $0] })!
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testStartAppliesBundleBeforeSlowNetworkAndServerReplacesWholeDocument() async throws {
        var current: [String: Any] = [:]
        var pending: CheckedContinuation<(Data, URLResponse), Error>?
        let client = RipulRemoteThemeClient(url: url, fallback: fallback, cacheDirectory: directory(),
            validateAndApply: { current = try self.object($0) },
            fetch: { _ in try await withCheckedThrowingContinuation { pending = $0 } })
        try client.start()
        XCTAssertEqual(current["title"] as? String, "bundled")
        XCTAssertEqual(client.origin, .bundled)
        while pending == nil { await Task.yield() }
        pending?.resume(returning: (Data(#"{"title":"server"}"#.utf8), response(etag: "v1")))
        await client.refresh()
        XCTAssertEqual(current["title"] as? String, "server")
        XCTAssertNil(current["localOnly"], "Server replaces rather than merges with client settings")
        XCTAssertEqual(client.origin, .server)
    }

    func testOfflineRelaunchUsesLastValidServerDocumentAndETag() async throws {
        let cache = directory()
        let remote = Data(#"{"title":"cached"}"#.utf8)
        let first = RipulRemoteThemeClient(url: url, fallback: fallback, cacheDirectory: cache,
            validateAndApply: { _ in }, fetch: { _ in (remote, self.response(etag: "v1")) })
        try first.start()
        await first.refresh()
        var current = Data()
        var requestedTag: String?
        let second = RipulRemoteThemeClient(url: url, fallback: fallback, cacheDirectory: cache,
            validateAndApply: { current = $0 }, fetch: { request in
                requestedTag = request.value(forHTTPHeaderField: "If-None-Match")
                throw URLError(.notConnectedToInternet)
            })
        try second.start()
        XCTAssertEqual(current, remote)
        XCTAssertEqual(second.origin, .cache)
        await second.refresh()
        XCTAssertEqual(requestedTag, "v1")
        XCTAssertEqual(current, remote)
        XCTAssertNotNil(second.lastError)
    }

    func testNotModifiedRestoresServerOverLocalPreview() async throws {
        var current = Data()
        var count = 0
        let remote = Data(#"{"title":"server"}"#.utf8)
        let client = RipulRemoteThemeClient(url: url, fallback: fallback, cacheDirectory: directory(),
            validateAndApply: { current = $0 }, fetch: { request in
                count += 1
                if count == 1 { return (remote, self.response(etag: "v1")) }
                XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "v1")
                return (Data(), self.response(304))
            })
        try client.start()
        await client.refresh()
        current = Data(#"{"title":"preview"}"#.utf8)
        await client.refresh()
        XCTAssertEqual(current, remote)
        XCTAssertNil(client.lastError)
    }

    func testInvalidOrIncompatibleResponsesDoNotReplaceOrPoisonCache() async throws {
        let cache = directory()
        let remote = Data(#"{"title":"good"}"#.utf8)
        var body = remote
        var current = Data()
        let client = RipulRemoteThemeClient(url: url, fallback: fallback, cacheDirectory: cache,
            validateAndApply: {
                struct Theme: Decodable { let title: String }
                _ = try JSONDecoder().decode(Theme.self, from: $0)
                current = $0
            }, fetch: { _ in (body, self.response()) })
        try client.start()
        await client.refresh()
        for bad in ["<html>error</html>", "[]", #"{"title":123}"#] {
            body = Data(bad.utf8)
            await client.refresh()
            XCTAssertEqual(current, remote)
            XCTAssertNotNil(client.lastError)
        }
        let reloaded = RipulRemoteThemeClient(url: url, fallback: fallback, cacheDirectory: cache,
            validateAndApply: { current = $0 }, fetch: { _ in throw URLError(.timedOut) })
        try reloaded.start()
        XCTAssertEqual(current, remote)
        reloaded.stop()
    }

    func testServerFailureKeepsBundleAndNeverCachesErrorBody() async throws {
        var current = Data()
        let client = RipulRemoteThemeClient(url: url, fallback: fallback, cacheDirectory: directory(),
            validateAndApply: { current = $0 }, fetch: { _ in
                (Data(#"{"error":"unavailable"}"#.utf8), self.response(503))
            })
        try client.start()
        await client.refresh()
        XCTAssertEqual(current, fallback)
        XCTAssertEqual(client.origin, .bundled)
        XCTAssertNotNil(client.lastError)
    }

    func testStopPreventsLateResponseFromApplying() async throws {
        var current = Data()
        var pending: CheckedContinuation<(Data, URLResponse), Error>?
        let client = RipulRemoteThemeClient(url: url, fallback: fallback, cacheDirectory: directory(),
            validateAndApply: { current = $0 },
            fetch: { _ in try await withCheckedThrowingContinuation { pending = $0 } })
        try client.start()
        while pending == nil { await Task.yield() }
        client.stop()
        pending?.resume(returning: (Data(#"{"title":"late"}"#.utf8), response()))
        // Let the cancelled request complete. Its response must never call the host.
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(current, fallback)
    }

    func testCacheDoesNotCrossThemeURLs() async throws {
        let cache = directory()
        let first = RipulRemoteThemeClient(url: url, fallback: fallback, cacheDirectory: cache,
            validateAndApply: { _ in }, fetch: { _ in
                (Data(#"{"title":"other app"}"#.utf8), self.response())
            })
        try first.start()
        await first.refresh()
        var current = Data()
        let second = RipulRemoteThemeClient(url: url.appendingPathComponent("beta"), fallback: fallback,
            cacheDirectory: cache, validateAndApply: { current = $0 },
            fetch: { _ in throw URLError(.notConnectedToInternet) })
        try second.start()
        XCTAssertEqual(current, fallback)
        second.stop()
    }

    func testIncompatibleCachedSchemaFallsBackWithoutSendingItsETag() async throws {
        let cache = directory()
        let first = RipulRemoteThemeClient(url: url, fallback: fallback, cacheDirectory: cache,
            validateAndApply: { _ in }, fetch: { _ in
                (Data(#"{"title":123}"#.utf8), self.response(etag: "incompatible"))
            })
        try first.start()
        await first.refresh()
        var current = Data()
        let second = RipulRemoteThemeClient(url: url, fallback: fallback, cacheDirectory: cache,
            validateAndApply: {
                struct Theme: Decodable { let title: String }
                _ = try JSONDecoder().decode(Theme.self, from: $0)
                current = $0
            }, fetch: { request in
                XCTAssertNil(request.value(forHTTPHeaderField: "If-None-Match"))
                throw URLError(.timedOut)
            })
        try second.start()
        XCTAssertEqual(current, fallback)
        XCTAssertEqual(second.origin, .bundled)
        await second.refresh()
    }
}
