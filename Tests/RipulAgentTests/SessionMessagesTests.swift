#if os(macOS)
import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import RipulAgent

@MainActor
final class SessionMessagesTests: XCTestCase {
    private final class Loader: NSObject, WKNavigationDelegate {
        var finished: (() -> Void)?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished?() }
    }

    func testMetadataPanelSettlesAndOnlyRefreshesWhenUserRowsChange() async throws {
        let bridge = AgentBridge()
        let web = WKWebView()
        let loader = Loader()
        let loaded = expectation(description: "Fixture loaded")
        loader.finished = { loaded.fulfill() }
        web.navigationDelegate = loader
        web.loadHTMLString("""
        <script>
        window.reads = 0;
        window.__ripulGetHumanChatAnchors = async () => {
          window.reads++;
          return {messages: [], complete: true};
        };
        </script>
        """, baseURL: nil)
        await fulfillment(of: [loaded], timeout: 5)
        bridge.attach(to: web)

        let session = ChatSession(id: "settle", sourceChatId: "settle", displayName: "Metadata refresh", createdAt: Date())
        let host = NSHostingView(rootView: SessionMetadataPanel(bridge: bridge, session: session))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 800),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }

        // A recreated Combine chain replayed @Published's current value on
        // every render, incrementing the task ID until the Mac main loop froze.
        try await Task.sleep(for: .milliseconds(500))
        let initialValue = try await web.evaluateJavaScript("window.reads")
        let initialReads = try XCTUnwrap(initialValue as? Int)
        XCTAssertGreaterThan(initialReads, 0)
        try await Task.sleep(for: .milliseconds(300))
        let settledReads = try await web.evaluateJavaScript("window.reads") as? Int
        XCTAssertEqual(settledReads, initialReads)

        bridge.nativeChat.applyBackfill([
            ["messageId": "one", "role": "user", "content": "A newly loaded input", "timestamp": 1]
        ], chatId: "settle")
        try await Task.sleep(for: .milliseconds(300))
        let changedValue = try await web.evaluateJavaScript("window.reads")
        let changedReads = try XCTUnwrap(changedValue as? Int)
        XCTAssertGreaterThan(changedReads, initialReads)
        for index in 1...5 {
            bridge.nativeChat.applyAdd(["messageId": "reply", "role": "assistant", "content": "Token \(index)", "timestamp": 2])
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(300))
        let streamedReads = try await web.evaluateJavaScript("window.reads") as? Int
        XCTAssertEqual(streamedReads, changedReads)
    }

    func testFullMessageGrowsPastOneLineAndWrapsAtInspectorWidths() {
        let source = """
        For future dates only, show me where and how the changes will apply.

        Please keep the existing bookings and their details visible while making this change. There should be enough room to read the whole request in the metadata panel.

        - Keep **all the details**, including this list.
        - Preserve the original paragraphs and `inline code`.

        This is the end of the message, which must remain visible too.
        """
        let anchor = AgentBridge.HumanChatAnchor(correlationId: "long", text: source,
            timestamp: Date(), senderDisplayName: "Example Participant")
        let short = AgentBridge.HumanChatAnchor(correlationId: "short", text: "Thanks.",
            timestamp: Date(), senderDisplayName: "Example Participant")

        let narrow = size(of: SessionMessageCard(number: 1, anchor: anchor, onJump: {}), width: 256)
        let wide = size(of: SessionMessageCard(number: 1, anchor: anchor, onJump: {}), width: 456)
        let brief = size(of: SessionMessageCard(number: 2, anchor: short, onJump: {}), width: 256)
        let prose = size(of: NativeChatMarkdownBody(content: source, contextMentions: true), width: 232)

        XCTAssertEqual(narrow.width, 256, accuracy: 0.5)
        XCTAssertEqual(wide.width, 456, accuracy: 0.5)
        XCTAssertGreaterThan(narrow.height, wide.height)
        XCTAssertGreaterThan(narrow.height, brief.height + 120)
        XCTAssertGreaterThanOrEqual(narrow.height, prose.height + 24,
            "The card must accommodate the complete rendered message plus its padding and header")
    }

    func testLongParagraphsAreNotCappedAtTheListViewportHeight() {
        let text = (1...24).map { "Paragraph \($0). Each message keeps its full text available while scrolling." }
            .joined(separator: "\n\n")
        let anchor = AgentBridge.HumanChatAnchor(correlationId: "very-long", text: text,
            timestamp: nil, senderDisplayName: nil)
        let rendered = size(of: SessionMessageCard(number: 12, anchor: anchor, onJump: {}), width: 256)
        XCTAssertEqual(rendered.width, 256, accuracy: 0.5)
        XCTAssertGreaterThan(rendered.height, 1000, "Only the list viewport is bounded, never the message")
    }

    private func size<V: View>(of view: V, width: CGFloat) -> CGSize {
        let host = NSHostingView(rootView: view.frame(width: width).fixedSize(horizontal: false, vertical: true))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 700),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        return host.fittingSize
    }
}
#endif
