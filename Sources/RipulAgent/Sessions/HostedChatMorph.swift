#if os(iOS)
import UIKit

/// Animates a host's already-mounted chat without transforming its live web view.
/// A separate, non-key window lets restore capture the newly revealed chat
/// while the old screen remains covered until the expanding glass reaches it.
@available(iOS 26.0, *)
@MainActor
final class HostedChatMorph: NSObject {
    private var window: RipulChromeWindow?
    private var animator: UIViewPropertyAnimator?
    private var completion: (() -> Void)?
    private var coverDisplayLink: CADisplayLink?
    private var coverHasHadFrame = false
    private var pendingUpdate: (() -> Void)?
    private var pendingAnimation: (() -> Void)?
    var isAnimating: Bool { window != nil }
    var reduceMotionEnabled: () -> Bool = { UIAccessibility.isReduceMotionEnabled }

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(finish),
            name: UIApplication.willResignActiveNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func run(expanding: Bool, in host: UIWindow, bubbleFrame: CGRect,
             updateChat: @escaping () -> Void, completion: @escaping () -> Void) {
        guard !isAnimating else { return }
        guard !reduceMotionEnabled(), let scene = host.windowScene,
              !host.bounds.isEmpty else {
            updateChat()
            completion()
            return
        }

        // The restore backdrop must be immutable and opaque, including any
        // transparent areas of the host. A render-server snapshot is useful
        // for the moving chat, but must not expose the newly revealed host.
        let before = expanding ? frozenBackdrop(host) : snapshot(host, afterUpdates: false)
        let overlay = RipulChromeWindow(windowScene: scene)
        overlay.accessibilityIdentifier = "RipulChatLauncher.morph"
        overlay.windowLevel = .init(rawValue: RipulExplorerOverlayWindow.overlayLevel.rawValue + 2)
        overlay.backgroundColor = .clear
        let root = MorphRootController(size: host.bounds.size)
        root.onResize = { [weak self] in self?.finish() }
        overlay.installRoot(root)
        overlay.frame = host.frame
        root.view.frame = overlay.bounds
        self.window = overlay
        self.completion = completion

        // Restore keeps the old document visible while SwiftUI brings the
        // chat back underneath this window. Minimise reveals the live document.
        if expanding {
            before.frame = root.view.bounds
            before.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            root.view.addSubview(before)
        }
        let scrim = UIView(frame: root.view.bounds)
        scrim.backgroundColor = .black
        scrim.alpha = expanding ? 0 : 0.18
        scrim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        root.view.addSubview(scrim)

        let fullFrame = host.convert(host.bounds, to: overlay)
        let smallFrame = host.convert(bubbleFrame, to: overlay)
        let surface = MorphSurface(fullSize: fullFrame.size)
        surface.frame = expanding ? smallFrame : fullFrame
        surface.layer.cornerRadius = expanding ? smallFrame.width / 2 : 0
        surface.icon.alpha = expanding ? 1 : 0
        root.view.addSubview(surface)
        if !expanding { surface.installSnapshot(before, scale: 1, alpha: 1) }
        overlay.isHidden = false
        overlay.layoutIfNeeded()

        let beginAnimation = { [weak self, weak host, weak overlay] in
            // SwiftUI commits its state change on the next run-loop turn. A
            // snapshot with afterScreenUpdates includes the restored chat chrome.
            DispatchQueue.main.async { [weak self, weak host, weak overlay] in
                guard let self, let host, let overlay, self.window === overlay else { return }
                host.layoutIfNeeded()
                if expanding {
                    surface.installSnapshot(self.snapshot(host, afterUpdates: true),
                        scale: smallFrame.width / fullFrame.width, alpha: 0)
                }
                let animation = UIViewPropertyAnimator(duration: 0.48, dampingRatio: 0.88)
                self.animator = animation
                animation.addAnimations {
                    surface.frame = expanding ? fullFrame : smallFrame
                    surface.layer.cornerRadius = expanding ? 0 : smallFrame.width / 2
                    surface.positionSnapshot(scale: expanding ? 1 : smallFrame.width / fullFrame.width)
                    scrim.alpha = expanding ? 0.18 : 0
                }
                animation.addAnimations({
                    surface.chatSnapshot?.alpha = expanding ? 1 : 0
                    surface.icon.alpha = expanding ? 0 : 1
                }, delayFactor: expanding ? 0.08 : 0.55)
                animation.addCompletion { [weak self, weak overlay] _ in
                    guard let self, let overlay, self.window === overlay else { return }
                    self.finish()
                }
                animation.startAnimation()
            }
        }
        // Showing a UIWindow only schedules its first render. Changing chat
        // in that same transaction can expose the host before the cover is
        // displayed: full chat on restore, bare document on minimise. Allow
        // one complete display interval before either live visibility change.
        pendingUpdate = updateChat
        pendingAnimation = beginAnimation
        coverHasHadFrame = false
        let link = CADisplayLink(target: self, selector: #selector(coverFrame))
        coverDisplayLink = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func coverFrame() {
        guard coverHasHadFrame else {
            coverHasHadFrame = true
            return
        }
        coverDisplayLink?.invalidate()
        coverDisplayLink = nil
        applyPendingUpdate()
        let begin = pendingAnimation
        pendingAnimation = nil
        begin?()
    }

    private func applyPendingUpdate() {
        let update = pendingUpdate
        pendingUpdate = nil
        if let update { UIView.performWithoutAnimation(update) }
    }

    /// Navigation/dismissal supersedes the transition; it must not reveal a FAB
    /// for a screen the host has already left.
    func cancel() { cleanUp(deliverCompletion: false) }

    /// Backgrounding or a resize settles to the requested state immediately.
    @objc private func finish() { cleanUp(deliverCompletion: true) }

    private func cleanUp(deliverCompletion: Bool) {
        guard let previous = window else { return }
        window = nil
        coverDisplayLink?.invalidate()
        coverDisplayLink = nil
        pendingAnimation = nil
        if deliverCompletion { applyPendingUpdate() } else { pendingUpdate = nil }
        if animator?.state == .active { animator?.stopAnimation(true) }
        animator = nil
        let done = completion
        completion = nil
        // Reveal the real bubble at the exact landing frame before retiring
        // the glass proxy. The host's key window never changes.
        if deliverCompletion { done?() }
        previous.isHidden = true
        previous.rootViewController = nil
    }

    private func frozenBackdrop(_ host: UIWindow) -> UIView {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: host.bounds, format: format).image { context in
            UIColor.systemBackground.resolvedColor(with: host.traitCollection).setFill()
            context.fill(host.bounds)
            host.drawHierarchy(in: host.bounds, afterScreenUpdates: false)
        }
        let view = UIImageView(image: image)
        view.isOpaque = true
        view.accessibilityIdentifier = "RipulChatLauncher.frozenBackdrop"
        return view
    }

    private func snapshot(_ host: UIWindow, afterUpdates: Bool) -> UIView {
        if let view = host.snapshotView(afterScreenUpdates: afterUpdates) { return view }
        let image = UIGraphicsImageRenderer(bounds: host.bounds).image { _ in
            host.drawHierarchy(in: host.bounds, afterScreenUpdates: afterUpdates)
        }
        return UIImageView(image: image)
    }
}

@available(iOS 26.0, *)
private final class MorphRootController: UIViewController {
    let expectedSize: CGSize
    var onResize: (() -> Void)?

    init(size: CGSize) {
        expectedSize = size
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        view = UIView()
        view.backgroundColor = .clear
        // Blocks accidental duplicate taps for the duration of the hand-off.
        view.isUserInteractionEnabled = true
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if !view.bounds.isEmpty, view.bounds.size != expectedSize { onResize?() }
    }
}

@available(iOS 26.0, *)
private final class MorphSurface: UIView {
    let fullSize: CGSize
    let icon = UIImageView(image: UIImage(systemName: "bubble.left.and.bubble.right.fill"))
    private(set) var chatSnapshot: UIView?

    init(fullSize: CGSize) {
        self.fullSize = fullSize
        super.init(frame: .zero)
        accessibilityIdentifier = "RipulChatLauncher.morphSurface"
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        let effect = UIGlassEffect()
        effect.isInteractive = true
        effect.tintColor = .systemBlue
        let glass = UIVisualEffectView(effect: effect)
        glass.frame = bounds
        glass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(glass)
        icon.tintColor = .white
        icon.contentMode = .center
        icon.frame = bounds
        icon.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(icon)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func installSnapshot(_ snapshot: UIView, scale: CGFloat, alpha: CGFloat) {
        chatSnapshot = snapshot
        snapshot.frame = CGRect(origin: .zero, size: fullSize)
        snapshot.alpha = alpha
        snapshot.isUserInteractionEnabled = false
        insertSubview(snapshot, belowSubview: icon)
        positionSnapshot(scale: scale)
    }

    func positionSnapshot(scale: CGFloat) {
        chatSnapshot?.transform = CGAffineTransform(scaleX: scale, y: scale)
        chatSnapshot?.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }
}
#endif
