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
}

/// Experimental attachment to the native UIScrollView backing CSS overflow.
/// No private classes/selectors, scroll observers, display links or scroll
/// offset writes. Once attached, UIKit moves and clips the toolbar itself.
@MainActor
final class NativeToolStripAnchorController {
    private static let appearanceAnimationKey = "NativeToolStrip.appear"
    private weak var webView: WKWebView?
    private let store: NativeToolStripStore
    private let accessibilityGroupId: String?
    private let canChangeLayout: () -> Bool
    private var host: UIHostingController<NativeToolStripContent>?
    private weak var scroller: UIScrollView?
    private var geometry: NativeToolAnchorGeometry?
    private var retry: Task<Void, Never>?
    private var enabled = false
    private(set) var placementCount = 0
    var frameInWebView: CGRect? {
        guard let webView, let view = host?.view, view.superview != nil else { return nil }
        return view.convert(view.bounds, to: webView)
    }

    private var buttonFrames: [String: CGRect] = [:]
    private var accessibleButtons: [String: NativeToolStripAccessibleButton] = [:]

    var accessibilityElements: [Any] {
        guard enabled, store.anchored, let webView, let scroller, let view = host?.view,
              view.superview === scroller, let snapshot = store.display else { return [] }
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

    init(webView: WKWebView, store: NativeToolStripStore, accessibilityGroupId: String? = nil,
         canChangeLayout: @escaping () -> Bool = { true }) {
        self.webView = webView
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
        schedulePlacement()
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
        guard let webView, let geometry, let anchor = geometry.anchor, let viewport = geometry.viewport,
              anchor.isValid, viewport.isValid,
              let contentHeight = geometry.contentHeight, contentHeight.isFinite, contentHeight > 0,
              let viewportWidth = geometry.viewportWidth, viewportWidth.isFinite, viewportWidth > 0,
              geometry.ownerId == store.display?.ownerId, geometry.groupId == store.display?.groupId else { return false }
        let scale = webView.bounds.width / viewportWidth
        let expected = CGRect(x: viewport.x * scale, y: viewport.y * scale,
                              width: viewport.width * scale, height: viewport.height * scale)
        var candidates: [(UIScrollView, CGFloat)] = []
        func visit(_ view: UIView) {
            if view === host?.view { return }
            if let scroll = view as? UIScrollView, scroll !== webView.scrollView, !scroll.isHidden {
                let actual = scroll.convert(scroll.bounds, to: webView)
                let error = abs(actual.minX - expected.minX) + abs(actual.minY - expected.minY)
                    + abs(actual.width - expected.width) + abs(actual.height - expected.height)
                let contentScale = scroll.bounds.width / viewport.width
                if error < 8, abs(scroll.contentSize.height - contentHeight * contentScale) < max(8, contentHeight * contentScale * 0.01) {
                    candidates.append((scroll, error))
                }
            }
            for child in view.subviews { visit(child) }
        }
        visit(webView.scrollView)
        let matchingScroller = candidates.min(by: { $0.1 < $1.1 })?.0
        // WebKit creates no inner native scroller until CSS content overflows.
        // A short chat cannot scroll internally, so the outer content view is
        // sufficient. A later content-height layout report moves us into the
        // inner scroll view as soon as the chat becomes scrollable.
        let fitsViewport = contentHeight <= viewport.height + 1
        guard let target = matchingScroller ?? (fitsViewport ? webView.scrollView : nil) else { return false }
        if host == nil {
            let controller = UIHostingController(rootView: NativeToolStripContent(store: store, onButtonFrames: { [weak self] in
                self?.buttonFrames = $0
            }))
            controller.safeAreaRegions = []
            controller.view.backgroundColor = .clear
            controller.view.accessibilityElementsHidden = true
            host = controller
        }
        guard let host else { return false }
        let isAppearing = host.view.superview == nil
        if host.parent == nil {
            var responder: UIResponder? = webView
            while let current = responder {
                if let parent = current as? UIViewController {
                    parent.addChild(host)
                    target.addSubview(host.view)
                    host.didMove(toParent: parent)
                    break
                }
                responder = current.next
            }
        }
        if host.view.superview !== target { target.addSubview(host.view) }
        scroller = target
        if target === webView.scrollView {
            let viewportFrame = CGRect(x: expected.minX + anchor.x * scale, y: expected.minY + anchor.y * scale,
                                       width: anchor.width * scale, height: 44 * scale)
            host.view.frame = target.convert(viewportFrame, from: webView)
        } else {
            let contentScale = target.bounds.width / viewport.width
            host.view.frame = CGRect(x: anchor.x * contentScale, y: anchor.y * contentScale,
                                     width: anchor.width * contentScale, height: 44 * contentScale)
        }
        host.view.isHidden = false
        host.view.layoutIfNeeded()
        if isAppearing && !UIAccessibility.isReduceMotionEnabled {
            // Animate only the rendered opacity. The model view stays fully
            // interactive, and UIKit keeps ownership of scrolling and layout.
            // Existing strips do not fade again when their anchor moves.
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.14
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
        guard enabled, store.anchored, let webView, let scroller, let view = host?.view,
              view.superview === scroller, !view.isHidden, webView.bounds.contains(point),
              scroller.convert(scroller.bounds, to: webView).contains(point) else { return nil }
        let local = view.convert(point, from: webView)
        return view.bounds.contains(local) ? view.hitTest(local, with: event) : nil
    }

    private func detach() {
        retry?.cancel()
        retry = nil
        host?.view.layer.removeAnimation(forKey: Self.appearanceAnimationKey)
        host?.view.removeFromSuperview()
        scroller = nil
        accessibleButtons = [:]
        store.setAnchored(false)
    }

    func invalidate() {
        detach()
        host?.willMove(toParent: nil)
        host?.removeFromParent()
        host = nil
        geometry = nil
        store.presentationChanged = nil
        store.scopeChanged = nil
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
