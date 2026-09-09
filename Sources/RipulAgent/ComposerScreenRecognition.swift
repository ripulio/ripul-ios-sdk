import Foundation
import Vision
import CoreGraphics

/// Top-left normalized rectangles keep observations useful across device sizes.
struct ComposerScreenText {
    var text: String
    var frame: CGRect
    var confidence: Float = 1
}

/// Shared by capture and regression tests. Vision runs off the UI thread.
enum ComposerScreenRecognition {
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
