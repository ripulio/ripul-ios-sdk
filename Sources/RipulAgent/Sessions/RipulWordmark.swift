import SwiftUI

/// The Ripul logo: the cut dot of the "i" beside the wordmark.
///
/// Two template assets of the same size (`RipulBranding.xcassets`,
/// `RipulWordmarkText` and `RipulWordmarkDot`), alpha only with no baked
/// colour, laid one over the other. So the logo takes whatever foreground style
/// it is given and follows light and dark by itself, while the dot can have a
/// colour of its own and move by itself. Use it wherever an app screen needs to
/// say "Ripul" as a logo rather than as text: startup, connecting, sign-in.
@available(iOS 15.0, macOS 13.0, *)
public struct RipulWordmark: View {
    /// The lime of the app icon's dot. One of the brand's rare dashes of colour:
    /// for the dot on a startup screen, not for text or controls.
    public static let lime = Color(red: 174 / 255, green: 245 / 255, blue: 114 / 255)  // theme-exempt: brand mark, the wordmark's lime dot

    /// The whole logo swelling and fading a little, over and over, while a screen waits.
    public struct Breath: Equatable, Sendable {
        var scale: ClosedRange<CGFloat>
        var opacity: ClosedRange<Double>
        /// One way, in seconds; it goes back in as long again.
        var duration: Double

        public init(scale: ClosedRange<CGFloat>, opacity: ClosedRange<Double>, duration: Double) {
            self.scale = scale
            self.opacity = opacity
            self.duration = duration
        }
    }

    let height: CGFloat
    let dot: Color?
    let bobs: Bool
    let breath: Breath?

    @State private var bob: CGFloat = 0
    @State private var breathing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - dot: A colour for the dot alone. Nil leaves it the colour of the wordmark.
    ///   - bobs: Whether the dot sways left and right once, shortly after the
    ///     logo appears, then settles (see `RipulWordmarkBob`).
    ///   - breath: The logo's breathing while a screen waits; nil for a still logo.
    ///
    /// A logo that moves is drawn in the theme's text colour, whatever foreground
    /// style is round it: on iOS its motion is Core Animation's, played by the
    /// system outside this process, so the work an app does as it starts cannot
    /// make it skip. SwiftUI would draw each frame on the main thread, which is
    /// busiest in exactly the second a startup screen is showing.
    public init(height: CGFloat = 56, dot: Color? = nil, bobs: Bool = false, breath: Breath? = nil) {
        self.height = height
        self.dot = dot
        self.bobs = bobs
        self.breath = breath
    }

    public var body: some View {
        #if canImport(UIKit)
        if bobs || breath != nil {
            RipulWordmarkLayers(dot: dot, bobs: bobs && !reduceMotion, breath: reduceMotion ? nil : breath)
                .frame(width: height * RipulWordmarkLayers.aspect, height: height)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Ripul")
        } else {
            drawn
        }
        #else
        drawn
        #endif
    }

    /// The logo drawn by SwiftUI: every still logo, and a moving one off iOS.
    private var drawn: some View {
        ZStack {
            part("RipulWordmarkText")
            Group {
                if let dot {
                    part("RipulWordmarkDot").foregroundStyle(dot)
                } else {
                    part("RipulWordmarkDot")
                }
            }
            .modifier(DotBob(progress: bob))
        }
        .frame(height: height)
        .scaleEffect(breath.map { breathing ? $0.scale.upperBound : $0.scale.lowerBound } ?? 1)
        .opacity(breath.map { breathing ? $0.opacity.upperBound : $0.opacity.lowerBound } ?? 1)
        .animation(breath.map { .easeInOut(duration: $0.duration).repeatForever(autoreverses: true) } ?? .default, value: breathing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ripul")
        .onAppear { breathing = breath != nil }
        .onChange(of: breath) { breathing = $0 != nil }
        .task {
            guard bobs, !reduceMotion, bob == 0 else { return }
            // Started in a later update than the one the screen appears in, so a
            // repeating animation the screen puts on the whole logo (its
            // breathing while connecting) cannot take this one over.
            try? await Task.sleep(nanoseconds: UInt64(RipulWordmarkBob.delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(.linear(duration: RipulWordmarkBob.duration)) { bob = 1 }
        }
    }

    private func part(_ name: String) -> some View {
        Image(name, bundle: .module)
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
    }
}

/// Slides and tips the dot about its own centre. Animating `progress` from 0 to
/// 1 at a steady rate plays the whole sway; the easing is in the pose itself.
private struct DotBob: GeometryEffect {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let pose = RipulWordmarkBob.pose(at: progress)
        let centre = CGPoint(x: size.width * RipulWordmarkBob.dotCentre.x, y: size.height * RipulWordmarkBob.dotCentre.y)
        let transform = CGAffineTransform(translationX: centre.x + pose.shift * size.height, y: centre.y)
            .rotated(by: pose.tilt)
            .translatedBy(x: -centre.x, y: -centre.y)
        return ProjectionTransform(transform)
    }
}

#if canImport(UIKit)
import UIKit

/// For a caller that draws the dot itself, in a layer it moves outside SwiftUI
/// (the drawer's header in the Ripul app). Pass `dot: .clear` to leave the
/// logo's own dot out, and lay this over the logo at the same size.
@available(iOS 15.0, *)
public extension RipulWordmark {
    /// The dot alone, on the logo's whole canvas, as a template image.
    static var dotImage: UIImage? {
        UIImage(named: "RipulWordmarkDot", in: .module, compatibleWith: nil)?.withRenderingMode(.alwaysTemplate)
    }

    /// The dot's centre on that canvas, as a share of its width and height.
    static var dotCentre: CGPoint { RipulWordmarkBob.dotCentre }
}
#endif

#if canImport(UIKit)
/// The moving logo as two image layers, with the sway and the breathing given to
/// Core Animation whole: the render server plays them, so a busy main thread
/// cannot drop their frames.
@available(iOS 15.0, *)
private struct RipulWordmarkLayers: UIViewRepresentable {
    let dot: Color?
    let bobs: Bool
    let breath: RipulWordmark.Breath?

    /// Width over height of the logo's canvas.
    static let aspect: CGFloat = {
        guard let size = UIImage(named: "RipulWordmarkText", in: .module, compatibleWith: nil)?.size, size.height > 0 else { return 3 }
        return size.width / size.height
    }()

    func makeUIView(context: Context) -> Canvas {
        let view = Canvas()
        view.bobs = bobs
        return view
    }

    func updateUIView(_ view: Canvas, context: Context) {
        view.dot.tintColor = dot.map(UIColor.init) ?? Canvas.ink
        view.breath = breath
    }

    final class Canvas: UIView {
        let text = UIImageView(image: UIImage(named: "RipulWordmarkText", in: .module, compatibleWith: nil)?.withRenderingMode(.alwaysTemplate))
        let dot = UIImageView(image: RipulWordmark.dotImage)
        var bobs = false
        var breath: RipulWordmark.Breath? { didSet { if breath != oldValue { breathe() } } }
        private var swayed = false
        static var ink: UIColor { UIColor.ripul(.text) } // theme-mapping: new; a logo drawn in layers takes the theme's text colour itself

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            text.tintColor = Self.ink
            for part in [text, dot] {
                part.contentMode = .scaleAspectFit
                addSubview(part)
            }
            // The dot is the logo's whole canvas, turned about the dot itself.
            dot.layer.anchorPoint = RipulWordmarkBob.dotCentre
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layoutSubviews() {
            super.layoutSubviews()
            text.frame = bounds
            dot.bounds = bounds
            dot.center = CGPoint(x: bounds.width * RipulWordmarkBob.dotCentre.x, y: bounds.height * RipulWordmarkBob.dotCentre.y)
            sway()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            // A layer's animations are dropped when it leaves a window.
            if window != nil { breathe(); sway() }
        }

        /// The dot's one sway, as keyframes of the pose `RipulWordmarkBob` gives.
        private func sway() {
            guard bobs, !swayed, window != nil, bounds.height > 0 else { return }
            swayed = true
            let steps = 144
            let animation = CAKeyframeAnimation(keyPath: "transform")
            animation.values = (0...steps).map { step -> NSValue in
                let pose = RipulWordmarkBob.pose(at: CGFloat(step) / CGFloat(steps))
                let slid = CATransform3DMakeTranslation(pose.shift * bounds.height, 0, 0)
                return NSValue(caTransform3D: CATransform3DRotate(slid, pose.tilt, 0, 0, 1))
            }
            animation.calculationMode = .linear
            animation.duration = RipulWordmarkBob.duration
            animation.beginTime = dot.layer.convertTime(CACurrentMediaTime(), from: nil) + RipulWordmarkBob.delay
            dot.layer.add(animation, forKey: "sway")
        }

        private func breathe() {
            layer.removeAnimation(forKey: "breath.scale")
            layer.removeAnimation(forKey: "breath.opacity")
            guard let breath, window != nil else { return }
            func back(_ keyPath: String, _ from: Double, _ to: Double) -> CABasicAnimation {
                let animation = CABasicAnimation(keyPath: keyPath)
                animation.fromValue = from
                animation.toValue = to
                animation.duration = breath.duration
                animation.autoreverses = true
                animation.repeatCount = .infinity
                animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                return animation
            }
            layer.add(back("transform.scale", Double(breath.scale.lowerBound), Double(breath.scale.upperBound)), forKey: "breath.scale")
            layer.add(back("opacity", breath.opacity.lowerBound, breath.opacity.upperBound), forKey: "breath.opacity")
        }
    }
}
#endif

