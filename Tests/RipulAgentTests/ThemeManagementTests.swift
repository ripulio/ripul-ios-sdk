#if os(iOS)
import XCTest
@testable import RipulAgent

@MainActor
final class ThemeManagementTests: XCTestCase {
    let base = URL(string: "https://example.com")!
    let original = Data(#"{"title":"Old","hostExtra":{"unknown":[1,true,null]}}"#.utf8)
    let edited = Data(#"{"title":"New","hostExtra":{"unknown":[1,true,null]}}"#.utf8)

    func testFailedPublishAndInvalidSourceSurviveClosingAndReopening() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        var live = original
        let remote = RipulRemoteThemeClient(url: base.appendingPathComponent("v1/app-themes/app"),
            fallback: original, cacheDirectory: folder.appendingPathComponent("cache"), validateAndApply: {
                struct Theme: Decodable { let title: String }
                _ = try JSONDecoder().decode(Theme.self, from: $0); live = $0
            }, fetch: { _ in throw URLError(.notConnectedToInternet) })
        try remote.start()
        var sends = 0
        let publisher = RipulThemePublisher(baseURL: base, tokenProvider: { "test" }, fetch: { request in
            sends += 1
            if request.httpMethod == "GET" { return (Data(), HTTPURLResponse(url: self.base, statusCode: 404, httpVersion: nil, headerFields: nil)!) }
            throw URLError(.notConnectedToInternet)
        })
        func make() -> ThemeManagementModel {
            ThemeManagementModel(baseURL: base, tokenProvider: { "test" }, remote: remote,
                publisher: publisher, draftURL: folder.appendingPathComponent("draft.json"), capture: { _ in live })
        }
        let first = make(); first.start()
        first.sourceChanged(String(decoding: edited, as: UTF8.self)); first.applySource()
        XCTAssertTrue(first.canPublish)
        await first.publish()
        XCTAssertFalse(first.published); XCTAssertNotNil(first.error); XCTAssertEqual(sends, 2)
        first.close(); remote.stop()
        let second = make(); second.start()
        XCTAssertEqual(ThemeManagementModel.canonical(second.data), ThemeManagementModel.canonical(edited))
        XCTAssertEqual(ThemeManagementModel.canonical(live), ThemeManagementModel.canonical(edited))
        XCTAssertTrue(second.hasChanges)
        second.sourceChanged("{invalid"); second.applySource()
        XCTAssertTrue(second.sourceDirty); XCTAssertFalse(second.canPublish)
        XCTAssertEqual(ThemeManagementModel.canonical(live), ThemeManagementModel.canonical(edited))
        second.close(); remote.stop()
        let third = make(); third.start()
        XCTAssertEqual(third.text, "{invalid"); XCTAssertFalse(third.canPublish)
        third.close(); remote.stop()
    }

    func testEngineCapturePreservesHostExtrasAndClearsOnlyEditedMaps() throws {
        let kind = RipulStyleKind(name: "copy", scopes: [.init(id: "welcome", label: "Welcome")],
            knobs: [.init("text", "Text", .text(fallback: ""))], defaultTier: { _, _ in [:] },
            persistedKeys: .init(styles: "copyStyles", assignments: "copyNames", overrides: "copyOverrides"))
        RipulThemeEngine.configure(RipulThemeSpec(bundleResource: "MissingFixture", overrideDefaultsKey: "ThemeManagementTests", vocabulary: .init(primitives: [], roles: [], components: []), styleKinds: [kind]))
        var document = RipulThemeDocument()
        document.styleOverrides["copy"] = ["welcome": ["text": .string("Updated")]]
        RipulThemeEngine.adopt(document)
        let base = Data(#"{"hostExtra":{"unknown":[1,true,null]},"copyOverrides":{"removed":{"text":"Old"}}}"#.utf8)
        let encoded = try RipulThemeEngine.themeDocumentForPublishing(over: base)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNotNil(json["hostExtra"])
        let overrides = try XCTUnwrap(json["copyOverrides"] as? [String: [String: String]])
        XCTAssertNil(overrides["removed"]); XCTAssertEqual(overrides["welcome"]?["text"], "Updated")
        XCTAssertNil(json["copyStyles"], "Opening the editor must not add absent empty maps")
    }
    func testResetLastTextChangeLeavesNoDraftChangesAndPreservesExistingEmptyGroups() throws {
        let exporter = RipulThemeEngine.exportThemeDocument, native = NativeTextRuntime.current
        defer { RipulThemeEngine.exportThemeDocument = exporter; NativeTextRuntime.adopt(native) }
        for original in [self.original, Data(#"{"title":"Old","nativeTextOverrides":{}}"#.utf8),
                         Data(#"{"title":"Old","nativeTextOverrides":{"tokens":{},"future":{}}}"#.utf8)] {
            RipulThemeEngine.exportThemeDocument = { $0 ?? original }
            NativeTextRuntime.adopt(try NativeTextTheme.decode(document: original))
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            var live = original
            let remote = RipulRemoteThemeClient(url: base.appendingPathComponent("v1/app-themes/app"),
                fallback: original, cacheDirectory: folder.appendingPathComponent("cache"),
                validateAndApply: { live = $0 }, fetch: { _ in throw URLError(.notConnectedToInternet) })
            try remote.start(); defer { remote.stop() }
            RipulElementText.configure(defaults: ["action.save": .text("Save")])
            let path = folder.appendingPathComponent("draft.json")
            func make() -> ThemeManagementModel {
                ThemeManagementModel(baseURL: base, tokenProvider: { nil }, remote: remote,
                    draftURL: path, capture: { _ in live })
            }
            let first = make(); first.start(); first.close()
            try ThemeManagementModel.saveTextMutation({ document in
                document.tokens["action.save"] = .text("Keep")
                document.elements["save"] = ["text": .token("action.save")]
            }, remote: remote, draftURL: path)
            try ThemeManagementModel.saveTextMutation({ document in
                document.tokens.removeAll(); document.elements.removeAll()
            }, remote: remote, draftURL: path)
            let reopened = make(); reopened.start()
            XCTAssertEqual(ThemeManagementModel.canonical(reopened.data), ThemeManagementModel.canonical(original))
            XCTAssertFalse(reopened.hasChanges)
            XCTAssertTrue(ThemeDocumentChanges.compare(original, reopened.data).isEmpty)
            reopened.close()
        }
    }
}
#endif
