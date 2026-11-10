import XCTest
import MarkdownUI
#if os(macOS)
import AppKit
import SwiftUI
#endif
@testable import RipulAgent

final class NativeChatContextMentionsTests: XCTestCase {
    private func render(_ source: String) -> MarkdownContent {
        NativeChatMarkdownDocument.parse(source, contextMentions: true)
    }

    func testLongChatReferenceShowsTitleInlineAndRetainsExactDestination() {
        let reference = String(repeating: "eyJtYWNoaW5lSWQiOiJtYWMiLCJzZXNzaW9uSWQiOiJjaGF0In0", count: 12)
        let source = "Report your findings to [context: ripul.chats/\(reference) | Instrumenting WAC iOS app for agent automation], then discuss what went wrong."
        let document = render(source)
        XCTAssertEqual(document.renderPlainText(), "Report your findings to @Instrumenting WAC iOS app for agent automation, then discuss what went wrong.")
        XCTAssertTrue(document.renderHTML().contains("href=\"ripul://chat-reference?ref=\(reference)\""))
        XCTAssertFalse(document.renderPlainText().contains("[context:"))
        // Assistant examples and the raw message are not rewritten by a cache hit.
        XCTAssertEqual(NativeChatMarkdownDocument.parse(source).renderPlainText(), source)
    }

    func testSameTitlesKeepDistinctReferencesAndSurroundingMarkdown() {
        let document = render("**Compare** [context: ripul.chats/YWJj | Same title] and [context: ripul.chats/ZGVm | Same title] with [the guide][g].\n\n[g]: https://example.com/guide")
        let html = document.renderHTML()
        XCTAssertTrue(html.contains("<strong>Compare</strong>"))
        XCTAssertTrue(html.contains("href=\"ripul://chat-reference?ref=YWJj\""))
        XCTAssertTrue(html.contains("href=\"ripul://chat-reference?ref=ZGVm\""))
        XCTAssertTrue(html.contains("href=\"https://example.com/guide\""))
    }

    func testCodeLinksImagesEscapesAndDefinitionsStayLiteral() {
        let token = "[context: ripul.chats/YWJj | Chat]"
        let sources = [
            "`\(token)`", "`` literal ` \(token) ``", "```text\n\(token)\n```",
            "> ~~~\n> \(token)\n> ~~~", "    \(token)",
            "[\(token)](https://example.com)", "![\(token)](https://example.com/image.png)",
            "[\(token)][g]\n\n[g]: https://example.com", "\\\(token)",
            "[context: ripul.chats/YWJj]: https://example.com\n\n[context: ripul.chats/YWJj]",
            "<div>\n\(token)\n</div>",
        ]
        for source in sources {
            XCTAssertEqual(NativeChatContextMentions.prepare(source), source, source)
        }
    }

    func testUnicodeAndMarkdownInTitleAreLiteral() {
        let title = "Café 👋 **bold** `code` <tag> & $x$ \\path"
        let document = render("👋 Send to [context: ripul.chats/YWJj | \(title)] please.")
        XCTAssertEqual(document.renderPlainText(), "👋 Send to @\(title) please.")
        let html = document.renderHTML()
        XCTAssertFalse(html.contains("<strong>"))
        XCTAssertFalse(html.contains("<code>"))
        XCTAssertFalse(html.contains("ripul-math:"))
        XCTAssertTrue(html.contains("&lt;tag&gt;"))
    }

    func testUnlabelledAndOtherContextMentionsHaveReadableFallbacks() {
        let document = render("[context: ripul.chats/YWJj] [context: repo.branches/ZGVm | Main branch] [context: page.blocks/hero]")
        XCTAssertEqual(document.renderPlainText(), "@Chat @Main branch @mention")
        XCTAssertEqual(document.renderHTML().components(separatedBy: "<a ").count - 1, 1)
    }

    func testNestedListsAndQuotesKeepTheirStructure() {
        let document = render("""
        > 3. Ask [context: ripul.chats/YWJj | First chat].
        > 4. Then [context: ripul.chats/ZGVm | Second chat].
        """)
        let html = document.renderHTML()
        XCTAssertTrue(html.contains("<blockquote>"))
        XCTAssertTrue(html.contains("<ol start=\"3\">"))
        XCTAssertFalse(document.renderPlainText().contains("[context:"))
    }

    func testMalformedAndIncompleteTokensStayUntouched() {
        for source in ["[context: ripul.chats/ | Chat]", "[context: ripul.chats/YWJj | Chat", "[context: invalid/id/extra | Chat]"] {
            XCTAssertEqual(NativeChatContextMentions.prepare(source), source)
        }
    }

    func testChatLinkRoutingAcceptsOnlyChatReferences() {
        XCTAssertEqual(NativeChatContextMentions.reference(in: URL(string: "ripul://chat-reference?ref=YWJj_-0")!), "YWJj_-0")
        XCTAssertNil(NativeChatContextMentions.reference(in: URL(string: "https://example.com?ref=YWJj")!))
        XCTAssertNil(NativeChatContextMentions.reference(in: URL(string: "ripul://open-chat?id=YWJj")!))
    }

    #if os(macOS)
    @MainActor
    func testLongReferenceFitsAReadableNarrowBubble() {
        let reference = String(repeating: "eyJtYWNoaW5lSWQiOiJtYWMi", count: 30)
        let source = "Report findings to [context: ripul.chats/\(reference) | Instrumenting WAC iOS app for agent automation], then discuss."
        let host = NSHostingView(rootView: NativeChatMarkdownBody(content: source, contextMentions: true)
            .frame(width: 320).fixedSize(horizontal: false, vertical: true))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        for _ in 0..<8 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        XCTAssertGreaterThan(host.fittingSize.height, 30)
        XCTAssertLessThan(host.fittingSize.height, 160, "The encoded reference must not inflate the native bubble")
        XCTAssertLessThanOrEqual(host.fittingSize.width, 320.5)
    }
    #endif
}
