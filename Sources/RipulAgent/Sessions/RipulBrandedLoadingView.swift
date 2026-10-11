import SwiftUI

/// Ripul's branded loading state — the logo and a status line under a
/// `ProgressView`. Used wherever the console has to show something before
/// real content is ready (e.g. `RipulAgentConsole`'s returning-user reconnect
/// wait) instead of a bare spinner.
///
/// The logo is `RipulWordmark`, a template asset, so it takes
/// `.foregroundStyle(.primary)` and follows light/dark automatically, the same
/// "let the system decide" rule applied to the console's glass chrome. Its dot
/// alone is the app icon's lime, and sways once as the screen arrives.
@available(iOS 15.0, macOS 13.0, *)
public struct RipulBrandedLoadingView: View {
    let status: String
    let action: (title: String, handler: () -> Void)?

    @State private var breathe = false
    @State private var appeared = false

    public init(status: String, action: (title: String, handler: () -> Void)? = nil) {
        self.status = status
        self.action = action
    }

    public var body: some View {
        VStack(spacing: 20) {
            RipulWordmark(height: 64, dot: RipulWordmark.lime, bobs: true)
                .foregroundStyle(.ripul(.text))
                .scaleEffect(breathe ? 1.04 : 0.97)
                .opacity(breathe ? 1 : 0.75)
                .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: breathe)

            VStack(spacing: 10) {
                ProgressView()
                Text(status)
                    .font(.ripul(.subheadline))
                    .foregroundStyle(.ripul(.textSecondary))
            }
            .padding(.top, 4)

            if let action {
                Button(action.title, action: action.handler)
                    .font(.ripul(.footnote))
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .uiKitIdentifier("RipulBrandedLoadingView.action")
            }
        }
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared ? 1 : 0.94)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .transition(.opacity)
        .onAppear {
            breathe = true
            withAnimation(.easeOut(duration: 0.35)) { appeared = true }
        }
    }
}
