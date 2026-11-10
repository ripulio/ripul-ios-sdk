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
    /// Draws the symbol so that what it draws meets the box's trailing edge,
    /// instead of sitting in its middle, for a column whose items end on one
    /// edge (the session list's time, spinner and icons). Symbols differ in
    /// width and carry blank space inside their images (`SymbolInk`), so a
    /// centred one stopped short of the time above it: by 2 points for a Mac,
    /// 5 for a phone.
    var hugsTrailingEdge = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        PulsingSymbolRepresentable(systemName: systemName, color: color, animates: animates && !reduceMotion,
                                   placement: !hugsTrailingEdge ? .centre : layoutDirection == .rightToLeft ? .left : .right)
            .frame(width: 18, height: 16)
            .allowsHitTesting(false)
    }
}

/// A busy spinner for a row in a chat: eight spokes, the brightest stepping
/// round once a second, the way the system's does. It replaces `ProgressView()`
/// in chat rows, whose `UIActivityIndicatorView` turns at the display's full
/// rate and keeps turning wherever its row is mounted: the window band keeps
/// about a screen of rows above and below the one read, and one moving layer
/// makes the render server compose the whole screen every refresh. A stuck
/// thinking row's spinner, off the screen, cost 5-7% of a core with the app
/// idle (simulator, 26 October 2026). This one steps eight times a second (no
/// more than the loop limit), and only while it can be seen (`canBeDrawn`).
struct RenderServerSpinner: View {
    var color: Color = .ripul(.textSecondary)
    var size: CGFloat = 14
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Settings > Debug > Native Chat Performance > Paced spinners: off draws
    // the system spinner these replaced, to compare. Read here so a change
    // redraws the spinners already on screen.
    @AppStorage(NativeChatPerformance.allKey) private var allNew = true
    @AppStorage(NativeChatPerformance.key(.pacedSpinners)) private var paced = true

    var body: some View {
        if allNew && paced {
            SpinnerRepresentable(color: color, animates: !reduceMotion)
                .frame(width: size, height: size)
                .allowsHitTesting(false)
                .accessibilityElement()
                .accessibilityLabel("In progress")
        } else {
            ProgressView()
                .controlSize(size <= 14 ? .mini : size <= 16 ? .small : .regular)
                .tint(color)
                .frame(width: size, height: size)
        }
    }
}

/// Glyphs drawn one after another in place, a step every `step` seconds, by
/// Core Animation: the composer's working star (`✢ ✳ ✶ ✻ ✽`). It replaces a
/// `@State` index moved every 150 ms for the whole turn, each move a SwiftUI
/// update, a text layout and a commit of the composer over glass. Draws the
/// first glyph still where it cannot animate. Drawn in the theme's text family
/// at `fontSize` and `weight`: size it with the text it sits beside.
struct RenderServerGlyphCycle: View {
    var glyphs: [String]
    var fontSize: CGFloat
    var weight: Font.Weight = .regular
    var color: Color
    var step: CFTimeInterval = 0.15
    var animates = true

    var body: some View {
        #if os(iOS)
        GlyphCycleRepresentable(glyphs: glyphs, fontSize: fontSize, weight: weight.uiFontWeight, color: color,
                                step: step, animates: animates)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        #else
        Text(glyphs.first ?? "")
            .font(.ripul(size: fontSize, weight: weight)) // theme-mapping: the text family, as the status beside it (Peter, 1 November 2026)
            .foregroundStyle(color)
            .accessibilityHidden(true)
        #endif
    }
}

/// Where a symbol sits across the box it is drawn in.
private enum SymbolPlacement {
    case centre, left, right
}

/// The most frames a second a turn-long loop asks the render server for.
///
/// Thirty frames a second keeps the composer's glow, shimmer and session-list
/// pulse visually smooth while capping ProMotion's 120 Hz display rate during
/// long turns.
private let turnLoopFramesPerSecond: Float = 30

/// The session list's running indicator shares the smooth 30 fps rate and
/// only runs while the list can be seen.
private let listIndicatorFramesPerSecond: Float = 30

/// The shimmer on waiting text: a smooth sweep, then a rest, for as long as it waits.
private let shimmerFramesPerSecond: Float = 30
private let shimmerEvery: TimeInterval = 5

/// Caps for the slow, low-contrast loops, applied whatever the Working
/// Animations setting says (Settings > Debug, `-perfLoopFps`): the setting
/// raises or lowers how fast loops may run, and these two never benefit from
/// more frames, because the extra frames are invisible. The render server
/// draws the whole screen at the rate of the fastest thing moving, and with
/// the setting at 40 the composer's glow alone held it at 40 frames a second
/// for the whole turn (Duo simulator, 27 October 2026: render server 18.8% of
/// a core while streaming, 15.1% with the glow off, 8.5% with every turn loop
/// off). `-perfOff slowLoops` puts back the setting's rate.
///
/// The composer's glow (the one pulse stroke) breathes its opacity between
/// 0.12 and 0.35 over six seconds each way: at its steepest that is under
/// 0.006 of opacity a frame at 12 frames a second, on a 1.25 pt line, which no
/// eye can see step.
private let glowFramesPerSecond: Float = 12
/// The shimmer's band is a soft gradient across dim placeholder text; at 20
/// frames a second it moves about 10-15 points a frame across a composer-wide
/// line, inside a soft band about ten times as wide (a fifth of four text widths).
private let shimmerCapFramesPerSecond: Float = 20

/// The spinner's steps a second: eight spokes, round once a second. Each step
/// is one frame for the render server, and nothing moves between them.
private let spinnerStepsPerSecond: Float = 8

/// Gives a loop its frame limit: the shipped one, or the one being tried
/// (`PerfSwitch.loopFramesPerSecond`), and never above `cap` for a loop whose
/// extra frames cannot be seen (unless `-perfOff slowLoops`).
private func paced(_ animation: CABasicAnimation, shipped: Float = turnLoopFramesPerSecond,
                   cap: Float? = nil) -> CABasicAnimation {
    var limit = PerfSwitch.loopFramesPerSecond ?? shipped
    if let cap, !PerfSwitch.isOff("slowLoops"), NativeChatPerformance.isEnabled(.slowLoops) { limit = min(limit, cap) }
    if limit < 120 {
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: max(1, limit / 2), maximum: limit, preferred: limit)
    }
    return animation
}

// MARK: - Layer views

private final class SpinnerLayerView: PlatformLayerView {
    let spokes = CAReplicatorLayer()
    let spoke = CALayer()
    var animates = true
    /// The step rate the running animation was given, so a new loop limit restarts it.
    private var runningRate: Float?

    override func setUpLayer() {
        spokes.instanceCount = 8
        // Each spoke after the first sits an eighth further back and fainter,
        // so the brightest leads as the whole steps round.
        spokes.instanceAlphaOffset = -0.1
        spokes.addSublayer(spoke)
        hostLayer.addSublayer(spokes)
    }

    override func layoutLayer() {
        let bounds = hostLayer.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let side = min(bounds.width, bounds.height)
        let length = side * 0.28
        let thickness = max(1, side * 0.11)
        #if os(iOS)
        let back: CGFloat = -1
        #else
        let back: CGFloat = 1
        #endif
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spokes.frame = bounds
        spokes.instanceTransform = CATransform3DMakeRotation(back * .pi / 4, 0, 0, 1)
        spoke.bounds = CGRect(x: 0, y: 0, width: thickness, height: length)
        spoke.cornerRadius = thickness / 2
        #if os(iOS)
        spoke.position = CGPoint(x: bounds.midX, y: bounds.midY - side / 2 + length / 2)
        #else
        spoke.position = CGPoint(x: bounds.midX, y: bounds.midY + side / 2 - length / 2)
        #endif
        CATransaction.commit()

        let limit = PerfSwitch.loopFramesPerSecond ?? turnLoopFramesPerSecond
        let rate = min(spinnerStepsPerSecond, limit)
        guard animates, canBeDrawn, !PerfSwitch.loopsAreOff, !PerfSwitch.isOff("spinner") else {
            spokes.removeAnimation(forKey: "spin")
            runningRate = nil
            return
        }
        // A layout pass leaves a turn that is under way alone.
        if runningRate == rate, spokes.animation(forKey: "spin") != nil { return }
        let steps = Int(spinnerStepsPerSecond)
        let spin = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        spin.values = (0..<steps).map { NSNumber(value: Double(-back) * Double($0) * 2 * .pi / Double(steps)) }
        // Discrete: one more key time than values, from 0 to 1.
        spin.keyTimes = (0...steps).map { NSNumber(value: Double($0) / Double(steps)) }
        spin.calculationMode = .discrete
        spin.duration = 1
        spin.repeatCount = .infinity
        // Survives the view leaving and re-entering a window.
        spin.isRemovedOnCompletion = false
        spin.preferredFrameRateRange = CAFrameRateRange(minimum: max(1, rate / 2), maximum: rate, preferred: rate)
        spokes.add(spin, forKey: "spin")
        runningRate = rate
    }
}

private final class PulsingSymbolLayerView: PlatformLayerView {
    /// Filled with the colour and masked to the symbol, so the glyph tints like
    /// a template image without a raster per colour.
    let tint = CALayer()
    let glyph = CALayer()
    var systemName = ""
    var animates = true
    var placement = SymbolPlacement.centre
    private var drawn: (name: String, size: CGSize, placement: SymbolPlacement)?

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
        if drawn?.name != systemName || drawn?.size != bounds.size || drawn?.placement != placement {
            glyph.contents = rasterisedSymbol(systemName, pointSize: 12, canvas: bounds.size, placement: placement)
            drawn = (systemName, bounds.size, placement)
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

/// Where a symbol's image sits in `canvas`: centred top to bottom, across as
/// `placement` says, and scaled down only when it would not otherwise fit.
/// Against a side, it is what the symbol draws that meets the side, not its
/// image: the image's own blank there (`SymbolInk`) hangs outside the canvas.
private func symbolRect(_ image: PlatformImage, in canvas: CGSize, placement: SymbolPlacement) -> CGRect {
    let size = image.size
    guard size.width > 0, size.height > 0 else { return .zero }
    let fit = min(1, canvas.width / size.width, canvas.height / size.height)
    let width = size.width * fit, height = size.height * fit
    let x: CGFloat = switch placement {
    case .centre: (canvas.width - width) / 2
    case .left: -SymbolInk.blanks(of: image).left * fit
    case .right: canvas.width - width + SymbolInk.blanks(of: image).right * fit
    }
    return CGRect(x: x, y: (canvas.height - height) / 2, width: width, height: height)
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
        shape.add(paced(pulse, cap: glowFramesPerSecond), forKey: "pulse")
    }
}

private final class ShimmerBandLayerView: PlatformLayerView {
    let gradient = CAGradientLayer()
    var duration: CFTimeInterval = 2
    private var width: CGFloat = 0
    /// Whether the text has had its first sweep since it could last be seen.
    private var started = false

    override func setUpLayer() {
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.locations = [0.40, 0.50, 0.60]
        hostLayer.addSublayer(gradient)
        hostLayer.masksToBounds = true
        // One sweep every few seconds for as long as the text waits, each a
        // single animation that ends: between sweeps nothing is moving and the
        // render server draws nothing. A band moving across text needs 30
        // frames a second to look smooth, and running without a break at that
        // rate cost two and a half times what the glow does. Sweeping only for
        // the first six seconds, which this replaced, read as the shimmer
        // having gone (Peter, 11 October 2026).
        let timer = Timer(timeInterval: shimmerEvery, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.sweepOnce()
            }
        }
        timer.tolerance = 0.5
        // Default mode: no sweep starts while a scroll is moving (it starts when
        // the scroll rests), so none adds work under a finger.
        RunLoop.main.add(timer, forMode: .default)
    }

    override func layoutLayer() {
        let bounds = hostLayer.bounds
        guard bounds.width > 0 else { return }
        width = bounds.width
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Band is 4x the text width; its highlight crosses the text once per sweep
        // and rests off the text, to its left.
        gradient.bounds = CGRect(x: 0, y: 0, width: width * 4, height: bounds.height)
        gradient.anchorPoint = CGPoint(x: 0, y: 0.5)
        gradient.position = CGPoint(x: -3 * width, y: bounds.midY)
        CATransaction.commit()
        guard canBeDrawn else {
            gradient.removeAnimation(forKey: "sweep")
            started = false
            return
        }
        // The first sweep comes as the text appears, not at the timer's next
        // turn. A layout pass leaves a sweep that is under way alone.
        if !started { started = true; sweepOnce() }
    }

    private func sweepOnce() {
        guard width > 0, canBeDrawn, !PerfSwitch.loopsAreOff, gradient.animation(forKey: "sweep") == nil else { return }
        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.fromValue = -3 * width
        sweep.toValue = 0
        sweep.duration = duration
        gradient.add(paced(sweep, shipped: shimmerFramesPerSecond, cap: shimmerCapFramesPerSecond), forKey: "sweep")
    }
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
        // A loop that is running takes a new rate from Settings at once.
        NotificationCenter.default.addObserver(self, selector: #selector(rateChanged), name: PerfSwitch.loopRateChanged, object: nil)
    }
    @objc private func rateChanged() { layoutLayer() }
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
        // Default mode, not common: every animated view in every row, hidden
        // lists' too, walked its layers once a second under a scrolling finger
        // (Peter's Duo, 5 November 2026). A scroll's rest is soon enough to
        // notice it was hidden or shown.
        RunLoop.main.add(timer, forMode: .default)
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
    var systemName: String, color: Color, animates: Bool, placement: SymbolPlacement
    func makeUIView(context: Context) -> PulsingSymbolLayerView { PulsingSymbolLayerView(frame: .zero) }
    func updateUIView(_ view: PulsingSymbolLayerView, context: Context) {
        view.tint.backgroundColor = UIColor(color).cgColor
        if view.systemName != systemName || view.animates != animates || view.placement != placement {
            view.systemName = systemName; view.animates = animates; view.placement = placement; view.setNeedsLayout()
        }
    }
}

private final class GlyphCycleLayerView: PlatformLayerView {
    let glyph = CALayer()
    var glyphs: [String] = []
    var fontSize: CGFloat = 13.5
    var weight = UIFont.Weight.regular
    var color = UIColor.ripul(.textSecondary)
    var step: CFTimeInterval = 0.15
    var animates = true
    private var drawn: (key: String, size: CGSize)?
    private var frames: [CGImage] = []
    private var runningRate: Float?

    override func setUpLayer() {
        glyph.contentsGravity = .center
        hostLayer.addSublayer(glyph)
        if #available(iOS 17.0, *) {
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: GlyphCycleLayerView, _) in
                view.setNeedsLayout()
            }
        }
    }

    override func layoutLayer() {
        let bounds = hostLayer.bounds
        guard bounds.width > 0, bounds.height > 0, !glyphs.isEmpty else { return }
        let scale = window?.screen.scale ?? traitCollection.displayScale
        // The glyphs are pictures: drawn in the colour as it resolves now, and
        // again when light or dark mode changes it.
        let resolved = color.resolvedColor(with: traitCollection)
        let key = "\(glyphs.joined())|\(fontSize)|\(weight.rawValue)|\(resolved.description)|\(scale)"
        if drawn?.key != key || drawn?.size != bounds.size {
            frames = glyphs.compactMap { render($0, colour: resolved, size: bounds.size, scale: scale) }
            drawn = (key, bounds.size)
            runningRate = nil
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glyph.frame = bounds
        glyph.contentsScale = scale
        glyph.contents = frames.first
        CATransaction.commit()
        let stepRate = Float(1 / step)
        let rate = min(stepRate, PerfSwitch.loopFramesPerSecond ?? turnLoopFramesPerSecond)
        guard animates, frames.count > 1, canBeDrawn, !PerfSwitch.loopsAreOff, !PerfSwitch.isOff("shimmer") else {
            glyph.removeAnimation(forKey: "cycle")
            runningRate = nil
            return
        }
        if runningRate == rate, glyph.animation(forKey: "cycle") != nil { return }
        let cycle = CAKeyframeAnimation(keyPath: "contents")
        cycle.values = frames
        // Discrete: one more key time than values, from 0 to 1.
        cycle.keyTimes = (0...frames.count).map { NSNumber(value: Double($0) / Double(frames.count)) }
        cycle.calculationMode = .discrete
        cycle.duration = step * Double(frames.count)
        cycle.repeatCount = .infinity
        // Survives the view leaving and re-entering a window.
        cycle.isRemovedOnCompletion = false
        cycle.preferredFrameRateRange = CAFrameRateRange(minimum: max(1, rate / 2), maximum: rate, preferred: rate)
        glyph.add(cycle, forKey: "cycle")
        runningRate = rate
    }

    private func render(_ text: String, colour: UIColor, size: CGSize, scale: CGFloat) -> CGImage? {
        let font = UIFont.ripul(size: fontSize, weight: weight) // theme-mapping: the text family, as the status beside it (Peter, 1 November 2026)
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: colour])
        let measured = string.size()
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            string.draw(at: CGPoint(x: (size.width - measured.width) / 2, y: (size.height - measured.height) / 2))
        }.cgImage
    }
}

private struct GlyphCycleRepresentable: UIViewRepresentable {
    var glyphs: [String], fontSize: CGFloat, weight: UIFont.Weight, color: Color, step: CFTimeInterval, animates: Bool
    func makeUIView(context: Context) -> GlyphCycleLayerView { GlyphCycleLayerView(frame: .zero) }
    func updateUIView(_ view: GlyphCycleLayerView, context: Context) {
        let colour = UIColor(color)
        if view.glyphs != glyphs || view.fontSize != fontSize || view.weight != weight || view.step != step
            || view.animates != animates || !view.color.isEqual(colour) {
            view.glyphs = glyphs; view.fontSize = fontSize; view.weight = weight; view.step = step
            view.animates = animates
            view.color = colour
            view.setNeedsLayout()
        }
    }
}

private extension Font.Weight {
    /// UIKit's weight of the same name, for glyphs drawn by UIKit.
    var uiFontWeight: UIFont.Weight {
        switch self {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black  // theme-exempt: a font weight, not a colour
        default: return .regular
        }
    }
}

private struct SpinnerRepresentable: UIViewRepresentable {
    var color: Color, animates: Bool
    func makeUIView(context: Context) -> SpinnerLayerView { SpinnerLayerView(frame: .zero) }
    func updateUIView(_ view: SpinnerLayerView, context: Context) {
        view.spoke.backgroundColor = UIColor(color).cgColor
        if view.animates != animates { view.animates = animates; view.setNeedsLayout() }
    }
}

/// The symbol drawn into a `canvas`-sized image at screen scale, for use as a
/// mask: only its alpha matters.
private func rasterisedSymbol(_ name: String, pointSize: CGFloat, canvas: CGSize, placement: SymbolPlacement) -> CGImage? {
    let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
    guard let symbol = UIImage(systemName: name, withConfiguration: configuration) else { return nil }
    let rect = symbolRect(symbol, in: canvas, placement: placement)
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
        NotificationCenter.default.addObserver(self, selector: #selector(rateChanged), name: PerfSwitch.loopRateChanged, object: nil)
    }
    @objc private func rateChanged() { layoutLayer() }
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
    var systemName: String, color: Color, animates: Bool, placement: SymbolPlacement
    func makeNSView(context: Context) -> PulsingSymbolLayerView { PulsingSymbolLayerView(frame: .zero) }
    func updateNSView(_ view: PulsingSymbolLayerView, context: Context) {
        view.tint.backgroundColor = NSColor(color).cgColor
        if view.systemName != systemName || view.animates != animates || view.placement != placement {
            view.systemName = systemName; view.animates = animates; view.placement = placement; view.needsLayout = true
        }
    }
}

private struct SpinnerRepresentable: NSViewRepresentable {
    var color: Color, animates: Bool
    func makeNSView(context: Context) -> SpinnerLayerView { SpinnerLayerView(frame: .zero) }
    func updateNSView(_ view: SpinnerLayerView, context: Context) {
        view.spoke.backgroundColor = NSColor(color).cgColor
        if view.animates != animates { view.animates = animates; view.needsLayout = true }
    }
}

/// The symbol drawn into a `canvas`-sized image at screen scale, for use as a
/// mask: only its alpha matters.
private func rasterisedSymbol(_ name: String, pointSize: CGFloat, canvas: CGSize, placement: SymbolPlacement) -> CGImage? {
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
    symbol.draw(in: symbolRect(symbol, in: canvas, placement: placement))
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
