import XCTest
import CoreGraphics
import ImageIO
@testable import RipulAgent

final class ComposerScreenOptionsTests: XCTestCase {
    private func snapshot(text: String? = "Shift: 01:00–02:00", configuration: RipulScreenContextConfiguration = .init()) -> RipulScreenContextSnapshot {
        .init(appDescription: "Host app: WAC", instrumentedText: text,
              screenshotJPEG: Data([1, 2, 3]), accessibleFallback: "Fallback value", configuration: configuration)
    }
    func testAdaptiveDefaultsPreferInstrumentationOtherwiseImageNeverFallback() {
        XCTAssertEqual(snapshot().selected, [.instrumentedText])
        XCTAssertEqual(snapshot(text: nil).selected, [.screenshot])
        XCTAssertEqual(snapshot(text: nil, configuration: .init(available: [.fallbackText])).selected, [])
        XCTAssertFalse(snapshot(text: nil, configuration: .init(available: [.fallbackText])).canAttach)
        XCTAssertEqual(snapshot(configuration: .init(defaults: [.instrumentedText, .screenshot])).selected, [.instrumentedText, .screenshot])
    }
    func testOnlySelectedComponentsEnterTextAndImagePayloads() {
        var attachment = RipulContextAttachment(option: .currentScreen, content: "Host app: WAC")
        attachment.screen = snapshot()
        attachment.screen?.fallbackText = "Unselected fallback must stay local"
        let photo = ["id": "photo", "mediaType": "image/png", "data": "photo-data"]
        XCTAssertEqual(RipulContextAttachment.images([photo], attachments: [attachment]), [photo])
        XCTAssertTrue(attachment.selectedContent.contains("Shift:"))
        XCTAssertFalse(attachment.selectedContent.contains("Unselected fallback"))
        attachment.screen?.selected = [.screenshot]
        let images = RipulContextAttachment.images([photo], attachments: [attachment])
        XCTAssertEqual(images.count, 2)
        XCTAssertEqual(images[1]["mediaType"], "image/jpeg")
        XCTAssertEqual(images[1]["data"], Data([1, 2, 3]).base64EncodedString())
        XCTAssertFalse(attachment.selectedContent.contains("Shift:"))
        XCTAssertTrue(attachment.selectedContent.contains("attached as an image"))
        let message = RipulContextAttachment.message("Explain", attachments: [attachment])
        XCTAssertFalse(message.contains("AQID")) // image bytes never enter text context
        attachment.screen?.selected = []
        XCTAssertFalse(attachment.screen!.canAttach)
        XCTAssertNil(attachment.screenshotAttachment)
    }
    func testDeveloperAvailabilityIsEnforcedAndFallbackMustFinishBeforeAttach() {
        var item = snapshot(configuration: .init(available: [.instrumentedText], defaults: [.screenshot]))
        XCTAssertEqual(item.selected, [])
        item.selected = [.screenshot] // even programmatic mutation cannot enable a disabled component
        XCTAssertFalse(item.canAttach)
        XCTAssertFalse(item.selectedText.contains("attached as an image"))
        item = snapshot(configuration: .init(defaults: [.fallbackText]))
        XCTAssertFalse(item.canAttach)
        item.fallbackText = "Total £65"
        XCTAssertTrue(item.canAttach)
        XCTAssertTrue(item.selectedText.contains("Total £65"))
    }
    @MainActor
    func testEachSelectionCapturesAgainAndScreenshotDraftNeverPersists() async throws {
        var captures = 0
        var option = RipulComposerContext.shortcut(id: "test", title: "Screen", instructions: "unused")
        option.captureScreen = {
            captures += 1
            return self.snapshot(text: "Capture \(captures)")
        }
        let first = try await option.makeAttachment()
        let second = try await option.makeAttachment()
        XCTAssertEqual(captures, 2)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.screen?.instrumentedText, "Capture 1")
        XCTAssertEqual(second.screen?.instrumentedText, "Capture 2")
        let suite = "ScreenOptions." + UUID().uuidString
        let storage = UserDefaults(suiteName: suite)!
        defer { storage.removePersistentDomain(forName: suite) }
        var item = first; item.duration = .conversation
        let store = RipulComposerContextStore(storage: storage)
        store.attach(item, to: "chat")
        XCTAssertTrue(RipulComposerContextStore(storage: storage).attachments(for: "chat").isEmpty)
    }
    func testSimplifiedFallbackOmitsCoordinatesDuplicatesAndLowConfidenceNoise() {
        let items: [ComposerScreenText] = [
            .init(text: "Total £65", frame: CGRect(x: 0.1, y: 0.7, width: 0.5, height: 0.1)),
            .init(text: "Job: TestClient", frame: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.1)),
            .init(text: "Total £65", frame: CGRect(x: 0.1, y: 0.8, width: 0.5, height: 0.1)),
            .init(text: "v - ?", frame: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.1), confidence: 0.3)
        ]
        XCTAssertEqual(ComposerScreenRecognition.simpleText(items), "Job: TestClient\nTotal £65")
    }
    func testScreenshotEncodingProducesBoundedDecodableImage() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2000, height: 3000, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 2000, height: 3000))
        let data = try XCTUnwrap(ComposerScreenRecognition.jpeg(try XCTUnwrap(context.makeImage())))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.height, 1600)
        XCTAssertLessThan(data.count, 200_000)
    }
}
