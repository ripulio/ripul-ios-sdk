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

    func testLateWebReplyCannotReplaceNewNativeSelection() async throws {
        let (window, _, button, inspector, session) = try await fixture()
        defer { session.close(); window.isHidden = true }
        _ = inspector.probe(atWindowPoint: CGPoint(x: 90, y: 165), fire: false)
        inspector.selectNativeView(button)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(session.native?.accessibilityId, "native.title")
        XCTAssertNil(session.web)
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

    func testWebContextFreezesSelectedElementAndMasksEditableDescendants() async throws {
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
        do {
            _ = try await session.captureWeb(configuration: .init(available: [.instrumentedText]))
            XCTFail("Editable element must not be captured")
        } catch { XCTAssertTrue(error.localizedDescription.contains("excluded")) }
    }

    func testWebScreenshotMasksPrivateDescendants() async throws {
        let (window, web, _, inspector, session) = try await fixture()
        defer { session.close(); window.isHidden = true }
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
