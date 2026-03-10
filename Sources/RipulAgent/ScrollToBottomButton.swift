import SwiftUI

/// A floating glass circle button with a chevron-down icon.
/// Tapping scrolls the web view to the bottom.
@available(iOS 15.0, macOS 13.0, *)
public struct ScrollToBottomButton: View {
    public let action: () -> Void

    public init(action: @escaping () -> Void) {
        self.action = action
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
    }
}
