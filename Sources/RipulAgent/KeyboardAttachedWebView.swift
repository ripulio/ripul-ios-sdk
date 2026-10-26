#if os(iOS)
import UIKit

/// A stationary viewport around the web controller. UIKit translates its
/// content with the same keyboard notification and animation as the composer;
/// SwiftUI neither interpolates the offset nor remeasures a shifted viewport.
@MainActor
final class KeyboardAttachedWebViewController: UIViewController {
    let content: AgentWebViewController
    private weak var bridge: AgentBridge?
    private var navigationInset: CGFloat?
    private var keyboardFrame: CGRect?

    init(content: AgentWebViewController, bridge: AgentBridge, navigationInset: CGFloat?) {
        self.content = content
        self.bridge = bridge
        self.navigationInset = navigationInset
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        addChild(content)
        view.addSubview(content.view)
        content.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.view.topAnchor.constraint(equalTo: view.topAnchor),
            content.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        content.didMove(toParent: self)
        for name in [UIResponder.keyboardWillChangeFrameNotification,
                     UIResponder.keyboardDidChangeFrameNotification,
                     UIResponder.keyboardWillHideNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)), name: name, object: nil)
        }
    }

    func update(navigationInset: CGFloat?) {
        guard self.navigationInset != navigationInset else { return }
        self.navigationInset = navigationInset
        if navigationInset == nil { keyboardFrame = nil }
        if isViewLoaded { updateTranslation() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateTranslation()
    }

    private func updateTranslation() {
        var shift: CGFloat = 0
        if let navigationInset, let window = view.window, let keyboardFrame {
            let local = view.convert(keyboardFrame, from: window.screen.coordinateSpace)
            let inWindow = window.convert(keyboardFrame, from: window.screen.coordinateSpace)
            shift = ComposerKeyboardLayout.webShift(bounds: view.bounds,
                safeBottom: window.safeAreaInsets.bottom, navigationInset: navigationInset,
                keyboard: local, docked: inWindow.maxY >= window.bounds.maxY - 1)
        }
        let transform = CGAffineTransform(translationX: 0, y: -shift)
        if content.view.transform != transform { content.view.transform = transform }
    }

    @objc private func keyboardChanged(_ note: Notification) {
        guard isViewLoaded, view.window != nil else { return }
        view.layoutIfNeeded()
        // Focus can go before the hide notification (for example a back swipe).
        // It must not reset the transform in a separate SwiftUI transaction.
        keyboardFrame = note.name != UIResponder.keyboardWillHideNotification
            && bridge?.nativeChatInputFocused == true
            ? note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect : nil
        ComposerKeyboardAnimation.perform(note) { self.updateTranslation() }
    }
}
#endif
