import SwiftUI

/// Ripul's branded loading state — the mark, wordmark, and a status line under
/// a `ProgressView`. Used wherever the console has to show something before
/// real content is ready (e.g. `RipulAgentConsole`'s returning-user reconnect
/// wait) instead of a bare spinner.
///
/// The mark is a template asset (`RipulBranding.xcassets/RipulMark`) — alpha
/// only, no baked colour — so it takes `.foregroundStyle(.primary)` and
/// follows light/dark automatically, the same "let the system decide" rule
/// applied to the console's glass chrome.
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
            Image("RipulMark", bundle: .module)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 44, height: 56)
                .foregroundStyle(.primary)
                .scaleEffect(breathe ? 1.06 : 0.96)
                .opacity(breathe ? 1 : 0.75)
                .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: breathe)

            Text("Ripul")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .tracking(1.5)
                .foregroundStyle(.primary)

            VStack(spacing: 10) {
                ProgressView()
                Text(status)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)

            if let action {
                Button(action.title, action: action.handler)
                    .font(.footnote)
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
