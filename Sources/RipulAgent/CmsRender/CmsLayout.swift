import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Swift twin of resolveLayout.ts — maps the CMS layout vocabulary
/// (hug / fill / fixed, container frames, CSS-ish size values) onto SwiftUI.
enum CmsCss {
    /// Parse a CSS length ("12px", "12", "1rem") to points. Percentages and
    /// tokens return nil — callers fall back to natural sizing.
    static func points(_ value: String?) -> CGFloat? {
        guard var v = value?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
        var scale: CGFloat = 1
        if v.hasSuffix("px") { v = String(v.dropLast(2)) }
        else if v.hasSuffix("rem") { v = String(v.dropLast(3)); scale = 16 }
        else if v.hasSuffix("%") { return nil }
        guard let n = Double(v) else { return nil }
        return CGFloat(n) * scale
    }

    /// Parse CSS padding shorthand (1–4 values) into EdgeInsets.
    static func insets(_ value: String?) -> EdgeInsets? {
        guard let value, !value.isEmpty else { return nil }
        let parts = value.split(separator: " ").map { points(String($0)) ?? 0 }
        switch parts.count {
        case 1: return EdgeInsets(top: parts[0], leading: parts[0], bottom: parts[0], trailing: parts[0])
        case 2: return EdgeInsets(top: parts[0], leading: parts[1], bottom: parts[0], trailing: parts[1])
        case 3: return EdgeInsets(top: parts[0], leading: parts[1], bottom: parts[2], trailing: parts[1])
        case 4: return EdgeInsets(top: parts[0], leading: parts[3], bottom: parts[2], trailing: parts[1])
        default: return nil
        }
    }

    /// Parse #rgb/#rrggbb/#rrggbbaa hex colors. Theme tokens (`color.*`) and
    /// named CSS colors are not resolved natively yet — nil means "no paint".
    static func color(_ value: String?) -> Color? {
        guard var v = value?.trimmingCharacters(in: .whitespaces), v.hasPrefix("#") else { return nil }
        v.removeFirst()
        if v.count == 3 { v = v.map { "\($0)\($0)" }.joined() }
        guard v.count == 6 || v.count == 8, let bits = UInt64(v, radix: 16) else { return nil }
        let hasAlpha = v.count == 8
        let r = Double((bits >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = Double((bits >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = Double((bits >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? Double(bits & 0xFF) / 255 : 1
        return Color(red: r, green: g, blue: b, opacity: a)
    }

    /// Perceived-luminance lightness test (shared by contrastText and the
    /// month calendar's light/dark rendering choice).
    static func isLight(_ color: Color) -> Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if canImport(UIKit)
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        #else
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return false }
        srgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        return 0.299 * r + 0.587 * g + 0.114 * b > 0.6
    }

    /// Twin of MUI's getContrastText: near-black text on light fills,
    /// white on dark — so an authored light accent stays legible.
    static func contrastText(on color: Color) -> Color {
        isLight(color) ? Color(white: 0, opacity: 0.87) : .white
    }
}

/// Applies a block's `frame` (BlockFrame): hug/fill/fixed sizing plus
/// padding, background, border and corner radius.
struct CmsBlockFrameModifier: ViewModifier {
    let frame: CmsBlockFrame?
    /// Main axis of the containing stack — fill/fixed act along this axis.
    let axis: Axis
    /// Colour resolver (theme tokens + CSS literals). Defaults to CSS-only.
    var resolve: (String?) -> Color? = { CmsCss.color($0) }

    func body(content: Content) -> some View {
        var fixedLength: CGFloat? = nil
        if frame?.size == "fixed" {
            fixedLength = CmsCss.points(frame?.fixedValue)
        }
        let fill = frame?.size == "fill"
        let width = CmsCss.points(frame?.width)
        let radius = CmsCss.points(frame?.borderRadius) ?? 0
        let borderWidth = CmsCss.points(frame?.borderWidth) ?? 0
        let borderColor = resolve(frame?.borderColor)

        return content
            .padding(CmsCss.insets(frame?.padding) ?? EdgeInsets())
            .frame(
                width: axis == .horizontal ? fixedLength : width,
                height: axis == .vertical ? fixedLength : nil
            )
            .frame(
                maxWidth: (fill && axis == .horizontal) ? .infinity : nil,
                maxHeight: (fill && axis == .vertical) ? .infinity : nil
            )
            .frame(minHeight: CmsCss.points(frame?.minHeight))
            .background(resolve(frame?.background) ?? Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(borderColor ?? Color.clear, lineWidth: borderWidth)
            )
            .padding(CmsCss.insets(frame?.margin) ?? EdgeInsets())
    }
}

/// Applies a container's `frame` (ContainerFrame): padding, background,
/// border, max-width centring (non-full-bleed pages).
struct CmsContainerFrameModifier: ViewModifier {
    let frame: CmsContainerFrame?
    /// Colour resolver (theme tokens + CSS literals). Defaults to CSS-only.
    var resolve: (String?) -> Color? = { CmsCss.color($0) }

    func body(content: Content) -> some View {
        let radius = CmsCss.points(frame?.borderRadius) ?? 0
        let borderWidth = CmsCss.points(frame?.borderWidth) ?? 0
        let borderColor = resolve(frame?.borderColor)

        return content
            .padding(CmsCss.insets(frame?.padding) ?? EdgeInsets())
            .frame(maxWidth: CmsCss.points(frame?.maxWidth))
            .frame(minHeight: CmsCss.points(frame?.minHeight))
            .background(resolve(frame?.background) ?? Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(borderColor ?? Color.clear, lineWidth: borderWidth)
            )
    }
}

extension CmsContainerFrame {
    var stackAxis: Axis { direction == "row" ? .horizontal : .vertical }

    var gapPoints: CGFloat { CmsCss.points(gap) ?? 16 }

    var horizontalAlignment: HorizontalAlignment {
        switch alignItems {
        case "center": return .center
        case "flex-end": return .trailing
        default: return .leading
        }
    }

    var verticalAlignment: VerticalAlignment {
        switch alignItems {
        case "center": return .center
        case "flex-end": return .bottom
        default: return .top
        }
    }
}
