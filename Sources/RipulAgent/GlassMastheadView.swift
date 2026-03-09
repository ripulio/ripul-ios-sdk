import SwiftUI

/// A glassy lozenge masthead that displays text and/or an image.
/// Uses Liquid Glass on iOS 26+ and ultraThinMaterial on older versions.
@available(iOS 15.0, macOS 13.0, *)
public struct GlassMastheadView: View {
    public let config: MastheadConfig

    public init(config: MastheadConfig) {
        self.config = config
    }

    private var resolvedHeight: CGFloat { config.height ?? 48 }
    private var resolvedFontSize: CGFloat { config.fontSize ?? 17 }

    /// Parse imageWidth CSS value (e.g. "120px", "80") into a CGFloat.
    private var resolvedImageWidth: CGFloat? {
        guard let raw = config.imageWidth else { return nil }
        let numeric = raw.replacingOccurrences(of: "px", with: "")
            .replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespaces)
        return Double(numeric).map { CGFloat($0) }
    }

    public var body: some View {
        HStack(spacing: 10) {
            if let imageUrl = config.imageUrl, let url = URL(string: imageUrl) {
                let imgHeight = resolvedHeight - 12
                let imgWidth = resolvedImageWidth ?? imgHeight * 3 // default: 3:1 aspect ratio
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: imgWidth, maxHeight: imgHeight)
                    case .failure(let error):
                        let _ = NSLog("[GlassMastheadView] Image load failed for %@: %@",
                                      imageUrl, error.localizedDescription)
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                            .frame(width: imgWidth, height: imgHeight)
                    case .empty:
                        ProgressView()
                            .frame(width: imgWidth, height: imgHeight)
                    @unknown default:
                        EmptyView()
                    }
                }
                .frame(width: imgWidth, height: imgHeight)
            }

            if let text = config.text {
                Text(text)
                    .font(.system(size: resolvedFontSize, weight: .semibold))
                    .foregroundStyle(Color(cssHex: config.textColor) ?? .primary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(minHeight: resolvedHeight)
        .modifier(GlassCapsuleModifier(tintColor: Color(cssHex: config.backgroundColor)))
    }
}

// MARK: - Glass Capsule Modifier

@available(iOS 15.0, macOS 13.0, *)
struct GlassCapsuleModifier: ViewModifier {
    let tintColor: Color?

    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            content
                .background(tintColor?.opacity(0.3) ?? .clear)
                .glassEffect(.regular, in: .capsule)
        } else {
            content
                .background(
                    ZStack {
                        if let tintColor {
                            Capsule().fill(tintColor.opacity(0.2))
                        }
                    }
                )
                .background(.ultraThinMaterial, in: Capsule())
        }
        #else
        content
            .background(
                ZStack {
                    if let tintColor {
                        Capsule().fill(tintColor.opacity(0.2))
                    }
                }
            )
            .background(.ultraThinMaterial, in: Capsule())
        #endif
    }
}

// MARK: - CSS Hex Color Parsing

extension Color {
    /// Parse a CSS hex colour string (#RGB, #RRGGBB, or #RRGGBBAA) into a SwiftUI Color.
    /// Returns nil for unrecognised formats.
    init?(cssHex hex: String?) {
        guard let hex, hex.hasPrefix("#") else { return nil }
        let stripped = String(hex.dropFirst())
        let scanner = Scanner(string: stripped)
        var rgb: UInt64 = 0
        guard scanner.scanHexInt64(&rgb) else { return nil }

        switch stripped.count {
        case 3: // #RGB
            let r = Double((rgb >> 8) & 0xF) / 15.0
            let g = Double((rgb >> 4) & 0xF) / 15.0
            let b = Double(rgb & 0xF) / 15.0
            self.init(red: r, green: g, blue: b)
        case 6: // #RRGGBB
            let r = Double((rgb >> 16) & 0xFF) / 255.0
            let g = Double((rgb >> 8) & 0xFF) / 255.0
            let b = Double(rgb & 0xFF) / 255.0
            self.init(red: r, green: g, blue: b)
        case 8: // #RRGGBBAA
            let r = Double((rgb >> 24) & 0xFF) / 255.0
            let g = Double((rgb >> 16) & 0xFF) / 255.0
            let b = Double((rgb >> 8) & 0xFF) / 255.0
            let a = Double(rgb & 0xFF) / 255.0
            self.init(red: r, green: g, blue: b, opacity: a)
        default:
            return nil
        }
    }
}
