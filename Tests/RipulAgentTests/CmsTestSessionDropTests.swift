import XCTest
@testable import RipulAgent

final class CmsTestSessionDropTests: XCTestCase {
    private var caches: URL!

    override func setUpWithError() throws {
        caches = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: caches)
    }

    private func drop(_ json: String, siteKey: String = "pk_live_abc") throws {
        let url = try XCTUnwrap(CmsTestSessionDrop.file(siteKey: siteKey, caches: caches))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
    }

    func testTakesTheSessionOnceAndDeletesTheFile() throws {
        let expires = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        try drop(#"{"token":"t0k","email":"guest@identities.invalid","expiresAt":"\#(expires)"}"#)
        let session = CmsTestSessionDrop.take(siteKey: "pk_live_abc", caches: caches)
        XCTAssertEqual(session?.email, "guest@identities.invalid")
        XCTAssertNil(CmsTestSessionDrop.take(siteKey: "pk_live_abc", caches: caches))
        let url = try XCTUnwrap(CmsTestSessionDrop.file(siteKey: "pk_live_abc", caches: caches))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testIgnoresAnotherSiteAndARunOutSession() throws {
        let expires = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        try drop(#"{"token":"t","email":"a@b.c","expiresAt":"\#(expires)"}"#, siteKey: "pk_other")
        XCTAssertNil(CmsTestSessionDrop.take(siteKey: "pk_live_abc", caches: caches))
        try drop(#"{"token":"t","email":"a@b.c","expiresAt":"2020-01-01T00:00:00Z"}"#)
        XCTAssertNil(CmsTestSessionDrop.take(siteKey: "pk_live_abc", caches: caches))
    }

    func testRefusesSiteKeysThatAreNotPlainNames() {
        XCTAssertNil(CmsTestSessionDrop.file(siteKey: "../escape", caches: caches))
        XCTAssertNil(CmsTestSessionDrop.file(siteKey: "", caches: caches))
    }

    func testOnlySimulatorDeveloperBuildsTakeDrops() {
        #if targetEnvironment(simulator)
        XCTAssertTrue(CmsTestSessionDrop.enabled)
        #else
        XCTAssertFalse(CmsTestSessionDrop.enabled)
        #endif
    }
}
