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
@MainActor
final class SimulatorPreviewState: ObservableObject {
    struct Selection: Equatable {
        let target: SimulatorTarget
        let machineId: String
        let chatId: String
    }
    struct Window: Identifiable {
        let id: Int
        let title: String
        let width: Double
        let height: Double
    }
    typealias Invoke = (String, String, [Any], String) async -> [String: Any]
    @Published private(set) var selection: Selection?
    let frame = HostScreenPreviewFrame()
    var image: UIImage? { frame.image }
    @Published private(set) var imageSize: CGSize = .zero
    private var lastJPEG: String?
    @Published private(set) var appearance: WindowPreviewAppearance?
    private var requestedAppearance: WindowPreviewAppearance?
    @Published private(set) var error: String?
    @Published private(set) var windows: [Window] = []
    @Published private(set) var window: Window?
    @Published var collapsed = false
    private var generation = UUID()
    private var inFlight = false
    @Published var allowed = true

    var aspectRatio: CGFloat {
        if imageSize.height > 0 { return imageSize.width / imageSize.height }
        return window.map { $0.width / $0.height } ?? 0.47
    }

    func open(_ target: SimulatorTarget, machineId: String, chatId: String) {
        generation = UUID()
        selection = Selection(target: target, machineId: machineId, chatId: chatId)
        resetFrame(); error = nil; windows = []; window = nil; collapsed = false
        appearance = nil; requestedAppearance = nil
    }
    func close() {
        generation = UUID()
        selection = nil; resetFrame(); error = nil; windows = []; window = nil
        appearance = nil; requestedAppearance = nil
    }
    func retry() {
        generation = UUID()
        resetFrame(); error = nil; windows = []; window = nil
        appearance = nil; requestedAppearance = nil
    }
    func choose(_ candidate: Window) {
        guard windows.contains(where: { $0.id == candidate.id }) else { return }
        window = candidate; windows = []
    }

    func refresh(invoke: Invoke) async {
        guard let selection, allowed, !collapsed, !inFlight, error == nil, windows.isEmpty else { return }
        inFlight = true
        defer { inFlight = false }
        let version = generation
        func current() -> Bool { version == generation && allowed && !collapsed && !Task.isCancelled }
        func result(_ response: [String: Any]) throws -> [String: Any] {
            guard response["success"] as? Bool == true, let value = response["result"] as? [String: Any] else {
                throw PreviewError.message(response["error"] as? String ?? "The Mac could not provide a preview. Check its connection and update Ripul on the Mac, then retry.")
            }
            return value
        }
        do {
            if window == nil {
                let response = await invoke(selection.machineId, "simulatorWindows", [selection.target.arguments], selection.chatId)
                guard current() else { return }
                let resolved = try result(response)
                requestedAppearance = WindowPreviewAppearance(resolved["appearance"])
                let candidates = (resolved["windows"] as? [[String: Any]] ?? []).compactMap { entry -> Window? in
                    guard let id = entry["id"] as? Int, let frame = entry["frame"] as? [String: Any],
                          let width = frame["width"] as? Double, let height = frame["height"] as? Double,
                          width > 0, height > 0 else { return nil }
                    return Window(id: id, title: entry["title"] as? String ?? "Simulator", width: width, height: height)
                }
                guard !candidates.isEmpty else {
                    throw PreviewError.message("Open this device in Simulator on the Mac, then retry.")
                }
                if candidates.count != 1 || resolved["needsChoice"] as? Bool == true { windows = candidates; return }
                window = candidates[0]
            }
            guard let window else { return }
            // Small, view-only snapshots reuse the Dock's authenticated remoting path.
            // One request at a time; the UI's timer waits a second AFTER it finishes.
            let response = await invoke(selection.machineId, "snapshot", [window.id, 320, 0.55], selection.chatId)
            guard current() else { return }
            let frame = try result(response)
            guard let base64 = frame["jpegB64"] as? String else {
                throw PreviewError.message("The Mac returned an unreadable preview. Retry to reconnect.")
            }
            // Crop metadata may change even while the pixels stay identical.
            let nextAppearance = (frame["cropPresetId"] as? String) == requestedAppearance?.cropPresetId ? requestedAppearance : nil
            if appearance != nextAppearance { appearance = nextAppearance }
            guard base64 != lastJPEG else { return }
            guard let data = Data(base64Encoded: base64), let next = UIImage(data: data) else {
                throw PreviewError.message("The Mac returned an unreadable preview. Retry to reconnect.")
            }
            lastJPEG = base64
            if imageSize != next.size { imageSize = next.size }
            self.frame.image = next
        } catch {
            if current() { self.error = error.localizedDescription }
        }
    }
    func setAllowed(_ value: Bool) { if allowed != value { allowed = value } }

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
        else { Color.black }
    }
}

@available(iOS 26.0, *)
struct SimulatorPreviewPanel: View {
    @ObservedObject var state: SimulatorPreviewState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            if state.selection != nil {
                let ratio = state.aspectRatio
                RipulFloatingPanel(storageKey: "ripul.simulatorPreview", defaultSize: CGSize(width: geometry.size.width / 3, height: geometry.size.width / 3 / ratio),
                    minSize: CGSize(width: 120, height: 120 / ratio), showsResizeGrip: !state.collapsed,
                    aspectRatio: ratio, contentInsets: UIEdgeInsets(top: 52, left: 0, bottom: 88, right: 0), avoidsKeyboard: true) { size in
                    let width = min(size.width, geometry.size.width - 24, max(120, (geometry.size.height - 156) * ratio))
                    let displaySize = CGSize(width: width, height: width / ratio)
                    let radius = state.collapsed ? 28 : state.appearance?.cornerRadius(for: displaySize) ?? 16
                    let outline = RoundedRectangle(cornerRadius: radius, style: .continuous)
                    ZStack(alignment: .topTrailing) {
                        SimulatorPreviewImage(frame: state.frame)
                        .allowsHitTesting(false)
                        .opacity(state.collapsed ? 0 : 1)
                        if state.collapsed {
                            control("pip", label: "Expand simulator preview", id: "expand", size: 56) { state.collapsed = false }
                                .contextMenu { Button("Close preview", role: .destructive) { state.close() } }
                        } else {
                            if let error = state.error {
                                VStack(spacing: 8) {
                                    Text(error).font(.caption).multilineTextAlignment(.center)
                                    Button("Retry") { state.retry() }.buttonStyle(.bordered)
                                }.padding(8).padding(.top, 44).frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else if !state.windows.isEmpty {
                                VStack(spacing: 8) {
                                    Text("Several simulators may match.").font(.caption).multilineTextAlignment(.center)
                                    Menu("Choose window") {
                                        ForEach(Array(state.windows.enumerated()), id: \.element.id) { index, window in
                                            Button("\(window.title) · Window \(index + 1)") { state.choose(window) }
                                        }
                                    }
                                }.padding(8).padding(.top, 44).frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else if state.imageSize == .zero {
                                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityLabel("Connecting to Simulator")
                            }
                            HStack(spacing: 0) {
                                control("xmark", label: "Close simulator preview", id: "close") { state.close() }
                                Spacer(minLength: 0)
                                control("minus", label: "Minimise simulator preview", id: "minimize") { state.collapsed = true }
                            }.padding(max(2, radius / 4))
                        }
                    }
                    .frame(width: state.collapsed ? 56 : width, height: state.collapsed ? 56 : width / ratio)
                    .clipShape(outline)
                    .glassEffect(.regular, in: outline)
                    .shadow(color: .black.opacity(0.2), radius: 10, y: 3)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("SimulatorPreview.surface")
                    .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.88), value: state.collapsed)
                }
            }
        }.ignoresSafeArea(.container)
    }

    private func control(_ symbol: String, label: String, id: String, size: CGFloat = 44, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size == 56 ? 22 : 14, weight: .semibold))
                .frame(width: size, height: size).contentShape(Rectangle())
                .glassEffect(.regular.interactive(), in: Circle())
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
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func loadView() { view = HostScreenPreviewPassthroughView() }
    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: SimulatorPreviewPanel(state: state))
        host.view.backgroundColor = .clear
        addChild(host); view.addSubview(host.view)
        host.view.frame = view.bounds; host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.didMove(toParent: self)
        state.$selection.combineLatest(state.$collapsed, state.$allowed)
            .sink { [weak self] selection, collapsed, allowed in
                self?.requested = selection != nil && !collapsed && allowed
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
        controller.state.setAllowed(!bridge.suppressNativeChatInput)
        if let selected = controller.state.selection, selected.chatId != bridge.currentSourceChatId { controller.state.close() }
    }
}

struct SimulatorPreviewPresenter: ViewModifier {
    let bridge: AgentBridge
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.overlay { SimulatorPreviewOverlay(bridge: bridge).ignoresSafeArea(.container) }
        } else { content }
    }
}
#else
import SwiftUI
struct SimulatorPreviewPresenter: ViewModifier {
    let bridge: AgentBridge
    func body(content: Content) -> some View { content }
}
#endif
