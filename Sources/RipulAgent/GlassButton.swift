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
                .modifier(GlassCircleModifier(glassStyle: "regular"))
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
        let shaped = content.contentShape(Circle())
        #if os(iOS)
        if #available(iOS 26.0, *) {
            if glassStyle == "identity" {
                shaped
            } else {
                let style: Glass = glassStyle == "regular" ? .regular : .clear
                shaped
                    .glassEffect(style, in: .circle)
            }
        } else {
            shaped
                .background(.ultraThinMaterial, in: Circle())
        }
        #elseif os(macOS)
        if #available(macOS 26.0, *) {
            if glassStyle == "identity" {
                shaped
            } else {
                let style: Glass = glassStyle == "regular" ? .regular : .clear
                shaped
                    .glassEffect(style, in: .circle)
            }
        } else {
            shaped
                .background(.ultraThinMaterial, in: Circle())
        }
        #endif
    }
}

/// Applies `.glassEffectID` on iOS 26+ so glass shapes inside a
/// `GlassEffectContainer` can morph between states. No-op on older versions.
@available(iOS 15.0, macOS 13.0, *)
public struct GlassEffectIDModifier: ViewModifier {
    public let id: String
    public let namespace: Namespace.ID

    public init(id: String, namespace: Namespace.ID) {
        self.id = id
        self.namespace = namespace
    }

    public func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            content.glassEffectID(id, in: namespace)
        } else {
            content
        }
        #elseif os(macOS)
        if #available(macOS 26.0, *) {
            content.glassEffectID(id, in: namespace)
        } else {
            content
        }
        #endif
    }
}

/// A slide-in side-panel glass surface (sidebar / drawer). Liquid Glass on
/// 26+, `.ultraThinMaterial` fallback below. Rounds only the interior-facing
/// corners (`roundTrailing` = a left-edge drawer, whose open side faces
/// trailing) so the panel reads as a native sidebar flush to the screen edge.
@available(iOS 15.0, macOS 13.0, *)
public struct GlassSidebarPanelModifier: ViewModifier {
    public var roundTrailing: Bool
    public var radius: CGFloat

    public init(roundTrailing: Bool, radius: CGFloat = 32) {
        self.roundTrailing = roundTrailing
        self.radius = radius
    }

    public func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            let shape = interiorShape()
            content.glassEffect(.regular, in: shape).clipShape(shape)
        } else {
            content.background(.ultraThinMaterial)
        }
        #elseif os(macOS)
        if #available(macOS 26.0, *) {
            let shape = interiorShape()
            content.glassEffect(.regular, in: shape).clipShape(shape)
        } else {
            content.background(.ultraThinMaterial)
        }
        #endif
    }

    @available(iOS 16.0, macOS 13.0, *)
    private func interiorShape() -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: roundTrailing ? 0 : radius,
            bottomLeadingRadius: roundTrailing ? 0 : radius,
            bottomTrailingRadius: roundTrailing ? radius : 0,
            topTrailingRadius: roundTrailing ? radius : 0,
            style: .continuous
        )
    }
}

/// A selected-row glass lozenge (WAC RecordMenu pattern): a Liquid Glass
/// capsule behind the active row — glass-on-glass depth, lightly tinted so the
/// selection reads. `.ultraThinMaterial` + tint fallback below 26.
@available(iOS 15.0, macOS 13.0, *)
public struct GlassLozengeModifier: ViewModifier {
    public var tint: Color
    public init(tint: Color) { self.tint = tint }

    public func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(tint.opacity(0.35)), in: .capsule)
        } else {
            content.background(tint.opacity(0.16), in: Capsule())
        }
        #elseif os(macOS)
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.tint(tint.opacity(0.35)), in: .capsule)
        } else {
            content.background(tint.opacity(0.16), in: Capsule())
        }
        #endif
    }
}

/// A capsule-shaped glass background modifier.
@available(iOS 15.0, macOS 13.0, *)
public struct GlassPillModifier: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        let shaped = content.contentShape(Capsule())
        #if os(iOS)
        if #available(iOS 26.0, *) {
            shaped
                .background(.clear)
                .glassEffect(.regular, in: .capsule)
        } else {
            shaped
                .background(.ultraThinMaterial, in: Capsule())
        }
        #elseif os(macOS)
        if #available(macOS 26.0, *) {
            shaped
                .background(.clear)
                .glassEffect(.regular, in: .capsule)
        } else {
            shaped
                .background(.ultraThinMaterial, in: Capsule())
        }
        #endif
    }
}
