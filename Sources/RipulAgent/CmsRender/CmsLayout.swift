import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Swift twin of resolveLayout.ts — maps the CMS layout vocabulary
/// (hug / fill / fixed, container frames, CSS-ish size values) onto SwiftUI.
enum CmsCss {
    /// SPACING_SCALE in spacingTokens.ts.
    static let spacingScale: [String: CGFloat] = [
        "spacing.xs": 0.5, "spacing.sm": 1, "spacing.md": 2, "spacing.lg": 3, "spacing.xl": 6,
    ]

    /// Parse a CSS length ("12px", "12", "1rem", "spacing.md") to points.
    /// Percentages and other tokens return nil — callers fall back to
    /// natural sizing.
    static func points(_ value: String?) -> CGFloat? {
        guard var v = value?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
        // Spacing tokens (spacingTokens.ts) resolve through theme.spacing (8).
        if let multiple = spacingScale[v] { return multiple * 8 }
        var scale: CGFloat = 1
        if v.hasSuffix("px") { v = String(v.dropLast(2)) }
        else if v.hasSuffix("rem") { v = String(v.dropLast(3)); scale = 16 }
        else if v.hasSuffix("%") { return nil }
        guard let n = Double(v) else { return nil }
        return CGFloat(n) * scale
    }

    /// Parse CSS padding shorthand (1–4 values) into EdgeInsets. Each value may
    /// be a length, a spacing token, or a CSS expression (`max(24px, calc(50% - 580px))`)
    /// read at `width` (percentages are of it).
    static func insets(_ value: String?, width: CGFloat = 390) -> EdgeInsets? {
        guard let value, !value.isEmpty else { return nil }
        let parts = topLevelParts(value).map { points($0) ?? CmsCssLength.points($0, viewport: width, percentOf: width) ?? 0 }
        switch parts.count {
        case 1: return EdgeInsets(top: parts[0], leading: parts[0], bottom: parts[0], trailing: parts[0])
        case 2: return EdgeInsets(top: parts[0], leading: parts[1], bottom: parts[0], trailing: parts[1])
        case 3: return EdgeInsets(top: parts[0], leading: parts[1], bottom: parts[2], trailing: parts[1])
        case 4: return EdgeInsets(top: parts[0], leading: parts[3], bottom: parts[2], trailing: parts[1])
        default: return nil
        }
    }

    /// A CSS value list split at its top-level spaces, so `max(24px, calc(50% - 580px))` stays one part.
    static func topLevelParts(_ value: String) -> [String] {
        var parts: [String] = [], current = "", depth = 0
        for ch in value {
            if ch == "(" { depth += 1 } else if ch == ")" { depth = max(0, depth - 1) }
            if ch == " " && depth == 0 {
                if !current.isEmpty { parts.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    /// Parse #rgb/#rrggbb/#rrggbbaa hex and rgb()/rgba() colours. Theme
    /// tokens (`color.*`) resolve through `CmsPortalTheme`; named CSS colours
    /// are not resolved natively yet — nil means "no paint".
    static func color(_ value: String?) -> Color? {
        rgba(value)?.color
    }

    /// Components of a hex or rgb()/rgba() colour (0…1). Shared by `color`
    /// and the theme's MUI colour maths (darken / alpha / contrast).
    static func rgba(_ value: String?) -> CmsRGBA? {
        guard let raw = value?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if raw.hasPrefix("#") {
            var v = String(raw.dropFirst())
            if v.count == 3 || v.count == 4 { v = v.map { "\($0)\($0)" }.joined() }
            guard v.count == 6 || v.count == 8, let bits = UInt64(v, radix: 16) else { return nil }
            let hasAlpha = v.count == 8
            let r = Double((bits >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
            let g = Double((bits >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
            let b = Double((bits >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
            let a = hasAlpha ? Double(bits & 0xFF) / 255 : 1
            return CmsRGBA(r: r, g: g, b: b, a: a)
        }
        let lower = raw.lowercased()
        guard lower.hasPrefix("rgb"), let open = lower.firstIndex(of: "("), lower.hasSuffix(")") else { return nil }
        let inner = lower[lower.index(after: open)..<lower.index(before: lower.endIndex)]
        let parts = inner
            .replacingOccurrences(of: "/", with: " ")
            .split(whereSeparator: { $0 == "," || $0 == " " })
            .map(String.init)
        guard parts.count == 3 || parts.count == 4 else { return nil }
        func channel(_ s: String) -> Double? {
            if s.hasSuffix("%") { return Double(s.dropLast()).map { $0 / 100 } }
            return Double(s).map { $0 / 255 }
        }
        guard let r = channel(parts[0]), let g = channel(parts[1]), let b = channel(parts[2]) else { return nil }
        var a = 1.0
        if parts.count == 4 {
            let s = parts[3]
            guard let parsed = s.hasSuffix("%") ? Double(s.dropLast()).map({ $0 / 100 }) : Double(s) else { return nil }
            a = parsed
        }
        return CmsRGBA(r: min(max(r, 0), 1), g: min(max(g, 0), 1), b: min(max(b, 0), 1), a: min(max(a, 0), 1))
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
    /// Background fill resolver — `color.gradient` paints the brand
    /// gradient. Defaults to the colour resolver.
    var fill: ((String?) -> AnyShapeStyle?)? = nil
    /// Radius resolver (`radius.*` tokens + CSS lengths). Defaults to CSS-only.
    var radius: (String?) -> CGFloat? = { CmsCss.points($0) }
    /// A bleeding block: its corners at the screen's edges square, and its
    /// surface runs under the status bar with the content kept below it.
    @Environment(\.cmsBleed) private var bleed
    /// `overlap`: the frame's own fill grows at the bottom when it has one.
    @Environment(\.cmsOverlap) private var overlap

    func body(content: Content) -> some View {
        var fixedLength: CGFloat? = nil
        if frame?.size == "fixed" {
            fixedLength = CmsCss.points(frame?.fixedValue)
        }
        let fill = frame?.size == "fill"
        let width = CmsCss.points(frame?.width)
        let radius = self.radius(frame?.borderRadius) ?? 0
        let borderWidth = CmsCss.points(frame?.borderWidth) ?? 0
        let borderColor = resolve(frame?.borderColor)
        let background = (self.fill ?? { resolve($0).map { AnyShapeStyle($0) } })(frame?.background)
            ?? AnyShapeStyle(Color.clear)

        let shape = bleed.map { AnyShape($0.shape(radius: radius)) }
            ?? AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        // Under the status bar, the room goes to whichever surface draws: the
        // frame's own fill when it has one, else the block's (a card, a calendar).
        let framePaints = frame?.background != nil
        var inner = bleed
        if framePaints { inner?.underTop = 0 }
        return content
            .environment(\.cmsBleed, inner)
            .environment(\.cmsOverlap, framePaints ? 0 : overlap)
            .padding(CmsCss.insets(frame?.padding, width: CmsSiteText.viewportWidth) ?? EdgeInsets())
            .padding(.top, framePaints ? bleed?.underTop ?? 0 : 0)
            .padding(.bottom, framePaints ? overlap : 0)
            .frame(
                width: axis == .horizontal ? fixedLength : width,
                height: axis == .vertical ? fixedLength : nil
            )
            .frame(
                maxWidth: (fill && axis == .horizontal) || bleed != nil ? .infinity : nil,
                maxHeight: (fill && axis == .vertical) ? .infinity : nil
            )
            .frame(minHeight: CmsCss.points(frame?.minHeight)
                   ?? CmsCssLength.points(frame?.minHeight, viewport: CmsSiteText.viewportWidth))
            .background(background)
            .background {
                // A gradient over a picture (the web's `linear-gradient(…), url(…) center / cover`).
                if let layered = CmsCssBackground(frame?.background) { CmsCssBackgroundView(background: layered, resolve: resolve) }
            }
            .clipShape(shape)
            .overlay(shape.stroke(borderColor ?? Color.clear, lineWidth: borderWidth))
            // `align`: a block narrower than its column sits at its centre or end (the web's align-self).
            .frame(maxWidth: Self.alignment(frame?.align) == nil ? nil : .infinity,
                   alignment: Self.alignment(frame?.align) ?? .leading)
            .padding(CmsCss.insets(frame?.margin, width: CmsSiteText.viewportWidth) ?? EdgeInsets())
    }

    static func alignment(_ align: String?) -> Alignment? {
        switch align {
        case "center": return .center
        case "end", "right", "flex-end": return .trailing
        default: return nil
        }
    }
}

/// Children side by side, wrapping onto the next line when the next one doesn't
/// fit: a CSS flex row with `flex-wrap: wrap`. Each child is offered the whole
/// width, so a line of text keeps one line when it can.
struct CmsFlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for (index, size) in row.items {
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var items: [(Int, CGSize)] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [], row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
            let needed = row.items.isEmpty ? size.width : row.width + spacing + size.width
            if !row.items.isEmpty && needed > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append((index, size))
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}

/// Applies a container's `frame` (ContainerFrame): padding, background,
/// border, max-width centring (non-full-bleed pages).
struct CmsContainerFrameModifier: ViewModifier {
    let frame: CmsContainerFrame?
    /// Colour resolver (theme tokens + CSS literals). Defaults to CSS-only.
    var resolve: (String?) -> Color? = { CmsCss.color($0) }
    /// Background fill resolver — `color.gradient` paints the brand
    /// gradient. Defaults to the colour resolver.
    var fill: ((String?) -> AnyShapeStyle?)? = nil
    /// Radius resolver (`radius.*` tokens + CSS lengths). Defaults to CSS-only.
    var radius: (String?) -> CGFloat? = { CmsCss.points($0) }

    func body(content: Content) -> some View {
        let radius = self.radius(frame?.borderRadius) ?? 0
        let borderWidth = CmsCss.points(frame?.borderWidth) ?? 0
        let borderColor = resolve(frame?.borderColor)
        let background = (self.fill ?? { resolve($0).map { AnyShapeStyle($0) } })(frame?.background)
            ?? AnyShapeStyle(Color.clear)

        return content
            .padding(CmsCss.insets(frame?.padding, width: CmsSiteText.viewportWidth) ?? EdgeInsets())
            .frame(maxWidth: CmsCss.points(frame?.maxWidth))
            .frame(minHeight: CmsCss.points(frame?.minHeight))
            .background(background)
            // Only rounded corners clip: a square container clipping its
            // children cut off a block that bleeds past it (and shadows).
            .modifier(CmsClipWhenRounded(radius: radius))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(borderColor ?? Color.clear, lineWidth: borderWidth)
            )
    }
}

struct CmsClipWhenRounded: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View {
        if radius > 0 {
            content.clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            content
        }
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

/// A CSS `background` with layers, as a site's frame may set it:
/// `linear-gradient(rgba(…), rgba(…)), url('…') center / cover no-repeat`.
/// Layers paint in CSS order: the first on top. Colour-only values stay with the
/// frame's ordinary fill; this handles gradients and pictures.
struct CmsCssBackground: Equatable {
    enum Layer: Equatable {
        /// Stops top to bottom, or along `angle` (CSS degrees).
        case gradient(stops: [String], angle: Double)
        case image(url: String, contain: Bool)
        case colour(String)
    }

    var layers: [Layer]

    /// Nil unless the value has a gradient or a picture.
    init?(_ css: String?) {
        guard let css, css.contains("gradient(") || css.contains("url(") else { return nil }
        layers = Self.split(css, on: ",").compactMap(Self.layer)
        if layers.isEmpty { return nil }
    }

    /// Top-level split, ignoring separators inside parentheses and quotes.
    static func split(_ s: String, on sep: Character) -> [String] {
        var out: [String] = [], cur = "", depth = 0, quote: Character?
        for ch in s {
            if let q = quote { cur.append(ch); if ch == q { quote = nil }; continue }
            if ch == "'" || ch == "\"" { quote = ch; cur.append(ch); continue }
            if ch == "(" { depth += 1 } else if ch == ")" { depth = max(0, depth - 1) }
            if ch == sep && depth == 0 { out.append(cur.trimmingCharacters(in: .whitespaces)); cur = "" } else { cur.append(ch) }
        }
        let last = cur.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { out.append(last) }
        return out
    }

    private static func inner(_ s: String, after prefix: String) -> String? {
        guard let start = s.range(of: prefix) else { return nil }
        var depth = 1, out = ""
        for ch in s[start.upperBound...] {
            if ch == "(" { depth += 1 } else if ch == ")" { depth -= 1; if depth == 0 { return out } }
            out.append(ch)
        }
        return nil
    }

    private static func layer(_ raw: String) -> Layer? {
        if let body = inner(raw, after: "linear-gradient(") {
            var parts = split(body, on: ",")
            var angle = 180.0
            if let first = parts.first {
                if first.hasSuffix("deg"), let a = Double(first.dropLast(3)) { angle = a; parts.removeFirst() }
                else if first.hasPrefix("to ") {
                    let dirs: [String: Double] = ["to top": 0, "to right": 90, "to bottom": 180, "to left": 270]
                    angle = dirs[first] ?? 180
                    parts.removeFirst()
                }
            }
            // A stop's colour, without its position.
            let stops = parts.map { stop -> String in
                if stop.hasPrefix("rgb") || stop.hasPrefix("hsl"), let close = stop.firstIndex(of: ")") { return String(stop[...close]) }
                return String(stop.split(separator: " ").first ?? "")
            }
            return stops.count >= 2 ? .gradient(stops: stops, angle: angle) : nil
        }
        if let body = inner(raw, after: "url(") {
            let url = body.trimmingCharacters(in: CharacterSet(charactersIn: "'\" "))
            return url.isEmpty ? nil : .image(url: url, contain: raw.contains("contain"))
        }
        return raw.isEmpty ? nil : .colour(raw)
    }
}

/// Paints a CmsCssBackground: each layer filling the frame, the first on top.
struct CmsCssBackgroundView: View {
    let background: CmsCssBackground
    let resolve: (String?) -> Color?

    var body: some View {
        ZStack {
            ForEach(Array(background.layers.enumerated().reversed()), id: \.offset) { _, layer in
                switch layer {
                case .gradient(let stops, let angle):
                    let points = CmsPortalTheme.gradientPoints(angle: angle)
                    LinearGradient(colors: stops.map { resolve($0) ?? .clear }, startPoint: points.start, endPoint: points.end)
                case .image(let url, let contain):
                    Color.clear.overlay {
                        CmsChainImage(candidates: [.url(url)], fit: contain ? "contain" : "cover", requestSize: 1600)
                    }
                    .clipped()
                case .colour(let value):
                    resolve(value) ?? .clear
                }
            }
        }
        .accessibilityHidden(true)
    }
}
