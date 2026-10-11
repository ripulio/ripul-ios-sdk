import WebKit
import XCTest
@testable import RipulAgent

/// The handoff of the adopted theme document from the native shell to the page
/// (`AgentBridge.syncThemeDocument`): what is sent, when, and what is not.
@MainActor
final class ThemeDocumentHandoffTests: XCTestCase {
    private static let loud = Data(##"{"schema":1,"name":"Loud","roles":{"ripul.accent":"#FF00FF"},"typography":{"families":{"text":"Georgia"}}}"##.utf8)
    private static let plain = Data(#"{"schema":1,"name":"Ripul","palette":{},"roles":{}}"#.utf8)

    override func tearDown() async throws {
        RipulTheme.resetToDefaults()
    }

    // MARK: - The script

    func testTheScriptCarriesTheDocumentAndAnnouncesIt() {
        let script = AgentBridge.themeDocumentScript(Self.loud)
        XCTAssertTrue(script.hasPrefix("window.__ripulNativeThemeDocument = {"))
        XCTAssertTrue(script.contains(##""ripul.accent":"#FF00FF""##))
        XCTAssertTrue(script.hasSuffix("window.dispatchEvent(new Event('ripul:native-theme-document'));"))
    }

    func testNoDocumentAndAnythingThatIsNotOneAreSentAsNull() {
        let none = "window.__ripulNativeThemeDocument = null; window.dispatchEvent(new Event('ripul:native-theme-document'));"
        XCTAssertEqual(AgentBridge.themeDocumentScript(nil), none)
        XCTAssertEqual(AgentBridge.themeDocumentScript(Data("[1,2]".utf8)), none)
        XCTAssertEqual(AgentBridge.themeDocumentScript(Data("alert(1)".utf8)), none)
    }

    func testTextThatWouldEndAScriptStringIsEscaped() {
        let script = AgentBridge.themeDocumentScript(Data("{\"name\":\"a\u{2028}b\u{2029}c\"}".utf8))
        XCTAssertFalse(script.contains("\u{2028}"))
        XCTAssertFalse(script.contains("\u{2029}"))
        XCTAssertTrue(script.contains(#"a\u2028b\u2029c"#), script)
    }

    // MARK: - The page

    #if os(macOS)
    private final class Loader: NSObject, WKNavigationDelegate {
        var finished: (() -> Void)?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished?() }
    }

    /// A page that records the document it started with and counts announcements.
    private static let page = """
    <script>
    window.__atStart = JSON.stringify(window.__ripulNativeThemeDocument === undefined ? 'absent' : window.__ripulNativeThemeDocument);
    window.__announced = 0;
    window.addEventListener('ripul:native-theme-document', () => { window.__announced += 1; });
    </script>
    """

    private func load(_ view: WKWebView) async {
        let loader = Loader()
        view.navigationDelegate = loader
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            loader.finished = { loader.finished = nil; done.resume() }
            view.loadHTMLString(Self.page, baseURL: URL(string: "https://theme.test/"))
        }
    }

    private func read(_ view: WKWebView, _ expression: String) async -> String {
        ((try? await view.evaluateJavaScript("String(\(expression))")) as? String) ?? "failed"
    }

    private func name(_ view: WKWebView) async -> String {
        await read(view, "window.__ripulNativeThemeDocument === undefined ? 'absent' : window.__ripulNativeThemeDocument === null ? 'null' : window.__ripulNativeThemeDocument.name")
    }

    /// Lets the notification reach the bridge and the script reach the page.
    private func settle() async { try? await Task.sleep(nanoseconds: 300_000_000) }

    func testAHostThatAdoptedNothingSendsNothing() async {
        let view = WKWebView()
        let bridge = AgentBridge()
        bridge.attach(to: view)
        await load(view)
        let atStart = await read(view, "window.__atStart")
        XCTAssertEqual(atStart, #""absent""#)
        XCTAssertTrue(view.configuration.userContentController.userScripts.allSatisfy { !$0.source.contains("__ripulNativeThemeDocument") })
    }

    func testTheDocumentIsInThePageBeforeItsOwnScriptsAndFollowsEachChange() async throws {
        try RipulTheme.adopt(documentData: Self.loud)
        let view = WKWebView()
        let bridge = AgentBridge()
        bridge.attach(to: view)
        await load(view)
        // There before the page's first script ran.
        let atStart = await read(view, "JSON.parse(window.__atStart).name")
        XCTAssertEqual(atStart, "Loud")

        // A change reaches the open page, announced once, with no reload.
        try RipulTheme.adopt(documentData: Self.plain)
        await settle()
        var current = await name(view)
        XCTAssertEqual(current, "Ripul")
        var announced = await read(view, "window.__announced")
        XCTAssertEqual(announced, "1")
        let stillTheFirstLoad = await read(view, "JSON.parse(window.__atStart).name")
        XCTAssertEqual(stillTheFirstLoad, "Loud")

        // The same document again is not sent again.
        try RipulTheme.adopt(documentData: Self.plain)
        NotificationCenter.default.post(name: .ripulThemeDidChange, object: nil)
        await settle()
        announced = await read(view, "window.__announced")
        XCTAssertEqual(announced, "1")

        // A page that loads later starts with the newest document, not the first.
        await load(view)
        let afterReload = await read(view, "JSON.parse(window.__atStart).name")
        XCTAssertEqual(afterReload, "Ripul")

        // Back to the defaults: the page is told there is no document.
        RipulTheme.resetToDefaults()
        await settle()
        current = await name(view)
        XCTAssertEqual(current, "null")
        await load(view)
        let afterReset = await read(view, "window.__atStart")
        XCTAssertEqual(afterReset, "null")
    }
    #endif
}
