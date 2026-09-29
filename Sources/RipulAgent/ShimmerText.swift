// Shimmer for in-progress copy — a highlight band sweeps across the
// glyphs on a loop so waiting text feels alive without a spinner.
// Adapted from the transitions.dev "shimmer text" recipe (band = 4x the
// text width, highlight at its midpoint, 2s linear loop).

import SwiftUI

private struct RipulShimmerModifier: ViewModifier {
    var base: Color
    var highlight: Color
    var duration: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion || PerfSwitch.isOff("shimmer") {
            content.foregroundStyle(base)
        } else {
            content
                .foregroundStyle(base)
                .overlay(bandOverlay(content: content))
        }
    }

    // The band sweeps in the render server: a TimelineView(.animation)
    // re-rendered this view every frame for as long as it was on screen.
    private func bandOverlay(content: Content) -> some View {
        RenderServerShimmerBand(highlight: highlight, duration: duration)
            .mask(content)
            .allowsHitTesting(false)
    }
}

extension View {
    /// Sweeps a highlight band across the view's glyphs on a loop.
    /// Honors Reduce Motion by rendering the static base color.
    func ripulShimmer(
        base: Color,
        highlight: Color = .primary,
        duration: Double = 2.0
    ) -> some View {
        modifier(RipulShimmerModifier(base: base, highlight: highlight, duration: duration))
    }
}
