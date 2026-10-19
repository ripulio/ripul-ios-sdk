#if os(iOS)
import UIKit
import WebKit

/// WKWebView subclass that zeroes-out bottom safe area insets so web content
/// (100vh, 100%) fills the entire frame including the home indicator region.
/// The native chat input overlay handles bottom spacing instead.
class FullBleedWebView: WKWebView {
    var onReplySelectionError: ((String) -> Void)?

    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .context else { return }
        // Resolve only when the system presents the menu, without observing
        // every selection change. The web restricts this to one chat bubble.
        let selection = UIDeferredMenuElement.uncached { [weak self] completion in
            Task { @MainActor in
                guard let self else { completion([]); return }
                do {
                    let value = try await self.callAsyncJavaScript("""
                        return window.__ripulCaptureSelectionReply
                            ? await window.__ripulCaptureSelectionReply() : null;
                        """, arguments: [:], in: nil, in: .page)
                    guard let reply = value as? [String: Any] else { completion([]); return }
                    let action = UIAction(title: "Quote in reply", image: UIImage(systemName: "arrowshape.turn.up.left")) { [weak self] _ in
                        self?.quoteSelection(reply)
                    }
                    completion([action])
                } catch {
                    completion([])
                }
            }
        }
        builder.insertChild(UIMenu(title: "", options: .displayInline, children: [selection]), atStartOfMenu: .root)
    }

    private func quoteSelection(_ reply: [String: Any]) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let value = try await self.callAsyncJavaScript("""
                    return await window.__ripulQuoteSelectionReply(reply);
                    """, arguments: ["reply": reply], in: nil, in: .page)
                let result = value as? [String: Any]
                if result?["success"] as? Bool != true {
                    self.onReplySelectionError?(result?["error"] as? String ?? "Select the passage again and try quoting it.")
                }
            } catch {
                self.onReplySelectionError?("The quote could not be added. Select the passage again and try quoting it.")
            }
        }
    }

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

    // A trackpad scroll goes to the innermost scroll view under the pointer and
    // stays there. UIKit hands a vertical finger drag over a sideways-only
    // scroller (a wide table, a code block) on to the chat, but not a trackpad
    // scroll: that moved nothing (measured on Catalyst, 6 October 2026). So
    // such a scroller takes no trackpad scrolls while a vertical scroller
    // encloses it, and the page applies the sideways part of the gesture
    // (trackpadSidewaysScroll.ts, which `trackpadScrollScript` switches on).
    // Its `appRoutesToChat` repeats the rule below; change them together, or
    // a scroller both sides claim moves twice. Native content keeps its own
    // scrolling.
    private let trackpadScrollTypes = NSMapTable<UIScrollView, NSNumber>.weakToStrongObjects()

    private func routeTrackpadScrolls(from hit: UIView?, event: UIEvent?) {
        guard event?.type != .touches else { return }
        var scrollers: [UIScrollView] = []
        var ancestor = hit
        while let view = ancestor, view !== self {
            if view is SlotMountView { scrollers.removeAll() }
            if let scroll = view as? UIScrollView { scrollers.append(scroll) }
            ancestor = view.superview
        }
        for (index, scroll) in scrollers.enumerated() {
            let pan = scroll.panGestureRecognizer
            let sidewaysOnly = !Self.scrolls(scroll, vertically: true) && Self.scrolls(scroll, vertically: false)
                && scrollers[(index + 1)...].contains { Self.scrolls($0, vertically: true) }
            if sidewaysOnly {
                guard trackpadScrollTypes.object(forKey: scroll) == nil else { continue }
                trackpadScrollTypes.setObject(NSNumber(value: pan.allowedScrollTypesMask.rawValue), forKey: scroll)
                pan.allowedScrollTypesMask = []
            } else if let saved = trackpadScrollTypes.object(forKey: scroll) {
                pan.allowedScrollTypesMask = UIScrollTypeMask(rawValue: saved.intValue)
                trackpadScrollTypes.removeObject(forKey: scroll)
            }
        }
    }

    private static func scrolls(_ scroll: UIScrollView, vertically: Bool) -> Bool {
        guard scroll.isScrollEnabled else { return false }
        return vertically
            ? scroll.contentSize.height > scroll.bounds.height + 1
            : scroll.contentSize.width > scroll.bounds.width + 1
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
        routeTrackpadScrolls(from: hit, event: event)
        return hit
    }
    override var safeAreaInsets: UIEdgeInsets {
        var insets = super.safeAreaInsets
        insets.bottom = 0
        return insets
    }
}

#endif
