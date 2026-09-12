#if os(iOS)
import SwiftUI
import UIKit

/// An authored text property. App data is declared at the same address but cannot
/// be replaced by a theme. Arguments allow copy templates without storing user data.
public struct RipulTextAssignment: Equatable, Identifiable {
    public let element: String
    public let property: String
    public let label: String
    public let defaultToken: String?
    public let defaultText: String
    public let dataSource: String?
    public let arguments: [String: String]
    public var id: String { element + "/" + property }

    public init(element: String, property: String = "text", label: String = "Text",
                token: String? = nil, fallback: String, dataSource: String? = nil,
                arguments: [String: String] = [:]) {
        self.element = element; self.property = property; self.label = label
        defaultToken = token; defaultText = fallback; self.dataSource = dataSource; self.arguments = arguments
    }
    @MainActor public var text: String { RipulElementText.text(self) }
    @MainActor public var override: RipulTextReference? { NativeTextRuntime.current.elements[element]?[property] }
    @MainActor public func setReference(_ reference: RipulTextReference?) throws {
        guard dataSource == nil else { throw TextReferenceError.data }
        try RipulElementText.change { document in
            if let reference { _ = try RipulElementText.resolve(reference, document: document) }
            document.elements[element, default: [:]][property] = reference
            if document.elements[element]?.isEmpty == true { document.elements[element] = nil }
            RipulElementText.legacyTargets[id]?.update(&document, text: nil)
        }
    }
}

@MainActor
public enum RipulElementText {
    public private(set) static var defaults: [String: RipulTextReference] = [:]
    private static var catalogue: [String: RipulTextAssignment] = [:]
    static var legacyTargets: [String: NativeTextTarget] = [:]
    private static var observer: NSObjectProtocol?
    private static let views = NSHashTable<UIView>.weakObjects()
    public static var assignments: [RipulTextAssignment] { catalogue.values.sorted { $0.id < $1.id } }
    public static var tokenNames: [String] { Set(defaults.keys).union(NativeTextRuntime.current.tokens.keys).sorted() }
    public static func configure(defaults: [String: RipulTextReference]) { self.defaults = defaults; install() }
    public static func register(_ assignment: RipulTextAssignment) { catalogue[assignment.id] = assignment }
    /// Bridge a component's former native label to its authored text address without
    /// changing the label's rendering or losing an already-saved replacement.
    public static func associateLegacyLabel(_ label: UILabel, with assignment: RipulTextAssignment) {
        register(assignment)
        if let selector = NativeLabelTheme.capture(label).selector { legacyTargets[assignment.id] = .label(selector) }
    }
    public static func definition(_ name: String) -> RipulTextReference? { NativeTextRuntime.current.tokens[name] ?? defaults[name] }

    static func resolve(_ reference: RipulTextReference, document: NativeTextTheme,
                        visited: Set<String> = []) throws -> String {
        switch reference {
        case .text(let value): return value
        case .token(let name):
            guard !visited.contains(name), visited.count < 64 else { throw TextReferenceError.cycle }
            guard let next = document.tokens[name] ?? defaults[name] else { throw TextReferenceError.unknown(name) }
            return try resolve(next, document: document, visited: visited.union([name]))
        }
    }
    public static func tokenText(_ name: String) -> String? { try? resolve(.token(name), document: NativeTextRuntime.current) }
    static func validate(_ document: NativeTextTheme) throws {
        for name in document.tokens.keys { _ = try resolve(.token(name), document: document) }
        for properties in document.elements.values { for reference in properties.values { _ = try resolve(reference, document: document) } }
        for name in document.tabBarItemTokens.values { _ = try resolve(.token(name), document: document) }
        for name in document.labels.compactMap(\.token) { _ = try resolve(.token(name), document: document) }
    }
    static func text(_ assignment: RipulTextAssignment) -> String {
        register(assignment)
        guard assignment.dataSource == nil else { return assignment.defaultText }
        let reference = assignment.override ?? legacyTargets[assignment.id]?.reference
            ?? assignment.defaultToken.map(RipulTextReference.token) ?? .text(assignment.defaultText)
        let resolved = (try? resolve(reference, document: NativeTextRuntime.current)) ?? assignment.defaultText
        // Replace placeholders in the template once; parameter contents aren't templates.
        guard let regex = try? NSRegularExpression(pattern: #"\{([A-Za-z][A-Za-z0-9_]*)\}"#) else { return resolved }
        let input = resolved as NSString
        var output = resolved
        for match in regex.matches(in: resolved, range: NSRange(location: 0, length: input.length)).reversed() {
            if let value = assignment.arguments[input.substring(with: match.range(at: 1))],
               let range = Range(match.range, in: output) { output.replaceSubrange(range, with: value) }
        }
        return output
    }
    public static func setToken(_ name: String, reference: RipulTextReference?) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TextReferenceError.name }
        try change { document in
            document.tokens[name] = reference
            _ = try resolve(.token(name), document: document)
            // Validate dependents too; a changed source must not introduce an alias cycle.
            for key in document.tokens.keys { _ = try resolve(.token(key), document: document) }
        }
    }
    /// All text edits use the same durable draft, even before Theme Management opens.
    static func change(_ edit: (inout NativeTextTheme) throws -> Void) throws {
        if RipulThemeEngine.remoteTheme != nil { try ThemeManagementModel.saveTextMutation(edit) }
        else { var document = NativeTextRuntime.current; try edit(&document); try validate(document); NativeTextRuntime.adopt(document); broadcast() }
    }
    static func broadcast() { NotificationCenter.default.post(name: .ripulThemeDidChange, object: nil) }
    static func install() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .ripulThemeDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { for view in views.allObjects { reapply(view) } }
        }
    }
    /// Reusable native component adapter, including placeholders and button titles.
    public static func bind(_ view: UIView, assignments: [RipulTextAssignment],
                            apply: @escaping (UIView, [String: String]) -> Void) {
        install()
        if let label = view as? UILabel, binding(view) == nil,
           let selector = NativeLabelTheme.capture(label).selector,
           let assignment = assignments.first(where: { $0.property == "text" && $0.dataSource == nil }) {
            legacyTargets[assignment.id] = .label(selector)
        }
        assignments.forEach(register)
        objc_setAssociatedObject(view, &nativeTextBindingKey, NativeElementTextBinding(assignments, apply: apply), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        views.add(view); reapply(view)
    }
    public static func bindLabel(_ label: UILabel, assignment: RipulTextAssignment) {
        bind(label, assignments: [assignment]) { view, values in (view as? UILabel)?.text = values[assignment.property] }
    }
    public static func unbind(_ view: UIView) {
        objc_setAssociatedObject(view, &nativeTextBindingKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        views.remove(view)
    }
    static func binding(_ view: UIView) -> NativeElementTextBinding? {
        objc_getAssociatedObject(view, &nativeTextBindingKey) as? NativeElementTextBinding
    }
    static func reapply(_ view: UIView) {
        guard let binding = binding(view), !binding.writing else { return }
        if let label = view as? UILabel,
           let assignment = binding.assignments.first(where: { $0.property == "text" && $0.dataSource == nil }),
           legacyTargets[assignment.id] == nil, let selector = NativeLabelTheme.capture(label).selector {
            legacyTargets[assignment.id] = .label(selector)
        }
        binding.writing = true; defer { binding.writing = false }
        binding.apply(view, Dictionary(binding.assignments.map { ($0.property, text($0)) }, uniquingKeysWith: { _, last in last }))
    }
    static func properties(for view: UIView, identifier: String?) -> [RipulTextAssignment] {
        if let binding = binding(view) { return binding.assignments }
        guard let id = identifier, !id.isEmpty else { return [] }
        return assignments.filter { $0.element == id || $0.element.hasPrefix(id + ".") }
    }
}

private var nativeTextBindingKey: UInt8 = 0
final class NativeElementTextBinding {
    let assignments: [RipulTextAssignment]
    let apply: (UIView, [String: String]) -> Void
    var writing = false
    init(_ assignments: [RipulTextAssignment], apply: @escaping (UIView, [String: String]) -> Void) {
        self.assignments = assignments; self.apply = apply
    }
}

/// SwiftUI reads the same assignment it exposes to the inspector. Formatting modifiers
/// remain normal SwiftUI; hosts can wrap this in their shared text component.
public struct RipulThemedText: View {
    public let assignment: RipulTextAssignment
    public let stampsIdentity: Bool
    @Environment(\.ripulThemeVersion) private var version
    public init(_ assignment: RipulTextAssignment, stampsIdentity: Bool = true) {
        self.assignment = assignment; self.stampsIdentity = stampsIdentity
    }
    public var body: some View {
        let _ = version
        if stampsIdentity { Text(verbatim: assignment.text).uiKitIdentifier(assignment.element) }
        else { Text(verbatim: assignment.text) }
    }
}
#endif
