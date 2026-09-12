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
    var reference: RipulTextReference? {
        switch self {
        case .tabTitle(let id):
            if let token = NativeTextRuntime.current.tabBarItemTokens[id] { return .token(token) }
            return NativeTextRuntime.current.tabBarItemTitles[id].map(RipulTextReference.text)
        case .label(let selector):
            guard let rule = NativeTextRuntime.current.labels.first(where: { $0.id == selector.id }) else { return nil }
            return rule.token.map(RipulTextReference.token) ?? .text(rule.text)
        }
    }
    func update(_ document: inout NativeTextTheme, reference: RipulTextReference?) {
        switch self {
        case .tabTitle(let id):
            document.tabBarItemTokens[id] = nil; document.tabBarItemTitles[id] = nil
            switch reference {
            case .token(let token): document.tabBarItemTokens[id] = token; document.tabBarItemTitles[id] = appText ?? text
            case .text(let value): document.tabBarItemTitles[id] = value
            case nil: break
            }
        case .label(let selector):
            switch reference {
            case .token(let token): document.setLabel(selector, text: appText ?? text, token: token)
            case .text(let value): document.setLabel(selector, text: value)
            case nil: document.setLabel(selector, text: nil)
            }
        }
    }
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
        update(&document, reference: text.map(RipulTextReference.text))
    }
}
#endif
