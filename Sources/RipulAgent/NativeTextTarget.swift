#if os(iOS)
import UIKit

/// All automatic text adapters share the same preview, draft and editor flow.
@MainActor
enum NativeTextTarget {
    case tabTitle(String)
    case label(NativeLabelSelector)

    var heading: String { switch self { case .tabTitle: return "Tab title"; case .label: return "Label text" } }
    var summary: String { switch self { case .tabTitle(let id): return id; case .label(let selector): return selector.summary } }
    var strategy: String { switch self { case .tabTitle: return "Accessibility identifier"; case .label(let selector): return selector.strategy } }
    var text: String {
        switch self {
        case .tabTitle(let id): return NativeTabTitleTheme.title(for: id) ?? ""
        case .label(let selector): return NativeLabelTheme.elements.first { $0.id == selector.id }?.text ?? ""
        }
    }
    var appText: String? {
        switch self {
        case .tabTitle(let id): return NativeTabTitleTheme.elements.first { $0.id == id }?.appTitle
        case .label(let selector): return NativeLabelTheme.appText(selector)
        }
    }
    func preview(_ text: String?) {
        switch self {
        case .tabTitle(let id): NativeTabTitleTheme.preview(text, identifier: id)
        case .label(let selector): NativeLabelTheme.preview(selector, text: text)
        }
    }
    func apply(_ text: String?) {
        switch self {
        case .tabTitle(let id): NativeTabTitleTheme.setOverride(text, identifier: id)
        case .label(let selector): NativeLabelTheme.setOverride(selector, text: text)
        }
    }
    func update(_ document: inout NativeTextTheme, text: String?) {
        switch self {
        case .tabTitle(let id): document.tabBarItemTitles[id] = text
        case .label(let selector): document.setLabel(selector, text: text)
        }
    }
}
#endif
