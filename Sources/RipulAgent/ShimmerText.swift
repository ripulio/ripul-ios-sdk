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

private struct ComposerWorkingTintKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}

extension EnvironmentValues {
    /// The colour of the open chat's icon in the session list and the title
    /// pill (its model's, else its CLI's), for the composer's working star.
    /// nil where the chat is not known: the star then takes the status text's.
    var composerWorkingTint: Color? {
        get { self[ComposerWorkingTintKey.self] }
        set { self[ComposerWorkingTintKey.self] = newValue }
    }
}

/// Claude Code-style working status for the chat composer: what the agent is
/// doing in the composer's own font, written out character by character when
/// the phrase changes, shimmering so it never looks like text the user typed
/// into the input, and after it a cycling ASCII star (`✢ ✳ ✶ ✻ ✽`) in the
/// colour of the chat's icon (`composerWorkingTint`). A phrase the agent wrote
/// (its composer goal) is italic and in the star's colour; the stand-in
/// "Waiting on agent…" stays dim.
///
/// The star cycles in the render server (`RenderServerGlyphCycle`): it was a
/// `@State` index moved every 150 ms for the whole turn, each move a SwiftUI
/// update, a text layout and a commit of the composer. The reveal is the only
/// SwiftUI tick left, and it ends when the phrase is written out.
struct ComposerWaitingStatusLabel: View {
    var text: String?
    var base: Color
    var highlight: Color
    /// The composer's type: the size and weight of its text and placeholder.
    var fontSize: CGFloat
    var weight: Font.Weight = .regular

    /// `✳` is an emoji too: drawn in the text family, which has no glyph for it,
    /// it fell back to the emoji font's green tile. The text presentation
    /// selector (U+FE0E) asks for the plain one.
    private static let frames = ["✢", "✳\u{FE0E}", "✶", "✻", "✽", "✻", "✶", "✳\u{FE0E}"]
    /// Characters written per tick of the reveal, and the tick: the speed it
    /// always had (one per 18 ms) at half the updates.
    private static let revealChunk = 2
    private static let revealTick: UInt64 = 36_000_000
    @State private var revealedCount = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.composerWorkingTint) private var tint

    private var cleanPhrase: String {
        let raw = (text?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "Waiting on agent"
        var trimmed = raw
        while trimmed.hasSuffix("…") || trimmed.hasSuffix(".") {
            trimmed.removeLast()
        }
        return trimmed.isEmpty ? "Waiting on agent" : trimmed
    }

    private var isStill: Bool { reduceMotion || PerfSwitch.isOff("shimmer") }

    /// The agent wrote the phrase, rather than the stand-in being shown.
    private var isAgentUpdate: Bool {
        !(text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    private var displayedText: String {
        let target = cleanPhrase
        if isStill {
            return "\(target)…"
        }
        let count = min(revealedCount, target.count)
        let prefix = String(target.prefix(count))
        let suffix = count < target.count ? "▌" : "…"
        return "\(prefix)\(suffix)"
    }

    var body: some View {
        let font = Font.ripul(size: fontSize, weight: weight) // theme-mapping: the composer's own type, not code (Peter, 1 November 2026)
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            // The agent's own words in the star's colour (Peter, 2 November 2026).
            let agentTint = isAgentUpdate ? tint : nil
            // Its colour on the Text itself: `ripulText()` there gave it the theme's
            // text colour wherever a theme names one, over the shimmer's (Peter saw the
            // agent's phrase italic but not in the star's colour, 2 November 2026).
            Text(displayedText).italic(isAgentUpdate).foregroundStyle(agentTint ?? base)
                .font(font)
                .lineLimit(1)
                .truncationMode(.tail)
                .ripulShimmer(base: agentTint ?? base, highlight: agentTint == nil ? highlight : .ripul(.text), // theme-mapping: the agent's phrase in the star's colour, its sweep the text colour (Peter, 2 November 2026)
                              duration: 2.2)
            // A space, then the star, outside the phrase: a long phrase
            // truncates and the star stays. The star's slot is the text's own,
            // so it sits on the text's line.
            Group {
                Text(" ").ripulText()
                Text("✶").ripulText()
                    .hidden()
                    .overlay {
                        RenderServerGlyphCycle(glyphs: Self.frames, fontSize: fontSize, weight: weight,
                                               color: tint ?? base, animates: !isStill)
                    }
            }
            .font(font)
            .fixedSize()
        }
        .task(id: cleanPhrase) {
            let targetCount = cleanPhrase.count
            if isStill {
                revealedCount = targetCount
                return
            }
            revealedCount = 0
            while !Task.isCancelled && revealedCount < targetCount {
                try? await Task.sleep(nanoseconds: Self.revealTick)
                guard !Task.isCancelled else { return }
                revealedCount = min(targetCount, revealedCount + Self.revealChunk)
            }
        }
    }
}
