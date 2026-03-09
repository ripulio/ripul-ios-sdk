import SwiftUI

/// A circular floating button that uses Liquid Glass on iOS 26+ and ultraThinMaterial on older versions.
@available(iOS 15.0, macOS 13.0, *)
public struct GlassButton: View {
    public let icon: String
    public let action: () -> Void

    public init(icon: String, action: @escaping () -> Void) {
        self.icon = icon
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .modifier(GlassCircleModifier(glassStyle: nil))
        }
    }
}

@available(iOS 15.0, macOS 13.0, *)
struct GlassCircleModifier: ViewModifier {
    var glassStyle: String?

    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            if glassStyle == "identity" {
                content
            } else {
                let style: Glass = glassStyle == "clear" ? .clear : .regular
                content
                    .glassEffect(style.interactive(), in: .circle)
            }
        } else {
            content
                .background(.ultraThinMaterial, in: Circle())
        }
        #else
        content
            .background(.ultraThinMaterial, in: Circle())
        #endif
    }
}
