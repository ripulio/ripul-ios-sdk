import XCTest
import MarkdownUI
#if os(macOS)
import AppKit
import SwiftUI
#endif
@testable import RipulAgent

final class NativeChatMarkdownTests: XCTestCase {
    func testReferenceLinkResolvesAcrossCodeBlock() {
        let html = NativeChatMarkdownDocument.parse("""
        Read [the guide][guide].

        ```swift
        let answer = 42
        ```

        [guide]: https://example.com/guide
        """).renderHTML()
        XCTAssertTrue(html.contains("href=\"https://example.com/guide\""))
        XCTAssertTrue(html.contains("language-swift"))
        XCTAssertFalse(html.contains("[guide]"))
    }

    func testLongFenceKeepsShorterFenceInCode() {
        let html = NativeChatMarkdownDocument.parse("""
        ````markdown
        ```swift
        let answer = 42
        ```
        ````
        """).renderHTML()
        XCTAssertEqual(html.components(separatedBy: "<pre>").count - 1, 1)
        XCTAssertTrue(html.contains("```swift\nlet answer = 42\n```"))
        XCTAssertTrue(html.contains("language-markdown"))
    }

    func testTildeFenceStaysInsideQuote() {
        let html = NativeChatMarkdownDocument.parse("""
        > Example
        >
        > ~~~swift
        > let answer = 42
        > ~~~
        """).renderHTML()
        XCTAssertTrue(html.contains("<blockquote>"))
        XCTAssertTrue(html.contains("language-swift"))
        XCTAssertTrue(html.contains("</code></pre>\n</blockquote>"))
    }

    func testCodeDoesNotBreakOrderedListNumbering() {
        let html = NativeChatMarkdownDocument.parse("""
        3. First

           ```swift
           let answer = 42
           ```

        4. Second
        """).renderHTML()
        XCTAssertTrue(html.contains("<ol start=\"3\">"))
        XCTAssertEqual(html.components(separatedBy: "<ol").count - 1, 1)
        XCTAssertEqual(html.components(separatedBy: "<li>").count - 1, 2)
        XCTAssertTrue(html.contains("</code></pre>\n</li>"))
    }

    func testOpenFenceCanGrowWithoutExposingFenceMarkers() {
        for suffix in ["", "42", "42\nprint(answer)"] {
            let html = NativeChatMarkdownDocument.parse("```swift\nlet answer = " + suffix).renderHTML()
            XCTAssertTrue(html.contains("language-swift"))
            XCTAssertFalse(html.contains("```"))
            XCTAssertTrue(html.contains("let answer = " + suffix))
        }
    }

    func testTablesKeepInlineFormattingAndAlignment() {
        let document = NativeChatMarkdownDocument.parse("""
        | Name | Count |
        | :--- | ---: |
        | **Ready** | `42` |
        """)
        // Verify the tree consumed by SwiftUI, including column alignment and
        // inline formatting, without routing it through an HTML serializer.
        XCTAssertEqual(document, MarkdownContent {
            TextTable {
                TextTableColumn<Int>(alignment: .leading, title: "Name") { _ in Strong("Ready") }
                TextTableColumn<Int>(alignment: .trailing, title: "Count") { _ in Code("42") }
            } rows: {
                TextTableRow(0)
            }
        })
    }

    #if os(macOS)
    @MainActor
    func testWideTablesAndCodeScrollInsideNarrowMessage() {
        let source = """
        | First column | Second column | Third column | Fourth column |
        | --- | --- | --- | --- |
        | A long first value | A long second value | A long third value | A long fourth value |

        ```plaintext
        This deliberately long code line must scroll inside the message without widening its bubble.
        ```
        """
        let host = NSHostingView(rootView: NativeChatMarkdownBody(content: source).frame(width: 320))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        for _ in 0..<8 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants($0) }
        }
        let scrollers = descendants(host).compactMap { $0 as? NSScrollView }
        XCTAssertGreaterThanOrEqual(scrollers.count, 2, "Both table and code need their own scroller")
        for scroller in scrollers {
            XCTAssertGreaterThan(scroller.bounds.width, 0)
            XCTAssertLessThanOrEqual(scroller.bounds.width, 320.5)
        }
    }
    #endif
}
