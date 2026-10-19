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
    private let aspectRatio: CGFloat?
    private let contentInsets: UIEdgeInsets
    private let avoidsKeyboard: Bool
    private let movesFromTopStrip: CGFloat?
    private let keepsTrailingEdge: Bool
    private let content: (CGSize) -> Content

    /// Live size during a resize drag. nil until the persisted value is read.
    @State private var liveSize: CGSize?

    /// `aspectRatio` locks width/height during resizing. `contentInsets` reserves
    /// room for surrounding chrome; `avoidsKeyboard` keeps the panel above it.
    /// `movesFromTopStrip` is for content that takes touches itself (a live
    /// screen): the panel is then moved only from that many points at its top.
    /// `keepsTrailingEdge` holds the panel's right edge still when its content
    /// changes width by itself, so a panel minimised from a button at its
    /// top-right shrinks into that button, and grows back out of it.
    public init(storageKey: String,
                defaultSize: CGSize,
                minSize: CGSize = CGSize(width: 220, height: 180),
                showsResizeGrip: Bool = true,
                gripTint: UIColor = UIColor.ripul(system: .white).withAlphaComponent(0.55),
                store: UserDefaults = .standard,
                aspectRatio: CGFloat? = nil,
                contentInsets: UIEdgeInsets = .zero,
                avoidsKeyboard: Bool = false,
                movesFromTopStrip: CGFloat? = nil,
                keepsTrailingEdge: Bool = false,
                @ViewBuilder content: @escaping (CGSize) -> Content) {
        self.storageKey = storageKey
        self.defaultSize = defaultSize
        self.minSize = minSize
        self.showsResizeGrip = showsResizeGrip
        self.gripTint = gripTint
        self.store = store
        self.aspectRatio = aspectRatio
        self.contentInsets = contentInsets
        self.avoidsKeyboard = avoidsKeyboard
        self.movesFromTopStrip = movesFromTopStrip
        self.keepsTrailingEdge = keepsTrailingEdge
        self.content = content
    }

    public var body: some View {
        let storedSize = liveSize ?? persistedSize
        let size = aspectRatio.flatMap { ratio -> CGSize? in
            guard ratio.isFinite, ratio > 0 else { return nil }
            return CGSize(width: storedSize.width, height: storedSize.width / ratio)
        } ?? storedSize
        FloatingPanelHost(
            content: content(size),
            size: size,
            minSize: minSize,
            showsResizeGrip: showsResizeGrip,
            gripTint: gripTint,
            posXKey: "\(storageKey).posX",
            posYKey: "\(storageKey).posY",
            store: store,
            aspectRatio: aspectRatio,
            contentInsets: contentInsets,
            avoidsKeyboard: avoidsKeyboard,
            movesFromTopStrip: movesFromTopStrip,
            keepsTrailingEdge: keepsTrailingEdge,
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

// MARK: - Minimising into the top-right button

/// A preview panel that minimises into a round button at its top-right
/// corner, where its minimise button is, and expands back out of it. Use with
/// `RipulFloatingPanel(keepsTrailingEdge: true)`.
///
/// Nothing changes size while it animates. Animating the panel's frame from
/// its full size down to the button's, inside a panel that UIKit was resizing
/// and moving, threw the picture up and to the right by half its size for the
/// first frames (recorded 14 October 2026), and so did the frame animation
/// alone. So the picture scales toward its top-right corner and fades as the
/// button fades in, and only then does the panel take the button's size;
/// expanding, the panel takes its full size first, under the button, and the
/// picture grows out of the corner.
@available(iOS 17.0, *)
struct FloatingPanelCollapse<Panel: View, Minimised: View>: View {
    let collapsed: Bool
    let expanded: CGSize
    let button: CGFloat
    let animation: Animation?
    let panel: () -> Panel
    let minimised: () -> Minimised
    /// What is drawn, and what size the panel takes. They start as the panel
    /// is, so the first change after it appears is sequenced like the rest.
    @State private var drawn: Bool
    @State private var held: Bool

    init(collapsed: Bool, expanded: CGSize, button: CGFloat = 56, animation: Animation?,
         @ViewBuilder panel: @escaping () -> Panel, @ViewBuilder minimised: @escaping () -> Minimised) {
        self.collapsed = collapsed
        self.expanded = expanded
        self.button = button
        self.animation = animation
        self.panel = panel
        self.minimised = minimised
        _drawn = State(initialValue: collapsed)
        _held = State(initialValue: collapsed)
    }

    /// How long the picture takes to settle into the button.
    static var settle: Duration { .milliseconds(450) }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if !held {
                panel()
                    .scaleEffect(drawn ? button / max(expanded.width, button) : 1, anchor: .topTrailing)
                    .opacity(drawn ? 0 : 1)
                    .allowsHitTesting(!drawn)
                    .accessibilityHidden(drawn)
            }
            minimised()
                .scaleEffect(drawn ? 1 : 0.5)
                .opacity(drawn ? 1 : 0)
                .allowsHitTesting(drawn)
                .accessibilityHidden(!drawn)
        }
        .animation(animation, value: drawn)
        .frame(width: held ? button : expanded.width, height: held ? button : expanded.height, alignment: .topTrailing)
        .onChange(of: collapsed) { _, now in
            guard animation != nil else { self.drawn = now; self.held = now; return }
            if now {
                self.drawn = true
                Task { @MainActor in
                    try? await Task.sleep(for: Self.settle)
                    if self.drawn { self.held = true }
                }
            } else {
                self.held = false
                Task { @MainActor in
                    // The panel has taken its full size, keeping its right edge, by the next frame.
                    try? await Task.sleep(for: .milliseconds(34))
                    if !self.held { self.drawn = false }
                }
            }
        }
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
    let aspectRatio: CGFloat?
    let contentInsets: UIEdgeInsets
    let avoidsKeyboard: Bool
    let movesFromTopStrip: CGFloat?
    let keepsTrailingEdge: Bool
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
            aspectRatio: aspectRatio,
            contentInsets: contentInsets,
            avoidsKeyboard: avoidsKeyboard,
            onResize: onResize,
            onResizeEnded: onResizeEnded
        )
    }

    func updateUIViewController(_ vc: RipulFloatingPanelController<Content>, context: Context) {
        vc.movesFromTopStrip = movesFromTopStrip
        vc.keepsTrailingEdge = keepsTrailingEdge
        vc.update(content: content,
                  size: size,
                  showsResizeGrip: showsResizeGrip,
                  aspectRatio: aspectRatio,
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
    private var aspectRatio: CGFloat?
    private let contentInsets: UIEdgeInsets
    private let avoidsKeyboard: Bool
    private var keyboardFrame: CGRect = .zero

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
    /// Content that takes touches leaves the panel to be moved from its top strip only.
    var movesFromTopStrip: CGFloat?
    /// The right edge stays put when the content changes width by itself.
    var keepsTrailingEdge = false
    /// The panel's width at the last layout, to see the content change it.
    private var laidOutWidth: CGFloat = 0

    init(content: Content,
         size: CGSize,
         minSize: CGSize,
         showsResizeGrip: Bool,
         gripTint: UIColor,
         posXKey: String,
         posYKey: String,
         store: UserDefaults,
         aspectRatio: CGFloat? = nil,
         contentInsets: UIEdgeInsets = .zero,
         avoidsKeyboard: Bool = false,
         onResize: @escaping (CGSize) -> Void,
         onResizeEnded: @escaping (CGSize) -> Void) {
        self.size = size
        self.minSize = minSize
        self.posXKey = posXKey
        self.posYKey = posYKey
        self.store = store
        self.aspectRatio = aspectRatio
        self.contentInsets = contentInsets
        self.avoidsKeyboard = avoidsKeyboard
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
        if posXKey == "viewInspector.posX" { view.tag = ripulViewExplorerOverlayTag }
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
        if avoidsKeyboard {
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
                name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
                name: UIResponder.keyboardWillHideNotification, object: nil)
        }

        // Position is restored + clamped in viewDidLayoutSubviews, once there's a
        // window and a real panel size — the first point at which safe-area insets
        // are meaningful. Clamping here would run against zero insets and could
        // strand the panel under the notch or home indicator.
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = panelView.bounds.width
        guard width > 0 else { return }
        // Read before the gesture guard, so a resize's own growth is never
        // taken for the content changing width.
        let widthBefore = laidOutWidth
        laidOutWidth = width
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
            var x = panelView.transform.tx
            if keepsTrailingEdge, widthBefore > 0, widthBefore != width { x += widthBefore - width }
            proposed = CGPoint(x: x, y: panelView.transform.ty)
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
        let region = availableRegion
        let panel = panelView.bounds.size
        let minX = region.minX
        let minY = region.minY
        // max(minX, …) guards a panel wider/taller than the safe region — keep the
        // top-left anchored just inside it.
        let maxX = max(minX, region.maxX - panel.width)
        let maxY = max(minY, region.maxY - panel.height)

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
    func clampedSize(_ proposed: CGSize) -> CGSize {
        let region = availableRegion
        let origin = CGPoint(x: panelView.transform.tx, y: panelView.transform.ty)
        let maxW = max(minSize.width, region.maxX - origin.x)
        let maxH = max(minSize.height, region.maxY - origin.y)

        if let ratio = aspectRatio, ratio.isFinite, ratio > 0 {
            let maxWidth = min(maxW, maxH * ratio)
            let minWidth = min(maxWidth, max(minSize.width, minSize.height * ratio))
            let projectedWidth = (proposed.width * ratio + proposed.height) * ratio / (ratio * ratio + 1)
            let width = min(max(projectedWidth, minWidth), maxWidth)
            return CGSize(width: width, height: width / ratio)
        }

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
                aspectRatio: CGFloat? = nil,
                onResize: @escaping (CGSize) -> Void,
                onResizeEnded: @escaping (CGSize) -> Void) {
        self.size = size
        self.aspectRatio = aspectRatio
        self.onResize = onResize
        self.onResizeEnded = onResizeEnded
        grip.isHidden = !showsResizeGrip
        hosting.rootView = content
    }

    private var availableRegion: CGRect {
        let insets = view.window?.safeAreaInsets ?? view.safeAreaInsets
        var bottom = view.bounds.maxY - insets.bottom
        if avoidsKeyboard, let window = view.window, !keyboardFrame.isEmpty {
            let local = view.convert(keyboardFrame, from: window.screen.coordinateSpace)
            if local.intersects(view.bounds), local.maxY >= view.bounds.maxY - insets.bottom {
                bottom = min(bottom, local.minY)
            }
        }
        let left = insets.left + contentInsets.left + 8
        let top = insets.top + contentInsets.top + 8
        return CGRect(x: left, y: top,
            width: max(0, view.bounds.width - insets.right - contentInsets.right - 8 - left),
            height: max(0, bottom - contentInsets.bottom - 8 - top))
    }

    @objc private func keyboardChanged(_ notification: Notification) {
        keyboardFrame = notification.name == UIResponder.keyboardWillHideNotification ? .zero
            : (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect ?? .zero)
        view.setNeedsLayout()
    }

    // MARK: Gesture arbitration

    /// The grip owns its corner: reject move-pan touches that land on it, so dragging
    /// the corner resizes rather than repositioning.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        let point = touch.location(in: panelView)
        if !grip.isHidden, grip.frame.contains(point) { return false }
        if let strip = movesFromTopStrip { return point.y <= strip }
        return true
    }
}
#endif
