#if os(iOS)
import XCTest
import UIKit
import WebKit
@testable import RipulAgent

@MainActor
final class UnifiedInspectorTests: XCTestCase {
    private final class Loader: NSObject, WKNavigationDelegate {
        var completion: (() -> Void)?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { completion?() }
    }

    private func fixture() async throws -> (UIWindow, WKWebView, UIButton, ViewInspectorController, InspectorSession) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = UIViewController(); window.rootViewController = root; window.isHidden = false
        root.view.frame = window.bounds
        let button = UIButton(frame: CGRect(x: 10, y: 35, width: 300, height: 44))
        button.setTitle("Native title", for: .normal); button.accessibilityIdentifier = "native.title"
        root.view.addSubview(button)
        let web = WKWebView(frame: CGRect(x: 20, y: 120, width: 350, height: 620))
        root.view.addSubview(web)
        let loader = Loader(); let loaded = expectation(description: "Web document loaded")
        loader.completion = { loaded.fulfill() }; web.navigationDelegate = loader
        web.loadHTMLString("""
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>body{margin:0}#card{padding:20px;height:240px}button{width:200px;height:50px}</style>
        <section id="card"><button data-ui="chat.message" onclick="window.presses=(window.presses||0)+1">Hello inspector</button>
        <div id="private"><input value="hidden value"><span>Should be omitted</span></div></section>
        """, baseURL: URL(string: "https://example.test"))
        await fulfillment(of: [loaded], timeout: 15)
        let inspector = ViewInspectorController(frame: window.bounds)
        let session = InspectorSession(); inspector.session = session; session.controller = inspector
        root.view.addSubview(inspector)
        return (window, web, button, inspector, session)
    }

    private func waitForWeb(_ session: InspectorSession) async throws {
        for _ in 0..<100 {
            if session.web != nil { return }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTFail("No DOM selection: \(session.error ?? "no error")")
    }

    func testCursorCrossesNativeAndWebWithOneHistoryAndNoActivation() async throws {
        let (window, web, _, inspector, session) = try await fixture()
        defer { session.close(); window.isHidden = true }
        _ = inspector.probe(atWindowPoint: CGPoint(x: 50, y: 55), fire: false)
        XCTAssertEqual(session.native?.accessibilityId, "native.title")
        // The web view starts at (20,120); button starts at CSS (20,20).
        _ = inspector.probe(atWindowPoint: CGPoint(x: 90, y: 165), fire: false)
        try await waitForWeb(session)
        XCTAssertEqual(session.web?.identifier, "chat.message")
        XCTAssertNil(session.native)
        XCTAssertEqual(session.historyCount, 1)
        let presses = try await web.evaluateJavaScript("window.presses") as? Int
        XCTAssertNil(presses)
        session.back()
        XCTAssertEqual(session.native?.accessibilityId, "native.title")
        XCTAssertNil(session.web)
    }

    func testShiftClickCollectsPinnedOriginTogglesAndCopiesAll() async throws {
        let (window, _, _, inspector, session) = try await fixture()
        defer { session.close(); window.isHidden = true }
        session.pointerActive = true
        _ = inspector.probe(atWindowPoint: CGPoint(x: 50, y: 55), fire: false)
        session.lockWhenPickSettles()
        XCTAssertTrue(session.pinned)
        // Pinned: hover cannot replace the element...
        _ = inspector.probe(atWindowPoint: CGPoint(x: 90, y: 165), fire: false)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(session.native?.accessibilityId, "native.title")
        XCTAssertNil(session.web)
        // ...until shift is held, when hover previews through the pin.
        session.setExtending(true)
        _ = inspector.probe(atWindowPoint: CGPoint(x: 90, y: 165), fire: false)
        try await waitForWeb(session)
        XCTAssertEqual(session.web?.identifier, "chat.message")
        XCTAssertTrue(session.collected.isEmpty)
        // The shift-click collects the clicked element AND the pinned origin.
        session.lockWhenPickSettles(collecting: true)
        XCTAssertEqual(session.collected.map(\.identity), ["native.title", "chat.message"])
        XCTAssertEqual(session.collected.map(\.kind), ["Native", "Web"])
        XCTAssertTrue(session.pinned)
        XCTAssertEqual(inspector.selectionSnapshot()["collected"] as? [String], ["native.title", "chat.message"])
        // What Copy all writes. The simulator's shared pasteboard stalls for
        // minutes on access, so the text is checked here, not the clipboard.
        XCTAssertEqual(session.collectedIdentities, "native.title\nchat.message")
        // A second shift-click on the same element takes it out again.
        session.lockWhenPickSettles(collecting: true)
        XCTAssertEqual(session.collected.map(\.identity), ["native.title"])
        // Releasing shift after a click keeps the clicked element current.
        session.setExtending(false)
        XCTAssertEqual(session.web?.identifier, "chat.message")
        session.clearCollected()
        XCTAssertTrue(session.collected.isEmpty)
        XCTAssertEqual(inspector.selectionSnapshot()["collected"] as? [String], [])
    }

    func testShiftClickEntryCollectsThroughAppearanceTouchPath() async throws {
        let (window, _, _, inspector, session) = try await fixture()
        defer { session.close(); window.isHidden = true }
        session.pointerActive = true
        _ = inspector.probe(atWindowPoint: CGPoint(x: 50, y: 55), fire: false)
        session.lockWhenPickSettles()
        XCTAssertTrue(session.pinned)
        // Appearance is the default tab and selects on release at the click
        // location, not the reticle. The touch layer hands that location here.
        inspector.selectsAppearance = true
        inspector.collectPointerSelection(at: CGPoint(x: 90, y: 165))
        try await waitForWeb(session)
        for _ in 0..<100 {
            if session.collected.count == 2 { break }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertEqual(session.collected.map(\.identity), ["native.title", "chat.message"])
        XCTAssertTrue(session.pinned)
        XCTAssertTrue(session.extending)
        session.setExtending(false)
        XCTAssertEqual(session.web?.identifier, "chat.message")
        XCTAssertEqual(session.collected.count, 2)
        // The pin still holds against a plain hover afterwards.
        _ = inspector.probe(atWindowPoint: CGPoint(x: 50, y: 55), fire: false)
        XCTAssertEqual(session.web?.identifier, "chat.message")
        XCTAssertNil(session.native)
    }

    func testReticuleDoubleTapCollectsHighlightedElementOnTouch() async throws {
        let (window, _, _, inspector, session) = try await fixture()
        defer { session.close(); window.isHidden = true }
        _ = inspector.probe(atWindowPoint: CGPoint(x: 50, y: 55), fire: false)
        XCTAssertTrue(inspector.reticuleContains(CGPoint(x: 60, y: 70)))
        XCTAssertFalse(inspector.reticuleContains(CGPoint(x: 120, y: 55)))
        inspector.collectFromReticule()
        XCTAssertEqual(session.collected.map(\.identity), ["native.title"])
        XCTAssertFalse(session.pinned)
        XCTAssertEqual(session.native?.accessibilityId, "native.title")
        _ = inspector.probe(atWindowPoint: CGPoint(x: 90, y: 165), fire: false)
        try await waitForWeb(session)
        inspector.collectFromReticule()
        XCTAssertEqual(session.collected.map(\.identity), ["native.title", "chat.message"])
        // A second double-tap on the same element takes it out again.
        inspector.collectFromReticule()
        XCTAssertEqual(session.collected.map(\.identity), ["native.title"])
        // Nothing highlighted: nothing collected.
        session.invalidate()
        inspector.collectFromReticule()
        XCTAssertEqual(session.collected.map(\.identity), ["native.title"])
    }

    func testShiftRunWithoutClickRestoresPinnedSelection() async throws {
        let (window, _, _, inspector, session) = try await fixture()
        defer { session.close(); window.isHidden = true }
        session.pointerActive = true
        _ = inspector.probe(atWindowPoint: CGPoint(x: 50, y: 55), fire: false)
        session.lockWhenPickSettles()
        session.setExtending(true)
        _ = inspector.probe(atWindowPoint: CGPoint(x: 90, y: 165), fire: false)
        try await waitForWeb(session)
        XCTAssertNil(session.native)
        session.setExtending(false)
        XCTAssertEqual(session.native?.accessibilityId, "native.title")
        XCTAssertNil(session.web)
        XCTAssertTrue(session.pinned)
        XCTAssertTrue(session.collected.isEmpty)
    }

    func testLateWebReplyCannotReplaceNewNativeSelection() async throws {
        let (window, _, button, inspector, session) = try await fixture()
        defer { session.close(); window.isHidden = true }
        _ = inspector.probe(atWindowPoint: CGPoint(x: 90, y: 165), fire: false)
        inspector.selectNativeView(button)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(session.native?.accessibilityId, "native.title")
        XCTAssertNil(session.web)
    }

    @available(iOS 26.0, *)
    func testAgentWebSelectionCannotRefreshRestoreOrActivateInAnyState() async throws {
        let (window, web, _, inspector, session) = try await fixture()
        let agent = RipulDevOverlayWindow(frame: window.frame)
        let root = UIViewController()
        agent.installRoot(root)
        agent.isHidden = false
        agent.isPassthrough = false
        defer { session.close(); agent.isHidden = true; window.isHidden = true }

        session.pickWeb(web, at: CGPoint(x: 70, y: 45))
        try await waitForWeb(session)
        let id = try XCTUnwrap(session.web?.id)
        root.view.addSubview(web)
        for expanded in [true, false] {
            agent.isExpanded = expanded
            XCTAssertEqual(inspector.selectionSnapshot()["hasSelection"] as? Bool, false)
            let activation = await session.activateWeb()
            XCTAssertEqual(activation["success"] as? Bool, false)
            session.selectWeb(id: id, in: web)
            await session.waitForPick()
            XCTAssertFalse(session.hasSelection)
            session.pickWeb(web, at: CGPoint(x: 70, y: 45))
            await session.waitForPick()
            XCTAssertFalse(session.hasSelection)
        }
        let presses = try await web.evaluateJavaScript("window.presses") as? Int
        XCTAssertNil(presses)

        // A host DOM reply arriving after the web view moves into the expanded
        // assistant cannot become a selection either.
        window.rootViewController?.view.addSubview(web)
        session.pickWeb(web, at: CGPoint(x: 70, y: 45))
        root.view.addSubview(web)
        agent.isExpanded = true
        await session.waitForPick()
        XCTAssertFalse(session.hasSelection)
    }

    func testNativeLogicalPartAndPointSurviveWebHistoryAndRefresh() async throws {
        let (window, _, button, inspector, session) = try await fixture()
        defer { session.close(); window.isHidden = true }
        let part = UIView(frame: CGRect(x: 8, y: 5, width: 40, height: 20))
        button.addSubview(part)
        button.accessibilityIdentifier = nil // Model a hosting view named by a logical sub-element stamp.
        let selected = InspectorNativeSelection(info: InspectedView.inspect(button, resolvedIdentifier: "logical.button.icon"),
            highlight: part, localPoint: CGPoint(x: 7, y: 6))
        inspector.restoreNativeSelection(selected, remembering: true)
        _ = inspector.probe(atWindowPoint: CGPoint(x: 90, y: 165), fire: false)
        try await waitForWeb(session)
        session.back()
        XCTAssertEqual(session.native?.accessibilityId, "logical.button.icon")
        part.frame.origin.x += 10
        session.refresh()
        XCTAssertEqual(session.native?.accessibilityId, "logical.button.icon")
        XCTAssertEqual(inspector.composerSelection()?.frame, part.convert(part.bounds, to: window))
        session.pinned = true
        _ = inspector.probe(atWindowPoint: CGPoint(x: 300, y: 600), fire: false)
        XCTAssertEqual(inspector.selectedPointInHost, part.convert(CGPoint(x: 7, y: 6), to: window))
    }

    func testPinnedWebSelectionSurvivesMovementAndTreeUsesSameSelection() async throws {
        let (window, _, _, inspector, session) = try await fixture()
        defer { session.close(); window.isHidden = true }
        _ = inspector.probe(atWindowPoint: CGPoint(x: 90, y: 165), fire: false)
        try await waitForWeb(session)
        session.pinned = true
        _ = inspector.probe(atWindowPoint: CGPoint(x: 50, y: 55), fire: false)
        XCTAssertEqual(session.web?.identifier, "chat.message")
        session.up()
        for _ in 0..<50 {
            if session.web?.identifier == "card" { break }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertEqual(session.web?.identifier, "card")
        XCTAssertEqual(session.web?.text, "") // Private descendant suppresses aggregate text.
    }

    func testRemovedNodeIsNeverRetargetedAndEditsApplyToSelectedNode() async throws {
        let (window, web, _, inspector, session) = try await fixture()
        defer { session.close(); window.isHidden = true }
        _ = inspector.probe(atWindowPoint: CGPoint(x: 90, y: 165), fire: false)
        try await waitForWeb(session)
        await session.editStyle("padding-left", value: "31px")
        XCTAssertEqual(session.web?.styles["padding-left"], "31px")
        XCTAssertEqual(session.web?.box.padding.left, 31)
        let identifier = await session.evaluate("$0.getAttribute('data-ui')")
        XCTAssertEqual(identifier, "\"chat.message\"")
        _ = try await web.evaluateJavaScript("document.querySelector('button').outerHTML = '<button data-ui=\"chat.message\">Replacement</button>'")
        let result = await session.evaluate("$0.textContent")
        XCTAssertTrue(result.contains("removed"))
        session.refresh()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(session.web)
        XCTAssertNotNil(session.error)
    }

    func testWebContextFreezesSelectedElementAndAllowsEditableFields() async throws {
        let (window, web, _, inspector, session) = try await fixture()
        defer { session.close(); window.isHidden = true }
        _ = inspector.probe(atWindowPoint: CGPoint(x: 90, y: 165), fire: false)
        try await waitForWeb(session)
        let snapshot = try await session.captureWeb(configuration: .init(available: [.instrumentedText]))
        XCTAssertTrue(snapshot.selectedText.contains("Hello inspector"))
        _ = try await web.evaluateJavaScript("document.querySelector('button').textContent = 'Changed'")
        XCTAssertFalse(snapshot.selectedText.contains("Changed"))
        let fresh = try await session.captureWeb(configuration: .init(available: [.instrumentedText]))
        XCTAssertTrue(fresh.selectedText.contains("Changed"))
        let privateID = try await web.evaluateJavaScript("window.__ripulInspector.pick(30,85).id") as! String
        session.selectWeb(id: privateID)
        try await Task.sleep(nanoseconds: 200_000_000)
        let field = try await session.captureWeb(configuration: .init(available: [.instrumentedText]))
        XCTAssertTrue(field.canAttach)
        XCTAssertFalse(try XCTUnwrap(session.web).private)
        XCTAssertTrue(try XCTUnwrap(session.web).privateRects.isEmpty)
    }

    func testWebScreenshotMasksExplicitlyExcludedDescendants() async throws {
        let (window, web, _, inspector, session) = try await fixture()
        defer { session.close(); window.isHidden = true }
        _ = try await web.evaluateJavaScript("document.querySelector('input').setAttribute('data-ripul-context-excluded', '')")
        _ = inspector.probe(atWindowPoint: CGPoint(x: 90, y: 165), fire: false)
        try await waitForWeb(session)
        session.up()
        for _ in 0..<50 {
            if session.web?.identifier == "card" { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let snapshot = try await session.captureWeb(configuration: .init(available: [.instrumentedText, .screenshot]))
        XCTAssertFalse(snapshot.selectedText.contains("hidden value"))
        let image = try XCTUnwrap(UIImage(data: try XCTUnwrap(snapshot.screenshotJPEG))?.cgImage)
        let input = try XCTUnwrap(session.web?.privateRects.first)
        let selected = try XCTUnwrap(session.web?.rect)
        var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(data: &rgba, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let x = Int((input.x + input.width / 2 - selected.x) / selected.width * Double(image.width))
        let y = Int((input.y + input.height / 2 - selected.y) / selected.height * Double(image.height))
        let pixel = (y * image.width + x) * 4
        XCTAssertLessThan(rgba[pixel], 15)
        XCTAssertLessThan(rgba[pixel + 1], 15)
        XCTAssertLessThan(rgba[pixel + 2], 15)
        let outline = try await web.evaluateJavaScript("document.getElementById('card').style.outline") as? String
        XCTAssertFalse(outline?.isEmpty ?? true)
    }
}
#endif
