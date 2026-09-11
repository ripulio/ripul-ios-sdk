#if os(iOS)
import SwiftUI
import UIKit

/// An authored styling role at a stable element/property address. The default is never
/// rewritten by an override, so removing an exception restores the current shared theme.
public struct RipulColourAssignment: Equatable, Hashable, Identifiable {
    public let element: String
    public let property: String
    public let defaultToken: String
    public var id: String { element + "/" + property }
    public init(element: String, property: String, defaultToken: String) {
        self.element = element; self.property = property; self.defaultToken = defaultToken
    }
    public var override: String? { RipulThemeEngine.current.elementColors[element]?[property] }
    public var reference: String { override ?? defaultToken }
    public var colour: UIColor {
        let value = RipulThemeEngine.colourReference(reference)
        // Preserve authored identity even when the exception is a literal colour.
        value.ripulToken = defaultToken
        value.ripulColourAssignment = self
        return value
    }
    public func setReference(_ reference: String?) {
        var document = RipulThemeEngine.current
        document.elementColors[element, default: [:]][property] = reference
        if document.elementColors[element]?.isEmpty == true { document.elementColors[element] = nil }
        if let persist = RipulThemeEngine.persistMutation { persist(document) }
        else { RipulThemeEngine.adopt(document) }
    }
}

private var colourAssignmentKey: UInt8 = 0
public extension UIColor {
    var ripulColourAssignment: RipulColourAssignment? {
        get { objc_getAssociatedObject(self, &colourAssignmentKey) as? RipulColourAssignment }
        set { objc_setAssociatedObject(self, &colourAssignmentKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}

public extension RipulThemeEngine {
    /// Reference resolution at an element boundary; shared token resolution retains its
    /// existing tier rules (including primitive/role names that intentionally overlap).
    static func colourReference(_ reference: String) -> UIColor {
        if let color = color(forTokenName: reference) { return color }
        return UIColor(ripulHexString: primitiveHex(reference) ?? reference) ?? .magenta
    }
    static func colour(element: String, property: String, defaultToken: String) -> UIColor {
        let assignment = RipulColourAssignment(element: element, property: property, defaultToken: defaultToken)
        RipulElementColours.register(assignment)
        return assignment.colour
    }
}

/// A runtime catalogue supplements persisted exceptions. Only stable author identifiers
/// are eligible; coordinates, displayed copy and UIKit wrapper identities are never keys.
public enum RipulElementColours {
    private static var catalogue: [String: RipulColourAssignment] = [:]
    public static var assignments: [RipulColourAssignment] { catalogue.values.sorted { $0.id < $1.id } }
    public static func register(_ assignment: RipulColourAssignment) { catalogue[assignment.id] = assignment }

    /// Central component adapter for CGColor sinks (gradients, borders and shadows).
    /// The closure receives the view, so callers need not retain it in their closure.
    public static func bind(_ view: UIView, tokens: [String: String], apply: @escaping (UIView, [String: UIColor]) -> Void) {
        objc_setAssociatedObject(view, &nativeColourBindingKey, NativeColourBinding(tokens: tokens, apply: apply), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        reapply(view)
    }

    /// Remove an adapter when a reusable view changes to a style without those sinks.
    public static func unbind(_ view: UIView) {
        if let binding = objc_getAssociatedObject(view, &nativeColourBindingKey) as? NativeColourBinding {
            view.ripulDeclaredTokenColors.removeAll { binding.tokens[$0.property] != nil }
        }
        objc_setAssociatedObject(view, &nativeColourBindingKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// Read the token actually authored on a UIKit property, or on a SwiftUI declaration.
    public static func assignment(view: UIView, property: String, colour: UIColor?) -> RipulColourAssignment? {
        if let existing = colour?.ripulColourAssignment { register(existing); return existing }
        guard let identifier = view.accessibilityIdentifier, !identifier.isEmpty,
              !identifier.hasPrefix("dogtags:"), let token = colour?.ripulToken else { return nil }
        let value = RipulColourAssignment(element: identifier, property: property, defaultToken: token)
        register(value)
        return value
    }

    static func resolved(view: UIView, property: String, colour: UIColor?) -> UIColor? {
        if let value = assignment(view: view, property: property, colour: colour) {
            return value.colour.ripulAlpha(colour?.cgColor.alpha ?? 1)
        }
        guard let token = colour?.ripulToken else { return nil }
        return RipulThemeEngine.color(forTokenName: token)?.ripulAlpha(colour?.cgColor.alpha ?? 1)
    }

    static func install() {
        let pairs: [(AnyClass, Selector, Selector)] = [
            (UILabel.self, #selector(setter: UILabel.textColor), #selector(UILabel.ripul_elementTextColor(_:))),
            (UITextField.self, #selector(setter: UITextField.textColor), #selector(UITextField.ripul_elementTextColor(_:))),
            (UITextView.self, #selector(setter: UITextView.textColor), #selector(UITextView.ripul_elementTextColor(_:))),
            (UIButton.self, #selector(UIButton.setTitleColor(_:for:)), #selector(UIButton.ripul_elementTitleColor(_:for:))),
            (UIView.self, #selector(setter: UIView.tintColor), #selector(UIView.ripul_elementTintColor(_:))),
            (UIView.self, #selector(UIView.didMoveToWindow), #selector(UIView.ripul_elementDidMoveToWindow))
        ]
        for (type, original, replacement) in pairs {
            if let a = class_getInstanceMethod(type, original), let b = class_getInstanceMethod(type, replacement) {
                method_exchangeImplementations(a, b)
            }
        }
    }

    /// Repaint actual UIKit colour sinks. SwiftUI rendering uses the modifier below.
    /// This also discovers existing tokenised UIKit controls without per-label adapters.
    public static func reapply(_ view: UIView) {
        func resolved(_ property: String, _ colour: UIColor?) -> UIColor? {
            Self.resolved(view: view, property: property, colour: colour)
        }
        if let token = view.ripulBackgroundToken, let id = view.accessibilityIdentifier, !id.hasPrefix("dogtags:") {
            view.backgroundColor = RipulThemeEngine.colour(element: id, property: "background", defaultToken: token)
                .ripulAlpha(view.backgroundColor?.cgColor.alpha ?? 1)
        }
        if let label = view as? UILabel, let c = resolved("foreground", label.textColor) { label.textColor = c }
        if let field = view as? UITextField, let c = resolved("foreground", field.textColor) { field.textColor = c }
        if let field = view as? UITextView, let c = resolved("foreground", field.textColor) { field.textColor = c }
        if let button = view as? UIButton {
            for state: UIControl.State in [.normal, .highlighted, .disabled, .selected] {
                if let c = resolved("foreground", button.titleColor(for: state)) { button.setTitleColor(c, for: state) }
            }
        }
        if view is UIControl || view is UIImageView, let c = resolved("tint", view.tintColor) { view.tintColor = c }
        if let binding = objc_getAssociatedObject(view, &nativeColourBindingKey) as? NativeColourBinding,
           let id = view.accessibilityIdentifier, !id.isEmpty {
            var resolved: [String: UIColor] = [:]
            for (property, token) in binding.tokens {
                resolved[property] = RipulThemeEngine.colour(element: id, property: property, defaultToken: token)
            }
            view.ripulDeclaredTokenColors = resolved.keys.sorted().map { .init(property: $0, color: resolved[$0]!) }
            binding.apply(view, resolved)
        }
    }
}

private var nativeColourBindingKey: UInt8 = 0
private final class NativeColourBinding {
    let tokens: [String: String]
    let apply: (UIView, [String: UIColor]) -> Void
    init(tokens: [String: String], apply: @escaping (UIView, [String: UIColor]) -> Void) {
        self.tokens = tokens; self.apply = apply
    }
}

private extension UILabel {
    @objc func ripul_elementTextColor(_ colour: UIColor?) {
        ripul_elementTextColor(RipulElementColours.resolved(view: self, property: "foreground", colour: colour) ?? colour)
    }
}
private extension UITextField {
    @objc func ripul_elementTextColor(_ colour: UIColor?) {
        ripul_elementTextColor(RipulElementColours.resolved(view: self, property: "foreground", colour: colour) ?? colour)
    }
}
private extension UITextView {
    @objc func ripul_elementTextColor(_ colour: UIColor?) {
        ripul_elementTextColor(RipulElementColours.resolved(view: self, property: "foreground", colour: colour) ?? colour)
    }
}
private extension UIButton {
    @objc func ripul_elementTitleColor(_ colour: UIColor?, for state: UIControl.State) {
        ripul_elementTitleColor(RipulElementColours.resolved(view: self, property: "foreground", colour: colour) ?? colour, for: state)
    }
}
private extension UIView {
    @objc func ripul_elementTintColor(_ colour: UIColor?) {
        ripul_elementTintColor(RipulElementColours.resolved(view: self, property: "tint", colour: colour) ?? colour)
    }
    @objc func ripul_elementDidMoveToWindow() {
        ripul_elementDidMoveToWindow()
        if window != nil { RipulElementColours.reapply(self) }
    }
}

@available(iOS 14.0, *)
private struct ElementForeground: ViewModifier {
    let identifier: String
    let token: String
    let label: String
    let opacity: Double
    @Environment(\.ripulThemeVersion) private var version
    func body(content: Content) -> some View {
        let _ = version
        let colour = RipulThemeEngine.colour(element: identifier, property: "foreground", defaultToken: token)
        content.foregroundColor(Color(colour).opacity(opacity))
            .uiKitIdentifier(identifier, tokenColors: [label: colour])
    }
}

public extension View {
    /// One render + identity + assignment declaration, including live theme invalidation.
    func ripulForeground(_ identifier: String, token: String, label: String = "Text colour", opacity: Double = 1) -> some View {
        modifier(ElementForeground(identifier: identifier, token: token, label: label, opacity: opacity))
    }
}
#endif
