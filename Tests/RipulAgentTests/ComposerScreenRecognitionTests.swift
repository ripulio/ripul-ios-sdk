import XCTest
import CoreGraphics
import ImageIO
@testable import RipulAgent
#if os(macOS)
import AppKit
#endif

final class ComposerScreenRecognitionTests: XCTestCase {
    func testRowsKeepRepeatedValuesAndColumnsAndFilterExcludedRegions() {
        let items: [ComposerScreenText] = [
            .init(text: "02:00", frame: CGRect(x: 0.7, y: 0.32, width: 0.1, height: 0.02)),
            .init(text: "01:00", frame: CGRect(x: 0.1, y: 0.32, width: 0.1, height: 0.02)),
            .init(text: "06 Aug 2026", frame: CGRect(x: 0.1, y: 0.35, width: 0.15, height: 0.02)),
            .init(text: "06 Aug 2026", frame: CGRect(x: 0.7, y: 0.35, width: 0.15, height: 0.02)),
            .init(text: "Private note", frame: CGRect(x: 0.1, y: 0.5, width: 0.6, height: 0.1))
        ]
        let rows = ComposerScreenRecognition.rows(items, excluding: [CGRect(x: 0, y: 0.49, width: 1, height: 0.2)])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0], "[y=33%] [x=10%] 01:00 | [x=70%] 02:00")
        XCTAssertEqual(rows[1].components(separatedBy: "06 Aug 2026").count, 3)
        XCTAssertFalse(rows.joined().contains("Private note"))
    }

    #if os(macOS)
    @MainActor
    func testComponentInstrumentationUpdatesWithCurrentValue() {
        let view = NSView()
        view.ripulAIContext = .init(id: "pay.total", label: "Total pay", value: "£65.00")
        XCTAssertEqual(view.ripulAIContext?.value, "£65.00")
        view.ripulAIContext?.value = "£75.00"
        XCTAssertEqual(view.ripulAIContext?.value, "£75.00")
        view.ripulAIContext = .excluded
        XCTAssertTrue(view.ripulAIContext?.isExcluded == true)
        view.ripulAIContext = nil
        XCTAssertNil(view.ripulAIContext)
    }

    @MainActor
    func testRenderedTextRecognitionFindsValuesWithoutNativeLabels() async throws {
        let image = NSImage(size: NSSize(width: 600, height: 800))
        image.lockFocus()
        NSColor.white.setFill(); NSBezierPath(rect: CGRect(x: 0, y: 0, width: 600, height: 800)).fill()
        for (index, line) in ["TestClient", "Account Manager £15.00", "Base pay £15.00", "Call out bonus £50.00", "Total £65.00"].enumerated() {
            (line as NSString).draw(at: NSPoint(x: 30, y: 700 - index * 90), withAttributes: [.font: NSFont.systemFont(ofSize: 26), .foregroundColor: NSColor.black])
        }
        image.unlockFocus()
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let result = try await ComposerScreenRecognition.recognize(cgImage)
        let text = ComposerScreenRecognition.rows(result).joined(separator: "\n")
        XCTAssertTrue(text.contains("TestClient"), text)
        XCTAssertTrue(text.contains("Account Manager"), text)
        XCTAssertTrue(text.contains("65.00"), text)
    }
    #endif

    /// Optional local regression against the reported screen. No user screenshot is committed.
    func testReportedScreenWhenProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["RIPUL_CONTEXT_TEST_IMAGE"] else { throw XCTSkip("No local screen fixture supplied") }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let text = ComposerScreenRecognition.rows(try await ComposerScreenRecognition.recognize(image)).joined(separator: "\n")
        print("Screen recognition regression:\n" + text)
        for expected in ["TestClient", "01:00", "02:00", "Account Manager", "15.00", "50.00", "65.00"] {
            XCTAssertTrue(text.contains(expected), "Missing \(expected):\n\(text)")
        }
    }
}
