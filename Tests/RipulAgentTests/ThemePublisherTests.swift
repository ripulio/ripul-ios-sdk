import XCTest
@testable import RipulAgent

@MainActor
final class ThemePublisherTests: XCTestCase {
    let base = URL(string: "https://example.com")!
    func response(_ code: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: base, statusCode: code, httpVersion: nil, headerFields: headers)!
    }
    func testPublishingUsesReviewedVersionAndPreservesTheCompleteDocument() async throws {
        let original = Data(#"{"tips":{"intro":{"title":"New copy"}},"hostOnly":{"values":[1,true,null]},"empty":""}"#.utf8)
        var request: URLRequest?
        let client = RipulThemePublisher(baseURL: base, tokenProvider: { "test-token" }, fetch: {
            request = $0
            return (Data(#"{"etag":"new-version"}"#.utf8), self.response(200))
        })
        let result = try await client.publish(id: "app-v1", data: original, replacing: "reviewed-version")
        XCTAssertEqual(request?.url?.path, "/api/admin/app-themes/app-v1")
        XCTAssertEqual(request?.httpMethod, "PUT")
        XCTAssertEqual(request?.httpBody, original)
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "If-Match"), "reviewed-version")
        XCTAssertNil(request?.value(forHTTPHeaderField: "If-None-Match"))
        XCTAssertEqual(result.etag, "new-version")
        XCTAssertEqual(result.data, original)
    }
    func testFirstPublishIsCreateOnlyAndReadDoesNotSendCredentials() async throws {
        let client = RipulThemePublisher(baseURL: base, tokenProvider: { "test-token" }, fetch: { request in
            if request.httpMethod == "PUT" {
                XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "*")
                return (Data(#"{"etag":"first"}"#.utf8), self.response(200))
            }
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.url?.path, "/api/v1/app-themes/app")
            return (Data(), self.response(404))
        })
        let loaded = try await client.load(id: "app")
        XCTAssertNil(loaded)
        _ = try await client.publish(id: "app", data: Data("{}".utf8), replacing: nil)
    }
    func testInvalidOversizedAndSignedOutDraftsNeverWrite() async throws {
        var calls = 0
        let client = RipulThemePublisher(baseURL: base, tokenProvider: { nil }, fetch: { _ in
            calls += 1; return (Data(), self.response(200))
        })
        for text in ["[]", "null", "broken", "{\"text\":\"" + String(repeating: "x", count: 512 * 1024) + "\"}", "{}"] {
            do { _ = try await client.publish(id: "app", data: Data(text.utf8), replacing: nil); XCTFail("Must reject") }
            catch {}
        }
        XCTAssertEqual(calls, 0)
    }
    func testConflictAndPermissionFailuresAreReportedWithoutSuccess() async throws {
        for status in [401, 403, 412, 500] {
            let client = RipulThemePublisher(baseURL: base, tokenProvider: { "test-token" }, fetch: { _ in
                (Data("{}".utf8), self.response(status))
            })
            do { _ = try await client.publish(id: "app", data: Data("{}".utf8), replacing: "old"); XCTFail("Must reject") }
            catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        }
    }
    func testReviewDistinguishesDeletionEmptyTextAndBooleanFromNumber() {
        let before = Data(#"{"a/b":"Old","deleted":true,"empty":"old","flag":false,"unchanged":{"x":1}}"#.utf8)
        let after = Data(#"{"a/b":"New","empty":"","flag":0,"unchanged":{"x":1}}"#.utf8)
        let changes = ThemeDocumentChanges.compare(before, after)
        XCTAssertEqual(changes.map(\.path), ["/a~1b", "/deleted", "/empty", "/flag"])
        XCTAssertEqual(changes[1].after, "(not set)")
        XCTAssertEqual(changes[2].after, "(empty text)")
    }
    func testEditingLeaseBlocksForegroundReplacementAndPublishedThemeSurvivesRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = Data(#"{"title":"old"}"#.utf8), draft = Data(#"{"title":"draft","hostExtra":[1,2]}"#.utf8)
        let url = base.appendingPathComponent("v1/app-themes/app")
        var current = Data(), calls = 0
        let remote = RipulRemoteThemeClient(url: url, fallback: old, cacheDirectory: directory,
            validateAndApply: { current = $0 }, fetch: { _ in calls += 1; return (old, self.response(200, headers: ["ETag": "old"])) })
        try remote.start(); await remote.refresh()
        let lease = remote.beginEditing()
        try remote.preview(draft)
        await remote.refresh()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(current, draft)
        XCTAssertEqual(remote.authoritativeDocument, old)
        try remote.acceptPublication(RipulThemeManifest(data: draft, etag: "published"))
        XCTAssertEqual(remote.authoritativeETag, "published")
        let reloaded = RipulRemoteThemeClient(url: url, fallback: old, cacheDirectory: directory,
            validateAndApply: { current = $0 }, fetch: { _ in throw URLError(.notConnectedToInternet) })
        try reloaded.start(); await reloaded.refresh()
        XCTAssertEqual(current, draft)
        remote.endEditing(lease); remote.stop(); reloaded.stop()
    }
}
