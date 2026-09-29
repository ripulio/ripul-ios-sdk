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

/// Three dots lighting in sequence: the running-chat indicator in the session
/// list. It replaces `.symbolEffect(.variableColor.iterative, options:
/// .repeating)`, which SwiftUI redrew on the main thread every frame for every
/// running chat, even with the list slid off screen behind the chat. On an
/// iPhone 16 with a turn open ([PERFMIN], 2026-09-26) that was 24-26% CPU
/// against 13-14% with it off, 67% of main-thread samples in RenderBox.
struct RenderServerEllipsis: View {
    var color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        EllipsisRepresentable(color: color, animates: !reduceMotion)
            .frame(width: 18, height: 16)
            .allowsHitTesting(false)
    }
}

// MARK: - Layer views

private final class EllipsisLayerView: PlatformLayerView {
    let replicator = CAReplicatorLayer()
    let dot = CALayer()
    var animates = true

    override func setUpLayer() {
        replicator.instanceCount = 3
        // Each copy runs the dot's animation this much later: the wave.
        replicator.instanceDelay = 0.2
        replicator.addSublayer(dot)
        hostLayer.addSublayer(replicator)
    }

    override func layoutLayer() {
        let bounds = hostLayer.bounds
        guard bounds.width > 0 else { return }
        let diameter: CGFloat = 3.5, gap: CGFloat = 2.5
        let total = diameter * 3 + gap * 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        replicator.frame = bounds
        replicator.instanceTransform = CATransform3DMakeTranslation(diameter + gap, 0, 0)
        dot.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        dot.cornerRadius = diameter / 2
        dot.position = CGPoint(x: (bounds.width - total) / 2 + diameter / 2, y: bounds.midY)
        dot.opacity = animates ? 0.35 : 1
        CATransaction.commit()
        dot.removeAnimation(forKey: "wave")
        guard animates else { return }
        let wave = CAKeyframeAnimation(keyPath: "opacity")
        wave.values = [0.35, 1, 0.35]
        wave.keyTimes = [0, 0.3, 0.6]
        wave.duration = 1.2
        wave.repeatCount = .infinity
        // Survives the view leaving and re-entering a window.
        wave.isRemovedOnCompletion = false
        dot.add(wave, forKey: "wave")
    }
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
        guard animates else { shape.opacity = (low + high) / 2; return }
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
        shape.add(pulse, forKey: "pulse")
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
        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.fromValue = -3 * width
        sweep.toValue = 0
        sweep.duration = duration
        sweep.repeatCount = .infinity
        sweep.isRemovedOnCompletion = false
        gradient.add(sweep, forKey: "sweep")
    }
}

// MARK: - Platform plumbing

#if os(iOS)
private class PlatformLayerView: UIView {
    var hostLayer: CALayer { layer }
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        setUpLayer()
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    func setUpLayer() {}
    func layoutLayer() {}
    override func layoutSubviews() { super.layoutSubviews(); layoutLayer() }
    override func didMoveToWindow() { super.didMoveToWindow(); if window != nil { layoutLayer() } }
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

private struct EllipsisRepresentable: UIViewRepresentable {
    var color: Color, animates: Bool
    func makeUIView(context: Context) -> EllipsisLayerView { EllipsisLayerView(frame: .zero) }
    func updateUIView(_ view: EllipsisLayerView, context: Context) {
        view.dot.backgroundColor = UIColor(color).cgColor
        if view.animates != animates { view.animates = animates; view.setNeedsLayout() }
    }
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

private struct EllipsisRepresentable: NSViewRepresentable {
    var color: Color, animates: Bool
    func makeNSView(context: Context) -> EllipsisLayerView { EllipsisLayerView(frame: .zero) }
    func updateNSView(_ view: EllipsisLayerView, context: Context) {
        view.dot.backgroundColor = NSColor(color).cgColor
        if view.animates != animates { view.animates = animates; view.needsLayout = true }
    }
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
