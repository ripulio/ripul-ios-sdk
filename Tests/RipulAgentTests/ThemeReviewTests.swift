import XCTest
@testable import RipulAgent

final class ThemeDocumentReviewTests: XCTestCase {
    private func data(_ text: String) -> Data { Data(text.utf8) }
    private func label(_ id: String, _ text: String) -> [String: Any] {
        ["selector": ["screen": "StorefrontScreen", "identifier": id], "text": text]
    }
    private func document(_ labels: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["nativeTextOverrides": ["labels": labels, "tabBarItemTitles": ["tab.help": "Help"]], "hostExtra": "keep"])
    }
    func testLabelsReviewIndividuallyAcrossReorderInsertionAndRemoval() throws {
        let a = try document([label("one", "Old one"), label("two", "Keep two"), label("gone", "Gone")])
        let b = try document([label("two", "Keep two"), label("new", "New"), label("one", "New one")])
        let changes = ThemeDocumentChanges.compare(a, b)
        XCTAssertEqual(changes.count, 3)
        XCTAssertEqual(Set(changes.map(\.kind)), [.added, .modified, .removed])
        XCTAssertEqual(Set(changes.compactMap { $0.selector?.identifier }), ["one", "new", "gone"])
        XCTAssertEqual(Set(changes.map(\.id)).count, 3)
        var reverted = b
        for change in changes { reverted = try ThemeDocumentChanges.reverting(change, baseline: a, draft: reverted) }
        XCTAssertTrue(ThemeDocumentChanges.compare(a, reverted).isEmpty)
        let reordered = try document([label("two", "Keep two"), label("one", "Old one"), label("gone", "Gone")])
        XCTAssertTrue(ThemeDocumentChanges.compare(a, reordered).isEmpty)
    }
    func testNewNestedFieldsAreSeparateAndDiscardPreservesSiblingsAndNulls() throws {
        let a = data(#"{"host":{"keep":true},"null":null,"remove":{"old":3}}"#)
        let b = data(#"{"host":{"keep":true,"a/b~c":{"first":"","second":false}},"null":0}"#)
        let changes = ThemeDocumentChanges.compare(a, b)
        XCTAssertEqual(changes.count, 4)
        let first = try XCTUnwrap(changes.first { $0.keys.last == "first" })
        XCTAssertEqual(first.path, "/host/a~1b~0c/first"); XCTAssertEqual(first.kind, .added)
        var reverted = try ThemeDocumentChanges.reverting(first, baseline: a, draft: b)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: reverted) as? [String: Any])
        XCTAssertNotNil((object["host"] as? [String: Any])?["a/b~c"])
        for change in changes where change.id != first.id { reverted = try ThemeDocumentChanges.reverting(change, baseline: a, draft: reverted) }
        XCTAssertTrue(ThemeDocumentChanges.compare(a, reverted).isEmpty)
    }
    func testDiscardNewNativeRuleRemovesOnlyIntroducedContainers() throws {
        let a = data(#"{"host":{"keep":[1,true,null]}}"#)
        let b = try document([label("added", "Hello")])
        let change = try XCTUnwrap(ThemeDocumentChanges.compare(a, b).first { $0.selector != nil })
        let reverted = try ThemeDocumentChanges.reverting(change, baseline: a, draft: b)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: reverted) as? [String: Any])
        let native = try XCTUnwrap(object["nativeTextOverrides"] as? [String: Any])
        XCTAssertNil(native["labels"]); XCTAssertNotNil(native["tabBarItemTitles"])
    }
    func testUnknownCollectionFieldsAreVisibleAndArraysStayAtomic() throws {
        var rule = label("one", "Hello"); rule["futureFeature"] = ["enabled": true]
        let a = try document([label("one", "Hello")]), b = try document([rule])
        let changes = ThemeDocumentChanges.compare(a, b)
        XCTAssertEqual(changes.count, 1); XCTAssertNil(changes[0].selector)
        XCTAssertEqual(changes[0].new?.display, "1 item")
        XCTAssertNotNil(changes[0].new?.children?.first?.1.children?.first { $0.0 == "futureFeature" })
        let list = ThemeDocumentChanges.compare(data(#"{"values":[1,true]}"#), data(#"{"values":[false,2,3]}"#))
        XCTAssertEqual(list.count, 1); XCTAssertEqual(list[0].keys, ["values"])
    }
    func testStaleDiscardCannotEraseANewerEdit() throws {
        let a = data(#"{"title":"Old"}"#), b = data(#"{"title":"Draft"}"#)
        let change = try XCTUnwrap(ThemeDocumentChanges.compare(a, b).first)
        XCTAssertThrowsError(try ThemeDocumentChanges.reverting(change, baseline: a, draft: data(#"{"title":"Newer"}"#)))
    }
    func testValueTypesRemainDistinctAndNoStructuredValueIsShownAsJSON() throws {
        let changes = ThemeDocumentChanges.compare(data(#"{"value":false}"#), data(#"{"value":0}"#))
        XCTAssertEqual(changes.first?.old?.display, "False"); XCTAssertEqual(changes.first?.new?.display, "0")
        XCTAssertEqual(ThemeDocumentChanges.Value(raw: NSNull()).display, "No value (null)")
        XCTAssertEqual(ThemeDocumentChanges.Value(raw: "").display, "Empty text")
        XCTAssertEqual(ThemeDocumentChanges.Value(raw: [String: String]()).display, "Empty group")
    }
}

#if os(iOS)
import SwiftUI
import UIKit

@MainActor
final class ThemeReviewTests: XCTestCase {
    private let base = URL(string: "https://example.com")!
    private func fixture() throws -> (ThemeManagementModel, RipulRemoteThemeClient, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        RipulThemeEngine.configure(RipulThemeSpec(bundleResource: "MissingReviewFixture", overrideDefaultsKey: "ReviewFixture", vocabulary: .init(primitives: [.init(name: "brand", label: "Brand colour", path: ["Brand"], defaultReference: "#000000")], roles: [], components: []), styleKinds: []))
        let original = Data(##"{"nativeTextOverrides":{"tabBarItemTitles":{"tabs.help":"Help centre","tabs.home":"Home"}},"colors":{"brand":"#7147E8"},"hostSettings":{"showWelcome":true}}"##.utf8)
        let draft = Data(##"{"nativeTextOverrides":{"tabBarItemTitles":{"tabs.help":"Advice centre","tabs.home":"Home"},"labels":[{"selector":{"screen":"StorefrontScreen","identifier":"welcome.message"},"text":"Give a friend a free trial"}]},"colors":{"brand":"#2A8B70"},"hostSettings":{"showWelcome":false}}"##.utf8)
        var live = original
        let remote = RipulRemoteThemeClient(url: base.appendingPathComponent("v1/app-themes/storefront"), fallback: original, cacheDirectory: folder.appendingPathComponent("cache"), validateAndApply: { live = $0 }, fetch: { _ in throw URLError(.notConnectedToInternet) })
        try remote.start(); remote.stop()
        let model = ThemeManagementModel(baseURL: base, tokenProvider: { "fixture" }, remote: remote, draftURL: folder.appendingPathComponent("draft.json"), capture: { _ in live })
        model.start(); model.sourceChanged(String(decoding: draft, as: UTF8.self)); model.applySource()
        return (model, remote, folder)
    }
    func testDiscardAndUndoUpdatePreviewAndPersistWholeDraft() throws {
        let (model, remote, folder) = try fixture()
        defer { model.close(); remote.stop(); try? FileManager.default.removeItem(at: folder) }
        let originalDraft = model.data
        let change = try XCTUnwrap(ThemeDocumentChanges.compare(model.baseline, model.data).first { $0.selector != nil })
        XCTAssertTrue(model.discard(change, title: "Welcome message"))
        XCTAssertFalse(ThemeDocumentChanges.compare(model.baseline, model.data).contains { $0.id == change.id })
        XCTAssertTrue(model.canUndoDiscard)
        model.undoDiscard()
        XCTAssertEqual(ThemeManagementModel.canonical(model.data), ThemeManagementModel.canonical(originalDraft))
        XCTAssertFalse(model.canUndoDiscard)
        XCTAssertTrue(model.discard(change, title: "Welcome message"))
        model.close(); model.start()
        XCTAssertFalse(ThemeDocumentChanges.compare(model.baseline, model.data).contains { $0.id == change.id })
        XCTAssertEqual(ThemeDocumentChanges.compare(model.baseline, model.data).count, 3)
    }
    func testUnreviewedEditsCannotBePublishedAndStaleUndoCannotOverwriteThem() async throws {
        let (model, remote, folder) = try fixture()
        defer { model.close(); remote.stop(); try? FileManager.default.removeItem(at: folder) }
        let reviewed = model.data
        let change = try XCTUnwrap(ThemeDocumentChanges.compare(model.baseline, model.data).first)
        XCTAssertTrue(model.discard(change, title: "Colour"))
        await model.publish(reviewed: reviewed)
        XCTAssertNotNil(model.error); XCTAssertFalse(model.published)
        let next = model.text.replacingOccurrences(of: "Advice centre", with: "Support centre")
        model.sourceChanged(next); model.applySource()
        let edited = model.data
        XCTAssertFalse(model.canUndoDiscard); model.undoDiscard()
        XCTAssertEqual(model.data, edited)
    }
    func testReviewUsesRegisteredLabelsAndEachDocumentsColour() throws {
        let kind = RipulStyleKind(name: "cards", scopes: [.init(id: "welcome", label: "Welcome card", path: ["Start"])], knobs: [.init("heading", "Heading", .text(fallback: ""))], defaultTier: { _, _ in [:] }, persistedKeys: .init(styles: "cardStyles", assignments: "cardNames", overrides: "cardOverrides"))
        let spec = RipulThemeSpec(bundleResource: "Missing", overrideDefaultsKey: "ReviewFixture", vocabulary: .init(primitives: [.init(name: "brand", label: "Brand colour", path: ["Brand"], defaultReference: "#000000")], roles: [], components: []), styleKinds: [kind])
        let before = Data(##"{"cardOverrides":{"welcome":{"heading":"Welcome back"}},"colors":{"brand":"#112233"}}"##.utf8)
        let after = Data(##"{"cardOverrides":{"welcome":{"heading":"Welcome home"}},"colors":{"brand":"#445566"}}"##.utf8)
        let entries = ThemeDocumentChanges.compare(before, after).map { ThemeChangePresentation($0, spec: spec) }
        let text = try XCTUnwrap(entries.first { $0.category == .text })
        XCTAssertEqual(text.title, "Welcome card"); XCTAssertEqual(text.property, "Heading")
        let color = try XCTUnwrap(entries.first { $0.category == .colors })
        XCTAssertEqual(color.title, "Brand colour")
        XCTAssertNotEqual(color.swatch(.init(raw: "brand"), document: before, spec: spec), color.swatch(.init(raw: "brand"), document: after, spec: spec))
        let highlighted = ThemeTextDifference.emphasized("Welcome home", comparedTo: "Welcome back", removal: false)
        XCTAssertEqual(String(highlighted.characters), "Welcome home")
        XCTAssertTrue(highlighted.runs.contains { $0.backgroundColor != nil })
    }
    func testHostValidationFailureKeepsDraftAndPreviewIntact() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let original = Data(#"{"first":0,"second":0}"#.utf8)
        let draft = Data(#"{"first":1,"second":1}"#.utf8)
        var live = original
        let remote = RipulRemoteThemeClient(url: base.appendingPathComponent("v1/app-themes/pair"), fallback: original, cacheDirectory: folder,
            validateAndApply: { bytes in
                let values = try JSONDecoder().decode([String: Int].self, from: bytes)
                guard values["first"] == values["second"] else { throw RipulThemePublishError.invalidDocument }
                live = bytes
            }, fetch: { _ in throw URLError(.notConnectedToInternet) })
        try remote.start(); remote.stop()
        let model = ThemeManagementModel(baseURL: base, tokenProvider: { nil }, remote: remote, draftURL: folder.appendingPathComponent("draft"), capture: { _ in live })
        defer { model.close(); remote.stop(); try? FileManager.default.removeItem(at: folder) }
        model.start(); model.sourceChanged(String(decoding: draft, as: UTF8.self)); model.applySource()
        let change = try XCTUnwrap(ThemeDocumentChanges.compare(model.baseline, model.data).first)
        XCTAssertFalse(model.discard(change, title: "Paired value"))
        XCTAssertEqual(model.data, draft); XCTAssertEqual(live, draft)
        XCTAssertFalse(model.sourceDirty); XCTAssertTrue(model.canPublish); XCTAssertNotNil(model.error)
    }
    func testPublicationKeepsConfirmedBytesDuringServerVersionCheck() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let original = Data(#"{"title":"Original"}"#.utf8), draft = Data(#"{"title":"Confirmed"}"#.utf8)
        var live = original
        let remote = RipulRemoteThemeClient(url: base.appendingPathComponent("v1/app-themes/review"), fallback: original, cacheDirectory: folder, validateAndApply: { live = $0 }, fetch: { _ in throw URLError(.notConnectedToInternet) })
        try remote.start(); remote.stop()
        var model: ThemeManagementModel!
        var sent: Data?
        let publisher = RipulThemePublisher(baseURL: base, tokenProvider: { "fixture" }, fetch: { request in
            if request.httpMethod == "GET" {
                model.sourceChanged(#"{"title":"Later edit"}"#)
                return (original, HTTPURLResponse(url: self.base, statusCode: 200, httpVersion: nil, headerFields: ["ETag": "old"])!)
            }
            sent = request.httpBody
            return (Data(#"{"etag":"published"}"#.utf8), HTTPURLResponse(url: self.base, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        model = ThemeManagementModel(baseURL: base, tokenProvider: { "fixture" }, remote: remote, publisher: publisher, draftURL: folder.appendingPathComponent("draft"), capture: { _ in live })
        defer { model.close(); remote.stop(); try? FileManager.default.removeItem(at: folder) }
        model.start(); model.sourceChanged(String(decoding: draft, as: UTF8.self)); model.applySource()
        await model.publish(reviewed: draft)
        XCTAssertEqual(sent, draft); XCTAssertTrue(model.published)
        XCTAssertEqual(ThemeManagementModel.canonical(live), ThemeManagementModel.canonical(draft))
    }
    func testReviewRendersOnPhoneInLightDarkAndAccessibilitySizes() async throws {
        let (model, remote, folder) = try fixture()
        defer { model.close(); remote.stop(); try? FileManager.default.removeItem(at: folder) }
        for (name, dark, size) in [("light", false, DynamicTypeSize.large), ("dark", true, .large), ("large-type", false, .accessibility3)] {
            let controller = UIHostingController(rootView: ThemePublishReviewScreen(model: model).environment(\.colorScheme, dark ? .dark : .light).environment(\.dynamicTypeSize, size))
            let window: UIWindow
            if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first { window = UIWindow(windowScene: scene) }
            else { window = UIWindow(frame: .zero) }
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            window.overrideUserInterfaceStyle = dark ? .dark : .light
            window.rootViewController = controller; window.makeKeyAndVisible()
            controller.beginAppearanceTransition(true, animated: false)
            controller.view.frame = window.bounds; controller.view.layoutIfNeeded()
            controller.endAppearanceTransition()
            try await Task.sleep(nanoseconds: 200_000_000)
            controller.view.layoutIfNeeded()
            // The package test runner has no foreground scene for drawHierarchy.
            let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { context in controller.view.layer.render(in: context.cgContext) }
            let pixels = try XCTUnwrap(image.cgImage?.dataProvider?.data) as Data
            XCTAssertGreaterThan(Set(pixels).count, 8, "A blank image is not a layout check")
            let attachment = XCTAttachment(image: image); attachment.name = "theme-review-" + name; attachment.lifetime = .keepAlways; add(attachment)
            XCTAssertEqual(image.size.width, 390)
            window.isHidden = true
        }
    }
}
#endif
