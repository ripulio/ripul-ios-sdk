#if os(iOS)
import UIKit

// MARK: - Text the system draws
//
// A navigation title, a segmented control's labels and a tab bar's labels are drawn by
// UIKit, which reads no SwiftUI environment: under a themed family they stay in the system
// font beside it (docs/theming.md, "Text the system draws"). UIKit's appearance settings
// reach them. They are set only while a theme names a text family, and put back to "not
// set" when it stops naming one, so with no theme nothing here is ever touched.
//
// A navigation title's colour goes the same way: it is UIKit's label colour, which no
// SwiftUI style reaches, so under a theme that names `text` the large and the inline
// title are given it. Tab and segment labels keep the colours the system gives each state.

extension RipulTheme {
    /// Main thread only.
    private static var systemTextIsThemed = false
    private static var textSizeObserver: NSObjectProtocol?

    /// Called on the main thread whenever the theme changes.
    /// True when a theme names a text family or a text colour: either changes what the
    /// system's own titles should be drawn with.
    static var hasThemedSystemText: Bool { hasThemedTextFamily || !isDefault(.text) }

    static func applySystemTextAppearance() {
        let themed = hasThemedSystemText
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
        if hasThemedTextFamily, textSizeObserver == nil {
            textSizeObserver = NotificationCenter.default.addObserver(
                forName: UIContentSizeCategory.didChangeNotification, object: nil, queue: .main
            ) { _ in applySystemTextAppearance() }
        } else if !hasThemedTextFamily, let observer = textSizeObserver {
            NotificationCenter.default.removeObserver(observer)
            textSizeObserver = nil
        }
    }

    /// Set the bars already in one window, for a window that appears under a themed
    /// family. Main thread only.
    static func restyleSystemText(in window: UIWindow) {
        guard hasThemedSystemText else { return }
        restyle(window, SystemTextFonts())
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

    /// The system's own size and weight for each, in the theme's family when a theme
    /// names one, and the theme's text colour for the two titles when it names that.
    private struct SystemTextFonts {
        let family = RipulTheme.hasThemedTextFamily
        let ink: UIColor? = RipulTheme.isDefault(.text) ? nil : UIColor.ripul(.text)
        let title = UIFont.ripul(.headline)
        let largeTitle = UIFont.ripul(.largeTitle, weight: .bold)
        let segment = UIFont.ripul(.footnote, weight: .medium)
        let selectedSegment = UIFont.ripul(.footnote, weight: .semibold)
        let tab = UIFont.ripul(size: 10, weight: .medium)

        /// nil, which is "not set", when the theme says nothing about this text.
        func attributes(_ font: KeyPath<SystemTextFonts, UIFont>) -> [NSAttributedString.Key: Any]? {
            var out: [NSAttributedString.Key: Any] = [:]
            if family { out[.font] = self[keyPath: font] }
            if let ink, font == \SystemTextFonts.title || font == \SystemTextFonts.largeTitle { out[.foregroundColor] = ink }
            return out.isEmpty ? nil : out
        }
    }
}
#endif
