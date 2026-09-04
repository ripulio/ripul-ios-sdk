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
        if reduceMotion {
            content.foregroundStyle(base)
        } else {
            content
                .foregroundStyle(base)
                .overlay(bandOverlay(content: content))
        }
    }

    private func bandOverlay(content: Content) -> some View {
        GeometryReader { geo in
            TimelineView(.animation) { timeline in
                band(width: geo.size.width, at: timeline.date)
            }
        }
        .mask(content)
        .allowsHitTesting(false)
    }

    private func band(width w: CGFloat, at date: Date) -> some View {
        let t = date.timeIntervalSinceReferenceDate
        let phase = (t / duration) - floor(t / duration)
        let offset = -3 * w + 3 * w * phase
        return LinearGradient(
            stops: [
                .init(color: .clear, location: 0.40),
                .init(color: highlight, location: 0.50),
                .init(color: .clear, location: 0.60),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: w * 4)
        .offset(x: offset)
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
