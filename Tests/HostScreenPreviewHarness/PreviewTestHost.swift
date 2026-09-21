import SwiftUI
@testable import RipulAgent

@main
struct PreviewTestHost: App {
    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("--explorer-agent-touch-ui-tests") {
                ExplorerAgentTouchHarness().ignoresSafeArea()
            } else if ProcessInfo.processInfo.arguments.contains("--simulator-preview-ui-tests") {
                SimulatorPreviewHarness().preferredColorScheme(.dark)
            } else if ProcessInfo.processInfo.arguments.contains("--anchored-tool-strip-ui-tests") || ProcessInfo.processInfo.arguments.contains("--all-tool-rows-ui-tests") {
                AnchoredToolStripHarness().ignoresSafeArea(edges: .bottom)
                    .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("--light-appearance") ? .light : .dark)
            } else if ProcessInfo.processInfo.arguments.contains("--tool-strip-ui-tests") {
                NativeToolStripHarnessSurface()
                    .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("--light-appearance") ? .light : .dark)
            } else if ProcessInfo.processInfo.arguments.contains("--code-width-ui-tests") {
                ToolCodeWidthHarnessSurface()
            } else if ProcessInfo.processInfo.arguments.contains("--tool-details-ui-tests") {
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

private struct ToolCodeWidthHarnessSurface: View {
    @State private var width: CGFloat = 360
    @State private var text = "printf 'a medium length line'"

    var body: some View {
        VStack(spacing: 20) {
            NativeToolCodeBlock(text: text, title: "Output", syntax: .shell).frame(width: width)
            Button("Narrow panel") { width = 260 }
            Button("Wide panel") { width = 360 }
            Button("Short text") { text = "done" }
            Button("Long text") { text = "printf 'a medium length line'" }
        }
    }
}

private struct ToolDetailsHarnessSurface: View {
    @StateObject private var store = ToolCallDetailsStore()
    @State private var dismissed = false
    @State private var copiedCommand = ""
    @State private var liveUpdates: Task<Void, Never>?

    var body: some View {
        VStack {
            Button("Open tool details") {
                liveUpdates?.cancel()
                let chosen = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--renderer=") }?.replacingOccurrences(of: "--renderer=", with: "")
                let data = try! Data(contentsOf: Bundle.main.url(forResource: "tool-call-renderers", withExtension: "json")!)
                let fixtures = try! JSONSerialization.jsonObject(with: data) as! [[String: Any]]
                var fixture = fixtures.first { $0["name"] as? String == (chosen ?? "terminal") }!
                if ProcessInfo.processInfo.arguments.contains("--console-large-capture") {
                    fixture["result"] = ["total": 500, "logs": (0..<130).map { index in
                        ["level": "INFO", "ts": 1_789_120_000_000 + index * 1000,
                         "message": index == 129 ? (1...12).map { "Diagnostic line \($0)" }.joined(separator: "\n") + "\nEND OF MESSAGE" : "Captured entry \(index)"] as [String: Any]
                    }] as [String: Any]
                }
                if ProcessInfo.processInfo.arguments.contains("--long-output") {
                    fixture["result"] = String(repeating: "Long output remains copyable and horizontally scrollable. ", count: 6) + "END"
                }
                if ProcessInfo.processInfo.arguments.contains("--terminal-source") {
                    fixture["renderArguments"] = ["cmd": "cat RipulVoiceModeRequest.swift"]
                    fixture["result"] = ["stdout": """
                    import SwiftUI

                    public enum RipulVoiceModeRequest {
                        public static var pending = false

                        public static func start() {
                            pending = true
                            NotificationCenter.default.post(name: Notification.Name("ripulStartVoiceMode"), object: nil)
                        }
                    }
                    """, "exit_code": 0] as [String: Any]
                }
                func text(_ value: Any) -> String {
                    if let value = value as? String { return value }
                    return String(decoding: try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .prettyPrinted, .sortedKeys]), as: UTF8.self)
                }
                let count = ProcessInfo.processInfo.arguments.contains("--call-gallery") ? 10 : chosen == nil ? 2 : 1
                let examples = [
                    ("Inspect working tree", "git status --short"),
                    ("Run the test suite", "npm test"),
                    ("Find the native renderer", "rg -n NativeToolCallRenderer Sources"),
                    ("Read the panel component", "sed -n '1,100p' GlassComponents.swift"),
                    ("Check changed files", "git diff --stat"),
                    ("Review the disclosure layout", "git diff -- ToolCallDetails.swift"),
                    ("Check formatting", "git diff --check"),
                    ("Verify the native tests", "swift test --filter ToolCallDetailsTests"),
                    ("Inspect the final changes", "git diff --stat"),
                    ("Review recent commits", "git log -5 --oneline"),
                ]
                var message: [String: Any] = [
                    "initialCallId": ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--initial-call=") }?.replacingOccurrences(of: "--initial-call=", with: "") ?? NSNull(),
                    "requestId": "ui-fixture", "title": (fixture["commandPresentation"] as? [String: Any])?["label"] ?? ToolValue.title((fixture["toolName"] as! String).replacingOccurrences(of: "^mcp__ripul_tools_+", with: "", options: .regularExpression)),
                    "calls": (1...count).map { number in [
                        "id": "call-\(number)", "toolName": fixture["toolName"]!, "status": "success",
                        "timestamp": 1_789_106_000_000,
                        "arguments": text(chosen == nil ? ["description": examples[number - 1].0, "command": examples[number - 1].1] : fixture["args"]!),
                        "rendererName": fixture["rendererName"]!,
                        "renderArguments": chosen == nil ? ["description": examples[number - 1].0, "command": examples[number - 1].1] : fixture["renderArguments"]!,
                        "commandPresentation": fixture["commandPresentation"] ?? NSNull(),
                        "result": chosen == nil ? "Result for call \(number)" : text(fixture["result"]!),
                        "diagnostics": text(["toolName": fixture["toolName"]!, "arguments": fixture["args"]!, "status": "success", "duration": 42.5, "background": false, "error": NSNull()]),
                    ] as [String: Any] },
                ]
                if ProcessInfo.processInfo.arguments.contains("--task-activity") {
                    var calls = message["calls"] as! [[String: Any]]
                    calls = [calls[0]]
                    calls[0]["status"] = "running"
                    calls[0]["rendererName"] = "Agent"
                    calls[0]["toolName"] = "Agent"
                    calls[0]["commandPresentation"] = NSNull()
                    calls[0]["task"] = ["id": "task-checks", "type": "local_agent", "title": "Check background task rendering",
                        "status": "running", "variant": "Explore", "synthetic": false, "totalCount": 14,
                        "usage": "1,234 tokens · 8 tool uses · 42s",
                        "entries": [["kind": "tool", "label": "Read", "detail": "src/logging/components/chat/v2/useChatItems.ts"],
                                    ["kind": "tool", "label": "Grep", "detail": "Locate task status updates and their rendering path"],
                                    ["kind": "text", "detail": "The launching call has completed; the background task is still working."]]] as [String: Any]
                    message["calls"] = calls
                    message["title"] = "Tool calls"
                }
                store.receive(message, opening: true)
                if ProcessInfo.processInfo.arguments.contains("--live-calls") {
                    liveUpdates = Task { @MainActor in
                        var update = message
                        var calls = message["calls"] as! [[String: Any]]
                        for addedCount in [1, 2] {
                            do { try await Task.sleep(for: .seconds(4)) } catch { return }
                            for _ in 0..<addedCount {
                                let number = calls.count + 1
                                var call = calls[0]
                                call["id"] = "call-\(number)"
                                let args = ["description": "Incoming call \(number)", "command": "echo \(number)"]
                                call["arguments"] = text(args)
                                call["renderArguments"] = args
                                call["result"] = "Result for call \(number)"
                                calls.append(call)
                            }
                            update["calls"] = calls
                            store.receive(update, opening: false)
                        }
                    }
                }
            }
            if dismissed { Text("Details dismissed") }
            Button("Read copied command") { copiedCommand = UIPasteboard.general.string ?? "" }
            Text(copiedCommand).accessibilityIdentifier("Copied command")
        }
        .modifier(ToolCallDetailsPresenter(store: store, onDismiss: { _ in
            liveUpdates?.cancel()
            dismissed = true
        }))
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

private struct NativeToolStripHarnessSurface: View {
    @StateObject private var strip = NativeToolStripStore()
    @StateObject private var details = ToolCallDetailsStore()
    @State private var count = 2
    @State private var busy = false
    @State private var group = "row-a"
    @State private var events = ""
    @State private var draft = ""

    private func update(idle: Bool = false) {
        // Typed piecewise: as one nested literal this expression exceeds the
        // compiler's type-check budget on a loaded machine.
        let labels = ["Python", "Grep", "Read", "Xcode", "Diff"]
        let tools: [[String: Any]] = (1...count).reversed().map { (n: Int) -> [String: Any] in
            let id: String = "call-\(n)"
            let label: String = labels[(n - 1) % 5]
            let uses: Int = n == 1 ? 2 : 1
            if busy && n == 1 { return ["id": id, "label": "Check background tasks", "count": 1, "rendererName": "Agent", "status": "running"] }
            return ["id": id, "label": label, "count": uses]
        }
        let updatedAt: Double = Date().timeIntervalSince1970 * 1000 - (idle ? 20_001 : 0)
        let payload: [String: Any] = ["ownerId": "fixture", "chatId": "chat", "groupId": group,
                                      "updatedAt": updatedAt, "tools": tools]
        strip.receive(payload)
    }

    var body: some View {
        VStack {
            Button("Start tools") { busy = false; count = 2; update() }
            Button("Start tasks") { busy = true; count = 2; update() }
            Button("Finish tasks") { busy = false; update(idle: true) }
            Button("Burst tools") {
                Task { for n in 3...10 { count = n; update(); try? await Task.sleep(nanoseconds: 40_000_000) } }
            }
            Button("Idle tools") { update(idle: true) }
            Button("Switch row") { group = "row-b"; count = 1; update() }
            Text(events).accessibilityIdentifier("StripHarness.event")
            ScrollView { ForEach(0..<20) { n in Text("Chat message \(n)").frame(maxWidth: .infinity).padding() } }
            VStack(spacing: 8) {
                NativeToolStrip(store: strip) { event in
                    events = event["type"] as? String ?? ""
                    if event["type"] as? String == "agent-framework:toolStrip:select" {
                        details.receive(["requestId": "fixture-details", "title": "Tool calls", "initialCallId": event["toolId"]!,
                                         "calls": (1...count).map { n in
                                             ["id": "call-\(n)", "toolName": "Bash", "status": "success", "timestamp": 1,
                                              "arguments": "{\"command\":\"pwd\"}", "result": "/repo", "diagnostics": "{}"] as [String: Any]
                                         }], opening: true)
                    }
                }
                TextField("Message", text: $draft).textFieldStyle(.roundedBorder).accessibilityIdentifier("StripHarness.composer")
            }.padding(.horizontal, 12)
        }
        .modifier(ToolCallDetailsPresenter(store: details, onDismiss: { _ in }))
    }
}
