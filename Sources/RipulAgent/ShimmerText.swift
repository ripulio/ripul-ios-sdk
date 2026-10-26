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
        highlight: Color = .ripul(.text),
        duration: Double = 2.0
    ) -> some View {
        modifier(RipulShimmerModifier(base: base, highlight: highlight, duration: duration))
    }
}

/// Claude Code-style working status for the chat composer: a cycling ASCII
/// star glyph (`✢ ✳ ✶ ✻ ✽`), a character-by-character typewriter reveal when
/// the phrase changes, and a dimmer monospaced shimmer so it never looks like
/// text the user typed into the input.
struct ComposerWaitingStatusLabel: View {
    var text: String?
    var base: Color
    var highlight: Color

    private static let frames = ["✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳"]
    @State private var frameIndex = 0
    @State private var revealedCount = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var cleanPhrase: String {
        let raw = (text?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "Waiting on agent"
        var trimmed = raw
        while trimmed.hasSuffix("…") || trimmed.hasSuffix(".") {
            trimmed.removeLast()
        }
        return trimmed.isEmpty ? "Waiting on agent" : trimmed
    }

    private var displayedText: String {
        let target = cleanPhrase
        if reduceMotion || PerfSwitch.isOff("shimmer") {
            return "✶ \(target)…"
        }
        let glyph = Self.frames[frameIndex % Self.frames.count]
        let count = min(revealedCount, target.count)
        let prefix = String(target.prefix(count))
        let suffix = count < target.count ? "▌" : "…"
        return "\(glyph) \(prefix)\(suffix)"
    }

    var body: some View {
        Text(displayedText).ripulText()
            .font(.ripul(size: 13.5, weight: .regular, family: .code))
            .lineLimit(1)
            .truncationMode(.tail)
            .ripulShimmer(base: base, highlight: highlight, duration: 2.2)
            .task(id: cleanPhrase) {
                let targetCount = cleanPhrase.count
                if reduceMotion || PerfSwitch.isOff("shimmer") {
                    revealedCount = targetCount
                    return
                }
                revealedCount = 0
                var step = 0
                while !Task.isCancelled && revealedCount < targetCount {
                    try? await Task.sleep(nanoseconds: 18_000_000)
                    guard !Task.isCancelled else { return }
                    revealedCount += 1
                    step += 1
                    if step % 8 == 0 {
                        frameIndex = (frameIndex + 1) % Self.frames.count
                    }
                }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    guard !Task.isCancelled else { return }
                    frameIndex = (frameIndex + 1) % Self.frames.count
                }
            }
    }
}
