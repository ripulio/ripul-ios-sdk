import SwiftUI
import WebKit
@testable import RipulAgent

struct InspectorAttachmentHarness: View {
    @StateObject private var model = InspectorAttachmentModel()

    var body: some View {
        VStack(spacing: 16) {
            Button("Open native inspector") { model.open(web: false) }
            Button("Open web inspector") { model.open(web: true) }
            InspectorAttachmentTargets(model: model).frame(height: 260)
            InspectorAttachmentStatus(store: model.bridge.composerContexts)
            ComposerContextChips(store: model.bridge.composerContexts, session: "attachment-conversation")
            ComposerContextButton(store: model.bridge.composerContexts, session: "attachment-conversation",
                                  options: model.bridge.composerContexts.availableOptions, size: 44)
            Spacer()
        }
        .padding(24)
    }
}

private struct InspectorAttachmentStatus: View {
    @ObservedObject var store: RipulComposerContextStore
    var body: some View {
        let items = store.attachments(for: "attachment-conversation")
        Text("attachments=\(items.count); images=\(items.compactMap(\.screenshotAttachment).count); tab=\(store.attachments(for: "attachment-tab").count)")
            .accessibilityIdentifier("attachmentHarness.status")
    }
}

@MainActor
private final class InspectorAttachmentModel: ObservableObject {
    @Published var bridge = AgentBridge()
    private var minimizedAgent: RipulDevOverlayWindow?
    private let usesHostGesture = ProcessInfo.processInfo.arguments.contains("--minimized-chat")
    weak var native: UIButton?
    weak var web: WKWebView?

    init() {
        configureChat()
    }

    private func configureChat() {
        bridge.sessions = [ChatSession(id: "attachment-tab", sourceChatId: "attachment-conversation", displayName: "Attachment test", createdAt: Date())]
        bridge.activeSessionId = "attachment-tab"
        bridge.composerContexts.availableOptions = [.selectedElement(configuration: .init(defaults: [.instrumentedText, .screenshot]))]
    }

    func open(web isWeb: Bool) {
        let candidate: UIView? = isWeb ? web : native
        guard let target = candidate, let window = target.window else { return }
        UserDefaults.standard.set(false, forKey: "viewInspector.folded")
        UserDefaults.standard.set("developer", forKey: "viewInspector.mode")
        UserDefaults.standard.set(8, forKey: "viewInspector.posX")
        UserDefaults.standard.set(80, forKey: "viewInspector.posY")
        UserDefaults.standard.set(360, forKey: "viewInspector.w")
        UserDefaults.standard.set(260, forKey: "viewInspector.h")
        if usesHostGesture {
            if minimizedAgent == nil, let scene = window.windowScene {
                let agent = RipulDevOverlayWindow(windowScene: scene)
                let root = RipulDevOverlayRootVC()
                root.configuration = RipulSessionsConfiguration(
                    cache: UserDefaultsSessionCache(suiteName: "io.ripul.attachment-harness.minimized"),
                    baseURL: URL(string: "http://127.0.0.1:9")!, websiteDataStore: .nonPersistent())
                agent.installRoot(root)
                agent.isHidden = false
                root.showCompact()
                guard let existingBridge = root.inspectorContextBridge else { return }
                bridge = existingBridge
                configureChat()
                minimizedAgent = agent
            }
            // This is exactly the host shake entry point: no bridge supplied.
            RipulViewExplorer.toggle(in: window)
        } else {
            RipulViewExplorer.present(in: window, bridge: bridge)
        }
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            let local = isWeb ? CGPoint(x: 40, y: 40) : CGPoint(x: target.bounds.midX, y: target.bounds.midY)
            let point = target.convert(local, to: window)
            _ = try? await ExplorerProbeTool().execute(args: ["x": point.x, "y": point.y])
        }
    }
}

private struct InspectorAttachmentTargets: UIViewControllerRepresentable {
    let model: InspectorAttachmentModel
    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        let button = UIButton(type: .system)
        button.frame = CGRect(x: 20, y: 10, width: 280, height: 44)
        button.setTitle("Native attachment target", for: .normal)
        button.accessibilityIdentifier = "attachment.native"
        controller.view.addSubview(button)
        let web = WKWebView(frame: CGRect(x: 0, y: 90, width: 340, height: 160))
        web.loadHTMLString("""
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <button data-ui="attachment.web" style="position:absolute;left:20px;top:20px;width:260px;height:60px">Web attachment target</button>
            """, baseURL: nil)
        controller.view.addSubview(web)
        model.native = button
        model.web = web
        return controller
    }
    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}
