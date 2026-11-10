#if os(iOS)
import SwiftUI
import UIKit

/// A non-key, pass-through window keeps the button reachable over sheets as
/// well as the chat. It takes only the button's touches, never typing focus.
@MainActor
enum WaitingOnYouFloatingButtonWindow {
    private static var window: ButtonWindow?
    private static var position: CGPoint?
    private static var didRestorePosition = false
    private static let positionKey = "ripul.waitingOnYou.buttonPosition"
    private static let persistence = DispatchQueue(label: "io.ripul.question-button-position", qos: .utility)

    static func show(count: Int) {
        guard count > 0, let scene = RipulChrome.appWindow()?.windowScene else { hide(); return }
        restorePosition()
        if let window, window.windowScene === scene,
           let controller = window.rootViewController as? ButtonController {
            controller.update(count: count)
            return
        }
        hide()
        let next = ButtonWindow(windowScene: scene)
        // This is a product control, not the inspector's own chrome: allow
        // actuation by its identifier while retaining non-key window behaviour.
        next.accessibilityIdentifier = "WaitingOnYou.floatingButtonWindow"
        next.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1)
        next.backgroundColor = .clear
        next.installRoot(ButtonController(count: count, position: position))
        next.isHidden = false
        window = next
    }

    static func hide() {
        window?.relinquishKey()
        window?.isHidden = true
        window = nil
    }

    private static func restorePosition() {
        guard !didRestorePosition else { return }
        didRestorePosition = true
        let key = positionKey
        persistence.async {
            guard let values = UserDefaults.standard.array(forKey: key) as? [Double],
                  values.count == 2, values.allSatisfy(\.isFinite) else { return }
            let saved = CGPoint(x: values[0], y: values[1])
            Task { @MainActor in
                // A drag made before the disk read finished wins over it.
                guard position == nil else { return }
                position = saved
                (window?.rootViewController as? ButtonController)?.restore(position: saved)
            }
        }
    }

    private static func remember(position: CGPoint) {
        self.position = position
        let key = positionKey
        // Once per completed drag, never on a frame or on the main thread.
        persistence.async {
            UserDefaults.standard.set([Double(position.x), Double(position.y)], forKey: key)
        }
    }

    private final class ButtonWindow: RipulChromeWindow {
        override var acceptsPresentation: Bool { false }

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            guard let controller = rootViewController as? ButtonController,
                  controller.buttonFrame.contains(point) else { return nil }
            return super.hitTest(point, with: event)
        }
    }

    private final class ButtonController: UIViewController {
        private var count: Int
        private var position: CGPoint?
        private var dragStart: CGPoint?
        private var suppressTapUntil: TimeInterval = 0
        private var keyboardFrame = CGRect.null
        private let button = UIHostingController(rootView: AnyView(EmptyView()))

        var buttonFrame: CGRect { button.view.isHidden ? .null : button.view.convert(button.view.bounds, to: view.window) }

        init(count: Int, position: CGPoint?) {
            self.count = count
            self.position = position
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            addChild(button)
            button.view.backgroundColor = .clear
            button.safeAreaRegions = []
            view.addSubview(button.view)
            button.didMove(toParent: self)
            let pan = ThresholdPanGesture(target: self, action: #selector(dragged(_:)))
            pan.maximumNumberOfTouches = 1
            button.view.addGestureRecognizer(pan)
            render()
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged),
                name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged),
                name: UIResponder.keyboardWillHideNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(composerChanged),
                name: ComposerAvoidance.didChange, object: nil)
        }

        func update(count: Int) {
            guard self.count != count else { return }
            self.count = count
            if isViewLoaded { render() }
        }

        private func render() {
            button.rootView = AnyView(WaitingOnYouFloatingButton(count: count, open: { [weak self] in
                guard let self, self.dragStart == nil, CACurrentMediaTime() >= self.suppressTapUntil else { return }
                let centre = WaitingOnYouCentre.shared
                centre.open(focusing: centre.focusId)
            }).ripulThemeRoot())
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            guard dragStart == nil else { return }
            place(WaitingOnYouButtonPlacement.frame(position: position,
                in: view.safeAreaLayoutGuide.layoutFrame, keyboard: keyboard, composers: ComposerAvoidance.frames(in: view)))
        }

        private func place(_ frame: CGRect) {
            button.view.isHidden = frame.isNull
            if !frame.isNull { button.view.frame = frame }
        }

        @objc private func composerChanged() { view.setNeedsLayout() }

        func restore(position: CGPoint) {
            guard dragStart == nil else { return }
            self.position = position
            viewIfLoaded?.setNeedsLayout()
        }

        private var keyboard: CGRect {
            if !keyboardFrame.isNull, let window = view.window {
                return view.convert(keyboardFrame, from: window.screen.coordinateSpace)
            } else if let appView = RipulChrome.appWindow(in: view.window?.windowScene)?.rootViewController?.view {
                // A question can arrive while the keyboard is already up,
                // before this controller has received any keyboard notification.
                return view.convert(appView.keyboardLayoutGuide.layoutFrame, from: appView)
            } else {
                return .null
            }
        }

        @objc private func dragged(_ gesture: UIPanGestureRecognizer) {
            if gesture.state == .began { dragStart = button.view.frame.origin }
            guard let start = dragStart else { return }
            let safe = view.safeAreaLayoutGuide.layoutFrame
            // Measure in the stationary window, not the button under the finger.
            let translation = gesture.translation(in: view)
            let frame = WaitingOnYouButtonPlacement.frame(
                origin: CGPoint(x: start.x + translation.x, y: start.y + translation.y), in: safe,
                keyboard: keyboard, composers: ComposerAvoidance.frames(in: view))
            place(frame)
            if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
                if !frame.isNull {
                    position = WaitingOnYouButtonPlacement.position(of: frame, in: safe)
                    if let position { WaitingOnYouFloatingButtonWindow.remember(position: position) }
                }
                dragStart = nil
                // The finger lifting from a drag must not also press the SwiftUI button.
                suppressTapUntil = CACurrentMediaTime() + 0.15
                view.setNeedsLayout()
            }
        }

        @objc private func keyboardChanged(_ notification: Notification) {
            keyboardFrame = notification.name == UIResponder.keyboardWillHideNotification ? .null
                : (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect ?? .null)
            view.setNeedsLayout()
        }
    }
}

private struct WaitingOnYouFloatingButton: View {
    let count: Int
    let open: () -> Void

    var body: some View {
        styledButton
            .overlay(alignment: .topTrailing) {
                Text(count > 99 ? "99+" : "\(count)")
                    .font(.ripul(.caption2, weight: .bold))
                    .foregroundStyle(.ripul(.onAccent))
                    .padding(.horizontal, 5)
                    .frame(minWidth: 22, minHeight: 22)
                    .background(.ripul(.accent), in: Capsule())
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .padding(4)
            .accessibilityLabel("Waiting on You")
            .accessibilityValue("\(count) items waiting")
            .accessibilityHint("Opens the questions and permission requests waiting for your answer. Drag to move the button.")
            .uiKitIdentifier("WaitingOnYou.floatingButton")
    }

    private var button: some View {
        Button(action: open) {
            Image(systemName: "questionmark.bubble.fill")
                .font(.ripul(.title2, weight: .semibold))
                .frame(width: 56, height: 56)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.ripul(.accent))
    }

    @ViewBuilder private var styledButton: some View {
        if #available(iOS 26.0, *) {
            button.glassEffect(.regular.interactive(), in: .circle)
        } else {
            button.background(.regularMaterial, in: Circle())
        }
    }
}
#endif
