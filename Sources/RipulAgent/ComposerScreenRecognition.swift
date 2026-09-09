import Foundation
import Vision
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Top-left normalized rectangles keep observations useful across device sizes.
struct ComposerScreenText {
    var text: String
    var frame: CGRect
    var confidence: Float = 1
}

/// Shared by capture and regression tests. Vision runs off the UI thread.
enum ComposerScreenRecognition {
    static func jpeg(_ image: CGImage) -> Data? {
        let scale = min(1, 1600 / CGFloat(max(image.width, image.height)))
        let width = max(1, Int(CGFloat(image.width) * scale)), height = max(1, Int(CGFloat(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let resized = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, resized, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Short reading-order text; no coordinates, technical roles or duplicated extraction layers.
    static func simpleText(_ items: [ComposerScreenText]) -> String {
        var seen = Set<String>()
        return items.sorted { $0.frame.minY < $1.frame.minY }.compactMap { item -> String? in
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count > 1, item.confidence >= 0.5, seen.insert(text).inserted else { return nil }
            return String(text.prefix(200))
        }.prefix(35).joined(separator: "\n")
    }

    static func recognize(_ image: CGImage) async throws -> [ComposerScreenText] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = false // Preserve names, amounts and dates verbatim.
                    request.automaticallyDetectsLanguage = true
                    request.minimumTextHeight = 0.005
                    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                    let items = (request.results ?? []).compactMap { observation -> ComposerScreenText? in
                        guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.25 else { return nil }
                        let box = observation.boundingBox
                        return ComposerScreenText(text: candidate.string,
                            frame: CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height),
                            confidence: candidate.confidence)
                    }
                    continuation.resume(returning: items)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    static func overlaps(_ frame: CGRect, regions: [CGRect]) -> Bool {
        regions.contains { region in
            let intersection = frame.intersection(region)
            return !intersection.isNull && intersection.width * intersection.height > 0
        }
    }

    /// Spatially grouped rows keep side-by-side labels/values together without inventing
    /// semantic relationships. Positions disambiguate multi-column forms and repeated values.
    static func rows(_ items: [ComposerScreenText], excluding regions: [CGRect] = []) -> [String] {
        let sorted = items.filter { !overlaps($0.frame, regions: regions) && !$0.text.isEmpty }
            .sorted { $0.frame.midY < $1.frame.midY }
        var rows: [[ComposerScreenText]] = []
        for item in sorted {
            if let last = rows.last, let anchor = last.first,
               abs(anchor.frame.midY - item.frame.midY) <= min(anchor.frame.height, item.frame.height) * 0.55 {
                rows[rows.count - 1].append(item)
            } else { rows.append([item]) }
        }
        return rows.prefix(100).map { row in
            let ordered = row.sorted { $0.frame.minX < $1.frame.minX }
            let y = Int((ordered[0].frame.midY * 100).rounded())
            return "[y=\(y)%] " + ordered.map {
                "[x=\(Int(($0.frame.minX * 100).rounded()))%] \(String($0.text.prefix(500)))\($0.confidence < 0.5 ? " (uncertain reading)" : "")"
            }.joined(separator: " | ")
        }
    }
}
