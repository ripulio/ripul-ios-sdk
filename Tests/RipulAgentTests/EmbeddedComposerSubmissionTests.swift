#if os(iOS)
import SwiftUI
import WebKit
import XCTest
@testable import RipulAgent

@MainActor
final class EmbeddedComposerSubmissionTests: XCTestCase {
    private final class ChatPage: NSObject, WKURLSchemeHandler {
        func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
            let html = """
            <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
            <script>
            window.submissions = [];
            window.__ripulSubmitMessage = text => {
                window.submissions.push(text);
                return new Promise(resolve => window.finishSubmission = resolve);
            };
            </script><p>Embedded chat</p>
            """
            let data = Data(html.utf8)
            task.didReceive(URLResponse(url: task.request.url!, mimeType: "text/html",
                expectedContentLength: data.count, textEncodingName: "utf-8"))
            task.didReceive(data)
            task.didFinish()
        }
        func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
    }

    private func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { self.find(type, in: $0) }.first
    }

    private func withComposer(_ check: (AgentBridge, ChatTextView, WKWebView) async throws -> Void) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let bridge = AgentBridge(registry: RipulToolRegistry())
        var config = AgentConfiguration(baseURL: URL(string: "embedded-send-fixture://chat")!,
            hideHeader: true, hideTabSwitcher: true, hideChatInput: true)
        config.websiteDataStore = .nonPersistent()
        config.configureWebView = { $0.setURLSchemeHandler(ChatPage(), forURLScheme: "embedded-send-fixture") }
        let host = UIHostingController(rootView: AgentView(configuration: config, bridge: bridge))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.endEditing(true); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        for _ in 0..<40 {
            if let web = find(WKWebView.self, in: host.view),
               (try? await web.evaluateJavaScript("typeof window.__ripulSubmitMessage === 'function'")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let web = try XCTUnwrap(find(WKWebView.self, in: host.view))
        let input = try XCTUnwrap(find(ChatTextView.self, in: host.view))
        bridge.sessions = []
        bridge.activeSessionId = nil
        XCTAssertNil(bridge.currentSourceChatId)
        input.text = "Embedded chat send regression"
        input.delegate?.textViewDidChange?(input)
        try await Task.sleep(for: .milliseconds(100))
        try await check(bridge, input, web)
    }

    private func submit(_ input: ChatTextView) throws {
        // Hardware Return and the tapped Send button share NativeChatInput's
        // submitMessage -> ChatComposer.handleSubmit path.
        let command = try XCTUnwrap(input.keyCommands?.first { $0.input == "\r" && $0.modifierFlags.isEmpty })
        XCTAssertTrue(UIApplication.shared.sendAction(try XCTUnwrap(command.action), to: input, from: command, for: nil))
    }

    private func waitForSubmission(_ web: WKWebView) async throws {
        for _ in 0..<20 {
            if (try await web.evaluateJavaScript("window.submissions.length")) as? Int == 1 { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("The production composer must submit without a native session ID")
    }

    func testEmbeddedChatSendsWithoutNativeSessionAndClearsOnlyAfterAcceptance() async throws {
        try await withComposer { _, input, web in
            try submit(input)
            try await waitForSubmission(web)
            XCTAssertEqual(input.text, "Embedded chat send regression")
            try submit(input)
            try await Task.sleep(for: .milliseconds(100))
            let submissions = try await web.evaluateJavaScript("window.submissions") as? [String]
            XCTAssertEqual(submissions, ["Embedded chat send regression"], "A pending send must not duplicate the message")
            _ = try await web.evaluateJavaScript("window.finishSubmission?.({success:true})")
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertEqual(input.text, "")
        }
    }

    func testEmbeddedChatKeepsDraftWhenDeliveryIsRejected() async throws {
        try await withComposer { bridge, input, web in
            try submit(input)
            try await waitForSubmission(web)
            _ = try await web.evaluateJavaScript("window.finishSubmission?.({success:false,error:'The conversation is still opening.'})")
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertEqual(input.text, "Embedded chat send regression")
            XCTAssertEqual(bridge.messageSubmissionError, "The conversation is still opening.")
        }
    }

    func testLateAcceptanceDoesNotClearAnotherChatsDraft() async throws {
        try await withComposer { bridge, input, web in
            try submit(input)
            try await waitForSubmission(web)
            bridge.sessions = [ChatSession(id: "other", sourceChatId: "other", displayName: "Other", createdAt: Date())]
            bridge.activeSessionId = "other"
            input.text = "Another chat's draft"
            input.delegate?.textViewDidChange?(input)
            _ = try await web.evaluateJavaScript("window.finishSubmission?.({success:true})")
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertEqual(input.text, "Another chat's draft")
        }
    }
}
#endif
