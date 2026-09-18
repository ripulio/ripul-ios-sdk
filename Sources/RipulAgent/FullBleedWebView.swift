#if os(iOS)
import UIKit
import WebKit

/// WKWebView subclass that zeroes-out bottom safe area insets so web content
/// (100vh, 100%) fills the entire frame including the home indicator region.
/// The native chat input overlay handles bottom spacing instead.
class FullBleedWebView: WKWebView {
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
        toolStripHitTest?(point, event) ?? super.hitTest(point, with: event)
    }
    override var safeAreaInsets: UIEdgeInsets {
        var insets = super.safeAreaInsets
        insets.bottom = 0
        return insets
    }
}

#endif
