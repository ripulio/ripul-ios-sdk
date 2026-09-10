#if os(iOS)
import UIKit

@MainActor
enum NativeLabelIdentity {
    struct Capture {
        var selector: NativeLabelSelector?
        var reason: String?
    }

    static func ancestors(_ view: UIView) -> [UIView] {
        var result: [UIView] = []; var parent = view.superview
        while let node = parent { result.append(node); parent = node.superview }
        return result
    }
    static func screen(of view: UIView) -> UIViewController? {
        var responder: UIResponder? = view
        while let node = responder {
            if let controller = node as? UIViewController { return controller }
            responder = node.next
        }
        return nil
    }
    static func isAppType(_ type: AnyClass) -> Bool {
        let bundle = Bundle(for: type)
        return !(bundle.bundleIdentifier ?? "").hasPrefix("com.apple.") && bundle != Bundle(for: UIView.self)
    }
    static func allowed(_ label: UILabel) -> Bool {
        if let window = label.window, RipulChrome.isRipulWindow(window) { return false }
        // Other adapters own system control internals. UILabel support is for the
        // app's labels, including custom views shipped in other framework bundles.
        return !ancestors(label).contains { $0 is UIControl || $0 is UITabBar || $0 is UITextView }
    }
    static func cell(of label: UILabel) -> UIView? {
        ancestors(label).first { $0 is UITableViewCell || $0 is UICollectionViewCell }
    }
    static func owners(of label: UILabel) -> [NSObject] {
        var result: [NSObject] = ancestors(label).filter { isAppType(type(of: $0)) }
        if let controller = screen(of: label), isAppType(type(of: controller)) { result.append(controller) }
        return result
    }
    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    static func capture(_ label: UILabel) -> Capture {
        guard allowed(label), let controller = screen(of: label) else {
            return Capture(reason: "Select an app label on its screen. Text inside system controls uses a control adapter.")
        }
        var selector = NativeLabelSelector(screen: String(describing: type(of: controller)))
        if let id = nonempty(label.accessibilityIdentifier) { selector.identifier = id }
        else if let owner = owners(of: label).first(where: { InspectedView.storedPropertyName(on: $0, pointingTo: label) != nil }) {
            selector.ownerType = String(describing: type(of: owner))
            selector.property = InspectedView.storedPropertyName(on: owner, pointingTo: label)
        } else {
            return Capture(reason: "This label has no stable identifier or stored view property. Give it an identity through your shared view setup.")
        }
        if let cell = cell(of: label) {
            var row = NativeLabelSelector.Row(ownerType: String(describing: type(of: cell)))
            if let context = nonempty(RipulThemeInstrumentation.labelRowContextProvider?(cell)) { row.context = context }
            else if let id = nonempty(cell.accessibilityIdentifier) { row.identifier = id }
            else {
                row.enums = enumContext(in: cell)
                guard !row.enums.isEmpty else {
                    return Capture(reason: "This reused row needs a stable context. Use an identified row or the app-wide labelRowContextProvider hook.")
                }
            }
            selector.row = row
        }
        guard (try? selector.validate()) != nil else { return Capture(reason: "The label's identity is not suitable for a theme rule.") }
        return Capture(selector: selector)
    }

    static func matches(_ selector: NativeLabelSelector, label: UILabel) -> Bool {
        guard allowed(label), let controller = screen(of: label),
              String(describing: type(of: controller)) == selector.screen else { return false }
        if let id = selector.identifier {
            guard label.accessibilityIdentifier == id else { return false }
        } else {
            guard let owner = owners(of: label).first(where: { String(describing: type(of: $0)) == selector.ownerType }),
                  InspectedView.storedPropertyName(on: owner, pointingTo: label) == selector.property else { return false }
        }
        if let row = selector.row {
            guard let cell = cell(of: label), String(describing: type(of: cell)) == row.ownerType else { return false }
            if let context = row.context { return RipulThemeInstrumentation.labelRowContextProvider?(cell) == context }
            if let id = row.identifier { return cell.accessibilityIdentifier == id }
            return row.enums.allSatisfy { condition in
                guard let value = storedValue(in: cell, path: condition.path) else { return false }
                return enumCase(value) == condition.value
            }
        }
        // A selector captured outside a list must not bleed into reused rows.
        return cell(of: label) == nil
    }

    /// Only bounded stored-value reflection. No arbitrary KVC paths, computed
    /// getters, object graph traversal, string searches, or user-data capture.
    private static func unwrapped(_ value: Any) -> Any? {
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional { return mirror.children.first.flatMap { unwrapped($0.value) } }
        return value
    }
    private static func fields(_ value: Any) -> [(String, Any)] {
        var result: [(String, Any)] = []
        var mirror: Mirror? = Mirror(reflecting: value)
        while let layer = mirror, result.count < 128 {
            if let type = layer.subjectType as? AnyClass, !isAppType(type) { break }
            for child in layer.children.prefix(128 - result.count) {
                if let name = child.label { result.append((name, child.value)) }
            }
            mirror = layer.superclassMirror
        }
        return result
    }
    private static func enumCase(_ value: Any) -> String? {
        guard let value = unwrapped(value) else { return nil }
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .enum, mirror.children.isEmpty else { return nil }
        return String(describing: value)
    }
    static func enumContext(in owner: NSObject) -> [NativeLabelSelector.EnumValue] {
        var result: [NativeLabelSelector.EnumValue] = []; var budget = 128
        func visit(_ value: Any, path: [String]) {
            guard budget > 0, path.count <= 5, let value = unwrapped(value) else { return }; budget -= 1
            if let name = enumCase(value) { result.append(.init(path: path, value: name)); return }
            let mirror = Mirror(reflecting: value)
            guard path.isEmpty || mirror.displayStyle == .struct else { return }
            for (key, child) in fields(value) { visit(child, path: path + [key]) }
        }
        visit(owner, path: [])
        // An incomplete context is not a reliable selector.
        guard budget > 0, result.count <= 16 else { return [] }
        return result.sorted { $0.path.joined(separator: ".") < $1.path.joined(separator: ".") }
    }
    private static func storedValue(in owner: NSObject, path: [String]) -> Any? {
        var value: Any = owner
        for (index, key) in path.enumerated() {
            guard let root = unwrapped(value),
                  index == 0 || Mirror(reflecting: root).displayStyle == .struct,
                  let next = fields(root).first(where: { $0.0 == key })?.1 else { return nil }
            value = next
        }
        return unwrapped(value)
    }
}
#endif
