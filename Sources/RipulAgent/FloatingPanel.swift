#if os(iOS)
import SwiftUI
import UIKit

// MARK: - Ripul Floating Panel
//
// The one implementation of "a HUD panel that floats over the app: drag to move,
// drag the corner to resize, remember where it was." Use this for every floating
// dev/debug panel instead of hand-rolling the gesture math again.
//
// ─────────────────────────────────────────────────────────────────────────────
// WHY THIS EXISTS — the resize-flicker bug, written down once so it stays fixed
// ─────────────────────────────────────────────────────────────────────────────
//
// A resize grip lives INSIDE the panel, so it moves as the panel resizes. That
// creates two feedback loops, and either one makes the panel visibly oscillate
// between two sizes/positions at frame rate while you drag:
//
//   1. Measuring the grip's drag translation in its OWN (moving) coordinate
//      space. Frame N grows the panel → the grip slides out from under the
//      finger → frame N+1 reads a translation that already includes the growth
//      → it grows again, then snaps back. `CpuHudView` hit this and fixed it
//      locally with `DragGesture(coordinateSpace: .global)`.
//
//   2. Re-clamping the panel's POSITION on every layout pass. Growing the panel
//      shrinks the "how far right/down may the origin sit" budget, so the clamp
//      shoves the panel up-left — which moves the grip — which perturbs the next
//      translation. This one bites even with a stable coordinate space.
//
// This container closes both:
//
//   • Resize translation is measured in the CONTAINER's coordinate space — a
//     full-screen view that never moves — not in the grip.
//   • Resize ANCHORS THE TOP-LEFT. The size is clamped so the bottom-right stays
//     inside the safe area; the position is never touched during a resize. The
//     layout re-clamp is suppressed while `isResizing` (and while dragging), so
//     nothing can move the panel out from under the finger.
//
// Move and resize both stay in UIKit and drive `transform` / constraints
// directly, bypassing SwiftUI's state-and-render round-trip for 1:1 60fps
// tracking under the finger.

/// A floating, draggable, resizable panel hosting SwiftUI content.
///
/// Position and size persist under `storageKey`:
/// `<storageKey>.posX`, `.posY`, `.w`, `.h`.
///
/// The content builder receives the panel's current size. Content decides how to
/// spend it — typically `.frame(width: size.width)` plus a scroll area bounded by
/// `size.height`, which lets a collapsed/folded panel hug its own content instead
/// of being stretched to the stored height.
///
///     RipulFloatingPanel(storageKey: "myTool",
///                        defaultSize: CGSize(width: 320, height: 240),
///                        showsResizeGrip: !folded) { size in
///         MyPanelContent(size: size)
///     }
@available(iOS 16.0, *)
public struct RipulFloatingPanel<Content: View>: View {
    private let storageKey: String
    private let defaultSize: CGSize
    private let minSize: CGSize
    private let showsResizeGrip: Bool
    private let gripTint: UIColor
    private let store: UserDefaults
    private let content: (CGSize) -> Content

    /// Live size during a resize drag. nil until the persisted value is read.
    @State private var liveSize: CGSize?

    public init(storageKey: String,
                defaultSize: CGSize,
                minSize: CGSize = CGSize(width: 220, height: 180),
                showsResizeGrip: Bool = true,
                gripTint: UIColor = UIColor.white.withAlphaComponent(0.55),
                store: UserDefaults = .standard,
                @ViewBuilder content: @escaping (CGSize) -> Content) {
        self.storageKey = storageKey
        self.defaultSize = defaultSize
        self.minSize = minSize
        self.showsResizeGrip = showsResizeGrip
        self.gripTint = gripTint
        self.store = store
        self.content = content
    }

    public var body: some View {
        let size = liveSize ?? persistedSize
        FloatingPanelHost(
            content: content(size),
            size: size,
            minSize: minSize,
            showsResizeGrip: showsResizeGrip,
            gripTint: gripTint,
            posXKey: "\(storageKey).posX",
            posYKey: "\(storageKey).posY",
            store: store,
            onResize: { liveSize = $0 },
            onResizeEnded: { persist($0) }
        )
    }

    private var persistedSize: CGSize {
        let w = store.double(forKey: "\(storageKey).w")
        let h = store.double(forKey: "\(storageKey).h")
        guard w > 0, h > 0 else { return defaultSize }
        return CGSize(width: w, height: h)
    }

    private func persist(_ size: CGSize) {
        store.set(Double(size.width), forKey: "\(storageKey).w")
        store.set(Double(size.height), forKey: "\(storageKey).h")
    }
}

// MARK: - Representable

@available(iOS 16.0, *)
private struct FloatingPanelHost<Content: View>: UIViewControllerRepresentable {
    let content: Content
    let size: CGSize
    let minSize: CGSize
    let showsResizeGrip: Bool
    let gripTint: UIColor
    let posXKey: String
    let posYKey: String
    let store: UserDefaults
    let onResize: (CGSize) -> Void
    let onResizeEnded: (CGSize) -> Void

    func makeUIViewController(context: Context) -> RipulFloatingPanelController<Content> {
        RipulFloatingPanelController(
            content: content,
            size: size,
            minSize: minSize,
            showsResizeGrip: showsResizeGrip,
            gripTint: gripTint,
            posXKey: posXKey,
            posYKey: posYKey,
            store: store,
            onResize: onResize,
            onResizeEnded: onResizeEnded
        )
    }

    func updateUIViewController(_ vc: RipulFloatingPanelController<Content>, context: Context) {
        vc.update(content: content,
                  size: size,
                  showsResizeGrip: showsResizeGrip,
                  onResize: onResize,
                  onResizeEnded: onResizeEnded)
    }
}

// MARK: - Root view (touch passthrough)

/// Root view of a floating panel: only claims touches landing on the panel itself.
/// Everything else returns nil from `hitTest`, so views below in the SwiftUI ZStack
/// (and the app underneath) keep receiving touches.
///
/// Named and non-private so hit-walks — notably `ViewInspectorController.isInspectorOwnView`
/// — can recognise panel chrome and skip it.
final class RipulFloatingPanelRootView: UIView {
    weak var panelView: UIView?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let panel = panelView, !panel.isHidden, panel.alpha > 0.01 else { return nil }
        // `panel` is positioned with a transform, so test against its presentation
        // frame rather than converting into untransformed bounds.
        guard panel.frame.contains(point) else { return nil }
        return panel.hitTest(panel.convert(point, from: self), with: event)
    }
}

// MARK: - Grip

/// The bottom-right resize affordance. A plain UIKit view so the container owns the
/// gesture outright — a SwiftUI grip would have to route its translation back through
/// SwiftUI state, which is feedback loop #1 above.
private final class FloatingPanelGripView: UIView {
    private let icon = UIImageView()

    init(tint: UIColor) {
        super.init(frame: .zero)
        backgroundColor = .clear
        icon.image = UIImage(systemName: "arrow.down.right",
                             withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .bold))
        icon.tintColor = tint
        icon.contentMode = .center
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        NSLayoutConstraint.activate([
            icon.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            icon.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

/// Pan that fails outright when a touch ends without ever panning, so taps still
/// reach the SwiftUI buttons inside the panel. (UIPanGestureRecognizer supplies the
/// movement slop itself; this only adds the fail-on-tap.)
private final class ThresholdPanGesture: UIPanGestureRecognizer {
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .possible { state = .failed }
        super.touchesEnded(touches, with: event)
    }
}

// MARK: - Controller

/// Hosts the SwiftUI content in a movable, resizable panel over a passthrough root.
///
/// Layout:
///
///     RipulFloatingPanelRootView   full screen, passthrough
///     └── panelView                transform-positioned, hugs the hosting view
///         ├── hosting.view         SwiftUI content (intrinsic size)
///         └── grip                 44×44, bottom-trailing
///
/// The transform is applied to `panelView` (not the hosting view) so the grip travels
/// with the panel while staying a layout sibling of the content.
@available(iOS 16.0, *)
final class RipulFloatingPanelController<Content: View>: UIViewController, UIGestureRecognizerDelegate {
    private let posXKey: String
    private let posYKey: String
    private let store: UserDefaults
    private let minSize: CGSize

    private let panelView = UIView()
    private let grip: FloatingPanelGripView
    private var hosting: UIHostingController<Content>!

    /// The size handed to the content — the resize base, so growth can't drift the
    /// way it would if we measured the laid-out bounds each frame.
    private var size: CGSize
    private var onResize: (CGSize) -> Void
    private var onResizeEnded: (CGSize) -> Void

    private var dragStartTransform: CGAffineTransform = .identity
    private var sizeAtResizeStart: CGSize = .zero
    private var hasRestoredPosition = false
    private var isDragging = false
    private var isResizing = false

    init(content: Content,
         size: CGSize,
         minSize: CGSize,
         showsResizeGrip: Bool,
         gripTint: UIColor,
         posXKey: String,
         posYKey: String,
         store: UserDefaults,
         onResize: @escaping (CGSize) -> Void,
         onResizeEnded: @escaping (CGSize) -> Void) {
        self.size = size
        self.minSize = minSize
        self.posXKey = posXKey
        self.posYKey = posYKey
        self.store = store
        self.onResize = onResize
        self.onResizeEnded = onResizeEnded
        self.grip = FloatingPanelGripView(tint: gripTint)
        super.init(nibName: nil, bundle: nil)
        self.hosting = UIHostingController(rootView: content)
        self.grip.isHidden = !showsResizeGrip
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = RipulFloatingPanelRootView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.clipsToBounds = false

        panelView.backgroundColor = .clear
        panelView.clipsToBounds = false
        panelView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panelView)

        addChild(hosting)
        hosting.view.backgroundColor = .clear
        hosting.view.clipsToBounds = false
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        panelView.addSubview(hosting.view)
        hosting.didMove(toParent: self)
        hosting.sizingOptions = .intrinsicContentSize

        grip.translatesAutoresizingMaskIntoConstraints = false
        panelView.addSubview(grip)

        NSLayoutConstraint.activate([
            // panelView is pinned to the root's top-leading; `transform` moves it from there.
            panelView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            panelView.topAnchor.constraint(equalTo: view.topAnchor),
            // panelView hugs the SwiftUI content.
            hosting.view.leadingAnchor.constraint(equalTo: panelView.leadingAnchor),
            hosting.view.topAnchor.constraint(equalTo: panelView.topAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: panelView.trailingAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: panelView.bottomAnchor),
            // Grip rides the panel's bottom-right corner.
            grip.trailingAnchor.constraint(equalTo: panelView.trailingAnchor),
            grip.bottomAnchor.constraint(equalTo: panelView.bottomAnchor),
            grip.widthAnchor.constraint(equalToConstant: 44),
            grip.heightAnchor.constraint(equalToConstant: 44),
        ])

        let move = ThresholdPanGesture(target: self, action: #selector(handleMove(_:)))
        move.maximumNumberOfTouches = 1
        move.delegate = self
        panelView.addGestureRecognizer(move)

        let resize = UIPanGestureRecognizer(target: self, action: #selector(handleResize(_:)))
        resize.maximumNumberOfTouches = 1
        grip.addGestureRecognizer(resize)

        (view as? RipulFloatingPanelRootView)?.panelView = panelView

        // Position is restored + clamped in viewDidLayoutSubviews, once there's a
        // window and a real panel size — the first point at which safe-area insets
        // are meaningful. Clamping here would run against zero insets and could
        // strand the panel under the notch or home indicator.
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard panelView.bounds.width > 0 else { return }
        // Never re-position under an active gesture: during a resize this is
        // feedback loop #2, and during a move the pan already owns the transform.
        guard !isDragging, !isResizing else { return }

        let proposed: CGPoint
        if !hasRestoredPosition {
            guard view.window != nil else { return }
            hasRestoredPosition = true
            proposed = CGPoint(x: store.double(forKey: posXKey),
                               y: store.double(forKey: posYKey))
        } else {
            // Rotation / content-size change (e.g. unfolding near an edge):
            // re-clamp so the panel can never be stranded in a safe area.
            proposed = CGPoint(x: panelView.transform.tx, y: panelView.transform.ty)
        }
        applyPosition(clampedTranslation(proposed))
    }

    // MARK: Position

    private func applyPosition(_ p: CGPoint) {
        panelView.transform = CGAffineTransform(translationX: p.x, y: p.y)
        if store.double(forKey: posXKey) != p.x { store.set(p.x, forKey: posXKey) }
        if store.double(forKey: posYKey) != p.y { store.set(p.y, forKey: posYKey) }
    }

    /// Clamp a proposed top-left translation so the panel stays fully within the safe
    /// area — never under the notch, status bar, home indicator, or landscape sensor
    /// housing. We read the window's insets because SwiftUI can zero out a child
    /// controller's own insets under `.ignoresSafeArea()`.
    private func clampedTranslation(_ proposed: CGPoint) -> CGPoint {
        let margin: CGFloat = 8
        let insets = view.window?.safeAreaInsets ?? view.safeAreaInsets
        let bounds = view.bounds.size
        let panel = panelView.bounds.size

        let minX = insets.left + margin
        let minY = insets.top + margin
        // max(minX, …) guards a panel wider/taller than the safe region — keep the
        // top-left anchored just inside it.
        let maxX = max(minX, bounds.width - insets.right - margin - panel.width)
        let maxY = max(minY, bounds.height - insets.bottom - margin - panel.height)

        return CGPoint(x: min(max(proposed.x, minX), maxX),
                       y: min(max(proposed.y, minY), maxY))
    }

    @objc private func handleMove(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            isDragging = true
            dragStartTransform = panelView.transform
        case .changed:
            // Clamp live so the panel hard-stops at the safe-area edge rather than
            // being draggable under the notch and snapped back on release.
            let t = gesture.translation(in: view)
            let clamped = clampedTranslation(CGPoint(x: dragStartTransform.tx + t.x,
                                                     y: dragStartTransform.ty + t.y))
            panelView.transform = CGAffineTransform(translationX: clamped.x, y: clamped.y)
        case .ended, .cancelled:
            let t = gesture.translation(in: view)
            let clamped = clampedTranslation(CGPoint(x: dragStartTransform.tx + t.x,
                                                     y: dragStartTransform.ty + t.y))
            isDragging = false
            applyPosition(clamped)
        default:
            isDragging = false
        }
    }

    // MARK: Resize

    /// Clamp a proposed size against the panel's CURRENT top-left. Resizing never
    /// moves the panel — it only grows or shrinks toward the bottom-right, stopping
    /// at the safe-area edge. That's what keeps the grip still under the finger.
    private func clampedSize(_ proposed: CGSize) -> CGSize {
        let margin: CGFloat = 8
        let insets = view.window?.safeAreaInsets ?? view.safeAreaInsets
        let origin = CGPoint(x: panelView.transform.tx, y: panelView.transform.ty)

        let maxW = max(minSize.width, view.bounds.width - insets.right - margin - origin.x)
        let maxH = max(minSize.height, view.bounds.height - insets.bottom - margin - origin.y)

        return CGSize(width: min(max(proposed.width, minSize.width), maxW),
                      height: min(max(proposed.height, minSize.height), maxH))
    }

    @objc private func handleResize(_ gesture: UIPanGestureRecognizer) {
        // Translation is measured in `view` — the full-screen root, which never
        // moves. Measuring in the grip (which slides as the panel grows) is
        // feedback loop #1.
        let t = gesture.translation(in: view)
        let proposed = CGSize(width: sizeAtResizeStart.width + t.x,
                              height: sizeAtResizeStart.height + t.y)

        switch gesture.state {
        case .began:
            isResizing = true
            sizeAtResizeStart = size
        case .changed:
            onResize(clampedSize(proposed))
        case .ended, .cancelled:
            let final = clampedSize(proposed)
            isResizing = false
            onResize(final)
            onResizeEnded(final)
        default:
            isResizing = false
        }
    }

    // MARK: Updates

    func update(content: Content,
                size: CGSize,
                showsResizeGrip: Bool,
                onResize: @escaping (CGSize) -> Void,
                onResizeEnded: @escaping (CGSize) -> Void) {
        self.size = size
        self.onResize = onResize
        self.onResizeEnded = onResizeEnded
        grip.isHidden = !showsResizeGrip
        hosting.rootView = content
    }

    // MARK: Gesture arbitration

    /// The grip owns its corner: reject move-pan touches that land on it, so dragging
    /// the corner resizes rather than repositioning.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard !grip.isHidden else { return true }
        return !grip.frame.contains(touch.location(in: panelView))
    }
}
#endif
