#if os(iOS)
import SwiftUI
import UIKit
import Combine

/// The host supplies a snapshot of its existing browser, without moving or
/// resizing the web view, changing its active tab, or creating another browser.
public struct BrowserPreviewSnapshot {
    public let image: UIImage?
    public let title: String
    public init(image: UIImage?, title: String) { self.image = image; self.title = title }
}

@MainActor
final class BrowserPreviewState: ObservableObject {
    typealias Capture = (Int?) async throws -> BrowserPreviewSnapshot
    var capture: Capture?
    @Published private(set) var chatId: String?
    @Published private(set) var title = "Browser"
    @Published private(set) var message: String?
    @Published private(set) var imageSize = CGSize.zero
    @Published var collapsed = false
    @Published private(set) var allowed = true
    let frame = HostScreenPreviewFrame()
    private(set) var tabId: Int?
    private var generation = UUID()
    private var inFlight = false
    private var lastPixels: Data?

    var aspectRatio: CGFloat { imageSize.height > 0 ? imageSize.width / imageSize.height : 390.0 / 844 }

    func open(chatId: String, tabId: Int? = nil, automatic: Bool = false) {
        guard capture != nil else { return }
        let sameChat = self.chatId == chatId
        if !sameChat || self.tabId != tabId {
            generation = UUID()
            self.tabId = tabId
            resetFrame()
            title = "Browser"; message = nil
        }
        if !sameChat { self.chatId = chatId }
        // A later tool call follows its tab without undoing the user's minimise.
        if !automatic || !sameChat { collapsed = false }
    }

    func close() {
        generation = UUID()
        chatId = nil; tabId = nil; message = nil
        resetFrame()
    }

    func setAllowed(_ value: Bool) {
        guard allowed != value else { return }
        generation = UUID()
        allowed = value
    }

    func refresh() async {
        guard chatId != nil, allowed, !collapsed, !inFlight, let capture else { return }
        inFlight = true
        defer { inFlight = false }
        let version = generation
        func current() -> Bool { generation == version && allowed && !collapsed && !Task.isCancelled }
        do {
            let snapshot = try await capture(tabId)
            guard current() else { return }
            if title != snapshot.title { title = snapshot.title }
            let nextMessage = snapshot.image == nil ? snapshot.title : nil
            if message != nextMessage { message = nextMessage }
            guard let image = snapshot.image else { resetFrame(); return }
            // Keep unchanged frames out of SwiftUI's observation graph.
            let pixels = image.pngData()
            guard pixels == nil || pixels != lastPixels else { return }
            lastPixels = pixels
            if imageSize != image.size { imageSize = image.size }
            frame.image = image
        } catch {
            guard current() else { return }
            let text = "Browser preview unavailable. \(error.localizedDescription)"
            if message != text { message = text }
        }
    }

    private func resetFrame() {
        lastPixels = nil
        if frame.image != nil { frame.image = nil }
        if imageSize != .zero { imageSize = .zero }
    }
}

private struct BrowserPreviewImage: View {
    @ObservedObject var frame: HostScreenPreviewFrame
    var body: some View {
        if let image = frame.image { Image(uiImage: image).resizable().scaledToFit() }
        else { Color.black }
    }
}

@available(iOS 26.0, *)
struct BrowserPreviewPanel: View {
    @ObservedObject var state: BrowserPreviewState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            if state.chatId != nil && state.allowed {
                let ratio = state.aspectRatio
                RipulFloatingPanel(storageKey: "ripul.browserPreview",
                    defaultSize: CGSize(width: geometry.size.width / 3, height: geometry.size.width / 3 / ratio),
                    minSize: CGSize(width: 120, height: 120 / ratio), showsResizeGrip: !state.collapsed,
                    aspectRatio: ratio, contentInsets: UIEdgeInsets(top: 52, left: 0, bottom: 88, right: 0), avoidsKeyboard: true) { size in
                    let width = min(size.width, geometry.size.width - 24, max(120, (geometry.size.height - 156) * ratio))
                    let outline = RoundedRectangle(cornerRadius: state.collapsed ? 28 : 16, style: .continuous)
                    ZStack(alignment: .topTrailing) {
                        BrowserPreviewImage(frame: state.frame).allowsHitTesting(false).opacity(state.collapsed ? 0 : 1)
                        if state.collapsed {
                            control("globe", label: "Expand browser preview", id: "expand", size: 56) { state.collapsed = false }
                                .contextMenu { Button("Close preview", role: .destructive) { state.close() } }
                        } else {
                            if let message = state.message {
                                Text(message).font(.caption).multilineTextAlignment(.center)
                                    .padding(8).padding(.top, 44).frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else if state.imageSize == .zero {
                                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .accessibilityLabel("Loading browser preview")
                            }
                            HStack(spacing: 0) {
                                control("xmark", label: "Close browser preview", id: "close") { state.close() }
                                Spacer(minLength: 0)
                                control("minus", label: "Minimise browser preview", id: "minimize") { state.collapsed = true }
                            }.padding(4)
                        }
                    }
                    .frame(width: state.collapsed ? 56 : width, height: state.collapsed ? 56 : width / ratio)
                    .clipShape(outline).glassEffect(.regular, in: outline)
                    .shadow(color: .black.opacity(0.2), radius: 10, y: 3)
                    .accessibilityElement(children: .contain).accessibilityLabel(state.title)
                    .accessibilityIdentifier("BrowserPreview.surface")
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
        }.buttonStyle(.plain).accessibilityLabel(label).uiKitIdentifier("BrowserPreview.\(id)")
    }
}

@available(iOS 26.0, *)
final class BrowserPreviewController: UIViewController {
    let state: BrowserPreviewState
    private var updates: Task<Void, Never>?
    private var observations = Set<AnyCancellable>()
    private var appeared = false
    private var requested = false
    init(state: BrowserPreviewState) { self.state = state; super.init(nibName: nil, bundle: nil) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func loadView() { view = HostScreenPreviewPassthroughView() }
    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: BrowserPreviewPanel(state: state))
        host.view.backgroundColor = .clear
        addChild(host); view.addSubview(host.view)
        host.view.frame = view.bounds; host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.didMove(toParent: self)
        state.$chatId.combineLatest(state.$collapsed, state.$allowed)
            .sink { [weak self] chat, collapsed, allowed in
                self?.requested = chat != nil && !collapsed && allowed
                self?.syncCapture()
            }.store(in: &observations)
        for name in [UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification] {
            NotificationCenter.default.publisher(for: name).sink { [weak self] notification in
                if notification.name == UIApplication.willResignActiveNotification { self?.stopCapture() }
                else { self?.syncCapture() }
            }.store(in: &observations)
        }
    }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); appeared = true; syncCapture() }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); appeared = false; stopCapture() }
    private func stopCapture() { updates?.cancel(); updates = nil }
    private func syncCapture() {
        guard appeared, requested, UIApplication.shared.applicationState == .active else { stopCapture(); return }
        guard updates == nil else { return }
        updates = Task { [weak self] in
            while !Task.isCancelled {
                if let self, self.visible, UIApplication.shared.applicationState == .active { await self.state.refresh() }
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
    deinit { updates?.cancel() }
}

@available(iOS 26.0, *)
private struct BrowserPreviewOverlay: UIViewControllerRepresentable {
    let bridge: AgentBridge
    func makeUIViewController(context: Context) -> BrowserPreviewController { BrowserPreviewController(state: bridge.browserPreview) }
    func updateUIViewController(_ controller: BrowserPreviewController, context: Context) {
        controller.state.setAllowed(!bridge.suppressNativeChatInput)
        if let chat = controller.state.chatId, chat != bridge.currentSourceChatId { controller.state.close() }
    }
}

struct BrowserPreviewPresenter: ViewModifier {
    let bridge: AgentBridge
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) { content.overlay { BrowserPreviewOverlay(bridge: bridge).ignoresSafeArea(.container) } }
        else { content }
    }
}
#else
import SwiftUI
struct BrowserPreviewPresenter: ViewModifier {
    let bridge: AgentBridge
    func body(content: Content) -> some View { content }
}
#endif
