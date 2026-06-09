import SwiftUI

#if canImport(PhotosUI)
import PhotosUI
#endif

#if os(iOS)
import UIKit
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

    /// Max dimension (longest edge) for images sent through the relay WebSocket.
    /// Configurable from the native settings screen. Default 800px produces
    /// ~40-100KB JPEG base64, well within the Cloudflare DO ~1MB WS limit.
    /// Claude API auto-resizes above 1568px (2576px for Opus 4.7).
    public static var maxDimension: CGFloat = 800

    /// JPEG compression quality (0.0–1.0). Lower values reduce size at the
    /// cost of detail. Default 0.5 balances relay size and readability.
    public static var compressionQuality: CGFloat = 0.5

    private static func makeAttachment(from data: Data) -> NativeImageAttachment? {
        let id = "img_\(Int(Date().timeIntervalSince1970 * 1000))_\(Int.random(in: 0..<100000))"

        #if os(iOS)
        guard let uiImage = UIImage(data: data) else { return nil }
        let resized = downsample(uiImage, maxDimension: maxDimension)
        let jpeg = resized.jpegData(compressionQuality: compressionQuality) ?? data
        let base64 = jpeg.base64EncodedString()
        return NativeImageAttachment(id: id, mediaType: "image/jpeg", data: base64, thumbnail: resized)
        #elseif os(macOS)
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
    /// Public entry point for camera capture path in NativeChatInput.
    public static func downsamplePublic(_ image: UIImage) -> UIImage {
        return downsample(image, maxDimension: maxDimension)
    }

    private static func downsample(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let scale = min(maxDimension / max(size.width, size.height), 1.0)
        if scale >= 1.0 { return image }
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
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
