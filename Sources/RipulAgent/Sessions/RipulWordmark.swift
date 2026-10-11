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

    let height: CGFloat
    let dot: Color?
    let bobs: Bool

    @State private var bob: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - dot: A colour for the dot alone. Nil leaves it the colour of the wordmark.
    ///   - bobs: Whether the dot sways left and right once, shortly after the
    ///     logo appears, then settles (see `RipulWordmarkBob`).
    public init(height: CGFloat = 56, dot: Color? = nil, bobs: Bool = false) {
        self.height = height
        self.dot = dot
        self.bobs = bobs
    }

    public var body: some View {
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ripul")
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
