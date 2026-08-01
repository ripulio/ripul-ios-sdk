#if os(iOS)
import UIKit

// MARK: - Ripul chrome windows
//
// Every window the SDK puts on screen (View Explorer, dev assistant, log
// console) is a `RipulChromeWindow`. A plain `UIWindow` gets two things wrong
// for SDK chrome, and only one of them is about `windowLevel`:
//
// 1. KEY-NESS. UIKit makes a window key as soon as it takes a touch, and "the
//    key window" is how nearly every host answers "where does my app live?".
//    WAC's slide-out sidebar is a plain `keyWindow.addSubview(self)`. So a
//    chrome window that HOLDS key-ness gets the host's own panel added inside
//    it, as our top-most sibling — above the reticule, above the compact agent
//    bar, and no window level can save us, because at that point it isn't a
//    cross-window question any more. Chrome therefore declines key-ness
//    (`canBecomeKey == false`) unless it is genuinely taking text input.
//
// 2. SIBLING ORDER inside the window. If a host injects a view anyway (an
//    older host, a resolver we don't control), `didAddSubview` catches it and
//    moves it back out to the app window, loudly.
//
// The public contract for hosts is `RipulChrome.appWindow()`: resolve YOUR
// window with that, never with `UIWindow.isKeyWindow`.

// MARK: - RipulChrome

@MainActor
public enum RipulChrome {

    /// True for any window the SDK put on screen. Hosts can use this to filter
    /// their own window lookups; the SDK uses it everywhere it needs "the app,
    /// not us".
    public static func isRipulWindow(_ window: UIWindow) -> Bool {
        window is RipulChromeWindow
            || window.accessibilityIdentifier == RipulInspection.excludedOverlayWindowIdentifier
    }

    /// The HOST app's window — what a host means when it reaches for "the key
    /// window", with SDK chrome excluded.
    ///
    /// Hosts: use this to resolve the window you mount panels/drawers into.
    /// `UIWindow.isKeyWindow` can transiently resolve to SDK chrome, and a view
    /// added to a chrome window renders above the SDK's own content.
    public static func appWindow(in scene: UIWindowScene? = nil) -> UIWindow? {
        let windows = candidateScenes(scene)
            .flatMap { $0.windows }
            .filter { !isRipulWindow($0) && !$0.isHidden }
        return windows.first { $0.isKeyWindow }
            ?? windows.filter { $0.windowLevel == .normal }.last
            ?? windows.last
    }

    /// The controller SDK-owned modal UI should be presented from (the theme
    /// remap sheet, the style picker, web-view JS dialogs).
    ///
    /// The top-most *interactive* chrome window wins when one is up: a sheet
    /// presented from the app window would appear UNDERNEATH the explorer.
    /// Pass-through chrome (the collapsed dev-assistant bubble) is skipped —
    /// presenting into it would produce a sheet that can't be touched.
    public static func presentationRoot() -> UIViewController? {
        let chrome = candidateScenes(nil)
            .flatMap { $0.windows }
            .compactMap { $0 as? RipulChromeWindow }
            .filter { !$0.isHidden && $0.acceptsPresentation }
            .max { $0.windowLevel.rawValue < $1.windowLevel.rawValue }
        guard var top = (chrome ?? appWindow())?.rootViewController else { return nil }
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }

    private static func candidateScenes(_ scene: UIWindowScene?) -> [UIWindowScene] {
        if let scene { return [scene] }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let active = scenes.filter { $0.activationState == .foregroundActive }
        return active.isEmpty ? scenes : active
    }
}

// MARK: - RipulChromeWindow

open class RipulChromeWindow: UIWindow {

    /// Whether SDK modal UI may be presented from this window's root — false
    /// for pass-through chrome, where a sheet would render but not take touches.
    open var acceptsPresentation: Bool { true }

    /// Armed by `hitTest` when a touch lands on a text-input view: hit-testing
    /// runs before UIKit decides which window to make key, so a tap on a field
    /// still gets a keyboard even though chrome is key-averse by default.
    private var isTakingTextInput = false
    /// Set by chrome that takes typed input for a whole session (the expanded
    /// console: web-view autofocus and `@FocusState` never go through a tap on
    /// a UIKit text view, so hit-test arming can't see them).
    private var wantsKeyInput = false
    /// True while we're installing our own root controller, whose view arrives
    /// through `didAddSubview` like any other.
    private var isInstallingRoot = false

    /// Chrome does not hold key-ness unless it is actually editing — see the
    /// file header. This is the whole fix for host panels landing inside SDK
    /// windows.
    open override var canBecomeKey: Bool { isTakingTextInput || wantsKeyInput }

    public override init(windowScene: UIWindowScene) {
        super.init(windowScene: windowScene)
        commonInit()
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required public init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        // Screen inspection and actuation skip stamped windows — the agent must
        // always see the HOST's screen, never the chrome driving it.
        accessibilityIdentifier = RipulInspection.excludedOverlayWindowIdentifier
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(textInputDidEnd),
                           name: UITextField.textDidEndEditingNotification, object: nil)
        center.addObserver(self, selector: #selector(textInputDidEnd),
                           name: UITextView.textDidEndEditingNotification, object: nil)
        center.addObserver(self, selector: #selector(textInputDidEnd),
                           name: UIResponder.keyboardDidHideNotification, object: nil)
    }

    // MARK: - Root

    /// Install the chrome's own root controller. Use this rather than setting
    /// `rootViewController` directly so the foreign-subview guard doesn't fire
    /// on our own root view.
    public func installRoot(_ controller: UIViewController) {
        isInstallingRoot = true
        rootViewController = controller
        isInstallingRoot = false
    }

    // MARK: - Key-ness

    /// Hold key-ness for as long as this chrome is taking typed input. Balance
    /// every `true` with a `false` — the `false` hands key-ness back to the app
    /// window, which is what keeps host window lookups honest.
    public func setKeyInputEnabled(_ enabled: Bool) {
        wantsKeyInput = enabled
        if !enabled { relinquishKeyIfIdle() }
    }

    /// Drop key-ness entirely. Call before hiding/releasing the window.
    public func relinquishKey() {
        wantsKeyInput = false
        isTakingTextInput = false
        handKeyToApp()
    }

    /// Hand key-ness back unless something in here is still editing.
    public func relinquishKeyIfIdle() {
        if editableFirstResponder(in: self) == nil { isTakingTextInput = false }
        guard !canBecomeKey else { return }
        handKeyToApp()
    }

    private func handKeyToApp() {
        guard isKeyWindow,
              let app = RipulChrome.appWindow(in: windowScene), app !== self else { return }
        app.makeKey()
    }

    @objc private func textInputDidEnd() {
        // One hop: the responder change lands after the notification.
        Task { @MainActor [weak self] in self?.relinquishKeyIfIdle() }
    }

    open override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if !isTakingTextInput, touchesTextInput(hit) { isTakingTextInput = true }
        return hit
    }

    /// Whether a hit view is (or sits just inside) something that types — a
    /// `UITextField`/`UITextView`, or a web view's content view.
    private func touchesTextInput(_ view: UIView?) -> Bool {
        var current = view
        var hops = 0
        while let v = current, hops < 4 {
            if v is UITextInput { return true }
            current = v.superview
            hops += 1
        }
        return false
    }

    private func editableFirstResponder(in view: UIView) -> UIView? {
        if view.isFirstResponder, view is UITextInput { return view }
        for sub in view.subviews {
            if let found = editableFirstResponder(in: sub) { return found }
        }
        return nil
    }

    // MARK: - Foreign subviews

    open override func didAddSubview(_ subview: UIView) {
        super.didAddSubview(subview)
        guard !isInstallingRoot,
              subview !== rootViewController?.view,
              !isUIKitInternal(subview) else { return }

        RipulLog.warn("[RIPUL_CHROME] \(type(of: subview)) was added to a Ripul chrome window — "
            + "a host resolved SDK chrome as its key window. Hosts must resolve the app window with "
            + "RipulChrome.appWindow(), not UIWindow.isKeyWindow. Moving it back to the app window.")

        Task { @MainActor [weak self, weak subview] in
            guard let self, let subview, subview.superview === self else { return }
            self.evict(subview)
        }
    }

    /// Move a host view out to the app window, preserving where it sits on
    /// screen. When it can't be moved safely (constraints pinned to us don't
    /// survive re-parenting), keep our own chrome on top instead.
    private func evict(_ subview: UIView) {
        let pinnedToWindow = constraints.contains {
            ($0.firstItem as? UIView) === subview || ($0.secondItem as? UIView) === subview
        }
        guard !pinnedToWindow,
              let app = RipulChrome.appWindow(in: windowScene), app !== self else {
            if let root = rootViewController?.view { bringSubviewToFront(root) }
            return
        }
        let frame = subview.convert(subview.bounds, to: app)
        app.addSubview(subview)
        subview.frame = frame
    }

    /// UIKit's own machinery — presentation transition views, shadow views —
    /// legitimately lives in our window and must not be evicted.
    private func isUIKitInternal(_ view: UIView) -> Bool {
        Bundle(for: type(of: view)) === Bundle(for: UIView.self)
    }
}
#endif
