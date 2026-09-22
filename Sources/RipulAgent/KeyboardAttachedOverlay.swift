import SwiftUI

/// Coordinates are local to the composer container, not screen heights. This
/// avoids subtracting the tab bar twice when UIKit resizes its destination.
enum ComposerKeyboardLayout {
    static func bottomInset(bounds: CGRect, safeBottom: CGFloat, keyboard: CGRect?, docked: Bool) -> CGFloat {
        let resting = max(0, safeBottom)
        guard docked, let keyboard,
              !bounds.intersection(keyboard).isEmpty else { return resting }
        return max(resting, bounds.maxY - max(bounds.minY, keyboard.minY))
    }
}

/// The chat's resting content clearance has two independent measurements:
/// the expanded composer body and the space occupied by navigation below it.
/// Never substitute a compact-frame height while scrolling through a morph.
enum ComposerContentLayout {
    static let scrollButtonHeight: CGFloat = 64

    static func expandedInputHeight(hostHeight: CGFloat, progress: CGFloat) -> CGFloat? {
        guard progress == 0, hostHeight > scrollButtonHeight, hostHeight.isFinite else { return nil }
        return hostHeight - scrollButtonHeight
    }

    static func bottomClearance(inputHeight: CGFloat, navigationInset: CGFloat,
                                safeBottom: CGFloat, keyboardHeight: CGFloat = 0) -> CGFloat {
        max(0, inputHeight) + max(0, navigationInset) + max(0, safeBottom)
            + max(0, keyboardHeight) + 8 + 8 // below composer, then above it
    }
}

/// Resting coordinates are independent of keyboard animation and content size.
/// The same progress changes horizontal space and vertical placement together.
enum ComposerChromeLayout {
    static func placement(bounds: CGRect, safeBottom: CGFloat, safeLeading: CGFloat, safeTrailing: CGFloat = 0,
                          navigation: CGRect, progress: CGFloat, bounce: CGFloat,
                          keyboardInset: CGFloat) -> (leading: CGFloat, trailing: CGFloat, bottom: CGFloat) {
        let p = min(1, max(0, progress))
        let expanded = max(safeBottom, bounds.maxY - navigation.minY)
        let resting = expanded + (safeBottom - expanded) * p
        let leading = max(0, navigation.minX + 48 + 10 - 12 - safeLeading) * p
        // The compact pair shares the native platter's two outer edges. Its
        // right edge must leave the same gutter as the compact button's left;
        // retaining the expanded composer's12pt gutter shifted the pair right.
        let trailing = max(0, bounds.maxX - safeTrailing - navigation.maxX - 12) * p
        let keyboardCoversChrome = keyboardInset > resting
        return (leading, trailing, -(max(keyboardInset, resting) + 8) + (keyboardCoversChrome ? 0 : bounce))
    }
}

#if os(iOS)
import UIKit
import Combine

/// UIKit owns positioning and uses the keyboard's frame, duration and curve.
/// No per-frame SwiftUI state or second spring is involved. Keyboard layout
/// guides were measured stuck at rest in the tab-hosted view hierarchy.
@available(iOS 16.0, *)
struct KeyboardAttachedOverlay<Content: View>: UIViewControllerRepresentable {
    @Environment(\.ripulComposerChrome) private var chrome
    let content: Content
    var onHeightChange: ((CGFloat) -> Void)?

    init(onHeightChange: ((CGFloat) -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.onHeightChange = onHeightChange
    }

    func makeUIViewController(context: Context) -> KeyboardAttachedOverlayController {
        KeyboardAttachedOverlayController(content: AnyView(content), chrome: chrome, environment: context.environment,
                                          onHeightChange: onHeightChange)
    }

    func updateUIViewController(_ controller: KeyboardAttachedOverlayController, context: Context) {
        // Updating the same hosting controller preserves the editor, draft,
        // selection and first responder across bridge/environment changes.
        controller.update(content: AnyView(content), chrome: chrome, environment: context.environment,
                          onHeightChange: onHeightChange)
    }
}

@available(iOS 16.0, *)
final class KeyboardAttachedOverlayController: UIViewController {
    let host: UIHostingController<AnyView>
    private var bottomConstraint: NSLayoutConstraint?
    private var keyboardFrame: CGRect?
    private var leadingConstraint: NSLayoutConstraint?
    private var trailingConstraint: NSLayoutConstraint?
    private var chrome: RipulComposerChrome?
    private let inactiveChrome = RipulComposerChrome()
    private var chromeSubscription: AnyCancellable?
    private var lastChromeTrace = ""
    private var onHeightChange: ((CGFloat) -> Void)?
    private var lastExpandedHeight: CGFloat?
    private var heightReportScheduled = false

    init(content: AnyView, chrome: RipulComposerChrome?, environment: EnvironmentValues,
         onHeightChange: ((CGFloat) -> Void)? = nil) {
        host = UIHostingController(rootView: content)
        super.init(nibName: nil, bundle: nil)
        update(content: content, chrome: chrome, environment: environment, onHeightChange: onHeightChange)
    }

    func update(content: AnyView, chrome: RipulComposerChrome?, environment: EnvironmentValues,
                onHeightChange: ((CGFloat) -> Void)? = nil) {
        self.onHeightChange = onHeightChange
        // This wrapper is always present; enabling chrome cannot replace the editor.
        // Copy the parent environment OUTSIDE the frame observer. Copying it
        // onto content itself would override the observer's collapse value.
        host.rootView = AnyView(ComposerChromeContent(chrome: chrome ?? inactiveChrome, content: content)
            .environment(\.self, environment))
        guard self.chrome !== chrome else { return }
        self.chrome = chrome
        chromeSubscription = nil
        if let chrome {
            chromeSubscription = chrome.$frame.combineLatest(chrome.$navigationFrame).sink { [weak self] _, _ in
                // @Published delivers before storage changes. Read after this update.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isViewLoaded else { return }
                    self.updateBottomConstraint()
                    self.view.layoutIfNeeded()
                    self.scheduleExpandedHeightReport()
                    self.reportSettledEditor()
                }
            }
        }
        if isViewLoaded { updateBottomConstraint(); view.setNeedsLayout() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = KeyboardOverlayPassthroughView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        host.view.backgroundColor = .clear
        host.sizingOptions = .intrinsicContentSize
        if #available(iOS 16.4, *) {
            // This controller owns avoidance; don't let the inner SwiftUI hierarchy
            // add another keyboard/safe-area inset as its frame moves.
            host.safeAreaRegions = []
        }
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        let bottom = host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8)
        bottomConstraint = bottom
        let leading = host.view.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor)
        leadingConstraint = leading
        let trailing = host.view.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor)
        trailingConstraint = trailing
        NSLayoutConstraint.activate([
            // Local guides are zero-inset when the parent already avoided an
            // edge, and protect the same composer in a full-window host.
            leading,
            trailing,
            bottom,
        ])
        host.didMove(toParent: self)
        (view as? KeyboardOverlayPassthroughView)?.contentView = host.view
        for name in [UIResponder.keyboardWillChangeFrameNotification,
                     UIResponder.keyboardDidChangeFrameNotification,
                     UIResponder.keyboardWillHideNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)), name: name, object: nil)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The tab container can change its frame/safe area during keyboard
        // presentation. Reconvert the screen frame rather than retaining a height.
        updateBottomConstraint()
        scheduleExpandedHeightReport()
    }

    /// Measure the actual hosting view after UIKit lays it out. SwiftUI
    /// preferences inside the separately hosted composer did not reliably
    /// deliver an initial height to AgentView, leaving the web's cached inset.
    private func scheduleExpandedHeightReport() {
        guard onHeightChange != nil, !heightReportScheduled,
              let height = ComposerContentLayout.expandedInputHeight(
                hostHeight: host.view.bounds.height, progress: chrome?.frame.progress ?? 0),
              height != lastExpandedHeight else { return }
        heightReportScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.heightReportScheduled = false
            guard self.view.window != nil,
                  let height = ComposerContentLayout.expandedInputHeight(
                    hostHeight: self.host.view.bounds.height, progress: self.chrome?.frame.progress ?? 0),
                  height != self.lastExpandedHeight else { return }
            self.lastExpandedHeight = height
            self.onHeightChange?(height)
        }
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        updateBottomConstraint()
    }

    @discardableResult
    private func updateBottomConstraint() -> Bool {
        guard let bottomConstraint else { return false }
        var localKeyboard: CGRect?
        var docked = false
        if let window = view.window, let keyboardFrame {
            localKeyboard = view.convert(keyboardFrame, from: window.screen.coordinateSpace)
            let inWindow = window.convert(keyboardFrame, from: window.screen.coordinateSpace)
            docked = inWindow.maxY >= window.bounds.maxY - 1
        }
        let inset = ComposerKeyboardLayout.bottomInset(
            bounds: view.bounds, safeBottom: view.safeAreaInsets.bottom,
            keyboard: localKeyboard, docked: docked)
        var next = -(inset + 8)
        var nextLeading: CGFloat = 0
        var nextTrailing: CGFloat = 0
        if let chrome, let window = view.window, chrome.navigationFrame.height > 0 {
            let navigation = view.convert(chrome.navigationFrame, from: window)
            let placement = ComposerChromeLayout.placement(
                bounds: view.bounds, safeBottom: view.safeAreaInsets.bottom,
                safeLeading: view.safeAreaInsets.left, safeTrailing: view.safeAreaInsets.right, navigation: navigation,
                progress: chrome.frame.progress, bounce: chrome.frame.bounce, keyboardInset: inset)
            nextLeading = placement.leading
            nextTrailing = -placement.trailing
            next = placement.bottom
        }
        var changed = false
        for (constraint, constant) in [(leadingConstraint, nextLeading), (trailingConstraint, nextTrailing), (Optional(bottomConstraint), next)] {
            if let constraint, abs(constraint.constant - constant) > 0.01 {
                constraint.constant = constant
                changed = true
            }
        }
        return changed
    }

    private func reportSettledEditor() {
        #if DEBUG
        guard let chrome, chrome.frame.progress == 0 || chrome.frame.progress == 1 else { return }
        func editor(in view: UIView) -> UITextView? {
            if let text = view as? ChatTextView { return text }
            for child in view.subviews { if let found = editor(in: child) { return found } }
            return nil
        }
        guard let editor = editor(in: host.view) else { return }
        let line = "LOG: [AgentChrome] editor=\(ObjectIdentifier(editor)) parent=\(String(describing: editor.superview.map(ObjectIdentifier.init))) progress=\(chrome.frame.progress) frame=\(editor.convert(editor.bounds, to: view.window)) focused=\(editor.isFirstResponder)"
        if line != lastChromeTrace { lastChromeTrace = line; chrome.report?(line) }
        #endif
    }

    @objc private func keyboardChanged(_ note: Notification) {
        view.layoutIfNeeded()
        keyboardFrame = note.name == UIResponder.keyboardWillHideNotification ? nil
            : note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
        guard updateBottomConstraint() else { return }
        let duration = note.name == UIResponder.keyboardDidChangeFrameNotification ? 0
            : (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0)
        let curve = note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt ?? 0
        if duration > 0 {
            UIView.animate(withDuration: duration, delay: 0,
                           options: [UIView.AnimationOptions(rawValue: curve << 16), .beginFromCurrentState, .allowUserInteraction]) {
                self.view.layoutIfNeeded()
            }
        } else {
            UIView.performWithoutAnimation { self.view.layoutIfNeeded() }
        }
    }
}

private final class KeyboardOverlayPassthroughView: UIView {
    weak var contentView: UIView?
    let overflowHitRegions = NSHashTable<UIView>.weakObjects()

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, alpha > 0, isUserInteractionEnabled, let contentView else { return nil }
        let localPoint = convert(point, to: contentView)
        // The reserved space above the input contains only the jump button.
        // A transparent UIHostingView still claims taps, so admit them there
        // only over the visible button's actual bounds.
        if localPoint.y < ComposerContentLayout.scrollButtonHeight,
           !overflowHitRegions.allObjects.contains(where: {
               $0.window === window && $0.bounds.insetBy(dx: -4, dy: -4).contains(convert(point, to: $0))
           }) {
            return nil
        }
        // The full-screen layout container must not intercept the chat behind it.
        // Keep hits on the hosting view itself: SwiftUI buttons use its gestures.
        return contentView.hitTest(localPoint, with: event)
    }
}

/// Marks the jump button's bounds without publishing per-frame SwiftUI geometry.
struct KeyboardOverlayHitRegion: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { KeyboardOverlayHitRegionView() }
    func updateUIView(_ view: UIView, context: Context) {}
}

private final class KeyboardOverlayHitRegionView: UIView {
    private weak var overlay: KeyboardOverlayPassthroughView?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        isUserInteractionEnabled = false
        overlay?.overflowHitRegions.remove(self)
        overlay = nil
        guard window != nil else { return }
        var ancestor = superview
        while let view = ancestor {
            if let container = view as? KeyboardOverlayPassthroughView {
                overlay = container
                container.overflowHitRegions.add(self)
                break
            }
            ancestor = view.superview
        }
    }
}
#endif

@available(iOS 16.0, macOS 14.0, *)
struct KeyboardAttachedOverlayModifier: ViewModifier {
    var onHeightChange: ((CGFloat) -> Void)? = nil
    func body(content: Content) -> some View {
        #if os(iOS)
        KeyboardAttachedOverlay(onHeightChange: onHeightChange) { content }
            .ignoresSafeArea(.keyboard)
        #else
        content
        #endif
    }
}
