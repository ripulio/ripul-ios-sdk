#if os(iOS) && (DEBUG || RIPUL_DEVELOPER_BUILD || RIPUL_DEVELOPER_TOOLS)
import SwiftUI
import UIKit

public extension Notification.Name {
    /// Asks the console to present `RipulSiteSwitchScreen`. Scoped to the
    /// originating bridge, like `ripulShowSolutions`.
    static let ripulShowSiteSwitch = Notification.Name("ripulShowSiteSwitch")
}

/// The dev helper's "Ripul Site" lever: the sites the signed-in Ripul person
/// belongs to, the one in use, and Reset. See `RipulSiteSwitch`.
@available(iOS 26.0, *)
public struct RipulSiteSwitchScreen: View {
    let baseURL: URL
    let tokenProvider: () -> String?
    let onClose: () -> Void

    @State private var sites: [RipulMemberSite] = []
    @State private var isLoading = true
    @State private var failure: String?
    @State private var activeKey: String = ""
    @State private var changedThisVisit = false

    public init(baseURL: URL, tokenProvider: @escaping () -> String?, onClose: @escaping () -> Void) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        self.onClose = onClose
    }

    private var compiled: RipulSiteSwitch.CompiledSite? { RipulSiteSwitchStore.compiled }
    private var isSwitched: Bool { compiled.map { activeKey != $0.publishableKey } ?? false }

    public var body: some View {
        NavigationStack {
            List {
                if let compiled {
                    Section {
                        row(name: compiled.name, detail: "Compiled into this build", key: compiled.publishableKey) {
                            choose(nil)
                        }
                    } header: {
                        Text("Default")
                    }
                    Section {
                        if isLoading {
                            HStack { ProgressView(); Text("Loading your sites…").foregroundStyle(.ripul(.textSecondary)) }
                        } else if let failure {
                            Text(failure).font(.ripul(.footnote)).foregroundStyle(.ripul(.danger))
                        } else if otherSites.isEmpty {
                            Text("You belong to no other site that accepts \(compiled.origin).")
                                .font(.ripul(.footnote)).foregroundStyle(.ripul(.textSecondary))
                        }
                        ForEach(otherSites) { site in
                            row(name: site.name, detail: [site.slug, site.role].compactMap { $0 }.joined(separator: " · "),
                                key: site.publishableKey) { choose(site) }
                        }
                    } header: {
                        Text("Your sites")
                    } footer: {
                        Text("Moves only what Ripul serves this app: the portal, the agent and conversations. "
                             + "Each site's own membership and row rules still decide what you see. "
                             + "Signing out clears the choice.")
                    }
                    if isSwitched {
                        Section {
                            Button("Reset to \(compiled.name)") { choose(nil) }
                                .uiKitIdentifier("RipulSiteSwitch.reset")
                        }
                    }
                    if changedThisVisit {
                        Section {
                            Text("Screens already open keep the site they opened with. Quit and reopen the app to be sure every screen follows.")
                                .font(.ripul(.footnote)).foregroundStyle(.ripul(.textSecondary))
                        }
                    }
                } else {
                    Text("This app has not registered its site with the SDK (RipulSiteSwitch.register).")
                        .font(.ripul(.footnote)).foregroundStyle(.ripul(.textSecondary))
                }
            }
            .navigationTitle("Ripul Site")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onClose).uiKitIdentifier("RipulSiteSwitch.done")
                }
            }
            .task { await load() }
        }
    }

    private var otherSites: [RipulMemberSite] {
        sites.filter { $0.publishableKey != compiled?.publishableKey }
    }

    private func row(name: String, detail: String, key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).foregroundStyle(.ripul(.text))
                    if !detail.isEmpty {
                        Text(detail).font(.ripul(.caption)).foregroundStyle(.ripul(.textSecondary))
                    }
                }
                Spacer()
                if key == activeKey {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
        }
        .uiKitIdentifier("RipulSiteSwitch.site")
    }

    private func choose(_ site: RipulMemberSite?) {
        guard let compiled else { return }
        let next = site?.publishableKey ?? compiled.publishableKey
        guard next != activeKey else { return }
        RipulSiteSwitchStore.set(site)
        activeKey = RipulSiteSwitch.siteKey(compiled: compiled.publishableKey)
        changedThisVisit = true
    }

    private func load() async {
        guard let compiled else { isLoading = false; return }
        activeKey = RipulSiteSwitch.siteKey(compiled: compiled.publishableKey)
        guard let token = tokenProvider() else {
            failure = "Sign in to your Ripul account in the dev helper to list your sites."
            isLoading = false
            return
        }
        do {
            sites = try await RipulSiteSwitchAPI.memberSites(baseURL: baseURL, token: token, origin: compiled.origin)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
        isLoading = false
    }
}

/// Presents `RipulSiteSwitchScreen` when this console's menu asks for it.
/// A ViewModifier for the same reason as `SolutionsSheet`.
@available(iOS 26.0, *)
struct SiteSwitchSheet: ViewModifier {
    let bridge: AgentBridge
    let baseURL: URL
    let tokenProvider: () -> String?
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .ripulShowSiteSwitch)) { notification in
                guard let source = notification.object as? AgentBridge, source === bridge else { return }
                isPresented = true
            }
            .ripulSheet(isPresented: $isPresented) {
                RipulSiteSwitchScreen(baseURL: baseURL, tokenProvider: tokenProvider, onClose: { isPresented = false })
            }
    }
}

// MARK: - Marker

/// A pill at the top of the screen while the app is pointed at a site other
/// than the one it compiled in: the site's name, and a Reset. It sits in its
/// own pass-through window, so it shows over every screen of the host app and
/// takes no touch outside itself.
@MainActor
final class RipulSiteSwitchMarker {
    static let shared = RipulSiteSwitchMarker()
    private var windows: [ObjectIdentifier: MarkerWindow] = [:]
    private var sceneObserver: NSObjectProtocol?

    /// An app registers its site at launch, before any scene is connected, so
    /// the marker is drawn again whenever a scene becomes active.
    func startShowing() {
        if sceneObserver == nil {
            sceneObserver = NotificationCenter.default.addObserver(
                forName: UIScene.didActivateNotification, object: nil, queue: .main
            ) { _ in MainActor.assumeIsolated { RipulSiteSwitchMarker.shared.update() } }
        }
        update()
    }

    func update() {
        let name = RipulSiteSwitchStore.compiled.flatMap { RipulSiteSwitch.switchedSiteName(compiledKey: $0.publishableKey) }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            let id = ObjectIdentifier(scene)
            guard let name else {
                windows[id]?.isHidden = true
                windows[id] = nil
                continue
            }
            let window = windows[id] ?? MarkerWindow(windowScene: scene)
            windows[id] = window
            window.show(name: name, compiledName: RipulSiteSwitchStore.compiled?.name ?? "the default")
        }
    }

    private final class MarkerWindow: RipulChromeWindow {
        private var host: UIHostingController<MarkerPill>?
        /// While the Reset dialog is up the whole window takes touches; otherwise only the pill does.
        private var isConfirming = false

        override var acceptsPresentation: Bool { false }

        func show(name: String, compiledName: String) {
            windowLevel = .statusBar + 1
            backgroundColor = .clear
            let pill = MarkerPill(name: name, compiledName: compiledName) { [weak self] confirming in
                self?.isConfirming = confirming
            }
            if let host {
                host.rootView = pill
            } else {
                let host = UIHostingController(rootView: pill)
                host.view.backgroundColor = .clear
                host.sizingOptions = [.intrinsicContentSize]
                rootViewController = host
                self.host = host
            }
            isHidden = false
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let view = host?.view else { return }
            let size = view.sizeThatFits(bounds.size)
            view.frame = CGRect(x: (bounds.width - size.width) / 2, y: safeAreaInsets.top,
                                width: size.width, height: size.height)
        }

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            if isConfirming { return super.hitTest(point, with: event) }
            guard let view = host?.view, view.frame.contains(point) else { return nil }
            return super.hitTest(point, with: event)
        }
    }

    private struct MarkerPill: View {
        let name: String
        let compiledName: String
        let onConfirmingChange: (Bool) -> Void
        @State private var confirming = false

        var body: some View {
            Button { confirming = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.swap")
                    Text("Ripul site: \(name)").lineLimit(1)
                }
                .font(.ripul(.caption))
                .foregroundStyle(.ripul(.onAccent))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.ripul(.warning)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Pointed at Ripul site \(name). Reset to \(compiledName).")
            .uiKitIdentifier("RipulSiteSwitch.marker")
            .confirmationDialog("Pointed at \(name)", isPresented: $confirming, titleVisibility: .visible) {
                Button("Reset to \(compiledName)") { RipulSiteSwitch.reset() }
                Button("Keep \(name)", role: .cancel) {}
            } message: {
                Text("This developer build is talking to \(name) instead of the site it was built with.")
            }
            .onChange(of: confirming) { _, value in onConfirmingChange(value) }
            .padding(4)
        }
    }
}

#endif
