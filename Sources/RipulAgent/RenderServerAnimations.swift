import SwiftUI
import QuartzCore
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// Looping decorations that run for a whole agent turn, animated by Core
// Animation in the render server instead of by SwiftUI.
//
// A SwiftUI `repeatForever` animation or `TimelineView(.animation)` is
// interpolated on the main thread: every display refresh re-evaluates the view
// graph and commits a frame, for as long as the loop runs. Measured on iPhone
// ([PERFMIN], 2026-09-25): an open agent turn with nothing arriving doubled
// main-thread wake time (14% idle -> 30%) — the composer's waiting glow and
// "Waiting on agent…" shimmer. A CAAnimation is handed to the render server
// once; the main thread does no per-frame work.
//
// The render server still draws every frame, and that work is in no counter of
// this process. Measured on a simulator on 8 October 2026 with the
// `layer_animations` tool: during a turn the simulator's render server used 41%
// of a core with the three loops below running and 1% with them frozen; any one
// alone cost about 33%, because one moving layer makes it compose the screen
// again every refresh; the session list's indicator did so from behind the open
// chat, one left on a hidden row kept it at 35% with the app idle, and the
// composer's two kept running with the chat moved off the screen. So a loop here
// runs only while it can be seen (`canBeDrawn`, and `animates` for the list's),
// and at a limited rate (`turnLoopFramesPerSecond`).

/// A rounded-rect stroke whose opacity pulses between `low` and `high`.
struct RenderServerPulseStroke: View {
    var cornerRadius: CGFloat
    var lineWidth: CGFloat
    var color: Color
    var low: Float
    var high: Float
    var duration: CFTimeInterval
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        PulseStrokeRepresentable(cornerRadius: cornerRadius, lineWidth: lineWidth, color: color,
                                 low: low, high: high, duration: duration, animates: !reduceMotion)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A highlight band sweeping left to right on a loop; mask it with the content.
struct RenderServerShimmerBand: View {
    var highlight: Color
    var duration: CFTimeInterval

    var body: some View {
        ShimmerBandRepresentable(highlight: highlight, duration: duration)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// An SF Symbol whose opacity pulses: the running-chat indicator in the session
/// list, drawn as the icon of the machine the chat runs on. It replaces three
/// dots lighting in sequence, which in turn replaced `.symbolEffect(
/// .variableColor.iterative, options: .repeating)`: SwiftUI redrew that on the
/// main thread every frame for every running chat, even with the list slid off
/// screen behind the chat. On an iPhone 16 with a turn open ([PERFMIN],
/// 2026-09-26) that was 24-26% CPU against 13-14% with it off, 67% of
/// main-thread samples in RenderBox. So the symbol is drawn once and pulsed by
/// Core Animation; do not animate it with a symbol effect.
struct RenderServerPulsingSymbol: View {
    var systemName: String
    var color: Color
    /// False where the symbol cannot be seen: it is then drawn still.
    var animates = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        PulsingSymbolRepresentable(systemName: systemName, color: color, animates: animates && !reduceMotion)
            .frame(width: 18, height: 16)
            .allowsHitTesting(false)
    }
}

/// The most frames a second a turn-long loop asks the render server for.
///
/// They are slow decorations: a six-second glow, a two-second shimmer, a pulse.
/// Left alone they are drawn at the display's own rate, 120 a second on a
/// ProMotion iPhone (the app opts in with CADisableMinimumFrameDurationOnPhone),
/// for as long as a turn runs. The render server's load follows the rate. On a
/// simulator, which draws 60 a second, with the glow and shimmer running
/// (8 October 2026): no limit 33% of a core, 30 a second 25-28%, 10 a second
/// 10%, none running under 1%. Ten is Peter's choice of that morning.
private let turnLoopFramesPerSecond: Float = 10

/// The session list's running indicator gets a few more. It is the quickest of
/// the loops, a small icon going from dim to full, and at 10 a second it moved
/// in visible steps (Peter, 8 October 2026, who also asked for it to cycle at
/// half the speed). It only runs while the list can be seen.
private let listIndicatorFramesPerSecond: Float = 15

/// The shimmer on waiting text: smooth, and only for its first few seconds.
private let shimmerFramesPerSecond: Float = 30
private let shimmerSeconds: CFTimeInterval = 6

/// Gives a loop its frame limit: the shipped one, or the one being tried
/// (`PerfSwitch.loopFramesPerSecond`).
private func paced(_ animation: CABasicAnimation, shipped: Float = turnLoopFramesPerSecond) -> CABasicAnimation {
    let limit = PerfSwitch.loopFramesPerSecond ?? shipped
    if limit < 120 {
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: max(1, limit / 2), maximum: limit, preferred: limit)
    }
    return animation
}

// MARK: - Layer views

private final class PulsingSymbolLayerView: PlatformLayerView {
    /// Filled with the colour and masked to the symbol, so the glyph tints like
    /// a template image without a raster per colour.
    let tint = CALayer()
    let glyph = CALayer()
    var systemName = ""
    var animates = true
    private var drawn: (name: String, size: CGSize)?

    override func setUpLayer() {
        tint.mask = glyph
        hostLayer.addSublayer(tint)
    }

    override func layoutLayer() {
        let bounds = hostLayer.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tint.frame = bounds
        glyph.frame = tint.bounds
        if drawn?.name != systemName || drawn?.size != bounds.size {
            glyph.contents = rasterisedSymbol(systemName, pointSize: 12, canvas: bounds.size)
            drawn = (systemName, bounds.size)
        }
        tint.opacity = animates ? 0.35 : 1
        CATransaction.commit()
        tint.removeAnimation(forKey: "pulse")
        guard animates, canBeDrawn, !PerfSwitch.loopsAreOff, !PerfSwitch.isOff("listPulse") else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.35
        pulse.toValue = 1
        // Dim to full in 1.2 s and back: half the speed it first shipped with.
        pulse.duration = 1.2
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        // Survives the view leaving and re-entering a window.
        pulse.isRemovedOnCompletion = false
        tint.add(paced(pulse, shipped: listIndicatorFramesPerSecond), forKey: "pulse")
    }
}

/// Where a symbol of `size` sits in `canvas`: centred, and scaled down only
/// when it would not otherwise fit.
private func symbolRect(_ size: CGSize, in canvas: CGSize) -> CGRect {
    guard size.width > 0, size.height > 0 else { return .zero }
    let fit = min(1, canvas.width / size.width, canvas.height / size.height)
    let width = size.width * fit, height = size.height * fit
    return CGRect(x: (canvas.width - width) / 2, y: (canvas.height - height) / 2, width: width, height: height)
}

private final class PulseStrokeLayerView: PlatformLayerView {
    let shape = CAShapeLayer()
    var cornerRadius: CGFloat = 0
    var lineWidth: CGFloat = 1
    var low: Float = 0
    var high: Float = 1
    var duration: CFTimeInterval = 1
    var animates = true

    override func setUpLayer() {
        shape.fillColor = nil
        hostLayer.addSublayer(shape)
    }

    override func layoutLayer() {
        let inset = lineWidth / 2
        let rect = hostLayer.bounds.insetBy(dx: inset, dy: inset)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = hostLayer.bounds
        shape.lineWidth = lineWidth
        shape.path = CGPath(roundedRect: rect, cornerWidth: max(0, cornerRadius - inset),
                            cornerHeight: max(0, cornerRadius - inset), transform: nil)
        CATransaction.commit()
        restart()
    }

    func restart() {
        shape.removeAnimation(forKey: "pulse")
        guard animates, canBeDrawn, !PerfSwitch.loopsAreOff else { shape.opacity = (low + high) / 2; return }
        shape.opacity = low
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = low
        pulse.toValue = high
        pulse.duration = duration
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        // Survives the view leaving and re-entering a window.
        pulse.isRemovedOnCompletion = false
        shape.add(paced(pulse), forKey: "pulse")
    }
}

private final class ShimmerBandLayerView: PlatformLayerView {
    let gradient = CAGradientLayer()
    var duration: CFTimeInterval = 2

    override func setUpLayer() {
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.locations = [0.40, 0.50, 0.60]
        hostLayer.addSublayer(gradient)
        hostLayer.masksToBounds = true
    }

    override func layoutLayer() {
        let bounds = hostLayer.bounds
        guard bounds.width > 0 else { return }
        let width = bounds.width
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Band is 4x the text width; its highlight crosses the text once per loop.
        gradient.bounds = CGRect(x: 0, y: 0, width: width * 4, height: bounds.height)
        gradient.anchorPoint = CGPoint(x: 0, y: 0.5)
        gradient.position = CGPoint(x: -3 * width, y: bounds.midY)
        CATransaction.commit()
        gradient.removeAnimation(forKey: "sweep")
        guard canBeDrawn, !PerfSwitch.loopsAreOff else { return }
        // A few sweeps when the text appears, then it rests in its base colour
        // (the band's resting place is off the text). A band moving across text
        // needs 30 frames a second to look smooth, which costs the render
        // server two and a half times what the glow does at 10, and the text is
        // there for the whole of a turn: so it is smooth while it says "a turn
        // has started" and still after that (Peter, 8 October 2026).
        let now = CACurrentMediaTime()
        if firstShownAt == nil { firstShownAt = now }
        let left = shimmerSeconds - (now - (firstShownAt ?? now))
        guard left >= duration / 2 else { return }
        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.fromValue = -3 * width
        sweep.toValue = 0
        sweep.duration = duration
        sweep.repeatCount = Float((left / duration).rounded())
        gradient.add(paced(sweep, shipped: shimmerFramesPerSecond), forKey: "sweep")
    }

    /// When this text first could be seen: the sweeps are counted from then,
    /// so a layout pass or a moment off screen does not start them again.
    private var firstShownAt: CFTimeInterval?
}

// MARK: - Platform plumbing

#if os(iOS)
private class PlatformLayerView: UIView {
    var hostLayer: CALayer { layer }
    private var watch: Timer?
    private var couldBeDrawn = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        setUpLayer()
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    func setUpLayer() {}
    /// Sets the layer up for its size and starts the loop, or stops it when the
    /// view should not animate or `canBeDrawn` is false.
    func layoutLayer() {}
    override func layoutSubviews() { super.layoutSubviews(); layoutLayer() }

    /// False outside a window, under a hidden or clear ancestor, and moved off
    /// the screen. UIKit tells a subview none of these. A list keeps the rows it
    /// is not showing, loops and all: one such row's indicator kept the render
    /// server composing every refresh with the app idle on its list. A chat
    /// stays in place beside the session list, a screen's width to the right:
    /// its composer's glow and shimmer ran there for the rest of the turn.
    var canBeDrawn: Bool {
        guard let window else { return false }
        var node: CALayer? = layer
        while let current = node {
            if current.isHidden || current.opacity < 0.01 { return false }
            node = current.superlayer
        }
        return convert(bounds, to: window).intersects(window.bounds)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        watch?.invalidate()
        watch = nil
        guard window != nil else { return }
        couldBeDrawn = canBeDrawn
        layoutLayer()
        // Nothing announces an ancestor being hidden or moved, so look. Once a
        // second, for as long as the view is in a window: a comparison, not a frame.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let can = self.canBeDrawn
                if can != self.couldBeDrawn { self.couldBeDrawn = can; self.layoutLayer() }
            }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        watch = timer
    }
}

private struct PulseStrokeRepresentable: UIViewRepresentable {
    var cornerRadius: CGFloat, lineWidth: CGFloat, color: Color, low: Float, high: Float
    var duration: CFTimeInterval, animates: Bool
    func makeUIView(context: Context) -> PulseStrokeLayerView { PulseStrokeLayerView(frame: .zero) }
    func updateUIView(_ view: PulseStrokeLayerView, context: Context) {
        view.shape.strokeColor = UIColor(color).cgColor
        let changed = view.cornerRadius != cornerRadius || view.lineWidth != lineWidth || view.low != low
            || view.high != high || view.duration != duration || view.animates != animates
        view.cornerRadius = cornerRadius; view.lineWidth = lineWidth; view.low = low; view.high = high
        view.duration = duration; view.animates = animates
        if changed { view.setNeedsLayout() }
    }
}

private struct PulsingSymbolRepresentable: UIViewRepresentable {
    var systemName: String, color: Color, animates: Bool
    func makeUIView(context: Context) -> PulsingSymbolLayerView { PulsingSymbolLayerView(frame: .zero) }
    func updateUIView(_ view: PulsingSymbolLayerView, context: Context) {
        view.tint.backgroundColor = UIColor(color).cgColor
        if view.systemName != systemName || view.animates != animates {
            view.systemName = systemName; view.animates = animates; view.setNeedsLayout()
        }
    }
}

/// The symbol drawn into a `canvas`-sized image at screen scale, for use as a
/// mask: only its alpha matters.
private func rasterisedSymbol(_ name: String, pointSize: CGFloat, canvas: CGSize) -> CGImage? {
    let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
    guard let symbol = UIImage(systemName: name, withConfiguration: configuration) else { return nil }
    let rect = symbolRect(symbol.size, in: canvas)
    return UIGraphicsImageRenderer(size: canvas).image { _ in
        symbol.withTintColor(.black, renderingMode: .alwaysOriginal).draw(in: rect)  // theme-exempt: a mask, only its alpha is used
    }.cgImage
}

private struct ShimmerBandRepresentable: UIViewRepresentable {
    var highlight: Color, duration: CFTimeInterval
    func makeUIView(context: Context) -> ShimmerBandLayerView { ShimmerBandLayerView(frame: .zero) }
    func updateUIView(_ view: ShimmerBandLayerView, context: Context) {
        let colour = UIColor(highlight)
        view.gradient.colors = [colour.withAlphaComponent(0).cgColor, colour.cgColor, colour.withAlphaComponent(0).cgColor]
        if view.duration != duration { view.duration = duration; view.setNeedsLayout() }
    }
}
#else
private class PlatformLayerView: NSView {
    var hostLayer: CALayer { layer! }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setUpLayer()
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    func setUpLayer() {}
    func layoutLayer() {}
    var canBeDrawn: Bool { window != nil && !isHiddenOrHasHiddenAncestor }
    override func viewDidHide() { super.viewDidHide(); layoutLayer() }
    override func viewDidUnhide() { super.viewDidUnhide(); layoutLayer() }
    override func layout() { super.layout(); layoutLayer() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window != nil { layoutLayer() } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct PulseStrokeRepresentable: NSViewRepresentable {
    var cornerRadius: CGFloat, lineWidth: CGFloat, color: Color, low: Float, high: Float
    var duration: CFTimeInterval, animates: Bool
    func makeNSView(context: Context) -> PulseStrokeLayerView { PulseStrokeLayerView(frame: .zero) }
    func updateNSView(_ view: PulseStrokeLayerView, context: Context) {
        view.shape.strokeColor = NSColor(color).cgColor
        let changed = view.cornerRadius != cornerRadius || view.lineWidth != lineWidth || view.low != low
            || view.high != high || view.duration != duration || view.animates != animates
        view.cornerRadius = cornerRadius; view.lineWidth = lineWidth; view.low = low; view.high = high
        view.duration = duration; view.animates = animates
        if changed { view.needsLayout = true }
    }
}

private struct PulsingSymbolRepresentable: NSViewRepresentable {
    var systemName: String, color: Color, animates: Bool
    func makeNSView(context: Context) -> PulsingSymbolLayerView { PulsingSymbolLayerView(frame: .zero) }
    func updateNSView(_ view: PulsingSymbolLayerView, context: Context) {
        view.tint.backgroundColor = NSColor(color).cgColor
        if view.systemName != systemName || view.animates != animates {
            view.systemName = systemName; view.animates = animates; view.needsLayout = true
        }
    }
}

/// The symbol drawn into a `canvas`-sized image at screen scale, for use as a
/// mask: only its alpha matters.
private func rasterisedSymbol(_ name: String, pointSize: CGFloat, canvas: CGSize) -> CGImage? {
    let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
    guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration) else { return nil }
    let scale = NSScreen.main?.backingScaleFactor ?? 2
    guard let bitmap = CGContext(data: nil, width: Int((canvas.width * scale).rounded(.up)),
                                 height: Int((canvas.height * scale).rounded(.up)), bitsPerComponent: 8,
                                 bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    bitmap.scaleBy(x: scale, y: scale)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: false)
    symbol.draw(in: symbolRect(symbol.size, in: canvas))
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.makeImage()
}

private struct ShimmerBandRepresentable: NSViewRepresentable {
    var highlight: Color, duration: CFTimeInterval
    func makeNSView(context: Context) -> ShimmerBandLayerView { ShimmerBandLayerView(frame: .zero) }
    func updateNSView(_ view: ShimmerBandLayerView, context: Context) {
        let colour = NSColor(highlight)
        view.gradient.colors = [colour.withAlphaComponent(0).cgColor, colour.cgColor, colour.withAlphaComponent(0).cgColor]
        if view.duration != duration { view.duration = duration; view.needsLayout = true }
    }
}
#endif
