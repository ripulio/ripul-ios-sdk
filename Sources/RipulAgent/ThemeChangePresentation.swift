#if os(iOS)
import SwiftUI

/// Display names come from the host's existing vocabulary and scope descriptors.
/// Unknown host fields still get a structured, complete review.
@MainActor
struct ThemeChangePresentation: Identifiable {
    enum Category: String, CaseIterable { case text = "Text", colors = "Colours", styles = "Styles", settings = "Settings" }
    let change: ThemeDocumentChanges.Change
    var category: Category = .settings
    var title: String
    var context: String
    var property = "Value"
    var unset = "Not set"
    var defaultText: String?
    var options: [String: String] = [:]
    var isColor = false
    var id: String { change.id }

    init(_ change: ThemeDocumentChanges.Change, spec: RipulThemeSpec? = RipulThemeEngine.reviewSpec) {
        self.change = change
        let keys = change.keys
        title = Self.readable(keys.last ?? "Theme")
        context = keys.dropLast().map(Self.readable).joined(separator: " › ")
        if let selector = change.selector {
            category = .text; title = "Label text"; property = "Text"; unset = "App default"
            defaultText = NativeLabelTheme.appText(selector)
            let row = selector.row.map { $0.context ?? $0.identifier ?? $0.enums.map(\.value).joined(separator: ", ") }
            context = [Self.screenName(selector.screen), row.map(Self.readable), (selector.identifier ?? selector.property).map(Self.readable)].compactMap { $0 }.joined(separator: " › ")
            return
        }
        if keys.starts(with: ["nativeTextOverrides", "tabBarItemTitles"]), keys.count == 3 {
            category = .text; title = Self.readable(keys[2].components(separatedBy: ".").last ?? keys[2])
            context = "Tab bar"; property = "Tab title"; unset = "App default"
            defaultText = NativeTabTitleTheme.elements.first { $0.id == keys[2] }?.appTitle
            return
        }
        if keys.first == "nativeTextOverrides", keys.count >= 3,
           ["tokens", "elements", "tabBarItemTokens"].contains(keys[1]) {
            category = .text; title = Self.readable(keys[2]); unset = "Author default"
            context = keys[1] == "tokens" ? "Shared text tokens" : "Text assignments"
            property = keys.last == "token" || keys[1] == "tabBarItemTokens" ? "Assigned token" : "Text"
            if keys[1] == "elements", keys.count >= 4 {
                let assignment = RipulElementText.assignments.first { $0.element == keys[2] && $0.property == keys[3] }
                property = assignment?.label ?? Self.readable(keys[3]); defaultText = assignment?.defaultText
            }
            return
        }
        if keys.first == "elementColors", keys.count == 3 {
            category = .colors; isColor = true; title = Self.readable(keys[1])
            context = "Individual colour overrides"; property = Self.readable(keys[2]); unset = "Author default"
            return
        }
        guard let spec else { return }
        let vocabularies: [(String, String, [RipulThemeVocabulary.Entry])] = [
            (spec.primitivesKey, "Palette", spec.vocabulary.primitives),
            (spec.semanticKey, "Semantic colours", spec.vocabulary.roles),
            (spec.componentsKey, "Component colours", spec.vocabulary.components)
        ]
        if keys.count == 2, let group = vocabularies.first(where: { $0.0 == keys[0] }) {
            let entry = group.2.first { $0.name == keys[1] }
            category = .colors; isColor = true; property = "Colour"; unset = "Theme default"
            title = entry?.label ?? Self.readable(keys[1]); context = ([group.1] + (entry?.path ?? [])).joined(separator: " › "); return
        }
        for kind in spec.styleKinds {
            guard let persisted = kind.persistedKeys, let root = keys.first,
                  [persisted.styles, persisted.assignments, persisted.overrides].contains(root), keys.count >= 2 else { continue }
            let scope = kind.scopes.first { $0.id == keys[1] }
            category = .styles; unset = "Inherited value"
            title = root == persisted.styles ? keys[1] : scope?.label ?? Self.readable(keys[1])
            context = (kind.path + [kind.label] + (scope?.path ?? [])).joined(separator: " › ")
            property = root == persisted.assignments ? "Assigned style" : "Style"
            if keys.count == 3, let knob = kind.knobs.first(where: { $0.key == keys[2] }) {
                property = knob.label
                switch knob.kind {
                case .text: category = .text
                case .color: category = .colors; isColor = true
                case .bool: options = ["True": "On", "False": "Off"]
                case .options(let values): options = Dictionary(values.map { ($0.raw, $0.label) }, uniquingKeysWith: { first, _ in first })
                case .number: break
                }
            }
            return
        }
    }
    func display(_ value: ThemeDocumentChanges.Value?) -> String {
        guard let value else { return defaultText.map { $0.isEmpty ? "Empty text" : $0 } ?? unset }
        return options[value.display] ?? value.display
    }
    var searchable: String { [title, context, property, display(change.old), display(change.new), change.path, change.selector?.summary ?? ""].joined(separator: " ") }
    static func readable(_ key: String) -> String {
        let words = key.replacingOccurrences(of: "([A-Z]+)([A-Z][a-z])", with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: "[_.-]+", with: " ", options: .regularExpression)
        return words.prefix(1).uppercased() + words.dropFirst()
    }
    private static func screenName(_ name: String) -> String {
        for suffix in ["ViewController", "Controller", "VC", "Screen"] where name.hasSuffix(suffix) && name.count > suffix.count {
            return readable(String(name.dropLast(suffix.count)))
        }
        return readable(name)
    }
    /// Resolve each side against its own document; a draft colour must never be
    /// used to illustrate the published value.
    func swatch(_ value: ThemeDocumentChanges.Value?, document: Data, spec: RipulThemeSpec? = RipulThemeEngine.reviewSpec) -> Color? {
        guard isColor, var reference = value?.string,
              let root = (try? JSONSerialization.jsonObject(with: document)) as? [String: Any] else { return nil }
        let maps = [spec?.componentsKey ?? "components", spec?.semanticKey ?? "semantic", spec?.primitivesKey ?? "colors"].compactMap { root[$0] as? [String: String] }
        let defaults = (spec?.vocabulary.components ?? []) + (spec?.vocabulary.roles ?? []) + (spec?.vocabulary.primitives ?? [])
        var visited = Set<String>()
        while visited.insert(reference).inserted && visited.count <= 32 {
            let hex = reference.hasPrefix("#") ? String(reference.dropFirst()) : reference
            if hex.count == 6, let rgb = UInt64(hex, radix: 16) {
                return Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
            }
            guard let next = maps.lazy.compactMap({ $0[reference] }).first ?? defaults.first(where: { $0.name == reference })?.defaultReference else { return nil }
            reference = next
        }
        return nil
    }
}

/// Word-level emphasis retains whitespace and leaves unchanged words readable.
enum ThemeTextDifference {
    static func emphasized(_ text: String, comparedTo other: String, removal: Bool) -> AttributedString {
        guard text.count <= 4_000, other.count <= 4_000 else { return AttributedString(text) }
        func tokens(_ value: String) -> [String] {
            guard let regex = try? NSRegularExpression(pattern: #"\s+|\S+"#) else { return [value] }
            let ns = value as NSString
            return regex.matches(in: value, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
        }
        let words = tokens(text), previous = tokens(other)
        let additions = Set(words.difference(from: previous).compactMap { change -> Int? in
            if case .insert(let offset, _, _) = change { return offset }; return nil
        })
        var result = AttributedString()
        for (index, word) in words.enumerated() {
            var part = AttributedString(word)
            if additions.contains(index), !word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                part.backgroundColor = removal ? Color.red.opacity(0.13) : Color.green.opacity(0.15)
                if removal { part.strikethroughStyle = .single }
            }
            result.append(part)
        }
        return result
    }
}
#endif
