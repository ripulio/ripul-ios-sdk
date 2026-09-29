#if os(iOS)
import UIKit
import SwiftUI
import WebKit

struct NativeToolAnchorGeometry: Decodable {
    let ownerId: String
    let groupId: String
    let anchor: NativeContentRect?
    let viewport: NativeContentRect?
    let contentHeight: CGFloat?
    let viewportWidth: CGFloat?
    let layered: Bool?
}

/// A tool strip mounted in its DOM anchor via `NativeSlotAttachment`: parented
/// to the anchor's own WebKit view when it has one, so it moves with its row;
/// otherwise to the chat scroller, following position reports. No private
/// classes/selectors, scroll observers, display links or scroll offset writes.
@MainActor
final class NativeToolStripAnchorController {
    private static let appearanceAnimationKey = "NativeToolStrip.appear"
    private weak var webView: WKWebView?
    private let store: NativeToolStripStore
    private let accessibilityGroupId: String?
    private let canChangeLayout: () -> Bool
    private var host: UIHostingController<NativeToolStripContent>?
    private var attachment: NativeSlotAttachment?
    private var geometry: NativeToolAnchorGeometry?
    private var retry: Task<Void, Never>?
    private var enabled = false
    private(set) var placementCount = 0
    #if DEBUG
    /// Where this lozenge is drawn right now (presentation layer, window points).
    var screenMinY: Int? {
        guard let view = host?.view, attachment?.isMounted == true, !view.isHidden, let window = view.window else { return nil }
        let layer = view.layer.presentation() ?? view.layer
        let windowLayer = window.layer.presentation() ?? window.layer
        return Int(layer.convert(layer.bounds, to: windowLayer).minY.rounded())
    }
    #endif
    var frameInWebView: CGRect? {
        guard let webView, let view = host?.view, attachment?.isMounted == true else { return nil }
        return view.convert(view.bounds, to: webView)
    }

    private var buttonFrames: [String: CGRect] = [:]
    private var accessibleButtons: [String: NativeToolStripAccessibleButton] = [:]

    var accessibilityElements: [Any] {
        guard enabled, store.anchored, let webView, let scroller = attachment?.scroller, let view = host?.view,
              view.isDescendant(of: scroller), let snapshot = store.display else { return [] }
        let visible = scroller.convert(scroller.bounds, to: view).intersection(view.bounds)
        let ids = store.collapsed ? ["summary"] : snapshot.tools.map(\.id)
        return ids.compactMap { id in
            guard let frame = buttonFrames[id], frame.intersects(visible) else { return nil }
            let element = accessibleButtons[id] ?? NativeToolStripAccessibleButton(accessibilityContainer: webView)
            accessibleButtons[id] = element
            element.host = view; element.localFrame = frame
            element.accessibilityIdentifier = id == "summary"
                ? "NativeToolStrip.summary" + (accessibilityGroupId.map { "." + $0 } ?? "")
                : "NativeToolStrip.tool.\(id)"
            element.accessibilityTraits = .button
            element.accessibilityCustomActions = nil
            if id == "summary" {
                element.accessibilityLabel = "\(snapshot.tools.reduce(0) { $0 + $1.count }) tool calls"
                element.accessibilityHint = "Show individual tools"
                element.activate = { [weak store] in store?.expand() }
            } else if let tool = snapshot.tools.first(where: { $0.id == id }) {
                element.accessibilityLabel = "\(tool.label), \(tool.count) \(tool.count == 1 ? "call" : "calls")"
                element.accessibilityHint = "Open tool details"
                element.activate = { [weak store] in store?.select(id) }
                if let action = tool.defaultAction {
                    element.accessibilityCustomActions = [UIAccessibilityCustomAction(name: action.title) { [weak store] _ in
                        store?.performDefault(id, actionId: action.id)
                        return store != nil
                    }]
                }
            }
            return element
        }
    }

    /// Where hosting controllers come from and go back to (rows share one).
    private let hosts: NativeToolStripHostPool?

    init(webView: WKWebView, store: NativeToolStripStore, accessibilityGroupId: String? = nil,
         hosts: NativeToolStripHostPool? = nil, canChangeLayout: @escaping () -> Bool = { true }) {
        self.webView = webView
        self.hosts = hosts
        self.store = store
        self.accessibilityGroupId = accessibilityGroupId
        self.canChangeLayout = canChangeLayout
        enabled = store.isPresented
        store.enableDOMAnchor()
        store.presentationChanged = { [weak self] enabled in
            self?.enabled = enabled
            if enabled { self?.schedulePlacement() } else { self?.detach() }
        }
        store.scopeChanged = { [weak self] in self?.geometry = nil; self?.detach() }
    }

    func receive(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let next = try? JSONDecoder().decode(NativeToolAnchorGeometry.self, from: data),
              next.ownerId == store.display?.ownerId, next.groupId == store.display?.groupId else { return }
        geometry = next
        guard next.anchor != nil else { detach(); return }
        // Already mounted: take the new position now, mid-scroll or not.
        if reposition() { retry?.cancel(); retry = nil; return }
        schedulePlacement()
    }

    /// Whether the strip is mounted, so a new position is just a frame move.
    var isAttached: Bool { attachment?.isMounted ?? false }

    private var slotGeometry: NativeSlotGeometry? {
        guard let geometry, geometry.ownerId == store.display?.ownerId, geometry.groupId == store.display?.groupId
        else { return nil }
        return NativeSlotGeometry(anchor: geometry.anchor, viewport: geometry.viewport,
                                  contentHeight: geometry.contentHeight, viewportWidth: geometry.viewportWidth,
                                  layered: geometry.layered ?? false)
    }

    /// The strip is a fixed 44pt row at the top of its anchor.
    private static func stripFrame(_ placed: NativeSlotPlacement) -> CGRect {
        CGRect(x: placed.rect.minX, y: placed.rect.minY, width: placed.rect.width, height: 44 * placed.unit)
    }

    private func reposition() -> Bool {
        guard enabled, let attachment, let g = slotGeometry else { return false }
        return attachment.reposition(geometry: g, frame: Self.stripFrame)
    }

    private func schedulePlacement() {
        retry?.cancel()
        guard enabled, geometry?.anchor != nil else { return }
        // A DOM layout message can beat WebKit's native layer-tree commit.
        // Allow eight idle retries for this layout event; pause while scrolling.
        retry = Task { [weak self] in
            var attempts = 0
            while true {
                guard !Task.isCancelled, let self, self.enabled else { return }
                MainThreadSampler.count("strip.retry")
                let idle = self.canChangeLayout()
                if idle {
                    guard attempts < 8 else { self.detach(); return }
                    if self.place() { return }
                    attempts += 1
                }
                // A gesture can begin after the row manager queued placement.
                // Do not create/reparent views, force layout or exhaust retries
                // until both dragging and native deceleration have ended.
                do { try await Task.sleep(nanoseconds: idle ? 32_000_000 : 80_000_000) }
                catch { return }
            }
        }
    }

    private func place() -> Bool {
        guard let webView, let g = slotGeometry else { return false }
        if host == nil {
            let content = NativeToolStripContent(store: store, onButtonFrames: { [weak self] in self?.buttonFrames = $0 })
            host = hosts?.take(content) ?? NativeToolStripHostPool.make(content)
        }
        guard let host else { return false }
        let attachment = self.attachment ?? {
            let made = NativeSlotAttachment(webView: webView, label: "toolStrip " + (accessibilityGroupId ?? "-"))
            made.onDropped = { [weak self] in
                guard let self, self.enabled, self.geometry?.anchor != nil else { return }
                self.schedulePlacement()
            }
            self.attachment = made
            return made
        }()
        let isAppearing = !attachment.isMounted
        if isAppearing {
            NativeComposerFocusTrace.shared.record("toolStrip.attach", view: host.view, values: ["reparenting": false])
        }
        guard attachment.place(content: host.view, controller: host, geometry: g, frame: Self.stripFrame) != nil
        else { return false }
        host.view.isHidden = false
        host.view.layoutIfNeeded()
        if isAppearing && !UIAccessibility.isReduceMotionEnabled {
            // Animate only the rendered opacity. The model view stays fully
            // interactive, and UIKit keeps ownership of scrolling and layout.
            // Existing strips do not fade again when their anchor moves.
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            // Matches the web copy's 180ms fade-out beneath: a crossfade.
            fade.duration = 0.18
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            host.view.layer.add(fade, forKey: Self.appearanceAnimationKey)
        }
        placementCount += 1
        store.setAnchored(true)
        return true
    }

    /// WebKit's compositing hierarchy normally routes taps back to web content.
    /// The web-view subclass gives only our own native controls first refusal.
    func hitTest(_ point: CGPoint, event: UIEvent?) -> UIView? {
        guard enabled, store.anchored, let webView, let scroller = attachment?.scroller, let view = host?.view,
              view.isDescendant(of: scroller), !view.isHidden, webView.bounds.contains(point),
              scroller.convert(scroller.bounds, to: webView).contains(point) else { return nil }
        let local = view.convert(point, from: webView)
        return view.bounds.contains(local) ? view.hitTest(local, with: event) : nil
    }

    private func detach() {
        if let view = host?.view, attachment?.isMounted == true {
            NativeComposerFocusTrace.shared.record("toolStrip.detach", view: view)
        }
        retry?.cancel()
        retry = nil
        host?.view.layer.removeAnimation(forKey: Self.appearanceAnimationKey)
        attachment?.unmount()
        accessibleButtons = [:]
        store.setAnchored(false)
    }

    func invalidate() {
        detach()
        attachment?.unmount(removing: host)
        attachment = nil
        if let host { hosts?.give(host) }
        host = nil
        geometry = nil
        store.presentationChanged = nil
        store.scopeChanged = nil
    }
}
/// Reuses tool-strip hosting controllers as rows scroll away and back, the way
/// a table view reuses cells. Creating a UIHostingController and its SwiftUI
/// graph per row was the cost that kept strips confined to a 200px window and
/// out of scrolls; a pooled host only swaps its root view.
@MainActor
final class NativeToolStripHostPool {
    private var idle: [UIHostingController<NativeToolStripContent>] = []
    /// About two screens of strips; beyond that, released.
    private let limit = 24

    static func make(_ content: NativeToolStripContent) -> UIHostingController<NativeToolStripContent> {
        let host = UIHostingController(rootView: content)
        host.safeAreaRegions = []
        host.view.backgroundColor = .clear
        host.view.accessibilityElementsHidden = true
        return host
    }

    func take(_ content: NativeToolStripContent) -> UIHostingController<NativeToolStripContent> {
        guard let host = idle.popLast() else { return Self.make(content) }
        host.rootView = content
        return host
    }

    func give(_ host: UIHostingController<NativeToolStripContent>) {
        host.view.layer.removeAllAnimations()
        host.view.isHidden = false
        if idle.count < limit { idle.append(host) }
    }
}

/// WebKit supplies its own remote accessibility tree. Expose the native buttons
/// explicitly, converting their strip-local layout only when assistive technology
/// asks for a screen frame. UIKit still owns all vertical scrolling.
@MainActor
private final class NativeToolStripAccessibleButton: UIAccessibilityElement {
    weak var host: UIView?
    var localFrame: CGRect = .zero
    var activate: (() -> Void)?
    override var accessibilityFrame: CGRect {
        get { host.map { UIAccessibility.convertToScreenCoordinates(localFrame, in: $0) } ?? .zero }
        set {}
    }
    override func accessibilityActivate() -> Bool { activate?(); return activate != nil }
}
#endif

#if DEBUG && os(iOS)
/// [LZLAG]: how far mounted native slot content (tool strips, embeds) jumped
/// when a new position was applied — how wrong it looked on screen until then.
/// `fast` counts moves made without a full placement. Near zero when content
/// rides its slot's WebKit view. Logged every 2s while anything moves.
@MainActor
final class NativeToolStripLagProbe {
    static let shared = NativeToolStripLagProbe()
    private var moves = 0, fast = 0, maxJump: CGFloat = 0, bigJumps = 0
    private var flush: Task<Void, Never>?

    func record(jump: CGFloat, fast isFast: Bool) {
        guard jump > 0.5 else { return }
        moves += 1
        if isFast { fast += 1 }
        maxJump = max(maxJump, jump)
        if jump >= 20 { bigJumps += 1 }
        guard flush == nil else { return }
        flush = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.report()
        }
    }

    private func report() {
        NSLog("[LZLAG] moves=%d fast=%d maxJump=%.0fpt jumps>=20pt=%d", moves, fast, maxJump, bigJumps)
        moves = 0; fast = 0; maxJump = 0; bigJumps = 0
        flush = nil
    }
}
#endif
