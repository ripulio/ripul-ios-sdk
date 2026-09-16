import SwiftUI
import WebKit
@testable import RipulAgent

struct ExplorerAgentTouchHarness: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> ExplorerAgentTouchController { .init() }
    func updateUIViewController(_ controller: ExplorerAgentTouchController, context: Context) {}
}

/// Uses the production minimized bar and both production UIWindow subclasses.
/// The capture surface omits the HUD so these taps test window routing directly.
final class ExplorerAgentTouchController: UIViewController {
    private var explorer: RipulExplorerOverlayWindow?
    private let session = InspectorSession()
    private var stateTimer: Timer?
    private var picks = 0

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
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 4)
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
        let state = UILabel(frame: CGRect(x: 12, y: 100, width: host.bounds.width - 24, height: 60))
        state.accessibilityIdentifier = "explorerAgentHarness.state"
        state.numberOfLines = 2
        explorerRoot.view.addSubview(state)
        window.isHidden = false
        explorer = window
        stateTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self, weak agent, weak state] _ in
            guard let self, let agent else { return }
            state?.text = "\(agent.isInspectorSelectionEnabled ? "expanded" : "minimized"); picks=\(self.picks); pinned=\(self.session.pinned)"
        }
    }
}
