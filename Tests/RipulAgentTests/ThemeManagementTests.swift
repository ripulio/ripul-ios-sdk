#if os(iOS)
import XCTest
import UIKit
@testable import RipulAgent

@MainActor
final class ThemeManagementTests: XCTestCase {
    let base = URL(string: "https://example.com")!
    let original = Data(#"{"title":"Old","hostExtra":{"unknown":[1,true,null]}}"#.utf8)
    let edited = Data(#"{"title":"New","hostExtra":{"unknown":[1,true,null]}}"#.utf8)

    func testSavingTextAppliesToBoundHostLabelBeforePublishingAndSurvivesDone() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let exporter = RipulThemeEngine.exportThemeDocument, native = NativeTextRuntime.current
        let defaults = RipulElementText.defaults
        let label = UILabel()
        defer {
            RipulElementText.unbind(label)
            RipulThemeEngine.exportThemeDocument = exporter
            RipulElementText.configure(defaults: defaults)
            NativeTextRuntime.adopt(native)
            try? FileManager.default.removeItem(at: folder)
        }
        RipulElementText.configure(defaults: [:])
        RipulThemeEngine.exportThemeDocument = { $0 ?? self.original }
        let assignment = RipulTextAssignment(element: "preview.regression.title", fallback: "Original")
        RipulElementText.bindLabel(label, assignment: assignment)
        var hostApplications = 0
        let remote = RipulRemoteThemeClient(url: base.appendingPathComponent("v1/app-themes/app"),
            fallback: original, cacheDirectory: folder.appendingPathComponent("cache"),
            validateAndApply: { data in
                try RipulThemeEngine.applyRemoteDocument(data) { _ in hostApplications += 1 }
            }, fetch: { _ in
                (self.original, HTTPURLResponse(url: self.base, statusCode: 200, httpVersion: nil,
                                               headerFields: ["ETag": "v1"])!)
            })
        try remote.start(); await remote.refresh()
        defer { remote.stop() }
        let lease = remote.beginEditing(), before = hostApplications
        let draftURL = folder.appendingPathComponent("draft.json")
        try ThemeManagementModel.saveTextMutation({ document in
            document.elements[assignment.element] = ["text": .text("Saved locally")]
        }, remote: remote, draftURL: draftURL)
        XCTAssertEqual(hostApplications, before + 1)
        XCTAssertEqual(label.text, "Saved locally")
        XCTAssertTrue(FileManager.default.fileExists(atPath: draftURL.path))
        remote.endEditing(lease)
        await remote.refresh()
        XCTAssertEqual(label.text, "Saved locally")
        XCTAssertEqual(remote.authoritativeDocument, original)
        XCTAssertEqual(remote.authoritativeETag, "v1")
    }

    func testHubSummaryReadsDraftWithoutApplyingAndTracksResetAndInvalidSource() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        var live = original
        var applications = 0
        let remote = RipulRemoteThemeClient(url: base.appendingPathComponent("v1/app-themes/app"),
            fallback: original, cacheDirectory: folder.appendingPathComponent("cache"),
            validateAndApply: { live = $0; applications += 1 }, fetch: { _ in throw URLError(.notConnectedToInternet) })
        let path = folder.appendingPathComponent("draft.json")
        func summary() -> RipulThemeDraftSummary {
            ThemeManagementModel.draftSummary(remote: remote, draftURL: path, capture: { $0 ?? live })
        }
        XCTAssertEqual(summary(), .changes(0))
        XCTAssertEqual(applications, 0, "Reading the hub must not apply or restore a theme")
        let editor = ThemeManagementModel(baseURL: base, tokenProvider: { nil }, remote: remote,
            draftURL: path, capture: { _ in live })
        editor.start()
        editor.sourceChanged(String(decoding: edited, as: UTF8.self)); editor.applySource(); editor.close(); remote.stop()
        let before = applications
        XCTAssertEqual(summary(), .changes(1))
        XCTAssertEqual(applications, before)
        editor.start(); editor.sourceChanged(String(decoding: original, as: UTF8.self)); editor.applySource(); editor.close(); remote.stop()
        XCTAssertEqual(summary(), .changes(0))
        editor.start(); editor.sourceChanged("{invalid"); editor.close(); remote.stop()
        XCTAssertEqual(summary(), .needsAttention)
        XCTAssertEqual(ThemeManagementModel.draftSummary(remote: nil, capture: { _ in self.original }), .unavailable)
    }

    func testSummaryDoesNotReplaceSavedTextWithUnrestoredLiveValues() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let remote = RipulRemoteThemeClient(url: base.appendingPathComponent("v1/app-themes/app"),
            fallback: original, cacheDirectory: folder, validateAndApply: { _ in },
            fetch: { _ in throw URLError(.notConnectedToInternet) })
        let path = folder.appendingPathComponent("draft.json")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(RipulThemeDraft(text: String(decoding: edited, as: UTF8.self),
            baseline: original, etag: "v1")).write(to: path)
        let summary = ThemeManagementModel.draftSummary(remote: remote, draftURL: path, capture: { _ in
            XCTFail("Saved drafts must be inspected independently of live state")
            return self.original
        })
        XCTAssertEqual(summary, .changes(1))
    }

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
