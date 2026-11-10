#if os(iOS) && !targetEnvironment(macCatalyst)
import UIKit

/// The system's tab bar where it stands at the side of the window as a rail
/// (an iPhone Duo, folded or open), read from public UIKit geometry. Its items
/// and glass are not inside the `UITabBar` view: UIKit hosts them in the tab
/// bar controller's own view, within the bar's strip.
@MainActor
enum SystemTabRail {
    /// The tab bar controller whose bar stands at the side of `window` and is
    /// showing, with the bar's frame in window coordinates. Cheap: no walk of
    /// any views.
    static func rail(in window: UIWindow) -> (controller: UITabBarController, frame: CGRect)? {
        guard let controller = tabBarController(from: window.rootViewController) else { return nil }
        if #available(iOS 18.0, *), controller.isTabBarHidden { return nil }
        let bar = controller.tabBar
        guard bar.window === window, isShowing(bar, in: window) else { return nil }
        let frame = bar.convert(bar.bounds, to: window)
        // Standing at the side: taller than wide. A bottom bar is the opposite.
        guard frame.height > frame.width, frame.intersects(window.bounds) else { return nil }
        return (controller, frame)
    }

    private static func isShowing(_ view: UIView, in window: UIWindow) -> Bool {
        var current: UIView? = view
        while let candidate = current, candidate !== window {
            if candidate.isHidden || candidate.alpha < 0.01 { return false }
            current = candidate.superview
        }
        return !view.bounds.isEmpty
    }

    private static func tabBarController(from root: UIViewController?) -> UITabBarController? {
        guard let root else { return nil }
        if let controller = root as? UITabBarController { return controller }
        for child in root.children {
            if let found = tabBarController(from: child) { return found }
        }
        return tabBarController(from: root.presentedViewController)
    }
}

/// The window's corner radii as UIKit resolves container-concentric corners
/// against it: the display's own corners for a full-screen window. Public API
/// (iOS 26); nil before it.
@MainActor
enum WindowCornerRadii {
    static func bottom(of window: UIWindow) -> (left: CGFloat, right: CGFloat)? {
        guard #available(iOS 26.0, *) else { return nil }
        let probe = UIView(frame: window.bounds)
        probe.isUserInteractionEnabled = false
        probe.alpha = 0
        probe.cornerConfiguration = .corners(radius: .containerConcentric())
        window.insertSubview(probe, at: 0)
        defer { probe.removeFromSuperview() }
        probe.setNeedsLayout()
        probe.layoutIfNeeded()
        return (probe.effectiveRadius(corner: .bottomLeft), probe.effectiveRadius(corner: .bottomRight))
    }
}
#endif
