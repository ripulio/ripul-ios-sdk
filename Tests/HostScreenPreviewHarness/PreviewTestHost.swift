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
            } else if ProcessInfo.processInfo.arguments.contains("--session-families-ui-tests") {
                SessionFamiliesHarness()
                    .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("--light-appearance") ? .light : .dark)
            } else if ProcessInfo.processInfo.arguments.contains("--code-width-ui-tests") {
                ToolCodeWidthHarnessSurface()
            } else if ProcessInfo.processInfo.arguments.contains("--tool-details-ui-tests") {
                ToolDetailsHarnessSurface()
                    .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("--light-appearance") ? .light : .dark)
            } else if ProcessInfo.processInfo.arguments.contains("--native-chat-ui-tests") {
                NativeChatHarnessSurface()
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
                        "agentComms": fixture["agentComms"] ?? NSNull(),
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

private struct NativeChatHarnessSurface: View {
    @State private var bridge = AgentBridge()
    @State private var scene: Int = {
        if ProcessInfo.processInfo.arguments.contains("--scene=2") { return 2 }
        if ProcessInfo.processInfo.arguments.contains("--scene=3") { return 3 }
        return 1
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button("Scene 1: Turns & Tools") { loadScene(1) }
                    .accessibilityIdentifier("NativeChatHarness.scene1")
                Button("Scene 2: Ask & Meta") { loadScene(2) }
                    .accessibilityIdentifier("NativeChatHarness.scene2")
                Button("Scene 3: Seams & Notes") { loadScene(3) }
                    .accessibilityIdentifier("NativeChatHarness.scene3")
            }
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // The page owns the thinking setting; with no page here, set the
            // bridge's copy of it directly.
            HStack(spacing: 8) {
                Button("Thinking: None") { bridge.showThinkingMode = "none" }
                    .accessibilityIdentifier("NativeChatHarness.thinkingNone")
                Button("Folded") { bridge.showThinkingMode = "folded" }
                    .accessibilityIdentifier("NativeChatHarness.thinkingFolded")
                Button("Open") { bridge.showThinkingMode = "open" }
                    .accessibilityIdentifier("NativeChatHarness.thinkingOpen")
            }
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Divider()

            NativeChatView(store: bridge.nativeChat, bridge: bridge)
        }
        .modifier(ToolCallDetailsPresenter(store: bridge.toolCallDetails, onDismiss: { _ in }))
        .onAppear {
            loadScene(scene)
        }
    }

    private func loadScene(_ index: Int) {
        scene = index
        switch index {
        case 2:
            bridge.nativeChat.applyBackfill(Self.scene2Entries())
        case 3:
            bridge.nativeChat.applyBackfill(Self.scene3Entries())
        default:
            bridge.nativeChat.applyBackfill(Self.scene1Entries())
        }
    }

    private static func scene1Entries() -> [[String: Any]] {
        let t0: Double = Date().timeIntervalSince1970 * 1000
        var u1: [String: Any] = [
            "messageId": "u-1",
            "chatId": "chat-demo",
            "role": "user",
            "kind": "user",
            "content": "Can you inspect `NativeChatView.swift` and port the web chat tool strip and code blocks?",
            "timestamp": t0,
            "isOwnMessage": true,
        ]
        u1["replyQuote"] = [
            "correlationId": "a-0",
            "senderDisplayName": "Opus 4.6",
            "excerpt": "I'm ready to inspect the native chat implementation.",
        ] as [String: Any]
        u1["contextTags"] = [
            ["id": "ct-1", "tagName": "ide_opened_file", "label": "NativeChatView.swift", "content": "ripul-ios-sdk/Sources/RipulAgent/NativeChatView.swift"],
            ["id": "ct-2", "tagName": "ide_selection", "label": "Selection", "content": "public struct NativeChatView: View"],
        ] as [[String: Any]]

        let readCall1: [String: Any] = [
            "id": "call-read-1",
            "toolName": "Read",
            "label": "Read",
            "rendererName": "Read",
            "symbol": "doc.text",
            "status": "success",
            "timestamp": t0 + 1_000,
            "arguments": "{\"file_path\":\"Sources/RipulAgent/NativeChatView.swift\"}",
            "result": "import SwiftUI\npublic struct NativeChatView: View { ... }",
            "diagnostics": "{}",
        ]
        let t1: [String: Any] = [
            "messageId": "call-read-1",
            "chatId": "chat-demo",
            "role": "tool",
            "kind": "toolCall",
            "toolName": "Read",
            "toolStatus": "success",
            "timestamp": t0 + 1_000,
            "toolCall": readCall1,
        ]

        let readCall2: [String: Any] = [
            "id": "call-read-2",
            "toolName": "Read",
            "label": "Read",
            "rendererName": "Read",
            "symbol": "doc.text",
            "status": "success",
            "timestamp": t0 + 2_000,
            "arguments": "{\"file_path\":\"Sources/RipulAgent/NativeChatMessageStore.swift\"}",
            "result": "public final class NativeChatMessageStore: ObservableObject { ... }",
            "diagnostics": "{}",
        ]
        let t2: [String: Any] = [
            "messageId": "call-read-2",
            "chatId": "chat-demo",
            "role": "tool",
            "kind": "toolCall",
            "toolName": "Read",
            "toolStatus": "success",
            "timestamp": t0 + 2_000,
            "toolCall": readCall2,
        ]

        let bashCall: [String: Any] = [
            "id": "call-bash-1",
            "toolName": "Bash",
            "label": "Swift",
            "rendererName": "terminal",
            "symbol": "swift",
            "status": "success",
            "timestamp": t0 + 3_000,
            "arguments": "{\"command\":\"swift test --filter ThermalWorkTests\"}",
            "result": "Test Suite 'ThermalWorkTests' passed (6 tests in 2.88s)",
            "diagnostics": "{}",
            "commandPresentation": [
                "label": "Swift",
                "symbol": "swift",
                "command": "swift test --filter ThermalWorkTests",
                "summary": "Run ThermalWorkTests suite",
            ] as [String: Any],
        ]
        let t3: [String: Any] = [
            "messageId": "call-bash-1",
            "chatId": "chat-demo",
            "role": "tool",
            "kind": "toolCall",
            "toolName": "Bash",
            "toolStatus": "success",
            "timestamp": t0 + 3_000,
            "toolCall": bashCall,
        ]

        let agentTask: [String: Any] = [
            "id": "task-explore-1",
            "type": "local_agent",
            "title": "Compare V2MessageRow and NativeChatView",
            "status": "completed",
            "variant": "Explore",
            "model": "claude-sonnet-4-6",
            "harness": "claude-code",
            "totalCount": 5,
            "usage": "12.4k tokens · 5 tools · 8.2s",
            "entries": [
                ["kind": "tool", "label": "Read", "detail": "V2MessageRow.tsx"],
                ["kind": "tool", "label": "Read", "detail": "UnifiedAgentQuestionPanelProviderReact.tsx"],
            ] as [[String: Any]],
        ]
        let agentCall: [String: Any] = [
            "id": "call-agent-1",
            "toolName": "Agent",
            "label": "Compare V2MessageRow and NativeChatView",
            "rendererName": "Agent",
            "symbol": "sparkles",
            "status": "success",
            "timestamp": t0 + 4_000,
            "arguments": "{\"description\":\"Compare V2MessageRow and NativeChatView\"}",
            "result": "Completed comparison",
            "diagnostics": "{}",
            "task": agentTask,
        ]
        let t4: [String: Any] = [
            "messageId": "call-agent-1",
            "chatId": "chat-demo",
            "role": "tool",
            "kind": "toolCall",
            "toolName": "Agent",
            "toolStatus": "success",
            "timestamp": t0 + 4_000,
            "toolCall": agentCall,
        ]

        let assistantMd = """
        I've ported the web chat pipeline into **NativeChatView** with grouped tool strips, sub-agent task rows, and syntax-highlighted code blocks:

        ```swift
        public struct NativeChatView: View {
            @ObservedObject private var store: NativeChatMessageStore
            public var body: some View {
                ForEach(store.rows) { row in
                    rowView(for: row)
                }
            }
        }
        ```

        Tap any tool lozenge above to inspect its full execution details.
        """
        let a1: [String: Any] = [
            "messageId": "a-1",
            "chatId": "chat-demo",
            "role": "assistant",
            "kind": "assistant",
            "content": assistantMd,
            "timestamp": t0 + 5_000,
            "thinking": [
                "content": "Checking how V2MessageRow groups consecutive tool calls into NativeToolStrip lozenges and renders sub-agent task runs underneath.",
                "isStreaming": false,
            ] as [String: Any],
            "respondent": [
                "label": "Opus 4.6",
                "modelId": "claude-opus-4-6",
                "provider": "anthropic",
                "contextTokens": 48_200,
                "contextWindow": 200_000,
                "contextPercent": 24,
                "inputTokens": 42_100,
                "outputTokens": 1_850,
                "cacheReadTokens": 38_000,
                "toolCallCount": 4,
                "durationMs": 6_400,
                "costUsd": 0.0412,
                "isRewindable": true,
                "metaJson": "{\"model\":\"claude-opus-4-6\",\"tokens\":48200}",
            ] as [String: Any],
        ]
        // Thinking with nothing else to say: its own row, not part of a reply.
        let th1: [String: Any] = [
            "messageId": "th-1",
            "chatId": "chat-demo",
            "role": "assistant",
            "kind": "assistant",
            "content": "",
            "timestamp": t0 + 6_000,
            "thinking": [
                "content": "Deciding whether the strip should fold after twenty idle seconds.",
                "isStreaming": false,
            ] as [String: Any],
        ]

        return [u1, t1, t2, t3, t4, a1, th1]
    }

    private static func scene2Entries() -> [[String: Any]] {
        let t0: Double = 1_729_765_000_000
        let q1: [String: Any] = [
            "messageId": "q-1",
            "chatId": "chat-demo",
            "role": "assistant",
            "kind": "askUser",
            "content": "",
            "timestamp": t0,
            "respondent": [
                "label": "Opus 4.6",
                "modelId": "claude-opus-4-6",
                "provider": "anthropic",
                "contextPercent": 31,
            ] as [String: Any],
            "askUser": [
                "question": "Which rendering layout should we use for **multi-tool rows** on iPhone?",
                "options": [
                    ["label": "Badged Lozenge Strip (Recommended)", "value": "strip", "description": "Horizontal capsule strip with counts and 20s idle collapse"],
                    ["label": "Expanded Stack", "value": "stack", "description": "Show every tool call on its own line"],
                    ["label": "Compact Counter", "value": "counter", "description": "Single summary pill only"],
                ] as [[String: Any]],
                "multiSelect": false,
                "completed": false,
                "responseKey": "rk-layout",
            ] as [String: Any],
            "table": [
                "columns": [
                    ["key": "feature", "label": "Feature"],
                    ["key": "web", "label": "Web Chat"],
                    ["key": "native", "label": "Native Chat"],
                ] as [[String: Any]],
                "rows": [
                    ["feature": "Tool Strip", "web": "NativeToolStrip", "native": "NativeToolStripContent"],
                    ["feature": "Code Blocks", "web": "Prism / Shiki", "native": "HighlightSwift"],
                    ["feature": "Question Cards", "web": "UnifiedAgentQuestion", "native": "NativeAskUser"],
                ] as [[String: Any]],
            ] as [String: Any],
        ]
        return [q1]
    }

    private static func scene3Entries() -> [[String: Any]] {
        let t0: Double = 1_729_700_000_000
        let tLater: Double = t0 + (4 * 3_600_000) // +4 hours -> conversation gap

        let groupMsg: [String: Any] = [
            "messageId": "g-1",
            "chatId": "chat-demo",
            "role": "user",
            "kind": "user",
            "content": "I pushed the updated schema to the feature branch.",
            "timestamp": t0,
            "senderLabel": "Alex Rivera",
            "senderUserId": "user-alex",
            "isGroupChat": true,
            "isOwnMessage": false,
        ]

        let sysMsg: [String: Any] = [
            "messageId": "sys-1",
            "chatId": "chat-demo",
            "role": "system",
            "kind": "systemStatus",
            "content": "Alex Rivera joined the room",
            "timestamp": t0 + 1_000,
            "systemStatus": [
                "message": "Alex Rivera joined the room",
                "severity": "info",
                "isSharedEvent": true,
            ] as [String: Any],
        ]

        let ownVoiceMsg: [String: Any] = [
            "messageId": "u-voice",
            "chatId": "chat-demo",
            "role": "user",
            "kind": "user",
            "content": "Let's check the latest build status and artefact.",
            "timestamp": tLater,
            "senderLabel": "Peter Maude",
            "isGroupChat": true,
            "isOwnMessage": true,
            "isVoice": true,
        ]

        let noteMsg: [String: Any] = [
            "messageId": "note-1",
            "chatId": "chat-demo",
            "role": "user",
            "kind": "userNote",
            "content": "Remember to verify both light and dark appearance on iPhone 17 Pro Max simulator.",
            "timestamp": tLater + 1_000,
            "senderLabel": "Note",
            "isNote": true,
        ]

        let artMsg: [String: Any] = [
            "messageId": "art-1",
            "chatId": "chat-demo",
            "role": "user",
            "kind": "userNote",
            "content": "",
            "timestamp": tLater + 2_000,
            "artefactRef": [
                "artefactId": "native-chat-architecture",
                "revision": 3,
                "surface": "page",
            ] as [String: Any],
        ]

        let cliVcs: [String: Any] = [
            "messageId": "cli-vcs",
            "chatId": "chat-demo",
            "role": "system",
            "kind": "cliEvent",
            "content": "",
            "timestamp": tLater + 3_000,
            "cliEvent": [
                "kind": "vcs",
                "label": "git commit",
                "detail": "feat(ios): port web chat features to NativeChatView",
                "accent": "success",
                "chips": ["7fa91c2", "main"],
            ] as [String: Any],
        ]

        let cliCompact: [String: Any] = [
            "messageId": "cli-compact",
            "chatId": "chat-demo",
            "role": "system",
            "kind": "cliEvent",
            "content": "",
            "timestamp": tLater + 4_000,
            "cliEvent": [
                "kind": "compact_boundary",
                "label": "Context compacted",
                "detail": "auto · 168k tokens",
                "accent": "info",
                "chips": [],
            ] as [String: Any],
        ]

        let errMsg: [String: Any] = [
            "messageId": "err-1",
            "chatId": "chat-demo",
            "role": "system",
            "kind": "error",
            "content": "Rate limit exceeded on upstream provider",
            "timestamp": tLater + 5_000,
            "errorInfo": [
                "title": "Upstream Rate Limit (429)",
                "message": "Retrying automatically in 2 seconds using fallback endpoint.",
                "details": "HTTP 429 Too Many Requests\nRetry-After: 2",
            ] as [String: Any],
        ]

        return [groupMsg, sysMsg, ownVoiceMsg, noteMsg, artMsg, cliVcs, cliCompact, errMsg]
    }
}
