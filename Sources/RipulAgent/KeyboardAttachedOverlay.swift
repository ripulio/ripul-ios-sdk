import SwiftUI
#if os(iOS)
import UIKit

/// UIKit owns the vertical position so the overlay participates in the keyboard's
/// own animation and interactive dismissal. Publishing a height to SwiftUI and
/// starting a second spring cannot keep the two surfaces attached.
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
            // The guide owns avoidance; don't let the inner SwiftUI hierarchy
            // add another keyboard/safe-area inset as its frame moves.
            host.safeAreaRegions = []
        }
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8),
        ])
        host.didMove(toParent: self)
        (view as? KeyboardOverlayPassthroughView)?.contentView = host.view
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
