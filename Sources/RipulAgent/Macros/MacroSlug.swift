import Foundation

/// Turns a developer-typed macro name into a valid `run_macro_<slug>` tool-name
/// suffix (mirrors `NativeTool`'s snake_case naming convention). Pure string
/// logic — no UIKit — used by the phase-2 save sheet.
public enum MacroSlug {
    public static func slug(from name: String) -> String {
        let lowered = name.lowercased()
        let mapped = lowered.map { $0.isLetter || $0.isNumber ? $0 : "_" }
        var result = String(mapped)
        while result.contains("__") { result = result.replacingOccurrences(of: "__", with: "_") }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }
}
