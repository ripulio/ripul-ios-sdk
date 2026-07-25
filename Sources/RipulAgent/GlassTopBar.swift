import SwiftUI

// MARK: - Glass Top Bar

/// Shared floating navigation bar with glass back button, title lozenge,
/// and trailing context menu. Matches the chat screen's `chatTopBar` pattern.
/// Use with `.toolbar(.hidden, for: .navigationBar)` and
/// `.safeAreaInset(edge: .top)` on the host view.
///
/// Ported from the native app (`Shared/GlassComponents.swift`) for the M8
/// whole-screen extraction. Two deliberate deviations:
/// - The screen-tip button is an injected slot (`screenTip`) instead of the
///   app's `ScreenTipButton`, which is app chrome.
/// - Long-press posts `.ripulShowDevTools` directly (the app bridges its
///   `glassTopBarLongPress` to that anyway).
@available(iOS 15.0, macOS 13.0, *)
public struct GlassTopBar<MenuContent: View>: View {
    let title: String
    var subtitle: String? = nil
    var leadingIcon: String = "chevron.left"
    var showLeading: Bool = true
    var screenKey: String? = nil
    var screenTip: ((String) -> AnyView)? = nil
    var onLeading: (() -> Void)? = nil
    @ViewBuilder var menu: () -> MenuContent

    public init(
        title: String,
        subtitle: String? = nil,
        leadingIcon: String = "chevron.left",
        showLeading: Bool = true,
        screenKey: String? = nil,
        screenTip: ((String) -> AnyView)? = nil,
        onLeading: (() -> Void)? = nil,
        @ViewBuilder menu: @escaping () -> MenuContent
    ) {
        self.title = title
        self.subtitle = subtitle
        self.leadingIcon = leadingIcon
        self.showLeading = showLeading
        self.screenKey = screenKey
        self.screenTip = screenTip
        self.onLeading = onLeading
        self.menu = menu
    }

    public var body: some View {
        HStack(spacing: 8) {
            if showLeading, let onLeading {
                GlassButton(icon: leadingIcon, action: onLeading)
                    .uiKitIdentifier("GlassTopBar.leadingButton")
            }

            VStack(spacing: 1) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    if let key = screenKey, let screenTip {
                        screenTip(key)
                    }
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minHeight: 44)
            .modifier(GlassPillModifier())
            .frame(maxWidth: .infinity)
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 1.0).onEnded { _ in
                    NotificationCenter.default.post(name: .ripulShowDevTools, object: nil)
                }
            )
            .uiKitIdentifier("GlassTopBar.titleLozenge")

            Menu {
                menu()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .modifier(GlassCircleModifier(glassStyle: "regular"))
            }
            .uiKitIdentifier("GlassTopBar.trailingMenu")
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }
}

// Back-button convenience (preserves existing call sites using onBack:)
@available(iOS 15.0, macOS 13.0, *)
public extension GlassTopBar {
    init(
        title: String,
        subtitle: String? = nil,
        screenTip: ((String) -> AnyView)? = nil,
        onBack: (() -> Void)?,
        @ViewBuilder menu: @escaping () -> MenuContent
    ) {
        self.init(title: title, subtitle: subtitle, leadingIcon: "chevron.left", showLeading: onBack != nil, screenTip: screenTip, onLeading: onBack, menu: menu)
    }
}

// Convenience: no menu (back + lozenge only)
@available(iOS 15.0, macOS 13.0, *)
public extension GlassTopBar where MenuContent == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        onBack: (() -> Void)? = nil
    ) {
        self.init(title: title, subtitle: subtitle, onBack: onBack) {
            EmptyView()
        }
    }
}
