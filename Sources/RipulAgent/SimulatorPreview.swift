import Foundation

struct SimulatorTarget: Decodable, Equatable {
    let udid: String
    var developerDir: String? = nil
    var deviceSet: String? = nil

    var arguments: [String: Any] {
        var result: [String: Any] = ["udid": udid]
        if let developerDir { result["developerDir"] = developerDir }
        if let deviceSet { result["deviceSet"] = deviceSet }
        return result
    }
}

#if os(iOS)
import SwiftUI
import UIKit
import Combine

/// Frames and capture lifecycle belong to this leaf, never AgentBridge's published state.
///
/// The picture is read from the simulator itself on its Mac (`simulatorSnapshot`,
/// SimulatorScreens.swift there), not from a window: Xcode 27 shows simulators
/// in Device Hub, one device per window, and a simulator an agent booted has no
/// window at all. Control swaps the still for live video that takes the
/// person's fingers, made by the host app (`AgentBridge.simulatorLiveContent`).
///
/// Each chat keeps its own panel: leaving a chat puts it away as it was, and
/// coming back brings it back, closed included.
@MainActor
final class SimulatorPreviewState: ObservableObject {
    struct Selection: Equatable {
        let target: SimulatorTarget
        let machineId: String
        let chatId: String
    }
    /// A chat's panel while another chat is showing.
    private struct Kept {
        var selection: Selection
        var targets: [SimulatorTarget]
        var collapsed: Bool
    }
    typealias Invoke = (String, String, [Any], String) async -> [String: Any]
    /// Live video of a simulator that takes fingers: (UDID, Mac) to a view, from the host app.
    typealias LiveContent = (String, String) -> AnyView
    @Published private(set) var selection: Selection?
    /// The chat's simulators, oldest first; more than one offers a switch between them.
    @Published private(set) var targets: [SimulatorTarget] = []
    /// Simulators' names by UDID, as their Mac said them.
    @Published private(set) var names: [String: String] = [:]
    let frame = HostScreenPreviewFrame()
    var image: UIImage? { frame.image }
    @Published private(set) var imageSize: CGSize = .zero
    private var lastJPEG: String?
    @Published private(set) var appearance: WindowPreviewAppearance?
    @Published private(set) var error: String?
    /// The simulator's name, once its Mac has said it.
    @Published private(set) var title = "Simulator"
    /// The simulator has two screens of its own and can be opened and closed (the iPhone Duo).
    @Published private(set) var foldable = false
    /// What a control just said, shown for a few seconds.
    @Published private(set) var notice: String?
    /// Asks the Mac, for the controls; set by the panel's controller.
    var invoke: Invoke?
    private var noticeGeneration = UUID()
    @Published var collapsed = false
    /// The person is driving the simulator: live video that takes their fingers.
    @Published var live = false
    @Published var allowed = true
    var liveContent: LiveContent?
    /// The simulator this app runs in, when it does.
    var ownSimulatorUdid = ProcessInfo.processInfo.environment["SIMULATOR_UDID"]
    private var kept: [String: Kept] = [:]
    private(set) var visibleChatId: String?
    private var generation = UUID()
    private var inFlight = false
    /// After a failure the panel asks again every few seconds, as the browser
    /// panel keeps asking: a Mac restarting, or a simulator booting, heals by
    /// itself. Retry asks at once.
    private var failedAt: Date?
    private var namesAsked: Set<String> = []
    static let askAgainAfterFailure: TimeInterval = 5
    /// The picture's width in pixels: the panel's, set as it is drawn. A fixed
    /// 320 was blurry on a 2x or 3x screen beside the live video.
    var pictureWidth = 640
    static func pictureWidth(points: CGFloat, scale: CGFloat) -> Int {
        min(900, max(320, Int((points * max(scale, 1)).rounded())))
    }
    /// How long a fold takes to settle before Control comes back on the new screen.
    var foldSettles: Duration = .milliseconds(700)
    var clock: () -> Date = Date.init

    var aspectRatio: CGFloat { imageSize.height > 0 ? imageSize.width / imageSize.height : 0.47 }

    /// `automatic` is the agent reaching for the simulator (a borrowed one, a
    /// tool call that names it), not the person asking. As with the browser
    /// preview, a later automatic open in the same chat keeps the person's
    /// minimise, and one for the simulator already showing changes nothing. A
    /// simulator being driven is never taken away: a new one waits in the switch.
    func open(_ target: SimulatorTarget, machineId: String, chatId: String, automatic: Bool = false) {
        // An agent driving this very app in a simulator, as agents testing
        // Ripul do: its picture here would be this screen inside itself.
        if let own = ownSimulatorUdid, own.caseInsensitiveCompare(target.udid) == .orderedSame { return }
        if visibleChatId == nil { visibleChatId = chatId }
        guard chatId == visibleChatId else {
            // A chat out of sight: its panel opens there for when it is shown.
            var away = kept[chatId] ?? Kept(selection: Selection(target: target, machineId: machineId, chatId: chatId),
                                            targets: [], collapsed: false)
            if !away.targets.contains(target) { away.targets.append(target) }
            if !automatic { away.selection = Selection(target: target, machineId: machineId, chatId: chatId) }
            kept[chatId] = away
            return
        }
        let next = Selection(target: target, machineId: machineId, chatId: chatId)
        let hadPanel = selection != nil
        if !targets.contains(target) { targets.append(target) }
        if selection != next {
            if automatic, live, selection != nil { return }
            select(next)
        } else if !automatic, error != nil {
            retry()
        }
        if !automatic || !hadPanel { collapsed = false }
    }

    /// Shows another of the chat's simulators.
    func switchTo(_ target: SimulatorTarget) {
        guard let selection, targets.contains(target), selection.target != target else { return }
        select(Selection(target: target, machineId: selection.machineId, chatId: selection.chatId))
        collapsed = false
    }

    func close() {
        if let chat = visibleChatId { kept[chat] = nil }
        generation = UUID()
        selection = nil; targets = []; live = false
        resetFrame(); error = nil; appearance = nil; title = "Simulator"; foldable = false
    }

    func retry() {
        generation = UUID()
        resetFrame(); error = nil
    }

    /// The chat on screen changed: put this chat's panel away and bring back that one's.
    func show(chatId: String?) {
        guard chatId != visibleChatId else { return }
        if let leaving = visibleChatId, let selection {
            kept[leaving] = Kept(selection: selection, targets: targets, collapsed: collapsed)
        }
        visibleChatId = chatId
        generation = UUID()
        resetFrame(); error = nil; appearance = nil; live = false; foldable = false
        if let chatId, let back = kept.removeValue(forKey: chatId) {
            selection = back.selection; targets = back.targets; collapsed = back.collapsed
            title = names[back.selection.target.udid] ?? "Simulator"
        } else {
            selection = nil; targets = []; collapsed = false; title = "Simulator"
        }
    }

    /// The simulator's hardware controls, as on its Mac (`screenWindows.simulatorControl`):
    /// `home`, `appSwitcher`, `rotateLeft`, `rotateRight`, and for a foldable
    /// `open`, `halfOpen` and `close`.
    struct Control: Identifiable {
        let action: String, title: String, symbol: String
        var id: String { action }
    }
    static let controls = [
        Control(action: "home", title: "Home", symbol: "house"),
        Control(action: "appSwitcher", title: "App Switcher", symbol: "square.stack"),
        Control(action: "rotateLeft", title: "Rotate Left", symbol: "rotate.left"),
        Control(action: "rotateRight", title: "Rotate Right", symbol: "rotate.right"),
    ]
    static let foldControls = [
        Control(action: "open", title: "Open", symbol: "book"),
        Control(action: "halfOpen", title: "Half Open", symbol: "book.closed"),
        Control(action: "close", title: "Close", symbol: "rectangle.portrait"),
    ]

    func control(_ action: String) async {
        guard let selection, let invoke else { return }
        let response = await invoke(selection.machineId, "simulatorControl", [selection.target.arguments, ["action": action]], selection.chatId)
        guard response["success"] as? Bool == true else {
            let said = response["error"] as? String
            show(notice: said.map { $0.contains("Unknown method") || $0.contains("NOT_ALLOWED") || $0.contains("not available through Direct")
                ? "Update Ripul on the Mac to use simulator controls." : $0 } ?? "The Mac didn't answer.")
            return
        }
        // Control stays on. A fold moves the picture to the other screen, so the
        // live video starts again on it once the fold has settled; a turn
        // changes nothing the video holds. The pictures take a fresh one.
        guard action.hasPrefix("rotate") || Self.foldControls.contains(where: { $0.action == action }) else { return }
        guard live, Self.foldControls.contains(where: { $0.action == action }) else {
            if !live { retry() }
            return
        }
        live = false
        retry()
        let folded = generation
        try? await Task.sleep(for: foldSettles)
        // Not if the person moved on meanwhile: another simulator, another chat, or closed.
        guard generation == folded, self.selection == selection, allowed else { return }
        live = true
    }

    private func show(notice text: String) {
        let generation = UUID()
        noticeGeneration = generation
        notice = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if noticeGeneration == generation { notice = nil }
        }
    }

    private func select(_ next: Selection) {
        generation = UUID()
        selection = next
        live = false
        resetFrame(); error = nil; appearance = nil; foldable = false
        title = names[next.target.udid] ?? "Simulator"
    }

    func refresh(invoke: Invoke) async {
        guard let selection, allowed, !collapsed, !live, !inFlight else { return }
        if error != nil, let failedAt, clock().timeIntervalSince(failedAt) < Self.askAgainAfterFailure { return }
        inFlight = true
        defer { inFlight = false }
        let version = generation
        func current() -> Bool { version == generation && allowed && !collapsed && !live && !Task.isCancelled }
        do {
            // Small, view-only pictures over the Dock's authenticated remoting path.
            // One request at a time; the UI's timer waits a second AFTER it finishes.
            let response = await invoke(selection.machineId, "simulatorSnapshot", [selection.target.arguments, pictureWidth, 0.6], selection.chatId)
            guard current() else { return }
            guard response["success"] as? Bool == true, let frame = response["result"] as? [String: Any] else {
                throw PreviewError.message(Self.explain(response["error"] as? String))
            }
            if error != nil { error = nil }
            let canFold = frame["foldable"] as? Bool ?? false
            if foldable != canFold { foldable = canFold }
            if let name = frame["name"] as? String, !name.isEmpty {
                if names[selection.target.udid] != name { names[selection.target.udid] = name }
                if title != name { title = name }
            }
            let nextAppearance = WindowPreviewAppearance(frame["appearance"])
            if appearance != nextAppearance { appearance = nextAppearance }
            guard let base64 = frame["jpegB64"] as? String else {
                throw PreviewError.message("The Mac returned an unreadable preview. Retry to reconnect.")
            }
            if base64 != lastJPEG {
                guard let data = Data(base64Encoded: base64), let next = UIImage(data: data) else {
                    throw PreviewError.message("The Mac returned an unreadable preview. Retry to reconnect.")
                }
                lastJPEG = base64
                if imageSize != next.size { imageSize = next.size }
                self.frame.image = next
            }
            await nameAnotherSimulator(showing: selection, invoke: invoke, current: current)
        } catch {
            guard current() else { return }
            failedAt = clock()
            if self.error != error.localizedDescription { self.error = error.localizedDescription }
        }
    }
    /// The switch lists the chat's simulators by name, and one never shown has
    /// none until its Mac says it: each refresh asks for one of them, a
    /// thumbnail for its name, until every one has been asked once.
    private func nameAnotherSimulator(showing: Selection, invoke: Invoke, current: () -> Bool) async {
        guard let unnamed = targets.first(where: { $0 != showing.target && names[$0.udid] == nil && !namesAsked.contains($0.udid) })
        else { return }
        namesAsked.insert(unnamed.udid)
        let response = await invoke(showing.machineId, "simulatorSnapshot", [unnamed.arguments, 64, 0.3], showing.chatId)
        guard current(), response["success"] as? Bool == true, let frame = response["result"] as? [String: Any],
              let name = frame["name"] as? String, !name.isEmpty, names[unnamed.udid] == nil else { return }
        names[unnamed.udid] = name
    }

    func setAllowed(_ value: Bool) {
        guard allowed != value else { return }
        allowed = value
        // Hidden under a sheet or the keyboard's own screen: the live video stops too.
        if !value { live = false }
    }

    /// What a failed request means to the person looking at it.
    static func explain(_ error: String?) -> String {
        guard let error, !error.isEmpty else {
            return "The Mac could not provide a preview. Check its connection, then retry."
        }
        // A Mac from before simulatorSnapshot: its host doesn't know the method,
        // its web view doesn't allow it, or its Direct policy doesn't list it.
        if error.contains("Unknown method") || error.contains("NOT_ALLOWED") || error.contains("not available through Direct") {
            return "Update Ripul on the Mac to see its simulators here."
        }
        return error
    }

    private func resetFrame() {
        lastJPEG = nil
        if frame.image != nil { frame.image = nil }
        if imageSize != .zero { imageSize = .zero }
    }

    private enum PreviewError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    }
}

private struct SimulatorPreviewImage: View {
    @ObservedObject var frame: HostScreenPreviewFrame
    var body: some View {
        if let image = frame.image { Image(uiImage: image).resizable().scaledToFit() }
        else { Color.ripul(system: .black) }
    }
}

@available(iOS 26.0, *)
struct SimulatorPreviewPanel: View {
    @ObservedObject var state: SimulatorPreviewState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    private var spring: Animation? { reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.88) }

    var body: some View {
        GeometryReader { geometry in
            if let selection = state.selection {
                let ratio = state.aspectRatio
                RipulFloatingPanel(storageKey: "ripul.simulatorPreview", defaultSize: CGSize(width: min(geometry.size.width / 3, 300), height: min(geometry.size.width / 3, 300) / ratio),
                    minSize: CGSize(width: 120, height: 120 / ratio), showsResizeGrip: !state.collapsed,
                    aspectRatio: ratio, contentInsets: UIEdgeInsets(top: 52, left: 0, bottom: 88, right: 0), avoidsKeyboard: true,
                    movesFromTopStrip: state.live ? 52 : nil, keepsTrailingEdge: true) { size in
                    let width = min(size.width, geometry.size.width - 24, max(120, (geometry.size.height - 156) * ratio))
                    let displaySize = CGSize(width: width, height: width / ratio)
                    let radius = state.appearance?.cornerRadius(for: displaySize) ?? 16
                    // Three 44-point buttons and their margin are wider than a panel
                    // a third of a 402-point phone: they shrink to fit instead.
                    let inset = max(2, radius / 4)
                    let side = min(44, ((width - inset * 2) / (state.liveContent == nil ? 3 : 4)).rounded(.down))
                    let outline = RoundedRectangle(cornerRadius: radius, style: .continuous)
                    // Minimising shrinks the panel into its minimise button at the
                    // top-right, and expanding grows it back out (`keepsTrailingEdge`).
                    FloatingPanelCollapse(collapsed: state.collapsed, expanded: displaySize, animation: spring) {
                        ZStack(alignment: .topTrailing) {
                            if state.live, let liveContent = state.liveContent {
                                // The person's fingers go to the simulator; the panel moves from its top strip.
                                liveContent(selection.target.udid, selection.machineId)
                                    .accessibilityIdentifier("SimulatorPreview.live")
                            } else {
                                SimulatorPreviewImage(frame: state.frame).allowsHitTesting(false)
                            }
                            if !state.live, let error = state.error {
                                VStack(spacing: 8) {
                                    Text(error).ripulText().font(.ripul(.caption)).multilineTextAlignment(.center)
                                    Button("Retry") { state.retry() }.buttonStyle(.bordered)
                                }.padding(8).padding(.top, 44).frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else if !state.live, state.imageSize == .zero {
                                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityLabel("Connecting to Simulator")
                            }
                            if let notice = state.notice {
                                Text(notice).ripulText().font(.ripul(.caption)).multilineTextAlignment(.center) // theme-mapping: a control's notice, set as the panel's error text
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .glassEffect(.regular, in: Capsule())
                                    .padding(.horizontal, 8).padding(.bottom, 44)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                                    .allowsHitTesting(false)
                                    .accessibilityIdentifier("SimulatorPreview.notice")
                            }
                            // The chat's other simulators, under the picture: a fourth
                            // button doesn't fit the top of a panel a third of the screen
                            // wide. Hidden while driving, which switching would stop.
                            if !state.live, state.targets.count > 1 {
                                switcher(showing: selection.target)
                                    .padding(.horizontal, 8).padding(.bottom, 8)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            }
                            HStack(spacing: 0) {
                                control("xmark", label: "Close simulator preview", id: "close", size: side) { state.close() }
                                controlsMenu(size: side)
                                Spacer(minLength: 0)
                                if state.liveContent != nil {
                                    if state.live {
                                        control("hand.raised.slash", label: "Stop controlling the simulator", id: "watch", size: side) { state.live = false }
                                    } else {
                                        control("hand.point.up.left", label: "Control the simulator", id: "control", size: side) { state.live = true }
                                    }
                                }
                                control("minus", label: "Minimise simulator preview", id: "minimize", size: side) {
                                    state.live = false
                                    state.collapsed = true
                                }
                            }.padding(inset)
                        }
                        .frame(width: width, height: width / ratio)
                        .clipShape(outline)
                        .glassEffect(.regular, in: outline)
                        .shadow(color: Color.ripul(system: .black).opacity(0.2), radius: 10, y: 3) // theme-mapping: the panel's shadow unchanged, now on the panel and on its minimised button apart
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(state.title)
                        .accessibilityIdentifier("SimulatorPreview.surface")
                        .onChange(of: width, initial: true) { _, points in
                            state.pictureWidth = SimulatorPreviewState.pictureWidth(points: points, scale: displayScale)
                        }
                    } minimised: {
                        control("pip", label: "Expand simulator preview", id: "expand", size: 56) { state.collapsed = false }
                            .contextMenu { MenuIcons { Button("Close preview", role: .destructive) { state.close() } }}
                            .clipShape(Circle())
                            .glassEffect(.regular, in: Circle())
                            .shadow(color: Color.ripul(system: .black).opacity(0.2), radius: 10, y: 3) // theme-mapping: the panel's shadow unchanged, now on the panel and on its minimised button apart
                    }
                }
            }
        }.ignoresSafeArea(.container)
    }

    /// The simulator's hardware, as its Mac offers it: Home, the app switcher,
    /// rotating, and opening or closing a foldable.
    private func controlsMenu(size: CGFloat) -> some View {
        let drawn = min(size, 36)
        return Menu {
            MenuIcons {
                ForEach(SimulatorPreviewState.controls) { item in
                    Button { Task { await state.control(item.action) } } label: { Label(item.title, systemImage: item.symbol) }
                }
                if state.foldable {
                    Divider()
                    ForEach(SimulatorPreviewState.foldControls) { item in
                        Button { Task { await state.control(item.action) } } label: { Label(item.title, systemImage: item.symbol) }
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis").font(.ripulIcon(size: 13, weight: .semibold)) // theme-mapping: drawn as the panel's other buttons
                .frame(width: drawn, height: drawn)
                .glassEffect(.regular.interactive(), in: Circle())
                .frame(width: size, height: size).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Simulator controls")
        .uiKitIdentifier("SimulatorPreview.controls")
    }

    /// The chat's other simulators, by the names their Mac gave them.
    private func switcher(showing: SimulatorTarget) -> some View {
        Menu {
            MenuIcons {
                ForEach(state.targets, id: \.udid) { target in
                    Button {
                        state.switchTo(target)
                    } label: {
                        if target == showing {
                            Label(name(of: target), systemImage: "checkmark")
                        } else {
                            Text(name(of: target))
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(name(of: showing)).ripulText().font(.ripul(.caption)).lineLimit(1) // theme-mapping: a new label, set as the panel's error text
                Image(systemName: "chevron.up.chevron.down").font(.ripulIcon(.caption2)) // theme-mapping: a new label's chevron, a step under its text
            }
            .padding(.horizontal, 10).frame(minHeight: 28).contentShape(Capsule())
            .glassEffect(.regular.interactive(), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Switch simulator")
        .accessibilityValue(name(of: showing))
        .uiKitIdentifier("SimulatorPreview.switch")
    }

    private func name(of target: SimulatorTarget) -> String {
        state.names[target.udid] ?? "Simulator \(target.udid.prefix(8))"
    }

    /// A round button drawn at most 36 points across over a touch area of `size`.
    private func control(_ symbol: String, label: String, id: String, size: CGFloat = 44, action: @escaping () -> Void) -> some View {
        let drawn = size == 56 ? 56 : min(size, 36)
        return Button(action: action) {
            Image(systemName: symbol).font(.ripulIcon(size: size == 56 ? 22 : 13, weight: .semibold)) // theme-mapping: the panel's buttons drawn a touch smaller (Peter, 14 Oct 2026)
                .frame(width: drawn, height: drawn)
                .glassEffect(.regular.interactive(), in: Circle())
                .frame(width: size, height: size).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(label).uiKitIdentifier("SimulatorPreview.\(id)")
    }
}

@available(iOS 26.0, *)
final class SimulatorPreviewController: UIViewController {
    let state: SimulatorPreviewState
    let invoke: SimulatorPreviewState.Invoke
    private var updates: Task<Void, Never>?
    private var observations = Set<AnyCancellable>()
    private var appeared = false
    private var requested = false
    init(state: SimulatorPreviewState, invoke: @escaping SimulatorPreviewState.Invoke) {
        self.state = state; self.invoke = invoke
        state.invoke = invoke
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func loadView() { view = HostScreenPreviewPassthroughView() }
    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: SimulatorPreviewPanel(state: state).ripulThemeRoot())
        host.view.backgroundColor = .clear
        addChild(host); view.addSubview(host.view)
        host.view.frame = view.bounds; host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.didMove(toParent: self)
        state.$selection.combineLatest(state.$collapsed, state.$allowed, state.$live)
            .sink { [weak self] selection, collapsed, allowed, live in
                self?.requested = selection != nil && !collapsed && allowed && !live
                self?.syncCapture()
            }.store(in: &observations)
        for name in [UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification] {
            NotificationCenter.default.publisher(for: name).sink { [weak self] notification in
                if notification.name == UIApplication.willResignActiveNotification { self?.stopCapture() }
                else { self?.syncCapture() }
            }.store(in: &observations)
        }
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        appeared = true
        syncCapture()
    }
    private func stopCapture() { updates?.cancel(); updates = nil }
    private func syncCapture() {
        guard appeared, requested, UIApplication.shared.applicationState == .active else { stopCapture(); return }
        guard updates == nil else { return }
        updates = Task { [weak self] in
            while !Task.isCancelled {
                if let self, self.visible, UIApplication.shared.applicationState == .active {
                    await self.state.refresh(invoke: self.invoke)
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
    private var visible: Bool {
        guard view.window != nil else { return false }
        var ancestor: UIView? = view
        while let next = ancestor {
            if next.isHidden || next.alpha < 0.01 { return false }
            ancestor = next.superview
        }
        return true
    }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); appeared = false; stopCapture() }
    deinit { updates?.cancel() }
}

@available(iOS 26.0, *)
private struct SimulatorPreviewOverlay: UIViewControllerRepresentable {
    let bridge: AgentBridge
    func makeUIViewController(context: Context) -> SimulatorPreviewController {
        SimulatorPreviewController(state: bridge.simulatorPreview) { [weak bridge] machineId, method, args, chatId in
            guard let bridge else { return ["success": false] }
            return await bridge.mirrorInvoke(machineId: machineId, capability: "screenWindows", method: method, args: args, chatId: chatId)
        }
    }
    func updateUIViewController(_ controller: SimulatorPreviewController, context: Context) {
        controller.state.liveContent = bridge.simulatorLiveContent
        controller.state.setAllowed(!bridge.suppressNativeChatInput)
        // Another chat: this one's panel is put away, and that one's comes back.
        controller.state.show(chatId: bridge.currentSourceChatId)
    }
}

struct SimulatorPreviewPresenter: ViewModifier {
    let bridge: AgentBridge
    var shown = true
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.overlay { if shown { SimulatorPreviewOverlay(bridge: bridge).ignoresSafeArea(.container) } }
        } else { content }
    }
}
#else
import SwiftUI
struct SimulatorPreviewPresenter: ViewModifier {
    let bridge: AgentBridge
    var shown = true
    func body(content: Content) -> some View { content }
}
#endif

private struct PreviewPanelsAtWindowKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// The host app shows the chat's preview panels over its whole window.
    var ripulPreviewPanelsAtWindow: Bool {
        get { self[PreviewPanelsAtWindowKey.self] }
        set { self[PreviewPanelsAtWindowKey.self] = newValue }
    }
}

public extension View {
    /// The chat's picture-in-picture panels (the simulator's and the
    /// browser's) over this whole view, the window, rather than over the
    /// chat's own area, so they can be moved anywhere in it: on a Mac, or on
    /// a wide phone, the chat is one column of several. The chat inside then
    /// leaves them out. `shown` is whether a chat is on screen; the panels
    /// belong to it, and go while another screen is.
    func ripulPreviewPanels(bridge: AgentBridge, shown: Bool) -> some View {
        environment(\.ripulPreviewPanelsAtWindow, true)
            .modifier(SimulatorPreviewPresenter(bridge: bridge, shown: shown))
            .modifier(BrowserPreviewPresenter(bridge: bridge, shown: shown))
    }
}
