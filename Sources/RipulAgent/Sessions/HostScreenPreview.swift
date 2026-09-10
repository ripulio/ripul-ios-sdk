#if os(iOS)
import SwiftUI
import UIKit

/// Image updates have their own observation boundary: a capture must never
/// invalidate the agent screen, composer, or the floating panel's geometry.
@MainActor
final class HostScreenPreviewFrame: ObservableObject {
    @Published var image: UIImage?
}

@MainActor
final class HostScreenPreviewState: NSObject, ObservableObject {
    static let storageKey = "ripul.devAssistantOverlay.hostPreview"
    let store: UserDefaults
    let frame = HostScreenPreviewFrame()
    @Published private(set) var hostSize: CGSize = .zero
    @Published private(set) var hostSafeArea: UIEdgeInsets = .zero
    @Published var isEnabled: Bool {
        didSet {
            store.set(isEnabled, forKey: Self.storageKey + ".enabled")
            reconcileCapture()
        }
    }
    @Published var isCollapsed: Bool {
        didSet {
            store.set(isCollapsed, forKey: Self.storageKey + ".collapsed")
            reconcileCapture()
        }
    }
    private(set) var isAgentExpanded = false
    private var isApplicationActive: Bool
    private let hostWindow: () -> UIWindow?
    private var timer: Timer?
    var isCapturing: Bool { timer != nil }

    init(store: UserDefaults, hostWindow: @escaping () -> UIWindow?) {
        self.store = store
        self.hostWindow = hostWindow
        isEnabled = store.object(forKey: Self.storageKey + ".enabled") as? Bool ?? true
        isCollapsed = store.bool(forKey: Self.storageKey + ".collapsed")
        isApplicationActive = UIApplication.shared.applicationState == .active
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(didBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(willResignActive),
            name: UIApplication.willResignActiveNotification, object: nil)
    }

    deinit { timer?.invalidate() }

    func setAgentExpanded(_ expanded: Bool) {
        isAgentExpanded = expanded
        reconcileCapture()
    }

    func setHostLayout(size: CGSize, safeArea: UIEdgeInsets) {
        if hostSize != size { hostSize = size }
        if hostSafeArea != safeArea { hostSafeArea = safeArea }
    }

    @objc func didBecomeActive() {
        isApplicationActive = true
        reconcileCapture()
    }

    @objc func willResignActive() {
        isApplicationActive = false
        reconcileCapture()
    }

    private var shouldCapture: Bool {
        isEnabled && !isCollapsed && isAgentExpanded && isApplicationActive
    }

    private func reconcileCapture() {
        guard shouldCapture else {
            timer?.invalidate()
            timer = nil
            // Retain the last frame while shrinking into the FAB. Fully hidden
            // or inactive previews release it, and re-opening captures afresh.
            if !isEnabled || !isAgentExpanded || !isApplicationActive { frame.image = nil }
            return
        }
        guard timer == nil else { return }
        captureAndSchedule()
    }

    private func captureAndSchedule() {
        guard shouldCapture else { return }
        let started = CACurrentMediaTime()
        frame.image = hostWindow().flatMap { Self.capture($0) }
        // One small local snapshot per second. Expensive host screens back off
        // to keep capture below roughly 5% of main-thread time. Default run-loop
        // mode also lets scrolling and dragging take priority over refreshes.
        let delay = max(1, (CACurrentMediaTime() - started) * 20)
        let next = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.timer = nil
                self?.captureAndSchedule()
            }
        }
        next.tolerance = delay * 0.2
        timer = next
        RunLoop.main.add(next, forMode: .default)
    }

    /// Draw only the actual host window, even when SDK chrome is key and fully
    /// covers it. No view reparenting, input forwarding, network, or attachment.
    static func capture(_ window: UIWindow, maxDimension: CGFloat = 1000) -> UIImage? {
        guard !RipulChrome.isRipulWindow(window), !window.isHidden,
              window.bounds.width > 0, window.bounds.height > 0 else { return nil }
        let scale = min(window.screen.scale, maxDimension / max(window.bounds.width, window.bounds.height))
        let size = CGSize(width: window.bounds.width * scale, height: window.bounds.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        var rendered = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            rendered = window.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: false)
        }
        return rendered ? image : nil
    }
}

@available(iOS 26.0, *)
struct HostScreenPreviewMenu: View {
    @ObservedObject var state: HostScreenPreviewState

    var body: some View {
        Toggle(isOn: $state.isEnabled) {
            Label("Host screen preview", systemImage: "pip")
        }
        .uiKitIdentifier("RipulDevConsole.hostPreview.toggle")
    }
}

@available(iOS 26.0, *)
private struct HostScreenPreviewImage: View {
    @ObservedObject var frame: HostScreenPreviewFrame

    var body: some View {
        Group {
            if let image = frame.image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.slash")
                    Text("Preview unavailable").font(.caption)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Host screen preview, view only")
    }
}

@available(iOS 26.0, *)
private struct HostScreenPreviewView: View {
    @ObservedObject var state: HostScreenPreviewState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            if state.isEnabled, geometry.size.width > 0, geometry.size.height > 0 {
                let sourceSize = state.hostSize == .zero ? geometry.size : state.hostSize
                let ratio = sourceSize.width / max(1, sourceSize.height)
                RipulFloatingPanel(
                    storageKey: HostScreenPreviewState.storageKey,
                    defaultSize: CGSize(width: sourceSize.width * 0.5, height: sourceSize.height * 0.5),
                    minSize: CGSize(width: 120, height: 120 / ratio),
                    showsResizeGrip: !state.isCollapsed,
                    store: state.store,
                    aspectRatio: ratio,
                    contentInsets: UIEdgeInsets(top: 52, left: 0, bottom: 88, right: 0),
                    avoidsKeyboard: true
                ) { size in
                    // Keep one shape mounted throughout the shrink/expand. The
                    // panel already hugs its content and retains the expanded
                    // size, so collapsing never overwrites the resize setting.
                    let availableHeight = geometry.size.height - state.hostSafeArea.top - state.hostSafeArea.bottom - 156
                    let width = max(56, min(size.width, geometry.size.width - 32, max(56, availableHeight * ratio)))
                    let collapsed = state.isCollapsed
                    ZStack(alignment: .topTrailing) {
                        HostScreenPreviewImage(frame: state.frame)
                            .background(Color(uiColor: .systemBackground))
                            .opacity(collapsed ? 0 : 1)
                        if collapsed {
                            Button { state.isCollapsed = false } label: {
                                Image(systemName: "pip")
                                    .font(.system(size: 22, weight: .medium))
                                    .frame(width: 56, height: 56)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Expand host screen preview")
                            .uiKitIdentifier("RipulDevConsole.hostPreview.expand")
                        } else {
                            Button { state.isCollapsed = true } label: {
                                Image(systemName: "minus")
                                    .font(.system(size: 16, weight: .semibold))
                                    .frame(width: 44, height: 44)
                                    .glassEffect(.regular.interactive(), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .padding(4)
                            .accessibilityLabel("Minimise host screen preview")
                            .uiKitIdentifier("RipulDevConsole.hostPreview.minimize")
                        }
                    }
                    .frame(width: collapsed ? 56 : width, height: collapsed ? 56 : width / ratio)
                    .clipShape(RoundedRectangle(cornerRadius: collapsed ? 28 : 18))
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: collapsed ? 28 : 18))
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
                    .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.88), value: collapsed)
                }
                .id(ratio)
            }
        }
        .ignoresSafeArea(.container)
    }
}

/// SwiftUI hosting backgrounds cover the whole overlay. Only hits inside the
/// shared floating panel belong to us; all other hits stay with the agent UI.
final class HostScreenPreviewPassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        var ancestor: UIView? = hit
        while let current = ancestor, current !== self {
            if current is RipulFloatingPanelRootView { return hit }
            ancestor = current.superview
        }
        return nil
    }
}

@available(iOS 26.0, *)
final class HostScreenPreviewController: UIViewController {
    let state: HostScreenPreviewState

    init(state: HostScreenPreviewState) {
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() { view = HostScreenPreviewPassthroughView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: HostScreenPreviewView(state: state))
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        state.setHostLayout(size: view.bounds.size, safeArea: view.window?.safeAreaInsets ?? view.safeAreaInsets)
    }
}
#endif
