#if os(iOS)
import XCTest
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
@testable import RipulAgent

@MainActor
final class ComposerPasteTests: XCTestCase {
    @MainActor private final class Model: ObservableObject {
        @Published var text = "Keep this draft"
        @Published var images: [NativeImageAttachment] = []
        let contexts = RipulComposerContextStore()
    }

    private struct Composer: View {
        @ObservedObject var model: Model
        var body: some View {
            NativeChatInput(text: $model.text, imageAttachments: $model.images,
                            selectedPhotos: .constant([]), isAgentRunning: false,
                            onSubmit: {}, contextStore: model.contexts)
                .frame(width: 370)
        }
    }

    private func image(size: CGSize = CGSize(width: 40, height: 20), scale: CGFloat = 1) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func editor(in view: UIView) -> ChatTextView? {
        if let editor = view as? ChatTextView { return editor }
        return view.subviews.lazy.compactMap { self.editor(in: $0) }.first
    }

    private func withComposer(_ check: (Model, ChatTextView) async throws -> Void) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let model = Model()
        let host = UIHostingController(rootView: Composer(model: model))
        window.rootViewController = host
        window.makeKeyAndVisible()
        let previousClipboard = UIPasteboard.general.items
        defer {
            UIPasteboard.general.items = previousClipboard
            window.endEditing(true)
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }
        try await Task.sleep(for: .milliseconds(300))
        let editor = try XCTUnwrap(editor(in: host.view))
        XCTAssertTrue(editor.becomeFirstResponder())
        try await check(model, editor)
    }

    func testImagePasteAppendsAttachmentsWithoutReplacingDraftOrSelection() async throws {
        try await withComposer { model, editor in
            let png = try XCTUnwrap(image().pngData())
            UIPasteboard.general.items = [
                [UTType.png.identifier: png, UTType.utf8PlainText.identifier: "photo metadata"],
                [UTType.png.identifier: png]
            ]
            let selection = NSRange(location: 5, length: 4)
            editor.selectedRange = selection
            XCTAssertTrue(editor.canPerformAction(#selector(UIResponderStandardEditActions.paste(_:)), withSender: nil))
            XCTAssertTrue(model.images.isEmpty, "Menu validation must not attach anything")
            editor.paste(nil)
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(model.images.count, 2)
            XCTAssertEqual(model.text, "Keep this draft")
            XCTAssertEqual(editor.text, model.text)
            XCTAssertEqual(editor.selectedRange, selection)
            XCTAssertTrue(editor.isFirstResponder)
            for attachment in model.images {
                XCTAssertEqual(attachment.toDictionary()["mediaType"], "image/jpeg")
                let data = try XCTUnwrap(Data(base64Encoded: attachment.data))
                XCTAssertEqual(Array(data.prefix(2)), [0xff, 0xd8])
                XCTAssertNotNil(UIImage(data: data))
            }
            editor.paste(nil)
            XCTAssertEqual(model.images.count, 4, "A second paste appends to existing attachments")
            XCTAssertEqual(Set(model.images.map(\.id)).count, 4)
        }
    }

    func testImageOnlyPasteAndOrdinaryTextPaste() async throws {
        try await withComposer { model, editor in
            editor.text = ""
            editor.delegate?.textViewDidChange?(editor)
            UIPasteboard.general.image = image()
            editor.paste(nil)
            XCTAssertEqual(model.images.count, 1)
            XCTAssertEqual(model.text, "")
            UIPasteboard.general.string = "A pasted caption"
            editor.paste(nil)
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(model.text, "A pasted caption")
            XCTAssertEqual(model.images.count, 1)
            editor.selectedRange = NSRange(location: 2, length: 6)
            UIPasteboard.general.string = "new"
            editor.paste(nil)
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(model.text, "A new caption")
            XCTAssertTrue(editor.isFirstResponder)
        }
    }

    func testClipboardMenuDoesNotEnablePasteForAnEmptyClipboard() async throws {
        try await withComposer { _, editor in
            UIPasteboard.general.items = []
            XCTAssertFalse(editor.canPerformAction(#selector(UIResponderStandardEditActions.paste(_:)), withSender: nil))
        }
    }

    func testRetinaAndRotatedPhotosRespectEncodedPixelLimit() throws {
        let oldLimit = PhotoAttachmentHelper.maxDimension
        PhotoAttachmentHelper.maxDimension = 800
        defer { PhotoAttachmentHelper.maxDimension = oldLimit }
        let source = image(size: CGSize(width: 600, height: 300), scale: 3)
        let rotated = UIImage(cgImage: try XCTUnwrap(source.cgImage), scale: 3, orientation: .right)
        for input in [source, rotated] {
            let attachment = try XCTUnwrap(PhotoAttachmentHelper.makeAttachment(from: input))
            let data = try XCTUnwrap(Data(base64Encoded: attachment.data))
            let decoded = try XCTUnwrap(UIImage(data: data))
            let pixels = try XCTUnwrap(decoded.cgImage)
            XCTAssertEqual(max(pixels.width, pixels.height), 800)
            XCTAssertEqual(min(pixels.width, pixels.height), 400)
            XCTAssertEqual(decoded.imageOrientation, .up)
            if input.imageOrientation == .right { XCTAssertGreaterThan(pixels.height, pixels.width) }
        }
    }
}
#endif
