#if os(iOS)
import XCTest
import UIKit
@testable import RipulAgent

@MainActor
final class NativeTabTitleThemeTests: XCTestCase {
    private let id = "tabbar.legalHub"
    private func install() {
        RipulThemeInstrumentation.install()
        NativeTabTitleTheme.adopt(NativeTextTheme())
    }

    func testWACTitleBeforeIdentifierAndLaterAppUpdatesRequireNoItemRegistration() {
        install()
        defer { NativeTabTitleTheme.adopt(NativeTextTheme()) }
        NativeTabTitleTheme.adopt(NativeTextTheme(tabBarItemTitles: [id: "Help"]))
        // Exact WAC construction order. No per-item SDK API calls.
        let item = UITabBarItem(title: "Legal hub", image: nil, selectedImage: nil)
        XCTAssertEqual(item.title, "Legal hub")
        item.accessibilityIdentifier = id
        XCTAssertEqual(item.title, "Help")
        item.title = "Legal advice"
        XCTAssertEqual(item.title, "Help", "App refreshes must not erase the server override")
        NativeTabTitleTheme.adopt(NativeTextTheme())
        XCTAssertEqual(item.title, "Legal advice", "Removal restores the latest app-supplied value")
    }

    func testIdentifierBeforeTitleEmptyOverrideNilTitleAndRenaming() {
        install()
        defer { NativeTabTitleTheme.adopt(NativeTextTheme()) }
        let item = UITabBarItem()
        item.accessibilityIdentifier = id
        NativeTabTitleTheme.adopt(NativeTextTheme(tabBarItemTitles: [id: ""]))
        XCTAssertEqual(item.title, "", "Empty title is a valid override")
        item.title = nil
        XCTAssertEqual(item.title, "")
        item.accessibilityIdentifier = "different"
        XCTAssertNil(item.title, "Changing identity restores a nil original correctly")
        item.title = "Other"
        XCTAssertEqual(item.title, "Other")
        item.accessibilityIdentifier = id
        XCTAssertEqual(item.title, "")
        NativeTabTitleTheme.adopt(NativeTextTheme())
        XCTAssertEqual(item.title, "Other")
    }

    func testUnidentifiedTabsAndOtherBarItemsKeepNormalUIKitBehavior() {
        install()
        NativeTabTitleTheme.adopt(NativeTextTheme(tabBarItemTitles: [id: "Help"]))
        defer { NativeTabTitleTheme.adopt(NativeTextTheme()) }
        let tab = UITabBarItem(title: "Normal", image: nil, tag: 1)
        let bar = UIBarButtonItem(title: "Navigation", style: .plain, target: nil, action: nil)
        bar.accessibilityIdentifier = id
        tab.title = "Updated"; bar.title = "Back"
        XCTAssertEqual(tab.title, "Updated"); XCTAssertEqual(bar.title, "Back")
    }

    func testDetachedItemDoesNotBlockReplacementAndRebindsWhenAttachedAgain() {
        install()
        defer { NativeTabTitleTheme.adopt(NativeTextTheme()) }
        let item = UITabBarItem(title: "Legal hub", image: nil, tag: 0); item.accessibilityIdentifier = id
        let bar = UITabBar()
        bar.setItems([item], animated: false)
        NativeTabTitleTheme.setOverride("Help", identifier: id)
        XCTAssertEqual(item.title, "Help")
        bar.setItems([], animated: false)
        let replacement = UITabBarItem(title: "Replacement", image: nil, tag: 0); replacement.accessibilityIdentifier = id
        XCTAssertEqual(replacement.title, "Help", "Detached items must not make new ones ambiguous")
        replacement.accessibilityIdentifier = "replacement"
        NativeTabTitleTheme.setOverride("Advice", identifier: id)
        bar.setItems([item], animated: false)
        XCTAssertEqual(item.title, "Advice")
        NativeTabTitleTheme.setOverride(nil, identifier: id)
        XCTAssertEqual(item.title, "Legal hub")
    }

    func testDuplicateIdentifiersFailClosedAndRecreatedItemsBindAgain() {
        install()
        NativeTabTitleTheme.adopt(NativeTextTheme(tabBarItemTitles: [id: "Help"]))
        defer { NativeTabTitleTheme.adopt(NativeTextTheme()) }
        autoreleasepool {
            let first = UITabBarItem(title: "First", image: nil, tag: 0)
            first.accessibilityIdentifier = id
            let second = UITabBarItem(title: "Second", image: nil, tag: 1)
            second.accessibilityIdentifier = id
            XCTAssertEqual(first.title, "First"); XCTAssertEqual(second.title, "Second")
            XCTAssertTrue(NativeTabTitleTheme.elements.first { $0.id == id }?.ambiguous == true)
            second.accessibilityIdentifier = "unique.second"
            XCTAssertEqual(first.title, "Help"); XCTAssertEqual(second.title, "Second")
        }
        let recreated = UITabBarItem(title: "Legal hub", image: nil, tag: 0)
        recreated.accessibilityIdentifier = id
        XCTAssertEqual(recreated.title, "Help", "Registry must hold items weakly")
    }

    func testExplorerResolvesActualRenderedTabAndDoesNotUsePosition() async throws {
        install()
        defer { NativeTabTitleTheme.adopt(NativeTextTheme()) }
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
        } else { window = UIWindow(frame: CGRect(x: 0, y: 0, width: 440, height: 956)) }
        let controller = UITabBarController()
        let home = UIViewController(), legal = UIViewController()
        home.tabBarItem = UITabBarItem(title: "Home", image: nil, tag: 0)
        home.tabBarItem.accessibilityIdentifier = "tabbar.home"
        legal.tabBarItem = UITabBarItem(title: "Legal hub", image: nil, selectedImage: nil)
        legal.tabBarItem.accessibilityIdentifier = id
        controller.viewControllers = [home, legal]
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.beginAppearanceTransition(true, animated: false); controller.endAppearanceTransition()
        try await Task.sleep(nanoseconds: 100_000_000)
        controller.view.layoutIfNeeded(); controller.tabBar.layoutIfNeeded()
        func find(_ view: UIView) -> UIView? {
            if view.accessibilityIdentifier == id { return view }
            // The standalone XCTest runner does not activate UIKit's accessibility
            // forwarding onto its internal buttons. Supply the explorer's resolved
            // identifier, as in the user's selected-element context, for this fixture.
            if let label = view as? UILabel, label.text == "Legal hub" { return label }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        func describe(_ view: UIView) -> String {
            "\(type(of: view)) id=\(view.accessibilityIdentifier ?? "nil") frame=\(view.frame) [\(view.subviews.map(describe).joined(separator: ", "))]"
        }
        let rendered = try XCTUnwrap(find(controller.tabBar), describe(controller.tabBar))
        XCTAssertEqual(NativeTabTitleTheme.identifier(for: rendered, resolvedIdentifier: id), id)
        let selection = InspectedView.inspect(rendered, resolvedIdentifier: id)
        XCTAssertEqual(selection.text, "Legal hub")
        NativeTabTitleTheme.preview("Preview", identifier: try XCTUnwrap(selection.accessibilityId))
        XCTAssertEqual(legal.tabBarItem.title, "Preview")
        XCTAssertNil(NativeTabTitleTheme.current.tabBarItemTitles[id], "Trial text must not silently become a saved override")
        NativeTabTitleTheme.preview(nil, identifier: id)
        XCTAssertEqual(legal.tabBarItem.title, "Legal hub")
        NativeTabTitleTheme.setOverride("Help", identifier: id)
        controller.viewControllers = [legal, home]
        XCTAssertEqual(legal.tabBarItem.title, "Help"); XCTAssertEqual(home.tabBarItem.title, "Home")
        let impostor = UIButton(); impostor.accessibilityIdentifier = id
        XCTAssertNil(NativeTabTitleTheme.identifier(for: impostor))
    }

    func testFullDocumentAppliesOutsideHostVocabularyAndRejectsInvalidBeforeMutation() throws {
        install()
        defer { NativeTabTitleTheme.adopt(NativeTextTheme()); RipulThemeEngine.exportThemeDocument = nil }
        let item = UITabBarItem(title: "Legal hub", image: nil, tag: 0); item.accessibilityIdentifier = id
        let full = Data(#"{"hostExtra":{"keep":true},"nativeTextOverrides":{"tabBarItemTitles":{"tabbar.legalHub":"Help"}}}"#.utf8)
        var hostCalls = 0
        try RipulThemeEngine.applyRemoteDocument(full) { _ in hostCalls += 1; RipulThemeEngine.adopt(RipulThemeDocument()) }
        XCTAssertEqual(item.title, "Help")
        // A host exporter knows nothing about automatic text bindings.
        RipulThemeEngine.exportThemeDocument = { _ in Data(#"{"hostExtra":{"keep":true}}"#.utf8) }
        let captured = try RipulThemeEngine.themeDocumentForPublishing()
        XCTAssertEqual(try NativeTextTheme.decode(document: captured).tabBarItemTitles[id], "Help")
        XCTAssertNotNil((try JSONSerialization.jsonObject(with: captured) as? [String: Any])?["hostExtra"])
        XCTAssertThrowsError(try RipulThemeEngine.applyRemoteDocument(Data(#"{"nativeTextOverrides":{"tabBarItemTitles":{"tabbar.legalHub":42}}}"#.utf8)) { _ in hostCalls += 1 })
        XCTAssertEqual(hostCalls, 1); XCTAssertEqual(item.title, "Help")
        XCTAssertThrowsError(try RipulThemeEngine.applyRemoteDocument(Data("{}".utf8)) { _ in throw URLError(.cannotParseResponse) })
        XCTAssertEqual(item.title, "Help")
        try RipulThemeEngine.applyRemoteDocument(Data("{}".utf8)) { _ in }
        XCTAssertEqual(item.title, "Legal hub")
    }

    func testExplorerDraftSurvivesServerResetAndReopensForPublishing() async throws {
        install()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder); RipulThemeEngine.exportThemeDocument = nil; NativeTabTitleTheme.adopt(NativeTextTheme()) }
        let base = Data(#"{"hostExtra":{"keep":true}}"#.utf8)
        RipulThemeEngine.exportThemeDocument = { $0 ?? base }
        let remote = RipulRemoteThemeClient(url: URL(string: "https://example.com/v1/app-themes/app")!, fallback: base,
            cacheDirectory: folder.appendingPathComponent("cache"), validateAndApply: { data in
                try RipulThemeEngine.applyRemoteDocument(data) { _ in }
            }, fetch: { _ in throw URLError(.notConnectedToInternet) })
        try remote.start(); remote.stop()
        let item = UITabBarItem(title: "Legal hub", image: nil, tag: 0); item.accessibilityIdentifier = id
        let path = folder.appendingPathComponent("draft.json")
        try ThemeManagementModel.saveTabTitleDraft(identifier: id, title: "Help", remote: remote, draftURL: path)
        XCTAssertEqual(item.title, "Help")
        try remote.preview(base)
        XCTAssertEqual(item.title, "Legal hub")
        let model = ThemeManagementModel(baseURL: URL(string: "https://example.com")!, tokenProvider: { nil }, remote: remote,
            draftURL: path, capture: { try RipulThemeEngine.themeDocumentForPublishing(over: $0) })
        model.start()
        XCTAssertEqual(item.title, "Help"); XCTAssertTrue(model.canPublish)
        XCTAssertEqual(ThemeManagementModel.canonical(model.baseline), ThemeManagementModel.canonical(base))
        XCTAssertNotNil((try JSONSerialization.jsonObject(with: model.data) as? [String: Any])?["hostExtra"])
        model.close(); remote.stop()
        try ThemeManagementModel.saveTabTitleDraft(identifier: "tabbar.home", title: "Start", remote: remote, draftURL: path)
        model.start()
        XCTAssertEqual(try NativeTextTheme.decode(document: model.data).tabBarItemTitles, [id: "Help", "tabbar.home": "Start"])
        model.close(); remote.stop()
    }

    func testExplorerKeepsUnversionedDraftBaselineWhenServerVersionArrives() throws {
        install()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder); RipulThemeEngine.exportThemeDocument = nil; NativeTabTitleTheme.adopt(NativeTextTheme()) }
        let base = Data(#"{"host":"original"}"#.utf8)
        RipulThemeEngine.exportThemeDocument = { $0 ?? base }
        let remote = RipulRemoteThemeClient(url: URL(string: "https://example.com/v1/app-themes/app")!, fallback: base,
            cacheDirectory: folder.appendingPathComponent("cache"), validateAndApply: { _ in }, fetch: { _ in throw URLError(.notConnectedToInternet) })
        try remote.start(); remote.stop()
        let path = folder.appendingPathComponent("draft.json")
        try ThemeManagementModel.saveTabTitleDraft(identifier: id, title: "Help", remote: remote, draftURL: path)
        try remote.acceptPublication(RipulThemeManifest(data: Data(#"{"host":"another publisher's change"}"#.utf8), etag: "new-version"))
        try ThemeManagementModel.saveTabTitleDraft(identifier: id, title: "Advice", remote: remote, draftURL: path)
        let model = ThemeManagementModel(baseURL: URL(string: "https://example.com")!, tokenProvider: { nil }, remote: remote,
            draftURL: path, capture: { $0 ?? base })
        model.start()
        XCTAssertNil(model.etag, "Saving an older draft must not silently claim review of the new server version")
        XCTAssertEqual(model.baseline, base)
        model.close(); remote.stop()
    }
}
#endif
