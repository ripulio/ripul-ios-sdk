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

#if os(iOS)
import UIKit

/// UIKit owns positioning and uses the keyboard's frame, duration and curve.
/// No per-frame SwiftUI state or second spring is involved. Keyboard layout
/// guides were measured stuck at rest in the tab-hosted view hierarchy.
@available(iOS 16.0, *)
struct KeyboardAttachedOverlay<Content: View>: UIViewControllerRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeUIViewController(context: Context) -> KeyboardAttachedOverlayController {
        KeyboardAttachedOverlayController(content: AnyView(content.environment(\.self, context.environment)))
    }

    func updateUIViewController(_ controller: KeyboardAttachedOverlayController, context: Context) {
        // Updating the same hosting controller preserves the editor, draft,
        // selection and first responder across bridge/environment changes.
        controller.host.rootView = AnyView(content.environment(\.self, context.environment))
    }
}

@available(iOS 16.0, *)
final class KeyboardAttachedOverlayController: UIViewController {
    let host: UIHostingController<AnyView>
    private var bottomConstraint: NSLayoutConstraint?
    private var keyboardFrame: CGRect?

    init(content: AnyView) {
        host = UIHostingController(rootView: content)
        super.init(nibName: nil, bundle: nil)
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
        NSLayoutConstraint.activate([
            // Local guides are zero-inset when the parent already avoided an
            // edge, and protect the same composer in a full-window host.
            host.view.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
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
        let next = -(inset + 8)
        guard abs(bottomConstraint.constant - next) > 0.01 else { return false }
        bottomConstraint.constant = next
        return true
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
        if localPoint.y < 64,
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
    func body(content: Content) -> some View {
        #if os(iOS)
        KeyboardAttachedOverlay { content }
            .ignoresSafeArea(.keyboard)
        #else
        content
        #endif
    }
}
