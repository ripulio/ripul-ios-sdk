import Foundation

/// Leaf changes for the phone's publication review. JSON-pointer paths are unambiguous
/// even when a host uses dots/slashes in its element IDs. Arrays are reviewed as a unit.
enum ThemeDocumentChanges {
    struct Change { let path: String; let before: String; let after: String }
    static func compare(_ before: Data, _ after: Data) -> [Change] {
        guard let a = try? JSONSerialization.jsonObject(with: before),
              let b = try? JSONSerialization.jsonObject(with: after) else { return [] }
        var changes: [Change] = []
        func display(_ value: Any?) -> String {
            guard let value else { return "(not set)" }
            if let text = value as? String { return text.isEmpty ? "(empty text)" : text }
            guard let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]) else { return "" }
            return String(decoding: bytes, as: UTF8.self)
        }
        func walk(_ a: Any?, _ b: Any?, path: String) {
            if let x = a as? [String: Any], let y = b as? [String: Any] {
                for key in Set(x.keys).union(y.keys).sorted() {
                    walk(x[key], y[key], path: path + "/" + key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1"))
                }
            } else {
                let x = a.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed, .sortedKeys]) }
                let y = b.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed, .sortedKeys]) }
                if x != y { changes.append(Change(path: path.isEmpty ? "/" : path, before: display(a), after: display(b))) }
            }
        }
        walk(a, b, path: "")
        return changes
    }
}
