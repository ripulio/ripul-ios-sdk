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
                .modifier(GlassCircleModifier(glassStyle: "clear"))
        }
    }
}

@available(iOS 15.0, macOS 13.0, *)
public struct GlassCircleModifier: ViewModifier {
    public var glassStyle: String?

    public init(glassStyle: String? = nil) {
        self.glassStyle = glassStyle
    }

    public func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            if glassStyle == "identity" {
                content
            } else {
                let style: Glass = glassStyle == "regular" ? .regular : .clear
                content
                    .glassEffect(style.interactive(), in: .circle)
            }
        } else {
            content
                .background(.ultraThinMaterial, in: Circle())
        }
        #elseif os(macOS)
        if #available(macOS 26.0, *) {
            if glassStyle == "identity" {
                content
            } else {
                let style: Glass = glassStyle == "regular" ? .regular : .clear
                content
                    .glassEffect(style.interactive(), in: .circle)
            }
        } else {
            content
                .background(.ultraThinMaterial, in: Circle())
        }
        #endif
    }
}

/// A capsule-shaped glass background modifier.
@available(iOS 15.0, macOS 13.0, *)
public struct GlassPillModifier: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            content
                .background(.clear)
                .glassEffect(.clear, in: .capsule)
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
        }
        #elseif os(macOS)
        if #available(macOS 26.0, *) {
            content
                .background(.clear)
                .glassEffect(.clear, in: .capsule)
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
        }
        #endif
    }
}
