import SwiftUI
@testable import RipulAgent

@main
struct PreviewTestHost: App {
    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("--tool-details-ui-tests") {
                ToolDetailsHarnessSurface()
                    .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("--light-appearance") ? .light : .dark)
            } else if ProcessInfo.processInfo.arguments.contains("--preview-ui-tests") {
                PreviewHarnessSurface().ignoresSafeArea()
            } else {
                Text("Host preview rendering tests")
            }
        }
    }
}

private struct ToolDetailsHarnessSurface: View {
    @StateObject private var store = ToolCallDetailsStore()
    @State private var dismissed = false

    var body: some View {
        VStack {
            Button("Open tool details") {
                let chosen = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--renderer=") }?.replacingOccurrences(of: "--renderer=", with: "")
                let data = try! Data(contentsOf: Bundle.main.url(forResource: "tool-call-renderers", withExtension: "json")!)
                let fixtures = try! JSONSerialization.jsonObject(with: data) as! [[String: Any]]
                let fixture = fixtures.first { $0["name"] as? String == (chosen ?? "terminal") }!
                func text(_ value: Any) -> String {
                    if let value = value as? String { return value }
                    return String(decoding: try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .prettyPrinted, .sortedKeys]), as: UTF8.self)
                }
                store.receive([
                    "requestId": "ui-fixture", "title": ToolValue.title((fixture["toolName"] as! String).replacingOccurrences(of: "^mcp__ripul_tools_+", with: "", options: .regularExpression)),
                    "calls": (1...(chosen == nil ? 2 : 1)).map { number in [
                        "id": "call-\(number)", "toolName": fixture["toolName"]!, "status": "success",
                        "timestamp": 1_789_106_000_000,
                        "arguments": text(chosen == nil ? ["command": "command \(number)"] : fixture["args"]!),
                        "rendererName": fixture["rendererName"]!,
                        "renderArguments": chosen == nil ? ["command": "command \(number)"] : fixture["renderArguments"]!,
                        "result": chosen == nil ? "Result for call \(number)" : text(fixture["result"]!),
                        "diagnostics": text(["toolName": fixture["toolName"]!, "arguments": fixture["args"]!, "status": "success", "duration": 42.5, "background": false, "error": NSNull()]),
                    ] as [String: Any] },
                ], opening: true)
            }
            if dismissed { Text("Details dismissed") }
        }
        .modifier(ToolCallDetailsPresenter(store: store, onDismiss: { _ in dismissed = true }))
    }
}

private struct PreviewHarnessSurface: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> PreviewHarnessController { PreviewHarnessController() }
    func updateUIViewController(_ controller: PreviewHarnessController, context: Context) {}
}

private final class PreviewHarnessController: UIViewController {
    private var overlay: RipulChromeWindow?
    private var agentTaps = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGreen
        let title = UILabel(frame: CGRect(x: 20, y: 180, width: 280, height: 60))
        title.text = "The host app"
        view.addSubview(title)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard overlay == nil, let host = view.window, let scene = host.windowScene else { return }
        let window = RipulChromeWindow(windowScene: scene)
        let root = UIViewController()
        root.view.backgroundColor = .systemBackground
        window.installRoot(root)
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 3)
        window.setKeyInputEnabled(true) // same input ownership as the expanded agent
        window.isHidden = false
        let button = UIButton(type: .system)
        button.frame = CGRect(x: 24, y: root.view.bounds.height - 100, width: 240, height: 44)
        button.autoresizingMask = [.flexibleTopMargin]
        button.setTitle("Agent taps: 0", for: .normal)
        button.accessibilityIdentifier = "previewHarness.agentButton"
        button.addAction(UIAction { [weak self, weak button] _ in
            guard let self else { return }
            self.agentTaps += 1
            button?.setTitle("Agent taps: \(self.agentTaps)", for: .normal)
        }, for: .touchUpInside)
        root.view.addSubview(button)
        let suite = "io.ripul.preview-test-host.controls"
        let store = UserDefaults(suiteName: suite)!
        store.removePersistentDomain(forName: suite)
        let state = HostScreenPreviewState(store: store) { [weak host] in host }
        let preview = HostScreenPreviewController(state: state)
        root.addChild(preview)
        preview.view.frame = root.view.bounds
        preview.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        root.view.addSubview(preview.view)
        preview.didMove(toParent: root)
        state.setAgentExpanded(true)
        overlay = window
    }
}
