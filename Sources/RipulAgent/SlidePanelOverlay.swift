import SwiftUI

// MARK: - Animatable Horizontal Slide

/// Animatable horizontal slide using Core Animation transform (no UIKit layout).
/// Unlike `.transformEffect`, this conforms to `Animatable` via `animatableData`
/// so SwiftUI can interpolate the offset with `withAnimation` / `.animation`.
/// Captures the backing UIView of any SwiftUI view so callers can apply
/// CALayer transforms directly (bypassing the SwiftUI render loop).
///
/// Ported verbatim from the native app (`iOS/SlidePanelOverlay.swift`) as part of
/// the M8 whole-screen extraction — keep semantics identical to the app.
#if os(iOS)
import UIKit

public struct UIViewCapture: UIViewRepresentable {
    let onCapture: (UIView) -> Void

    public init(onCapture: @escaping (UIView) -> Void) {
        self.onCapture = onCapture
    }

    public func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = false
        // Report the superview one run-loop tick later so it is already in the
        // hierarchy when the caller stores the reference.
        DispatchQueue.main.async {
            if let parent = v.superview { self.onCapture(parent) }
        }
        return v
    }

    public func updateUIView(_ uiView: UIView, context: Context) {}
}

public struct SlideEffect: GeometryEffect {
    public var offset: CGFloat
    /// The offset the view rests at; the rest of `offset` is a slide carrying
    /// it. Zero except where a view rests away from its origin (a split's
    /// chat, beside the list).
    var rest: CGFloat = 0
    /// Told, as each frame is drawn, how far from `rest` that frame puts the
    /// view (see `SlideDisplacement`).
    var displacement: SlideDisplacement?
    /// The display's pixels per point, to move by whole pixels; 0 moves by
    /// whatever the frame gives.
    var scale: CGFloat = 0

    public init(offset: CGFloat) {
        self.offset = offset
    }

    init(offset: CGFloat, rest: CGFloat, displacement: SlideDisplacement, scale: CGFloat = 0) {
        self.offset = offset
        self.rest = rest
        self.displacement = displacement
        self.scale = scale
    }

    public var animatableData: CGFloat {
        get { offset }
        set { offset = newValue }
    }

    public func effectValue(size: CGSize) -> ProjectionTransform {
        // Every frame of a drag or a spring comes through here, with the
        // offset that frame draws. By whole pixels: between two, the carried
        // views' edges fall on the pixel grid separately and a page measured
        // a pixel wider or narrower mid-slide (the Agents list, 382 to
        // 382.33 pt, laid out again under the finger, 5 November 2026).
        let drawn = scale > 0 ? (offset * scale).rounded() / scale : offset
        let x = drawn - rest
        if let displacement, displacement.x != x { SlideResizeWatch.moved(x) }
        displacement?.x = x
        return ProjectionTransform(CGAffineTransform(translationX: drawn, y: 0))
    }
}

/// How far a slide draws the views it carries from where they rest, as of the
/// frame last drawn. SwiftUI carries out a slide by moving the frames of the
/// UIKit views it carries, not by transforming them (measured on the Duo
/// simulator, 1 November 2026: no transform anywhere up the chain), so a view
/// inside that asks UIKit where it is in its window (`RailGutters`, the
/// composer's resting place) is told where the finger has it. Deciding a
/// layout by that changed the layout under the finger: on an iPhone Duo the
/// chat's back swipe carries it toward the tab rail, and the moment it moved
/// the messages and composer lost 12pt of width and the composer rose 26pt,
/// then all of it sprang back when the swipe was given up (Peter). Such a view
/// takes `x` off what UIKit reports. Plain storage, not observable: writing it
/// as each frame is drawn re-renders nothing. Public for a host's own slide
/// of a screen holding the chat (Home's way back, in the Ripul app), which
/// carries the chat's own slide: the views inside take off both (`total`).
public final class SlideDisplacement {
    public var x: CGFloat = 0
    /// The slide carrying this one, if any.
    weak var outer: SlideDisplacement?
    /// How far every slide carrying the view has it from where it rests.
    var total: CGFloat { x + (outer?.total ?? 0) }
    public init() {}
}

private struct RipulSlideDisplacementKey: EnvironmentKey {
    static let defaultValue: SlideDisplacement? = nil
}

extension EnvironmentValues {
    /// The slide carrying this view, if any (see `SlideDisplacement`).
    var ripulSlideDisplacement: SlideDisplacement? {
        get { self[RipulSlideDisplacementKey.self] }
        set { self[RipulSlideDisplacementKey.self] = newValue }
    }
}

extension View {
    /// Slides this view sideways by `offset`, as `SlideEffect` does, and tells
    /// the views it carries how far that is from `rest` (`SlideDisplacement`),
    /// so a view that places itself by where it is in the window keeps its
    /// layout while it is carried.
    public func slide(by offset: CGFloat, rest: CGFloat = 0, displacement: SlideDisplacement) -> some View {
        modifier(CarriedSlide(offset: offset, rest: rest, displacement: displacement))
    }
}

/// Accepts the proposed size during sizing while passing the full container
/// bounds (including any safe area `.ignoresSafeArea` expanded into) to its
/// child during placement, so adding `.safeAreaInset` inside `CarriedSlide`
/// never widens a fixed-width caller such as `SessionChatColumns`.
private struct CarriedSlideLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let size = subview.sizeThatFits(proposal)
        return CGSize(width: proposal.width ?? size.width, height: proposal.height ?? size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let subview = subviews.first else { return }
        subview.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
}

/// A slide that knows the slide carrying it, so the views inside take off
/// both (`SlideDisplacement.total`), and pins the resting horizontal safe area
/// across the slide so neither SwiftUI nor UIKit reflows the moving page as it
/// crosses a side safe-area strip (such as the closed iPhone Duo's tab rail).
private struct CarriedSlide: ViewModifier {
    let offset: CGFloat
    let rest: CGFloat
    let displacement: SlideDisplacement
    @Environment(\.ripulSlideDisplacement) private var outer
    @Environment(\.displayScale) private var displayScale
    @State private var leadingSafe: CGFloat = 0
    @State private var trailingSafe: CGFloat = 0
    /// A reading has been taken with nothing carrying the view: from then on
    /// readings wait for rest (`take`).
    @State private var settled = false
    /// A reading that came while the view was carried, for when it rests.
    @State private var pending: EdgeInsets?

    func body(content: Content) -> some View {
        // Plain storage, as `x` is: linking it re-renders nothing.
        if displacement.outer !== outer, outer !== displacement { displacement.outer = outer }
        let hasHorizontalSafeArea = rest == 0 && (leadingSafe > 0 || trailingSafe > 0)
        return CarriedSlideLayout {
            ZStack(alignment: .topLeading) {
                if hasHorizontalSafeArea {
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                content
            }
            .safeAreaInset(edge: .leading, spacing: 0) {
                Color.clear.frame(width: rest == 0 ? leadingSafe : 0).allowsHitTesting(false).accessibilityHidden(true)
            }
            .safeAreaInset(edge: .trailing, spacing: 0) {
                Color.clear.frame(width: rest == 0 ? trailingSafe : 0).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .environment(\.ripulSlideDisplacement, displacement)
        .modifier(SlideEffect(offset: offset, rest: rest, displacement: displacement, scale: displayScale))
        .ignoresSafeArea(.container, edges: hasHorizontalSafeArea ? .horizontal : [])
        .background {
            Color.clear
                .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { take($0) }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .onChange(of: abs(offset - rest) < 0.5) { _, atRest in
            guard atRest, let waiting = pending else { return }
            pending = nil
            take(waiting, atRest: true)
        }
    }

    /// The side insets where the view rests. In whole points: under a moving
    /// slide the reading wandered by a sixth of a point either way (84.17,
    /// 83.83), and each one laid the whole page out again under the finger
    /// (the Agents list, a 210 ms stall on the Duo simulator, 5 November
    /// 2026). Once read at rest, held while anything carries the view.
    private func take(_ insets: EdgeInsets, atRest: Bool = false) {
        let leading = insets.leading.rounded(), trailing = insets.trailing.rounded()
        // At rest by this slide's own offset: its last frame may not have told the displacement yet.
        let carried = !atRest && abs(displacement.total) >= 0.5
        if carried && settled {
            let waiting: EdgeInsets? = leading != leadingSafe || trailing != trailingSafe ? insets : nil
            if pending != waiting { pending = waiting }
            return
        }
        if !carried && !settled { settled = true }
        guard leadingSafe != leading || trailingSafe != trailing else { return }
        SlideResizeWatch.log("CarriedSlide rest \(rest) sides \(leadingSafe),\(trailingSafe) -> \(leading),\(trailing)")
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            leadingSafe = leading
            trailingSafe = trailing
        }
    }
}

// MARK: - Slide Panel Overlay

/// Reusable slide-in panel container that manages:
/// - Horizontal slide animation via `SlideEffect`
/// - Left-edge swipe to dismiss via `InteractiveEdgeSwipeView`
/// - Optional scrim backdrop
/// - Solid background and safe-area top inset
/// - Dismiss coordination: animate offset, delay boolean flip so the view stays mounted
///
/// **Parent owns both `isPresented` and `offset` bindings.**
/// - To reveal via swipe: update `offset` progressively, then set `isPresented = true` + `offset = 0`.
/// - To reveal programmatically: set `isPresented = true`; the container animates `offset` to 0.
/// - To dismiss: set `isPresented = false`; the container animates out and stays mounted during the transition.
/// - The container also dismisses on left-edge swipe commit or scrim tap.
public struct SlidePanelOverlay<Content: View>: View {
    @Binding var isPresented: Bool
    @Binding var offset: CGFloat
    public var showsScrim: Bool = true
    public var topInset: CGFloat = 52
    public var containerWidth: CGFloat? = nil
    /// Whether the panel's own left-edge swipe dismisses it. Off when the
    /// content has taken that edge for itself (a mirrored Android emulator
    /// reads it as Back), so the recogniser is not installed at all and the
    /// touch reaches the content.
    public var edgeSwipeEnabled: Bool = true
    @ViewBuilder var content: () -> Content

    /// Keeps the view mounted during dismiss animation.
    @State private var keepMounted = false
    @State private var previousLayoutWidth: CGFloat?
    @State private var slideDisplacement = SlideDisplacement()

    @State private var measuredWidth: CGFloat = 1
    private var screenWidth: CGFloat { max(1, containerWidth ?? measuredWidth) }

    /// Mount when presented, during dismiss animation, or when being revealed by an external swipe.
    private var shouldMount: Bool {
        isPresented || keepMounted || (previousLayoutWidth != nil && offset < min(screenWidth, previousLayoutWidth ?? screenWidth))
    }

    public init(
        isPresented: Binding<Bool>,
        offset: Binding<CGFloat>,
        showsScrim: Bool = true,
        topInset: CGFloat = GlassTopBarLayout.contentReservation,
        containerWidth: CGFloat? = nil,
        edgeSwipeEnabled: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self._isPresented = isPresented
        self._offset = offset
        self.showsScrim = showsScrim
        self.topInset = topInset
        self.containerWidth = containerWidth
        self.edgeSwipeEnabled = edgeSwipeEnabled
        self.content = content
    }

    public var body: some View {
        ZStack { panelBody }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measuredWidth = max(1, $0) }
        .onChange(of: screenWidth, initial: true) { oldWidth, width in
            // A larger container is not a right-edge reveal gesture. Move a
            // resting closed panel to its new edge without mounting it.
            let closedWidth = previousLayoutWidth ?? oldWidth
            let initial = previousLayoutWidth == nil
            previousLayoutWidth = width
            if !isPresented && (initial || offset >= closedWidth) {
                offset = width
                keepMounted = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            settleAfterInterruption()
        }
    }

    /// Land a panel the system interrupted mid-slide.
    ///
    /// The offset is only ever strictly between the two edges while a finger
    /// is tracking it — programmatic moves set the model to its destination in
    /// one step and animate the presentation. So a partial offset on
    /// `didBecomeActive`, when no touch can be live, is a drag whose cancel
    /// never reached the owner: backgrounded mid-swipe, a call, Control Centre.
    /// Left alone it sits there, half-revealed, until the next edge swipe.
    /// Panels at either edge — including a dismiss still animating out — are
    /// untouched.
    private func settleAfterInterruption() {
        guard offset > 0, offset < screenWidth else { return }
        NSLog("[FGSETTLE] slide panel settled from offset=\(Int(offset))/\(Int(screenWidth)) presented=\(isPresented)")
        // Stay mounted through the slide-out; the offset observer below
        // unmounts once it has landed, as it does for a bounced-back reveal.
        if !isPresented { keepMounted = true }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            offset = isPresented ? 0 : screenWidth
        }
    }

    @ViewBuilder private var panelBody: some View {
        if shouldMount {
            ZStack {
                if showsScrim {
                    Color.ripul(system: .black).opacity(Double(max(0, 1 - offset / screenWidth)) * 0.3)
                        .ignoresSafeArea()
                        .onTapGesture { performDismiss() }
                }

                content()
                    .safeAreaInset(edge: .top) { Color.clear.frame(height: topInset) }
                    .background(Color.ripul(.canvas))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .slide(by: offset, displacement: slideDisplacement)
                    .overlay(alignment: .leading) {
                        if edgeSwipeEnabled {
                            InteractiveEdgeSwipeView(
                                onChanged: { dragOffset in
                                    var t = Transaction()
                                    t.disablesAnimations = true
                                    withTransaction(t) { offset = dragOffset }
                                },
                                onEnded: { dragOffset, velocity in
                                    if dragOffset > screenWidth * 0.35 || velocity > 400 {
                                        performDismiss()
                                    } else {
                                        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                                            offset = 0
                                        }
                                    }
                                },
                                onCancelled: {
                                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                                        offset = 0
                                    }
                                },
                                maxOffset: screenWidth
                            )
                            .frame(width: 20)
                            .ignoresSafeArea()
                        }
                    }
            }
            .onAppear {
                if isPresented && offset > 0 {
                    // Appearing because the parent set isPresented = true.
                    // onChange(of: isPresented) won't fire for the initial value,
                    // so drive the slide-in animation here.
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        offset = 0
                    }
                } else if !isPresented && offset < screenWidth {
                    // Appearing because offset < screenWidth (external reveal swipe) —
                    // keep mounted so bounce-back animation slides instead of fading.
                    keepMounted = true
                }
            }
            .onChange(of: offset) { newOffset in
                // When offset returns to screenWidth during a non-presented reveal,
                // schedule unmount after the slide-out animation completes.
                if newOffset >= screenWidth && !isPresented && keepMounted {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        if offset >= screenWidth && !isPresented {
                            keepMounted = false
                        }
                    }
                }
            }
            .onChange(of: isPresented) { presented in
                if presented {
                    if offset != 0 {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                            offset = 0
                        }
                    }
                } else if offset < screenWidth {
                    // Parent requested dismiss (e.g. back button) — animate out, keep mounted
                    keepMounted = true
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        offset = screenWidth
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        keepMounted = false
                    }
                }
            }
        }
    }

    /// Animate out, then flip `isPresented` after the animation finishes.
    private func performDismiss() {
        keepMounted = true
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            offset = screenWidth
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            isPresented = false
            keepMounted = false
        }
    }
}

// MARK: - Interactive Edge Swipe Gesture

/// Edge-swipe recogniser using `UIScreenEdgePanGestureRecognizer` for
/// precise left-edge gesture detection. Reports offset via `onChanged`
/// so the caller can update SwiftUI state with `withTransaction(disablesAnimations:)`
/// for smooth 120 fps tracking without animation interpolation overhead.
public struct InteractiveEdgeSwipeView: UIViewRepresentable {
    /// Once, when the swipe is recognised and before its first `onChanged`.
    public var onBegan: (() -> Void)? = nil
    public var onChanged: ((CGFloat) -> Void)? = nil
    public let onEnded: (CGFloat, CGFloat) -> Void
    public let onCancelled: () -> Void
    public var maxOffset: CGFloat? = nil
    /// When set, the coordinator applies the CALayer transform directly to this
    /// view during `.changed` — bypassing SwiftUI's state/render cycle entirely
    /// for maximum drag smoothness. `onChanged` is still called for any other
    /// bookkeeping but is NOT needed to drive the visual position during drag.
    public var directTransformTarget: UIView? = nil

    public init(
        onBegan: (() -> Void)? = nil,
        onChanged: ((CGFloat) -> Void)? = nil,
        onEnded: @escaping (CGFloat, CGFloat) -> Void,
        onCancelled: @escaping () -> Void,
        maxOffset: CGFloat? = nil,
        directTransformTarget: UIView? = nil
    ) {
        self.onBegan = onBegan
        self.onChanged = onChanged
        self.onEnded = onEnded
        self.onCancelled = onCancelled
        self.maxOffset = maxOffset
        self.directTransformTarget = directTransformTarget
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(
            onBegan: onBegan,
            onChanged: onChanged,
            onEnded: onEnded,
            onCancelled: onCancelled,
            maxOffset: maxOffset
        )
    }

    public func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let pan = UIScreenEdgePanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )
        pan.edges = .left
        view.addGestureRecognizer(pan)
        return view
    }

    public func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onBegan = onBegan
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
        context.coordinator.onCancelled = onCancelled
        context.coordinator.maxOffset = maxOffset
        context.coordinator.directTransformTarget = directTransformTarget
    }

    public class Coordinator {
        public var onBegan: (() -> Void)?
        public var onChanged: ((CGFloat) -> Void)?
        public var onEnded: (CGFloat, CGFloat) -> Void
        public var onCancelled: () -> Void
        public var maxOffset: CGFloat?
        weak var directTransformTarget: UIView?
        /// Frozen snapshot of the chat layer captured at drag-start so WKWebView
        /// stops repainting under the moving layer. Placed as a subview on top of
        /// all WKWebView content; removed when the gesture ends or cancels.
        private var dragSnapshot: UIView?

        init(
            onBegan: (() -> Void)?,
            onChanged: ((CGFloat) -> Void)?,
            onEnded: @escaping (CGFloat, CGFloat) -> Void,
            onCancelled: @escaping () -> Void,
            maxOffset: CGFloat?
        ) {
            self.onBegan = onBegan
            self.onChanged = onChanged
            self.onEnded = onEnded
            self.onCancelled = onCancelled
            self.maxOffset = maxOffset
        }

        private func attachFreezeOverlay() {
            guard dragSnapshot == nil, let target = directTransformTarget else { return }
            // Plain opaque overlay — no snapshot needed. WKWebView renders out-of-process
            // so synchronous capture is impossible. Instead, cover the live view with a
            // solid background-coloured UIView. The user can't see WKWebView repainting
            // underneath, and touches can't reach it (no accidental scroll during drag).
            let overlay = UIView(frame: target.bounds)
            overlay.backgroundColor = UIColor.ripul(.canvas)
            overlay.isUserInteractionEnabled = false
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            target.addSubview(overlay)
            target.isUserInteractionEnabled = false  // prevent WKWebView scroll during drag
            dragSnapshot = overlay
        }

        private func removeFreezeOverlay(afterDelay seconds: Double = 0) {
            guard let overlay = dragSnapshot else { return }
            dragSnapshot = nil
            directTransformTarget?.isUserInteractionEnabled = true
            if seconds <= 0 {
                overlay.removeFromSuperview()
            } else {
                // Remove after the spring animation settles so the overlay doesn't
                // pop away mid-animation exposing the WKWebView at the wrong position.
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                    overlay.removeFromSuperview()
                }
            }
        }

        @objc func handlePan(_ recognizer: UIScreenEdgePanGestureRecognizer) {
            let referenceView = recognizer.view?.window
            let limit = maxOffset ?? directWidth(recognizer.view)
            let translation = recognizer.translation(in: referenceView)
            let offset = max(0, min(limit, translation.x))

            switch recognizer.state {
            case .began:
                onBegan?()
            case .changed:
                attachFreezeOverlay()
                onChanged?(offset)
            case .ended:
                // Keep overlay visible until the spring animation completes so there's
                // no flash of WKWebView at the wrong position mid-animation.
                let velocity = recognizer.velocity(in: referenceView).x
                removeFreezeOverlay(afterDelay: 0.4)
                onEnded(offset, velocity)
            case .cancelled, .failed:
                removeFreezeOverlay(afterDelay: 0.35)
                onCancelled()
            default:
                break
            }
        }
    }
}

// MARK: - Right Edge Swipe Gesture

/// Right-edge swipe recogniser — mirror of `InteractiveEdgeSwipeView` for the trailing edge.
/// Reports a positive offset representing how far from the right edge the finger has moved.
public struct RightEdgeSwipeView: UIViewRepresentable {
    public var onChanged: ((CGFloat) -> Void)? = nil
    public let onEnded: (CGFloat, CGFloat) -> Void
    public let onCancelled: () -> Void
    public var maxOffset: CGFloat? = nil

    public init(
        onChanged: ((CGFloat) -> Void)? = nil,
        onEnded: @escaping (CGFloat, CGFloat) -> Void,
        onCancelled: @escaping () -> Void,
        maxOffset: CGFloat? = nil
    ) {
        self.onChanged = onChanged
        self.onEnded = onEnded
        self.onCancelled = onCancelled
        self.maxOffset = maxOffset
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(
            onChanged: onChanged,
            onEnded: onEnded,
            onCancelled: onCancelled,
            maxOffset: maxOffset
        )
    }

    public func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let pan = UIScreenEdgePanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )
        pan.edges = .right
        view.addGestureRecognizer(pan)
        return view
    }

    public func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
        context.coordinator.onCancelled = onCancelled
        context.coordinator.maxOffset = maxOffset
    }

    public class Coordinator {
        public var onChanged: ((CGFloat) -> Void)?
        public var onEnded: (CGFloat, CGFloat) -> Void
        public var onCancelled: () -> Void
        public var maxOffset: CGFloat?

        init(
            onChanged: ((CGFloat) -> Void)?,
            onEnded: @escaping (CGFloat, CGFloat) -> Void,
            onCancelled: @escaping () -> Void,
            maxOffset: CGFloat?
        ) {
            self.onChanged = onChanged
            self.onEnded = onEnded
            self.onCancelled = onCancelled
            self.maxOffset = maxOffset
        }

        @objc func handlePan(_ recognizer: UIScreenEdgePanGestureRecognizer) {
            let referenceView = recognizer.view?.window
            let limit = maxOffset ?? directWidth(recognizer.view)
            let translation = recognizer.translation(in: referenceView)
            let offset = max(0, min(limit, -translation.x))

            switch recognizer.state {
            case .changed:
                onChanged?(offset)
            case .ended:
                let velocity = -recognizer.velocity(in: referenceView).x
                onEnded(offset, velocity)
            case .cancelled, .failed:
                onCancelled()
            default:
                break
            }
        }
    }
}

private func directWidth(_ view: UIView?) -> CGFloat {
    max(1, view?.superview?.bounds.width ?? view?.window?.bounds.width ?? 1)
}

// MARK: - Keyboard-Stable Top Bar Support

/// Tracks the parent view's global Y position so overlays can counteract
/// keyboard-driven upward shifts. Each screen adds a `.background { GeometryReader }`
/// that writes to this key, then reads it via `.onPreferenceChange` to offset the top bar.
public struct KeyboardStableYKey: PreferenceKey {
    public static var defaultValue: CGFloat = 0
    public static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
#endif
