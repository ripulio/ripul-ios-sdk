import SwiftUI

#if canImport(PhotosUI)
import PhotosUI
#endif

#if os(iOS)
import UIKit
import UniformTypeIdentifiers
#elseif os(macOS)
import AppKit
#endif

/// Converts PhotosPickerItem selections into NativeImageAttachment models.
@available(iOS 16.0, macOS 14.0, *)
public enum PhotoAttachmentHelper {

    /// Process selected photo items into image attachments with JPEG base64 data.
    public static func process(_ items: [PhotosPickerItem]) async -> [NativeImageAttachment] {
        var result: [NativeImageAttachment] = []
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            if let attachment = makeAttachment(from: data) {
                result.append(attachment)
            }
        }
        return result
    }

    /// Max dimension (longest edge) for images. Configurable from the native
    /// settings screen. 1568px is as much as Claude reads before resizing, so
    /// small text in a screenshot stays legible. The page uploads the image
    /// and the relay carries only its link; inline, as when the upload fails
    /// or in a Mac-local chat, an iPhone screenshot measured 100KB of base64
    /// at this size (26KB at the old 800px), so four stay under the 1MB limits.
    public static var maxDimension: CGFloat = 1568

    /// JPEG compression quality (0.0–1.0), as the camera already used.
    public static var compressionQuality: CGFloat = 0.7

    static func makeAttachment(from data: Data) -> NativeImageAttachment? {
        #if os(iOS)
        guard let uiImage = UIImage(data: data) else { return nil }
        return makeAttachment(from: uiImage)
        #elseif os(macOS)
        let id = "img_\(Int(Date().timeIntervalSince1970 * 1000))_\(Int.random(in: 0..<100000))"
        guard let nsImage = NSImage(data: data) else { return nil }
        let resized = downsampleMac(nsImage, maxDimension: maxDimension)
        let tiffData = resized.tiffRepresentation
        let bitmap = tiffData.flatMap { NSBitmapImageRep(data: $0) }
        let jpeg = bitmap?.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality]) ?? data
        let base64 = jpeg.base64EncodedString()
        return NativeImageAttachment(id: id, mediaType: "image/jpeg", data: base64, thumbnail: resized)
        #endif
    }

    #if os(iOS)
    /// Clipboard images use exactly the same normalization as Photos selections.
    static func makeAttachment(from image: UIImage) -> NativeImageAttachment? {
        let resized = downsample(image, maxDimension: maxDimension)
        guard let jpeg = resized.jpegData(compressionQuality: compressionQuality) else { return nil }
        return NativeImageAttachment(id: "img_\(UUID().uuidString)", mediaType: "image/jpeg",
                                     data: jpeg.base64EncodedString(), thumbnail: resized)
    }

    /// Items dropped on the composer (Finder files, Photos, a browser's
    /// images) become attachments: images with the same normalization as
    /// Photos selections, other files by FileAttachmentHelper's rules.
    /// `refused` says, for each item left out, why.
    static func process(dropped providers: [NSItemProvider]) async -> (attachments: [NativeImageAttachment], refused: [String]) {
        var attachments: [NativeImageAttachment] = []
        var refused: [String] = []
        for provider in providers {
            if let data = await loadImageData(provider), let attachment = makeAttachment(from: data) {
                attachments.append(attachment)
            } else if let url = await loadFileURL(provider) {
                do {
                    attachments.append(try FileAttachmentHelper.attachment(fromFileAt: url))
                } catch {
                    refused.append(error.localizedDescription)
                }
            } else {
                refused.append("\(provider.suggestedName ?? "An item") isn't a file or an image.")
            }
        }
        return (attachments, refused)
    }

    /// The provider's own image representation, if it offers one.
    private static func loadImageData(_ provider: NSItemProvider) async -> Data? {
        guard let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    /// The file a dropped item stands for, when it offers one.
    private static func loadFileURL(_ provider: NSItemProvider) async -> URL? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }

    /// Public entry point for camera capture path in NativeChatInput.
    public static func downsamplePublic(_ image: UIImage) -> UIImage {
        return downsample(image, maxDimension: maxDimension)
    }

    private static func downsample(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let pixelSize = CGSize(width: size.width * image.scale, height: size.height * image.scale)
        let scale = min(maxDimension / max(pixelSize.width, pixelSize.height), 1.0)
        if scale >= 1.0 && image.imageOrientation == .up { return image }
        let newSize = CGSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1 // The relay limit is in pixels, independent of display scale.
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
    #elseif os(macOS)
    private static func downsampleMac(_ image: NSImage, maxDimension: CGFloat) -> NSImage {
        let size = image.size
        let scale = min(maxDimension / max(size.width, size.height), 1.0)
        if scale >= 1.0 { return image }
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let newImage = NSImage(size: newSize)
        newImage.lockFocus()
        image.draw(in: CGRect(origin: .zero, size: newSize),
                   from: CGRect(origin: .zero, size: size),
                   operation: .copy,
                   fraction: 1.0)
        newImage.unlockFocus()
        return newImage
    }
    #endif
}
