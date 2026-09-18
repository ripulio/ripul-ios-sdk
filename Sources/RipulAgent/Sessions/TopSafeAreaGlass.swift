import SwiftUI

/// Compatibility backdrop for platforms without the iOS system scroll-edge
/// treatment. On iOS 27+, WKWebView and native scroll views provide their own
/// status-region effect, including when the web page scrolls a CSS container.
/// Do not stack another full-width glass sheet over it. Floating controls keep
/// their individual glass; the system owns the edge's blur and falloff.
public struct TopSafeAreaGlass: View {
    /// Pass the same window clearance used to position the associated bar so
    /// its backdrop and title move together when a scene is mirrored/resized.
    /// Standalone callers can omit it and use the owning-window reader below.
    public init(topInset: CGFloat? = nil) {
        self.topInset = topInset
    }

    private let topInset: CGFloat?
    @State private var measuredTopInset: CGFloat = 0

    #if targetEnvironment(macCatalyst)
    private var fadeHeight: CGFloat { 16 }
    #else
    private var fadeHeight: CGFloat { 32 }
    #endif

    public var body: some View {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        if #available(iOS 27.0, *) {
            EmptyView()
        } else {
            legacyBackdrop
        }
        #else
        legacyBackdrop
        #endif
    }

    private var legacyBackdrop: some View {
        TopSafeAreaGlassRegion(topInset: topInset ?? measuredTopInset,
            fadeHeight: fadeHeight, backdrop: backdrop)
        #if os(iOS)
        .background {
            if topInset == nil {
                WindowSafeAreaTop { measuredTopInset = $0 }
            }
        }
        #endif
    }

    @ViewBuilder private var backdrop: some View {
        #if targetEnvironment(macCatalyst)
        // Keep the existing non-refracting desktop backdrop material.
        Rectangle().fill(.regularMaterial)
        #else
        if #available(iOS 26.0, macOS 26.0, *) {
            Rectangle().fill(.clear).glassEffect(.clear, in: .rect)
        } else {
            Rectangle().fill(.ultraThinMaterial).opacity(0.6)
        }
        #endif
    }
}

/// Only the current TOP clearance needs this status-region backdrop. Side
/// insets in landscape do not imply a top strip; the bar's individual controls
/// retain their own glass when this additional full-width surface disappears.
struct TopSafeAreaGlassRegion<Backdrop: View>: View {
    let topInset: CGFloat
    let fadeHeight: CGFloat
    let backdrop: Backdrop

    var body: some View {
        VStack(spacing: 0) {
            if topInset > 0 {
                // GlassTopBar's 44pt row + 4pt top padding.
                let solidHeight = topInset + 48
                backdrop
                    .frame(height: solidHeight + fadeHeight)
                    .mask {
                        VStack(spacing: 0) {
                            Color.black.frame(height: solidHeight)
                            LinearGradient(colors: [.black, .clear],
                                startPoint: .top, endPoint: .bottom)
                                .frame(height: fadeHeight)
                        }
                    }
            }
            Spacer()
        }
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
    }
}
