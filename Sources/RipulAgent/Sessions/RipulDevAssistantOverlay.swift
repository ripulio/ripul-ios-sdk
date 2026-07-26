#if os(iOS)
import SwiftUI
import WebKit

/// Floating dev-assistant overlay: a draggable, edge-snapping bubble that
/// expands into a full `RipulAgentConsole`, minimizes back, and stays warm in
/// between (the console's web view / relay / auth are kept alive while hidden).
///
/// Moved from WAC's `DebugTestingHubVC.swift` into the SDK so any host gets the
/// whole thing with ~2 lines:
///
/// ```swift
/// // Once, at launch (behind the host's own debug gate):
/// RipulDevAssistantOverlay.installRestoreHook(
///     configuration: myConsoleConfig,
///     isEnabled: { MyFlags.debugToolsEnabled }
/// )
/// // A button/row anywhere:
/// RipulDevAssistantOverlay.shared.toggle()
/// ```
///
/// Minimize paths are wired internally: the top-bar minus button and the
/// session list's rightward edge swipe (the showingSidebar slot) both collapse
/// to the bubble. Persisted state (visibility, bubble position) lives in the
/// configuration's `cache` suite, alongside the console's other keys.
@available(iOS 26.0, *)
public final class RipulDevAssistantOverlay {
    public static let shared = RipulDevAssistantOverlay()
    private init() {}

    private var window: RipulDevOverlayWindow?
    private var configuration: RipulSessionsConfiguration?
    private var isEnabled: (() -> Bool)?

    // MARK: - Public API

    /// Install the relaunch-restore hook and store the console configuration.
    /// Call once at app launch. When the app becomes active and the assistant
    /// was left visible last session (and `isEnabled()` is true), the bubble
    /// reappears collapsed — no console boot until the user expands it.
    public static func installRestoreHook(
        configuration: RipulSessionsConfiguration,
        isEnabled: (() -> Bool)? = nil
    ) {
        shared.configuration = configuration
        shared.isEnabled = isEnabled
        guard !restoreHookInstalled else { return }
        restoreHookInstalled = true
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            RipulDevAssistantOverlay.shared.restoreIfNeeded()
        }
    }

    /// Open the assistant (expanded) if hidden, else tear the overlay down.
    public func toggle() {
        if window == nil {
            present()
            expand()
            cache?.set(true, forKey: Self.visibleKey)
        } else {
            dismiss()
            cache?.set(false, forKey: Self.visibleKey)
        }
    }

    /// Expand the bubble into the full console (creates the console on first
    /// expand — the only cold boot; later expands are instant).
    public func expand() {
        window?.isPassthrough = false
        (window?.rootViewController as? RipulDevOverlayRootVC)?.showPanel()
    }

    /// Minimize to the bubble (console stays warm).
    public func collapse() {
        window?.isPassthrough = true
        (window?.rootViewController as? RipulDevOverlayRootVC)?.showBubble()
    }

    /// Tear the overlay down completely (the real "close").
    public func dismiss() {
        window?.isHidden = true
        window = nil
    }

    // MARK: - Internals

    private static var restoreHookInstalled = false
    private static let visibleKey = "ripul.devAssistantOverlay.visible"
    private static let bubbleXKey = "ripul.devAssistantOverlay.bubbleX"
    private static let bubbleYKey = "ripul.devAssistantOverlay.bubbleY"

    private var cache: RipulSessionCache? { configuration?.cache }

    private func restoreIfNeeded() {
        guard window == nil,
              isEnabled?() ?? true,
              let configuration,
              (configuration.cache.object(forKey: Self.visibleKey) as? Bool) == true else { return }
        present()
        collapse()
    }

    private func present() {
        guard window == nil, let configuration, let scene = Self.activeWindowScene() else { return }
        let win = RipulDevOverlayWindow(windowScene: scene)
        win.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
        win.backgroundColor = .clear
        win.accessibilityIdentifier = RipulDevOverlayWindow.markerIdentifier
        let root = RipulDevOverlayRootVC()
        root.overlay = self
        root.configuration = configuration
        win.rootViewController = root
        win.isHidden = false
        window = win
    }

    fileprivate func saveBubblePosition(_ point: CGPoint) {
        cache?.set(Double(point.x), forKey: Self.bubbleXKey)
        cache?.set(Double(point.y), forKey: Self.bubbleYKey)
    }

    fileprivate func savedBubblePosition() -> CGPoint? {
        guard let cache, cache.object(forKey: Self.bubbleXKey) != nil else { return nil }
        return CGPoint(x: cache.object(forKey: Self.bubbleXKey) as? Double ?? 0,
                       y: cache.object(forKey: Self.bubbleYKey) as? Double ?? 0)
    }

    private static func activeWindowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }
}

// MARK: - Overlay window (pass-through when collapsed)

@available(iOS 26.0, *)
final class RipulDevOverlayWindow: UIWindow {
    static let markerIdentifier = "ripul.devAssistant.overlay"
    /// Collapsed: only `interactiveFrame` (the bubble) is live; the rest passes
    /// through to the host app. Expanded: the whole window is live (takes over).
    var isPassthrough = true
    var interactiveFrame: CGRect = .zero

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if !isPassthrough { return super.hitTest(point, with: event) }
        return interactiveFrame.contains(point) ? super.hitTest(point, with: event) : nil
    }
}

// MARK: - Root view controller (bubble + console hosting)

@available(iOS 26.0, *)
final class RipulDevOverlayRootVC: UIViewController {
    weak var overlay: RipulDevAssistantOverlay?
    var configuration: RipulSessionsConfiguration!
    private var bubble: UIView!
    private var panelHost: UIHostingController<AnyView>?
    private var didPositionBubble = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        setupBubble()
    }

    private func setupBubble() {
        let size: CGFloat = 56
        let b = UIView(frame: CGRect(x: 0, y: 0, width: size, height: size))
        b.backgroundColor = .systemBlue
        b.layer.cornerRadius = size / 2
        b.layer.shadowColor = UIColor.black.cgColor
        b.layer.shadowOpacity = 0.25
        b.layer.shadowRadius = 8
        b.layer.shadowOffset = CGSize(width: 0, height: 3)
        let icon = UIImageView(image: UIImage(systemName: "terminal.fill"))
        icon.tintColor = .white
        icon.contentMode = .center
        icon.frame = b.bounds
        icon.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        b.addSubview(icon)
        b.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(bubbleTapped)))
        b.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(bubblePanned(_:))))
        view.addSubview(b)
        bubble = b
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if !didPositionBubble, bubble != nil {
            didPositionBubble = true
            let half = bubble.bounds.width / 2
            if let saved = overlay?.savedBubblePosition() {
                let minY = view.safeAreaInsets.top + half + 16
                let maxY = view.bounds.height - view.safeAreaInsets.bottom - half - 16
                bubble.center = CGPoint(
                    x: min(max(saved.x, half + 16), view.bounds.width - half - 16),
                    y: min(max(saved.y, minY), maxY)
                )
            } else {
                bubble.center = CGPoint(
                    x: view.bounds.width - half - 16,
                    y: view.bounds.height - view.safeAreaInsets.bottom - half - 24
                )
            }
        }
        panelHost?.view.frame = view.bounds
        updateInteractiveFrame()
    }

    @objc private func bubbleTapped() { overlay?.expand() }

    @objc private func bubblePanned(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: view)
        bubble.center = CGPoint(x: bubble.center.x + t.x, y: bubble.center.y + t.y)
        g.setTranslation(.zero, in: view)
        updateInteractiveFrame()
        if g.state == .ended { snapBubbleToEdge() }
    }

    private func snapBubbleToEdge() {
        let half = bubble.bounds.width / 2
        let margin: CGFloat = 16
        let x = bubble.center.x < view.bounds.midX ? half + margin : view.bounds.width - half - margin
        let minY = view.safeAreaInsets.top + half + margin
        let maxY = view.bounds.height - view.safeAreaInsets.bottom - half - margin
        let y = min(max(bubble.center.y, minY), maxY)
        let target = CGPoint(x: x, y: y)
        overlay?.saveBubblePosition(target)
        UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0, options: [.allowUserInteraction]) {
            self.bubble.center = target
        } completion: { _ in self.updateInteractiveFrame() }
    }

    private func updateInteractiveFrame() {
        (view.window as? RipulDevOverlayWindow)?.interactiveFrame = bubble?.frame ?? .zero
    }

    func showBubble() {
        // Keep the console ALIVE — hide, don't destroy. Tearing the hosting
        // controller down here killed the AgentBridge + WKWebView + relay +
        // auth poller, so every re-entry paid a full cold boot (web app fetch,
        // Clerk re-poll, machines/sessions refetch). A real teardown still
        // happens via dismiss().
        panelHost?.view.isHidden = true
        bubble.isHidden = false
        updateInteractiveFrame()
    }

    func showPanel() {
        bubble.isHidden = true
        if panelHost == nil {
            // First open: mount the console (cold boot — web app load + Clerk
            // poll + list fetch). No .ignoresSafeArea(): that flag zeroes
            // safeAreaInsets for the whole console subtree (including its
            // GeometryReader proxies), so the console cannot inset itself.
            // Minimize paths are wired here: the session list's rightward edge
            // swipe (the showingSidebar slot — a host app has no sidebar, the
            // bubble IS the console's off-screen home) and the glass minus
            // button in the top bar's trailing accessory slot.
            let console = AnyView(RipulAgentConsole(
                configuration: configuration,
                slots: RipulAgentScreenSlots(
                    showingSidebar: Binding(
                        get: { false },
                        set: { [weak self] open in
                            if open { self?.overlay?.collapse() }
                        }
                    ),
                    topBarTrailingAccessory: { [weak self] in
                        AnyView(
                            GlassButton(icon: "minus") {
                                self?.overlay?.collapse()
                            }
                            .uiKitIdentifier("RipulDevConsole.minimizeButton")
                        )
                    }
                )
            ))
            let host = UIHostingController(rootView: console)
            host.view.backgroundColor = .systemBackground
            addChild(host)
            host.view.frame = view.bounds
            host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(host.view)
            host.didMove(toParent: self)
            panelHost = host
        } else {
            // Re-open: console is already warm (web view + relay + auth) — just show it.
            panelHost?.view.isHidden = false
        }
    }
}
#endif
