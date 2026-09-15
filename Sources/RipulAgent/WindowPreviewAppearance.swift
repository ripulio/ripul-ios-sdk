import Foundation
import CoreGraphics

/// Optional appearance of a known app surface, paired with the crop that produced it.
struct WindowPreviewAppearance: Equatable {
    let cropPresetId: String
    let cornerRadiusFraction: CGFloat

    init?(_ value: Any?) {
        guard let value = value as? [String: Any],
              let preset = value["cropPresetId"] as? String, !preset.isEmpty,
              let fraction = value["cornerRadiusFraction"] as? Double,
              fraction.isFinite, (0...0.5).contains(fraction) else { return nil }
        cropPresetId = preset
        cornerRadiusFraction = fraction
    }

    func cornerRadius(for size: CGSize) -> CGFloat {
        min(size.width, size.height) * cornerRadiusFraction
    }
}
