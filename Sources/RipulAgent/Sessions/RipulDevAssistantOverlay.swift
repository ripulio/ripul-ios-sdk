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

    /// Minimize to the bubble (console stays warm). The panel shrinks back
    /// into the bubble — the pass-through flip happens when that animation
    /// completes so the panel stays interactive while shrinking.
    public func collapse() {
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
    private static let compactYKey = "ripul.devAssistantOverlay.compactY"

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

    fileprivate func saveCompactY(_ y: CGFloat) {
        cache?.set(Double(y), forKey: Self.compactYKey)
    }

    /// The persisted bar Y, clamped into the view's current safe region.
    fileprivate func savedCompactY(in view: UIView) -> CGFloat? {
        guard let raw = cache?.object(forKey: Self.compactYKey) as? Double else { return nil }
        let minY = view.safeAreaInsets.top + 8
        let maxY = view.bounds.height - view.safeAreaInsets.bottom - 8 - 64
        return min(max(CGFloat(raw), minY), maxY)
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
    private var compactHost: UIHostingController<CompactAgentBarView>?
    /// Where the panel returns on minimize: the state you expanded FROM
    /// (compact bar or circle). expand() preserves it; showCompact /
    /// hideCompactToBubble set it.
    private enum MinimizedState { case bubble, compact }
    private var minimizedState: MinimizedState = .bubble
    private var didPositionBubble = false
    /// The console's bridge, created lazily on first use and shared with the
    /// compact bar (which mirrors the active chat off it). Owning it here also
    /// means the relay comes online before the first panel expand.
    private var sharedBridge: AgentBridge?

    /// The compact bar's frame: bottom-docked by default (mini-player idiom),
    /// or the user's dragged-to Y (persisted per host in the cache suite).
    private var compactFrame: CGRect {
        let bottom = view.safeAreaInsets.bottom
        let defaultY = view.bounds.height - bottom - 72
        let y = overlay?.savedCompactY(in: view) ?? defaultY
        return CGRect(x: 12, y: y, width: view.bounds.width - 24, height: 64)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        setupBubble()
    }

    private func setupBubble() {
        let size: CGFloat = 56
        let b = UIView(frame: CGRect(x: 0, y: 0, width: size, height: size))
        b.backgroundColor = .clear
        b.layer.shadowColor = UIColor.black.cgColor
        b.layer.shadowOpacity = 0.25
        b.layer.shadowRadius = 8
        b.layer.shadowOffset = CGSize(width: 0, height: 3)
        // Liquid Glass bubble — the minimize morph's landing shape is a glass
        // droplet, so the bubble must be glass too or the hand-off pops.
        let glassEffect = UIGlassEffect()
        glassEffect.isInteractive = true
        glassEffect.tintColor = .systemBlue
        let glass = UIVisualEffectView(effect: glassEffect)
        glass.frame = b.bounds
        glass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        glass.layer.cornerRadius = size / 2
        glass.layer.masksToBounds = true
        b.addSubview(glass)
        let icon = UIImageView(image: UIImage(systemName: "terminal.fill"))
        icon.tintColor = .white
        icon.contentMode = .center
        icon.frame = b.bounds
        icon.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        glass.contentView.addSubview(icon)
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
        if let compactHost, !compactHost.view.isHidden, compactHost.view.transform == .identity {
            compactHost.view.frame = compactFrame
        }
        updateInteractiveFrame()
    }

    /// bubble tap → compact bar (the two-state model: circle ⇄ bar ⇄ panel).
    @objc private func bubbleTapped() { showCompact() }

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
        let win = view.window as? RipulDevOverlayWindow
        if let compactHost, !compactHost.view.isHidden {
            win?.interactiveFrame = compactHost.view.frame
        } else {
            win?.interactiveFrame = bubble?.frame ?? .zero
        }
    }

    /// DEBUG: collapse animation time-scale. 1.0 = production timing (~0.56s
    /// total); raise (e.g. 5.36 ≈ 3s) to evaluate the motion stage-by-stage.
    private let collapseTimeScale: CGFloat = 1.0

    /// Drag the compact bar vertically; the Y persists (per host cache suite).
    /// The SwiftUI bar's tap-to-expand still fires on a plain tap (pan only
    /// engages on an actual drag).
    @objc private func compactPanned(_ g: UIPanGestureRecognizer) {
        guard let host = compactHost else { return }
        let t = g.translation(in: view)
        g.setTranslation(.zero, in: view)
        let minY = view.safeAreaInsets.top + 8
        let maxY = view.bounds.height - view.safeAreaInsets.bottom - 8 - host.view.bounds.height
        let newY = min(max(host.view.frame.minY + t.y, minY), maxY)
        host.view.frame = CGRect(x: host.view.frame.minX, y: newY,
                                 width: host.view.frame.width, height: host.view.frame.height)
        updateInteractiveFrame()
        if g.state == .ended || g.state == .cancelled {
            overlay?.saveCompactY(newY)
        }
    }

    /// Circle → compact bar: the live session-row toolbar (active chat's
    /// title, tool updates, hand when the agent awaits input). Morphs out of
    /// the bubble's frame; the bar's expand button (or a bar tap) opens the
    /// panel, its minus returns to the bubble.
    func showCompact() {
        minimizedState = .compact
        if compactHost == nil {
            if sharedBridge == nil { sharedBridge = AgentBridge() }
            let bar = CompactAgentBarView(
                bridge: sharedBridge!,
                onExpand: { [weak self] in self?.overlay?.expand() },
                onMinimize: { [weak self] in self?.hideCompactToBubble() }
            )
            let host = UIHostingController(rootView: bar)
            host.view.backgroundColor = .clear
            addChild(host)
            host.view.frame = compactFrame
            host.view.autoresizingMask = [.flexibleWidth, .flexibleTopMargin]
            view.addSubview(host.view)
            host.didMove(toParent: self)
            compactHost = host
            host.view.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(compactPanned(_:))))
        }
        guard let host = compactHost else { return }

        // Always re-run the appear morph (circle -> bar) — the hide animation
        // leaves the bar at alpha 0 centered on the bubble, so a plain
        // isHidden flip would show it invisible and off-frame (the
        // tap-then-tap-again "compact is gone" bug).
        host.view.isHidden = false
        bubble.isHidden = false
        let fromFrame = bubble.frame
        let toFrame = compactFrame
        let sx = fromFrame.width / toFrame.width
        let sy = fromFrame.height / toFrame.height
        host.view.alpha = 0
        host.view.center = bubble.center
        host.view.transform = CGAffineTransform(scaleX: sx, y: sy)
        UIView.animate(withDuration: 0.38, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
            host.view.transform = .identity
            host.view.frame = toFrame
            host.view.alpha = 1
            self.bubble.alpha = 0
            self.bubble.transform = CGAffineTransform(scaleX: 1.3, y: 1.3)
        } completion: { _ in
            self.bubble.isHidden = true
            self.bubble.transform = .identity
            self.bubble.alpha = 1
        }
        updateInteractiveFrame()
    }

    /// Compact bar → circle (the bar's minus button).
    private func hideCompactToBubble() {
        minimizedState = .bubble
        guard let host = compactHost else { return }
        bubble.isHidden = false
        bubble.alpha = 0
        bubble.transform = CGAffineTransform(scaleX: 1.15, y: 1.15)
        UIView.animate(withDuration: 0.32, delay: 0, options: [.curveEaseIn, .beginFromCurrentState]) {
            host.view.alpha = 0
            host.view.center = self.bubble.center
            host.view.transform = CGAffineTransform(scaleX: 0.2, y: 0.2)
            self.bubble.alpha = 1
            self.bubble.transform = .identity
        } completion: { _ in
            host.view.isHidden = true
            host.view.transform = .identity
        }
        updateInteractiveFrame()
    }

    /// Compact bar → panel (expand button / bar tap): hide the bar and run the
    /// usual panel morph. The bar STAYS alive behind the panel (console state
    /// preserved); it comes back on the next collapse.
    private func hideCompactForPanel() {
        compactHost?.view.isHidden = true
        updateInteractiveFrame()
    }

    func showBubble() {
        // Minimize returns to WHERE YOU EXPANDED FROM: the compact bar when
        // the panel came from compact, the circle when it came from the bubble.
        if minimizedState == .compact, compactHost?.view != nil {
            collapseToMinimized(targetFrame: compactFrame, cornerRadius: 20, reveal: .compact)
        } else {
            collapseToMinimized(targetFrame: bubble.frame, cornerRadius: bubble.frame.width / 2, reveal: .bubble)
        }
    }

    private enum MinimizedReveal { case bubble, compact }

    private func collapseToMinimized(targetFrame: CGRect, cornerRadius: CGFloat, reveal: MinimizedReveal) {
        // Keep the console ALIVE — hide, don't destroy. Tearing the hosting
        // controller down here killed the AgentBridge + WKWebView + relay +
        // auth poller, so every re-entry paid a full cold boot (web app fetch,
        // Clerk re-poll, machines/sessions refetch). A real teardown still
        // happens via dismiss().
        guard let panel = panelHost?.view, !panel.isHidden else {
            panelHost?.view.isHidden = true
            if reveal == .compact {
                showCompact()
            } else {
                bubble.isHidden = false
                updateInteractiveFrame()
            }
            (view.window as? RipulDevOverlayWindow)?.isPassthrough = true
            return
        }
        // Springboard close, matching iOS's app-minimize: the panel stays
        // OPAQUE while it collapses into the bubble's frame (overdamped spring,
        // corner radius climbing to the icon circle), fading only in the last
        // beat; the bubble pops in LATE from slightly-large with a gentle
        // overshoot — the icon "catches" the app.
        //
        // Two on-device lessons baked in (see docs/dev-console-minimize-morph-handover.md):
        // 1. NEVER transform the live panel — its WKWebView composites out of
        //    process and blanks to systemBackground white mid-transform (the
        //    freeze-overlay precedent in SlidePanelOverlay). Morph a
        //    render-server snapshot instead; the live panel is hidden under it
        //    untouched, so keep-alive is unaffected.
        // 2. The reveal behind the shrink is WAC's mostly-white UI, so the
        //    collapse needs a dim scrim as its backdrop (SpringBoard closes
        //    against a dimmed wallpaper) or it reads as a dissolve into void.
        switch reveal {
        case .bubble:
            bubble.isHidden = false
            bubble.alpha = 0
            bubble.transform = CGAffineTransform(scaleX: 1.1, y: 1.1)
        case .compact:
            compactHost?.view.isHidden = false
            compactHost?.view.alpha = 0
            compactHost?.view.transform = CGAffineTransform(scaleX: 1.05, y: 1.05)
        }

        let scrim = UIView(frame: view.bounds)
        scrim.backgroundColor = UIColor.black.withAlphaComponent(0.3)
        scrim.isUserInteractionEnabled = false
        view.insertSubview(scrim, at: 0)

        // The morph container animates its FRAME to the bubble's exact circle
        // (not a uniform transform: the panel isn't square, so pure scaling
        // lands on a 56×121 pill and the final fade to the round bubble reads
        // as a snap). The snapshot scales inside and the collapsing bounds
        // clip it — the iOS-close mask behavior — while Liquid Glass
        // materializes under the dissolving content, so what merges with the
        // (glass) bubble is an identical glass droplet.
        let targetFrame = targetFrame
        let morph = UIView(frame: panel.frame)
        morph.backgroundColor = .clear
        morph.layer.masksToBounds = true
        morph.isUserInteractionEnabled = false
        let glass = UIVisualEffectView(effect: nil)
        glass.frame = morph.bounds
        glass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        morph.addSubview(glass)
        let snapshot = panel.snapshotView(afterScreenUpdates: false) ?? {
            // Fallback: rasterize the hierarchy. Blank web tiles here are no
            // worse than what snapshotView failing would have given us.
            let image = UIGraphicsImageRenderer(bounds: panel.bounds).image { _ in
                panel.drawHierarchy(in: panel.bounds, afterScreenUpdates: false)
            }
            return UIImageView(image: image)
        }()
        snapshot.frame = morph.bounds
        morph.addSubview(snapshot)
        view.addSubview(morph)
        panel.isHidden = true

        let s = targetFrame.width / panel.bounds.width
        let ts = collapseTimeScale
        UIView.animate(withDuration: 0.36 * ts, delay: 0, usingSpringWithDamping: 0.92, initialSpringVelocity: 0, options: [.beginFromCurrentState]) {
            morph.frame = targetFrame
            morph.layer.cornerRadius = cornerRadius
            snapshot.transform = CGAffineTransform(scaleX: s, y: s)
            snapshot.center = CGPoint(x: targetFrame.width / 2, y: targetFrame.height / 2)
        }
        UIView.animate(withDuration: 0.14 * ts, delay: 0.20 * ts, options: [.curveEaseIn]) {
            snapshot.alpha = 0
            glass.effect = UIGlassEffect()
        }
        UIView.animate(withDuration: 0.12 * ts, delay: 0.36 * ts, options: [.curveEaseOut]) {
            morph.alpha = 0
        }
        UIView.animate(withDuration: 0.26 * ts, delay: 0.24 * ts, options: [.curveEaseOut]) {
            scrim.alpha = 0
        }
        UIView.animate(withDuration: 0.42 * ts, delay: 0.12 * ts, usingSpringWithDamping: 0.72, initialSpringVelocity: 0, options: [.beginFromCurrentState]) {
            switch reveal {
            case .bubble:
                self.bubble.alpha = 1
                self.bubble.transform = .identity
            case .compact:
                self.compactHost?.view.alpha = 1
                self.compactHost?.view.transform = .identity
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.56 * ts) {
            morph.removeFromSuperview()
            scrim.removeFromSuperview()
            self.updateInteractiveFrame()
            // Skip the passthrough flip if the user re-expanded mid-collapse —
            // a live panel behind a bubble-only hit region would be untappable.
            if self.panelHost?.view.isHidden == true {
                (self.view.window as? RipulDevOverlayWindow)?.isPassthrough = true
            }
        }
    }

    func showPanel() {
        hideCompactForPanel()
        if panelHost == nil {
            // First open: mount the console (cold boot — web app load + Clerk
            // poll + list fetch). No .ignoresSafeArea(): that flag zeroes
            // safeAreaInsets for the whole console subtree (including its
            // GeometryReader proxies), so the console cannot inset itself.
            // Minimize paths are wired here: the session list's rightward edge
            // swipe (the showingSidebar slot — a host app has no sidebar, the
            // bubble IS the console's off-screen home) and the glass minus
            // button in the top bar's trailing accessory slot.
            if sharedBridge == nil { sharedBridge = AgentBridge() }
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
                ),
                bridge: sharedBridge
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
        // Springboard launch: the panel grows out of the bubble (scale +
        // corner radius + fade from the bubble's frame to fullscreen) while
        // the bubble zoom-fades away into it.
        guard let panel = panelHost?.view else { return }
        let s = bubble.bounds.width / view.bounds.width
        let startRadius = (bubble.bounds.width / 2) / s
        panel.layer.masksToBounds = true
        panel.alpha = 0
        panel.center = bubble.center
        panel.transform = CGAffineTransform(scaleX: s, y: s)
        panel.layer.cornerRadius = startRadius
        UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
            panel.transform = .identity
            panel.center = CGPoint(x: self.view.bounds.midX, y: self.view.bounds.midY)
            panel.layer.cornerRadius = 0
            panel.alpha = 1
            self.bubble.transform = CGAffineTransform(scaleX: 1.4, y: 1.4)
            self.bubble.alpha = 0
        } completion: { _ in
            panel.layer.masksToBounds = false
            self.bubble.isHidden = true
            self.bubble.transform = .identity
            self.bubble.alpha = 1
        }
    }
}

// MARK: - Compact agent bar (live session-row toolbar)

/// The compact state's content: mirrors a session row for the ACTIVE chat —
/// status glyph, title, live tool subtitle, and a raised hand when the agent
/// awaits input ("ready"). Expand opens the panel; minus returns to the
/// bubble; a tap anywhere on the bar expands too (the mini-player idiom).
@available(iOS 26.0, *)
private struct CompactAgentBarView: View {
    @ObservedObject var bridge: AgentBridge
    let onExpand: () -> Void
    let onMinimize: () -> Void

    private var activeSession: ChatSession? {
        bridge.sessions.first(where: { $0.id == bridge.activeSessionId })
    }

    /// The active chat as a UnifiedSession — the same shape the list's own
    /// builder produces for a local session, so the shared row renders
    /// byte-identical readout (icon swap, plan/tool/done/idle lozenge, detail).
    private var rowSession: UnifiedSession? {
        guard let s = activeSession else { return nil }
        return UnifiedSession(
            id: s.id, title: s.displayName, lastUsed: s.createdAt,
            gitBranch: nil, messageCount: nil, projectName: nil, projectPath: nil,
            provider: s.provider, providerLabel: s.providerLabel,
            machineName: s.remoteMachineName, machineId: nil,
            matchKeys: [s.id, s.sourceChatId],
            tags: [], metadataKey: UnifiedSession.canonicalKey(s.sourceChatId),
            ripulSession: s
        )
    }

    var body: some View {
        HStack(spacing: 10) {
            // The ACTUAL session-list row component — no emulation. Every
            // readout behavior (plan progress, live tool line, provider icon,
            // subtitle priority) is whatever the console's list would show.
            if let session = rowSession {
                UnifiedSessionRow(
                    sessionStore: bridge.sessionList,
                    session: session,
                    onSessionAction: { _ in onExpand() }
                )
            } else {
                Image(systemName: "terminal.fill")
                    .foregroundStyle(.blue)
                    .frame(width: 28, height: 28)
                Text("Agent")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }

            Spacer()

            Button(action: onMinimize) {
                Image(systemName: "minus")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
                    .modifier(GlassCircleModifier(glassStyle: "regular"))
            }
            .uiKitIdentifier("RipulDevConsole.compact.minimizeButton")

            Button(action: onExpand) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
                    .modifier(GlassCircleModifier(glassStyle: "regular"))
            }
            .uiKitIdentifier("RipulDevConsole.compact.expandButton")
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Regular (adaptive) glass applied to the CONTAINER, not a background
        // sibling — only content INSIDE the glass effect gets the system's
        // vibrant/adaptive foreground (text flips light/dark with the
        // backdrop per Apple's guidance). Regular is the variant for floating
        // chrome over content you don't control; foregrounds stay semantic.
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture { onExpand() }
    }
}
#endif
