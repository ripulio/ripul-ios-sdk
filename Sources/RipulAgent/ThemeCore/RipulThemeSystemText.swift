#if os(iOS)
import UIKit

// MARK: - Text the system draws
//
// A navigation title, a segmented control's labels and a tab bar's labels are drawn by
// UIKit, which reads no SwiftUI environment: under a themed family they stay in the system
// font beside it (docs/theming.md, "Text the system draws"). UIKit's appearance settings
// reach them. They are set only while a theme names a text family, and put back to "not
// set" when it stops naming one, so with no theme nothing here is ever touched.

extension RipulTheme {
    /// Main thread only.
    private static var systemTextIsThemed = false
    private static var textSizeObserver: NSObjectProtocol?

    /// Called on the main thread whenever the theme changes.
    static func applySystemTextAppearance() {
        let themed = hasThemedTextFamily
        guard themed || systemTextIsThemed else { return }
        systemTextIsThemed = themed

        let fonts = themed ? SystemTextFonts() : nil
        let navigationBar = UINavigationBar.appearance()
        navigationBar.titleTextAttributes = fonts?.attributes(\.title)
        navigationBar.largeTitleTextAttributes = fonts?.attributes(\.largeTitle)
        let segmented = UISegmentedControl.appearance()
        segmented.setTitleTextAttributes(fonts?.attributes(\.segment), for: .normal)
        segmented.setTitleTextAttributes(fonts?.attributes(\.selectedSegment), for: .selected)
        let tabItem = UITabBarItem.appearance()
        tabItem.setTitleTextAttributes(fonts?.attributes(\.tab), for: .normal)
        tabItem.setTitleTextAttributes(fonts?.attributes(\.tab), for: .selected)

        // An appearance setting reaches a view when it joins a window. The ones already
        // on screen are set directly, so a switch shows at once.
        for scene in UIApplication.shared.connectedScenes {
            guard let scene = scene as? UIWindowScene else { continue }
            for window in scene.windows { restyle(window, fonts) }
        }

        // The sizes are read once, so read them again when the text size setting changes.
        if themed, textSizeObserver == nil {
            textSizeObserver = NotificationCenter.default.addObserver(
                forName: UIContentSizeCategory.didChangeNotification, object: nil, queue: .main
            ) { _ in applySystemTextAppearance() }
        } else if !themed, let observer = textSizeObserver {
            NotificationCenter.default.removeObserver(observer)
            textSizeObserver = nil
        }
    }

    private static func restyle(_ view: UIView, _ fonts: SystemTextFonts?) {
        if let bar = view as? UINavigationBar {
            bar.titleTextAttributes = fonts?.attributes(\.title)
            bar.largeTitleTextAttributes = fonts?.attributes(\.largeTitle)
        } else if let segmented = view as? UISegmentedControl {
            segmented.setTitleTextAttributes(fonts?.attributes(\.segment), for: .normal)
            segmented.setTitleTextAttributes(fonts?.attributes(\.selectedSegment), for: .selected)
            return
        } else if let tabBar = view as? UITabBar {
            for item in tabBar.items ?? [] {
                item.setTitleTextAttributes(fonts?.attributes(\.tab), for: .normal)
                item.setTitleTextAttributes(fonts?.attributes(\.tab), for: .selected)
            }
        }
        for subview in view.subviews { restyle(subview, fonts) }
    }

    /// The system's own size and weight for each, in the theme's family.
    private struct SystemTextFonts {
        let title = UIFont.ripul(.headline)
        let largeTitle = UIFont.ripul(.largeTitle, weight: .bold)
        let segment = UIFont.ripul(.footnote, weight: .medium)
        let selectedSegment = UIFont.ripul(.footnote, weight: .semibold)
        let tab = UIFont.ripul(size: 10, weight: .medium)

        func attributes(_ font: KeyPath<SystemTextFonts, UIFont>) -> [NSAttributedString.Key: Any] {
            [.font: self[keyPath: font]]
        }
    }
}
#endif
