#if os(iOS)
import UIKit

/// Hosts the same chat controller in both presentations. Changing a view context
/// changes geometry only: the WebView, composer, draft and conversation survive.
/// The content's AgentConfiguration must set respectsContainerSafeArea = true.
@MainActor
public final class EmbeddedAgentContainerController: UIViewController {
    public var floatingCornerRadius: () -> CGFloat = { 20 }
    public var onPresentationChanged: ((EmbeddedChatPresentation) -> Void)?
    public private(set) var presentation: EmbeddedChatPresentation
    private let defaultPresentation: EmbeddedChatPresentation
    private let content: UIViewController
    private let bridge: AgentBridge
    private let viewport = UIView()

    public init(content: UIViewController, bridge: AgentBridge, defaultPresentation: EmbeddedChatPresentation = .fullscreen) {
        self.content = content
        self.bridge = bridge
        self.defaultPresentation = defaultPresentation
        self.presentation = bridge.embeddedChatPresentation ?? defaultPresentation
        super.init(nibName: nil, bundle: nil)
        bridge.onEmbeddedChatPresentationChanged = { [weak self] in self?.applyPresentation() }
    }

    required init?(coder: NSCoder) { fatalError("Use init(content:bridge:)") }

    public override func loadView() { view = EmbeddedChatRootView() }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "embeddedChat.container"
        viewport.accessibilityIdentifier = "embeddedChat.safeViewport"
        view.backgroundColor = .clear
        viewport.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(viewport)
        let safe = view.safeAreaLayoutGuide
        let bottom = viewport.bottomAnchor.constraint(equalTo: safe.bottomAnchor)
        bottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            bottom,
            viewport.topAnchor.constraint(equalTo: safe.topAnchor),
            viewport.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            viewport.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            viewport.bottomAnchor.constraint(lessThanOrEqualTo: safe.bottomAnchor),
            viewport.bottomAnchor.constraint(lessThanOrEqualTo: view.keyboardLayoutGuide.topAnchor),
        ])
        addChild(content)
        viewport.addSubview(content.view)
        content.didMove(toParent: self)
        content.view.clipsToBounds = true
        content.view.layer.cornerCurve = .continuous
        (view as? EmbeddedChatRootView)?.content = content.view
        applyPresentation()
    }

    private func applyPresentation() {
        presentation = bridge.embeddedChatPresentation ?? defaultPresentation
        guard isViewLoaded else { return }
        (view as? EmbeddedChatRootView)?.passesThroughOutsideContent = presentation == .floating
        view.setNeedsLayout()
        onPresentationChanged?(presentation)
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        content.view.frame = EmbeddedChatLayout.frame(in: viewport.bounds, presentation: presentation)
        content.view.layer.cornerRadius = presentation == .floating ? floatingCornerRadius() : 0
        view.backgroundColor = presentation == .fullscreen ? content.view.backgroundColor : .clear
    }
}

/// A floating window leaves the customer's app usable around it. Full screen
/// consumes the whole surface, including the background around safe content.
private final class EmbeddedChatRootView: UIView {
    weak var content: UIView?
    var passesThroughOutsideContent = false
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if passesThroughOutsideContent, let content,
           !content.bounds.contains(content.convert(point, from: self)) { return nil }
        return super.hitTest(point, with: event)
    }
}
#endif
