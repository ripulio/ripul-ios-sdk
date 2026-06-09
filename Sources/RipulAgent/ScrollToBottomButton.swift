import SwiftUI

/// A floating glass circle button with a chevron-down icon.
/// Tapping scrolls the web view to the bottom.
/// Displays a numeric badge when `unreadCount > 0` — used by the web app to
/// signal new messages arrived while the user is scrolled up.
@available(iOS 15.0, macOS 13.0, *)
public struct ScrollToBottomButton: View {
    public let action: () -> Void
    public let unreadCount: Int

    public init(unreadCount: Int = 0, action: @escaping () -> Void) {
        self.action = action
        self.unreadCount = unreadCount
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.down")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
        }
        #if os(macOS)
        .buttonStyle(.plain)
        #endif
        .modifier(GlassCircleModifier(glassStyle: nil))
        .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
        .overlay(alignment: .topTrailing) {
            if unreadCount > 0 {
                Text(unreadCount > 99 ? "99+" : "\(unreadCount)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .frame(minWidth: 18)
                    .background(Capsule().fill(Color.accentColor))
                    .offset(x: 6, y: -6)
            }
        }
        .animation(.spring(duration: 0.25), value: unreadCount)
    }
}
