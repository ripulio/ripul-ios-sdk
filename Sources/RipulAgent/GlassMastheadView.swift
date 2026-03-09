import SwiftUI

/// A glassy lozenge masthead that displays text and/or an image.
/// Uses Liquid Glass on iOS 26+ and ultraThinMaterial on older versions.
@available(iOS 15.0, macOS 13.0, *)
public struct GlassMastheadView: View {
    public let config: MastheadConfig

    public init(config: MastheadConfig) {
        self.config = config
    }

    public var body: some View {
        HStack(spacing: 8) {
            if let imageUrl = config.imageUrl, let url = URL(string: imageUrl) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: (config.height ?? 40) - 12)
                    case .failure:
                        EmptyView()
                    case .empty:
                        ProgressView()
                            .controlSize(.mini)
                    @unknown default:
                        EmptyView()
                    }
                }
            }

            if let text = config.text {
                Text(text)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color(cssHex: config.textColor) ?? .primary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(height: config.height ?? 44)
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
