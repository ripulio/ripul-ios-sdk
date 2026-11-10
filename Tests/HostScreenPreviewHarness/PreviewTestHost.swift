import SwiftUI
import UIKit
@testable import RipulAgent

@main
struct PreviewTestHost: App {
    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("--explorer-agent-touch-ui-tests") {
                ExplorerAgentTouchHarness().ignoresSafeArea()
            } else if ProcessInfo.processInfo.arguments.contains("--preview-dock-ui-tests") {
                PreviewDockHarness()
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
            } else if ProcessInfo.processInfo.arguments.contains("--home-scroll-ui-tests") {
                HomeScrollHarness().preferredColorScheme(.dark)
            } else if ProcessInfo.processInfo.arguments.contains("--code-width-ui-tests") {
                ToolCodeWidthHarnessSurface()
            } else if ProcessInfo.processInfo.arguments.contains("--tool-details-ui-tests") {
                ToolDetailsHarnessSurface()
                    .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("--light-appearance") ? .light : .dark)
            } else if ProcessInfo.processInfo.arguments.contains("--native-chat-inset-ui-tests") {
                NativeChatInsetHarnessSurface()
            } else if ProcessInfo.processInfo.arguments.contains("--native-chat-loading-ui-tests") {
                NativeChatLoadingHarnessSurface()
            } else if ProcessInfo.processInfo.arguments.contains("--native-chat-follow-ui-tests") {
                NativeChatFollowHarness().preferredColorScheme(.dark)
            } else if ProcessInfo.processInfo.arguments.contains("--native-chat-entry-ui-tests") {
                NativeChatEntryHarnessSurface()
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

/// AgentView placed as the agent screen places it (`--native-chat-inset-ui-tests`):
/// the chat column through the vertical safe area with the native chat on, and
/// a glass bar at the window's top clearance floating over it.
private struct NativeChatInsetHarnessSurface: View {
    @State private var bridge = AgentBridge()
    @State private var topChrome = WindowTopChromeClearance()

    var body: some View {
        ZStack(alignment: .top) {
            AgentView(configuration: AgentConfiguration(baseURL: URL(string: "http://127.0.0.1:9")!), bridge: bridge) { _ in EmptyView() }
                .ignoresSafeArea(.container, edges: .vertical)
            GlassTopBar(title: "Inset check") { Button("Nothing") {} }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("NativeChatInsetHarness.bar")
                .topChromeExclusion(topChrome)
                .padding(.top, topChrome.top)
                .ignoresSafeArea(edges: .top)
        }
        .background(WindowTopChrome { topChrome = $0 })
        .onAppear {
            bridge.nativeChatScrollerEnabled = true
            bridge.nativeChat.applyBackfill([
                ["messageId": "u-inset", "chatId": "chat-demo", "role": "user", "kind": "user",
                 "content": "The first message of the chat.", "timestamp": 1_729_900_000_000.0, "isOwnMessage": true],
                ["messageId": "a-inset", "chatId": "chat-demo", "role": "assistant", "kind": "assistant",
                 "content": "It starts below the bar.", "timestamp": 1_729_900_001_000.0],
            ])
        }
    }
}

/// Chats entered as the iPhone's agent screen enters them, with the native chat
/// on (`--native-chat-entry-ui-tests`). The chat column stays mounted off screen
/// beside a list. Opening a chat calls `focusSession`, lands the switch while the
/// column is still off screen with the place the page saved for that chat,
/// slides the column in, and rewrites and grows the tail as the Mac's catch-ups
/// do: once while it slides, once after the entry has settled. A cold chat (not
/// loaded on the device yet) is first sent empty, then its rows once loaded, as
/// the page's forwarder sends one. Opening the chat already shown appends rows
/// first, as an agent does while the list is up. A chat that lands with its slide
/// is sent its rows in the same update as the slide starts, as the app slides a
/// cold chat in once its history is applied. `NativeChatEntryHarness.report`
/// reads the chat's own scroll view: the chat, how far it is from its end, its
/// last row, and how far that row moved up or down on screen while the chat slid
/// in (`drift`, which should be 0: a slide moves it sideways only).
private struct NativeChatEntryHarnessSurface: View {
    private struct Chat {
        let id: String
        let prefix: String
        let count: Int
        var cold = false
        var landsWithSlide = false
        var cardsLandAbove = false
    }
    private static let chats = [
        Chat(id: "chat-a", prefix: "a", count: 160),
        Chat(id: "chat-b", prefix: "b", count: 120),
        Chat(id: "chat-c", prefix: "c", count: 24),
        Chat(id: "chat-d", prefix: "d", count: 140, cold: true),
        Chat(id: "chat-e", prefix: "e", count: 100, cold: true),
        Chat(id: "chat-f", prefix: "f", count: 72, cold: true, landsWithSlide: true),
        Chat(id: "chat-g", prefix: "g", count: 29, cardsLandAbove: true),
    ]

    /// When the tool-image cards of `chat-g` land after its slide starts, in seconds:
    /// the times Peter's Duo logged for a 29-row chat on 8 November 2026 (seven 430 pt
    /// steps, inside the 3 s entry hold), then three after the hold. The page publishes
    /// an older tool call's screenshots two at a time after a chat opens, each card a
    /// 420 pt upright screenshot at its known size (`toolImages.ts`), so each lands
    /// above the reader at full height.
    private static let cardTimes: [Double] = [2.242, 2.255, 2.339, 2.717, 2.746, 2.883, 2.989, 4.0, 4.6, 5.3]

    /// Where the chat's last row is drawn, frame by frame, while the chat slides in:
    /// the highest and lowest place on screen. On Peter's Duo a cold chat's rows,
    /// landing as the slide began, drifted about 70 pt down along the slide's own
    /// curve (8 November 2026).
    private final class SlideDriftTracker: NSObject {
        private var link: CADisplayLink?
        private var rowId = ""
        private weak var row: UIView?
        private var until: CFTimeInterval = 0
        private var highest: CGFloat?
        private var lowest: CGFloat?

        /// Points the row travelled up and down while on screen; -1 before it was seen.
        var drift: CGFloat {
            guard let highest, let lowest else { return -1 }
            return lowest - highest
        }

        private var from: CFTimeInterval = 0
        /// Frames sampled, and frames where the row moved more than half a point.
        private(set) var frames = 0
        private(set) var moves = 0
        private var last: CGFloat?

        /// Samples from `after` seconds on, until `seconds` after the call.
        func start(rowId: String, seconds: CFTimeInterval, after: CFTimeInterval = 0) {
            link?.invalidate()
            self.rowId = rowId
            row = nil
            highest = nil
            lowest = nil
            last = nil
            frames = 0
            moves = 0
            from = CACurrentMediaTime() + after
            until = CACurrentMediaTime() + seconds
            let link = CADisplayLink(target: self, selector: #selector(frame))
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        @objc private func frame() {
            let now = CACurrentMediaTime()
            guard now < until else {
                link?.invalidate()
                link = nil
                return
            }
            guard now >= from, let point = rowScreenPoint(), let width = row?.window?.bounds.width,
                  point.x < width - 1 else { return }
            frames += 1
            if let last, abs(point.y - last) > 0.5 { moves += 1 }
            last = point.y
            highest = min(highest ?? point.y, point.y)
            lowest = max(lowest ?? point.y, point.y)
        }

        /// The row's top, drawn: its marker's presentation through every ancestor's,
        /// so an animated scroll or slide counts as drawn.
        private func rowScreenPoint() -> CGPoint? {
            if row?.window == nil {
                row = nil
                func visit(_ view: UIView) {
                    guard row == nil else { return }
                    if String(describing: type(of: view)).contains("MarkerView"),
                       Mirror(reflecting: view).children.first(where: { $0.label == "rowId" })?.value as? String == rowId {
                        row = view
                        return
                    }
                    view.subviews.forEach(visit)
                }
                for scene in UIApplication.shared.connectedScenes {
                    (scene as? UIWindowScene)?.windows.forEach(visit)
                }
            }
            guard let row, let window = row.window else { return nil }
            let layer = row.layer.presentation() ?? row.layer
            let windowLayer = window.layer.presentation() ?? window.layer
            return layer.convert(CGPoint.zero, to: windowLayer)
        }
    }

    /// Frames while the test flings the chat: how many came more than one and a half
    /// frame intervals after the last (hitches), the time they lost past one interval,
    /// and the longest gap. Only frames while the chat moves under a finger or a coast
    /// count, as the app's own `[LISTPERF]` lines do: at rest the owned list mounts more
    /// rows on purpose, and nothing on screen moves for it. XCTest's own hitch metric has
    /// no numbers on a simulator.
    private final class HitchRecorder: NSObject {
        private var link: CADisplayLink?
        private var until: CFTimeInterval = 0
        private var last: CFTimeInterval = 0
        private(set) var frames = 0
        private(set) var hitches = 0
        private(set) var lostMs: Double = 0
        private(set) var worstMs: Double = 0
        var scroller: (() -> UIScrollView?)?

        func start(seconds: CFTimeInterval) {
            link?.invalidate()
            frames = 0; hitches = 0; lostMs = 0; worstMs = 0; last = 0
            until = CACurrentMediaTime() + seconds
            let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        @objc private func frame(_ link: CADisplayLink) {
            guard link.timestamp < until else {
                link.invalidate()
                self.link = nil
                return
            }
            defer { last = link.timestamp }
            guard last > 0 else { return }
            if let scroller, let sv = scroller(), !(sv.isTracking || sv.isDragging || sv.isDecelerating) { return }
            let interval = max(link.targetTimestamp - link.timestamp, 1 / 120)
            let gap = link.timestamp - last
            frames += 1
            worstMs = max(worstMs, gap * 1000)
            if gap > interval * 1.5 {
                hitches += 1
                lostMs += (gap - interval) * 1000
            }
        }
    }

    private final class ScrollerFinder {
        weak var scroller: UIScrollView?

        /// The chat's scroll view: the tallest one in the window that is not the
        /// page's, a text view's or a list's.
        func find() -> UIScrollView? {
            if let scroller, scroller.window != nil { return scroller }
            var found: UIScrollView?
            func visit(_ view: UIView) {
                if let candidate = view as? UIScrollView, !(candidate is UITextView), !(candidate is UICollectionView),
                   !String(describing: type(of: candidate)).hasPrefix("WK"),
                   candidate.contentSize.height > (found?.contentSize.height ?? 0) {
                    found = candidate
                }
                view.subviews.forEach(visit)
            }
            for scene in UIApplication.shared.connectedScenes {
                (scene as? UIWindowScene)?.windows.forEach(visit)
            }
            // Only kept once it holds a chat, so the empty one at launch is not.
            if let found, found.contentSize.height > 2000 { scroller = found }
            return found
        }
    }

    @State private var bridge = AgentBridge()
    @State private var showingList = true
    @State private var entry: Task<Void, Never>?
    @State private var appended = 0
    @State private var report = "chat=- fromEnd=- last=- drift=- catchUpDrift=- catchUpMoves=- catchUpFrames=-"
    @State private var finder = ScrollerFinder()
    @State private var slide = SlideDriftTracker()
    /// The last row from a second after the slide starts (it has landed) to 8 s:
    /// where the history landing above it moves it.
    @State private var catchUp = SlideDriftTracker()
    /// The composer's clearance as the app's tab shell drives it: its tab-bar row and
    /// its fold to the pill (`foldUndone`).
    @State private var clearance = RipulComposerChrome()
    @State private var hitches = HitchRecorder()
    private let ticks = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(Self.chats, id: \.id) { chat in
                        Button("Open \(chat.id)") { open(chat) }
                            .accessibilityIdentifier("NativeChatEntryHarness.open.\(chat.id)")
                    }
                }
                .padding(.top, 140)
                .padding(.horizontal, 24)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .allowsHitTesting(showingList)

                AgentView(configuration: AgentConfiguration(baseURL: URL(string: "http://127.0.0.1:9")!), bridge: bridge) { _ in EmptyView() }
                    .environment(\.composerClearanceChrome, clearance)
                    .modifier(BarSafeArea(active: Self.barSafeArea))
                    .frame(width: geo.size.width, height: geo.size.height)
                    .overlay(alignment: .topLeading) {
                        // Beside each other at the leading edge: on the open Duo the
                        // trailing edge is under the status bar's pill.
                        HStack(spacing: 24) {
                            Button("Back") {
                                withAnimation(.spring(response: 0.42, dampingFraction: 0.9)) { showingList = true }
                            }
                            .accessibilityIdentifier("NativeChatEntryHarness.back")
                            Button("Fold undone") { foldUndone() }
                                .accessibilityIdentifier("NativeChatEntryHarness.foldUndone")
                            Button("Nudge") {
                                // The content 120 pt down, as a short drag would move it.
                                if let sv = finder.find() {
                                    sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: sv.contentOffset.y - 120), animated: false)
                                }
                            }
                            .accessibilityIdentifier("NativeChatEntryHarness.nudge")
                            Button("Switch") {
                                // As Settings > Debug > Native Chat Performance > Owned chat list does.
                                let key = NativeChatPerformance.key(.ownedList)
                                let on = UserDefaults.standard.object(forKey: key) as? Bool ?? true
                                UserDefaults.standard.set(!on, forKey: key)
                                NativeChatPerformance.notifyChanged()
                            }
                            .accessibilityIdentifier("NativeChatEntryHarness.switchScroller")
                            Button("Hitches") {
                                hitches.scroller = { [finder] in finder.find() }
                                hitches.start(seconds: 60)
                            }
                                .accessibilityIdentifier("NativeChatEntryHarness.recordHitches")
                        }
                        .padding(.top, 64)
                        .padding(.leading, 20)
                    }
                    .clipped()
                    .offset(x: showingList ? geo.size.width : 0)
                    .allowsHitTesting(!showingList)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
        }
        .ignoresSafeArea()
        .overlay(alignment: .bottom) {
            Text(report)
                .font(.caption.monospaced())
                .padding(6)
                .background(.thinMaterial)
                .allowsHitTesting(false)
                .accessibilityIdentifier("NativeChatEntryHarness.report")
                .padding(.bottom, 24)
        }
        .onReceive(ticks) { _ in report = measure() }
        .onAppear { bridge.nativeChatScrollerEnabled = true }
    }

    private func open(_ chat: Chat) {
        entry?.cancel()
        entry = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 16_000_000)
            let switching = bridge.nativeChat.currentChatId != chat.id
            if !switching {
                // Rows the agent added while the list was up.
                appended += 2
                bridge.nativeChat.applyPatch([Self.message(chat, chat.count + 9 + appended - 1, grown: false),
                                              Self.message(chat, chat.count + 9 + appended, grown: false)],
                                             chatId: chat.id)
            }
            await bridge.focusSession(id: chat.id)
            guard !Task.isCancelled else { return }
            if switching {
                // The page's forwarder: the chat's rows (none yet for a cold
                // chat), and the place it saved for it.
                bridge.nativeChat.applyBackfill(chat.cold ? [] : Self.entries(chat, rewritten: false), chatId: chat.id,
                    scrollPosition: ["rowId": "\(chat.prefix)-\(chat.count / 3)", "offset": 80.0, "following": false])
            }
            let lastRow = switching ? "\(chat.prefix)-\(chat.count - 1)" : "\(chat.prefix)-\(chat.count + 9 + appended)"
            if chat.landsWithSlide && switching {
                // The app slides a cold chat in once its history is applied: the rows
                // and the slide in the same update. Nothing else lands while it slides.
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                slide.start(rowId: lastRow, seconds: 1.6)
                bridge.nativeChat.applyBackfill(Self.entries(chat, rewritten: false), chatId: chat.id)
                withAnimation(.spring(response: 0.62, dampingFraction: 0.92)) { showingList = false }
                return
            }
            slide.start(rowId: lastRow, seconds: 1.6)
            if chat.cardsLandAbove && switching {
                // Only history above the reader changes: no tail growth, so the last
                // row should not move at all once the slide has landed.
                catchUp.start(rowId: lastRow, seconds: 8, after: 1.0)
                withAnimation(.spring(response: 0.62, dampingFraction: 0.92)) { showingList = false }
                let start = Date()
                for (card, at) in Self.cardTimes.enumerated() {
                    let wait = at - Date().timeIntervalSince(start)
                    if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                    guard !Task.isCancelled else { return }
                    bridge.nativeChat.applyPatch([Self.imageCard(chat, card)], chatId: chat.id)
                }
                return
            }
            withAnimation(.spring(response: 0.62, dampingFraction: 0.92)) { showingList = false }
            guard switching else { return }
            if chat.cold {
                // Loaded: the rows follow as a second backfill of the same chat.
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                bridge.nativeChat.applyBackfill(Self.entries(chat, rewritten: false), chatId: chat.id)
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            bridge.nativeChat.applyBackfill(Self.entries(chat, rewritten: true), chatId: chat.id)
            try? await Task.sleep(nanoseconds: 3_600_000_000)
            guard !Task.isCancelled else { return }
            bridge.nativeChat.applyPatch((chat.count + 6..<chat.count + 10).map { Self.message(chat, $0, grown: false) },
                                         chatId: chat.id)
        }
    }

    /// `--bar-safe-area`: the chat column under a top bar that adds itself to the safe
    /// area, as `GlassTopBar` does in the app (`.safeAreaInset(edge: .top)`), the column
    /// running under it through the vertical safe area as `AgentView` does there.
    private static let barSafeArea = ProcessInfo.processInfo.arguments.contains("--bar-safe-area")

    private struct BarSafeArea: ViewModifier {
        let active: Bool
        func body(content: Content) -> some View {
            if active {
                content
                    .ignoresSafeArea(.container, edges: .vertical)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        Color.clear.frame(height: 100).allowsHitTesting(false)
                    }
            } else {
                content
            }
        }
    }

    /// The composer folding to its pill and unfolding 15 ms later, three times, over a
    /// chat resting at its end, as on Peter's iPhone 17 Pro Max (9 November 2026: the
    /// clearance went 195 → 106 → 195 pt). First the tab bar's row under the composer
    /// (49 pt, which the fold drops too), given a second to settle; then the last row
    /// is tracked, every frame, for three seconds.
    private func foldUndone() {
        entry?.cancel()
        entry = Task { @MainActor in
            clearance.contentBottomInset = 49
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let last = bridge.nativeChat.rows.last?.id else { return }
            catchUp.start(rowId: last, seconds: 3)
            for _ in 0..<3 {
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard !Task.isCancelled else { return }
                clearance.isCollapsed = true
                try? await Task.sleep(nanoseconds: 15_000_000)
                clearance.isCollapsed = false
            }
        }
    }

    private func measure() -> String {
        guard let sv = finder.find() else { return "chat=- fromEnd=- last=- drift=- catchUpDrift=- catchUpMoves=- catchUpFrames=-" }
        let end = max(-sv.adjustedContentInset.top, sv.contentSize.height + sv.adjustedContentInset.bottom - sv.bounds.height)
        let list = String(describing: type(of: sv)).contains("NativeChatListScroller") ? "owned" : "old"
        return String(format: "chat=%@ fromEnd=%.0f last=%@ drift=%.0f catchUpDrift=%.1f catchUpMoves=%d catchUpFrames=%d "
                      + "hitchFrames=%d hitches=%d hitchLostMs=%.0f hitchWorstMs=%.0f list=%@",
                      bridge.nativeChat.currentChatId ?? "-", end - sv.contentOffset.y,
                      bridge.nativeChat.rows.last?.id ?? "-", slide.drift, catchUp.drift, catchUp.moves, catchUp.frames,
                      hitches.frames, hitches.hitches, hitches.lostMs, hitches.worstMs, list)
    }

    /// A tool call's screenshot card, as the page forwards one: a media-only reply
    /// holding one upright Duo screenshot at its known size (1206×2622, drawn 420 pt
    /// high), no URL yet, timestamped among the chat's older messages so it lands
    /// well above the screen.
    private static func imageCard(_ chat: Chat, _ card: Int) -> [String: Any] {
        ["messageId": "\(chat.prefix)-image-\(card)", "chatId": chat.id, "role": "assistant", "kind": "assistant",
         "content": "", "timestamp": 1_729_900_000_000.0 + 6_000 + Double(card) * 10,
         "imageAttachments": [["id": "\(chat.prefix)-image-\(card)-0", "mediaType": "image/png",
                               "width": 1206, "height": 2622]]]
    }

    /// The chat as first sent, or after a catch-up: the last rows grown and six more.
    private static func entries(_ chat: Chat, rewritten: Bool) -> [[String: Any]] {
        (0..<chat.count + (rewritten ? 6 : 0)).map { message(chat, $0, grown: rewritten && $0 >= chat.count - 8) }
    }

    /// Users and replies alternate; rows past the chat's first count are replies.
    private static func message(_ chat: Chat, _ index: Int, grown: Bool) -> [String: Any] {
        let user = index < chat.count && index % 2 == 0
        let paragraphs = user ? 1 : 1 + (index * 7) % 5 + (grown ? 4 : 0)
        let text = (0..<paragraphs).map { paragraph in
            "Paragraph \(paragraph + 1) of message \(index) in \(chat.id). "
                + String(repeating: "A chat that is entered opens at its end. ", count: 2 + (index + paragraph) % 4)
        }.joined(separator: "\n\n")
        return ["messageId": "\(chat.prefix)-\(index)", "chatId": chat.id,
                "role": user ? "user" : "assistant", "kind": user ? "user" : "assistant",
                "content": text, "timestamp": 1_729_900_000_000.0 + Double(index) * 1000, "isOwnMessage": user]
    }
}

/// The first responder, by the public route: an action sent to no target goes to it.
private enum HarnessFirstResponder {
    static weak var found: UIResponder?

    static func describe() -> String {
        found = nil
        UIApplication.shared.sendAction(#selector(UIResponder.harnessCaptureFirstResponder(_:)), to: nil, from: nil, for: nil)
        guard let found else { return "-" }
        var text = String(describing: type(of: found))
        if let input = found as? UITextInput {
            if let range = input.selectedTextRange {
                text += range.isEmpty ? ",empty" : ",selected:\(input.offset(from: range.start, to: range.end))"
            } else {
                text += ",none"
            }
        } else {
            text += ",notInput"
        }
        return text
    }
}

extension UIResponder {
    @objc fileprivate func harnessCaptureFirstResponder(_ sender: Any?) {
        HarnessFirstResponder.found = self
    }
}

private struct NativeChatHarnessSurface: View {
    @State private var bridge = AgentBridge()
    @State private var responder = "-"
    @State private var scene: Int = {
        if ProcessInfo.processInfo.arguments.contains("--scene=2") { return 2 }
        if ProcessInfo.processInfo.arguments.contains("--scene=3") { return 3 }
        if ProcessInfo.processInfo.arguments.contains("--scene=4") { return 4 }
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

            if scene == 2 {
                // This harness has no web transport. Make delivery explicit so
                // a tap alone can never masquerade as an acknowledged answer.
                Button("Acknowledge answer") {
                    bridge.nativeChat.markQuestionAnswered(messageId: "q-1", answer: "strip", selectedValues: ["strip"])
                }
                .accessibilityIdentifier("NativeChatHarness.acknowledgeAnswer")
            }

            // Which message a reply (a swipe, or Reply) would quote, and what holds
            // the keyboard focus (a text selection makes its view first responder).
            HStack(spacing: 12) {
                Text("reply=\(bridge.replyTargets["chat-demo"]?.correlationId ?? "-")")
                    .accessibilityIdentifier("NativeChatHarness.replyTarget")
                Text("responder=\(responder)")
                    .accessibilityIdentifier("NativeChatHarness.responder")
            }
            .font(.system(size: 11, design: .monospaced))
            .onReceive(Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()) { _ in
                responder = HarnessFirstResponder.describe()
            }

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
        case 4:
            bridge.nativeChat.applyBackfill(Self.scene4Entries())
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

    /// Images to open in the viewer (`--scene=4` only): a tall one attached to
    /// the user's message and a wide one in the reply.
    private static func scene4Entries() -> [[String: Any]] {
        let t0: Double = 1_729_800_000_000
        let userMsg: [String: Any] = [
            "messageId": "u-img",
            "chatId": "chat-demo",
            "role": "user",
            "kind": "user",
            "content": "Here is the tall test card.",
            "timestamp": t0,
            "isOwnMessage": true,
            "imageAttachments": [
                ["id": "img-portrait", "mediaType": "image/png", "data": testCard(width: 900, height: 1800, hue: 0.58),
                 "name": "Portrait test card", "width": 900, "height": 1800],
            ] as [[String: Any]],
        ]
        let reply: [String: Any] = [
            "messageId": "a-img",
            "chatId": "chat-demo",
            "role": "assistant",
            "kind": "assistant",
            "content": "And the wide one.",
            "timestamp": t0 + 1_000,
            "imageAttachments": [
                ["id": "img-landscape", "mediaType": "image/png", "data": testCard(width: 1600, height: 1000, hue: 0.08),
                 "name": "Landscape test card", "width": 1600, "height": 1000],
            ] as [[String: Any]],
        ]
        return [userMsg, reply]
    }

    /// A PNG, as base64, one point per pixel: a 100 px grid, a ring in the
    /// middle and its corners labelled, so a picture shows which part is in view.
    private static func testCard(width: CGFloat, height: CGFloat, hue: CGFloat) -> String {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            let cg = context.cgContext
            UIColor(hue: hue, saturation: 0.55, brightness: 0.85, alpha: 1).setFill()
            cg.fill(CGRect(x: 0, y: 0, width: width, height: height))
            UIColor.white.withAlphaComponent(0.55).setStroke()
            cg.setLineWidth(3)
            for x in stride(from: CGFloat(0), through: width, by: 100) {
                cg.move(to: CGPoint(x: x, y: 0))
                cg.addLine(to: CGPoint(x: x, y: height))
            }
            for y in stride(from: CGFloat(0), through: height, by: 100) {
                cg.move(to: CGPoint(x: 0, y: y))
                cg.addLine(to: CGPoint(x: width, y: y))
            }
            cg.strokePath()
            UIColor.white.setStroke()
            cg.setLineWidth(14)
            cg.strokeEllipse(in: CGRect(x: width / 2 - 160, y: height / 2 - 160, width: 320, height: 320))
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 72), .foregroundColor: UIColor.white]
            for (label, origin) in [("TL", CGPoint(x: 30, y: 20)), ("TR", CGPoint(x: width - 130, y: 20)),
                                    ("BL", CGPoint(x: 30, y: height - 110)), ("BR", CGPoint(x: width - 130, y: height - 110))] {
                (label as NSString).draw(at: origin, withAttributes: attributes)
            }
        }
        return image.pngData()!.base64EncodedString()
    }
}


private struct NativeChatLoadingHarnessSurface: View {
    @State private var bridge = AgentBridge()
    var body: some View {
        VStack {
            HStack {
                Button("Progress") { set(["phase": "loading", "label": "Loading messages…", "detail": "50 of 100 messages", "fraction": 0.5]) }
                Button("Fail") { set(["phase": "failed", "label": "Couldn’t load this chat’s messages"]) }
                Button("Empty") { set(["phase": "ready"]) }
                Button("Messages") {
                    bridge.nativeChat.applyBackfill([["messageId": "one", "content": "Loaded message", "role": "user", "timestamp": 1]], chatId: "loading-test")
                }
            }.buttonStyle(.bordered)
                .padding(.top, 60)
            NativeChatView(store: bridge.nativeChat, bridge: bridge)
        }
        .onAppear { bridge.nativeChat.applyBackfill([], chatId: "loading-test", loadingState: .loading) }
    }
    private func set(_ wire: [String: Any]) {
        bridge.nativeChat.applyLoadingState(NativeChatLoadingState(wire: wire)!, chatId: "loading-test")
    }
}
