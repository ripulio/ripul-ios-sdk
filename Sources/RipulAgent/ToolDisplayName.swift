import Foundation

/// Display-only tool names, matching the web's formatToolDisplayName.
enum ToolDisplayName {
    static func format(_ name: String) -> String {
        let words = name.replacingOccurrences(of: "^mcp__ripul_tools_+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "_+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    static func activity(toolName: String, label: String?) -> String {
        // Shell activity already carries the shared executable identity (e.g.
        // "Python + Status"); retain its individual command labels.
        if NativeToolRendererKind.resolve(toolName) == .terminal,
           let label, !label.isEmpty, !label.contains("_") {
            return label
        }
        return format(label.flatMap { $0.isEmpty ? nil : $0 } ?? toolName)
    }
}
