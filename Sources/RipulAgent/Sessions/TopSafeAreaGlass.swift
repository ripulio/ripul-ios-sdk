import SwiftUI

/// The fading glass strip that bleeds a top bar's material into the status-bar
/// region — content scrolling underneath frosts out instead of colliding with
/// the clock.
///
/// A public component so any bar that floats over full-bleed content (the
/// agent screen's unified bar, the Agents|Plans shell's root bar) draws the
/// SAME strip. Extracted verbatim from RipulAgentScreen.safeAreaGlass.
public struct TopSafeAreaGlass: View {
    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            if #available(iOS 26.0, macOS 26.0, *) {
                Rectangle()
                    .fill(.clear)
                    .frame(height: 130)
                    .glassEffect(.clear, in: .rect)
                    .mask(mask)
            } else {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(0.6)
                    .frame(height: 130)
                    .mask(mask)
            }
            Spacer()
        }
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
    }

    private var mask: some View {
        VStack(spacing: 0) {
            Color.black.frame(height: 98)
            LinearGradient(
                colors: [.black, .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 32)
        }
    }
}
