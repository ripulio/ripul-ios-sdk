import WebKit
import XCTest
@testable import RipulAgent

/// A send whose answer is lost: the page reloads under it, hands back
/// something WebKit cannot convert, has not started yet, or never answers.
/// Each case checks what the composer is told and, above all, how many times
/// the message was actually sent.
@MainActor
final class MessageSubmissionRecoveryTests: XCTestCase {
    /// A chat page served afresh on every load, as a reload would get it.
    ///
    /// `behaviours` are the bodies of `__ripulSubmitMessage`, one per load;
    /// the last serves every later load. What a page would keep in storage
    /// across a reload (the record of sends) is kept here and written into
    /// the next page.
    private final class ChatPage: NSObject, WKURLSchemeHandler, WKScriptMessageHandler {
        var behaviours: [String]
        /// Milliseconds before a load installs its callables.
        var installDelay = 0
        /// What the next page's record says of a send the page before it took.
        var stateAfterReload = "interrupted"
        var withOutcomeCallable = true
        private(set) var loads = 0
        private(set) var sent: [String] = []
        private var taken: [String: String] = [:]

        init(_ behaviours: [String]) { self.behaviours = behaviours }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: String], let text = body["text"] else { return }
            sent.append(text)
            if let id = body["id"] { taken[id] = body["state"] ?? "started" }
        }

        func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
            let behaviour = behaviours[min(loads, behaviours.count - 1)]
            loads += 1
            // A send this page did not finish is, to the next page, whatever the test says.
            let record = taken.mapValues { $0 == "started" ? stateAfterReload : $0 }
            let json = String(data: try! JSONSerialization.data(withJSONObject: record), encoding: .utf8)!
            let outcome = withOutcomeCallable
                ? "window.__ripulSubmissionOutcome = async id => ({ state: pending.has(id) ? 'pending' : (record[id] || 'unknown') });"
                : ""
            let html = """
            <!doctype html><script>
            const record = \(json);
            const pending = new Set();
            const take = (text, id, state) => webkit.messageHandlers.fixture.postMessage({ text, id, state: state || 'started' });
            setTimeout(() => {
                window.__ripulOpenRemoteSession = () => {};
                \(outcome)
                const send = \(behaviour);
                window.__ripulSubmitMessage = (text, images, addressed, modality, id) => {
                    pending.add(id);
                    return Promise.resolve(send(text, id)).finally(() => pending.delete(id));
                };
            }, \(installDelay));
            </script><p>Chat</p>
            """
            let data = Data(html.utf8)
            task.didReceive(URLResponse(url: task.request.url!, mimeType: "text/html",
                expectedContentLength: data.count, textEncodingName: "utf-8"))
            task.didReceive(data)
            task.didFinish()
        }
        func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
    }

    private static let accepts = "(text, id) => { take(text, id, 'accepted'); return { success: true }; }"

    private var saved: (TimeInterval, TimeInterval, TimeInterval)!

    override func setUp() async throws {
        saved = (AgentBridge.submissionPagePatience, AgentBridge.submissionAnswerPatience, AgentBridge.submissionPendingPatience)
        AgentBridge.submissionPagePatience = 8
    }

    override func tearDown() async throws {
        (AgentBridge.submissionPagePatience, AgentBridge.submissionAnswerPatience, AgentBridge.submissionPendingPatience) = saved
    }

    private func chat(_ page: ChatPage) async throws -> AgentBridge {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(page, forURLScheme: "send-fixture")
        configuration.userContentController.add(page, name: "fixture")
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.load(URLRequest(url: URL(string: "send-fixture://chat")!))
        let bridge = AgentBridge()
        bridge.attach(to: web)
        if page.installDelay == 0 {
            for _ in 0..<100 {
                if (try? await web.evaluateJavaScript("typeof window.__ripulSubmitMessage === 'function'")) as? Bool == true { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        webViews.append(web)
        return bridge
    }
    private var webViews: [WKWebView] = []

    func testAnAnswerWebKitCannotConvertIsStillRead() async throws {
        // Handed back as it is, a Proxy is "JavaScript execution returned a
        // result of an unsupported type".
        let page = ChatPage(["(text, id) => { take(text, id, 'accepted'); return new Proxy({ success: true }, {}); }"])
        let bridge = try await chat(page)
        let accepted = await bridge.submitMessage("hello")
        XCTAssertTrue(accepted)
        XCTAssertEqual(page.sent, ["hello"])
        XCTAssertNil(bridge.messageSubmissionError)
    }

    func testAPageThatReloadsBeforeTakingTheMessageIsSentItAgain() async throws {
        let page = ChatPage(["() => { location.reload(); return new Promise(() => {}); }", Self.accepts])
        let bridge = try await chat(page)
        let accepted = await bridge.submitMessage("hello")
        XCTAssertTrue(accepted, bridge.messageSubmissionError ?? "")
        XCTAssertEqual(page.sent, ["hello"], "The message is sent once, by the page that came back")
        XCTAssertEqual(page.loads, 2)
    }

    func testAnAcceptedSendWhoseAnswerWasLostIsNotSentAgain() async throws {
        let page = ChatPage(["(text, id) => { take(text, id); location.reload(); return new Promise(() => {}); }", Self.accepts])
        page.stateAfterReload = "accepted"
        let bridge = try await chat(page)
        let accepted = await bridge.submitMessage("hello")
        XCTAssertTrue(accepted, bridge.messageSubmissionError ?? "")
        XCTAssertEqual(page.sent, ["hello"])
    }

    func testASendTheReloadInterruptedIsNeitherRepeatedNorCalledSent() async throws {
        let page = ChatPage(["(text, id) => { take(text, id); location.reload(); return new Promise(() => {}); }", Self.accepts])
        let bridge = try await chat(page)
        let accepted = await bridge.submitMessage("hello")
        XCTAssertFalse(accepted)
        XCTAssertEqual(page.sent, ["hello"], "Whether it arrived is not known, so it must not be sent twice")
        XCTAssertEqual(bridge.messageSubmissionError, AgentBridge.submissionInterrupted)
    }

    func testAPageReloadingOntoANewBuildIsSentTheMessageWhenItIsBack() async throws {
        let stale = """
        () => { setTimeout(() => location.reload(), 150);
                return { success: false, error: 'The chat is updating to a new version.', retry: true }; }
        """
        let page = ChatPage([stale, Self.accepts])
        let bridge = try await chat(page)
        let accepted = await bridge.submitMessage("hello")
        XCTAssertTrue(accepted, bridge.messageSubmissionError ?? "")
        XCTAssertEqual(page.sent, ["hello"])
        XCTAssertEqual(page.loads, 2)
    }

    func testAPageThatHasNotStartedIsWaitedFor() async throws {
        let page = ChatPage([Self.accepts])
        page.installDelay = 1_500
        let bridge = try await chat(page)
        let accepted = await bridge.submitMessage("hello")
        XCTAssertTrue(accepted, bridge.messageSubmissionError ?? "")
        XCTAssertEqual(page.sent, ["hello"])
    }

    func testASendThatNeverAnswersEndsWithoutASecondSend() async throws {
        AgentBridge.submissionAnswerPatience = 0.5
        AgentBridge.submissionPendingPatience = 1
        let page = ChatPage(["(text, id) => { take(text, id); return new Promise(() => {}); }"])
        let bridge = try await chat(page)
        let accepted = await bridge.submitMessage("hello")
        XCTAssertFalse(accepted)
        XCTAssertEqual(page.sent, ["hello"])
        XCTAssertEqual(bridge.messageSubmissionError, AgentBridge.submissionUnconfirmed)
    }

    func testAPageThatKeepsNoRecordIsNotSentTheMessageTwice() async throws {
        // An older build of the page: nothing to ask what became of the send.
        let page = ChatPage(["(text, id) => { take(text, id); location.reload(); return new Promise(() => {}); }", Self.accepts])
        page.withOutcomeCallable = false
        let bridge = try await chat(page)
        let accepted = await bridge.submitMessage("hello")
        XCTAssertFalse(accepted)
        XCTAssertEqual(page.sent, ["hello"])
        XCTAssertEqual(bridge.messageSubmissionError, AgentBridge.submissionUnconfirmed)
    }

    func testARefusalIsReportedInThePagesWordsAndNotRetried() async throws {
        let page = ChatPage(["() => ({ success: false, error: 'The conversation is still opening.' })"])
        let bridge = try await chat(page)
        let accepted = await bridge.submitMessage("hello")
        XCTAssertFalse(accepted)
        XCTAssertEqual(bridge.messageSubmissionError, "The conversation is still opening.")
        XCTAssertEqual(page.loads, 1)
    }
}
