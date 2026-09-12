import Foundation
import CoreFoundation

/// Complete-document differences. Native label lists are matched by selector,
/// not array position; unknown collections remain atomic so review cannot hide data.
enum ThemeDocumentChanges {
    enum Kind: String, CaseIterable { case added = "Added", modified = "Changed", removed = "Removed" }
    struct Value {
        let raw: Any
        var encoded: Data? { try? JSONSerialization.data(withJSONObject: raw, options: [.fragmentsAllowed, .sortedKeys]) }
        var string: String? { raw as? String }
        var children: [(String, Value)]? {
            if let object = raw as? [String: Any] { return object.keys.sorted().map { ($0, Value(raw: object[$0]!)) } }
            if let array = raw as? [Any] { return array.enumerated().map { ("Item \($0.offset + 1)", Value(raw: $0.element)) } }
            return nil
        }
        var display: String {
            if let text = raw as? String { return text.isEmpty ? "Empty text" : text }
            if raw is NSNull { return "No value (null)" }
            if let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "True" : "False" }
            if let number = raw as? NSNumber { return number.stringValue }
            if let array = raw as? [Any] { return array.isEmpty ? "Empty list" : "\(array.count) \(array.count == 1 ? "item" : "items")" }
            if let object = raw as? [String: Any] {
                if object.count == 1, let token = object["token"] as? String { return "Token: " + token }
                if object.count == 1, let text = object["text"] as? String { return text.isEmpty ? "Empty text" : text }
                return object.isEmpty ? "Empty group" : "\(object.count) \(object.count == 1 ? "property" : "properties")"
            }
            return "No value"
        }
    }
    struct Change: Identifiable {
        let keys: [String]
        let old: Value?
        let new: Value?
        let selector: NativeLabelSelector?
        var path: String { "/" + keys.map { $0.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1") }.joined(separator: "/") }
        var id: String { path + (selector.map { "/selector:" + $0.id } ?? "") }
        var kind: Kind { old == nil ? .added : new == nil ? .removed : .modified }
        // Kept for non-visual consumers; the review uses typed values, never JSON blobs.
        var before: String { old.map { $0.string == "" ? "(empty text)" : $0.display } ?? "(not set)" }
        var after: String { new.map { $0.string == "" ? "(empty text)" : $0.display } ?? "(not set)" }
    }
    private static let labelPath = ["nativeTextOverrides", "labels"]
    private static func object(_ data: Data) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }
    private static func equal(_ a: Any?, _ b: Any?) -> Bool { a.map { Value(raw: $0).encoded } == b.map { Value(raw: $0).encoded } }

    /// Reject unknown fields from semantic handling: those must still appear in review.
    private static func labels(_ value: Any?) -> [String: NativeLabelOverride]? {
        guard let value else { return [:] }
        guard let array = value as? [[String: Any]], array.count <= 256 else { return nil }
        for item in array {
            guard Set(item.keys).isSubset(of: ["selector", "text", "token"]),
                  let selector = item["selector"] as? [String: Any],
                  Set(selector.keys).isSubset(of: ["screen", "identifier", "ownerType", "property", "row"]) else { return nil }
            if let row = selector["row"] as? [String: Any] {
                guard Set(row.keys).isSubset(of: ["ownerType", "identifier", "context", "enums"]) else { return nil }
                for condition in row["enums"] as? [[String: Any]] ?? [] {
                    guard Set(condition.keys).isSubset(of: ["path", "value"]) else { return nil }
                }
            }
        }
        guard let data = Value(raw: value).encoded, let rules = try? JSONDecoder().decode([NativeLabelOverride].self, from: data),
              Set(rules.map(\.id)).count == rules.count,
              rules.allSatisfy({ (try? $0.selector.validate()) != nil }) else { return nil }
        return Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0) })
    }
    static func compare(_ before: Data, _ after: Data) -> [Change] {
        guard let a = object(before), let b = object(after) else { return [] }
        var changes: [Change] = []
        func walk(_ a: Any?, _ b: Any?, keys: [String]) {
            guard !equal(a, b) else { return }
            if keys == labelPath, let x = labels(a), let y = labels(b), !x.isEmpty || !y.isEmpty {
                for id in Set(x.keys).union(y.keys).sorted() where x[id] != y[id] {
                    func shown(_ rule: NativeLabelOverride) -> Value { Value(raw: rule.token.map { ["token": $0] } as Any? ?? rule.text) }
                    changes.append(Change(keys: keys, old: x[id].map(shown), new: y[id].map(shown), selector: (y[id] ?? x[id])!.selector))
                }
                return
            }
            // A reference is one setting. Splitting token/text keys would let discard
            // leave an invalid object containing both alternatives.
            if keys.first == "nativeTextOverrides",
               (keys.count == 3 && keys[1] == "tokens") || (keys.count == 4 && keys[1] == "elements") {
                changes.append(Change(keys: keys, old: a.map(Value.init), new: b.map(Value.init), selector: nil)); return
            }
            let x = a as? [String: Any], y = b as? [String: Any]
            if (x != nil || a == nil), (y != nil || b == nil), x != nil || y != nil {
                let all = Set(x?.keys.map { $0 } ?? []).union(y?.keys.map { $0 } ?? [])
                if !all.isEmpty { for key in all.sorted() { walk(x?[key], y?[key], keys: keys + [key]) }; return }
            }
            changes.append(Change(keys: keys, old: a.map(Value.init), new: b.map(Value.init), selector: nil))
        }
        walk(a, b, keys: [])
        return changes
    }

    enum ReviewError: LocalizedError {
        case changed
        var errorDescription: String? { "The draft changed since this review. Review the latest changes and try again." }
    }
    /// Restore one reviewed change without touching siblings. Newly introduced empty
    /// ancestors are removed only when they were absent from the baseline.
    static func reverting(_ change: Change, baseline: Data, draft: Data) throws -> Data {
        guard let base = object(baseline), var root = object(draft),
              let current = compare(baseline, draft).first(where: { $0.id == change.id }),
              current.old?.encoded == change.old?.encoded, current.new?.encoded == change.new?.encoded else { throw ReviewError.changed }
        func value(_ root: Any?, at keys: [String]) -> Any? { keys.reduce(root) { ($0 as? [String: Any])?[$1] } }
        func restoring(_ object: [String: Any], base: [String: Any]?, keys: ArraySlice<String>, replacement: Any?) -> [String: Any] {
            guard let key = keys.first else { return object }
            var result = object
            if keys.count == 1 { result[key] = replacement }
            else {
                let child = restoring(result[key] as? [String: Any] ?? [:], base: base?[key] as? [String: Any], keys: keys.dropFirst(), replacement: replacement)
                result[key] = child.isEmpty && base?[key] == nil ? nil : child
            }
            return result
        }
        if let selector = change.selector {
            var array = value(root, at: labelPath) as? [[String: Any]] ?? []
            func id(_ entry: [String: Any]) -> String? {
                guard let raw = entry["selector"], let bytes = Value(raw: raw).encoded else { return nil }
                return (try? JSONDecoder().decode(NativeLabelSelector.self, from: bytes))?.id
            }
            array.removeAll { id($0) == selector.id }
            let original = value(base, at: labelPath) as? [[String: Any]] ?? []
            if let entry = original.first(where: { id($0) == selector.id }) { array.append(entry) }
            // Restore the baseline's relative order while retaining other draft entries.
            let order = original.compactMap(id)
            array.sort { (order.firstIndex(of: id($0) ?? "") ?? Int.max) < (order.firstIndex(of: id($1) ?? "") ?? Int.max) }
            let replacement: Any? = array.isEmpty && value(base, at: labelPath) == nil ? nil : array
            root = restoring(root, base: base, keys: labelPath[...], replacement: replacement)
        } else { root = restoring(root, base: base, keys: change.keys[...], replacement: value(base, at: change.keys)) }
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}
