import XCTest
import MarkdownUI
#if os(macOS)
import AppKit
import SwiftUI
#endif
@testable import RipulAgent

final class NativeChatRenderingTests: XCTestCase {
    private func fixtures(_ key: String) throws -> [[String: Any]] {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: repo.appendingPathComponent("shared/native-chat-rendering.json"))
        return try XCTUnwrap((JSONSerialization.jsonObject(with: data) as? [String: Any])?[key] as? [[String: Any]])
    }

    @MainActor
    func testRealWebContractsReachNativeRows() throws {
        let store = NativeChatMessageStore()
        let rows = try fixtures("messages").map { try XCTUnwrap($0["wire"] as? [String: Any]) }
        store.applyBackfill(rows, chatId: "chat")
        let table = try XCTUnwrap(store.messages.first { $0.id == "table" }?.table)
        XCTAssertEqual(table.columns.map(\.key), ["Name", "Status"])
        XCTAssertEqual(table.rows.first?["Status"], "Ready")
        XCTAssertEqual(table.rows.first?["_link"], "https://example.com/item")
        XCTAssertEqual(table.matchingOption(for: table.rows[0], options: store.messages[0].askUser!.options)?.value, "alice")
        let video = try XCTUnwrap(store.messages.first { $0.id == "video" }?.videoAttachments.first)
        XCTAssertEqual(video.url, "https://example.com/recording.mp4")
        XCTAssertEqual(video.posterUrl, "https://example.com/poster.jpg")
        XCTAssertEqual(video.width, 640)
        XCTAssertEqual(store.messages.first { $0.id == "picture-choice" }?.askUser?.options.first?.image, "https://example.com/blue.jpg")
        // Streaming updates preserve media and rebuild a row when media changes.
        store.applyUpdate(["messageId": "video", "content": "Recording ready"])
        XCTAssertEqual(store.messages.first { $0.id == "video" }?.videoAttachments, [video])
        store.applyPatch([["messageId": "video", "videoAttachments": []]], chatId: "chat")
        XCTAssertEqual(store.messages.first { $0.id == "video" }?.videoAttachments, [])
    }

    /// The SDK's context envelope arrives as cards with the web card's labels, not as JSON in the text.
    @MainActor
    func testContextAttachmentsReachNativeRowsWithTheWebLabels() throws {
        let store = NativeChatMessageStore()
        store.applyBackfill(try fixtures("messages").map { try XCTUnwrap($0["wire"] as? [String: Any]) }, chatId: "chat")
        let sent = try XCTUnwrap(store.messages.first { $0.id == "context-attachment" })
        XCTAssertEqual(sent.content, "It’s the records ...")
        let element = try XCTUnwrap(sent.contextAttachments.first)
        XCTAssertEqual(element.title, "Element A — home.card.earning.monthDots")
        XCTAssertEqual(element.source, "Screen element · WAC Beta · Reference")
        XCTAssertEqual(element.icon, .element)
        XCTAssertEqual(element.scope, "Included with this message")
        XCTAssertTrue(element.content.hasPrefix("Host app: WAC Beta\nSelected Inspector element\n"))
        XCTAssertNotEqual(element.capturedLabel, element.capturedAt, "The SDK's timestamp reads as a date")

        let only = try XCTUnwrap(store.messages.first { $0.id == "context-attachment-only" })
        XCTAssertEqual(only.content, "")
        XCTAssertEqual(only.contextAttachments.map(\.icon), [.element, .instructions])
        XCTAssertEqual(only.contextAttachments.map(\.id), ["0", "1"])
        XCTAssertEqual(only.contextAttachments[1].source, "Instructions · Every message")
        XCTAssertNotEqual(only.contextAttachments[1].capturedLabel, only.contextAttachments[1].capturedAt, "A web timestamp with milliseconds reads as a date")
        XCTAssertTrue(store.rows.contains { $0 == .user(only) }, "Attachments alone still make a user row")
        XCTAssertEqual(NativeContextAttachment(id: "0", title: "", source: "", icon: .app, scope: "", capturedAt: "soon", content: "").capturedLabel, "soon")
    }

    func testSharedCitationFixturesRenderReadableLinks() throws {
        for fixture in try fixtures("citations") {
            let source = try XCTUnwrap(fixture["source"] as? String)
            let document = NativeChatMarkdownDocument.parse(source)
            XCTAssertEqual(document.renderPlainText(), fixture["text"] as? String)
            let prepared = NativeChatFileReferences.prepare(source)
            let link = try XCTUnwrap(prepared.range(of: #"ripul://file-references\?refs=[A-Za-z0-9_-]+"#, options: .regularExpression))
            let references = try XCTUnwrap(NativeChatFileReferences.references(in: URL(string: String(prepared[link]))!))
            XCTAssertEqual(references.map(\.filePath), fixture["paths"] as? [String])
            XCTAssertFalse(document.renderHTML().contains(":codex-file-citation"))
        }
    }

    func testCitationsKeepCodeEscapesLinksAndMalformedInputLiteral() {
        let token = #":codex-file-citation{path="/Users/me/a.ts"}"#
        for source in ["`\(token)`", "```text\n\(token)\n```", "    \(token)", "\\\(token)", "[\(token)](https://example.com)", "<code>\(token)</code>", "<pre>\n\(token)\n</pre>",
                       #":codex-file-citation{path="javascript:alert(1)"}"#,
                       #":codex-file-citation{path="/a" path="/b"}"#,
                       #":codex-file-citation{path=oops}"#] {
            XCTAssertEqual(NativeChatFileReferences.prepare(source), source, source)
        }
        XCTAssertEqual(NativeChatMarkdownDocument.parse(token, contextMentions: true).renderPlainText(), token, "User code examples retain the web sent-message behaviour")
    }

    func testCitationsGroupDeduplicateAndHidePartialStreamingAttributes() {
        let token = #":codex-file-citation{path="/Users/me/a.ts:3"}"#
        for n in NativeChatFileReferences.prefix.count..<token.count {
            XCTAssertEqual(NativeChatMarkdownDocument.parse(String(token.prefix(n))).renderPlainText(), "Source…", "prefix \(n)")
        }
        XCTAssertEqual(NativeChatMarkdownDocument.parse("\(token)\n \(token)").renderPlainText(), "a.ts:3")
        XCTAssertEqual(NativeChatMarkdownDocument.parse("\(token) :codex-file-citation{path=\"").renderPlainText(), "a.ts:3")
        let separate = NativeChatMarkdownDocument.parse("\(token)\n\n\(token)").renderHTML()
        XCTAssertEqual(separate.components(separatedBy: "<a ").count - 1, 2)
    }

    func testLiteralFilenamesAndFileNavigation() throws {
        let ref = try XCTUnwrap(NativeChatFileReferences.fromPath("/custom/notes #1?:literal.md:42-48"))
        XCTAssertEqual(ref.label, "notes #1?:literal.md:42–48")
        XCTAssertEqual(ref.href, "file:///custom/notes%20%231%3F%3Aliteral.md#L42-L48")
        XCTAssertEqual(NativeChatFileReferences.references(in: NativeChatFileReferences.url(for: [ref])!), [ref])
        let page = URL(string: "https://demo.ripul.io/mobile")!
        for href in ["/Users/me/a.swift:12", "file:///custom/a", "https://demo.ripul.io/Users/me/a#L4", "https://demo.ripul.io:443/Users/me/a"] {
            XCTAssertTrue(NativeChatFileReferences.isFileURL(URL(string: href)!, pageURL: page), href)
        }
        for href in ["https://example.com/Users/me/a", "file://other-host/a", "/settings", "https://demo.ripul.io.evil/Users/me/a", "//example.com/Users/me/a", "/%2555sers/me/a"] {
            XCTAssertFalse(NativeChatFileReferences.isFileURL(URL(string: href)!, pageURL: page), href)
        }
    }

    func testParticipantDisplayPreservesIdentityFreeLabelsAndLiteralExamples() {
        let source = "**Hello @Peter_Maude_(Mac)** and *@Alice*."
        XCTAssertEqual(NativeChatMarkdownDocument.parse(source, contextMentions: true).renderPlainText(), "Hello @Peter Maude (Mac) and @Alice.")
        for text in ["`@Peter_Maude_(Mac)`", "```\n@Peter_Maude\n```", "mail@Alice.com", "@media @TODO @API", "[@Peter_Maude](https://example.com)", "\\@Peter_Maude", "[context: ripul.chats/YWJj | @Peter_Maude chat]"] {
            if text.hasPrefix("[context:") {
                XCTAssertEqual(NativeChatMarkdownDocument.parse(text, contextMentions: true).renderPlainText(), "@@Peter_Maude chat")
            } else { XCTAssertEqual(NativeChatParticipantMentions.prepare(text), text, text) }
        }
    }

    @MainActor
    func testPlaybackIsIdleUntilRequestedAndHandlesUnavailableFiles() async throws {
        let playback = NativeChatVideoPlayback()
        XCTAssertNil(playback.player)
        playback.play("javascript:alert(1)")
        XCTAssertTrue(playback.failed)
        XCTAssertNil(playback.player)
        playback.stop()
        playback.play(URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".mp4").absoluteString)
        let deadline = Date().addingTimeInterval(5)
        while !playback.failed && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(playback.failed, "Unavailable recordings need a readable fallback")
        playback.stop()
        XCTAssertNil(playback.player, "Recycled rows must stop playback and release the asset")
        XCTAssertFalse(playback.failed)
    }

    #if os(macOS)
    @MainActor
    func testMediaFitsANarrowChatWithoutDownloadingVideo() {
        let video = NativeChatVideoAttachment(id: "fixture", url: "https://example.com/video.mp4", width: 640, height: 360)
        let host = NSHostingView(rootView: NativeChatVideoView(attachment: video).frame(width: 300).fixedSize(horizontal: false, vertical: true))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        for _ in 0..<8 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) }
        XCTAssertEqual(host.fittingSize.width, 300, accuracy: 1)
        XCTAssertEqual(host.fittingSize.height, 168.75, accuracy: 1)
    }

    @MainActor
    func testContextAttachmentCardStartsClosedAndFitsANarrowBubble() {
        let attachment = NativeContextAttachment(
            id: "0", title: "Element A — home.card.earning.monthDots", source: "Screen element · WAC Beta · Reference",
            icon: .element, scope: "Included with this message", capturedAt: "2026-10-27T10:10:58Z",
            content: String(repeating: "Location in host window (points): x=88, y=522, width=272, height=8\n", count: 40))
        let host = NSHostingView(rootView: NativeContextAttachmentCard(attachment: attachment).frame(width: 240).fixedSize(horizontal: false, vertical: true))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        for _ in 0..<8 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) }
        XCTAssertEqual(host.fittingSize.width, 240, accuracy: 1)
        XCTAssertGreaterThanOrEqual(host.fittingSize.height, 44)
        XCTAssertLessThan(host.fittingSize.height, 140, "Closed, the card shows its title and source, not the 40 lines attached")
    }
    #endif
}
