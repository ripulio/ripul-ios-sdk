import XCTest
import MarkdownUI
@testable import RipulAgent

final class NativeChatMarkdownBlocksTests: XCTestCase {
    private typealias Blocks = NativeChatMarkdownBlocks

    /// Messages whose blocks, parsed one by one, must show what the whole does.
    private let corpus: [String] = [
        "# Title\n\nA paragraph\nover two lines.\n\n- one\n- two\n\nAfter the list.",
        "- loose\n\n- list\n\n- items\n\nThen text.",
        "1. first\n\n2. second\n\n   still second\n\n3. third",
        "```swift\nlet a = 1\n\nlet b = 2\n```\n\nAfter code.",
        "~~~\nnot ```closed here\n\n~~~\n\nText.",
        "Para\n\n    indented code\n\n    more code\n\nEnd.",
        "> quoted\n> more\n\n> another quote\n\nText.",
        "Read [the guide][guide].\n\n```js\nx()\n```\n\nSee [guide] again.\n\n[guide]: https://example.com/guide",
        "$$\na = b\n\nc = d\n$$\n\nAfter maths.",
        "Text\n\n<!-- a comment\n\nstill comment -->\n\nAfter.",
        "| a | b |\n|---|---|\n| 1 | 2 |\n\nBelow the table.",
        "Heading\n===\n\nText\n\n---\n\nMore",
        "- item\n\n  ```\n  code in item\n\n  more\n  ```\n\n- next item",
    ]

    func testBlocksRenderWhatTheWholeMessageDoes() {
        for message in corpus {
            let whole = NativeChatMarkdownDocument.parse(message).renderHTML()
            let pieces = Blocks.split(message)
                .map { NativeChatMarkdownDocument.parse($0.source).renderHTML() }
                .joined()
            XCTAssertEqual(pieces, whole, "split changed:\n\(message)")
        }
    }

    func testClosedBlocksKeepIdentityAcrossAStreamedAppend() {
        let message = """
        # Plan

        First we read the file.

        ```swift
        let a = 1

        let b = 2
        ```

        - one
        - two

        | a | b |
        |---|---|
        | 1 | 2 |

        Done.
        """
        let final = Blocks.split(message)
        XCTAssertEqual(final.count, 6)
        var index = message.startIndex
        while index < message.endIndex {
            index = message.index(after: index)
            let blocks = Blocks.split(String(message[..<index]))
            // Every block but the one still growing is already the final block.
            for block in blocks.dropLast() {
                XCTAssertEqual(block, final[block.id], "block \(block.id) changed at \(message.distance(from: message.startIndex, to: index))")
            }
        }
        // An unchanged block parses to the same content (the cache hit).
        let before = Blocks.split("# Plan\n\nFirst we read")
        let after = Blocks.split("# Plan\n\nFirst we read the file.\n\nMore")
        XCTAssertEqual(before[0], after[0])
        XCTAssertEqual(NativeChatMarkdownDocument.parse(before[0].source),
                       NativeChatMarkdownDocument.parse(after[0].source))
    }

    func testDoesNotSplitWhereTheMessageWouldChange() {
        XCTAssertEqual(Blocks.split("- a\n\n- b").count, 1, "a loose list is one list")
        XCTAssertEqual(Blocks.split("- a\n\n  more of a").count, 1, "an indented line continues the item")
        XCTAssertEqual(Blocks.split("```\na\n\nb").count, 1, "an open fence")
        XCTAssertEqual(Blocks.split("$$\na\n\nb\n$$").count, 1, "display maths")
        XCTAssertEqual(Blocks.split("<!--\na\n\nb -->").count, 1, "an HTML comment")
        XCTAssertEqual(Blocks.split("a\n\nb\n\nc").count, 3)
    }

    func testReferenceDefinitionsReachEveryBlockThatMayUseThem() {
        let blocks = Blocks.split("See [x].\n\nPlain.\n\n[x]: https://example.com")
        XCTAssertEqual(blocks.map(\.text), ["See [x].", "Plain."], "a block of definitions alone is not drawn")
        XCTAssertTrue(blocks[0].source.hasSuffix("[x]: https://example.com"))
        XCTAssertEqual(blocks[1].source, "Plain.")
    }

    func testSpacingFollowsTheThemeMargins() {
        let blocks = Blocks.split("# H\n\npara\n\n```\ncode\n```\n\n---\n\n- a\n\nend")
        XCTAssertEqual(blocks.map(\.spacingAbove), [0, 4, 8, 12, 12, 8])
    }
}
