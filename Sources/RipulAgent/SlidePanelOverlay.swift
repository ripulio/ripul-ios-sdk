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

    public init(offset: CGFloat) {
        self.offset = offset
    }

    public var animatableData: CGFloat {
        get { offset }
        set { offset = newValue }
    }

    public func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: offset, y: 0))
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
    @ViewBuilder var content: () -> Content

    /// Keeps the view mounted during dismiss animation.
    @State private var keepMounted = false

    private var screenWidth: CGFloat { UIScreen.main.bounds.width }

    /// Mount when presented, during dismiss animation, or when being revealed by an external swipe.
    private var shouldMount: Bool {
        isPresented || keepMounted || offset < screenWidth
    }

    public init(
        isPresented: Binding<Bool>,
        offset: Binding<CGFloat>,
        showsScrim: Bool = true,
        topInset: CGFloat = 52,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self._isPresented = isPresented
        self._offset = offset
        self.showsScrim = showsScrim
        self.topInset = topInset
        self.content = content
    }

    public var body: some View {
        if shouldMount {
            ZStack {
                if showsScrim {
                    Color.black.opacity(Double(max(0, 1 - offset / screenWidth)) * 0.3)
                        .ignoresSafeArea()
                        .onTapGesture { performDismiss() }
                }

                content()
                    .safeAreaInset(edge: .top) { Color.clear.frame(height: topInset) }
                    .background(Color(uiColor: .systemBackground))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .modifier(SlideEffect(offset: offset))
                    .overlay(alignment: .leading) {
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
                            }
                        )
                        .frame(width: 20)
                        .ignoresSafeArea()
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
        onChanged: ((CGFloat) -> Void)? = nil,
        onEnded: @escaping (CGFloat, CGFloat) -> Void,
        onCancelled: @escaping () -> Void,
        maxOffset: CGFloat? = nil,
        directTransformTarget: UIView? = nil
    ) {
        self.onChanged = onChanged
        self.onEnded = onEnded
        self.onCancelled = onCancelled
        self.maxOffset = maxOffset
        self.directTransformTarget = directTransformTarget
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(
            onChanged: onChanged,
            onEnded: onEnded,
            onCancelled: onCancelled,
            maxOffset: maxOffset ?? UIScreen.main.bounds.width
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
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
        context.coordinator.onCancelled = onCancelled
        context.coordinator.maxOffset = maxOffset ?? UIScreen.main.bounds.width
        context.coordinator.directTransformTarget = directTransformTarget
    }

    public class Coordinator {
        public var onChanged: ((CGFloat) -> Void)?
        public var onEnded: (CGFloat, CGFloat) -> Void
        public var onCancelled: () -> Void
        public var maxOffset: CGFloat
        weak var directTransformTarget: UIView?
        /// Frozen snapshot of the chat layer captured at drag-start so WKWebView
        /// stops repainting under the moving layer. Placed as a subview on top of
        /// all WKWebView content; removed when the gesture ends or cancels.
        private var dragSnapshot: UIView?

        init(
            onChanged: ((CGFloat) -> Void)?,
            onEnded: @escaping (CGFloat, CGFloat) -> Void,
            onCancelled: @escaping () -> Void,
            maxOffset: CGFloat
        ) {
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
            overlay.backgroundColor = UIColor.systemBackground
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
            let translation = recognizer.translation(in: referenceView)
            let offset = max(0, min(maxOffset, translation.x))

            switch recognizer.state {
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
            maxOffset: maxOffset ?? UIScreen.main.bounds.width
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
        context.coordinator.maxOffset = maxOffset ?? UIScreen.main.bounds.width
    }

    public class Coordinator {
        public var onChanged: ((CGFloat) -> Void)?
        public var onEnded: (CGFloat, CGFloat) -> Void
        public var onCancelled: () -> Void
        public var maxOffset: CGFloat

        init(
            onChanged: ((CGFloat) -> Void)?,
            onEnded: @escaping (CGFloat, CGFloat) -> Void,
            onCancelled: @escaping () -> Void,
            maxOffset: CGFloat
        ) {
            self.onChanged = onChanged
            self.onEnded = onEnded
            self.onCancelled = onCancelled
            self.maxOffset = maxOffset
        }

        @objc func handlePan(_ recognizer: UIScreenEdgePanGestureRecognizer) {
            let referenceView = recognizer.view?.window
            let translation = recognizer.translation(in: referenceView)
            let offset = max(0, min(maxOffset, -translation.x))

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
