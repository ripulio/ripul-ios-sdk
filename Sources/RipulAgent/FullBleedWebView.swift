#if os(iOS)
import UIKit
import WebKit

/// WKWebView subclass that zeroes-out bottom safe area insets so web content
/// (100vh, 100%) fills the entire frame including the home indicator region.
/// The native chat input overlay handles bottom spacing instead.
class FullBleedWebView: WKWebView {
    private let observedScrollPans = NSHashTable<UIPanGestureRecognizer>.weakObjects()
    private var scrollDirections: [ObjectIdentifier: String] = [:]

    // Native tool/widget touches can bypass DOM touchmove. Observe the actual
    // ancestor scroll gesture, without replacing WebKit's delegate, adding a
    // competing recognizer, publishing SwiftUI state, or writing an offset.
    private func observeScrollIntent(from hit: UIView?, event: UIEvent?) {
        guard event?.type == .touches else { return }
        var ancestor = hit
        while let view = ancestor, view !== self {
            if let scroll = view as? UIScrollView {
                let pan = scroll.panGestureRecognizer
                if !observedScrollPans.contains(pan) {
                    observedScrollPans.add(pan)
                    pan.addTarget(self, action: #selector(scrollIntentChanged(_:)))
                }
            }
            ancestor = view.superview
        }
    }

    @objc private func scrollIntentChanged(_ pan: UIPanGestureRecognizer) {
        let id = ObjectIdentifier(pan)
        guard pan.state == .began || pan.state == .changed else {
            scrollDirections.removeValue(forKey: id)
            return
        }
        guard let scroll = pan.view as? UIScrollView, bounds.width > 0 else { return }
        let velocity = pan.velocity(in: scroll)
        guard abs(velocity.y) > abs(velocity.x), abs(velocity.y) > 2 else { return }
        let direction = velocity.y > 0 ? "up" : "down"
        guard scrollDirections[id] != direction else { return }
        scrollDirections[id] = direction
        let viewport = scroll.convert(scroll.bounds, to: self)
        // DOM validates the scrolling viewport, so a map or horizontal tool
        // strip's own interaction cannot release chat following.
        callAsyncJavaScript("""
            const scale = document.documentElement.clientWidth / nativeWidth;
            window.dispatchEvent(new CustomEvent('ripul:user-scroll-intent', { detail: {
                direction, left: left * scale, top: top * scale,
                width: width * scale, height: height * scale
            }}));
            """, arguments: ["direction": direction, "left": viewport.minX,
                "top": viewport.minY, "width": viewport.width, "height": viewport.height,
                "nativeWidth": bounds.width], in: nil, in: .page, completionHandler: nil)
    }

    /// Fires on the main queue, outside any SwiftUI update, when the row the
    /// native top bar occupies moves (see `WindowTopChromeLayout`) after the
    /// first measurement. The bridge re-injects the web clearance under it.
    var onTopClearanceChange: (() -> Void)?
    private var lastTopClearance: CGFloat?

    #if !targetEnvironment(macCatalyst)
    private var edgeUpdateScheduled = false
    private var hasTopClearance: Bool?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        hasTopClearance = nil
        scheduleScrollEdgeUpdate()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        scheduleScrollEdgeUpdate()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scheduleScrollEdgeUpdate()
    }

    private func scheduleScrollEdgeUpdate() {
        guard #available(iOS 27.0, *), !edgeUpdateScheduled else { return }
        edgeUpdateScheduled = true
        // As with WindowSafeAreaTopReader, never query window safe areas inside
        // a SwiftUI layout transaction. No bridge publication or scroll polling.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.edgeUpdateScheduled = false
            guard let window = self.window else { return }
            let clearance = WindowTopChromeLayout.clearance(for: window).top
            if let last = self.lastTopClearance, last != clearance {
                self.onTopClearanceChange?()
            }
            self.lastTopClearance = clearance
            let hasClearance = window.safeAreaInsets.top > 0
            guard hasClearance != self.hasTopClearance else { return }
            self.hasTopClearance = hasClearance
            // UIKit/WebKit own the blur, including CSS overflow content. Only
            // suppress the status-region effect when there is no top clearance;
            // individual floating controls retain their own glass.
            self.scrollView.topEdgeEffect.isHidden = !hasClearance
        }
    }
    #endif

    var toolStripAccessibilityElements: (() -> [Any])?
    override var accessibilityElements: [Any]? {
        get {
            guard let native = toolStripAccessibilityElements?(), !native.isEmpty else { return super.accessibilityElements }
            if let webElements = super.accessibilityElements { return webElements + native }
            // Direct children of the root scroll view are already exposed.
            // WebKit's overflow scrollers expose a separate web accessibility
            // tree, so native children attached there need an explicit entry.
            return [scrollView] + native.filter { element in
                guard let view = element as? UIView else { return true }
                return view.superview !== scrollView
            }
        }
        set { super.accessibilityElements = newValue }
    }
    var toolStripHitTest: ((CGPoint, UIEvent?) -> UIView?)?
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = toolStripHitTest?(point, event) ?? super.hitTest(point, with: event)
        observeScrollIntent(from: hit, event: event)
        return hit
    }
    override var safeAreaInsets: UIEdgeInsets {
        var insets = super.safeAreaInsets
        insets.bottom = 0
        return insets
    }
}

#endif
