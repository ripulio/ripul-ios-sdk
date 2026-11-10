import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Where the side drawer is, kept outside SwiftUI state. A drag sets the
/// panel's transform and the scrim's alpha in UIKit on every touch, so the
/// page is never re-rendered while a finger moves it (it was: the offset
/// used to be `@Published` on the runtime, and every frame redrew every
/// view observing it, which measured 13 gaps of 79-129 ms in a 0.8 s drag).
/// SwiftUI is told only that a drawer is open (`runtime.openDrawer`) and
/// that it has closed. docs/cms-sidebar.md, "Following the finger".
public final class CmsDrawerTrack {
    /// 0 hidden at its edge, 1 fully open.
    public internal(set) var progress: CGFloat = 0
    /// The next drawer to appear is placed by a finger, not slid in.
    var startsInteractive = false
    /// A release that came before the drawer's view existed.
    var pendingRelease: CGFloat?

    #if os(iOS)
    weak var controller: CmsDrawerTrackController?
    private var animator: UIViewPropertyAnimator?
    #endif

    // MARK: Driving it (edge pans, the drawer's own pan, close)

    /// A drag takes hold: a spring in flight stops where it is.
    func grab() {
        #if os(iOS)
        if let animator, animator.state == .active {
            animator.stopAnimation(true)
            progress = controller?.presentedProgress ?? progress
        }
        animator = nil
        #endif
        pendingRelease = nil
    }

    /// The finger moves: 0...1, applied at once.
    func drag(to value: CGFloat) {
        progress = min(max(value, 0), 1)
        #if os(iOS)
        controller?.apply(progress)
        #endif
    }

    /// The finger lifts with `velocity` (points a second toward open):
    /// opens or closes by where it would come to rest, carrying that speed.
    func release(velocity: CGFloat, width: CGFloat, onClosed: @escaping () -> Void) {
        #if os(iOS)
        // Lifted before the drawer's view was made: it settles once it is.
        guard controller != nil else { pendingRelease = velocity; return }
        #endif
        let open = Self.settlesOpen(progress: progress, velocity: velocity, width: width)
        settle(open: open, velocity: velocity, width: width, onClosed: onClosed)
    }

    /// Where a release comes to rest: its position thrown on by a fifth of a
    /// second at its speed, then open past halfway.
    static func settlesOpen(progress: CGFloat, velocity: CGFloat, width: CGFloat) -> Bool {
        guard width > 0 else { return progress > 0.5 }
        return progress + velocity * 0.2 / width > 0.5
    }

    /// An interruptible spring to open or closed, starting at `velocity`.
    func settle(open: Bool, velocity: CGFloat = 0, width: CGFloat, onClosed: @escaping () -> Void) {
        #if os(iOS)
        guard let controller else {
            progress = open ? 1 : 0
            if !open { onClosed() }
            return
        }
        animator?.stopAnimation(true)
        let target: CGFloat = open ? 1 : 0
        let distance = abs(target - progress) * width
        let relative = distance > 1 ? velocity * (open ? 1 : -1) / distance : 0
        let timing = UISpringTimingParameters(dampingRatio: 0.9,
                                              initialVelocity: CGVector(dx: max(min(relative, 30), -30), dy: 0))
        let animator = UIViewPropertyAnimator(duration: 0.42, timingParameters: timing)
        animator.addAnimations { [weak controller] in controller?.apply(target) }
        animator.addCompletion { [weak self] position in
            guard let self, position == .end else { return }
            self.progress = target
            self.animator = nil
            if !open { onClosed() }
        }
        progress = target
        self.animator = animator
        animator.startAnimation()
        #else
        progress = open ? 1 : 0
        if !open { onClosed() }
        #endif
    }
}

#if os(iOS)
/// The drawer as UIKit: a scrim and a panel holding the SwiftUI content in a
/// hosting controller. Position comes from `CmsDrawerTrack`; a pan here
/// (on the panel or the scrim) closes it under the finger, and a tap on the
/// scrim closes it.
struct CmsDrawerTrackView: UIViewControllerRepresentable {
    let runtime: CmsRuntime
    let edge: CmsRuntime.DrawerRequest.Edge
    let width: CGFloat
    let panel: AnyView

    func makeUIViewController(context: Context) -> CmsDrawerTrackController {
        let controller = CmsDrawerTrackController(runtime: runtime, edge: edge, width: width, panel: panel)
        return controller
    }

    func updateUIViewController(_ controller: CmsDrawerTrackController, context: Context) {
        controller.update(edge: edge, width: width, panel: panel)
    }
}

final class CmsDrawerTrackController: UIViewController, UIGestureRecognizerDelegate {
    private weak var runtime: CmsRuntime?
    private(set) var edge: CmsRuntime.DrawerRequest.Edge
    private(set) var width: CGFloat
    private let host: UIHostingController<AnyView>
    private let scrim = UIView()
    private let panelView = UIView()
    private var startProgress: CGFloat = 0
    private var attached = false

    init(runtime: CmsRuntime, edge: CmsRuntime.DrawerRequest.Edge, width: CGFloat, panel: AnyView) {
        self.runtime = runtime
        self.edge = edge
        self.width = width
        self.host = UIHostingController(rootView: panel)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        scrim.backgroundColor = UIColor.black.withAlphaComponent(0.2)
        scrim.alpha = 0
        scrim.accessibilityIdentifier = "Cms.drawer.scrim"
        view.addSubview(scrim)
        scrim.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapScrim)))

        panelView.backgroundColor = .clear
        panelView.accessibilityIdentifier = "Cms.drawer.panel"
        view.addSubview(panelView)
        addChild(host)
        host.view.backgroundColor = .clear
        panelView.addSubview(host.view)
        host.didMove(toParent: self)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)
        // A finger may already have moved it before this view existed.
        let track = runtime?.drawerTrack
        track?.controller = self
        apply(track?.startsInteractive == true ? track?.progress ?? 0 : 0)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        scrim.frame = bounds
        let transform = panelView.transform
        panelView.transform = .identity
        panelView.frame = CGRect(x: edge == .leading ? 0 : bounds.width - width, y: 0, width: width, height: bounds.height)
        panelView.transform = transform
        host.view.frame = panelView.bounds
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !attached, let runtime else { return }
        attached = true
        let track = runtime.drawerTrack
        if track.startsInteractive {
            track.startsInteractive = false
            apply(track.progress)
            if let velocity = track.pendingRelease {
                track.pendingRelease = nil
                track.release(velocity: velocity, width: width) { [weak runtime] in runtime?.finishClosingDrawer() }
            }
        } else {
            track.progress = 0
            apply(0)
            track.settle(open: true, width: width) { [weak runtime] in runtime?.finishClosingDrawer() }
        }
    }

    func update(edge: CmsRuntime.DrawerRequest.Edge, width: CGFloat, panel: AnyView) {
        host.rootView = panel
        guard edge != self.edge || width != self.width else { return }
        self.edge = edge
        self.width = width
        view.setNeedsLayout()
        apply(runtime?.drawerTrack.progress ?? 1)
    }

    /// Places the panel and the scrim for `progress`, in UIKit only.
    func apply(_ progress: CGFloat) {
        let hidden = edge == .leading ? -width : width
        panelView.transform = CGAffineTransform(translationX: hidden * (1 - progress), y: 0)
        scrim.alpha = progress
    }

    /// Where the panel is on screen right now, mid-spring included.
    var presentedProgress: CGFloat {
        let tx = panelView.layer.presentation()?.affineTransform().tx ?? panelView.transform.tx
        let hidden = edge == .leading ? -width : width
        return hidden == 0 ? 1 : min(max(1 - tx / hidden, 0), 1)
    }

    @objc private func tapScrim() { runtime?.closeDrawer() }

    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        guard let runtime else { return }
        let track = runtime.drawerTrack
        let dx = pan.translation(in: view).x
        let toward = edge == .leading ? dx : -dx
        switch pan.state {
        case .began:
            track.grab()
            startProgress = track.progress
        case .changed:
            track.drag(to: startProgress + toward / width)
        case .ended, .cancelled, .failed:
            let vx = pan.velocity(in: view).x
            let velocity = pan.state == .ended ? (edge == .leading ? vx : -vx) : 0
            track.release(velocity: velocity, width: width) { [weak runtime] in runtime?.finishClosingDrawer() }
        default:
            break
        }
    }

    /// Only a sideways drag toward the drawer's edge closes it; anything
    /// else (a vertical scroll in the panel) is left alone.
    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
        let v = pan.velocity(in: view)
        guard abs(v.x) > abs(v.y) else { return false }
        return edge == .leading ? v.x < 0 : v.x > 0
    }

    /// The panel's scroll views wait for this drag to fail, as the edge pan's do.
    func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        guard let scroll = other.view as? UIScrollView else { return false }
        return scroll.isDescendant(of: view)
    }
}
#endif
