import CoreGraphics
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Where an SF Symbol's drawing ends inside its image.
///
/// A symbol's image carries blank space beside what it draws. On the right:
/// 1.5 points for server.rack at 12 points and 1.75 for person.2.fill at 11
/// (measured 23 October 2026). Set against an edge, the image reaches the
/// edge and the drawing stops that far short of it, so icons under text set
/// against the same edge ended up to a point short of the text (Peter's
/// phone, the session list's times and icons, that day).
enum SymbolInk {
    /// The blank on the trailing side of what `name` draws at `pointSize`
    /// (regular weight), in points. Measured once for each symbol and size.
    @MainActor
    static func trailingBlank(_ name: String, pointSize: CGFloat, layoutDirection: LayoutDirection) -> CGFloat {
        let key = "\(name) \(pointSize)"
        let sides = measured[key] ?? {
            #if os(iOS)
            let image = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: .regular))
            #else
            let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular))
            #endif
            let sides = image.map(blanks(of:)) ?? (0, 0)
            measured[key] = sides
            return sides
        }()
        return layoutDirection == .rightToLeft ? sides.left : sides.right
    }

    @MainActor private static var measured: [String: (left: CGFloat, right: CGFloat)] = [:]

    /// The blank left and right of what `image` draws, in points: drawn at four
    /// times its size, the columns at each side with nothing half opaque.
    static func blanks(of image: PlatformImage) -> (left: CGFloat, right: CGFloat) {
        let scale: CGFloat = 4
        let width = Int((image.size.width * scale).rounded(.up)), height = Int((image.size.height * scale).rounded(.up))
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return (0, 0) }
        context.scaleBy(x: scale, y: scale)
        // Upside down in this context, which leaves its left and right alone.
        #if os(iOS)
        UIGraphicsPushContext(context)
        image.withTintColor(.black, renderingMode: .alwaysOriginal).draw(in: CGRect(origin: .zero, size: image.size))  // theme-exempt: measured, only its alpha is read
        UIGraphicsPopContext()
        #else
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: CGRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        #endif
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        func inked(_ x: Int) -> Bool { (0..<height).contains { pixels[($0 * width + x) * 4 + 3] >= 128 } }
        guard let first = (0..<width).first(where: inked),
              let last = (0..<width).reversed().first(where: inked) else { return (0, 0) }
        return (CGFloat(first) / scale, CGFloat(width - 1 - last) / scale)
    }
}
