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

    private static func makeAttachment(from data: Data) -> NativeImageAttachment? {
        let id = "img_\(Int(Date().timeIntervalSince1970 * 1000))_\(Int.random(in: 0..<100000))"

        #if os(iOS)
        guard let uiImage = UIImage(data: data) else { return nil }
        let jpeg = uiImage.jpegData(compressionQuality: 0.8) ?? data
        let base64 = jpeg.base64EncodedString()
        return NativeImageAttachment(id: id, mediaType: "image/jpeg", data: base64, thumbnail: uiImage)
        #elseif os(macOS)
        guard let nsImage = NSImage(data: data) else { return nil }
        let tiffData = nsImage.tiffRepresentation
        let bitmap = tiffData.flatMap { NSBitmapImageRep(data: $0) }
        let jpeg = bitmap?.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) ?? data
        let base64 = jpeg.base64EncodedString()
        return NativeImageAttachment(id: id, mediaType: "image/jpeg", data: base64, thumbnail: nsImage)
        #endif
    }
}
