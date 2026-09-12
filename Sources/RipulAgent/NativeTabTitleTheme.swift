#if os(iOS)
import UIKit

private var nativeTabTitleStateKey: UInt8 = 0

/// Event-driven adapter for public UITabBarItem titles. No private view classes,
/// position selectors, repeated window scans, or host-specific registrations.
@MainActor
enum NativeTabTitleTheme {
    private final class State {
        var appTitle: String?
        var applying = false
        weak var tabBar: UITabBar?
        var wasAttached = false
        init(_ title: String?) { appTitle = title }
    }
    private static let items = NSHashTable<UITabBarItem>.weakObjects()
    private static var installed = false
    private static var previews: [String: String] = [:]

    static func install() {
        guard !installed else { return }; installed = true
        NativeTextHooks.intercept(UITabBarItem.self, #selector(setter: UITabBarItem.title), #selector(UITabBarItem.ripul_setThemeTitle(_:)))
        NativeTextHooks.intercept(UITabBarItem.self, #selector(setter: UITabBarItem.accessibilityIdentifier), #selector(UITabBarItem.ripul_setThemeIdentifier(_:)))
        NativeTextHooks.intercept(UITabBar.self, #selector(UITabBar.setItems(_:animated:)), #selector(UITabBar.ripul_setThemeItems(_:animated:)))
        NativeTextHooks.intercept(UITabBar.self, #selector(UITabBar.didMoveToWindow), #selector(UITabBar.ripul_themeDidMoveToWindow))
        // Covers apps opting in after their existing tabs have been constructed.
        func discover(_ view: UIView) {
            if let bar = view as? UITabBar { register(bar.items ?? [], in: bar) }
            for child in view.subviews { discover(child) }
        }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows { discover(window) }
        }
    }

    private static func state(_ item: UITabBarItem) -> State {
        if let state = objc_getAssociatedObject(item, &nativeTabTitleStateKey) as? State { return state }
        let state = State(item.title)
        objc_setAssociatedObject(item, &nativeTabTitleStateKey, state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        items.add(item)
        return state
    }

    static func register(_ newItems: [UITabBarItem], in bar: UITabBar) {
        for item in newItems {
            let record = state(item)
            record.tabBar = bar; record.wasAttached = true
        }
        reapply()
    }

    private static func isLive(_ item: UITabBarItem) -> Bool {
        let record = state(item)
        return !record.wasAttached || record.tabBar?.items?.contains(where: { $0 === item }) == true
    }

    static func titleAssigned(_ title: String?, to item: UITabBarItem) {
        let record = state(item)
        if record.applying { item.ripul_setThemeTitle(title); return }
        record.appTitle = title
        // If the app explicitly changes a detached item, preserve normal UIKit
        // semantics. Theme broadcasts must not poke UIKit's destroyed item views.
        guard isLive(item) else { item.ripul_setThemeTitle(title); return }
        reapply()
    }

    static func identifierAssigned(to item: UITabBarItem) {
        _ = state(item)
        reapply() // also restores items whose old identifier became ambiguous/unbound
    }

    static func clearPreviews() { previews.removeAll() }

    static func setOverride(_ title: String?, identifier: String) {
        previews.removeValue(forKey: identifier)
        NativeTextRuntime.mutate { $0.tabBarItemTitles[identifier] = title; $0.tabBarItemTokens[identifier] = nil }
    }

    static func preview(_ title: String?, identifier: String) {
        previews[identifier] = title
        reapply()
    }

    static func reapply() {
        // UIKit may retain a tab item after destroying its rendered owner. Changing
        // that orphan's title can dereference UIKit's unowned view on iOS 27.
        // Reattachment registers it again and applies the latest theme then.
        let live = items.allObjects.filter(isLive)
        let counts = Dictionary(grouping: live.compactMap { $0.accessibilityIdentifier }, by: { $0 }).mapValues(\.count)
        for item in live {
            let record = state(item)
            guard !record.applying else { continue }
            var title = record.appTitle
            if let id = item.accessibilityIdentifier, counts[id] == 1 {
                title = previews[id] ?? NativeTextRuntime.current.tabBarItemTokens[id].flatMap(RipulElementText.tokenText)
                    ?? NativeTextRuntime.current.tabBarItemTitles[id] ?? record.appTitle
            }
            guard item.title != title else { continue }
            record.applying = true
            item.title = title
            record.applying = false
        }
    }

    struct Element: Identifiable {
        let id: String
        let title: String
        let appTitle: String?
        let mounted: Bool
        let ambiguous: Bool
    }
    static var elements: [Element] {
        let grouped = Dictionary(grouping: items.allObjects.filter { isLive($0) && !($0.accessibilityIdentifier ?? "").isEmpty }, by: { $0.accessibilityIdentifier! })
        return Set(grouped.keys).union(NativeTextRuntime.current.tabBarItemTitles.keys).union(NativeTextRuntime.current.tabBarItemTokens.keys).sorted().map { id in
            let matching = grouped[id] ?? []
            let item = matching.first
            return Element(id: id, title: item?.title ?? NativeTextRuntime.current.tabBarItemTokens[id].flatMap(RipulElementText.tokenText) ?? NativeTextRuntime.current.tabBarItemTitles[id] ?? "",
                           appTitle: item.flatMap { state($0).appTitle }, mounted: item != nil,
                           ambiguous: matching.count > 1)
        }
    }

    /// Resolve the selected rendered view to its owning public item using its existing
    /// identifier and containing tab bar. Never infer identity from text or tab position.
    static func identifier(for view: UIView, resolvedIdentifier: String? = nil) -> String? {
        var candidate = resolvedIdentifier
        var ancestor: UIView? = view
        while let node = ancestor {
            if let bar = node as? UITabBar {
                guard let id = candidate, !id.isEmpty else { return nil }
                let matching = (bar.items ?? []).filter { $0.accessibilityIdentifier == id }
                guard matching.count == 1 else { return nil }
                register(bar.items ?? [], in: bar)
                guard items.allObjects.filter({ isLive($0) && $0.accessibilityIdentifier == id }).count == 1 else { return nil }
                return id
            }
            if candidate == nil, let id = node.accessibilityIdentifier, !id.isEmpty { candidate = id }
            ancestor = node.superview
        }
        return nil
    }

    static func title(for identifier: String) -> String? {
        elements.first { $0.id == identifier }?.title
    }
}

extension UITabBarItem {
    @objc fileprivate func ripul_setThemeTitle(_ title: String?) { NativeTabTitleTheme.titleAssigned(title, to: self) }
    @objc fileprivate func ripul_setThemeIdentifier(_ identifier: String?) {
        ripul_setThemeIdentifier(identifier)
        NativeTabTitleTheme.identifierAssigned(to: self)
    }
}
extension UITabBar {
    @objc fileprivate func ripul_setThemeItems(_ items: [UITabBarItem]?, animated: Bool) {
        ripul_setThemeItems(items, animated: animated)
        NativeTabTitleTheme.register(items ?? [], in: self)
    }
    @objc fileprivate func ripul_themeDidMoveToWindow() {
        ripul_themeDidMoveToWindow()
        NativeTabTitleTheme.register(items ?? [], in: self)
    }
}
#endif
