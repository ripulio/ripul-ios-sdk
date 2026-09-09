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

    #if targetEnvironment(macCatalyst)
    @State private var safeAreaTop: CGFloat = 0
    private var solidHeight: CGFloat { safeAreaTop + 48 }
    private var fadeHeight: CGFloat { 16 }
    #else
    private var solidHeight: CGFloat { 98 }
    private var fadeHeight: CGFloat { 32 }
    #endif

    public var body: some View {
        VStack(spacing: 0) {
            #if targetEnvironment(macCatalyst)
            // This strip provides scroll-content legibility behind the glass
            // controls. A second glass surface refracts at its rectangular
            // edges and produces triangular highlights beside the columns.
            Rectangle()
                .fill(.regularMaterial)
                .frame(height: solidHeight + fadeHeight)
                .mask(mask)
            #else
            if #available(iOS 26.0, macOS 26.0, *) {
                Rectangle()
                    .fill(.clear)
                    .frame(height: solidHeight + fadeHeight)
                    .glassEffect(.clear, in: .rect)
                    .mask(mask)
            } else {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(0.6)
                    .frame(height: solidHeight + fadeHeight)
                    .mask(mask)
            }
            #endif
            Spacer()
        }
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
        #if targetEnvironment(macCatalyst)
        .background(WindowSafeAreaTop { safeAreaTop = $0 })
        #endif
    }

    private var mask: some View {
        VStack(spacing: 0) {
            Color.black.frame(height: solidHeight)
            LinearGradient(
                colors: [.black, .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: fadeHeight)
        }
    }
}
