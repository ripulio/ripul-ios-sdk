import SwiftUI
import WebKit
@testable import RipulAgent

struct ExplorerAgentTouchHarness: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> ExplorerAgentTouchController { .init() }
    func updateUIViewController(_ controller: ExplorerAgentTouchController, context: Context) {}
}

/// Uses the production minimized bar and both production UIWindow subclasses.
/// A real floating-panel root deliberately overlaps an agent control so the
/// coordinate test checks both capture priority and visible window ordering.
final class ExplorerAgentTouchController: UIViewController {
    private var explorer: RipulExplorerOverlayWindow?
    private let session = InspectorSession()
    private var stateTimer: Timer?
    private var picks = 0
    private var agentTaps = 0
    private var panelTaps = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGreen
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard explorer == nil, let host = view.window, let scene = host.windowScene else { return }
        let suite = "io.ripul.preview-test-host.explorer-agent-touches"
        let store = UserDefaults(suiteName: suite)!
        store.removePersistentDomain(forName: suite)
        let configuration = RipulSessionsConfiguration(
            cache: UserDefaultsSessionCache(suite: store),
            baseURL: URL(string: "http://127.0.0.1:9")!,
            websiteDataStore: .nonPersistent())
        RipulDevAssistantOverlay.installRestoreHook(configuration: configuration)
        RipulDevAssistantOverlay.shared.prewarm()
        guard let agent = scene.windows.compactMap({ $0 as? RipulDevOverlayWindow }).first,
              let root = agent.rootViewController as? RipulDevOverlayRootVC else { return }
        root.showCompact()

        let window = RipulExplorerOverlayWindow(windowScene: scene)
        window.frame = host.frame
        window.windowLevel = RipulExplorerOverlayWindow.overlayLevel
        let explorerRoot = UIViewController()
        explorerRoot.view.backgroundColor = .clear
        explorerRoot.view.tag = ripulViewExplorerOverlayTag
        window.installRoot(explorerRoot)
        let capture = ViewInspectorController(frame: host.bounds)
        capture.hostWindow = host
        capture.session = session
        session.controller = capture
        capture.onInspect = { [weak self] _ in self?.picks += 1 }
        explorerRoot.view.addSubview(capture)
        let overlap = CGRect(x: 40, y: 350, width: host.bounds.width - 80, height: 60)
        let panel = RipulFloatingPanelRootView(frame: host.bounds)
        let panelButton = UIButton(type: .system)
        panelButton.frame = overlap
        panelButton.backgroundColor = .systemYellow
        panelButton.setTitle("Explorer panel control", for: .normal)
        panelButton.accessibilityIdentifier = "explorerAgentHarness.panelButton"
        panelButton.addAction(UIAction { [weak self] _ in self?.panelTaps += 1 }, for: .touchUpInside)
        panel.addSubview(panelButton)
        panel.panelView = panelButton
        explorerRoot.view.addSubview(panel)
        let agentButton = UIButton(type: .system)
        agentButton.frame = overlap
        agentButton.backgroundColor = .systemBlue
        agentButton.setTitle("Agent control", for: .normal)
        agentButton.accessibilityIdentifier = "explorerAgentHarness.agentButton"
        agentButton.addAction(UIAction { [weak self] _ in self?.agentTaps += 1 }, for: .touchUpInside)
        root.view.addSubview(agentButton)
        let collapse = UIButton(type: .system)
        collapse.frame = CGRect(x: 40, y: 440, width: host.bounds.width - 80, height: 60)
        collapse.setTitle("Minimize agent", for: .normal)
        collapse.accessibilityIdentifier = "explorerAgentHarness.collapse"
        collapse.addAction(UIAction { _ in RipulDevAssistantOverlay.shared.collapse() }, for: .touchUpInside)
        root.view.addSubview(collapse)
        let state = UILabel(frame: CGRect(x: 12, y: 100, width: host.bounds.width - 24, height: 60))
        state.accessibilityIdentifier = "explorerAgentHarness.state"
        state.numberOfLines = 2
        root.view.addSubview(state)
        window.isHidden = false
        explorer = window
        stateTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self, weak agent, weak state, weak agentButton, weak collapse] _ in
            guard let self, let agent else { return }
            agentButton?.isHidden = !agent.isExpanded
            collapse?.isHidden = !agent.isExpanded
            // The production console is mounted lazily on the first expand.
            for control in [agentButton, collapse, state] {
                if let control { root.view.bringSubviewToFront(control) }
            }
            state?.text = "\(agent.isExpanded ? "expanded" : "minimized"); picks=\(self.picks); pinned=\(self.session.pinned); agent=\(self.agentTaps); panel=\(self.panelTaps)"
        }
    }
}
